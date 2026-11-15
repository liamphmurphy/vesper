package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// request_push only records what the persona asked for (the runner stages it
// when the turn ends); the card can be declined, and pushing needs a token.
func TestChatRequestPushAndDecide(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	tr := &tracker.Service{Pool: pool}
	rs := &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts}
	handler := (&Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: rs, Artifacts: arts}).Handler()

	code := true
	p, err := (&personas.Service{Pool: pool}).Create(ctx, personas.Owner{WorkspaceID: ws, UserID: me.ID}, personas.NewInput{Name: "Coder", Code: &code})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := rs.StartChat(ctx, ws, me.ID, runs.ChatInput{PersonaID: &p.ID, Message: &runs.ChatMessageInput{Body: "hi"}})
	if err != nil {
		t.Fatal(err)
	}
	// What the runner records once the checkout is set up.
	if _, err := q.AttachChatRepository(ctx, store.AttachChatRepositoryParams{ChatID: chat.ID, RepoUrl: "https://github.com/acme/alpha.git", Directory: ".lazyagents/repos/acme/alpha"}); err != nil {
		t.Fatal(err)
	}
	chat, _ = q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: ws})
	runID := *chat.CurrentRunID
	if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: runID, State: "running"}); err != nil {
		t.Fatal(err)
	}
	token, _, err := agents.IssueToken(ctx, q, chat.AgentID, "run", "chat", &runID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	do := func(method, path, auth string, body any) (int, map[string]any) {
		t.Helper()
		raw, _ := json.Marshal(body)
		req := httptest.NewRequest(method, path, bytes.NewReader(raw))
		req.Header.Set("Content-Type", "application/json")
		if auth != "" {
			req.Header.Set("Authorization", "Bearer "+auth)
		}
		w := httptest.NewRecorder()
		handler.ServeHTTP(w, req)
		var out map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &out)
		return w.Code, out
	}
	tool := func(args map[string]any) (int, map[string]any) {
		return do("POST", "/api/v1/agent/tools/request_push", token, args)
	}

	for name, args := range map[string]map[string]any{
		"default branch name": {"branch": "main", "title": "x"},
		"no title":            {"branch": "feat/x"},
		"unattached repo":     {"branch": "feat/x", "title": "x", "repository": "https://github.com/acme/other"},
	} {
		if c, out := tool(args); c < 400 || c >= 500 {
			t.Errorf("%s: %d %v", name, c, out)
		}
	}
	c, first := tool(map[string]any{"branch": "feat/x", "title": "First", "body": "b", "repository": ".lazyagents/repos/acme/alpha"})
	if c != 200 || first["state"] != "staging" || !strings.Contains(first["tell_the_person"].(string), "Requested, not pushed") {
		t.Fatalf("request_push = %d %v", c, first)
	}
	c, second := tool(map[string]any{"branch": "feat/x", "title": "Second", "repository": "https://github.com/acme/alpha"})
	if c != 200 {
		t.Fatalf("second = %d %v", c, second)
	}

	c, list := do("GET", "/api/v1/chats/"+chat.ID.String()+"/push-requests", "", nil)
	reqs, _ := list["requests"].([]any)
	if c != 200 || len(reqs) != 2 {
		t.Fatalf("list = %d %v", c, list)
	}
	byID := map[string]map[string]any{}
	for _, r := range reqs {
		m := r.(map[string]any)
		byID[m["id"].(string)] = m
	}
	if old := byID[first["request_id"].(string)]; old["state"] != "declined" || !strings.Contains(old["error"].(string), "Replaced") {
		t.Fatalf("the newer request for the branch replaces the older: %v", old)
	}

	id := second["request_id"].(string)
	if c, out := do("POST", "/api/v1/push-requests/"+id, "", map[string]any{"decision": "push"}); c != 409 {
		t.Fatalf("a request still staging can't be decided: %d %v", c, out)
	}
	sha, base, ref := "0123456789abcdef0123456789abcdef01234567", "main", "vesper-checkpoint/push/"+id
	if _, err := q.SetPushRequestStaged(ctx, store.SetPushRequestStagedParams{ID: uuid.MustParse(id), BaseBranch: &base, BaseSha: &sha, HeadSha: &sha, StagingRef: &ref, Commits: []byte("[]"), Files: []byte("[]")}); err != nil {
		t.Fatal(err)
	}
	if c, out := do("POST", "/api/v1/push-requests/"+id, "", map[string]any{"decision": "push"}); c != 409 || !strings.Contains(strings.ToLower(jsonText(out)), "token") {
		t.Fatalf("pushing without a GitHub token is refused: %d %v", c, out)
	}
	c, declined := do("POST", "/api/v1/push-requests/"+id, "", map[string]any{"decision": "deny"})
	if c != 200 || declined["state"] != "declined" {
		t.Fatalf("decline = %d %v", c, declined)
	}
	if c, _ := do("POST", "/api/v1/push-requests/"+id, "", map[string]any{"decision": "deny"}); c != 409 {
		t.Fatalf("a decided request stays decided: %d", c)
	}
}

