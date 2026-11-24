package harness

import (
	"encoding/json"
	"reflect"
	"regexp"
	"strconv"
	"strings"
	"sync"
)

// PlanStep is one step of a turn's checklist, in the one shape every harness's
// plan is turned into. Status is pending, in_progress, completed or failed.
type PlanStep struct {
	ID     string `json:"id"`
	Title  string `json:"title"`
	Status string `json:"status"`
}

// PlanToolName is Vesper's own plan tool, for harnesses that have none.
const PlanToolName = "set_plan"

const (
	planMaxSteps      = 50
	planMaxTitleRunes = 300
)

// planEvent is the lifecycle event the chat's checklist reads: always the
// whole plan, so a client never has to replay one harness's partial updates.
// An empty steps list clears the plan.
func planEvent(source string, steps []PlanStep) Event {
	if steps == nil {
		steps = []PlanStep{}
	}
	if len(steps) > planMaxSteps {
		steps = steps[:planMaxSteps]
	}
	return Event{"lifecycle", map[string]any{"state": "plan", "source": source, "steps": steps}}
}

// planStatus maps each harness's step status onto PlanStep's. ok is false for
// a step that left the plan (Claude's cancelled or deleted).
func planStatus(s string) (status string, ok bool) {
	switch s {
	case "completed", "complete", "done":
		return "completed", true
	case "in_progress", "inProgress", "active", "current":
		return "in_progress", true
	case "failed":
		return "failed", true
	case "cancelled", "canceled", "deleted":
		return "", false
	}
	return "pending", true
}

func planTitle(s string) string {
	s = strings.Join(strings.Fields(s), " ")
	if r := []rune(s); len(r) > planMaxTitleRunes {
		s = string(r[:planMaxTitleRunes])
	}
	return s
}

// TrackPlans wraps a turn's event sink so a plan written through a tool call
// also arrives as a plan event, whichever harness wrote it: Claude Code's
// TodoWrite, TaskCreate and TaskUpdate, and Vesper's set_plan (any harness).
// Codex reports its plan outside tool calls, and its parsers emit plan events
// themselves; those pass through here. Create one per turn: Claude's tasks are
// numbered by its session, and a task this turn never saw created is skipped.
func TrackPlans(emit func(Event)) func(Event) {
	t := &planTracker{emit: emit, pending: map[string]planCall{}}
	return t.observe
}

type planCall struct {
	tool  string
	input json.RawMessage
}

type planTracker struct {
	// Sessions emit from their one read loop today; the lock keeps the task
	// list sound should another goroutine ever emit too.
	mu      sync.Mutex
	emit    func(Event)
	pending map[string]planCall // tool call id → a plan call awaiting its result
	tasks   []PlanStep          // Claude Code's task list, from TaskCreate/TaskUpdate
	last    []PlanStep          // the plan last emitted, to drop repeats
	sent    bool
}

func (t *planTracker) observe(e Event) {
	t.mu.Lock()
	defer t.mu.Unlock()
	if e.Type == "lifecycle" && e.Payload["state"] == "plan" {
		steps, _ := e.Payload["steps"].([]PlanStep)
		if t.repeat(steps) {
			return
		}
	}
	t.emit(e)
	if e.Payload["subagent"] == true { // a sub agent's plan isn't the turn's
		return
	}
	id, _ := e.Payload["id"].(string)
	tool, _ := e.Payload["tool"].(string)
	switch e.Type {
	case "tool_call":
		tool = planToolOf(tool)
		if tool == "" || id == "" {
			return
		}
		raw, err := json.Marshal(e.Payload["input"])
		if err != nil {
			return
		}
		t.pending[id] = planCall{tool: tool, input: raw}
	case "tool_result":
		call, ok := t.pending[id]
		if !ok {
			return
		}
		delete(t.pending, id)
		// A refused or failed call changed nothing, set_plan's validation
		// errors included.
		if isErr, _ := e.Payload["is_error"].(bool); isErr {
			return
		}
		output, _ := e.Payload["output"].(string)
		if steps, ok := t.apply(call, output); ok && !t.repeat(steps) {
			t.emit(planEvent(call.tool, steps))
		}
	}
}

// repeat reports whether steps is the plan last emitted, and records it if not.
func (t *planTracker) repeat(steps []PlanStep) bool {
	if steps == nil {
		steps = []PlanStep{}
	}
	if t.sent && reflect.DeepEqual(steps, t.last) {
		return true
	}
	t.sent, t.last = true, append([]PlanStep(nil), steps...)
	return false
}

