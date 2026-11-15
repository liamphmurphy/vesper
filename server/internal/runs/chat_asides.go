package runs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// An aside is a question about a reply while it runs, answered without
// interrupting it. Each aside is a hidden chat of its own (parent_chat_id),
// answered in a fresh read-only session whose prompt carries the parent's
// recent conversation and either a snapshot of the running reply, an anchored
// message (thread), or a second-opinion critique (optionally on another
// harness/model with branch/turn diff context). The aside reads but changes
// nothing (ChatCaps.Aside: no shell, images, connectors or secrets, and only
// the read tools over MCP), so it can't race the main reply or invalidate the
// parent chat's warm prompt cache.

const (
	// MaxLiveAsides bounds the asides answering at once for one chat.
	MaxLiveAsides = 3
	// asideHistoryChars bounds the parent's conversation an aside gets.
	asideHistoryChars = 12000
	// asideEvents is how many of the running reply's latest events it gets.
	asideEvents = 60
	// asideInputRunes and asideOutputRunes clip one tool call's input and output.
	asideInputRunes  = 240
	asideOutputRunes = 600
	asideTextRunes   = 2000
	// asideSnapshotRunes bounds the whole snapshot of the running reply.
	asideSnapshotRunes = 16000
	// secondOpinionDiffRunes bounds the diff/commit snapshot on a second opinion.
	secondOpinionDiffRunes = 24000
)

// AsideInput configures StartChatAsideWith.
type AsideInput struct {
	Body            string
	AnchorMessageID *uuid.UUID
	Harness         string
	Model           string
	Effort          string
	SecondOpinion   bool
	Repository      string
}

const asideFooter = `---
(Vesper: this is an aside. While you keep working on the reply above in the main conversation, the person asked the question below. You are a separate instance answering only this question: the main reply carries on without seeing it, and nothing you write here reaches it.
Answer briefly and concretely from the snapshot above and the conversation; use the read tools if you need more. Don't create, change or delete anything (tickets, epics, memory, canvases, chats, code). If the question asks to change what the main reply is doing, say so, and that the person can queue it as a follow-up or send it to interrupt.)

The person's question:
`

const threadFooter = `---
(Vesper: this is a thread about the message above, which the person picked in the main conversation. You are a separate instance answering in this side conversation: the main conversation doesn't see it, and nothing you write here reaches it.
Answer about that message, concretely; use the read tools if you need more. Don't create, change or delete anything (tickets, epics, memory, canvases, chats, code). If the person asks for a change, say so, and that they can ask for it in the main conversation.)

The person's question:
`

const secondOpinionFooter = `---
(Vesper: this is a read-only second-opinion aside. The main conversation stays on its active harness session so its prompt cache remains warm, and nothing you write here modifies the main chat or workspace.
Give a direct, high-signal critique: highlight blind spots, subtle bugs, race conditions, edge cases, architectural tradeoffs, or confirm clearly if the approach looks solid. Don't create, change or delete anything (tickets, epics, memory, canvases, chats, code); use read tools only if you need more context.)

The person's request:
`

// StartChatAside asks a question beside the chat's main conversation and
// returns the aside: a hidden chat whose first turn answers it. Without an
// anchor it is about the running reply, so something must be running. With
// one it is a thread about that message of the chat, which can start at any
// time.
func (s *Service) StartChatAside(ctx context.Context, ws, user, parentID uuid.UUID, question string, anchor *uuid.UUID) (store.ChatSession, error) {
	return s.StartChatAsideWith(ctx, ws, user, parentID, AsideInput{
		Body:            question,
		AnchorMessageID: anchor,
	})
}

