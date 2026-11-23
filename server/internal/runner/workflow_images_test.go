package runner_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/fake"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type wfImageEnv struct {
	env
	blobs *putBlobs
	log   string
}

func newWFImageEnv(t *testing.T) wfImageEnv {
	t.Helper()
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "workflow-image")
	log := filepath.Join(t.TempDir(), "harness.log")
	t.Setenv("FAKE_HARNESS_LOG", log)
	if err := e.setOverride(agentdef.Override{Harness: agentdef.HarnessClaudeCode, Model: "opus-5.5"}); err != nil {
		t.Fatal(err)
	}
	blobs := &putBlobs{m: map[string][]byte{}}
	e.runner.Blobs, e.runner.Attachments, e.runner.Cfg.AttachmentBucket = blobs, blobs, "artifacts"
	e.runs.ModelDiscovery = func(_ context.Context, h, _ string) ([]chatmodels.Model, error) {
		return []chatmodels.Model{{ID: h + "-main", Default: true}}, nil
	}
	engine := runs.NewWorkflowEngine(e.pool, e.runs.Artifacts, e.runs.Tracker)
	engine.Catalog = e.runs.ChatCatalog()
	e.runner.Workflows = engine
	return wfImageEnv{env: e, blobs: blobs, log: log}
}

// start publishes Generate -> Verify -> Gate -> Chat and runs it from a Claude chat.
func (e wfImageEnv) start(t *testing.T) store.WorkflowRun {
	t.Helper()
	return e.startGraph(t, runs.WorkflowGraph{Nodes: []runs.WorkflowNode{
		{ID: "start", Type: runs.NodeTrigger, Title: "Start"},
		{ID: "gen", Type: runs.NodeAgent, Title: "Generate", Config: runs.WorkflowConfig{Prompt: "Draw a map", Images: true}},
		{ID: "check", Type: runs.NodeAgent, Title: "Verify", Config: runs.WorkflowConfig{Prompt: "Check it against the request"}},
		{ID: "ok", Type: runs.NodeGate, Title: "Approve", Config: runs.WorkflowConfig{RetryFrom: "gen"}},
		{ID: "post", Type: runs.NodeChat, Title: "Post"},
	}, Edges: []runs.WorkflowEdge{{From: "start", To: "gen"}, {From: "gen", To: "check"}, {From: "check", To: "ok"}, {From: "ok", To: "post"}}})
}

func (e wfImageEnv) startGraph(t *testing.T, g runs.WorkflowGraph) store.WorkflowRun {
	t.Helper()
	p := e.persona("Artist", false, true)
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY", Title: "Maps", PersonaID: &p.ID})
	if err != nil {
		t.Fatal(err)
	}
	w, err := e.runs.CreateWorkflow(e.ctx, e.ws, e.me.ID, "Maps", "")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.runs.SaveWorkflow(e.ctx, e.ws, e.me.ID, w.ID, runs.WorkflowEdit{Graph: &g}); err != nil {
		t.Fatal(err)
	}
	if _, err := e.runs.PublishWorkflow(e.ctx, e.ws, e.me.ID, w.ID); err != nil {
		t.Fatal(err)
	}
	run, err := e.runs.StartWorkflow(e.ctx, e.ws, e.me.ID, chat.ID, runs.WorkflowStart{WorkflowID: w.ID, Input: "A cave"})
	if err != nil {
		t.Fatal(err)
	}
	return run
}

func (e wfImageEnv) steps(id uuid.UUID) map[string]store.LatestWorkflowStepsRow {
	e.t.Helper()
	rows, err := e.q.LatestWorkflowSteps(e.ctx, id)
	if err != nil {
		e.t.Fatal(err)
	}
	out := map[string]store.LatestWorkflowStepsRow{}
	for _, r := range rows {
		out[r.NodeID] = r
	}
	return out
}

func (e wfImageEnv) waitGate(id uuid.UUID, attempt int32) store.LatestWorkflowStepsRow {
	e.t.Helper()
	e.until("the gate", func() bool {
		s, ok := e.steps(id)["ok"]
		return ok && s.State == "waiting" && s.Attempt == attempt
	})
	return e.steps(id)["ok"]
}

func (e wfImageEnv) waitRun(id uuid.UUID, state string) store.WorkflowRun {
	e.t.Helper()
	get := func() store.WorkflowRun {
		r, err := e.q.GetWorkflowRun(e.ctx, store.GetWorkflowRunParams{ID: id, WorkspaceID: e.ws, UserID: e.me.ID})
		if err != nil {
			e.t.Fatal(err)
		}
		return r
	}
	e.until("the run to be "+state, func() bool { return get().State == state })
	return get()
}