func jsonText(v any) string { b, _ := json.Marshal(v); return string(b) }

func TestGetChatCodeReviewTreeIsolationAndAccess(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	q := store.New(pool)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	me, _ := q.GetLocalUser(ctx)
	ws := me.WorkspaceID
	tr := &tracker.Service{Pool: pool}
	rs := &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts}
	handler := (&Server{AnonymousAPI: true, Pool: pool, Q: q, Tracker: tr, Runs: rs, Artifacts: arts}).Handler()

	code := true
	p, err := (&personas.Service{Pool: pool}).Create(ctx, personas.Owner{WorkspaceID: ws, UserID: me.ID}, personas.NewInput{Name: "Coder", Code: &code})
	if err != nil {
		t.Fatal(err)
	}
	chat, err := rs.StartChat(ctx, ws, me.ID, runs.ChatInput{PersonaID: &p.ID, Message: &runs.ChatMessageInput{Body: "hi"}})
	if err != nil {
		t.Fatal(err)
	}

	b1, sha1 := "feat/alpha", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
	b2, sha2 := "feat/beta", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
	if err := q.UpsertChatCodeReview(ctx, store.UpsertChatCodeReviewParams{
		ChatID: chat.ID, RepoUrl: "https://github.com/acme/alpha.git", Branch: &b1, BaseSha: &sha1, HeadSha: &sha1,
		Commits: []byte("[]"), Files: []byte(`[{"path":"a.go","status":"modified","additions":1,"deletions":0,"binary":false,"truncated":false}]`),
		Tree:          []byte(`[{"path":"README.md","size":5,"binary":false,"content":"alpha","truncated":false}]`),
		TreeTruncated: false,
	}); err != nil {
		t.Fatal(err)
	}
	if err := q.UpsertChatCodeReview(ctx, store.UpsertChatCodeReviewParams{
		ChatID: chat.ID, RepoUrl: "https://github.com/acme/beta.git", Branch: &b2, BaseSha: &sha2, HeadSha: &sha2,
		Commits: []byte("[]"), Files: []byte(`[{"path":"b.ts","status":"added","additions":2,"deletions":0,"binary":false,"truncated":false}]`),
		Tree:          []byte(`[{"path":"package.json","size":2,"binary":false,"content":"{}","truncated":false}]`),
		TreeTruncated: true,
	}); err != nil {
		t.Fatal(err)
	}

	req := httptest.NewRequest("GET", "/api/v1/chats/"+chat.ID.String()+"/code-review", nil)
	w := httptest.NewRecorder()
	handler.ServeHTTP(w, req)
	if w.Code != 200 {
		t.Fatalf("status = %d body = %s", w.Code, w.Body.String())
	}
	var resp struct {
		Repositories []struct {
			Repository    string `json:"repository"`
			Branch        string `json:"branch"`
			HeadSha       string `json:"head_sha"`
			TreeTruncated bool   `json:"tree_truncated"`
			Tree          []struct {
				Path    string  `json:"path"`
				Content *string `json:"content"`
			} `json:"tree"`
		} `json:"repositories"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &resp); err != nil {
		t.Fatal(err)
	}
	if len(resp.Repositories) != 2 {
		t.Fatalf("repos = %+v", resp.Repositories)
	}
	if resp.Repositories[0].Repository != "https://github.com/acme/alpha.git" || resp.Repositories[0].TreeTruncated ||
		len(resp.Repositories[0].Tree) != 1 || resp.Repositories[0].Tree[0].Path != "README.md" || *resp.Repositories[0].Tree[0].Content != "alpha" {
		t.Fatalf("alpha mismatch: %+v", resp.Repositories[0])
	}
	if resp.Repositories[1].Repository != "https://github.com/acme/beta.git" || !resp.Repositories[1].TreeTruncated ||
		len(resp.Repositories[1].Tree) != 1 || resp.Repositories[1].Tree[0].Path != "package.json" || *resp.Repositories[1].Tree[0].Content != "{}" {
		t.Fatalf("beta mismatch: %+v", resp.Repositories[1])
	}

	// Non-owned / unknown chat returns 404; unauthenticated server denies anonymous access.
	w404 := httptest.NewRecorder()
	handler.ServeHTTP(w404, httptest.NewRequest("GET", "/api/v1/chats/"+uuid.New().String()+"/code-review", nil))
	if w404.Code != 404 {
		t.Fatalf("missing chat status = %d", w404.Code)
	}
	strict := (&Server{AnonymousAPI: false, Pool: pool, Q: q, Tracker: tr, Runs: rs, Artifacts: arts}).Handler()
	w401 := httptest.NewRecorder()
	strict.ServeHTTP(w401, httptest.NewRequest("GET", "/api/v1/chats/"+chat.ID.String()+"/code-review", nil))
	if w401.Code != 401 {
		t.Fatalf("unauth status = %d", w401.Code)
	}
}
