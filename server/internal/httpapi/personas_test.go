package httpapi

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync"
	"testing"

	"github.com/google/uuid"
)

// myDefaultPersona returns the caller's default persona from GET /personas.
func (e *chatEnv) myDefaultPersona() map[string]any {
	e.t.Helper()
	list := e.want("GET", "/personas", nil, 200)
	for _, p := range list["personas"].([]any) {
		if p := p.(map[string]any); p["is_default"] == true {
			if list["default_persona_id"] != p["id"] {
				e.t.Fatalf("default_persona_id %v, default row %v", list["default_persona_id"], p["id"])
			}
			return p
		}
	}
	e.t.Fatalf("no default persona in %v", list)
	return nil
}

// strangerPersona is a persona of another person in the same workspace.
func (e *chatEnv) strangerPersona() string {
	e.t.Helper()
	var id uuid.UUID
	if err := e.pool.QueryRow(context.Background(), `SELECT p.id FROM personas p WHERE p.workspace_id=$1 AND p.user_id<>$2 LIMIT 1`, e.me.WorkspaceID, e.me.ID).Scan(&id); err != nil {
		e.t.Fatalf("no stranger persona: %v", err)
	}
	return id.String()
}

// onlyChatPersonas drops the personas the seed made from its agents, for tests about a
// person's chat personas alone (working personas can't be deleted while they hold tickets).
func (e *chatEnv) onlyChatPersonas() {
	e.t.Helper()
	if _, err := e.pool.Exec(context.Background(), `DELETE FROM personas WHERE id IN (SELECT id FROM agents)`); err != nil {
		e.t.Fatal(err)
	}
}

func (e *chatEnv) defaultCount() int {
	e.t.Helper()
	var n int
	if err := e.pool.QueryRow(context.Background(), `SELECT count(*) FROM personas WHERE workspace_id=$1 AND user_id=$2 AND is_default`, e.me.WorkspaceID, e.me.ID).Scan(&n); err != nil {
		e.t.Fatal(err)
	}
	return n
}

