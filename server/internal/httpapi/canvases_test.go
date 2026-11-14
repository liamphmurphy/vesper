package httpapi

import (
	"bytes"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// canvasToken is a run token for a chat with a turn in progress.
func (e *chatEnv) canvasToken(chat uuid.UUID) string {
	e.t.Helper()
	ctx := e.t.Context()
	if _, err := e.runs.PostChatMessage(ctx, e.me.WorkspaceID, e.me.ID, chat, runs.ChatMessageInput{Body: "draft it"}); err != nil {
		e.t.Fatal(err)
	}
	c, err := e.q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat, WorkspaceID: e.me.WorkspaceID})
	if err != nil {
		e.t.Fatal(err)
	}
	token, _, err := agents.IssueToken(ctx, e.q, c.AgentID, "run", "chat", c.CurrentRunID, nil, nil)
	if err != nil {
		e.t.Fatal(err)
	}
	return token
}

func (e *chatEnv) tool(token, name string, args any) (int, map[string]any) {
	e.t.Helper()
	raw, _ := json.Marshal(args)
	req, _ := http.NewRequest("POST", e.srv.URL+"/api/v1/agent/tools/"+name, bytes.NewReader(raw))
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Content-Type", "application/json")
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	_ = json.NewDecoder(res.Body).Decode(&out)
	return res.StatusCode, out
}

func (e *chatEnv) toolInvalid(token, name string, args any, field string) {
	e.t.Helper()
	code, out := e.tool(token, name, args)
	if msg, _ := out["message"].(string); code != http.StatusUnprocessableEntity || !strings.HasPrefix(msg, field+":") {
		e.t.Fatalf("%s(%v) = %d %v, want 422 on %s", name, args, code, out, field)
	}
}

func TestTextCanvasToolsAndReadAPI(t *testing.T) {
	e := newChatEnv(t)
	chat := uuid.MustParse(e.newChat(nil)["id"].(string))
	token := e.canvasToken(chat)

	code, out := e.tool(token, "canvas_create", map[string]any{"kind": "text", "title": " Retention\n policy ", "body": "Archive after 30 days.", "note": "First draft"})
	if code != 200 || out["version"] != float64(1) {
		t.Fatalf("create = %d %v", code, out)
	}
	id := out["canvas_id"].(string)
	base := "/chats/" + chat.String() + "/canvases"

	patch := func(version int, ops ...map[string]any) (int, map[string]any) {
		return e.tool(token, "canvas_patch", map[string]any{"canvas_id": id, "base_version": version, "ops": ops, "note": "Longer window"})
	}
	if code, out = patch(1, map[string]any{"find": "30", "replace": "60"}); code != 200 || out["version"] != float64(2) {
		t.Fatalf("patch = %d %v", code, out)
	}
	if code, out = patch(1, map[string]any{"find": "60", "replace": "90"}); code != 409 || !strings.Contains(out["message"].(string), "version 2") {
		t.Fatalf("stale patch = %d %v", code, out)
	}
	if code, out = patch(2, map[string]any{"find": "missing", "replace": "x"}); code != 422 {
		t.Fatalf("bad find = %d %v", code, out)
	}
	if code, out = patch(2, map[string]any{"find": "60", "replace": "60"}); code != 422 {
		t.Fatalf("no-op = %d %v", code, out)
	}

	if code, out = e.tool(token, "canvas_read", map[string]any{"canvas_id": id, "version": 1}); code != 200 || out["body"] != "Archive after 30 days." {
		t.Fatalf("read v1 = %d %v", code, out)
	}
	if code, out = e.tool(token, "canvas_list", map[string]any{}); code != 200 || out["canvases"].([]any)[0].(map[string]any)["version"] != float64(2) {
		t.Fatalf("list = %d %v", code, out)
	}

	list := e.want("GET", base, nil, 200)["canvases"].([]any)
	if len(list) != 1 || list[0].(map[string]any)["title"] != "Retention policy" || list[0].(map[string]any)["seq"] != float64(2) {
		t.Fatalf("api list = %v", list)
	}
	cur := e.want("GET", base+"/"+id, nil, 200)
	if cur["body"] != "Archive after 60 days." || cur["viewing_seq"] != float64(2) || cur["seq"] != float64(2) {
		t.Fatalf("api current = %v", cur)
	}
	versions := cur["versions"].([]any)
	if len(versions) != 2 || versions[0].(map[string]any)["seq"] != float64(2) || versions[0].(map[string]any)["note"] != "Longer window" {
		t.Fatalf("versions = %v", versions)
	}
	old := e.want("GET", base+"/"+id+"?seq=1", nil, 200)
	if old["body"] != "Archive after 30 days." || old["viewing_seq"] != float64(1) || old["seq"] != float64(2) {
		t.Fatalf("api v1 = %v", old)
	}
	e.want("GET", base+"/"+id+"?seq="+strconv.Itoa(9), nil, 404)

	// A canvas belongs to its chat.
	other := uuid.MustParse(e.newChat(nil)["id"].(string))
	otherToken := e.canvasToken(other)
	if code, out = e.tool(otherToken, "canvas_read", map[string]any{"canvas_id": id}); code != 404 {
		t.Fatalf("other chat read = %d %v", code, out)
	}
	if code, out = e.tool(otherToken, "canvas_patch", map[string]any{"canvas_id": id, "base_version": 2, "ops": []map[string]any{{"find": "60", "replace": "1"}}}); code != 404 {
		t.Fatalf("other chat patch = %d %v", code, out)
	}
	e.want("GET", "/chats/"+other.String()+"/canvases/"+id, nil, 404)
}

