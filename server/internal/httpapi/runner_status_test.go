package httpapi

import (
	"context"
	"net/http"
	"sync/atomic"
	"testing"
)

// The Runs nav count leaves out Personal Assistant chat runs: they live in Chat.
func TestRunnerStatusLiveSkipsChatRuns(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `INSERT INTO runs (workspace_id, ticket_id, agent_id, mode, state, resolved_spec, harness, model, purpose)
		SELECT t.workspace_id, t.id, a.id, 'managed', s.state, '{}', 'claude-code', 'm', 'ticket'
		FROM (SELECT *, row_number() OVER (ORDER BY created_at) n FROM tickets) t
		JOIN unnest(ARRAY['running', 'starting', 'waiting', 'completed']) WITH ORDINALITY s(state, n) ON s.n = t.n,
		(SELECT id FROM agents WHERE kind <> 'assistant' LIMIT 1) a`); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `INSERT INTO runs (workspace_id, agent_id, mode, state, resolved_spec, harness, model, purpose)
		SELECT workspace_id, id, 'managed', 'running', '{}', 'claude-code', 'm', 'chat' FROM agents WHERE kind = 'assistant' LIMIT 1`); err != nil {
		t.Fatal(err)
	}
	out := e.want("GET", "/runner", nil, http.StatusOK)
	if out["live"] != float64(2) {
		t.Fatalf("live = %v, want 2 (running + starting ticket runs, no chat)", out["live"])
	}
}

// Host-folder workspaces: the toggle round-trips, each runner says whether it
// has a folder configured, and a run's or chat's folder shows only while the
// checkout exists.
func TestHostFolderWorkspaces(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()
	if _, err := e.pool.Exec(ctx, `INSERT INTO runners (id, backend, max_concurrent, host_workspaces_dir) VALUES
		('with-folder', 'docker', 2, '/Users/me/vesper/workspaces'), ('without', 'docker', 2, '')`); err != nil {
		t.Fatal(err)
	}
	out := e.want("GET", "/runner", nil, http.StatusOK)
	if out["host_folder_workspaces"] != false {
		t.Fatalf("default host_folder_workspaces = %v", out["host_folder_workspaces"])
	}
	dirs := map[string]any{}
	for _, r := range out["runners"].([]any) {
		r := r.(map[string]any)
		dirs[r["id"].(string)] = r["host_workspaces_dir"]
	}
	if dirs["with-folder"] != "/Users/me/vesper/workspaces" || dirs["without"] != nil {
		t.Fatalf("host_workspaces_dir by runner %v", dirs)
	}
	if out := e.want("PUT", "/runner/settings", map[string]any{"host_folder_workspaces": true}, http.StatusOK); out["host_folder_workspaces"] != true {
		t.Fatalf("after PUT %v", out["host_folder_workspaces"])
	}
	if out := e.want("GET", "/runner", nil, http.StatusOK); out["host_folder_workspaces"] != true {
		t.Fatalf("not saved: %v", out["host_folder_workspaces"])
	}

	chat := e.want("POST", "/chats", map[string]any{}, http.StatusCreated)
	var runID string
	if err := e.pool.QueryRow(ctx, `INSERT INTO runs (workspace_id, agent_id, mode, state, resolved_spec, harness, model, purpose, workspace_volume, workspace_host_path)
		SELECT workspace_id, id, 'managed', 'running', '{}', 'claude-code', 'm', 'chat', 'v', '/Users/me/vesper/workspaces/r'
		FROM agents WHERE kind = 'assistant' LIMIT 1 RETURNING id`).Scan(&runID); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `UPDATE chat_sessions SET current_run_id = $1 WHERE id = $2`, runID, chat["id"]); err != nil {
		t.Fatal(err)
	}
	runOf := func() map[string]any {
		return e.want("GET", "/runs/"+runID, nil, http.StatusOK)["run"].(map[string]any)
	}
	if got := runOf()["workspace_path"]; got != "/Users/me/vesper/workspaces/r" {
		t.Fatalf("run workspace_path = %v", got)
	}
	if got := e.want("GET", "/chats/"+chat["id"].(string), nil, http.StatusOK)["workspace_path"]; got != "/Users/me/vesper/workspaces/r" {
		t.Fatalf("chat workspace_path = %v", got)
	}
	// Once the workspace is removed, the stale path is not offered.
	if _, err := e.pool.Exec(ctx, `UPDATE runs SET workspace_volume = NULL WHERE id = $1`, runID); err != nil {
		t.Fatal(err)
	}
	if got, ok := runOf()["workspace_path"]; ok {
		t.Fatalf("removed run workspace_path = %v", got)
	}
	if got, ok := e.want("GET", "/chats/"+chat["id"].(string), nil, http.StatusOK)["workspace_path"]; ok {
		t.Fatalf("removed chat workspace_path = %v", got)
	}
}