func TestPersonaCRUDAndValidation(t *testing.T) {
	e := newChatEnv(t)
	e.onlyChatPersonas()
	def := e.myDefaultPersona()
	if def["name"] != "Assistant" || def["tone"] != "neutral" || def["color"] != "#64748b" {
		t.Fatalf("seeded default %v", def)
	}

	work := e.want("POST", "/personas", map[string]any{"name": "  Work  ", "tone": "concise", "color": "#AABBCC", "custom_instructions": "Lead with the answer."}, http.StatusCreated)
	if work["name"] != "Work" || work["color"] != "#aabbcc" || work["tone"] != "concise" || work["is_default"] != false ||
		work["revision"].(float64) != 1 || work["chat_count"].(float64) != 0 || work["custom_instructions"] != "Lead with the answer." {
		t.Fatalf("created %v", work)
	}
	if _, ok := work["avatar_url"]; ok {
		t.Fatalf("avatar_url without an avatar: %v", work)
	}
	id := work["id"].(string)
	if got := e.want("GET", "/personas/"+id, nil, 200); got["name"] != "Work" {
		t.Fatalf("get %v", got)
	}
	plain := e.want("POST", "/personas", map[string]any{"name": "Plain"}, http.StatusCreated)
	if plain["tone"] != "neutral" || plain["color"] != "#64748b" || plain["custom_instructions"] != "" {
		t.Fatalf("defaults %v", plain)
	}

	// Edit, revision-checked.
	upd := e.want("PATCH", "/personas/"+id, map[string]any{"revision": 1, "name": "Work mode", "custom_instructions": ""}, 200)
	if upd["name"] != "Work mode" || upd["revision"].(float64) != 2 || upd["custom_instructions"] != "" || upd["tone"] != "concise" {
		t.Fatalf("update %v", upd)
	}
	e.want("PATCH", "/personas/"+id, map[string]any{"revision": 1, "name": "Stale"}, http.StatusConflict)
	e.want("DELETE", "/personas/"+id+"?revision=1", nil, http.StatusConflict)

	// Validation: 422 with the field set.
	e.invalid("POST", "/personas", map[string]any{"name": "   "}, "name", "1–60")
	e.invalid("POST", "/personas", map[string]any{"name": strings.Repeat("x", 61)}, "name", "1–60")
	e.invalid("POST", "/personas", map[string]any{"name": " ASSISTANT "}, "name", "already")
	e.invalid("POST", "/personas", map[string]any{"name": "T", "tone": "angry"}, "tone", "one of")
	e.invalid("POST", "/personas", map[string]any{"name": "C", "color": "red"}, "color", "#rrggbb")
	e.invalid("POST", "/personas", map[string]any{"name": "C", "color": "#abcdeg"}, "color", "#rrggbb")
	e.invalid("POST", "/personas", map[string]any{"name": "I", "custom_instructions": strings.Repeat("é", 2001)}, "custom_instructions", "2000")
	e.invalid("POST", "/personas", map[string]any{"name": "S", "custom_instructions": "use password: hunter2222 for the VPN"}, "custom_instructions", "looks like")
	e.invalid("PATCH", "/personas/"+id, map[string]any{"revision": 2, "name": "assistant"}, "name", "already")
	e.invalid("PATCH", "/personas/"+id, map[string]any{"revision": 2, "color": "#12345"}, "color", "#rrggbb")
	e.invalid("PATCH", "/personas/"+id, map[string]any{"revision": 2, "tone": "loud"}, "tone", "one of")
	e.invalid("PATCH", "/personas/"+id, map[string]any{"revision": 0}, "revision", "invalid")
	// Renaming to its own name in another case is fine.
	e.want("PATCH", "/personas/"+id, map[string]any{"revision": 2, "name": "WORK MODE"}, 200)

	// The 40-persona cap (3 exist).
	for i := range 37 {
		e.want("POST", "/personas", map[string]any{"name": fmt.Sprintf("P%d", i)}, http.StatusCreated)
	}
	e.invalid("POST", "/personas", map[string]any{"name": "One too many"}, "personas", "at most 40")
	if n := len(e.want("GET", "/personas", nil, 200)["personas"].([]any)); n != 40 {
		t.Fatalf("%d personas, want 40", n)
	}

	// Delete.
	e.want("DELETE", "/personas/"+plain["id"].(string)+"?revision=1", nil, http.StatusNoContent)
	e.want("GET", "/personas/"+plain["id"].(string), nil, http.StatusNotFound)
	e.want("DELETE", "/personas/"+plain["id"].(string), nil, http.StatusNotFound)

	// Unknown and foreign personas are 404 everywhere, and never listed.
	for _, other := range []string{uuid.NewString(), e.strangerPersona()} {
		e.want("GET", "/personas/"+other, nil, http.StatusNotFound)
		e.want("PATCH", "/personas/"+other, map[string]any{"revision": 1, "name": "Mine now"}, http.StatusNotFound)
		e.want("POST", "/personas/"+other+"/default", nil, http.StatusNotFound)
		e.want("DELETE", "/personas/"+other, nil, http.StatusNotFound)
		for _, p := range e.want("GET", "/personas", nil, 200)["personas"].([]any) {
			if p.(map[string]any)["id"] == other {
				t.Fatalf("list leaked persona %s", other)
			}
		}
	}
	if e.defaultCount() != 1 {
		t.Fatal("want exactly one default")
	}
}

