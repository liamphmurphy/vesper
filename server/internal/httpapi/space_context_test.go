package httpapi

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

func TestSpaceRepositoriesAutoAttachAndNonCodingSkip(t *testing.T) {
	e := newChatEnv(t)
	coder := e.want("POST", "/personas", map[string]any{"name": "Judy", "capabilities": map[string]any{"code": true}}, http.StatusCreated)["id"].(string)
	writer := e.want("POST", "/personas", map[string]any{"name": "Iris"}, http.StatusCreated)["id"].(string)

	sp := e.want("POST", "/chat-spaces", map[string]any{"name": "Vesper", "persona_id": coder}, http.StatusCreated)
	spID := sp["id"].(string)

	r1 := e.want("POST", "/chat-spaces/"+spID+"/repositories", map[string]any{"repo_url": "liamphmurphy/Vesper"}, http.StatusCreated)
	if r1["repo_url"] != "https://github.com/liamphmurphy/vesper.git" || r1["read_only"] != false {
		t.Fatalf("unexpected repo1: %v", r1)
	}
	// Duplicate returns 409.
	e.want("POST", "/chat-spaces/"+spID+"/repositories", map[string]any{"repo_url": "https://github.com/liamphmurphy/Vesper"}, http.StatusConflict)

	r2 := e.want("POST", "/chat-spaces/"+spID+"/repositories", map[string]any{"repo_url": "liamphmurphy/dotfiles", "read_only": true}, http.StatusCreated)
	if r2["read_only"] != true {
		t.Fatalf("expected read_only=true: %v", r2)
	}

	// Coding chat inherits both space repos automatically.
	chat := e.want("POST", "/chats", map[string]any{"space_id": spID}, http.StatusCreated)
	chatID := uuid.MustParse(chat["id"].(string))
	attached, err := e.q.ChatRepositories(context.Background(), chatID)
	if err != nil {
		t.Fatal(err)
	}
	if len(attached) != 2 {
		t.Fatalf("want 2 attached repos, got %d: %+v", len(attached), attached)
	}

	// Explicit no_repo skips space repos.
	brainstorm := e.want("POST", "/chats", map[string]any{"space_id": spID, "no_repo": true}, http.StatusCreated)
	bsAttached, err := e.q.ChatRepositories(context.Background(), uuid.MustParse(brainstorm["id"].(string)))
	if err != nil {
		t.Fatal(err)
	}
	if len(bsAttached) != 0 {
		t.Fatalf("want 0 attached repos with no_repo, got %d", len(bsAttached))
	}

	// Non-coding persona in a space with repos succeeds without error and attaches 0 repos.
	nonCoding := e.want("POST", "/chats", map[string]any{"space_id": spID, "persona_id": writer}, http.StatusCreated)
	ncAttached, err := e.q.ChatRepositories(context.Background(), uuid.MustParse(nonCoding["id"].(string)))
	if err != nil {
		t.Fatal(err)
	}
	if len(ncAttached) != 0 {
		t.Fatalf("want 0 attached repos for non-coding persona, got %d", len(ncAttached))
	}

	// Toggle read_only and delete.
	updated := e.want("PATCH", "/chat-spaces/"+spID+"/repositories/"+r1["id"].(string), map[string]any{"read_only": true}, http.StatusOK)
	if updated["read_only"] != true {
		t.Fatalf("expected read_only updated: %v", updated)
	}
	e.want("DELETE", "/chat-spaces/"+spID+"/repositories/"+r2["id"].(string), nil, http.StatusNoContent)
}

