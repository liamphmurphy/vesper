package harness

import (
	"encoding/json"
	"reflect"
	"testing"
)

// plans feeds events through TrackPlans and returns the plan events it let out.
func plans(t *testing.T, events ...Event) [][]PlanStep {
	t.Helper()
	var out [][]PlanStep
	sink := TrackPlans(func(e Event) {
		if e.Type == "lifecycle" && e.Payload["state"] == "plan" {
			steps, ok := e.Payload["steps"].([]PlanStep)
			if !ok {
				t.Fatalf("plan steps are %T", e.Payload["steps"])
			}
			out = append(out, steps)
		}
	})
	for _, e := range events {
		sink(e)
	}
	return out
}

func call(id, tool string, input any) Event {
	return Event{"tool_call", map[string]any{"id": id, "tool": tool, "input": input}}
}

func result(id, output string, isErr bool) Event {
	return Event{"tool_result", map[string]any{"id": id, "is_error": isErr, "output": output}}
}

func steps(s ...string) []PlanStep { // title, status pairs, numbered from 1
	var out []PlanStep
	for i := 0; i < len(s); i += 2 {
		out = append(out, PlanStep{ID: itoaTest(len(out) + 1), Title: s[i], Status: s[i+1]})
	}
	return out
}

func itoaTest(n int) string { b, _ := json.Marshal(n); return string(b) }

func TestTrackPlansTodoWriteSendsTheWholeList(t *testing.T) {
	got := plans(t,
		call("t1", "TodoWrite", map[string]any{"todos": []any{
			map[string]any{"content": "Read the parser", "status": "in_progress"},
			map[string]any{"content": "Write tests", "status": "pending"},
			map[string]any{"content": "Dropped idea", "status": "cancelled"},
		}}),
		result("t1", "ok", false),
	)
	want := [][]PlanStep{steps("Read the parser", "in_progress", "Write tests", "pending")}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestTrackPlansAppliesClaudeTaskUpdatesToTheWholeList(t *testing.T) {
	got := plans(t,
		call("c1", "TaskCreate", map[string]any{"subject": "Check status"}),
		result("c1", "Task #5 created successfully: Check status", false),
		call("c2", "TaskCreate", map[string]any{"subject": "Count lines"}),
		result("c2", "Task #6 created successfully: Count lines", false),
		call("u1", "TaskUpdate", map[string]any{"taskId": "5", "status": "completed"}),
		result("u1", "Updated task #5 status", false),
		call("u2", "TaskUpdate", map[string]any{"taskId": "1", "status": "completed"}), // created in an earlier turn
		result("u2", "Updated task #1 status", false),
		call("u3", "TaskUpdate", map[string]any{"taskId": "6", "status": "deleted"}),
		result("u3", "Updated task #6 status", false),
	)
	want := [][]PlanStep{
		{{ID: "5", Title: "Check status", Status: "pending"}},
		{{ID: "5", Title: "Check status", Status: "pending"}, {ID: "6", Title: "Count lines", Status: "pending"}},
		{{ID: "5", Title: "Check status", Status: "completed"}, {ID: "6", Title: "Count lines", Status: "pending"}},
		{{ID: "5", Title: "Check status", Status: "completed"}},
	}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestTrackPlansReadsSetPlanFromEveryHarnessesName(t *testing.T) {
	in := map[string]any{"steps": []any{
		map[string]any{"title": "Plan", "status": "completed"},
		map[string]any{"title": "Build", "status": "in_progress"},
		map[string]any{"title": "Ship", "status": "failed"},
		map[string]any{"title": "  ", "status": "pending"},
	}}
	want := steps("Plan", "completed", "Build", "in_progress", "Ship", "failed")
	for _, name := range []string{"mcp__lazyagents__set_plan", "set_plan"} { // Claude Code; Codex and agy
		got := plans(t, call("s", name, in), result("s", "{}", false))
		if len(got) != 1 || !reflect.DeepEqual(got[0], want) {
			t.Errorf("%s: got %+v", name, got)
		}
	}
}

func TestTrackPlansIgnoresFailedSubagentAndOtherServersCalls(t *testing.T) {
	in := map[string]any{"steps": []any{map[string]any{"title": "A", "status": "pending"}}}
	sub := call("s2", "set_plan", in)
	sub.Payload["subagent"] = true
	subRes := result("s2", "{}", false)
	subRes.Payload["subagent"] = true
	got := plans(t,
		call("s1", "set_plan", in), result("s1", "steps: give 1–50 steps", true),
		sub, subRes,
		call("s3", "github.set_plan", in), result("s3", "{}", false),
	)
	if len(got) != 0 {
		t.Fatalf("want no plan, got %+v", got)
	}
}

func TestTrackPlansDropsARepeatedPlan(t *testing.T) {
	in := map[string]any{"steps": []any{map[string]any{"title": "A", "status": "pending"}}}
	got := plans(t,
		call("1", "set_plan", in), result("1", "{}", false),
		call("2", "set_plan", in), result("2", "{}", false),
		planEvent("codex", steps("A", "pending")),
		planEvent("codex", steps("A", "completed")),
	)
	if len(got) != 2 {
		t.Fatalf("want the first plan and the change, got %+v", got)
	}
}

func TestTrackPlansClearsThePlan(t *testing.T) {
	got := plans(t,
		call("1", "set_plan", map[string]any{"steps": []any{map[string]any{"title": "A"}}}), result("1", "{}", false),
		call("2", "set_plan", map[string]any{"steps": []any{}}), result("2", "{}", false),
	)
	if len(got) != 2 || len(got[1]) != 0 || got[1] == nil {
		t.Fatalf("want an empty plan last, got %+v", got)
	}
}

func TestCodexExecTodoListBecomesAPlan(t *testing.T) {
	p := Codex{}.NewParser("gpt-5")
	line := `{"type":"item.updated","item":{"id":"item_3","type":"todo_list","items":[{"text":"Read code","completed":true},{"text":"Edit","completed":false},{"text":"Test","completed":false}]}}`
	evs := p.Line([]byte(line))
	if len(evs) != 1 || evs[0].Payload["state"] != "plan" || evs[0].Payload["source"] != "codex" {
		t.Fatalf("got %+v", evs)
	}
	// exec only says what's completed: the first open step is under way.
	want := steps("Read code", "completed", "Edit", "in_progress", "Test", "pending")
	if got := evs[0].Payload["steps"]; !reflect.DeepEqual(got, want) {
		t.Fatalf("got %+v, want %+v", got, want)
	}
}

func TestCodexAppServerPlanUpdateBecomesAPlan(t *testing.T) {
	var got []Event
	s := &codexSessionState{emit: func(e Event) { got = append(got, e) }}
	params := `{"threadId":"t","turnId":"u","explanation":null,"plan":[{"step":"Read code","status":"completed"},{"step":"Edit","status":"inProgress"},{"step":"Test","status":"pending"}]}`
	if done := s.handleNotification("turn/plan/updated", json.RawMessage(params)); done {
		t.Fatal("a plan update doesn't end the turn")
	}
	want := steps("Read code", "completed", "Edit", "in_progress", "Test", "pending")
	if len(got) != 1 || !reflect.DeepEqual(got[0].Payload["steps"], want) {
		t.Fatalf("got %+v", got)
	}
}