func TestPersonaDefaultSwapAndDeleteOfDefault(t *testing.T) {
	e := newChatEnv(t)
	e.onlyChatPersonas()
	assistant := e.myDefaultPersona()["id"].(string)

	// Creating with is_default replaces the default.
	b := e.want("POST", "/personas", map[string]any{"name": "B", "is_default": true}, http.StatusCreated)
	if b["is_default"] != true || e.myDefaultPersona()["id"] != b["id"] || e.defaultCount() != 1 {
		t.Fatalf("create with is_default: %v", b)
	}
	if got := e.want("GET", "/personas/"+assistant, nil, 200); got["is_default"] != false {
		t.Fatalf("old default still default: %v", got)
	}
	// Setting a default swaps it; doing it again changes nothing.
	set := e.want("POST", "/personas/"+assistant+"/default", nil, 200)
	if set["is_default"] != true || e.defaultCount() != 1 {
		t.Fatalf("set default %v", set)
	}
	again := e.want("POST", "/personas/"+assistant+"/default", nil, 200)
	if again["revision"] != set["revision"] {
		t.Fatalf("idempotent set bumped the revision: %v → %v", set["revision"], again["revision"])
	}
	list := e.want("GET", "/personas", nil, 200)["personas"].([]any)
	if list[0].(map[string]any)["id"] != assistant {
		t.Fatalf("default not listed first: %v", list)
	}

	// C gets used most recently, so it is promoted when the default goes.
	c := e.want("POST", "/personas", map[string]any{"name": "C"}, http.StatusCreated)
	cID := c["id"].(string)
	chat := e.newChat(map[string]any{"persona_id": cID, "message": map[string]any{"body": "hello"}})
	if got := e.want("GET", "/personas/"+cID, nil, 200); got["last_used_at"] == nil || got["chat_count"].(float64) != 1 {
		t.Fatalf("used persona %v", got)
	}
	e.want("DELETE", "/personas/"+assistant, nil, http.StatusNoContent)
	if d := e.myDefaultPersona(); d["id"] != cID {
		t.Fatalf("promoted %v, want C", d["name"])
	}
	// Then B, the only one left.
	e.want("DELETE", "/personas/"+cID, nil, http.StatusNoContent)
	if d := e.myDefaultPersona(); d["id"] != b["id"] {
		t.Fatalf("promoted %v, want B", d["name"])
	}
	// C's chat falls back to the built-in Assistant.
	if got := e.want("GET", "/chats/"+chat["id"].(string), nil, 200); got["persona"] != nil {
		t.Fatalf("chat of a deleted persona still has %v", got["persona"])
	}
	// Deleting the last persona leaves the built-in Assistant as the default.
	e.want("DELETE", "/personas/"+b["id"].(string), nil, http.StatusNoContent)
	out := e.want("GET", "/personas", nil, 200)
	if len(out["personas"].([]any)) != 0 || out["default_persona_id"] != nil {
		t.Fatalf("after deleting every persona: %v", out)
	}
	if cs := ids(e.want("GET", "/chats", nil, 200)["chats"], "id"); len(cs) != 1 || cs[0] != chat["id"] {
		t.Fatalf("with no default, GET /chats should list the persona-less chats: %v", cs)
	}
	if got := e.newChat(nil); got["persona"] != nil {
		t.Fatalf("new chat without a default got %v", got["persona"])
	}
}

// TestPersonaConcurrentSetDefault: racing default swaps never leave two defaults (or none).
func TestPersonaConcurrentSetDefault(t *testing.T) {
	e := newChatEnv(t)
	var personas []string
	for i := range 5 {
		personas = append(personas, e.want("POST", "/personas", map[string]any{"name": fmt.Sprintf("P%d", i)}, http.StatusCreated)["id"].(string))
	}
	var wg sync.WaitGroup
	codes := make(chan int, 45) // 40 swaps and 5 creates
	for i := range 40 {
		wg.Go(func() {
			req, _ := http.NewRequest("POST", e.srv.URL+"/api/v1/personas/"+personas[i%len(personas)]+"/default", nil)
			res, err := http.DefaultClient.Do(req)
			if err != nil {
				codes <- 0
				return
			}
			res.Body.Close()
			codes <- res.StatusCode
		})
	}
	// Concurrent creates with is_default race against the swaps too.
	for i := range 5 {
		wg.Go(func() {
			code, _ := e.do("POST", "/personas", map[string]any{"name": fmt.Sprintf("D%d", i), "is_default": true})
			codes <- code
		})
	}
	wg.Wait()
	close(codes)
	for code := range codes {
		if code != http.StatusOK && code != http.StatusCreated {
			t.Fatalf("concurrent default change answered %d", code)
		}
	}
	if n := e.defaultCount(); n != 1 {
		t.Fatalf("%d defaults after concurrent swaps, want 1", n)
	}
}

