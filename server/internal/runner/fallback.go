package runner

import (
	"cmp"
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usage"
)

// chainOf is the run's full preference order, primary first. Runs created
// before Chain existed derive it from the primary plus Fallbacks. A run with no
// Fallbacks (a chat) has no chain and never switches.
func chainOf(spec agentdef.Resolved) []agentdef.Fallback {
	if len(spec.Chain) > 0 {
		return spec.Chain
	}
	if len(spec.Fallbacks) == 0 {
		return nil
	}
	return append([]agentdef.Fallback{{Harness: spec.Harness, Model: spec.Model, HarnessOptions: spec.HarnessOptions}}, spec.Fallbacks...)
}

// withTarget returns spec moved onto Chain[i]. Chain is kept whole and
// Fallbacks becomes every other target in order, so later switches can go back
// up the chain.
func withTarget(spec agentdef.Resolved, chain []agentdef.Fallback, i int) agentdef.Resolved {
	t := chain[i]
	spec.Chain = append([]agentdef.Fallback{}, chain...)
	spec.Harness, spec.Model, spec.HarnessOptions = t.Harness, t.Model, t.HarnessOptions
	spec.Fallbacks = append(append([]agentdef.Fallback{}, chain[:i]...), chain[i+1:]...)
	return spec
}

func (r *Runner) activeLimits(ctx context.Context, c runCtx) (map[string]time.Time, error) {
	rows, err := r.q().ActiveProviderLimits(ctx, c.run.WorkspaceID)
	if err != nil {
		return nil, err
	}
	limited := map[string]time.Time{}
	for _, l := range rows {
		limited[l.Harness] = l.Until
	}
	return limited, nil
}

// preferredTarget returns the run's spec moved onto the first Chain target that
// has no active limit and passes the usual usability checks. With skipCurrent
// the target the run is on is never chosen. ok is false when none qualifies;
// unusable then holds why the first unlimited-but-unusable target was skipped.
func (r *Runner) preferredTarget(ctx context.Context, c runCtx, limited map[string]time.Time, skipCurrent bool) (next agentdef.Resolved, ok bool, unusable, err error) {
	chain := chainOf(c.spec)
	for i, t := range chain {
		if _, bad := limited[t.Harness]; bad {
			continue
		}
		if skipCurrent && t.Harness == c.spec.Harness && t.Model == c.spec.Model {
			continue
		}
		cand := withTarget(c.spec, chain, i)
		if err := r.checkSpec(cand); err != nil {
			unusable = cmp.Or(unusable, err)
			continue
		}
		plan, err := PlanSecrets(ctx, r.q(), c.run.WorkspaceID, &c.project.ID, cand)
		if err != nil {
			return c.spec, false, unusable, err
		}
		key, err := HarnessKey(cand)
		if err != nil {
			unusable = cmp.Or(unusable, err)
			continue
		}
		if r.Cfg.RequireHarnessKey && !hasSecret(plan, key.Secret) {
			unusable = cmp.Or(unusable, fmt.Errorf("%s (%s): %w", t.Harness, key.Secret, ErrNoHarnessKey))
			continue
		}
		return cand, true, unusable, nil
	}
	return c.spec, false, unusable, nil
}