func TestSVGCanvasNeedsThePersonaCapabilityAndKeepsElementIDs(t *testing.T) {
	e := newChatEnv(t)
	persona := e.dockPersona("Designer")
	chat := e.dockChat(persona)
	token := e.canvasToken(chat)
	const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="1"/><text>Stop</text></svg>`
	set := func(on bool) {
		if _, err := e.pool.Exec(t.Context(), `UPDATE personas SET can_create_svgs = $2 WHERE id = $1`, persona, on); err != nil {
			t.Fatal(err)
		}
	}

	set(false)
	create := map[string]any{"kind": "svg", "title": "Run screen", "body": svg}
	if code, out := e.tool(token, "canvas_create", create); code != 409 || !strings.Contains(out["message"].(string), "SVG") {
		t.Fatalf("no capability = %d %v", code, out)
	}
	set(true)
	if code, out := e.tool(token, "canvas_create", map[string]any{"kind": "svg", "title": "Bad", "body": "<svg>"}); code != 422 {
		t.Fatalf("malformed = %d %v", code, out)
	}
	code, out := e.tool(token, "canvas_create", create)
	if code != 200 {
		t.Fatalf("create = %d %v", code, out)
	}
	id := out["canvas_id"]
	read := func() string {
		_, r := e.tool(token, "canvas_read", map[string]any{"canvas_id": id})
		return r["body"].(string)
	}
	body := read()
	if strings.Count(body, "data-vid=") != 2 {
		t.Fatalf("not stamped: %s", body)
	}
	var vids []string
	for _, part := range strings.Split(body, `data-vid="`)[1:] {
		vids = append(vids, part[:strings.Index(part, `"`)])
	}

	code, out = e.tool(token, "canvas_patch", map[string]any{"canvas_id": id, "base_version": 1, "ops": []map[string]any{
		{"op": "insert", "vid": vids[0], "position": "before", "markup": `<circle r="2"/>`},
		{"op": "set_text", "vid": vids[1], "text": "Halt"},
	}})
	if code != 200 {
		t.Fatalf("patch = %d %v", code, out)
	}
	body = read()
	if !strings.Contains(body, `data-vid="`+vids[0]+`"`) || !strings.Contains(body, `data-vid="`+vids[1]+`">Halt</text>`) || strings.Count(body, "data-vid=") != 3 {
		t.Fatalf("after patch: %s", body)
	}

	if code, out = e.tool(token, "canvas_patch", map[string]any{"canvas_id": id, "base_version": 2, "ops": []map[string]any{{"op": "remove", "vid": "nope"}}}); code != 422 {
		t.Fatalf("unknown element = %d %v", code, out)
	}

	set(false)
	if code, out = e.tool(token, "canvas_patch", map[string]any{"canvas_id": id, "base_version": 2, "ops": []map[string]any{{"op": "remove", "vid": vids[0]}}}); code != 409 {
		t.Fatalf("patch without capability = %d %v", code, out)
	}
}