func TestChatPersonaGroupingAndOwnership(t *testing.T) {
	e := newChatEnv(t)
	e.onlyChatPersonas()
	assistant := e.myDefaultPersona()["id"].(string)
	work := e.want("POST", "/personas", map[string]any{"name": "Work", "color": "#112233"}, http.StatusCreated)
	workID := work["id"].(string)

	// New chats take the default unless persona_id is given; payloads embed the summary.
	c1 := e.newChat(nil)
	p1 := c1["persona"].(map[string]any)
	if p1["id"] != assistant || p1["name"] != "Assistant" || p1["color"] != "#64748b" {
		t.Fatalf("default chat persona %v", p1)
	}
	c2 := e.newChat(map[string]any{"persona_id": workID})
	if p := c2["persona"].(map[string]any); p["id"] != workID || p["color"] != "#112233" {
		t.Fatalf("explicit chat persona %v", p)
	}
	id1, id2 := c1["id"].(string), c2["id"].(string)

	list := func(q string) []string {
		t.Helper()
		return ids(e.want("GET", "/chats"+q, nil, 200)["chats"], "id")
	}
	same := func(got []string, want ...string) bool {
		if len(got) != len(want) {
			return false
		}
		for _, w := range want {
			found := false
			for _, g := range got {
				found = found || g == w
			}
			if !found {
				return false
			}
		}
		return true
	}
	if got := list(""); !same(got, id1) {
		t.Fatalf("default list %v, want only the default persona's chat", got)
	}
	if got := list("?persona_id=" + workID); !same(got, id2) {
		t.Fatalf("work list %v", got)
	}
	if got := list("?persona_id=all"); !same(got, id1, id2) {
		t.Fatalf("all list %v", got)
	}
	if got := list("?persona_id=none"); len(got) != 0 {
		t.Fatalf("none list %v", got)
	}
	// A persona that joined a chat (by @mention) lists it too; the host still does.
	if _, err := e.pool.Exec(context.Background(), `INSERT INTO chat_participants (chat_id, persona_id) VALUES ($1, $2)`, id1, workID); err != nil {
		t.Fatal(err)
	}
	if got := list("?persona_id=" + workID); !same(got, id1, id2) {
		t.Fatalf("work list with a joined chat %v", got)
	}
	if got := list(""); !same(got, id1) {
		t.Fatalf("host list with a guest %v", got)
	}
	if _, err := e.pool.Exec(context.Background(), `DELETE FROM chat_participants WHERE chat_id = $1`, id1); err != nil {
		t.Fatal(err)
	}

	// Someone else's or an unknown persona is rejected without revealing it.
	stranger := e.strangerPersona()
	for _, bad := range []string{stranger, uuid.NewString(), "nonsense"} {
		e.invalid("GET", "/chats?persona_id="+bad, nil, "persona_id", "")
	}
	for _, bad := range []string{stranger, uuid.NewString()} {
		e.invalid("POST", "/chats", map[string]any{"project": "PAY", "persona_id": bad}, "persona_id", "unknown persona")
	}
	var foreignChats int
	if err := e.pool.QueryRow(context.Background(), `SELECT count(*) FROM chat_sessions WHERE persona_id=$1`, stranger).Scan(&foreignChats); err != nil || foreignChats != 0 {
		t.Fatalf("a chat was linked to a foreign persona (%d, %v)", foreignChats, err)
	}

	// Changing the default changes the unfiltered list.
	e.want("POST", "/personas/"+workID+"/default", nil, 200)
	if got := list(""); !same(got, id2) {
		t.Fatalf("list after the default swap %v", got)
	}
	// A rename shows up in the embedded summary.
	e.want("PATCH", "/personas/"+workID, map[string]any{"revision": work["revision"].(float64) + 1, "name": "Deep work"}, 200)
	if p := e.want("GET", "/chats/"+id2, nil, 200)["persona"].(map[string]any); p["name"] != "Deep work" {
		t.Fatalf("summary after rename %v", p)
	}

	// Deleting the default: its chats move to `none`, the Assistant is promoted.
	e.want("DELETE", "/personas/"+workID, nil, http.StatusNoContent)
	if got := e.want("GET", "/chats/"+id2, nil, 200); got["persona"] != nil {
		t.Fatalf("deleted persona still embedded: %v", got["persona"])
	}
	if got := list("?persona_id=none"); !same(got, id2) {
		t.Fatalf("none list after delete %v", got)
	}
	if got := list("?persona_id=all"); !same(got, id1, id2) {
		t.Fatalf("all list after delete %v", got)
	}
	if got := list(""); !same(got, id1) {
		t.Fatalf("default list after delete %v (the Assistant should be promoted)", got)
	}
	e.invalid("GET", "/chats?persona_id="+workID, nil, "persona_id", "unknown")
}