func TestSpaceKnowledgeLinksAndFolderRenameSync(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()
	ws := e.me.WorkspaceID
	userID := e.me.ID

	wikiSvc := &wiki.Service{Pool: e.pool, Artifacts: &artifacts.Service{Pool: e.pool}}

	// Create two pages inside Umbra/ so folder count and MoveFolder work.
	if _, err := wikiSvc.SaveAsUser(ctx, ws, userID, wiki.Save{Path: "Umbra/Campaign Bible", Body: "# Umbra\nDark fantasy."}); err != nil {
		t.Fatal(err)
	}
	if _, err := wikiSvc.SaveAsUser(ctx, ws, userID, wiki.Save{Path: "Umbra/Sessions/Session 1", Body: "Opening scene."}); err != nil {
		t.Fatal(err)
	}

	sp := e.want("POST", "/chat-spaces", map[string]any{"name": "Umbra Campaign"}, http.StatusCreated)
	spID := sp["id"].(string)

	link := e.want("POST", "/chat-spaces/"+spID+"/knowledge", map[string]any{"kind": "folder", "path": "Umbra"}, http.StatusCreated)
	if link["is_default_target"] != true || link["page_count"].(float64) != 2 {
		t.Fatalf("unexpected folder link: %v", link)
	}

	// Moving the folder in Knowledge updates the linked path on the Space automatically.
	if _, err := wikiSvc.MoveFolder(ctx, ws, userID, wiki.FolderScope{Folder: "Umbra"}, "Campaigns/Umbra"); err != nil {
		t.Fatal(err)
	}
	list := e.want("GET", "/chat-spaces/"+spID+"/knowledge", nil, http.StatusOK)["links"].([]any)
	if len(list) != 1 || list[0].(map[string]any)["path"] != "Campaigns/Umbra" {
		t.Fatalf("expected link path synced to Campaigns/Umbra, got %v", list)
	}

	// SpaceSectionWithContext renders repos, Knowledge manifest, and pinned page body.
	spRow, err := e.q.GetChatSpaceByID(ctx, uuid.MustParse(spID))
	if err != nil {
		t.Fatal(err)
	}
	sec := runs.SpaceSectionWithContext(&spRow, nil, runs.SpaceLiveContext{
		Repos: []store.ChatSpaceRepository{{RepoUrl: "https://github.com/liamphmurphy/Vesper", ReadOnly: true}},
		KnowledgeLinks: []runs.SpaceKnowledgeManifestEntry{
			{Kind: "folder", Path: "Campaigns/Umbra", PageCount: 2, IsDefaultTarget: true},
			{Kind: "page", Path: "Campaigns/Umbra/Campaign Bible", Pinned: true, PinnedBody: "Dark fantasy."},
		},
	})
	for _, want := range []string{"read-only reference", "Campaigns/Umbra/", "default folder for new notes", "Dark fantasy."} {
		if !strings.Contains(sec, want) {
			t.Fatalf("SpaceSectionWithContext missing %q:\n%s", want, sec)
		}
	}
}

func TestSpaceTasksAndChatLinking(t *testing.T) {
	e := newChatEnv(t)
	sp := e.want("POST", "/chat-spaces", map[string]any{"name": "Roadmap"}, http.StatusCreated)
	spID := sp["id"].(string)

	task := e.want("POST", "/chat-spaces/"+spID+"/tasks", map[string]any{"title": "Wire space context dock"}, http.StatusCreated)
	taskID := task["id"].(string)
	if task["done"] != false {
		t.Fatalf("expected open task: %v", task)
	}

	// Creating a chat with task_id links the chat back to the task.
	chat := e.want("POST", "/chats", map[string]any{"space_id": spID, "task_id": taskID, "title": "Build context dock"}, http.StatusCreated)
	tasks := e.want("GET", "/chat-spaces/"+spID+"/tasks", nil, http.StatusOK)["tasks"].([]any)
	if len(tasks) != 1 || tasks[0].(map[string]any)["chat_id"] != chat["id"] {
		t.Fatalf("expected task linked to chat %v, got %v", chat["id"], tasks)
	}

	// Mark task done and verify open_task_count on the space drops to 0.
	e.want("PATCH", "/chat-spaces/"+spID+"/tasks/"+taskID, map[string]any{"done": true}, http.StatusOK)
	gotSpace := e.want("GET", "/chat-spaces/"+spID, nil, http.StatusOK)
	if gotSpace["open_task_count"].(float64) != 0 {
		t.Fatalf("expected open_task_count 0, got %v", gotSpace["open_task_count"])
	}

	// Unspaced GET /chats (default) leaves Space chats out.
	plain := e.want("GET", "/chats?persona_id=all", nil, http.StatusOK)["chats"].([]any)
	if len(plain) != 0 {
		t.Fatalf("expected Space chat excluded from default GET /chats, got %d", len(plain))
	}

	// Branches endpoint responds cleanly.
	branches := e.want("GET", "/chat-spaces/"+spID+"/branches", nil, http.StatusOK)["branches"].([]any)
	if len(branches) != 0 {
		t.Fatalf("expected 0 branches, got %d", len(branches))
	}
}

