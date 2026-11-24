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
