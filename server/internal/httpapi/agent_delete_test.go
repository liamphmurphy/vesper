package httpapi

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"testing"
)

func TestDeleteAgentArchivesAndKeepsHistory(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()
	// A persona that takes tickets: its work record is the agent.
	p := e.want("POST", "/personas", map[string]any{"name": "Gone"}, http.StatusCreated)
	if p = e.want("PATCH", "/personas/"+p["id"].(string), map[string]any{"revision": p["revision"], "work": "tickets"}, http.StatusOK); p["handle"] != "gone" {
		t.Fatalf("persona work %v", p)
	}
	e.want("DELETE", "/agents/nobody", nil, http.StatusNotFound)

	// Open tickets block the delete.
	var tid string
	if err := e.pool.QueryRow(ctx, `UPDATE tickets SET assignee_agent_id=(SELECT id FROM agents WHERE handle='gone')
		WHERE id=(SELECT id FROM tickets WHERE status<>'done' ORDER BY created_at LIMIT 1) RETURNING id`).Scan(&tid); err != nil {
		t.Fatal(err)
	}
	out := e.want("DELETE", "/agents/gone", nil, http.StatusConflict)
	if !strings.Contains(out["message"].(string), "open ticket") {
		t.Fatalf("message = %v", out["message"])
	}

	// So does a run in progress, even once the ticket is finished.
	if _, err := e.pool.Exec(ctx, `UPDATE tickets SET status='done' WHERE id=$1`, tid); err != nil {
		t.Fatal(err)
	}
	var runID string
	if err := e.pool.QueryRow(ctx, `INSERT INTO runs (workspace_id, ticket_id, agent_id, mode, state, resolved_spec, harness, model, purpose)
		SELECT workspace_id, id, assignee_agent_id, 'managed', 'running', '{}', 'claude-code', 'm', 'ticket' FROM tickets WHERE id=$1 RETURNING id`, tid).Scan(&runID); err != nil {
		t.Fatal(err)
	}
	out = e.want("DELETE", "/agents/gone", nil, http.StatusConflict)
	if !strings.Contains(out["message"].(string), "in progress") {
		t.Fatalf("message = %v", out["message"])
	}
	if _, err := e.pool.Exec(ctx, `UPDATE runs SET state='completed' WHERE id=$1`, runID); err != nil {
		t.Fatal(err)
	}

	e.want("DELETE", "/agents/gone", nil, http.StatusNoContent)
	e.want("GET", "/agents/gone", nil, http.StatusNotFound)
	e.want("DELETE", "/agents/gone", nil, http.StatusNotFound)
	boot := e.want("GET", "/bootstrap", nil, http.StatusOK)
	if slices.Contains(ids(boot["agents"], "handle"), "gone") {
		t.Fatalf("archived agent in bootstrap: %v", ids(boot["agents"], "handle"))
	}
	// Archived agents can't be assigned work, and history still names them.
	var agentID string
	if err := e.pool.QueryRow(ctx, `SELECT id FROM agents WHERE handle='gone'`).Scan(&agentID); err != nil {
		t.Fatal(err)
	}
	e.invalid("PATCH", "/tickets/"+e.otherTk, map[string]any{"assignee_agent_id": agentID}, "assignee_agent_id", "no longer works on tickets")
	var n int
	if err := e.pool.QueryRow(ctx, `SELECT count(*) FROM runs WHERE id=$1`, runID).Scan(&n); err != nil || n != 1 {
		t.Fatalf("run history lost: %d %v", n, err)
	}

	// The handle is free again.
	var taken bool
	if err := e.pool.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM agents WHERE handle='gone' AND archived_at IS NULL)`).Scan(&taken); err != nil || taken {
		t.Fatalf("handle still taken: %v %v", taken, err)
	}
}
