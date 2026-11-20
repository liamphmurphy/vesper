package runs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Brief limits, in runes.
const (
	briefDescriptionLimit = 4000
	briefOutcomeLimit     = 600
)

// RunBrief renders what Vesper knows about a ticket run as Markdown, so a fresh
// harness session can continue it without replaying history: the ticket, its
// acceptance criteria, the run's plan, the pull request and the delegations so
// far. It reads only the database and is deterministic for the same state.
func RunBrief(ctx context.Context, q *store.Queries, run store.Run) (string, error) {
	var b strings.Builder
	if run.TicketID != nil {
		t, err := q.GetTicketByID(ctx, *run.TicketID)
		if err != nil {
			return "", err
		}
		fmt.Fprintf(&b, "## Ticket %s: %s\n\n", t.Key, t.Title)
		if d := strings.TrimSpace(t.DescriptionMd); d != "" {
			b.WriteString(clipRunes(d, briefDescriptionLimit) + "\n\n")
		}
		criteria, err := q.ListCriteria(ctx, t.ID)
		if err != nil {
			return "", err
		}
		if len(criteria) > 0 {
			b.WriteString("## Acceptance criteria\n\n")
			for i, c := range criteria {
				mark := " "
				if c.Done {
					mark = "x"
				}
				fmt.Fprintf(&b, "%d. [%s] %s\n", i+1, mark, c.Text)
			}
			b.WriteString("\n")
		}
		if t.PrUrl != nil && *t.PrUrl != "" {
			b.WriteString("## Pull request\n\n" + *t.PrUrl + "\n\n")
		}
	}
	plan, err := q.ListPlan(ctx, run.ID)
	if err != nil {
		return "", err
	}
	if len(plan) > 0 {
		b.WriteString("## Plan\n\n")
		for i, s := range plan {
			line := fmt.Sprintf("%d. [%s] %s", i+1, s.State, s.Text)
			if s.State == "current" {
				line += "  <- current step"
			}
			b.WriteString(line + "\n")
			if s.State == "done" && s.Note != nil && strings.TrimSpace(*s.Note) != "" {
				b.WriteString("   Note: " + strings.ReplaceAll(strings.TrimSpace(*s.Note), "\n", "\n   ") + "\n")
			}
		}
		b.WriteString("\n")
	}
	children, err := q.ChildRuns(ctx, &run.ID)
	if err != nil {
		return "", err
	}
	if len(children) > 0 {
		b.WriteString("## Delegations so far\n\n")
		for _, child := range children {
			handle := child.AgentID.String()
			if a, err := q.GetAgent(ctx, store.GetAgentParams{ID: child.AgentID, WorkspaceID: child.WorkspaceID}); err == nil {
				handle = a.Handle
			}
			verdict, err := q.RunVerdict(ctx, child.ID)
			if err != nil && !errors.Is(err, pgx.ErrNoRows) {
				return "", err
			}
			fmt.Fprintf(&b, "- @%s (run %s): %s", handle, ShortRunID(child.ID), child.State)
			if verdict != "" {
				b.WriteString(", verdict " + verdict)
			}
			var k Checks
			if len(child.Checks) > 0 && json.Unmarshal(child.Checks, &k) == nil {
				if k.Passed {
					b.WriteString(", checks passed")
				} else {
					b.WriteString(", checks failed")
				}
				if k.Merged {
					b.WriteString(", branch merged")
				} else if k.Branch != "" {
					b.WriteString(", branch " + k.Branch + " not merged")
				}
			}
			b.WriteString("\n")
			if child.Outcome != nil && strings.TrimSpace(*child.Outcome) != "" {
				b.WriteString("  Outcome: " + clipRunes(strings.TrimSpace(*child.Outcome), briefOutcomeLimit) + "\n")
			}
		}
		b.WriteString("\n")
	}
	b.WriteString("The ticket is already claimed and the plan already posted: don't call claim_ticket or post_plan again. " +
		"Continue from the current step. The code in the checkout is the source of truth where it differs from this summary.\n")
	return b.String(), nil
}
