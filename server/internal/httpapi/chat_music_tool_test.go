package httpapi

import (
	"bytes"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/fake"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// generate_music works in non-coding chats too, enforces the per-turn limit,
// saves finished tracks to the Library linked to the chat run/turn, and
// returns structured failure details on provider errors (429/403).
func TestGenerateMusicTool(t *testing.T) {
	ctx := t.Context()
	reg := media.NewRegistry()
	ctrl := &fake.Controller{}
	fake.Register(reg, ctrl)
	media.RegisterLocalMLXPlaceholder(reg)

	blobs := newFakeBlobs(t)
	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	if err != nil {
		t.Fatal(err)
	}

	var srv *Server
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: box}
		s.MediaRegistry = reg
		s.Blobs = blobs.Store
		s.ArtifactBucket = avatarBucket
		srv = s
	})
	t.Cleanup(func() {
		if srv != nil {
			srv.CloseMedia()
		}
	})

	callTool := func(token string, args any) (int, map[string]any) {
		t.Helper()
		raw, _ := json.Marshal(args)
		req := httptest.NewRequest(http.MethodPost, "/api/v1/agent/tools/generate_music", bytes.NewReader(raw))
		req.Header.Set("Authorization", "Bearer "+token)
		w := httptest.NewRecorder()
		srv.Handler().ServeHTTP(w, req)
		var out map[string]any
		_ = json.Unmarshal(w.Body.Bytes(), &out)
		return w.Code, out
	}

	// Non-coding chat (Built-in Personal Assistant / default non-code chat).
	chat, err := e.runs.StartChat(ctx, e.me.WorkspaceID, e.me.ID, runs.ChatInput{Project: "PAY"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.runs.PostChatMessage(ctx, e.me.WorkspaceID, e.me.ID, chat.ID, runs.ChatMessageInput{Body: "make me a synth track"}); err != nil {
		t.Fatal(err)
	}
	chat, _ = e.q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: e.me.WorkspaceID})
	runID := *chat.CurrentRunID
	assistant, _ := e.q.GetAgent(ctx, store.GetAgentParams{ID: chat.AgentID, WorkspaceID: e.me.WorkspaceID})
	token, _, err := agents.IssueToken(ctx, e.q, assistant.ID, "run", "chat", &runID, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, "UPDATE runs SET state='running' WHERE id=$1", runID); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, "UPDATE run_turns SET status='running' WHERE run_id=$1", runID); err != nil {
		t.Fatal(err)
	}

	// Unconfigured provider returns 409 Conflict.
	code, out := callTool(token, map[string]any{"prompt": "warm synthwave"})
	if code != http.StatusConflict {
		t.Fatalf("unconfigured generate_music = %d %v, want 409", code, out)
	}

	// Configure fake provider and set as active music default.
	e.want("PUT", "/media/providers/fake", map[string]any{
		"secrets": map[string]any{"api_key": "fake-secret"},
	}, http.StatusOK)
	e.want("PUT", "/media/defaults/music", map[string]any{"provider_id": "fake"}, http.StatusOK)

	// Happy path inside non-coding chat turn.
	code, out = callTool(token, map[string]any{
		"title":        "Midnight Arp",
		"prompt":       "warm analog synth arp at 105 bpm",
		"instrumental": true,
		"length":       "clip",
	})
	if code != http.StatusOK || out["state"] != "done" || out["library_item_id"] == nil {
		t.Fatalf("generate_music happy = %d %v", code, out)
	}

	// Verify run_id and turn_id were recorded on the chat_audio_jobs row.
	var linked int
	if err := e.pool.QueryRow(ctx, `SELECT count(*)::int FROM chat_audio_jobs WHERE run_id=$1 AND turn_id IS NOT NULL AND source_kind='music' AND state='done'`, runID).Scan(&linked); err != nil {
		t.Fatal(err)
	}
	if linked != 1 {
		t.Fatalf("linked music jobs = %d, want 1", linked)
	}

	// Provider 429 quota failure creates failed job and returns structured error info.
	ctrl.GenerateErr = &media.ProviderError{Provider: "fake", Kind: media.ErrKindQuota, Message: "Gemini quota exhausted."}
	code, out = callTool(token, map[string]any{"prompt": "upbeat lo-fi"})
	if code != http.StatusOK || out["state"] != "failed" || out["error_kind"] != "quota" {
		t.Fatalf("quota error tool response = %d %v", code, out)
	}

	// 3rd call succeeds (count=3 == MaxChatAudioJobsPerTurn); 4th call hits per-turn cap (409).
	ctrl.GenerateErr = nil
	code, out = callTool(token, map[string]any{"prompt": "third track"})
	if code != http.StatusOK || out["state"] != "done" {
		t.Fatalf("third generate_music = %d %v", code, out)
	}
	code, out = callTool(token, map[string]any{"prompt": "fourth track"})
	if code != http.StatusConflict {
		t.Fatalf("4th generate_music = %d %v, want 409", code, out)
	}
}