// StartChatAsideWith starts an aside, thread, or read-only cross-harness second
// opinion on parentID without mutating the parent chat's active session.
func (s *Service) StartChatAsideWith(ctx context.Context, ws, user, parentID uuid.UUID, in AsideInput) (store.ChatSession, error) {
	var out store.ChatSession
	question := strings.TrimSpace(in.Body)
	n := len([]rune(question))
	if n > 20000 || (n == 0 && !in.SecondOpinion) {
		return out, apperr.Invalid("body", "provide 1–20000 characters")
	}
	err := s.tx(ctx, func(q *store.Queries) error {
		parent, err := lockChat(ctx, q, ws, user, parentID)
		if err != nil {
			return err
		}
		switch {
		case parent.Archived:
			return apperr.Conflict("the chat is archived")
		case parent.ParentChatID != nil:
			return apperr.Conflict("an aside can't have asides of its own")
		}
		anchor := in.AnchorMessageID
		var anchored *store.ChatMessage
		if anchor != nil {
			m, err := q.GetChatMessage(ctx, *anchor)
			if errors.Is(err, pgx.ErrNoRows) || (err == nil && m.SessionID != parent.ID) {
				return apperr.Invalid("anchor_message_id", "not a message of this chat")
			}
			if err != nil {
				return err
			}
			if m.Role == "system" {
				return apperr.Invalid("anchor_message_id", "a thread needs a message from you or a persona")
			}
			anchored = &m
		}
		asides, err := q.ListChatAsides(ctx, &parent.ID)
		if err != nil {
			return err
		}
		if n := countRunning(asides); n >= MaxLiveAsides {
			return apperr.Conflict("%d asides are still answering; wait for one to finish", n)
		}
		sel, err := s.ChatCatalog().Resolve(ctx, q, ws,
			chatmodels.Selection{Harness: parent.Harness, Model: parent.Model, Effort: parent.Effort},
			chatmodels.Selection{Harness: in.Harness, Model: in.Model, Effort: in.Effort},
		)
		if err != nil {
			return err
		}

		var preamble, title string
		if in.SecondOpinion {
			var reviews []store.ChatCodeReview
			reviews, err = loadSecondOpinionReviews(ctx, q, parent, in.Repository)
			if err != nil {
				return err
			}
			if anchor == nil && (parent.State != "running" || parent.CurrentRunID == nil) {
				recent, err := q.PageChatMessages(ctx, store.PageChatMessagesParams{
					SessionID:   parent.ID,
					NewestFirst: true,
					RowLimit:    20,
				})
				if err != nil {
					return err
				}
				if pick := pickSecondOpinionAnchor(recent); pick != nil {
					anchored = pick
					anchor = &pick.ID
				} else if len(reviews) == 0 {
					return apperr.Conflict("nothing to review yet: send a message first")
				}
			}
			if question == "" {
				question = defaultSecondOpinionPrompt(anchored != nil, len(reviews) > 0)
			}
			preamble, err = secondOpinionPreamble(ctx, q, parent, anchored, reviews)
			if err != nil {
				return err
			}
			title = "Second opinion: " + firstLine(question, 70)
		} else {
			if anchor == nil && (parent.State != "running" || parent.CurrentRunID == nil) {
				return apperr.Conflict("nothing is running: send it as a message instead")
			}
			if anchored != nil {
				preamble, err = threadPreamble(ctx, q, parent, *anchored)
			} else {
				preamble, err = asidePreamble(ctx, q, parent)
			}
			if err != nil {
				return err
			}
			title = asideTitle(anchored != nil) + firstLine(question, 70)
		}

		p, err := chatProject(ctx, q, parent)
		if err != nil {
			return err
		}
		// No repository and no connectors; the persona answering the parent
		// answers the aside. Temporary carries over, so a temporary chat's
		// asides don't reach memory or past chats either.
		aside, err := s.startChat(ctx, q, ws, user, ChatInput{
			Project:      p.Key,
			Title:        title,
			PersonaID:    ChatSpeakerID(parent),
			Hidden:       true,
			Temporary:    parent.Temporary,
			NoRepo:       true,
			ConnectorIDs: []uuid.UUID{},
		})
		if err != nil {
			return err
		}
		// Apply the resolved harness/model/effort only to the child aside so the
		// parent chat's active session and warm prompt cache stay untouched.
		if aside, err = q.SetChatSelection(ctx, store.SetChatSelectionParams{
			ID:        aside.ID,
			Harness:   sel.Harness,
			Model:     sel.Model,
			Effort:    sel.Effort,
			AutoModel: false,
		}); err != nil {
			return err
		}
		if aside, err = q.SetChatParent(ctx, store.SetChatParentParams{
			ID:              aside.ID,
			ParentChatID:    &parent.ID,
			AnchorMessageID: anchor,
			SecondOpinion:   in.SecondOpinion,
		}); err != nil {
			return err
		}
		if aside, _, err = postChatMessage(ctx, q, s.ChatCatalog(), aside, ChatMessageInput{Body: question, preamble: preamble}, s.HandoffChars); err != nil {
			return err
		}
		// The parent's clients learn of the new aside from its chat.updated.
		if _, err = q.BumpChatRevision(ctx, parent.ID); err != nil {
			return err
		}
		out = aside
		return nil
	})
	return out, err
}