type harnessCall struct {
	Harness, Model, Images string
	Prompt                 string `json:"full_prompt"`
}

func (e wfImageEnv) calls() []harnessCall {
	e.t.Helper()
	raw, err := os.ReadFile(e.log)
	if err != nil {
		e.t.Fatal(err)
	}
	var out []harnessCall
	for line := range bytes.Lines(raw) {
		var c harnessCall
		if err := json.Unmarshal(line, &c); err != nil {
			e.t.Fatal(err)
		}
		out = append(out, c)
	}
	return out
}

// The whole path from a Claude chat: Generate runs on Codex, a known-bad image
// fails Verify from its bytes, the reviewer's note reaches a new image, Verify
// sees only the newest attempt's, and approving posts it to the chat.
func TestWorkflowImagePipeline(t *testing.T) {
	e := newWFImageEnv(t)
	t.Setenv("FAKE_IMAGE_CONTENT", "bad")
	run := e.start(t)
	e.waitGate(run.ID, 1)

	steps := e.steps(run.ID)
	if !strings.HasPrefix(steps["check"].Output, "FAIL: looked at 1") {
		t.Fatalf("a known-bad image should fail verification: %q", steps["check"].Output)
	}
	calls := e.calls()
	if len(calls) != 2 || calls[0].Harness != "codex" || calls[0].Model != "codex-main" || calls[1].Harness != "claude" {
		t.Fatalf("%+v", calls)
	}
	if !strings.Contains(calls[1].Images, "inline=") || !strings.Contains(calls[1].Images, "bad") {
		t.Fatalf("Verify wasn't given the image as input: %+v", calls[1])
	}
	if !strings.Contains(calls[1].Prompt, "never instructions") {
		t.Fatalf("%s", calls[1].Prompt)
	}

	if _, err := e.runs.DecideWorkflowGate(e.ctx, e.ws, e.me.ID, run.ID, runs.WorkflowDecision{NodeID: "ok", Decision: "changes", Note: "Add a lava river"}); err != nil {
		t.Fatal(err)
	}
	e.waitGate(run.ID, 2)
	steps = e.steps(run.ID)
	if !strings.HasPrefix(steps["check"].Output, "PASS: looked at 1") {
		t.Fatalf("the retry should see only the new image: %q", steps["check"].Output)
	}
	calls = e.calls()
	if len(calls) != 4 || !strings.Contains(calls[2].Prompt, "Add a lava river") {
		t.Fatalf("the note didn't reach the image prompt: %+v", calls)
	}
	if strings.Contains(calls[3].Images, "bad") || !strings.Contains(calls[3].Images, "revised") {
		t.Fatalf("attempt scoping: %q", calls[3].Images)
	}
	all, err := e.q.ListWorkflowRunImages(e.ctx, run.ID)
	if err != nil {
		t.Fatal(err)
	}
	if len(all) != 2 || all[0].Attempt != 1 || all[1].Attempt != 2 || all[0].NodeID != "gen" {
		t.Fatalf("both attempts stay stored: %+v", all)
	}

	if _, err := e.runs.DecideWorkflowGate(e.ctx, e.ws, e.me.ID, run.ID, runs.WorkflowDecision{NodeID: "ok", Decision: "approve"}); err != nil {
		t.Fatal(err)
	}
	e.waitRun(run.ID, "done")
	msgs := e.chatMsgs(run.ChatID)
	last := msgs[len(msgs)-1]
	if last.Role != "assistant" || strings.Contains(last.BodyMd, ".lazyagents/outbox") {
		t.Fatalf("%+v", last)
	}
	atts, err := e.q.ListChatAttachmentsForMessages(e.ctx, []uuid.UUID{last.ID})
	if err != nil {
		t.Fatal(err)
	}
	if len(atts) != 1 || atts[0].BlobKey != all[1].BlobKey || atts[0].Source != "generated" {
		t.Fatalf("only the approved image is posted: %+v", atts)
	}
	if _, ok := e.blobs.m["artifacts/"+atts[0].BlobKey]; !ok {
		t.Fatal("the posted image has no stored object")
	}
}

