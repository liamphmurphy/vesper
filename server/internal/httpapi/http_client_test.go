package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/httpclient"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

func TestHTTPClientCRUDAPI(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	tr := &tracker.Service{Pool: pool}
	rs := &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts}
	h := (&Server{AnonymousAPI: true, Pool: pool, Q: q, Runs: rs, Tracker: tr, Artifacts: arts, Secrets: &secrets.Service{Q: q, Box: testBox(t)}}).Handler()

	do := func(method, path, body string, want int) string {
		t.Helper()
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(method, "/api/v1"+path, strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		h.ServeHTTP(rec, req)
		if rec.Code != want {
			t.Fatalf("%s %s: got %d (%s), want %d", method, path, rec.Code, rec.Body.String(), want)
		}
		return rec.Body.String()
	}

	// Create workspace with seeded nonprod/prod environments.
	raw := do(http.MethodPost, "/http/workspaces", `{"name":"Vesper Core","description":"Core API calls","seed_environments":true,"default_auth":{"type":"bearer","token":"{{api_token}}"}}`, http.StatusCreated)
	var bundle httpclient.WorkspaceBundle
	if err := json.Unmarshal([]byte(raw), &bundle); err != nil {
		t.Fatal(err)
	}
	if bundle.Workspace.Name != "Vesper Core" || len(bundle.Environments) != 2 || bundle.Workspace.ActiveEnvironmentID == nil {
		t.Fatalf("unexpected bundle: %+v", bundle)
	}

	// Switch active environment to prod.
	prodID := bundle.Environments[1].ID
	raw = do(http.MethodPatch, "/http/workspaces/"+bundle.Workspace.ID.String()+"/active-environment", `{"environment_id":"`+prodID.String()+`"}`, http.StatusOK)
	var updatedWS httpclient.Workspace
	if err := json.Unmarshal([]byte(raw), &updatedWS); err != nil {
		t.Fatal(err)
	}
	if updatedWS.ActiveEnvironmentID == nil || *updatedWS.ActiveEnvironmentID != prodID {
		t.Fatalf("active env did not switch to prod: %+v", updatedWS)
	}

	// Create folder + nested subfolder and prevent folder cycle.
	raw = do(http.MethodPost, "/http/workspaces/"+bundle.Workspace.ID.String()+"/folders", `{"name":"Users","default_auth":{"type":"inherit"}}`, http.StatusCreated)
	var rootFolder httpclient.Folder
	if err := json.Unmarshal([]byte(raw), &rootFolder); err != nil {
		t.Fatal(err)
	}
	raw = do(http.MethodPost, "/http/workspaces/"+bundle.Workspace.ID.String()+"/folders", `{"name":"Admin","parent_folder_id":"`+rootFolder.ID.String()+`"}`, http.StatusCreated)
	var subFolder httpclient.Folder
	if err := json.Unmarshal([]byte(raw), &subFolder); err != nil {
		t.Fatal(err)
	}
	do(http.MethodPut, "/http/folders/"+rootFolder.ID.String(), `{"name":"Users","parent_folder_id":"`+subFolder.ID.String()+`"}`, http.StatusUnprocessableEntity)

	// Create and update request inside subfolder.
	raw = do(http.MethodPost, "/http/workspaces/"+bundle.Workspace.ID.String()+"/requests", `{"folder_id":"`+subFolder.ID.String()+`","name":"Sync users","method":"post","url":"{{base_url}}/v1/users/sync","body_mode":"json","body":"{\"dry_run\":false}"}`, http.StatusCreated)
	var reqItem httpclient.Request
	if err := json.Unmarshal([]byte(raw), &reqItem); err != nil {
		t.Fatal(err)
	}
	if reqItem.Method != "POST" || reqItem.Auth.Type != httpclient.AuthInherit {
		t.Fatalf("unexpected request defaults: %+v", reqItem)
	}

	// Workspace bundle reflects folder + request.
	raw = do(http.MethodGet, "/http/workspaces/"+bundle.Workspace.ID.String(), "", http.StatusOK)
	if err := json.Unmarshal([]byte(raw), &bundle); err != nil {
		t.Fatal(err)
	}
	if len(bundle.Folders) != 2 || len(bundle.Requests) != 1 {
		t.Fatalf("expected 2 folders and 1 request, got %d / %d", len(bundle.Folders), len(bundle.Requests))
	}

	// Deleting workspace cascades cleanly.
	do(http.MethodDelete, "/http/workspaces/"+bundle.Workspace.ID.String(), "", http.StatusNoContent)
	do(http.MethodGet, "/http/workspaces/"+bundle.Workspace.ID.String(), "", http.StatusNotFound)
}
