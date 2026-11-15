package httpapi

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestAppChatsStayInTheirApps(t *testing.T) {
	e := newChatEnv(t)
	ctx := t.Context()
	persona := e.want("POST", "/personas", map[string]any{"name": "Historian"}, http.StatusCreated)["id"].(string)
	plain := e.newChat(map[string]any{"title": "apphistory normal", "persona_id": persona})["id"].(string)
	e.addReply(t, plain, "apphistory normal reply")
	knowledge := e.newChat(map[string]any{"title": "apphistory knowledge", "hidden": true, "persona_id": persona})["id"].(string)
	e.addReply(t, knowledge, "apphistory Knowledge reply")
	e.want("GET", "/chats/"+knowledge+"/messages", nil, http.StatusOK)
	for _, app := range []string{"docs", "slides", "designs"} {
		space, err := e.q.CreateAppSpace(ctx, store.CreateAppSpaceParams{WorkspaceID: e.me.WorkspaceID, UserID: e.me.ID, Name: app, Color: "blue", AppName: app})
		if err != nil {
			t.Fatal(err)
		}
		chat := e.newChat(map[string]any{"title": "apphistory " + app, "space_id": space.ID, "persona_id": persona})["id"].(string)
		e.addReply(t, chat, "apphistory app reply")
		// App screens can resume and list their conversations, including old ones.
		e.want("GET", "/chats/"+chat, nil, http.StatusOK)
		e.want("GET", "/chats/"+chat+"/messages", nil, http.StatusOK)
		inApp := ids(e.want("GET", "/chats?persona_id=all&space="+space.ID.String(), nil, http.StatusOK)["chats"], "id")
		if !slices.Contains(inApp, chat) {
			t.Fatalf("%s chat missing inside app: %v", app, inApp)
		}
	}
	for _, archived := range []bool{false, true} {
		for _, scope := range []string{"", "&space=all"} {
			path := "/chats?persona_id=all" + scope
			if archived {
				path += "&archived=true"
			}
			listed := ids(e.want("GET", path, nil, http.StatusOK)["chats"], "id")
			if len(listed) != 1 || listed[0] != plain {
				t.Fatalf("%s = %v, want only normal chat", path, listed)
			}
		}
		if !archived {
			counts, err := e.q.PersonaChatCounts(ctx, []uuid.UUID{uuid.MustParse(persona)})
			if err != nil || len(counts) != 1 || counts[0].N != 1 {
				t.Fatalf("personal chat counts = %v, %v", counts, err)
			}
			chat, err := e.q.GetChatSession(ctx, store.GetChatSessionParams{ID: uuid.MustParse(plain), WorkspaceID: e.me.WorkspaceID})
			if err != nil {
				t.Fatal(err)
			}
			legacy, err := e.q.ListChatSessions(ctx, store.ListChatSessionsParams{WorkspaceID: e.me.WorkspaceID, ProjectID: chat.ProjectID, CreatedBy: e.me.ID, Limit: 50})
			if err != nil || len(legacy) != 1 || legacy[0].ID != chat.ID {
				t.Fatalf("project chat list = %v, %v", legacy, err)
			}
			search := e.want("GET", "/chat-search?q=apphistory", nil, http.StatusOK)["hits"].([]any)
			if len(search) != 1 || search[0].(map[string]any)["chat_id"] != plain {
				t.Fatalf("conversation search = %v", search)
			}
			for _, hit := range e.want("GET", "/search?q=apphistory", nil, http.StatusOK)["hits"].([]any) {
				row := hit.(map[string]any)["target"].(map[string]any)
				if row["kind"] == "chat" && !strings.HasPrefix(row["href"].(string), "/chat/"+plain) {
					t.Fatalf("app chat in global search: %v", row)
				}
			}
			dock, err := e.q.PersonaDockChats(ctx, store.PersonaDockChatsParams{WorkspaceID: e.me.WorkspaceID, CreatedBy: e.me.ID})
			if err != nil || len(dock) != 1 || dock[0].ID != uuid.MustParse(plain) {
				t.Fatalf("dock = %v, %v", dock, err)
			}
			if _, err := e.pool.Exec(ctx, `UPDATE chat_sessions SET archived=true WHERE created_by=$1`, e.me.ID); err != nil {
				t.Fatal(err)
			}
		}
	}
}