func asideTitle(thread bool) string {
	if thread {
		return "Thread: "
	}
	return "Aside: "
}

func defaultSecondOpinionPrompt(hasAnchor, hasDiff bool) string {
	switch {
	case hasAnchor:
		return "Give an independent second opinion on this reply (and any code changes): highlight blind spots, subtle bugs, edge cases, risks, or a cleaner approach."
	case hasDiff:
		return "Give an independent second opinion on the current branch diff and conversation: highlight subtle bugs, edge cases, regressions, or a cleaner approach."
	default:
		return "Give an independent second opinion on the approach so far: highlight blind spots, edge cases, risks, or a better direction."
	}
}

func pickSecondOpinionAnchor(recent []store.ChatMessage) *store.ChatMessage {
	var fallback *store.ChatMessage
	for i := range recent {
		switch recent[i].Role {
		case "assistant":
			cp := recent[i]
			return &cp
		case "user":
			if fallback == nil {
				cp := recent[i]
				fallback = &cp
			}
		}
	}
	return fallback
}

func loadSecondOpinionReviews(ctx context.Context, q *store.Queries, parent store.ChatSession, repository string) ([]store.ChatCodeReview, error) {
	reviews, err := q.ChatCodeReviews(ctx, parent.ID)
	if err != nil {
		return nil, err
	}
	repo := strings.TrimSpace(repository)
	if repo != "" {
		filtered := make([]store.ChatCodeReview, 0, 1)
		for _, r := range reviews {
			if r.RepoUrl == repo {
				filtered = append(filtered, r)
			}
		}
		if len(filtered) == 0 {
			return nil, apperr.Invalid("repository", "no code review for that repository")
		}
		return filtered, nil
	}
	if parent.RepoUrl != nil && len(reviews) > 1 {
		active := *parent.RepoUrl
		slices.SortStableFunc(reviews, func(a, b store.ChatCodeReview) int {
			switch {
			case a.RepoUrl == active && b.RepoUrl != active:
				return -1
			case a.RepoUrl != active && b.RepoUrl == active:
				return 1
			default:
				return 0
			}
		})
	}
	return reviews, nil
}

// loadAsideHistory fetches bounded parent conversation history and artifacts for
// aside/thread/second-opinion preambles. When skipSeq > 0, that message is
// omitted from the history slice and total so an anchored target message isn't
// duplicated before its dedicated block.
func loadAsideHistory(ctx context.Context, q *store.Queries, parentID uuid.UUID, skipSeq int64) ([]HandoffMessage, int, HandoffContext, error) {
	total, err := q.CountChatHistory(ctx, parentID)
	if err != nil {
		return nil, 0, HandoffContext{}, err
	}
	rows, err := q.ListRecentChatMessages(ctx, store.ListRecentChatMessagesParams{SessionID: parentID, RowLimit: handoffRows, MaxChars: handoffFetchChars})
	if err != nil {
		return nil, 0, HandoffContext{}, err
	}
	hist := make([]HandoffMessage, 0, len(rows))
	for _, r := range rows {
		if skipSeq > 0 && r.Seq == skipSeq {
			if total > 0 {
				total--
			}
			continue
		}
		hist = append(hist, HandoffMessage{Seq: r.Seq, Role: r.Role, Harness: deref(r.Harness), Model: deref(r.Model), Persona: r.PersonaName, Body: r.BodyMd})
	}
	hc, err := loadHandoffContext(ctx, q, parentID)
	if err != nil {
		return nil, 0, HandoffContext{}, err
	}
	return hist, int(total), hc, nil
}