func TestPersonaCapabilitiesAndRepos(t *testing.T) {
	e := newChatEnv(t)
	plain := e.want("POST", "/personas", map[string]any{"name": "Plain"}, http.StatusCreated)
	if c := plain["capabilities"].(map[string]any); c["code"] != false || c["images"] != false {
		t.Fatalf("default capabilities %v", plain)
	}
	if repos, ok := plain["repos"].([]any); !ok || len(repos) != 0 {
		t.Fatalf("repos must be [] not %#v", plain["repos"])
	}

	dev := e.want("POST", "/personas", map[string]any{
		"name": "Dev", "capabilities": map[string]any{"code": true, "images": false},
		"repos": []string{"HTTPS://GitHub.com/acme/app.git/", "git@github.com:acme/api", "https://github.com/acme/app.git"},
	}, http.StatusCreated)
	id := dev["id"].(string)
	if c := dev["capabilities"].(map[string]any); c["code"] != true || c["images"] != false {
		t.Fatalf("capabilities %v", dev)
	}
	if got := fmt.Sprint(dev["repos"]); got != "[https://github.com/acme/app.git git@github.com:acme/api]" {
		t.Fatalf("repos not normalized and deduplicated: %s", got)
	}

	// Patch: capabilities replace together, repos replace the whole list, absent leaves them.
	upd := e.want("PATCH", "/personas/"+id, map[string]any{"revision": 1, "name": "Developer"}, 200)
	if upd["capabilities"].(map[string]any)["code"] != true || len(upd["repos"].([]any)) != 2 || upd["revision"].(float64) != 2 {
		t.Fatalf("an unrelated patch changed capabilities or repos: %v", upd)
	}
	upd = e.want("PATCH", "/personas/"+id, map[string]any{"revision": 2, "capabilities": map[string]any{"code": false, "images": true}, "repos": []string{"https://github.com/acme/web"}}, 200)
	if c := upd["capabilities"].(map[string]any); c["code"] != false || c["images"] != true || fmt.Sprint(upd["repos"]) != "[https://github.com/acme/web]" {
		t.Fatalf("patch %v", upd)
	}
	// Repos may be kept while code is off, and cleared with [].
	upd = e.want("PATCH", "/personas/"+id, map[string]any{"revision": 3, "repos": []string{}}, 200)
	if len(upd["repos"].([]any)) != 0 || upd["revision"].(float64) != 4 {
		t.Fatalf("clear repos %v", upd)
	}
	// Stale revision still conflicts.
	e.want("PATCH", "/personas/"+id, map[string]any{"revision": 3, "capabilities": map[string]any{"code": true, "images": true}}, http.StatusConflict)

	for _, bad := range []string{"-uhttps://x", "ext::sh -c touch", "file:///etc", "/tmp/repo", "https://u:t@github.com/a/b", "http://github.com/a/b"} {
		e.invalid("POST", "/personas", map[string]any{"name": "Bad", "repos": []string{bad}}, "repos", "")
		e.invalid("PATCH", "/personas/"+id, map[string]any{"revision": 4, "repos": []string{bad}}, "repos", "")
	}
	e.invalid("POST", "/personas", map[string]any{"name": "Bad", "repos": []string{"https://u:t@github.com/a/b"}}, "repos", "Settings secrets")
	many := make([]string, 11)
	for i := range many {
		many[i] = fmt.Sprintf("https://github.com/acme/r%d", i)
	}
	e.want("POST", "/personas", map[string]any{"name": "Many", "repos": many}, http.StatusUnprocessableEntity)
	e.invalid("POST", "/personas", map[string]any{"name": "Many", "repos": many}, "repos", "at most 10")

	// The summary a chat embeds carries the capabilities.
	e.want("PATCH", "/personas/"+id, map[string]any{"revision": 4, "capabilities": map[string]any{"code": true, "images": true}}, 200)
	chat := e.newChat(map[string]any{"persona_id": id})
	if c := chat["persona"].(map[string]any)["capabilities"].(map[string]any); c["code"] != true || c["images"] != true {
		t.Fatalf("chat persona summary %v", chat["persona"])
	}
}