func planToolOf(tool string) string {
	tool = strings.TrimPrefix(tool, "mcp__"+lazyagentsServer+"__")
	switch tool {
	case "TodoWrite", "TaskCreate", "TaskUpdate", PlanToolName:
		return tool
	}
	return ""
}

var claudeTaskID = regexp.MustCompile(`#(\d+)`)

// apply returns the plan after a successful plan call; ok is false when the
// call doesn't change one this turn knows about.
func (t *planTracker) apply(call planCall, output string) ([]PlanStep, bool) {
	switch call.tool {
	case PlanToolName:
		var in SetPlanInput
		if json.Unmarshal(call.input, &in) != nil {
			return nil, false
		}
		steps := make([]PlanStep, 0, len(in.Steps))
		for _, s := range in.Steps {
			status, keep := planStatus(s.Status)
			if title := planTitle(s.Title); keep && title != "" {
				steps = append(steps, PlanStep{ID: strconv.Itoa(len(steps) + 1), Title: title, Status: status})
			}
		}
		return steps, true
	case "TodoWrite":
		var in struct {
			Todos []struct {
				Content string `json:"content"`
				Status  string `json:"status"`
			} `json:"todos"`
		}
		if json.Unmarshal(call.input, &in) != nil {
			return nil, false
		}
		steps := make([]PlanStep, 0, len(in.Todos))
		for _, td := range in.Todos {
			status, keep := planStatus(td.Status)
			if title := planTitle(td.Content); keep && title != "" {
				steps = append(steps, PlanStep{ID: strconv.Itoa(len(steps) + 1), Title: title, Status: status})
			}
		}
		return steps, true
	case "TaskCreate":
		var in struct {
			Subject string `json:"subject"`
		}
		if json.Unmarshal(call.input, &in) != nil || planTitle(in.Subject) == "" {
			return nil, false
		}
		// Claude Code numbers the task in its result: "Task #3 created …".
		id := strconv.Itoa(len(t.tasks) + 1)
		if m := claudeTaskID.FindStringSubmatch(output); m != nil {
			id = m[1]
		}
		t.tasks = append(t.tasks, PlanStep{ID: id, Title: planTitle(in.Subject), Status: "pending"})
		return append([]PlanStep(nil), t.tasks...), true
	case "TaskUpdate":
		var in struct {
			TaskID  string `json:"taskId"`
			Subject string `json:"subject"`
			Status  string `json:"status"`
		}
		if json.Unmarshal(call.input, &in) != nil {
			return nil, false
		}
		at := -1
		for i, s := range t.tasks {
			if s.ID == in.TaskID {
				at = i
			}
		}
		if at < 0 {
			return nil, false
		}
		if in.Status != "" {
			status, keep := planStatus(in.Status)
			if !keep {
				t.tasks = append(t.tasks[:at:at], t.tasks[at+1:]...)
				return append([]PlanStep(nil), t.tasks...), true
			}
			t.tasks[at].Status = status
		}
		if title := planTitle(in.Subject); title != "" {
			t.tasks[at].Title = title
		}
		return append([]PlanStep(nil), t.tasks...), true
	}
	return nil, false
}

// SetPlanInput is set_plan's input; the MCP tool validates the same shape.
type SetPlanInput struct {
	Steps []struct {
		Title  string `json:"title"`
		Status string `json:"status"`
	} `json:"steps"`
}

// codexPlan turns Codex's plan into PlanSteps. Its app-server reports each
// step's status; exec's todo_list only says whether a step is completed, so
// the first open step is taken as the one under way, as Codex works in order.
func codexPlan(items []codexPlanItem) []PlanStep {
	steps := make([]PlanStep, 0, len(items))
	open := false
	for _, it := range items {
		title := planTitle(it.Step + it.Text)
		if title == "" {
			continue
		}
		status, keep := planStatus(it.Status)
		if !keep {
			continue
		}
		if it.Status == "" {
			status = "pending"
			if it.Completed {
				status = "completed"
			} else if !open {
				status = "in_progress"
			}
		}
		if status == "in_progress" {
			open = true
		}
		steps = append(steps, PlanStep{ID: strconv.Itoa(len(steps) + 1), Title: title, Status: status})
	}
	return steps
}

// codexPlanItem is a step of exec's todo_list item ({text, completed}) or of
// the app-server's turn/plan/updated ({step, status}).
type codexPlanItem struct {
	Text      string `json:"text"`
	Completed bool   `json:"completed"`
	Step      string `json:"step"`
	Status    string `json:"status"`
}