// makeCanvas opens a chat with a running turn and a text canvas in it.
func (e *chatEnv) makeCanvas(body string) (chat uuid.UUID, token, id string) {
	e.t.Helper()
	chat = uuid.MustParse(e.newChat(nil)["id"].(string))
	token = e.canvasToken(chat)
	code, out := e.tool(token, "canvas_create", map[string]any{"kind": "text", "title": "Policy", "body": body})
	if code != 200 {
		e.t.Fatalf("create = %d %v", code, out)
	}
	return chat, token, out["canvas_id"].(string)
}

func TestCanvasCommentsFollowTheirTextAndReachTheAgent(t *testing.T) {
	e := newChatEnv(t)
	const doc = "# Policy\n\nArchive after 30 days. Delete after 90."
	chat, token, id := e.makeCanvas(doc)
	base := "/chats/" + chat.String() + "/canvases/" + id
	start := strings.Index(doc, "30 days")

	c := e.want("POST", base+"/comments", map[string]any{"seq": 1, "start": start, "end": start + 7, "body": "Too short"}, 201)
	if c["status"] != "draft" || c["anchor"].(map[string]any)["quote"] != "30 days" {
		t.Fatalf("comment = %v", c)
	}
	cid := c["id"].(string)
	e.want("POST", base+"/comments", map[string]any{"seq": 9, "start": 0, "end": 1, "body": "stale"}, 409)
	e.want("POST", base+"/comments", map[string]any{"seq": 1, "start": 90, "end": 99, "body": "out of range"}, 422)

	// A draft is the person's own until sent.
	if _, r := e.tool(token, "canvas_read", map[string]any{"canvas_id": id}); len(r["comments"].([]any)) != 0 {
		t.Fatalf("agent saw a draft: %v", r["comments"])
	}
	discard := e.want("POST", base+"/comments", map[string]any{"seq": 1, "start": 0, "end": 1, "body": "never mind"}, 201)["id"].(string)
	e.want("DELETE", base+"/comments/"+discard, nil, 204)
	e.want("PATCH", base+"/comments/"+cid, map[string]any{"status": "resolved"}, 409)

	e.want("POST", base+"/comments/send", map[string]any{"comment_ids": []string{cid}}, 204)
	list := func() []any { return e.want("GET", base+"/comments", nil, 200)["comments"].([]any) }
	if got := list()[0].(map[string]any); got["status"] != "open" {
		t.Fatalf("after send = %v", got)
	}
	msgs := e.want("GET", "/chats/"+chat.String()+"/messages", nil, 200)["messages"].([]any)
	last := msgs[len(msgs)-1].(map[string]any)
	if !strings.Contains(last["body_md"].(string), "1 comment on “Policy”") || last["context_refs"].([]any)[0].(map[string]any)["kind"] != "canvas" {
		t.Fatalf("message = %v", last)
	}

	// What the turn is given, and only inside its own chat.
	refs := []runs.ChatContextRef{{Kind: "canvas", ID: ptr(uuid.MustParse(id))}}
	docs, err := runs.ResolveChatRefs(t.Context(), e.q, e.me.WorkspaceID, chat, refs)
	if err != nil || !strings.Contains(docs[0].Body, "> 30 days") || !strings.Contains(docs[0].Body, "Person: Too short") || !strings.Contains(docs[0].Body, cid) || !strings.Contains(docs[0].Body, doc) {
		t.Fatalf("doc = %+v %v", docs, err)
	}
	if _, err := runs.ResolveChatRefs(t.Context(), e.q, e.me.WorkspaceID, uuid.New(), refs); err == nil {
		t.Fatal("resolved a canvas from another chat")
	}

	// An edit elsewhere moves the anchor; rewriting the passage loses it.
	if code, out := e.tool(token, "canvas_patch", map[string]any{"canvas_id": id, "base_version": 1, "ops": []map[string]any{{"find": "# Policy", "replace": "# Retention policy"}}}); code != 200 {
		t.Fatalf("patch = %d %v", code, out)
	}
	got := list()[0].(map[string]any)
	a := got["anchor"].(map[string]any)
	if got["seq"] != float64(2) || got["target_lost"] != false || a["start"] != float64(start+10) {
		t.Fatalf("moved = %v", got)
	}
	if code, out := e.tool(token, "canvas_patch", map[string]any{"canvas_id": id, "base_version": 2, "ops": []map[string]any{{"find": "30 days", "replace": "60 weeks"}}}); code != 200 {
		t.Fatalf("patch = %d %v", code, out)
	}
	if got = list()[0].(map[string]any); got["target_lost"] != true {
		t.Fatalf("lost = %v", got)
	}

	// Restoring brings the passage, and the comment's place in it, back.
	e.want("POST", base+"/restore", map[string]any{"seq": 2}, 201)
	if got = list()[0].(map[string]any); got["target_lost"] != false {
		t.Fatalf("restored = %v", got)
	}

	if code, out := e.tool(token, "canvas_reply", map[string]any{"canvas_id": id, "comment_id": cid, "body": "Made it 60", "addressed": true}); code != 200 {
		t.Fatalf("reply = %d %v", code, out)
	}
	cs := list()
	if len(cs) != 2 || cs[0].(map[string]any)["status"] != "addressed" || cs[1].(map[string]any)["parent_id"] != cid {
		t.Fatalf("thread = %v", cs)
	}
	// A person replying reopens it.
	e.want("POST", base+"/comments", map[string]any{"parent_id": cid, "body": "Still short"}, 201)
	if got = list()[0].(map[string]any); got["status"] != "open" {
		t.Fatalf("reopened = %v", got)
	}
	e.want("PATCH", base+"/comments/"+cid, map[string]any{"status": "resolved"}, 200)
	e.want("POST", base+"/comments/send", map[string]any{"comment_ids": []string{cid}}, 422)
}

