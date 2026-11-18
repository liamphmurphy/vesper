package httpapi

import (
	"context"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func wfNode(id, typ, title string, config map[string]any) map[string]any {
	return map[string]any{"id": id, "type": typ, "title": title, "config": config}
}

func (e *chatEnv) publishGraph(t *testing.T, nodes []map[string]any, edges [][2]string) string {
	t.Helper()
	list := make([]map[string]any, len(edges))
	for i, ed := range edges {
		list[i] = map[string]any{"from": ed[0], "to": ed[1]}
	}
	id := e.want("POST", "/workflows", map[string]any{"name": "Images"}, http.StatusCreated)["id"].(string)
	e.want("PATCH", "/workflows/"+id, map[string]any{"graph": map[string]any{"nodes": nodes, "edges": list}}, 200)
	e.want("POST", "/workflows/"+id+"/publish", nil, 200)
	return id
}

func (e *chatEnv) imagePersona(t *testing.T, name string, images bool) string {
	t.Helper()
	p, err := (&personas.Service{Pool: e.pool}).Create(t.Context(), personas.Owner{WorkspaceID: e.me.WorkspaceID, UserID: e.me.ID}, personas.NewInput{Name: name, Images: &images})
	if err != nil {
		t.Fatal(err)
	}
	return p.ID.String()
}

func imageStepGraph(config map[string]any) ([]map[string]any, [][2]string) {
	config["prompt"], config["images"] = "Draw it", true
	return []map[string]any{wfNode("start", "trigger", "Start", map[string]any{}), wfNode("gen", "agent", "Generate", config), wfNode("post", "chat", "Post", map[string]any{})},
		[][2]string{{"start", "gen"}, {"gen", "post"}}
}

func TestWorkflowImageStepNeedsAPersonaThatCan(t *testing.T) {
	e := newChatEnv(t)
	wf := e.publishGraph(t, func() []map[string]any {
		n, _ := imageStepGraph(map[string]any{"persona_id": e.imagePersona(t, "Plain", false)})
		return n
	}(), [][2]string{{"start", "gen"}, {"gen", "post"}})
	chat := e.newChat(map[string]any{"persona_id": e.imagePersona(t, "Painter", true)})["id"].(string)
	run := e.want("POST", "/chats/"+chat+"/workflows", map[string]any{"workflow_id": wf, "input": "A cave"}, http.StatusCreated)
	if run["state"] != "failed" || !strings.Contains(run["error"].(string), "Plain can't generate images") {
		t.Fatalf("the node's persona decides: %v", run)
	}

	// With no persona on the node, the chat's persona decides.
	nodes, edges := imageStepGraph(map[string]any{})
	wf = e.publishGraph(t, nodes, edges)
	chat = e.newChat(map[string]any{"persona_id": e.imagePersona(t, "Plain too", false)})["id"].(string)
	run = e.want("POST", "/chats/"+chat+"/workflows", map[string]any{"workflow_id": wf, "input": "A cave"}, http.StatusCreated)
	if run["state"] != "failed" || !strings.Contains(run["error"].(string), "Plain too can't generate images") {
		t.Fatalf("%v", run)
	}
}

func TestWorkflowImageStepFailsClearlyWithoutCodex(t *testing.T) {
	e := newChatEnvWith(t, func(s *runs.Service) {
		s.ModelDiscovery = func(ctx context.Context, h, key string) ([]chatmodels.Model, error) {
			if h == "codex" || h == "antigravity" {
				return nil, context.DeadlineExceeded
			}
			return testChatModels(ctx, h, key)
		}
	})
	nodes, edges := imageStepGraph(map[string]any{})
	wf := e.publishGraph(t, nodes, edges)
	chat := e.newChat(map[string]any{"persona_id": e.imagePersona(t, "Painter", true), "harness": "claude-code", "model": "opus-5.5"})["id"].(string)
	run := e.want("POST", "/chats/"+chat+"/workflows", map[string]any{"workflow_id": wf, "input": "A cave"}, http.StatusCreated)
	if run["state"] != "failed" || !strings.Contains(run["error"].(string), "Image steps need an image engine: no image engine is connected") {
		t.Fatalf("%v", run)
	}
}

func TestWorkflowImageSettingIsValidated(t *testing.T) {
	e := newChatEnv(t)
	id := e.want("POST", "/workflows", map[string]any{"name": "Bad"}, http.StatusCreated)["id"].(string)
	nodes, edges := imageStepGraph(map[string]any{"agent_handle": "atlas"})
	list := []map[string]any{{"from": edges[0][0], "to": edges[0][1]}, {"from": edges[1][0], "to": edges[1][1]}}
	e.want("PATCH", "/workflows/"+id, map[string]any{"graph": map[string]any{"nodes": nodes, "edges": list}}, 200)
	e.invalid("POST", "/workflows/"+id+"/publish", nil, "graph", "Image steps run as a persona")
}

// generatedStep starts an image step, stores an image against it, and finishes it.
func (e *chatEnv) generatedStep(t *testing.T, blobs *fakeBlobs, wf, chat string) (string, store.WorkflowStepImage) {
	t.Helper()
	run := e.want("POST", "/chats/"+chat+"/workflows", map[string]any{"workflow_id": wf, "input": "A cave"}, http.StatusCreated)
	id := run["id"].(string)
	agent := uuid.MustParse(e.wfStep(run, "gen")["agent_run_id"].(string))
	step, err := e.q.WorkflowStepForAgentRun(t.Context(), &agent)
	if err != nil {
		t.Fatal(err)
	}
	key := "images/" + uuid.NewString()
	body := []byte("\x89PNG\r\n\x1a\nmap")
	blobs.put(avatarBucket+"/"+key, body, "image/png")
	im, err := e.q.CreateWorkflowStepImage(t.Context(), store.CreateWorkflowStepImageParams{StepID: step.ID, RunID: step.RunID, Filename: "map.png", ContentType: "image/png", SizeBytes: int64(len(body)), BlobKey: key})
	if err != nil {
		t.Fatal(err)
	}
	if err := e.runs.SubmitWorkflowOutput(t.Context(), agent, "A map ![map](.lazyagents/outbox/map.png)", ""); err != nil {
		t.Fatal(err)
	}
	e.setRunState(t, agent, "completed")
	e.advanceWorkflows(t)
	return id, im
}

func newImageOutputsEnv(t *testing.T) (*chatEnv, *fakeBlobs) {
	t.Helper()
	fake := newFakeBlobs(t)
	store := fake.Store
	e := newChatEnvServer(t, func(s *runs.Service) { s.Artifacts.Blobs, s.Artifacts.Bucket = store, avatarBucket }, func(s *Server) { s.Blobs, s.ArtifactBucket = store, avatarBucket })
	return e, fake
}

func getStatus(t *testing.T, url string) int {
	t.Helper()
	res, err := http.Get(url)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	_, _ = io.Copy(io.Discard, res.Body)
	return res.StatusCode
}

func TestWorkflowImageReadsAreAuthorized(t *testing.T) {
	e, blobs := newImageOutputsEnv(t)
	nodes, edges := imageStepGraph(map[string]any{})
	nodes[2] = wfNode("post", "gate", "Hold", map[string]any{})
	nodes = append(nodes, wfNode("end", "chat", "Post", map[string]any{}))
	edges = append(edges, [2]string{"post", "end"})
	wf := e.publishGraph(t, nodes, edges)
	chat := e.newChat(map[string]any{"persona_id": e.imagePersona(t, "Painter", true)})["id"].(string)
	id, im := e.generatedStep(t, blobs, wf, chat)
	otherRun, _ := e.generatedStep(t, blobs, wf, chat)

	url := e.srv.URL + "/api/v1/workflow-runs/" + id + "/images/" + im.ID.String() + "/content"
	if code := getStatus(t, url); code != 200 {
		t.Fatalf("owner: %d", code)
	}
	if code := getStatus(t, e.srv.URL+"/api/v1/workflow-runs/"+otherRun+"/images/"+im.ID.String()+"/content"); code != 404 {
		t.Fatalf("an image through another run: %d", code)
	}
	other, err := e.q.CreateUser(t.Context(), store.CreateUserParams{WorkspaceID: e.me.WorkspaceID, Name: "Other", Email: "o@example.com", Initials: "OT"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(t.Context(), `UPDATE workflow_runs SET user_id = $2 WHERE id = $1`, id, other.ID); err != nil {
		t.Fatal(err)
	}
	if code := getStatus(t, url); code != 404 {
		t.Fatalf("someone else's run: %d", code)
	}
}

// A text-only Verify passes the image on; a gate shows it; the Library keeps
// it as an image; wiki and ticket outputs leave it out with no broken link.
func TestWorkflowImagesReachOutputs(t *testing.T) {
	e, blobs := newImageOutputsEnv(t)
	wf := e.publishGraph(t, []map[string]any{
		wfNode("start", "trigger", "Start", map[string]any{}),
		wfNode("gen", "agent", "Generate", map[string]any{"prompt": "Draw it", "images": true}),
		wfNode("check", "agent", "Verify", map[string]any{"prompt": "Check it"}),
		wfNode("ok", "gate", "Approve", map[string]any{}),
		wfNode("lib", "library", "Save", map[string]any{"title": "Cave map"}),
		wfNode("page", "wiki", "Page", map[string]any{"path": "Maps/Cave"}),
		wfNode("tick", "ticket", "File", map[string]any{"title": "Review the map"}),
	}, [][2]string{{"start", "gen"}, {"gen", "check"}, {"check", "ok"}, {"ok", "lib"}, {"ok", "page"}, {"ok", "tick"}})
	chat := e.newChat(map[string]any{"persona_id": e.imagePersona(t, "Painter", true)})["id"].(string)
	id, im := e.generatedStep(t, blobs, wf, chat)
	run := e.finishWFStep(t, id, "check", "PASS ![map](.lazyagents/outbox/map.png)")

	gate := e.wfStep(run, "ok")
	shown, _ := gate["images"].([]any)
	if gate["state"] != "waiting" || len(shown) != 1 || shown[0].(map[string]any)["id"] != im.ID.String() || shown[0].(map[string]any)["node_id"] != "gen" {
		t.Fatalf("the gate should carry the image through Verify: %v", gate)
	}
	e.want("POST", "/workflow-runs/"+id+"/gate", map[string]any{"node_id": "ok", "decision": "approve"}, 200)

	var items int
	if err := e.pool.QueryRow(t.Context(), `SELECT count(*) FROM library_items WHERE blob_key = $1 AND kind = 'image' AND title = 'Cave map'`, im.BlobKey).Scan(&items); err != nil {
		t.Fatal(err)
	}
	if items != 1 {
		t.Fatalf("library image items: %d", items)
	}
	var page, ticket string
	if err := e.pool.QueryRow(t.Context(), `SELECT coalesce(v.body_md, '') FROM artifacts a JOIN artifact_versions v ON v.id = a.current_version_id WHERE a.path = 'Maps/Cave'`).Scan(&page); err != nil {
		t.Fatal(err)
	}
	if err := e.pool.QueryRow(t.Context(), `SELECT description_md FROM tickets WHERE title = 'Review the map'`).Scan(&ticket); err != nil {
		t.Fatal(err)
	}
	for _, body := range []string{page, ticket} {
		if strings.Contains(body, "outbox") || !strings.Contains(body, "PASS") {
			t.Fatalf("%q", body)
		}
	}
}

func TestTextOnlyWorkflowIsUnchanged(t *testing.T) {
	e := newChatEnv(t)
	wf := e.publishedWorkflow(t)
	chat := e.newChat(nil)["id"].(string)
	run := e.want("POST", "/chats/"+chat+"/workflows", map[string]any{"workflow_id": wf, "input": "Compare queues"}, http.StatusCreated)
	agent := e.wfStep(run, "brief")["agent_run_id"].(string)
	var spec []byte
	var prompt string
	if err := e.pool.QueryRow(t.Context(), `SELECT r.resolved_spec, t.input_message FROM runs r JOIN run_turns t ON t.run_id = r.id WHERE r.id = $1`, agent).Scan(&spec, &prompt); err != nil {
		t.Fatal(err)
	}
	if containsBytes(spec, "image_generation") {
		t.Fatalf("%s", spec)
	}
	if !strings.HasSuffix(prompt, "Finish by calling submit_workflow_output.") || strings.Contains(prompt, "image") {
		t.Fatalf("%q", prompt)
	}
	if _, has := run["images"]; has {
		t.Fatalf("%v", run)
	}
	if _, has := e.wfStep(run, "brief")["images"]; has {
		t.Fatalf("%v", run)
	}
}
