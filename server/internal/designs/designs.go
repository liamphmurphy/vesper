// Package designs is the Designs app (docs/design/ADR-designs.md): designs the
// person builds with a persona. A design is a canvas of kind "design" in its
// own chat in the person's Designs space, like a Slides deck. Its images are
// design_assets rows over content-addressed blobs (swept with the decks'),
// its switches are design_settings, and a persona's patches are held as
// design_proposals until the person accepts or rejects each op.
package designs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/canvas"
	"github.com/liamphmurphy/vesper/server/internal/design"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/slides"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// AppName marks the Designs app's space in chat_spaces.app.
const AppName = "designs"

// SpaceInstructions reach every chat the Designs app starts (ADR §3.9).
const SpaceInstructions = `This chat belongs to one design in the person's Designs app: the design canvas in this chat (find its canvas_id with design_list). They see it in an editor and talk to you from a panel beside it.

How to work on it:
- Outline first: call design_outline to see the pages and nodes, then design_read the nodes you will change before you touch them. Never guess ids.
- Change it with design_patch, against the version you read. While you answer, your patches build a draft only you see (design_read, design_outline and design_render show it), so finish the work before you reply. When your reply ends the person gets the result as one suggestion of the net changes, which they accept or reject, unless they let you edit directly. Say in a sentence what you changed. Don't patch the same thing again while a suggestion is pending.
- Use the design's tokens ("$name"), not hex, for colours; design_read shows each token's value. Use auto layout (auto_layout, hug and fill sizing) for UI, not hand-placed coordinates.
- Give every op a specific why, for example "Make the button stand out" rather than "Update button". The person reads it in the review.
- Never paste the design's JSON into the chat. Refer to nodes by name.
- For a diagram (a flow, states, an architecture), write it as a Mermaid flowchart and design_import it rather than placing shapes and connectors op by op; add notes with add_sticky.
- design_render a frame to check your work before you reply.
- When the person says "this" or "these", they mean the nodes selected in their editor, which arrive with their message. If a message tells you what they rejected and why, take it on board and don't suggest it again.
- Comments on nodes are in design_comments; answer them with design_reply (addressed once done), or flag something yourself with design_comment.
Keep replies short.`

// UntitledTitle names a design started without a title.
const UntitledTitle = "Untitled design"

// MaxAssetEdge caps a design image's longest side (ADR §3.6).
const MaxAssetEdge = 4096

const (
	maxSummary = 500
	maxReason  = 500
)

type Service struct {
	Pool *pgxpool.Pool
	Runs *runs.Service
	// Worker renders designs; Blobs and Bucket hold their images, which go to
	// the worker as data URIs. Any may be nil: rendering is then unavailable.
	Worker *Worker
	Blobs  *blob.Store
	Bucket string
}

func (s *Service) canvases() *canvas.Service { return &canvas.Service{Pool: s.Pool} }

// EnsureSpace is the person's Designs space, made the first time it's needed.
func (s *Service) EnsureSpace(ctx context.Context, ws, user uuid.UUID) (store.ChatSpace, error) {
	q := store.New(s.Pool)
	sp, err := q.GetAppSpace(ctx, store.GetAppSpaceParams{WorkspaceID: ws, UserID: user, AppName: AppName})
	if !errors.Is(err, pgx.ErrNoRows) {
		return sp, err
	}
	return q.CreateAppSpace(ctx, store.CreateAppSpaceParams{WorkspaceID: ws, UserID: user, Name: "Designs", Color: "teal",
		Description: "Flows, diagrams and wireframes you design with the assistant.", Instructions: SpaceInstructions, AppName: AppName})
}

// CleanTitle collapses whitespace and checks the length.
func CleanTitle(title string) (string, error) {
	title = strings.Join(strings.Fields(title), " ")
	if title == "" {
		title = UntitledTitle
	}
	if utf8.RuneCountInString(title) > 200 {
		return "", apperr.Invalid("title", "must be at most 200 characters")
	}
	return title, nil
}