// threadPreamble is what a thread's first turn is told ahead of the question:
// the parent's recent conversation, then the message the thread is about.
func threadPreamble(ctx context.Context, q *store.Queries, parent store.ChatSession, m store.ChatMessage) (string, error) {
	hist, total, hc, err := loadAsideHistory(ctx, q, parent.ID, 0)
	if err != nil {
		return "", err
	}
	who := "The person"
	if m.Role == "assistant" {
		who = "You"
	}
	about := fmt.Sprintf("---\nThe message this thread is about (%s wrote it, message %d of the conversation):\n\n%s\n\n", who, m.Seq, quote(clip(m.BodyMd, asideSnapshotRunes)))
	rendered := renderHandoff(hist, total, asideHistoryChars, hc, about+threadFooter, "")
	return strings.Replace(rendered, handoffLead, "You are answering a thread about one message of the conversation below.", 1), nil
}

func secondOpinionPreamble(ctx context.Context, q *store.Queries, parent store.ChatSession, anchored *store.ChatMessage, reviews []store.ChatCodeReview) (string, error) {
	var skipSeq int64
	if anchored != nil {
		skipSeq = anchored.Seq
	}
	hist, total, hc, err := loadAsideHistory(ctx, q, parent.ID, skipSeq)
	if err != nil {
		return "", err
	}
	var middle strings.Builder
	if anchored != nil {
		who := "The person"
		if anchored.Role == "assistant" {
			who = "The previous assistant reply"
		}
		fmt.Fprintf(&middle, "---\nReply under review (%s, message %d of the conversation):\n\n%s\n\n", who, anchored.Seq, quote(clip(anchored.BodyMd, asideSnapshotRunes)))
	} else if parent.State == "running" && parent.CurrentRunID != nil {
		snapshot, err := liveTurnSnapshot(ctx, q, *parent.CurrentRunID, time.Now())
		if err != nil {
			return "", err
		}
		middle.WriteString(snapshot)
	}
	if diff := formatSecondOpinionDiff(reviews, anchored); diff != "" {
		middle.WriteString(diff)
	}
	middle.WriteString(secondOpinionFooter)
	lead := fmt.Sprintf("You are giving an independent read-only second opinion alongside a conversation whose main session stays on %s (%s) so its prompt cache stays warm.", parent.Harness, parent.Model)
	rendered := renderHandoff(hist, total, asideHistoryChars, hc, middle.String(), "")
	return strings.Replace(rendered, handoffLead, lead, 1), nil
}

type diffCommit struct {
	SHA     string `json:"sha"`
	Subject string `json:"subject"`
}

type diffFileChange struct {
	Repository string  `json:"repository,omitempty"`
	Path       string  `json:"path"`
	OldPath    *string `json:"old_path,omitempty"`
	Status     string  `json:"status"`
	Additions  int     `json:"additions"`
	Deletions  int     `json:"deletions"`
	Binary     bool    `json:"binary"`
	Patch      *string `json:"patch,omitempty"`
	Truncated  bool    `json:"truncated"`
}

func formatSecondOpinionDiff(reviews []store.ChatCodeReview, anchored *store.ChatMessage) string {
	var b strings.Builder
	remaining := secondOpinionDiffRunes
	if len(reviews) > 0 {
		b.WriteString("---\nBranch diff snapshot (secret-redacted):\n\n")
		for _, r := range reviews {
			if remaining <= 0 {
				break
			}
			var hdr strings.Builder
			fmt.Fprintf(&hdr, "Repository: %s", r.RepoUrl)
			if r.Branch != nil && *r.Branch != "" {
				fmt.Fprintf(&hdr, " (branch %s)", *r.Branch)
			}
			if r.BaseSha != nil && r.HeadSha != nil && *r.BaseSha != "" && *r.HeadSha != "" {
				fmt.Fprintf(&hdr, " [%s..%s]", shortSHA(*r.BaseSha), shortSHA(*r.HeadSha))
			}
			if r.Dirty {
				hdr.WriteString(" [includes uncommitted changes]")
			}
			hdr.WriteByte('\n')
			writeBudgeted(&b, hdr.String(), &remaining)

			var commits []diffCommit
			if len(r.Commits) > 2 && json.Unmarshal(r.Commits, &commits) == nil && len(commits) > 0 {
				writeBudgeted(&b, "Commits:\n", &remaining)
				limit := min(len(commits), 15)
				for _, c := range commits[:limit] {
					writeBudgeted(&b, fmt.Sprintf("- %s %s\n", shortSHA(c.SHA), c.Subject), &remaining)
				}
				if len(commits) > limit {
					writeBudgeted(&b, fmt.Sprintf("- … (%d more commits)\n", len(commits)-limit), &remaining)
				}
			}

			var files []diffFileChange
			if len(r.Files) > 2 && json.Unmarshal(r.Files, &files) == nil && len(files) > 0 {
				appendDiffFiles(&b, files, &remaining)
			} else if len(commits) == 0 {
				writeBudgeted(&b, "No diff files recorded.\n", &remaining)
			}
			writeBudgeted(&b, "\n", &remaining)
		}
		return b.String()
	}
	if anchored != nil && len(anchored.CodeChanges) > 2 {
		var files []diffFileChange
		if json.Unmarshal(anchored.CodeChanges, &files) == nil && len(files) > 0 {
			b.WriteString("---\nCode changes in the reply under review (secret-redacted):\n\n")
			appendDiffFiles(&b, files, &remaining)
			b.WriteByte('\n')
		}
	}
	return b.String()
}