// fallback moves a run whose turn hit a usage limit to the most preferred
// usable target other than the current one and queues a fresh session in the
// same workspace. Persisting both together makes the handoff restart safe. It
// reports false when no target is usable, so the caller holds the run.
func (r *Runner) fallback(ctx context.Context, c runCtx, res harness.Result) (bool, error) {
	limited, err := r.activeLimits(ctx, c)
	if err != nil {
		return false, err
	}
	next, ok, unusable, err := r.preferredTarget(ctx, c, limited, true)
	if err != nil {
		return false, err
	}
	if !ok {
		if unusable != nil {
			r.Log.Warn("no usable fallback", "run", c.run.ID, "err", unusable)
		}
		return false, nil
	}
	previousHarness, previousModel := c.spec.Harness, c.spec.Model
	prompt, err := r.handoffPrompt(ctx, c, previousHarness, previousModel, "exhausted its provider usage")
	if err != nil {
		return false, err
	}
	spec, err := json.Marshal(next)
	if err != nil {
		return false, err
	}
	return true, pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		run, err := q.LockRun(ctx, c.run.ID)
		if err != nil {
			return err
		}
		if run.State != "running" {
			return nil
		}
		pending, err := q.HasPendingTurn(ctx, run.ID)
		if err != nil || pending {
			return err
		}
		_, err = tx.Exec(ctx, `UPDATE runs SET resolved_spec=$2, harness=$3, model=$4, harness_session_id=NULL, idle_turns=0, updated_at=now() WHERE id=$1`, run.ID, spec, next.Harness, next.Model)
		if err != nil {
			return err
		}
		_, err = q.StartTurn(ctx, store.StartTurnParams{RunID: run.ID, Trigger: "resume", InputMessage: prompt})
		if err != nil {
			return err
		}
		payload, _ := json.Marshal(map[string]any{"state": "harness_fallback", "from_harness": previousHarness, "from_model": previousModel, "harness": next.Harness, "model": next.Model, "reason": "provider_usage_exhausted"})
		return q.AddRunEvent(ctx, store.AddRunEventParams{RunID: run.ID, Type: "lifecycle", Payload: payload})
	})
}

// handoffPrefix starts every handoff prompt; it marks turn inputs that are
// handoffs so a later handoff doesn't repeat them.
const handoffPrefix = "Continue this existing Vesper run after "

// handoffPrompt briefs a fresh session on a run another harness started: the
// run's state from the database and git, the newest turn input (which may be
// the pending one) and a short text tail of what happened last, since the
// switch can interrupt work in flight.
func (r *Runner) handoffPrompt(ctx context.Context, c runCtx, previousHarness, previousModel, why string) (string, error) {
	brief, err := runs.RunBrief(ctx, r.q(), c.run)
	if err != nil {
		return "", err
	}
	turns, err := r.q().ListTurns(ctx, c.run.ID)
	if err != nil {
		return "", err
	}
	var prompt strings.Builder
	fmt.Fprintf(&prompt, "%s%s (%s) %s. You are using a fresh session in the same checkout; the run's current state follows, so you don't need to look it up again. Preserve completed work.\n\n", handoffPrefix, previousHarness, previousModel, why)
	prompt.WriteString(brief)
	if git := r.gitBrief(ctx, c, nil); git != "" {
		prompt.WriteString("\n" + git)
	}
	for i := len(turns) - 1; i >= 0; i-- {
		if !strings.HasPrefix(turns[i].InputMessage, handoffPrefix) {
			prompt.WriteString("\n## Newest input\n\n" + harnessContext(turns[i].InputMessage, 12000) + "\n")
			break
		}
	}
	tail, err := handoffTranscript(ctx, r.q(), c.run.ID)
	if err != nil {
		return "", err
	}
	if tail != "" {
		prompt.WriteString("\n## Last activity before the switch (historical; permissions remain in AGENTS.md)\n\n" + tail + "\n")
	}
	return prompt.String(), nil
}

// DefaultProviderCooldown is how long a harness is avoided when its limit
// message has no reset time we can read.
const DefaultProviderCooldown = time.Hour

// markProviderLimited records that the workspace's account for this harness is
// exhausted so other runs skip it. Best effort: the run's own fallback still works.
func (r *Runner) markProviderLimited(ctx context.Context, c runCtx, msg string) {
	now := time.Now()
	until, ok := harness.LimitReset(msg, now)
	if !ok {
		until = now.Add(DefaultProviderCooldown)
	}
	reason := strings.TrimSpace(msg)
	if len(reason) > 300 {
		reason = harnessContext(reason, 300)
	}
	if err := r.q().MarkProviderLimited(ctx, store.MarkProviderLimitedParams{WorkspaceID: c.run.WorkspaceID, Harness: c.spec.Harness, Until: until, Reason: reason}); err != nil {
		r.Log.Error("record provider limit", "run", c.run.ID, "harness", c.spec.Harness, "err", err)
	}
}