// start makes a chat in the Designs space holding a design canvas with body,
// and records the project the chat ended up in.
func (s *Service) start(ctx context.Context, ws, user uuid.UUID, title, body, note, project string) (store.ChatCanvas, store.ChatSession, error) {
	sp, err := s.EnsureSpace(ctx, ws, user)
	if err != nil {
		return store.ChatCanvas{}, store.ChatSession{}, err
	}
	chat, err := s.Runs.StartChat(ctx, ws, user, runs.ChatInput{Title: title, SpaceID: &sp.ID, Project: project})
	if err != nil {
		return store.ChatCanvas{}, chat, err
	}
	cv, _, err := s.canvases().Create(ctx, chat.ID, canvas.New{Kind: canvas.KindDesign, Title: title, Body: body, Note: note}, canvas.Actor{Type: "user", ID: user})
	if err != nil {
		return cv, chat, err
	}
	if chat.ProjectID != nil {
		err = store.New(s.Pool).UpsertDesignSettings(ctx, store.UpsertDesignSettingsParams{CanvasID: cv.ID, ProjectID: chat.ProjectID})
	}
	return cv, chat, err
}

// Create starts a design from a starter (design.Starters; "" is blank).
// project is a project key, or empty.
func (s *Service) Create(ctx context.Context, ws, user uuid.UUID, title, starter, project string) (store.ChatCanvas, store.ChatSession, error) {
	title, err := CleanTitle(title)
	if err != nil {
		return store.ChatCanvas{}, store.ChatSession{}, err
	}
	body, err := design.Starter(starter)
	if err != nil {
		return store.ChatCanvas{}, store.ChatSession{}, err
	}
	note := ""
	if starter != "" && starter != "blank" {
		note = "Started from the " + starter + " starter"
	}
	return s.start(ctx, ws, user, title, body, note, project)
}

// CreateInChat starts a design from a starter in an existing chat: a persona's
// design_create, so the design opens beside the conversation that asked for
// it and the persona's design tools reach it there. project is a project key
// ("" keeps the chat's own project). In a turn (turn non-nil) the design
// starts blank and the starter goes into the turn's draft, so its placeholder
// frames are only ever the persona's scaffolding: the person sees what the
// persona made of them when the turn ends.
func (s *Service) CreateInChat(ctx context.Context, ws uuid.UUID, chat store.ChatSession, title, starter, project string, by canvas.Actor, runID, turn *uuid.UUID) (store.ChatCanvas, store.ChatCanvasVersion, error) {
	title, err := CleanTitle(title)
	if err != nil {
		return store.ChatCanvas{}, store.ChatCanvasVersion{}, err
	}
	body, err := design.Starter(starter)
	if err != nil {
		return store.ChatCanvas{}, store.ChatCanvasVersion{}, err
	}
	var seed []design.Op
	if turn != nil && starter != "" && starter != "blank" {
		blank, err := design.Starter("blank")
		if err != nil {
			return store.ChatCanvas{}, store.ChatCanvasVersion{}, err
		}
		why := func(string) string { return "Start from the " + starter + " starter" }
		if seed, err = design.Diff(blank, body, why); err == nil {
			body, starter = blank, ""
		}
	}
	q := store.New(s.Pool)
	projectID := chat.ProjectID
	if project != "" {
		p, err := q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: project})
		if errors.Is(err, pgx.ErrNoRows) {
			return store.ChatCanvas{}, store.ChatCanvasVersion{}, apperr.Invalid("project", "there's no project %s", project)
		}
		if err != nil {
			return store.ChatCanvas{}, store.ChatCanvasVersion{}, err
		}
		projectID = &p.ID
	}
	note := ""
	if starter != "" && starter != "blank" {
		note = "Started from the " + starter + " starter"
	}
	cv, v, err := s.canvases().Create(ctx, chat.ID, canvas.New{Kind: canvas.KindDesign, Title: title, Body: body, Note: note}, by)
	if err != nil {
		return cv, v, err
	}
	if projectID != nil {
		if err = q.UpsertDesignSettings(ctx, store.UpsertDesignSettingsParams{CanvasID: cv.ID, ProjectID: projectID}); err != nil {
			return cv, v, err
		}
	}
	if len(seed) > 0 {
		raw, err := json.Marshal(seed)
		if err != nil {
			return cv, v, err
		}
		_, err = q.CreateDesignProposal(ctx, store.CreateDesignProposalParams{CanvasID: cv.ID, ChatID: &chat.ID, RunID: runID, TurnID: turn,
			AgentID: by.ID, BaseSeq: v.Seq, Summary: "Draft " + title, Ops: raw, Status: StatusDraft})
		return cv, v, err
	}
	return cv, v, err
}