func appendDiffFiles(b *strings.Builder, files []diffFileChange, remaining *int) {
	omitted := 0
	for i, f := range files {
		if *remaining < 200 {
			omitted = len(files) - i
			break
		}
		var meta strings.Builder
		if f.Repository != "" {
			fmt.Fprintf(&meta, "[%s] ", f.Repository)
		}
		fmt.Fprintf(&meta, "%s %s (+%d/-%d)", f.Status, f.Path, f.Additions, f.Deletions)
		if f.OldPath != nil && *f.OldPath != "" {
			fmt.Fprintf(&meta, " (from %s)", *f.OldPath)
		}
		if f.Binary {
			meta.WriteString(" [binary]")
		}
		if f.Truncated {
			meta.WriteString(" [patch truncated]")
		}
		meta.WriteByte('\n')
		writeBudgeted(b, meta.String(), remaining)

		if !f.Binary && f.Patch != nil && *f.Patch != "" && *remaining > 80 {
			patch := clip(*f.Patch, max(*remaining-32, 64))
			writeBudgeted(b, "```diff\n"+patch+"\n```\n", remaining)
		}
	}
	if omitted > 0 {
		fmt.Fprintf(b, "… (%d more changed file(s) omitted to fit diff budget)\n", omitted)
	}
}

func writeBudgeted(b *strings.Builder, s string, remaining *int) {
	if *remaining <= 0 {
		return
	}
	n := utf8.RuneCountInString(s)
	if n > *remaining {
		s = clip(s, *remaining)
		n = *remaining
	}
	b.WriteString(s)
	*remaining -= n
}

func shortSHA(sha string) string {
	if len(sha) > 7 {
		return sha[:7]
	}
	return sha
}

func countRunning(asides []store.ChatSession) int {
	n := 0
	for _, a := range asides {
		if a.State == "running" {
			n++
		}
	}
	return n
}

// ListChatAsides is the chat's asides, oldest first.
func (s *Service) ListChatAsides(ctx context.Context, ws, user, id uuid.UUID) ([]store.ChatSession, error) {
	var out []store.ChatSession
	q := store.New(s.Pool)
	chat, err := readOwnChat(ctx, q, ws, user, id)
	if err != nil {
		return out, err
	}
	return q.ListChatAsides(ctx, &chat.ID)
}

// EndAside runs in the runner's transaction once an aside's turn has ended
// (the chat lock is held): it has answered, or was stopped, so its segment
// completes and the runner sweep removes its workspace.
func EndAside(ctx context.Context, q *store.Queries, chatID uuid.UUID) error {
	chat, err := q.LockChatSessionByID(ctx, chatID)
	if err != nil || chat.State == "running" || chat.CurrentRunID == nil {
		return err
	}
	run, err := q.LockRun(ctx, *chat.CurrentRunID)
	if err != nil {
		return err
	}
	if slices.Contains(Terminal, run.State) {
		return nil
	}
	outcome := "The aside answered."
	if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "completed", Outcome: &outcome}); err != nil {
		return err
	}
	if err = q.DropPendingTurns(ctx, run.ID); err != nil {
		return err
	}
	if err = q.ExpireRunApprovals(ctx, run.ID); err != nil {
		return err
	}
	if err = event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "chat_segment_ended", "reason": "aside_answered"}); err != nil {
		return err
	}
	return RecomputeAgentStatus(ctx, q, run.AgentID)
}

