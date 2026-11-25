package runs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// requireMockup refuses to finish implementation while the ticket's mockup
// gate is open. Delegated runs report to their parent and are not gated.
func requireMockup(ctx context.Context, q *store.Queries, run store.Run, t store.Ticket) error {
	if run.ParentRunID != nil {
		return nil
	}
	g, err := artifacts.MockupGate(ctx, q, t)
	if err != nil {
		return err
	}
	if !g.Unblocked() {
		return apperr.Conflict("%s needs a person-approved UI mockup first; draft one with create_mockup", t.Key)
	}
	return nil
}

// MockupOutcome is what create_mockup returns to the agent.
type MockupOutcome struct {
	Artifact store.Artifact
	Version  store.ArtifactVersion
	Waiting  bool // the run now waits for a person's review
	ChildRun bool // a delegated run: the main agent owns the review
}

// CreateMockup drafts a mockup (or a new version of one) for the run's ticket.
// When the ticket's gate is required the run waits until a person reviews it.
func (s *Service) CreateMockup(ctx context.Context, c Caller, key, title, svg, note string, mockupID *uuid.UUID) (MockupOutcome, error) {
	var out MockupOutcome
	by := artifacts.Actor{Type: "agent", ID: c.Agent.ID}
	err := s.tx(ctx, func(q *store.Queries) error {
		run, t, err := s.running(ctx, q, c, key)
		if err != nil {
			return err
		}
		ws := run.WorkspaceID
		if mockupID != nil {
			g, err := artifacts.MockupGate(ctx, q, t)
			if err != nil {
				return err
			}
			ok := false
			for _, m := range g.Mockups {
				ok = ok || m.ID == *mockupID
			}
			if !ok {
				return apperr.Invalid("mockup_id", "not a mockup attached to %s or its epic", t.Key)
			}
			a, err := q.LockArtifact(ctx, store.LockArtifactParams{ID: *mockupID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
			if err != nil {
				return err
			}
			r, err := artifacts.Mockup(svg)
			if err != nil {
				return err
			}
			out.Version, err = artifacts.AddVersionTx(ctx, q, a, r, by, artifacts.NewVersion{Note: note})
			if err != nil {
				return err
			}
			out.Artifact = a
		} else {
			p, err := q.GetProject(ctx, store.GetProjectParams{ID: t.ProjectID, WorkspaceID: ws})
			if err != nil {
				return err
			}
			a, err := s.Artifacts.CreateMockupTx(ctx, q, ws, by, p.Key, title, nil, svg) // attachment, not the epic, links an agent's mockup
			if err != nil {
				return err
			}
			if err := tracker.AttachArtifactInTx(ctx, q, ws, agentActor(c), t.Key, a.ID, "generated"); err != nil {
				return err
			}
			if out.Artifact, err = q.GetArtifact(ctx, store.GetArtifactParams{ID: a.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID}); err != nil {
				return err
			}
			if out.Version, err = q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *out.Artifact.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID}); err != nil {
				return err
			}
		}
		g, err := artifacts.MockupGate(ctx, q, t)
		if err != nil {
			return err
		}
		if !g.Required {
			return nil
		}
		if run.ParentRunID != nil {
			out.ChildRun = true
			return nil
		}
		out.Waiting = true
		wait := "mockup_review"
		if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "waiting", WaitReason: &wait}); err != nil {
			return err
		}
		if err := q.EndOpenTurn(ctx, store.EndOpenTurnParams{RunID: run.ID, ExitCode: ptr[int32](0)}); err != nil {
			return err
		}
		if err := event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "waiting", "reason": "mockup_review", "artifact_id": out.Artifact.ID, "version": out.Version.Label}); err != nil {
			return err
		}
		if err := tracker.Record(ctx, q, ws, t.ID, t.EpicID, agentActor(c), tracker.VerbMockupReviewRequested,
			map[string]any{"run_id": run.ID, "artifact_id": out.Artifact.ID, "title": out.Artifact.Title, "version": out.Version.Label}, nil); err != nil {
			return err
		}
		return RecomputeAgentStatus(ctx, q, c.Agent.ID)
	})
	return out, err
}