// Duplicate copies a design's current version, with fresh ids, its images and
// its project into a new design and chat. Proposals and switches stay behind.
func (s *Service) Duplicate(ctx context.Context, ws, user uuid.UUID, src store.GetMyCanvasRow) (store.ChatCanvas, store.ChatSession, error) {
	q := store.New(s.Pool)
	cur, err := q.LatestChatCanvasVersion(ctx, src.ID)
	if err != nil {
		return store.ChatCanvas{}, store.ChatSession{}, err
	}
	body, err := design.Remint(cur.Body)
	if err != nil {
		return store.ChatCanvas{}, store.ChatSession{}, err
	}
	set, err := q.GetDesignSettings(ctx, src.ID)
	if err != nil {
		return store.ChatCanvas{}, store.ChatSession{}, err
	}
	project := ""
	if set.ProjectID != nil {
		p, err := q.GetProject(ctx, store.GetProjectParams{ID: *set.ProjectID, WorkspaceID: ws})
		if err == nil {
			project = p.Key
		}
	}
	title := "Copy of " + src.Title
	if r := []rune(title); len(r) > 200 {
		title = string(r[:200])
	}
	cv, chat, err := s.start(ctx, ws, user, title, body, fmt.Sprintf("Copied from %s", src.Title), project)
	if err != nil {
		return cv, chat, err
	}
	if err := q.CopyDesignAssets(ctx, store.CopyDesignAssetsParams{ToCanvas: cv.ID, FromCanvas: src.ID}); err != nil {
		// Don't leave a copy whose images are missing.
		_ = s.Runs.DeleteChat(context.WithoutCancel(ctx), ws, user, chat.ID)
		return store.ChatCanvas{}, store.ChatSession{}, err
	}
	return cv, chat, nil
}

// Rename sets a design's title.
func (s *Service) Rename(ctx context.Context, cv store.GetMyCanvasRow, title string) error {
	title, err := CleanTitle(title)
	if err != nil {
		return err
	}
	return store.New(s.Pool).RenameCanvas(ctx, store.RenameCanvasParams{ID: cv.ID, Title: title})
}

// Settings are a design's switches.
type Settings = store.GetDesignSettingsRow

// UpdateSettings changes the switches that are set.
func (s *Service) UpdateSettings(ctx context.Context, id uuid.UUID, directEdit, paused *bool) (Settings, error) {
	q := store.New(s.Pool)
	cur, err := q.GetDesignSettings(ctx, id)
	if err != nil {
		return cur, err
	}
	if directEdit != nil {
		cur.DirectEdit = *directEdit
	}
	if paused != nil {
		cur.PersonaPaused = *paused
	}
	if err := q.UpsertDesignSettings(ctx, store.UpsertDesignSettingsParams{CanvasID: id, DirectEdit: cur.DirectEdit, PersonaPaused: cur.PersonaPaused, ProjectID: cur.ProjectID}); err != nil {
		return cur, err
	}
	return cur, nil
}

// ReadAsset checks an uploaded image (PNG or JPEG, 10 MB, 4096 px on a side)
// and keys it under designs/{workspace}/{user}/{sha256}.
func ReadAsset(r io.Reader, ws, user uuid.UUID) (slides.Asset, error) {
	a, err := slides.ReadAsset(r, ws, user)
	if err != nil {
		return a, err
	}
	if a.Width > MaxAssetEdge || a.Height > MaxAssetEdge {
		return a, apperr.Invalid("file", "images are at most %d pixels on a side", MaxAssetEdge)
	}
	a.Key = "designs/" + strings.TrimPrefix(a.Key, "slides/")
	return a, nil
}

