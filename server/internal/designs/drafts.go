package designs

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/canvas"
	"github.com/liamphmurphy/vesper/server/internal/design"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// ---- a persona's turn as one draft ----
//
// The person sees what a persona made, not how: every design_patch in one chat
// turn goes into that turn's draft (status draft), which only the persona sees,
// through its own design_read, design_outline and design_render. When the turn
// ends, Publish turns the draft into its net changes against the design as it
// is then: one suggestion to review, or a version when the person lets the
// persona edit directly, or when the design holds nothing of the person's yet
// (untouched since it was made, from blank or a starter: a first draft).

// StatusDraft is a turn's work in progress.
const StatusDraft = "draft"

// Working is the design as the persona sees it during turn: the current
// version with the turn's draft applied. Draft ops that no longer apply (the
// person removed their target meanwhile) are skipped, as review would.
func Working(ctx context.Context, q *store.Queries, canvasID uuid.UUID, turn *uuid.UUID, cur string) (string, error) {
	if turn == nil {
		return cur, nil
	}
	d, err := q.GetDesignDraft(ctx, store.GetDesignDraftParams{CanvasID: canvasID, TurnID: turn})
	if errors.Is(err, pgx.ErrNoRows) {
		return cur, nil
	} else if err != nil {
		return "", err
	}
	ops, err := design.DecodeOps(d.Ops)
	if err != nil {
		return "", err
	}
	body, _, err := design.ApplyEach(cur, ops)
	return body, err
}

// joinSummary adds a patch's summary to a draft's, once, within the limit.
func joinSummary(have, add string) string {
	if have == "" || have == add || strings.Contains("; "+have+"; ", "; "+add+"; ") {
		if have == "" {
			return add
		}
		return have
	}
	out := have + "; " + add
	if utf8.RuneCountInString(out) > maxSummary {
		return have
	}
	return out
}

// draft adds a patch to its turn's draft. The ops must apply on the working
// copy (the version plus the draft so far), all or none.
func (s *Service) draft(ctx context.Context, p Patch, summary string, raw []byte) (Proposed, error) {
	var out Proposed
	// A draft left by an earlier turn that ended without publishing comes first.
	if err := s.PublishSettled(ctx, &p.CanvasID, nil); err != nil {
		return out, err
	}
	err := s.canvases().Locked(ctx, p.ChatID, p.CanvasID, func(q *store.Queries, c store.ChatCanvas, cur store.ChatCanvasVersion) error {
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
		var have []design.Op
		existing, err := q.GetDesignDraft(ctx, store.GetDesignDraftParams{CanvasID: c.ID, TurnID: p.TurnID})
		found := err == nil
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return err
		}
		if found {
			if have, err = design.DecodeOps(existing.Ops); err != nil {
				return err
			}
		}
		working, _, err := design.ApplyEach(cur.Body, have)
		if err != nil {
			return err
		}
		var ops []design.Op
		if err := json.Unmarshal(raw, &ops); err != nil {
			return err
		}
		body, err := design.Apply(working, ops)
		if err != nil {
			return err
		}
		if body == working {
			return apperr.Invalid("ops", "these ops change nothing")
		}
		if err := json.Unmarshal(raw, &ops); err != nil {
			return err
		}
		all, err := json.Marshal(append(have, ops...))
		if err != nil {
			return err
		}
		if found {
			out.Proposal, err = q.UpdateDesignDraft(ctx, store.UpdateDesignDraftParams{ID: existing.ID, Ops: all, Summary: joinSummary(existing.Summary, summary)})
			return err
		}
		out.Proposal, err = q.CreateDesignProposal(ctx, store.CreateDesignProposalParams{CanvasID: c.ID, ChatID: &p.ChatID, RunID: p.RunID, TurnID: p.TurnID,
			AgentID: p.AgentID, BaseSeq: cur.Seq, Summary: summary, Ops: all, Status: StatusDraft})
		return err
	})
	return out, err
}

// PublishSettled publishes the drafts whose turn has ended, on one design or
// from one turn (nil for any). The runner calls it as a turn ends; reading a
// design calls it too, so a turn that ended any other way (failed, stopped,
// the runner died) still hands over its work.
func (s *Service) PublishSettled(ctx context.Context, canvasID, turnID *uuid.UUID) error {
	drafts, err := store.New(s.Pool).SettledDesignDrafts(ctx, store.SettledDesignDraftsParams{CanvasID: canvasID, TurnID: turnID})
	if err != nil {
		return err
	}
	for _, d := range drafts {
		if err := s.publish(ctx, d); err != nil {
			return err
		}
	}
	return nil
}

// whyOf names each net op's reason after the last draft op about the same
// page, layer or link, or the draft's summary.
func whyOf(ops []design.Op, summary string) func(id string) string {
	by := map[string]string{}
	for _, op := range ops {
		why, _ := op["why"].(string)
		if why == "" {
			continue
		}
		for _, id := range design.Creates(op) {
			by[id] = why
		}
		for _, k := range []string{"id", "node", "from"} {
			if id, ok := op[k].(string); ok {
				by[id] = why
			}
		}
	}
	return func(id string) string {
		if w, ok := by[id]; ok {
			return w
		}
		return summary
	}
}

func (s *Service) publish(ctx context.Context, d store.DesignProposal) error {
	chat := uuid.Nil
	if d.ChatID != nil {
		chat = *d.ChatID
	}
	err := s.canvases().Locked(ctx, chat, d.CanvasID, func(q *store.Queries, c store.ChatCanvas, cur store.ChatCanvasVersion) error {
		d, err := q.LockDesignDraft(ctx, d.ID)
		if errors.Is(err, pgx.ErrNoRows) {
			return nil // another reader published it first
		} else if err != nil {
			return err
		}
		ops, err := design.DecodeOps(d.Ops)
		if err != nil {
			return err
		}
		final, applied, err := design.ApplyEach(cur.Body, ops)
		if err != nil {
			return err
		}
		if final == cur.Body {
			return q.DeleteDesignDraft(ctx, d.ID)
		}
		net, err := design.Diff(cur.Body, final, whyOf(ops, d.Summary))
		if err != nil {
			// No exact net form (a page reorder, say): the steps that still apply.
			slog.Default().Info("design draft kept as its steps", "canvas", c.ID, "draft", d.ID, "err", err)
			net = net[:0]
			for i, op := range ops {
				if applied[i] {
					net = append(net, op)
				}
			}
		}
		raw, err := json.Marshal(net)
		if err != nil {
			return err
		}
		set, err := q.GetDesignSettings(ctx, c.ID)
		if err != nil {
			return err
		}
		only, err := q.DesignHasOnlyPersonaWork(ctx, c.ID)
		if err != nil {
			return err
		}
		in := store.PublishDesignDraftParams{ID: d.ID, Status: StatusPending, Ops: raw, BaseSeq: cur.Seq}
		if !set.PersonaPaused && (set.DirectEdit || only) {
			v, err := canvas.WriteVersion(ctx, q, c, cur, final, d.Summary, canvas.Actor{Type: "agent", ID: d.AgentID})
			if err != nil {
				return err
			}
			in.Status, in.ResultSeq = StatusApplied, &v.Seq
		}
		_, err = q.PublishDesignDraft(ctx, in)
		return err
	})
	if errors.Is(err, apperr.ErrNotFound) {
		// The design or its chat is gone; so is anything to publish onto.
		return nil
	}
	return err
}