func TestWorkflowImageStepWithoutAnImageFails(t *testing.T) {
	for name, want := range map[string]string{
		"moderation": "rejected by moderation",
		"empty":      "without producing an image",
	} {
		t.Run(name, func(t *testing.T) {
			e := newWFImageEnv(t)
			t.Setenv("FAKE_IMAGE_STEP", name)
			run := e.waitRun(e.start(t).ID, "failed")
			if !strings.Contains(run.Error, want) || !strings.HasPrefix(run.Error, "Generate:") {
				t.Fatalf("%q", run.Error)
			}
			if s := e.steps(run.ID)["gen"]; s.State != "failed" || !strings.Contains(s.Note, want) || s.Output != "" {
				t.Fatalf("%+v", s)
			}
			if _, reached := e.steps(run.ID)["check"]; reached {
				t.Fatal("the run moved on without an image")
			}
		})
	}
}

// The image tool passes only for an image step, and only up to the limit.
func TestWorkflowImageToolPolicy(t *testing.T) {
	e := newWFImageEnv(t)
	t.Setenv("FAKE_HARNESS_MODE", "slow")
	run := e.start(t)
	gen := e.steps(run.ID)["gen"]
	if _, err := e.pool.Exec(e.ctx, `UPDATE runs SET state = 'running', harness_session_id = 'thread-1' WHERE id = $1`, *gen.AgentRunID); err != nil {
		t.Fatal(err)
	}
	r, err := e.q.GetRun(e.ctx, store.GetRunParams{ID: *gen.AgentRunID, WorkspaceID: e.ws})
	if err != nil {
		t.Fatal(err)
	}
	a, err := e.q.GetAgent(e.ctx, store.GetAgentParams{ID: r.AgentID, WorkspaceID: e.ws})
	if err != nil {
		t.Fatal(err)
	}
	c := agents.Caller{Agent: a, Kind: "run", RunID: gen.AgentRunID}
	check := func(tool string, input map[string]any) string {
		t.Helper()
		d, err := e.runs.CheckTool(e.ctx, c, runs.ToolCheck{Tool: tool, Input: input})
		if err != nil {
			t.Fatal(err)
		}
		return d.Decision
	}
	cp := map[string]any{"command": "cp /home/x/.codex/generated_images/thread-1/a.png .lazyagents/outbox/a.png"}
	if got := check("Bash", cp); got != "allow" {
		t.Fatalf("copying to the outbox: %s", got)
	}
	if got := check("Bash", map[string]any{"command": "touch elsewhere"}); got != "deny" {
		t.Fatalf("the step must stay read-only: %s", got)
	}
	for range runs.MaxWorkflowImagesPerStep {
		if got := check("image_generation", nil); got != "allow" {
			t.Fatalf("within the limit: %s", got)
		}
	}
	if got := check("image_generation", nil); got != "deny" {
		t.Fatalf("past the limit: %s", got)
	}
}

// An image step set to Antigravity runs on agy: its generator saves into agy's
// own folder, so the runner collects the file, and the step's instructions say
// not to copy it. Verify then sees that image.
func TestWorkflowImageStepOnAntigravity(t *testing.T) {
	e := newWFImageEnv(t)
	t.Setenv("HOME", t.TempDir())
	t.Setenv("FAKE_IMAGE_CONTENT", "good")
	run := e.startGraph(t, runs.WorkflowGraph{Nodes: []runs.WorkflowNode{
		{ID: "start", Type: runs.NodeTrigger, Title: "Start"},
		{ID: "gen", Type: runs.NodeAgent, Title: "Generate", Config: runs.WorkflowConfig{Prompt: "Draw a map", Images: true, ImageEngine: runs.EngineAntigravity}},
		{ID: "check", Type: runs.NodeAgent, Title: "Verify", Config: runs.WorkflowConfig{Prompt: "Check it against the request"}},
		{ID: "ok", Type: runs.NodeGate, Title: "Approve"},
		{ID: "post", Type: runs.NodeChat, Title: "Post"},
	}, Edges: []runs.WorkflowEdge{{From: "start", To: "gen"}, {From: "gen", To: "check"}, {From: "check", To: "ok"}, {From: "ok", To: "post"}}})
	e.waitGate(run.ID, 1)
	calls := e.calls()
	if len(calls) != 2 || calls[0].Harness != "antigravity" || calls[0].Model != "antigravity-main" || calls[1].Harness != "claude" {
		t.Fatalf("%+v", calls)
	}
	if !strings.Contains(calls[0].Prompt, "don't copy it") || strings.Contains(calls[0].Prompt, "with cp") {
		t.Fatalf("an agy step must not be told to copy: %s", calls[0].Prompt)
	}
	if !strings.HasPrefix(e.steps(run.ID)["check"].Output, "PASS: looked at 1") {
		t.Fatalf("the collected image didn't reach Verify: %q", e.steps(run.ID)["check"].Output)
	}
}