func TestCanvasSuggestionSaveAndPromote(t *testing.T) {
	e := newChatEnv(t)
	chat, token, id := e.makeCanvas("Archive after 30 days.")
	base := "/chats/" + chat.String() + "/canvases/" + id

	if code, out := e.tool(token, "canvas_comment", map[string]any{"canvas_id": id, "quote": "z", "body": "x"}); code != 422 {
		t.Fatalf("missing quote = %d %v", code, out)
	}
	code, out := e.tool(token, "canvas_comment", map[string]any{"canvas_id": id, "quote": "30 days", "body": "Longer?", "suggestion": "60 days"})
	if code != 200 {
		t.Fatalf("comment = %d %v", code, out)
	}
	cid := out["comment_id"].(string)
	if v := e.want("POST", base+"/comments/"+cid+"/apply", nil, 201); v["seq"] != float64(2) || v["author_type"] != "user" {
		t.Fatalf("apply = %v", v)
	}
	if cur := e.want("GET", base, nil, 200); cur["body"] != "Archive after 60 days." {
		t.Fatalf("applied = %v", cur)
	}
	got := e.want("GET", base+"/comments", nil, 200)["comments"].([]any)[0].(map[string]any)
	if got["status"] != "addressed" || got["suggestion"] != nil {
		t.Fatalf("after apply = %v", got)
	}
	e.want("POST", base+"/comments/"+cid+"/apply", nil, 409)

	e.want("POST", base+"/versions", map[string]any{"base_seq": 1, "body": "stale"}, 409)
	e.want("POST", base+"/versions", map[string]any{"base_seq": 2, "body": "Archive after 60 days."}, 422)
	e.want("POST", base+"/versions", map[string]any{"base_seq": 2, "body": "My own words.", "note": "Tweaked"}, 201)
	if cur := e.want("GET", base, nil, 200); cur["seq"] != float64(3) || cur["versions"].([]any)[0].(map[string]any)["author_type"] != "user" {
		t.Fatalf("saved = %v", cur)
	}

	first := e.want("POST", base+"/promote", nil, 200)["artifact_id"].(string)
	if again := e.want("POST", base+"/promote", nil, 200)["artifact_id"].(string); again != first {
		t.Fatalf("promoted twice: %s %s", first, again)
	}
	art := e.want("GET", "/artifacts/"+first, nil, 200)
	if art["type"] != "design" || art["title"] != "Policy" {
		t.Fatalf("artifact = %v", art)
	}
	if e.want("GET", base, nil, 200)["promoted_artifact_id"] != first {
		t.Fatal("promotion not recorded")
	}
}