func TestChatRepoSelection(t *testing.T) {
	e := newChatEnv(t)
	mk := func(name string, code bool, repos ...string) string {
		return e.want("POST", "/personas", map[string]any{"name": name, "capabilities": map[string]any{"code": code, "images": false}, "repos": repos}, http.StatusCreated)["id"].(string)
	}
	coder := mk("Pair Programmer", true, "https://github.com/acme/app", "git@github.com:acme/api.git")
	noCode := mk("Writer", false, "https://github.com/acme/docs")
	noRepos := mk("Empty", true)

	// The first repo is the default. No branch yet: the persona makes its
	// branches as changes are asked for.
	noBranches := func(c map[string]any) bool { b, ok := c["work_branches"].([]any); return ok && len(b) == 0 }
	c := e.newChat(map[string]any{"persona_id": coder})
	if c["repo_url"] != "https://github.com/acme/app" || !noBranches(c) {
		t.Fatalf("default repo/branches: %v %v", c["repo_url"], c["work_branches"])
	}
	// An explicit repo is compared after normalization.
	c = e.newChat(map[string]any{"persona_id": coder, "repo_url": "git@github.com:acme/api.git"})
	if c["repo_url"] != "https://github.com/acme/api.git" || !noBranches(c) {
		t.Fatalf("explicit repo: %v", c)
	}
	// It is fixed for the chat: renaming the chat or editing the persona leaves it.
	chatID := c["id"].(string)
	e.want("PATCH", "/chats/"+chatID, map[string]any{"revision": c["revision"], "title": "renamed"}, 200)
	if got := e.want("GET", "/chats/"+chatID, nil, 200); got["repo_url"] != "https://github.com/acme/api.git" || !noBranches(got) {
		t.Fatalf("repo changed: %v", got)
	}
	e.want("POST", "/chats", map[string]any{"project": "PAY", "persona_id": coder, "repo_url": "https://github.com/acme/other"}, 201)
	e.invalid("POST", "/chats", map[string]any{"project": "PAY", "persona_id": coder, "repo_url": "file:///etc"}, "repo_url", "GitHub URL")
	e.invalid("POST", "/chats", map[string]any{"project": "PAY", "persona_id": noCode, "repo_url": "https://github.com/acme/docs"}, "repo_url", "can code")
	// A persona that can't code, or has no repos, gets a chat without a repository.
	for _, p := range []string{noCode, noRepos} {
		if c := e.newChat(map[string]any{"persona_id": p}); c["repo_url"] != nil || c["work_branches"] != nil {
			t.Fatalf("persona %s: %v", p, c)
		}
	}
	// The default persona is resolved the same way when persona_id is omitted.
	e.want("POST", "/personas/"+coder+"/default", nil, 200)
	if c := e.newChat(nil); c["repo_url"] != "https://github.com/acme/app" || c["persona"].(map[string]any)["id"] != coder {
		t.Fatalf("default persona chat: %v", c)
	}
}