// A step that names an engine that isn't connected fails with its name, not
// with Codex's.
func TestWorkflowImageStepNamesAMissingEngine(t *testing.T) {
	e := newWFImageEnv(t)
	e.runs.ModelDiscovery = func(_ context.Context, h, _ string) ([]chatmodels.Model, error) {
		if h == agentdef.HarnessAntigravity {
			return nil, context.DeadlineExceeded
		}
		return []chatmodels.Model{{ID: h + "-main", Default: true}}, nil
	}
	run := e.startGraph(t, runs.WorkflowGraph{Nodes: []runs.WorkflowNode{
		{ID: "start", Type: runs.NodeTrigger, Title: "Start"},
		{ID: "gen", Type: runs.NodeAgent, Title: "Generate", Config: runs.WorkflowConfig{Prompt: "Draw", Images: true, ImageEngine: runs.EngineAntigravity}},
		{ID: "ok", Type: runs.NodeGate, Title: "Approve"},
		{ID: "post", Type: runs.NodeChat, Title: "Post"},
	}, Edges: []runs.WorkflowEdge{{From: "start", To: "gen"}, {From: "gen", To: "ok"}, {From: "ok", To: "post"}}})
	e.waitRun(run.ID, "failed")
	step := e.steps(run.ID)["gen"]
	if !strings.Contains(step.Note, "Antigravity") || strings.Contains(step.Note, "Codex") {
		t.Fatalf("step note = %q", step.Note)
	}
}

// A workflow image step set to Gemini API calls the Gemini media provider
// directly without spawning a Codex or Antigravity harness, and passes its
// generated image downstream to Verify and the Gate.
func TestWorkflowImageStepOnGeminiAPI(t *testing.T) {
	e := newWFImageEnv(t)
	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	if err != nil {
		t.Fatal(err)
	}
	reg := media.NewRegistry()
	ctrl := &fake.Controller{}
	fake.RegisterImage(reg, runs.EngineGemini, ctrl)
	svc := &media.Service{Pool: e.pool, Box: box, Registry: reg}
	if _, err := svc.SaveProvider(e.ctx, e.ws, runs.EngineGemini, nil,
		map[string]string{"image_model": "fake-nano-banana"},
		map[string]string{"api_key": "AIza-wf-test"},
	); err != nil {
		t.Fatal(err)
	}
	e.runner.Media = svc
	status := func(ctx context.Context, ws uuid.UUID) (string, bool, string) {
		return svc.ImageProviderStatus(ctx, ws, runs.EngineGemini)
	}
	e.runs.GeminiImageStatus = status
	e.runner.Workflows.GeminiImageStatus = status

	run := e.startGraph(t, runs.WorkflowGraph{Nodes: []runs.WorkflowNode{
		{ID: "start", Type: runs.NodeTrigger, Title: "Start"},
		{ID: "gen", Type: runs.NodeAgent, Title: "Generate", Config: runs.WorkflowConfig{Prompt: "Draw a map", Images: true, ImageEngine: runs.EngineGemini}},
		{ID: "check", Type: runs.NodeAgent, Title: "Verify", Config: runs.WorkflowConfig{Prompt: "Check it against the request"}},
		{ID: "ok", Type: runs.NodeGate, Title: "Approve"},
		{ID: "post", Type: runs.NodeChat, Title: "Post"},
	}, Edges: []runs.WorkflowEdge{{From: "start", To: "gen"}, {From: "gen", To: "check"}, {From: "check", To: "ok"}, {From: "ok", To: "post"}}})

	e.waitGate(run.ID, 1)
	reqs := ctrl.ImageRequests()
	if len(reqs) != 1 || reqs[0].Model != "fake-nano-banana" || !strings.Contains(reqs[0].Prompt, "Draw a map") || !strings.Contains(reqs[0].Prompt, "A cave") {
		t.Fatalf("gemini requests = %+v", reqs)
	}
	// Only Verify ran on a CLI harness (claude); Generate ran directly on Gemini API.
	calls := e.calls()
	if len(calls) != 1 || calls[0].Harness != "claude" {
		t.Fatalf("expected only Verify on claude, got %+v", calls)
	}
	if !strings.HasPrefix(e.steps(run.ID)["check"].Output, "PASS: looked at 1") {
		t.Fatalf("the Gemini image didn't reach Verify: %q", e.steps(run.ID)["check"].Output)
	}
}