func TestSVGCanvasCommentsAndPromotion(t *testing.T) {
	e := newChatEnv(t)
	persona := e.dockPersona("Designer")
	if _, err := e.pool.Exec(t.Context(), `UPDATE personas SET can_create_svgs = true WHERE id = $1`, persona); err != nil {
		t.Fatal(err)
	}
	chat := e.dockChat(persona)
	token := e.canvasToken(chat)
	code, out := e.tool(token, "canvas_create", map[string]any{"kind": "svg", "title": "Run", "body": `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><text x="1" y="2">Stop run</text><rect width="1" height="1"/></svg>`})
	if code != 200 {
		t.Fatalf("create = %d %v", code, out)
	}
	id := out["canvas_id"].(string)
	base := "/chats/" + chat.String() + "/canvases/" + id
	body := e.want("GET", base, nil, 200)["body"].(string)
	vid := strings.SplitN(strings.SplitN(body, `data-vid="`, 2)[1], `"`, 2)[0]

	e.want("POST", base+"/comments", map[string]any{"seq": 1, "vid": "nope", "body": "x"}, 422)
	c := e.want("POST", base+"/comments", map[string]any{"seq": 1, "vid": vid, "point": map[string]any{"x": .5, "y": .5}, "body": "Confirm first"}, 201)
	a := c["anchor"].(map[string]any)
	if a["tag"] != "text" || a["label"] != "Stop run" {
		t.Fatalf("anchor = %v", a)
	}
	if code, out = e.tool(token, "canvas_patch", map[string]any{"canvas_id": id, "base_version": 1, "ops": []map[string]any{{"op": "remove", "vid": vid}}}); code != 200 {
		t.Fatalf("patch = %d %v", code, out)
	}
	if got := e.want("GET", base+"/comments", nil, 200)["comments"].([]any)[0].(map[string]any); got["target_lost"] != true {
		t.Fatalf("element gone = %v", got)
	}
	art := e.want("POST", base+"/promote", nil, 200)["artifact_id"].(string)
	if got := e.want("GET", "/artifacts/"+art, nil, 200); got["type"] != "mockup" {
		t.Fatalf("artifact = %v", got)
	}
}

// Over MCP, as a harness calls it: the schema and the decoder must agree on a UUID.
func TestCanvasToolsTakeStringIDsOverMCP(t *testing.T) {
	e := newChatEnv(t)
	_, token, id := e.makeCanvas("Archive after 30 days.")
	client := mcp.NewClient(&mcp.Implementation{Name: "test-agent", Version: "1"}, nil)
	sess, err := client.Connect(t.Context(), &mcp.StreamableClientTransport{
		Endpoint: e.srv.URL + "/mcp", HTTPClient: &http.Client{Transport: bearer{token, http.DefaultTransport}}, DisableStandaloneSSE: true,
	}, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	for name, args := range map[string]map[string]any{
		"canvas_read":    {"canvas_id": id},
		"canvas_comment": {"canvas_id": id, "quote": "30 days", "body": "Longer?", "suggestion": "60 days"},
	} {
		res, err := sess.CallTool(t.Context(), &mcp.CallToolParams{Name: name, Arguments: args})
		if err != nil || res.IsError {
			t.Fatalf("%s: %v %+v", name, err, res)
		}
	}
}

// A chat with no default project saves its canvases outside any project, as
// the same artifact types (a mockup stays a mockup, so it still renders).
func TestPromoteCanvasWithoutProject(t *testing.T) {
	e := newChatEnv(t)
	chat := uuid.MustParse(e.newChat(map[string]any{"project": ""})["id"].(string))
	token := e.canvasToken(chat)
	for kind, want := range map[string]string{"text": "design", "svg": "mockup"} {
		body := "Archive after 30 days."
		if kind == "svg" {
			body = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10"/></svg>`
		}
		code, out := e.tool(token, "canvas_create", map[string]any{"kind": kind, "title": "Loose " + kind, "body": body})
		if code != 200 {
			t.Fatalf("create %s = %d %v", kind, code, out)
		}
		id := e.want("POST", "/chats/"+chat.String()+"/canvases/"+out["canvas_id"].(string)+"/promote", nil, 200)["artifact_id"].(string)
		a := e.want("GET", "/artifacts/"+id, nil, 200)
		if a["type"] != want || a["project"] != nil {
			t.Errorf("%s canvas saved as %v in project %v, want %s with none", kind, a["type"], a["project"], want)
		}
	}
}