// AddAsset lists an image under a design, holding the blob's sweep lock (see
// slides.Service.AddAsset).
func (s *Service) AddAsset(ctx context.Context, p store.CreateDesignAssetParams) (store.DesignAsset, error) {
	var row store.DesignAsset
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if err := q.LockDeckBlob(ctx, p.BlobKey); err != nil {
			return err
		}
		var err error
		row, err = q.CreateDesignAsset(ctx, p)
		return err
	})
	return row, err
}

// ---- proposals ----

// Proposal states and decision states (ADR §3.7).
const (
	StatusPending  = "pending"
	StatusResolved = "resolved"
	StatusApplied  = "applied"

	Accepted = "accepted"
	Rejected = "rejected"
	Stale    = "stale"
)

// Patch is a persona's design_patch.
type Patch struct {
	CanvasID, ChatID uuid.UUID
	RunID            *uuid.UUID
	// TurnID is the chat turn the patch is part of: its ops join that turn's
	// draft (drafts.go). Nil outside a turn, where a patch stands alone.
	TurnID  *uuid.UUID
	AgentID uuid.UUID
	Base    int32
	Summary string
	Ops     []design.Op
}

// Proposed is what a patch became: a pending proposal, or (direct edit on)
// an applied one with the version it wrote. Nodes are the nodes its ops are
// about, with the ids minted for any the persona left unnamed.
type Proposed struct {
	Proposal store.DesignProposal
	Version  *store.ChatCanvasVersion
	Nodes    []string
}

// Propose takes a persona's patch on a design. During a chat turn it joins
// the turn's draft, published when the turn ends (drafts.go). Outside one,
// with direct edit off (the default) it dry-runs the ops and holds them as a
// pending proposal, leaving the design untouched; with it on, it applies them
// as a version by the persona and records the proposal as applied. Either way
// the patch must be against the current version (409 otherwise), and a
// paused design refuses it.
func (s *Service) Propose(ctx context.Context, p Patch) (Proposed, error) {
	var out Proposed
	summary := strings.TrimSpace(p.Summary)
	if n := utf8.RuneCountInString(summary); n < 1 || n > maxSummary {
		return out, apperr.Invalid("summary", "sum the patch up in 1–%d characters", maxSummary)
	}
	if len(p.Ops) == 0 || len(p.Ops) > 100 {
		return out, apperr.Invalid("ops", "provide 1 to 100 ops")
	}
	for i, op := range p.Ops {
		if err := design.CheckOp(i, op, true); err != nil {
			return out, err
		}
	}
	design.MintIDs(p.Ops)
	out.Nodes = design.Touches(p.Ops)
	raw, err := json.Marshal(p.Ops)
	if err != nil {
		return out, err
	}
	if p.TurnID != nil {
		nodes := out.Nodes
		out, err = s.draft(ctx, p, summary, raw)
		out.Nodes = nodes
		return out, err
	}
	err = s.canvases().Locked(ctx, p.ChatID, p.CanvasID, func(q *store.Queries, c store.ChatCanvas, cur store.ChatCanvasVersion) error {
		if c.Kind != canvas.KindDesign {
			return apperr.Invalid("canvas_id", "isn't a design")
		}
		set, err := q.GetDesignSettings(ctx, c.ID)
		if err != nil {
			return err
		}
		if set.PersonaPaused {
			return apperr.Conflict("the person paused persona edits on this design; wait until they resume")
		}
		if p.Base != cur.Seq {
			return apperr.Conflict("this design is at version %d, not %d; read it again and redo your patch", cur.Seq, p.Base)
		}
		// Apply mutates its ops; keep the stored ones as sent.
		var ops []design.Op
		if err := json.Unmarshal(raw, &ops); err != nil {
			return err
		}
		body, err := design.Apply(cur.Body, ops)
		if err != nil {
			return err
		}
		if body == cur.Body {
			return apperr.Invalid("ops", "these ops change nothing")
		}
		in := store.CreateDesignProposalParams{CanvasID: c.ID, ChatID: &p.ChatID, RunID: p.RunID, AgentID: p.AgentID, BaseSeq: cur.Seq,
			Summary: summary, Ops: raw, Status: StatusPending}
		if set.DirectEdit {
			v, err := canvas.WriteVersion(ctx, q, c, cur, body, summary, canvas.Actor{Type: "agent", ID: p.AgentID})
			if err != nil {
				return err
			}
			out.Version = &v
			in.Status, in.ResultSeq = StatusApplied, &v.Seq
		}
		out.Proposal, err = q.CreateDesignProposal(ctx, in)
		return err
	})
	return out, err
}