// ChatMockup is a mockup a persona drafts, or revises, in a chat with a person.
type ChatMockup struct {
	ChatID uuid.UUID
	// ProjectKey is a new mockup's project; empty takes the ticket's.
	ProjectKey string
	// TicketKey, when set, attaches the mockup to that ticket, so it can
	// satisfy the ticket's mockup gate once approved.
	TicketKey        string
	Title, SVG, Note string
	// MockupID revises a mockup made in this chat instead of creating one.
	MockupID *uuid.UUID
}

// CreateChatMockup saves a chat persona's mockup through the same profile
// normalization and validation as a run's. The mockup remembers its chat, so
// a review of it is told there (ReviewMockup). Nothing waits for the review:
// the chat shows the mockup as a card the person decides on in place.
func (s *Service) CreateChatMockup(ctx context.Context, c Caller, in ChatMockup) (MockupOutcome, error) {
	var out MockupOutcome
	by := artifacts.Actor{Type: "agent", ID: c.Agent.ID}
	ws := c.Agent.WorkspaceID
	viewer := pageview.From(ctx).UserID
	err := s.tx(ctx, func(q *store.Queries) error {
		projectKey := strings.ToUpper(strings.TrimSpace(in.ProjectKey))
		var a store.Artifact
		if in.MockupID != nil {
			var err error
			a, err = q.LockArtifact(ctx, store.LockArtifactParams{ID: *in.MockupID, WorkspaceID: ws, Viewer: viewer})
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return err
			}
			if err != nil || a.Type != "mockup" || a.ChatSessionID == nil || *a.ChatSessionID != in.ChatID {
				return apperr.Invalid("mockup_id", "not a mockup made in this chat")
			}
			if a.ProjectID != nil {
				p, err := q.GetProject(ctx, store.GetProjectParams{ID: *a.ProjectID, WorkspaceID: ws})
				if err != nil {
					return err
				}
				if projectKey != "" && projectKey != p.Key {
					return apperr.Invalid("project", "the mockup is in %s", p.Key)
				}
				projectKey = p.Key
			}
		}
		if in.TicketKey != "" {
			t, err := tracker.Get(ctx, q, ws, strings.ToUpper(strings.TrimSpace(in.TicketKey)))
			if err != nil {
				return err
			}
			p, err := q.GetProject(ctx, store.GetProjectParams{ID: t.ProjectID, WorkspaceID: ws})
			if err != nil {
				return err
			}
			if projectKey != "" && projectKey != p.Key {
				return apperr.Invalid("ticket", "%s is in %s, not %s", t.Key, p.Key, projectKey)
			}
			projectKey = p.Key
		}
		if in.MockupID != nil {
			r, err := artifacts.Mockup(in.SVG)
			if err != nil {
				return err
			}
			if out.Version, err = artifacts.AddVersionTx(ctx, q, a, r, by, artifacts.NewVersion{Note: in.Note}); err != nil {
				return err
			}
		} else {
			if projectKey == "" {
				return apperr.Invalid("project", "is required: this chat has no default project")
			}
			var err error
			if a, err = s.Artifacts.CreateMockupTx(ctx, q, ws, by, projectKey, in.Title, nil, in.SVG); err != nil {
				return err
			}
			if err := q.SetArtifactChat(ctx, store.SetArtifactChatParams{ChatID: &in.ChatID, ID: a.ID, WorkspaceID: ws}); err != nil {
				return err
			}
		}
		if in.TicketKey != "" {
			if err := tracker.AttachArtifactInTx(ctx, q, ws, agentActor(c), strings.ToUpper(strings.TrimSpace(in.TicketKey)), a.ID, "generated"); err != nil {
				return err
			}
		}
		var err error
		if out.Artifact, err = q.GetArtifact(ctx, store.GetArtifactParams{ID: a.ID, WorkspaceID: ws, Viewer: viewer}); err != nil {
			return err
		}
		if in.MockupID == nil {
			out.Version, err = q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *out.Artifact.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: ws, Viewer: viewer})
		}
		return err
	})
	return out, err
}