func TestRunnerStatusReportsStartingUntilRunnerRegisters(t *testing.T) {
	var starting atomic.Bool
	starting.Store(true)
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.RunnerStarting = starting.Load
	})

	out := e.want("GET", "/runner", nil, http.StatusOK)
	if out["online"] != false || out["starting"] != true {
		t.Fatalf("starting status = %+v, want online=false starting=true", out)
	}
	dash := e.want("GET", "/dashboard", nil, http.StatusOK)["runner"].(map[string]any)
	if dash["online"] != false || dash["starting"] != true {
		t.Fatalf("dashboard starting runner = %+v, want online=false starting=true", dash)
	}

	// If startup exits without registering, starting drops and offline surfaces.
	starting.Store(false)
	out = e.want("GET", "/runner", nil, http.StatusOK)
	if out["online"] != false || out["starting"] != nil {
		t.Fatalf("failed-start status = %+v, want online=false starting omitted", out)
	}

	// Once a runner heartbeats, online wins even if the startup flag were still set.
	starting.Store(true)
	if _, err := e.pool.Exec(context.Background(), `INSERT INTO runners (id, backend, max_concurrent) VALUES ('app-runner', 'microvm', 4)`); err != nil {
		t.Fatal(err)
	}
	out = e.want("GET", "/runner", nil, http.StatusOK)
	if out["online"] != true || out["starting"] != nil {
		t.Fatalf("online status = %+v, want online=true starting omitted", out)
	}
}

func TestRunnerSettingsSubagentAndDelegationLimits(t *testing.T) {
	e := newChatEnv(t)

	out := e.want("GET", "/runner", nil, http.StatusOK)
	if out["host_folder_workspaces"] != false || out["max_concurrent_subagents"] != float64(3) || out["max_parallel_delegations"] != float64(3) {
		t.Fatalf("defaults = %+v", out)
	}

	out = e.want("PUT", "/runner/settings", map[string]any{"max_concurrent_subagents": 6}, http.StatusOK)
	if out["max_concurrent_subagents"] != float64(6) || out["max_parallel_delegations"] != float64(3) || out["host_folder_workspaces"] != false {
		t.Fatalf("after updating subagents = %+v", out)
	}

	out = e.want("PUT", "/runner/settings", map[string]any{"max_parallel_delegations": 5}, http.StatusOK)
	if out["max_concurrent_subagents"] != float64(6) || out["max_parallel_delegations"] != float64(5) || out["host_folder_workspaces"] != false {
		t.Fatalf("after updating delegations = %+v", out)
	}

	out = e.want("PUT", "/runner/settings", map[string]any{"host_folder_workspaces": true}, http.StatusOK)
	if out["host_folder_workspaces"] != true || out["max_concurrent_subagents"] != float64(6) || out["max_parallel_delegations"] != float64(5) {
		t.Fatalf("after updating host folders = %+v", out)
	}

	out = e.want("GET", "/runner", nil, http.StatusOK)
	if out["host_folder_workspaces"] != true || out["max_concurrent_subagents"] != float64(6) || out["max_parallel_delegations"] != float64(5) {
		t.Fatalf("persisted GET /runner = %+v", out)
	}

	e.invalid("PUT", "/runner/settings", map[string]any{"max_concurrent_subagents": 0}, "max_concurrent_subagents", "")
	e.invalid("PUT", "/runner/settings", map[string]any{"max_concurrent_subagents": 17}, "max_concurrent_subagents", "")
	e.invalid("PUT", "/runner/settings", map[string]any{"max_parallel_delegations": 0}, "max_parallel_delegations", "")
	e.invalid("PUT", "/runner/settings", map[string]any{"max_parallel_delegations": 9}, "max_parallel_delegations", "")
}