// Decision is the person's call on one op of a proposal.
type Decision struct {
	I      int    `json:"i"`
	State  string `json:"state"`
	Reason string `json:"reason,omitempty"`
}

// Resolved is a resolved proposal and the version accepting it wrote, if any.
type Resolved struct {
	Proposal store.DesignProposal
	Version  *store.ChatCanvasVersion
}

// Resolve records the person's decision on every op of a pending proposal and
// applies the accepted ones on the current version (not the proposal's base):
// ops are id-keyed, so they rebase. An accepted op that no longer applies (its
// target is gone) is marked stale and skipped, so the person's own later edits
// win. Accepting an op that needs another the person rejected is refused.
func (s *Service) Resolve(ctx context.Context, cv store.GetMyCanvasRow, ws, user, id uuid.UUID, decisions []Decision) (Resolved, error) {
	var out Resolved
	var feedbackOps []design.Op
	var feedbackStates []Decision
	err := s.canvases().Locked(ctx, cv.ChatID, cv.ID, func(q *store.Queries, c store.ChatCanvas, cur store.ChatCanvasVersion) error {
		p, err := q.LockDesignProposal(ctx, store.LockDesignProposalParams{ID: id, CanvasID: c.ID})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		} else if err != nil {
			return err
		}
		if p.Status != StatusPending {
			return apperr.Conflict("this suggestion was already %s", p.Status)
		}
		var ops []design.Op
		if err := json.Unmarshal(p.Ops, &ops); err != nil {
			return err
		}
		states, err := checkDecisions(ops, decisions)
		if err != nil {
			return err
		}
		var accepted []design.Op
		var at []int
		for i, op := range ops {
			if states[i].State == Accepted {
				accepted, at = append(accepted, op), append(at, i)
			}
		}
		var resultSeq *int32
		if len(accepted) > 0 {
			body, applied, err := design.ApplyEach(cur.Body, accepted)
			if err != nil {
				return err
			}
			n := 0
			for k, ok := range applied {
				if ok {
					n++
				} else {
					states[at[k]].State = Stale
				}
			}
			if n > 0 && body != cur.Body {
				note := fmt.Sprintf("Accepted %d of %d suggested changes", n, len(ops))
				v, err := canvas.WriteVersion(ctx, q, c, cur, body, note, canvas.Actor{Type: "user", ID: user})
				if err != nil {
					return err
				}
				out.Version, resultSeq = &v, &v.Seq
				if _, err := q.MarkMyCanvasReviewed(ctx, store.MarkMyCanvasReviewedParams{ID: c.ID, WorkspaceID: ws, UserID: user, Seq: v.Seq}); err != nil {
					return err
				}
			}
		}
		raw, err := json.Marshal(states)
		if err != nil {
			return err
		}
		out.Proposal, err = q.ResolveDesignProposal(ctx, store.ResolveDesignProposalParams{ID: p.ID, Decisions: raw, ResultSeq: resultSeq})
		if err != nil {
			return err
		}
		ops = append([]design.Op(nil), ops...)
		feedbackOps, feedbackStates = ops, states
		return nil
	})
	if err != nil {
		return out, err
	}
	// The resolution is saved; telling the persona is best effort.
	if msg := feedbackText(s.personName(ctx, ws, user), out.Proposal.Summary, feedbackOps, feedbackStates); msg != "" && out.Proposal.ChatID != nil {
		if err := s.postFeedback(ctx, *out.Proposal.ChatID, cv.ID, msg); err != nil {
			slog.Default().Error("posting design review feedback", "canvas", cv.ID, "err", err)
		}
	}
	return out, nil
}