// mockupReviewNotice is what a chat is told when a person decides on a
// mockup a persona made there. It's a system message the person sees in the
// transcript; its artifact ref puts it in the next turn's prompt
// (runner.ChatTurnContext). It starts no turn, like design review feedback.
func mockupReviewNotice(ctx context.Context, q *store.Queries, ws, chatID uuid.UUID, a store.Artifact, label, decision, note string) error {
	if _, err := q.LockChatSession(ctx, store.LockChatSessionParams{ID: chatID, WorkspaceID: ws}); err != nil {
		return err
	}
	body := fmt.Sprintf("Mockup %q %s approved.", a.Title, label)
	if decision == artifacts.ReviewChangesRequested {
		body = fmt.Sprintf("Changes requested on mockup %q %s:\n%s", a.Title, label, note)
	} else if note != "" {
		body += "\nNote: " + note
	}
	refs, err := json.Marshal([]ChatContextRef{{Kind: "artifact", ID: &a.ID}})
	if err != nil {
		return err
	}
	_, err = q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chatID, Role: "system", BodyMd: body, ContextRefs: refs, Citations: []byte("[]")})
	return err
}

// ReviewMockup records a person's decision on a mockup's current version and
// wakes the runs it was gating. snap, when set, is the picture the decision
// was made on; it replaces any earlier snapshot of the version, and a review
// without one clears it, so a snapshot always belongs to the latest decision.
func (s *Service) ReviewMockup(ctx context.Context, ws, userID, artifactID, versionID uuid.UUID, decision, note string, pins []artifacts.ReviewPin, snap *artifacts.ReviewSnapshot) (store.Artifact, error) {
	note = strings.TrimSpace(note)
	pins, err := artifacts.CleanReviewPins(pins)
	if err != nil {
		return store.Artifact{}, err
	}
	pinsJSON, err := json.Marshal(pins)
	if err != nil {
		return store.Artifact{}, err
	}
	// The blob is written before the transaction (a store can't join it) and
	// removed again if the review doesn't commit.
	var snapKey, snapRenderer, snapSHA *string
	cleanup := func() {}
	if snap != nil {
		if s.Artifacts == nil {
			return store.Artifact{}, errors.New("runs: no artifact store for review snapshots")
		}
		key, undo, err := s.Artifacts.PutReviewSnapshot(ctx, ws, versionID, snap)
		if err != nil {
			return store.Artifact{}, err
		}
		snapKey, snapRenderer, snapSHA, cleanup = &key, &snap.Renderer, &snap.SourceSHA256, undo
	}
	var replacedKey string
	var out store.Artifact
	err = s.tx(ctx, func(q *store.Queries) error {
		a, err := q.LockArtifact(ctx, store.LockArtifactParams{ID: artifactID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		} else if err != nil {
			return err
		}
		if a.Type != "mockup" {
			return apperr.Invalid("artifact", "only mockups are reviewed")
		}
		if decision != artifacts.ReviewApproved && decision != artifacts.ReviewChangesRequested {
			return apperr.Invalid("decision", "must be approved or changes_requested")
		}
		if decision == artifacts.ReviewChangesRequested && note == "" {
			return apperr.Invalid("note", "say what should change")
		}
		if a.CurrentVersionID == nil || *a.CurrentVersionID != versionID {
			return apperr.Conflict("a newer version exists; review that one")
		}
		prev, err := q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: versionID, ArtifactID: a.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
		if err != nil {
			return err
		}
		if snap != nil && artifacts.SourceSHA256(deref(prev.BodyMd)) != snap.SourceSHA256 {
			return apperr.Invalid("snapshot", "is of a different version of this mockup")
		}
		replacedKey = deref(prev.ReviewSnapshotKey)
		note := artifacts.GatherReviewNote(note, pins)
		v, err := q.ReviewArtifactVersion(ctx, store.ReviewArtifactVersionParams{ID: versionID, ReviewState: &decision, ReviewedByUserID: &userID, ReviewNote: note, ReviewPins: pinsJSON,
			SnapshotKey: snapKey, SnapshotRenderer: snapRenderer, SnapshotSha256: snapSHA})
		if err != nil {
			return err
		}
		verb, msg := tracker.VerbMockupApproved, fmt.Sprintf("Mockup approved: %s %s. Implement to match it (read_artifact %s).", a.Title, v.Label, a.ID)
		if decision == artifacts.ReviewChangesRequested {
			sep := ". "
			if len(pins) > 0 {
				sep = "\n\n" // the note ends with the numbered pin list
			}
			verb, msg = tracker.VerbMockupChangesRequested, fmt.Sprintf("Changes requested on mockup %s %s: %s%sRevise it with create_mockup (mockup_id %s).", a.Title, v.Label, note, sep, a.ID)
		} else if note != "" {
			msg += "\nNote from the reviewer: " + note
		}
		if snap != nil {
			msg += "\nA PNG of exactly what the reviewer saw is beside the mockup's SVG in .lazyagents/context/."
		}
		tickets, err := q.ListTicketsGatedByMockup(ctx, store.ListTicketsGatedByMockupParams{WorkspaceID: ws, ArtifactID: a.ID, EpicID: a.EpicID})
		if err != nil {
			return err
		}
		for _, t := range tickets {
			if t.Attached {
				if err := tracker.Record(ctx, q, ws, t.ID, t.EpicID, tracker.UserActor(userID), verb,
					map[string]any{"artifact_id": a.ID, "title": a.Title, "version": v.Label, "note": note}, nil); err != nil {
					return err
				}
			}
			if decision == artifacts.ReviewChangesRequested && !t.Attached {
				continue // an epic-wide mockup's revision is the attached tickets' business
			}
			run, err := q.ActiveRunForTicket(ctx, &t.ID)
			if errors.Is(err, pgx.ErrNoRows) {
				continue
			} else if err != nil {
				return err
			}
			if run.State != "waiting" || deref(run.WaitReason) != "mockup_review" {
				continue
			}
			if run, err = q.LockRun(ctx, run.ID); err != nil {
				return err
			}
			if run.State != "waiting" || deref(run.WaitReason) != "mockup_review" {
				continue
			}
			// The turn trigger is "approval": a person's decision resumes the run.
			if err := resume(ctx, q, run, "approval", msg); err != nil {
				return err
			}
		}
		if a.ChatSessionID != nil {
			if err := mockupReviewNotice(ctx, q, ws, *a.ChatSessionID, a, v.Label, decision, note); err != nil {
				return err
			}
		}
		out, err = q.GetArtifact(ctx, store.GetArtifactParams{ID: a.ID, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
		return err
	})
	if err != nil {
		cleanup()
		return out, err
	}
	if replacedKey != "" && s.Artifacts != nil && (snapKey == nil || *snapKey != replacedKey) {
		s.Artifacts.DeleteReviewSnapshot(ctx, replacedKey)
	}
	return out, nil
}

// ReleaseMockupWaiters re-evaluates the mockup gate of waiting runs after a
// person removed what they waited for, and resumes those it no longer holds.
// A run on a ticket whose key is in keys, or whose epic is epicID, is a
// candidate. When detachedTitle is set a mockup was detached from the ticket
// instead of a requirement being cleared. It runs in its own transaction, just
// after the change that triggered it.
func (s *Service) ReleaseMockupWaiters(ctx context.Context, ws uuid.UUID, keys []string, epicID *uuid.UUID, detachedTitle string) error {
	inKeys := map[string]bool{}
	for _, k := range keys {
		inKeys[strings.ToUpper(strings.TrimSpace(k))] = true
	}
	return s.tx(ctx, func(q *store.Queries) error {
		waiting, err := q.ListMockupWaitingRuns(ctx, ws)
		if err != nil {
			return err
		}
		for _, run := range waiting {
			if run.TicketID == nil {
				continue
			}
			t, err := q.GetTicketByID(ctx, *run.TicketID)
			if err != nil {
				return err
			}
			if !inKeys[t.Key] && (epicID == nil || t.EpicID == nil || *t.EpicID != *epicID) {
				continue
			}
			g, err := artifacts.MockupGate(ctx, q, t)
			if err != nil {
				return err
			}
			var msg string
			switch {
			case g.Unblocked() && detachedTitle != "":
				msg = fmt.Sprintf("Mockup %s was detached from %s, but another approved mockup satisfies the gate; continue.", detachedTitle, t.Key)
			case g.Unblocked():
				msg = "The mockup requirement was removed; continue."
			case detachedTitle != "":
				msg = fmt.Sprintf("Mockup %s was detached from %s; draft a new one with create_mockup.", detachedTitle, t.Key)
			default:
				continue
			}
			if run, err = q.LockRun(ctx, run.ID); err != nil {
				return err
			}
			if run.State != "waiting" || deref(run.WaitReason) != "mockup_review" {
				continue
			}
			if err := resume(ctx, q, run, "approval", msg); err != nil {
				return err
			}
		}
		return nil
	})
}