// asidePreamble is what an aside's turn is told ahead of the question: the
// parent's recent conversation, then the snapshot of its running reply.
func asidePreamble(ctx context.Context, q *store.Queries, parent store.ChatSession) (string, error) {
	hist, total, hc, err := loadAsideHistory(ctx, q, parent.ID, 0)
	if err != nil {
		return "", err
	}
	snapshot, err := liveTurnSnapshot(ctx, q, *parent.CurrentRunID, time.Now())
	if err != nil {
		return "", err
	}
	// The handoff's lead would say other models answered; here it's the same persona, still working.
	rendered := renderHandoff(hist, total, asideHistoryChars, hc, snapshot+asideFooter, "")
	return strings.Replace(rendered, handoffLead, "You are answering an aside in the conversation below, the one you are working on right now.", 1), nil
}

// liveTurnSnapshot describes the running reply on run so far, oldest first.
func liveTurnSnapshot(ctx context.Context, q *store.Queries, runID uuid.UUID, now time.Time) (string, error) {
	since, err := q.OpenChatTurnStart(ctx, runID)
	if errors.Is(err, pgx.ErrNoRows) {
		return "---\nYour reply in the main conversation is about to start; it hasn't written anything or used any tools yet.\n\n", nil
	}
	if err != nil {
		return "", err
	}
	rows, err := q.LiveTurnEvents(ctx, store.LiveTurnEventsParams{RunID: runID, At: since, RowLimit: asideEvents})
	if err != nil {
		return "", err
	}
	slices.Reverse(rows)
	return renderLiveTurn(rows, now.Sub(since)), nil
}

// renderLiveTurn is liveTurnSnapshot's text, from the reply's events oldest
// first. When it runs long, the oldest lines go first.
func renderLiveTurn(rows []store.LiveTurnEventsRow, elapsed time.Duration) string {
	var lines []string
	for _, r := range rows {
		var p struct {
			Text    string          `json:"text"`
			Tool    string          `json:"tool"`
			Input   json.RawMessage `json:"input"`
			Output  string          `json:"output"`
			IsError bool            `json:"is_error"`
		}
		if json.Unmarshal(r.Payload, &p) != nil {
			continue
		}
		switch r.Type {
		case "message":
			if t := strings.TrimSpace(p.Text); t != "" {
				lines = append(lines, "You wrote:\n"+quote(clip(t, asideTextRunes)))
			}
		case "tool_call":
			if p.Tool == "" {
				continue
			}
			line := "Called " + p.Tool
			if in := strings.TrimSpace(string(p.Input)); in != "" && in != "{}" && in != "null" {
				line += " " + head(in, asideInputRunes)
			}
			lines = append(lines, line)
		case "tool_result":
			out := strings.TrimSpace(p.Output)
			if out == "" {
				continue
			}
			label := "Result"
			if p.IsError {
				label = "Error"
			}
			lines = append(lines, label+":\n"+quote(clip(out, asideOutputRunes)))
		}
	}
	var b strings.Builder
	fmt.Fprintf(&b, "---\nYour reply in the main conversation is still running (for %s so far). What it has done, oldest first:\n\n", elapsed.Round(time.Second))
	if len(lines) == 0 {
		b.WriteString("Nothing yet: it hasn't written anything or used any tools.\n\n")
		return b.String()
	}
	size := 0
	keep := len(lines)
	for keep > 0 && size+len([]rune(lines[keep-1])) <= asideSnapshotRunes {
		keep--
		size += len([]rune(lines[keep])) + 2
	}
	if keep > 0 {
		fmt.Fprintf(&b, "(%d earlier steps left out)\n\n", keep)
	}
	b.WriteString(strings.Join(lines[keep:], "\n\n"))
	b.WriteString("\n\n")
	return b.String()
}

// head keeps the start of s within max runes.
func head(s string, max int) string {
	r := []rune(s)
	if len(r) <= max {
		return s
	}
	return string(r[:max-1]) + "…"
}