func TestRunnerSettingsSubagentTierRoutingAndRules(t *testing.T) {
	e := newChatEnv(t)

	out := e.want("GET", "/runner", nil, http.StatusOK)
	if out["subagent_tier_routing"] != true {
		t.Fatalf("default subagent_tier_routing = %v, want true", out["subagent_tier_routing"])
	}
	rules, ok := out["subagent_tier_models"].(map[string]any)
	if !ok || len(rules) != 0 {
		t.Fatalf("default subagent_tier_models = %#v, want empty map", out["subagent_tier_models"])
	}

	// Configure explicit Antigravity Carbon -> Neon -> Hydrogen ladder.
	out = e.want("PUT", "/runner/settings", map[string]any{
		"subagent_tier_models": map[string]any{
			"antigravity": map[string]any{
				"deep":     " gemini-4-carbon ",
				"standard": "gemini-4-neon",
				"fast":     "gemini-4-hydrogen",
			},
			"codex": map[string]any{},
		},
	}, http.StatusOK)
	savedRules := out["subagent_tier_models"].(map[string]any)
	if len(savedRules) != 1 {
		t.Fatalf("expected empty codex entry stripped, got %#v", savedRules)
	}
	agy := savedRules["antigravity"].(map[string]any)
	if agy["deep"] != "gemini-4-carbon" || agy["standard"] != "gemini-4-neon" || agy["fast"] != "gemini-4-hydrogen" {
		t.Fatalf("antigravity ladder = %#v", agy)
	}

	// Toggle routing off: saved ladder must remain intact when toggled back later.
	out = e.want("PUT", "/runner/settings", map[string]any{"subagent_tier_routing": false}, http.StatusOK)
	if out["subagent_tier_routing"] != false {
		t.Fatalf("subagent_tier_routing = %v, want false", out["subagent_tier_routing"])
	}
	if out["subagent_tier_models"].(map[string]any)["antigravity"].(map[string]any)["deep"] != "gemini-4-carbon" {
		t.Fatalf("toggling off wiped ladder: %#v", out["subagent_tier_models"])
	}

	// Updating another setting preserves both subagent_tier_routing and subagent_tier_models.
	out = e.want("PUT", "/runner/settings", map[string]any{"max_concurrent_subagents": 5}, http.StatusOK)
	if out["subagent_tier_routing"] != false || out["subagent_tier_models"].(map[string]any)["antigravity"] == nil {
		t.Fatalf("partial PUT clobbered tier settings: %#v", out)
	}

	// Clearing ladders with {} leaves empty map; unknown harness key is rejected cleanly.
	out = e.want("PUT", "/runner/settings", map[string]any{"subagent_tier_models": map[string]any{}}, http.StatusOK)
	if len(out["subagent_tier_models"].(map[string]any)) != 0 {
		t.Fatalf("expected cleared subagent_tier_models, got %#v", out["subagent_tier_models"])
	}
	e.invalid("PUT", "/runner/settings", map[string]any{
		"subagent_tier_models": map[string]any{"unknown-cli": map[string]any{"fast": "m"}},
	}, "subagent_tier_models", "")
}