// A persona's work is its agents row with the persona's id: turning it on makes that row (and
// a handle), and turning it off archives it, refused while the persona holds open tickets.
// Renaming the persona renames its work. Taking tickets is the only work.
func TestPersonaWork(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()
	p := e.want("POST", "/personas", map[string]any{"name": "Dr. Mara"}, http.StatusCreated)
	id := p["id"].(string)
	if p["work"] != "none" || p["in_chat_list"] != true || p["handle"] != nil {
		t.Fatalf("new persona %v, want work none, in the chat list, no handle", p)
	}

	p = e.want("PATCH", "/personas/"+id, map[string]any{"revision": 1, "work": "tickets"}, 200)
	if p["work"] != "tickets" || p["handle"] != "dr-mara" || p["work_status"] != "idle" || p["work_model"] == nil {
		t.Fatalf("after tickets %v", p)
	}
	var kind, handle string
	if err := e.pool.QueryRow(ctx, `SELECT kind, handle FROM agents WHERE id=$1 AND archived_at IS NULL`, id).Scan(&kind, &handle); err != nil || kind != "main" || handle != "dr-mara" {
		t.Fatalf("work record kind=%q handle=%q err=%v", kind, handle, err)
	}
	// It can be assigned a ticket now, by handle, like any agent.
	ticket := e.want("POST", "/tickets", map[string]any{"project_key": "PAY", "title": "Check the ledger", "assignee_agent_id": id}, http.StatusCreated)

	// Work can't stop while it holds one.
	rev := int(p["revision"].(float64))
	e.invalid("PATCH", "/personas/"+id, map[string]any{"revision": rev, "work": "helper"}, "work", "")
	e.want("PATCH", "/personas/"+id, map[string]any{"revision": rev, "work": "none"}, http.StatusConflict)
	rev++
	e.want("DELETE", "/personas/"+id, nil, http.StatusConflict)
	e.want("PATCH", "/tickets/"+ticket["key"].(string), map[string]any{"revision": int(ticket["revision"].(float64)), "status": "done"}, 200)

	p = e.want("PATCH", "/personas/"+id, map[string]any{"revision": rev, "name": "Mara", "in_chat_list": false, "work": "none"}, 200)
	if p["work"] != "none" || p["in_chat_list"] != false || p["handle"] != "dr-mara" {
		t.Fatalf("after none %v: the handle stays, the work stops", p)
	}
	var name string
	var archived bool
	if err := e.pool.QueryRow(ctx, `SELECT name, archived_at IS NOT NULL FROM agents WHERE id=$1`, id).Scan(&name, &archived); err != nil || name != "Mara" || !archived {
		t.Fatalf("work record name=%q archived=%v err=%v", name, archived, err)
	}
	// Back on: the same record, revived.
	p = e.want("PATCH", "/personas/"+id, map[string]any{"revision": int(p["revision"].(float64)), "work": "tickets"}, 200)
	if p["work"] != "tickets" || p["handle"] != "dr-mara" {
		t.Fatalf("revived %v", p)
	}
	e.invalid("PATCH", "/personas/"+id, map[string]any{"revision": int(p["revision"].(float64)), "work": "everything"}, "work", "")
}