func TestPersonaDockChatsAssistantSeqAndProposalIndex(t *testing.T) {
	e := newChatEnv(t)
	ctx := context.Background()

	var agentID uuid.UUID
	if err := e.pool.QueryRow(ctx, `SELECT id FROM agents WHERE workspace_id=$1 LIMIT 1`, e.me.WorkspaceID).Scan(&agentID); err != nil {
		t.Fatal(err)
	}
	var chatID uuid.UUID
	if err := e.pool.QueryRow(ctx, `
		INSERT INTO chat_sessions (workspace_id, title, created_by, agent_id, harness, model)
		VALUES ($1, 'Dock Sync', $2, $3, 'codex', 'm') RETURNING id`,
		e.me.WorkspaceID, e.me.ID, agentID).Scan(&chatID); err != nil {
		t.Fatal(err)
	}

	// Inserting a user message alone leaves last_assistant_seq = 0 (not in dock).
	if _, err := e.pool.Exec(ctx, `INSERT INTO chat_messages (session_id, seq, role, body_md) VALUES ($1, 1, 'user', 'hi')`, chatID); err != nil {
		t.Fatal(err)
	}
	dock, err := e.q.PersonaDockChats(ctx, store.PersonaDockChatsParams{WorkspaceID: e.me.WorkspaceID, CreatedBy: e.me.ID})
	if err != nil {
		t.Fatal(err)
	}
	if len(dock) != 0 {
		t.Fatalf("expected empty dock after user-only message, got %d items", len(dock))
	}

	// Assistant reply sets last_assistant_seq = 2 and surfaces chat in dock.
	if _, err := e.pool.Exec(ctx, `INSERT INTO chat_messages (session_id, seq, role, body_md) VALUES ($1, 2, 'assistant', 'first reply')`, chatID); err != nil {
		t.Fatal(err)
	}
	dock, err = e.q.PersonaDockChats(ctx, store.PersonaDockChatsParams{WorkspaceID: e.me.WorkspaceID, CreatedBy: e.me.ID})
	if err != nil || len(dock) != 1 || dock[0].ID != chatID || dock[0].Unread != 1 || dock[0].LastSeq != 2 {
		t.Fatalf("after assistant #1: dock = %+v, err = %v", dock, err)
	}

	// Marking read hides the chat from the dock.
	if err := e.q.MarkChatRead(ctx, store.MarkChatReadParams{ID: chatID, Seq: 2}); err != nil {
		t.Fatal(err)
	}
	dock, err = e.q.PersonaDockChats(ctx, store.PersonaDockChatsParams{WorkspaceID: e.me.WorkspaceID, CreatedBy: e.me.ID})
	if err != nil || len(dock) != 0 {
		t.Fatalf("after MarkChatRead(2): dock = %+v, err = %v", dock, err)
	}

	// Second assistant reply advances last_assistant_seq = 3 and re-surfaces chat.
	if _, err := e.pool.Exec(ctx, `
		INSERT INTO chat_messages (session_id, seq, role, body_md)
		VALUES ($1, 3, 'assistant', 'second reply')`, chatID); err != nil {
		t.Fatal(err)
	}
	dock, err = e.q.PersonaDockChats(ctx, store.PersonaDockChatsParams{WorkspaceID: e.me.WorkspaceID, CreatedBy: e.me.ID})
	if err != nil || len(dock) != 1 || dock[0].Unread != 1 || dock[0].LastSeq != 3 {
		t.Fatalf("after assistant #2: dock = %+v, err = %v", dock, err)
	}

	// DeleteChatMessagesAfter removes seq=3; delete trigger resyncs last_assistant_seq back to 2
	// so the already-read chat disappears from the dock again.
	if err := e.q.DeleteChatMessagesAfter(ctx, store.DeleteChatMessagesAfterParams{SessionID: chatID, Seq: 2}); err != nil {
		t.Fatal(err)
	}
	var syncedSeq int64
	if err := e.pool.QueryRow(ctx, `SELECT last_assistant_seq FROM chat_sessions WHERE id=$1`, chatID).Scan(&syncedSeq); err != nil {
		t.Fatal(err)
	}
	if syncedSeq != 2 {
		t.Fatalf("last_assistant_seq after DeleteChatMessagesAfter = %d, want 2", syncedSeq)
	}
	dock, err = e.q.PersonaDockChats(ctx, store.PersonaDockChatsParams{WorkspaceID: e.me.WorkspaceID, CreatedBy: e.me.ID})
	if err != nil || len(dock) != 0 {
		t.Fatalf("after DeleteChatMessagesAfter(2): dock = %+v, err = %v", dock, err)
	}

	// Pending persona proposal surfaces an otherwise-read chat via Branch 2 (waiting_approval).
	if _, err := e.pool.Exec(ctx, `
		INSERT INTO persona_proposals (chat_id, name, tone, color, state)
		VALUES ($1, 'Helper', 'concise', '#123456', 'pending')`, chatID); err != nil {
		t.Fatal(err)
	}
	dock, err = e.q.PersonaDockChats(ctx, store.PersonaDockChatsParams{WorkspaceID: e.me.WorkspaceID, CreatedBy: e.me.ID})
	if err != nil || len(dock) != 1 || dock[0].ID != chatID || !dock[0].WaitingApproval {
		t.Fatalf("with pending proposal: dock = %+v, err = %v", dock, err)
	}

	// Verify Postgres query planner uses the new partial index when seqscans are disabled.
	tx, err := e.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx)
	if _, err := tx.Exec(ctx, `SET LOCAL enable_seqscan = off`); err != nil {
		t.Fatal(err)
	}
	rows, err := tx.Query(ctx, `
		EXPLAIN (FORMAT TEXT)
		WITH candidates AS (
		  SELECT c.id FROM chat_sessions c
		  WHERE c.workspace_id = $1 AND c.created_by = $2 AND NOT c.archived AND NOT c.hidden
		    AND (c.state = 'running' OR c.last_assistant_seq > c.last_read_seq)
		  UNION
		  SELECT pp.chat_id AS id FROM persona_proposals pp WHERE pp.state = 'pending'
		  UNION
		  SELECT tc.chat_id AS id FROM ticket_change_requests tc WHERE tc.state = 'pending'
		  UNION
		  SELECT ctr.chat_id AS id FROM runs r
		  JOIN chat_ticket_runs ctr ON ctr.run_id = r.id
		  WHERE r.workspace_id = $1 AND r.state = 'waiting' AND r.wait_reason IN ('human_reply', 'approval')
		)
		SELECT c.id FROM candidates cand
		JOIN chat_sessions c ON c.id = cand.id
		WHERE c.workspace_id = $1 AND c.created_by = $2 AND NOT c.archived AND NOT c.hidden`,
		e.me.WorkspaceID, e.me.ID)
	if err != nil {
		t.Fatal(err)
	}
	var planLines []string
	for rows.Next() {
		var line string
		if err := rows.Scan(&line); err != nil {
			t.Fatal(err)
		}
		planLines = append(planLines, line)
	}
	rows.Close()
	if err := rows.Err(); err != nil {
		t.Fatal(err)
	}
	plan := strings.Join(planLines, "\n")
	if !strings.Contains(plan, "chat_sessions_dock_active_idx") {
		t.Fatalf("expected chat_sessions_dock_active_idx in EXPLAIN plan, got:\n%s", plan)
	}
}