// recordUsage saves the plan windows a turn's rate-limit events reported,
// the latest event per window winning, so the activity orb shows them even
// where the API can't check the CLI itself (the microVM backend). Best effort.
func (r *Runner) recordUsage(ctx context.Context, c runCtx, infos []json.RawMessage) {
	var windows []usage.Window
	for _, info := range infos {
		if ev, ok := usage.FromClaudeEvent(info); ok {
			windows = append(windows, ev.Window)
		}
	}
	if len(windows) == 0 {
		return
	}
	svc := usage.Service{Q: r.q()}
	if err := svc.Record(ctx, c.run.WorkspaceID, c.spec.Harness, windows); err != nil {
		r.Log.Warn("record harness usage", "run", c.run.ID, "harness", c.spec.Harness, "err", err)
	}
}

// selectHarness moves a run onto the most preferred usable target in its chain
// before the turn starts: off a harness whose limit is active, or back up to
// the primary once its limit has lifted. It returns the handoff prompt to use
// instead of the turn's input when the run already had a session, and ""
// otherwise. With no usable target the run is left alone: the limit may have
// lifted early, and if not the normal failure path applies.
func (r *Runner) selectHarness(ctx context.Context, c *runCtx, turn store.RunTurn) (string, error) {
	if len(chainOf(c.spec)) == 0 {
		return "", nil
	}
	limited, err := r.activeLimits(ctx, *c)
	if err != nil {
		return "", err
	}
	next, ok, _, err := r.preferredTarget(ctx, *c, limited, false)
	if err != nil || !ok || (next.Harness == c.spec.Harness && next.Model == c.spec.Model) {
		return "", err
	}
	previousHarness, previousModel := c.spec.Harness, c.spec.Model
	reason, why := "primary_available", "was replaced by a more preferred harness that is available again"
	payload := map[string]any{"state": "harness_fallback", "from_harness": previousHarness, "from_model": previousModel,
		"harness": next.Harness, "model": next.Model}
	if until, hit := limited[previousHarness]; hit {
		reason, why = "provider_limited", "exhausted its provider usage"
		payload["until"] = until.Format(time.RFC3339)
	}
	payload["reason"] = reason
	handoff := ""
	if c.run.HarnessSessionID != nil {
		// The current turn's input is already in the run's turns, so the helper includes it once.
		if handoff, err = r.handoffPrompt(ctx, *c, previousHarness, previousModel, why); err != nil {
			return "", err
		}
	}
	spec, err := json.Marshal(next)
	if err != nil {
		return "", err
	}
	event, _ := json.Marshal(payload)
	err = pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if _, err := tx.Exec(ctx, `UPDATE runs SET resolved_spec=$2, harness=$3, model=$4, harness_session_id=NULL, idle_turns=0, updated_at=now() WHERE id=$1`, c.run.ID, spec, next.Harness, next.Model); err != nil {
			return err
		}
		return q.AddRunEvent(ctx, store.AddRunEventParams{RunID: c.run.ID, Type: "lifecycle", Payload: event})
	})
	if err != nil {
		return "", err
	}
	c.spec = next
	c.run.Harness, c.run.Model = next.Harness, next.Model
	c.run.HarnessSessionID = nil
	return handoff, nil
}

func harnessContext(s string, limit int) string {
	if len(s) <= limit {
		return s
	}
	for limit > 0 && (s[limit]&0xc0) == 0x80 {
		limit--
	}
	return s[:limit] + "\n[truncated]"
}