func TestSpaceBranchesPRStateCorrelationAndSync(t *testing.T) {
	var syncFn func(ctx context.Context, ws, user, space uuid.UUID) error
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.SyncSpacePRs = func(ctx context.Context, ws, user, space uuid.UUID) error {
			if syncFn != nil {
				return syncFn(ctx, ws, user, space)
			}
			return nil
		}
	})
	ctx := context.Background()

	sp1 := e.want("POST", "/chat-spaces", map[string]any{"name": "Vesper"}, http.StatusCreated)
	sp1ID := uuid.MustParse(sp1["id"].(string))
	sp2 := e.want("POST", "/chat-spaces", map[string]any{"name": "Umbra"}, http.StatusCreated)
	sp2ID := uuid.MustParse(sp2["id"].(string))

	c1 := e.want("POST", "/chats", map[string]any{"space_id": sp1ID.String(), "title": "Merged PR chat"}, http.StatusCreated)
	c1ID := uuid.MustParse(c1["id"].(string))
	c2 := e.want("POST", "/chats", map[string]any{"space_id": sp1ID.String(), "title": "Open PR chat"}, http.StatusCreated)
	c2ID := uuid.MustParse(c2["id"].(string))
	c3 := e.want("POST", "/chats", map[string]any{"space_id": sp1ID.String(), "title": "New commits after merge"}, http.StatusCreated)
	c3ID := uuid.MustParse(c3["id"].(string))
	cArchived := e.want("POST", "/chats", map[string]any{"space_id": sp1ID.String(), "title": "Archived chat"}, http.StatusCreated)
	cArchivedID := uuid.MustParse(cArchived["id"].(string))
	cOther := e.want("POST", "/chats", map[string]any{"space_id": sp2ID.String(), "title": "Umbra open PR"}, http.StatusCreated)
	cOtherID := uuid.MustParse(cOther["id"].(string))

	var agentID uuid.UUID
	if err := e.pool.QueryRow(ctx, `SELECT agent_id FROM chat_sessions WHERE id = $1`, c1ID).Scan(&agentID); err != nil {
		t.Fatal(err)
	}
	repo := "https://github.com/liamphmurphy/vesper.git"

	seedBranch := func(chatID uuid.UUID, branch, reviewSHA, pushSHA, state, prState, prURL string, prNum int, dirty bool) uuid.UUID {
		t.Helper()
		if reviewSHA != "" {
			if _, err := e.pool.Exec(ctx,
				`INSERT INTO chat_code_reviews (chat_id, repo_url, branch, head_sha, dirty, live) VALUES ($1,$2,$3,$4,$5,false)`,
				chatID, repo, branch, reviewSHA, dirty); err != nil {
				t.Fatal(err)
			}
		}
		var id uuid.UUID
		if state != "" {
			if err := e.pool.QueryRow(ctx,
				`INSERT INTO push_requests (workspace_id, user_id, chat_id, agent_id, repo_url, branch, head_sha, title, state, pr_state, pr_url, pr_number)
				 VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12) RETURNING id`,
				e.me.WorkspaceID, e.me.ID, chatID, agentID, repo, branch, pushSHA, "PR "+branch, state, prState, prURL, prNum).Scan(&id); err != nil {
				t.Fatal(err)
			}
		}
		return id
	}

	// 1) Merged PR with lingering chat_code_reviews row at the same SHA -> active=false.
	seedBranch(c1ID, "feat/merged-pr", "sha-1", "sha-1", "pushed", "merged", "https://github.com/liamphmurphy/vesper/pull/101", 101, false)
	// 2) Open PR -> active=true.
	openPRID := seedBranch(c2ID, "feat/open-pr", "sha-2", "sha-2", "pushed", "open", "https://github.com/liamphmurphy/vesper/pull/102", 102, false)
	// 3) Merged PR, but chat_code_reviews moved to a newer SHA -> active=true.
	seedBranch(c3ID, "feat/continued", "sha-3-new", "sha-3-old", "pushed", "merged", "https://github.com/liamphmurphy/vesper/pull/103", 103, false)
	// 4) Archived chat with an open PR -> excluded entirely.
	seedBranch(cArchivedID, "feat/archived", "sha-4", "sha-4", "pushed", "open", "https://github.com/liamphmurphy/vesper/pull/104", 104, false)
	if _, err := e.pool.Exec(ctx, `UPDATE chat_sessions SET archived = true WHERE id = $1`, cArchivedID); err != nil {
		t.Fatal(err)
	}
	// 5) Second space's open PR -> appears in GET /chat-spaces/branches with space_name.
	seedBranch(cOtherID, "feat/umbra-pr", "", "sha-5", "pushed", "draft", "https://github.com/liamphmurphy/vesper/pull/105", 105, false)

	// Per-space endpoint returns all non-archived branches with accurate active & pr_state.
	sp1Branches := e.want("GET", "/chat-spaces/"+sp1ID.String()+"/branches", nil, http.StatusOK)["branches"].([]any)
	byBranch := map[string]map[string]any{}
	for _, raw := range sp1Branches {
		b := raw.(map[string]any)
		byBranch[b["branch"].(string)] = b
	}
	if len(byBranch) != 3 {
		t.Fatalf("want 3 non-archived branches in sp1, got %d: %v", len(byBranch), sp1Branches)
	}
	if byBranch["feat/merged-pr"]["active"] != false || byBranch["feat/merged-pr"]["pr_state"] != "merged" {
		t.Fatalf("merged PR with lingering code review should be inactive: %v", byBranch["feat/merged-pr"])
	}
	if byBranch["feat/open-pr"]["active"] != true || byBranch["feat/open-pr"]["pr_state"] != "open" {
		t.Fatalf("open PR should be active: %v", byBranch["feat/open-pr"])
	}
	if byBranch["feat/continued"]["active"] != true {
		t.Fatalf("branch with newer commits after merge should remain active: %v", byBranch["feat/continued"])
	}

	// Cross-space endpoint returns only active branches across all spaces, with space_name populated.
	allActive := e.want("GET", "/chat-spaces/branches", nil, http.StatusOK)["branches"].([]any)
	allNames := map[string]string{}
	for _, raw := range allActive {
		b := raw.(map[string]any)
		if b["active"] != true {
			t.Fatalf("GET /chat-spaces/branches returned inactive branch: %v", b)
		}
		allNames[b["branch"].(string)] = b["space_name"].(string)
	}
	if len(allNames) != 3 || allNames["feat/open-pr"] != "Vesper" || allNames["feat/continued"] != "Vesper" || allNames["feat/umbra-pr"] != "Umbra" {
		t.Fatalf("unexpected cross-space active branches: %v", allNames)
	}

	// On-demand sync endpoint calls SyncSpacePRs and returns updated state.
	syncFn = func(ctx context.Context, ws, user, space uuid.UUID) error {
		if space != sp1ID {
			t.Fatalf("SyncSpacePRs called with wrong space %s", space)
		}
		_, err := e.pool.Exec(ctx, `UPDATE push_requests SET pr_state = 'merged', pr_synced_at = now() WHERE id = $1`, openPRID)
		return err
	}
	synced := e.want("POST", "/chat-spaces/"+sp1ID.String()+"/branches/sync", nil, http.StatusOK)["branches"].([]any)
	for _, raw := range synced {
		b := raw.(map[string]any)
		if b["branch"] == "feat/open-pr" {
			if b["active"] != false || b["pr_state"] != "merged" {
				t.Fatalf("expected feat/open-pr to flip to merged/inactive after sync: %v", b)
			}
		}
	}

	// ChatSpace exposes last_activity_at.
	gotSpace := e.want("GET", "/chat-spaces/"+sp1ID.String(), nil, http.StatusOK)
	if gotSpace["last_activity_at"] == nil || gotSpace["last_activity_at"] == "" {
		t.Fatalf("expected last_activity_at on ChatSpace: %v", gotSpace)
	}
}