func TestPersonaDefaultModelAndWorkSync(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()

	// 1. Non-worker persona sets a default harness, model, and effort; new chats inherit it.
	p := e.want("POST", "/personas", map[string]any{
		"name": "Reviewer", "default_harness": "codex", "default_model": "gpt-5-codex", "default_effort": "high",
	}, http.StatusCreated)
	id := p["id"].(string)
	if p["default_harness"] != "codex" || p["default_model"] != "gpt-5-codex" || p["default_effort"] != "high" {
		t.Fatalf("created persona default model = %v", p)
	}
	chat := e.newChat(map[string]any{"persona_id": id})
	if chat["harness"] != "codex" || chat["model"] != "gpt-5-codex" || chat["effort"] != "high" || chat["auto_model"] != nil {
		t.Fatalf("chat inherited %v", chat)
	}

	// 2. Enabling work inherits the persona's default harness/model/effort on the agent definition.
	p = e.want("PATCH", "/personas/"+id, map[string]any{"revision": p["revision"], "work": "tickets"}, http.StatusOK)
	if p["work_model"] != "gpt-5-codex" {
		t.Fatalf("started work_model = %v, want gpt-5-codex", p["work_model"])
	}
	detail := e.want("GET", "/agents/"+p["handle"].(string), nil, http.StatusOK)
	spec := detail["spec"].(map[string]any)
	if spec["harness"] != "codex" || spec["model"] != "gpt-5-codex" {
		t.Fatalf("agent spec after starting work = %v", spec)
	}
	if opts := spec["harness_options"].(map[string]any)["codex"].(map[string]any); opts["effort"] != "high" {
		t.Fatalf("agent effort after starting work = %v, want high", opts)
	}

	// 3. Add a fallback for claude-code/opus-5.5 on the agent, then switch persona's default
	// to claude-code/opus-5.5: work definition updates AND matching fallback is stripped.
	spec["fallbacks"] = []any{map[string]any{"harness": "claude-code", "model": "opus-5.5"}}
	e.want("PUT", "/agents/"+p["handle"].(string)+"/definition", map[string]any{
		"name": p["name"], "role": "", "specialty": "", "color_index": 0, "spec": spec, "note": "Add fallback",
	}, http.StatusOK)
	// Direct agent definition save keeps persona default synced; refetch persona for latest revision.
	p = e.want("GET", "/personas/"+id, nil, http.StatusOK)
	p = e.want("PATCH", "/personas/"+id, map[string]any{
		"revision": p["revision"], "default_harness": "claude-code", "default_model": "opus-5.5", "default_effort": "default",
	}, http.StatusOK)
	if p["default_harness"] != "claude-code" || p["default_model"] != "opus-5.5" || p["default_effort"] != nil || p["work_model"] != "opus-5.5" {
		t.Fatalf("updated persona = %v", p)
	}
	detail = e.want("GET", "/agents/"+p["handle"].(string), nil, http.StatusOK)
	spec = detail["spec"].(map[string]any)
	if spec["harness"] != "claude-code" || spec["model"] != "opus-5.5" {
		t.Fatalf("agent spec after persona update = %v", spec)
	}
	if fbs, ok := spec["fallbacks"].([]any); ok && len(fbs) != 0 {
		t.Fatalf("matching fallback should be removed, got %v", fbs)
	}
	var dbModel string
	if err := e.pool.QueryRow(ctx, `SELECT model FROM agents WHERE id = $1`, id).Scan(&dbModel); err != nil || dbModel != "opus-5.5" {
		t.Fatalf("agents.model = %q err=%v", dbModel, err)
	}

	// 4. Editing via PUT /agents/{handle}/definition syncs back to persona.
	spec["harness"], spec["model"] = "codex", "gpt-5"
	spec["harness_options"] = map[string]any{"codex": map[string]any{"effort": "medium"}}
	e.want("PUT", "/agents/"+p["handle"].(string)+"/definition", map[string]any{
		"name": p["name"], "role": "", "specialty": "", "color_index": 0, "spec": spec,
	}, http.StatusOK)
	p = e.want("GET", "/personas/"+id, nil, http.StatusOK)
	if p["default_harness"] != "codex" || p["default_model"] != "gpt-5" || p["default_effort"] != "medium" {
		t.Fatalf("persona after PUT definition = %v", p)
	}

	// 5. Stopping work, clearing back to Auto, and resuming work keeps things valid.
	p = e.want("PATCH", "/personas/"+id, map[string]any{"revision": p["revision"], "work": "none"}, http.StatusOK)
	p = e.want("PATCH", "/personas/"+id, map[string]any{
		"revision": p["revision"], "default_harness": "", "default_model": "auto", "default_effort": "",
	}, http.StatusOK)
	if p["default_harness"] != nil || p["default_model"] != nil || p["default_effort"] != nil {
		t.Fatalf("cleared to Auto = %v", p)
	}
	p = e.want("PATCH", "/personas/"+id, map[string]any{
		"revision": p["revision"], "default_harness": "antigravity", "default_model": "gemini-2.5-pro",
	}, http.StatusOK)
	p = e.want("PATCH", "/personas/"+id, map[string]any{"revision": p["revision"], "work": "tickets"}, http.StatusOK)
	if p["work_model"] != "gemini-2.5-pro" {
		t.Fatalf("resumed work_model = %v, want gemini-2.5-pro", p["work_model"])
	}

	// 6. Validation errors.
	rev := int(p["revision"].(float64))
	e.invalid("PATCH", "/personas/"+id, map[string]any{"revision": rev, "default_harness": "codex", "default_model": "auto"}, "default_model", "")
	e.invalid("PATCH", "/personas/"+id, map[string]any{"revision": rev, "default_effort": "ludicrous"}, "default_effort", "")
}