func (s *Service) personName(ctx context.Context, ws, user uuid.UUID) string {
	if u, err := store.New(s.Pool).GetUser(ctx, store.GetUserParams{ID: user, WorkspaceID: ws}); err == nil && strings.TrimSpace(u.Name) != "" {
		return strings.TrimSpace(u.Name)
	}
	return "The person"
}

// feedbackText words what the persona should hear after a review: each
// rejected op with its why and the person's reason, and each stale op. It's
// empty when everything was accepted.
func feedbackText(who, summary string, ops []design.Op, states []Decision) string {
	var lines []string
	why := func(i int) string {
		w, _ := ops[i]["why"].(string)
		return strings.TrimSpace(w)
	}
	for i, d := range states {
		switch d.State {
		case Rejected:
			l := fmt.Sprintf("%s rejected '%s'", who, why(i))
			if d.Reason != "" {
				l += ": " + d.Reason
			}
			lines = append(lines, l)
		case Stale:
			lines = append(lines, fmt.Sprintf("'%s' was accepted but no longer applied (what it changed is gone), so it was skipped", why(i)))
		}
	}
	if len(lines) == 0 {
		return ""
	}
	return fmt.Sprintf("Review of your design suggestion \"%s\":\n- %s", summary, strings.Join(lines, "\n- "))
}

// postFeedback records the notice as a system message in the design's chat,
// carrying a canvas ref so the next turn's prompt includes it
// (runner.ChatTurnContext). It starts no turn. Concurrent appenders to a chat
// collide on the message seq, so it retries.
func (s *Service) postFeedback(ctx context.Context, chat, canvasID uuid.UUID, body string) error {
	refs, err := json.Marshal([]runs.ChatContextRef{{Kind: "canvas", ID: &canvasID}})
	if err != nil {
		return err
	}
	q := store.New(s.Pool)
	for attempt := 0; ; attempt++ {
		_, err = q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chat, Role: "system", BodyMd: body, ContextRefs: refs, Citations: []byte("[]")})
		var pg *pgconn.PgError
		if err == nil || attempt >= 3 || !errors.As(err, &pg) || pg.Code != "23505" {
			return err
		}
	}
}

// checkDecisions wants exactly one accepted or rejected decision per op, so a
// review can't skip one by accident, and no accepted op that needs an op the
// person rejected (one that creates what it refers to).
func checkDecisions(ops []design.Op, ds []Decision) ([]Decision, error) {
	out := make([]Decision, len(ops))
	seen := make([]bool, len(ops))
	for _, d := range ds {
		if d.I < 0 || d.I >= len(ops) {
			return nil, apperr.Invalid("decisions", "op %d isn't in this suggestion (it has %d)", d.I, len(ops))
		}
		if seen[d.I] {
			return nil, apperr.Invalid("decisions", "op %d is decided twice", d.I)
		}
		if d.State != Accepted && d.State != Rejected {
			return nil, apperr.Invalid("decisions", "op %d: state must be accepted or rejected", d.I)
		}
		d.Reason = strings.TrimSpace(d.Reason)
		if utf8.RuneCountInString(d.Reason) > maxReason {
			return nil, apperr.Invalid("decisions", "op %d: a reason is at most %d characters", d.I, maxReason)
		}
		if d.State == Accepted {
			d.Reason = ""
		}
		seen[d.I], out[d.I] = true, d
	}
	for i, ok := range seen {
		if !ok {
			return nil, apperr.Invalid("decisions", "decide op %d too: every change needs accepted or rejected", i)
		}
	}
	for j, deps := range design.Deps(ops) {
		for _, i := range deps {
			if out[j].State == Accepted && out[i].State == Rejected {
				return nil, apperr.Invalid("decisions", "op %d needs op %d, which you rejected; reject op %d too or accept op %d", j, i, j, i)
			}
		}
	}
	return out, nil
}
