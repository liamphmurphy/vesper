package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/customapps"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

type stubCustomAppVM struct {
	state        customapps.VMState
	stops        int
	restarts     int
	windowClosed int
	lastAppID    uuid.UUID
}

func (s *stubCustomAppVM) StartAppVMProcess(context.Context, customapps.VMExecRequest) (customapps.VMProcess, error) {
	return nil, nil
}
func (s *stubCustomAppVM) ReadAppVMFile(context.Context, customapps.VMAppSpec, string, int64) ([]byte, error) {
	return nil, nil
}
func (s *stubCustomAppVM) UnlinkAppVMPaths(context.Context, customapps.VMAppSpec, []string, bool) error {
	return nil
}
func (s *stubCustomAppVM) SyncAppVMPolicy(context.Context, customapps.VMAppSpec) error {
	return nil
}
func (s *stubCustomAppVM) AppVMStatus(id uuid.UUID) customapps.VMStatus {
	s.lastAppID = id
	return customapps.VMStatus{Available: true, State: s.state}
}
func (s *stubCustomAppVM) StopAppVM(_ context.Context, id uuid.UUID) error {
	s.lastAppID = id
	s.stops++
	s.state = customapps.VMStateStopped
	return nil
}
func (s *stubCustomAppVM) RestartAppVM(_ context.Context, app customapps.VMAppSpec) error {
	s.lastAppID = app.AppID
	s.restarts++
	s.state = customapps.VMStateRunning
	return nil
}
func (s *stubCustomAppVM) DeleteAppVM(context.Context, uuid.UUID) error { return nil }
func (s *stubCustomAppVM) NotifyAppWindowClosed(id uuid.UUID) {
	s.lastAppID = id
	s.windowClosed++
}

func TestCustomAppVMEndpoints(t *testing.T) {
	pool := testdb.New(t)
	if _, err := seed.Run(context.Background(), pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	srv := &Server{
		Pool:         pool,
		Q:            store.New(pool),
		AnonymousAPI: true,
	}
	defer srv.CloseCustomApps()
	h := srv.Handler()

	// Create a custom app first.
	bodyBytes, _ := json.Marshal(map[string]any{
		"slug":  "vm-status-test",
		"name":  "VM Status Test",
		"files": map[string]string{"app.tsx": "export default function App() { return null; }"},
	})
	createReq := httptest.NewRequest(http.MethodPost, "/api/v1/custom-apps", bytes.NewReader(bodyBytes))
	createReq.Header.Set("Content-Type", "application/json")
	createRec := httptest.NewRecorder()
	h.ServeHTTP(createRec, createReq)
	if createRec.Code != http.StatusCreated {
		t.Fatalf("create app: %d %s", createRec.Code, createRec.Body.String())
	}

	readVMStatus := func(method, path string) customapps.VMStatus {
		t.Helper()
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(method, path, nil))
		if rec.Code != http.StatusOK {
			t.Fatalf("%s %s: %d %s", method, path, rec.Code, rec.Body.String())
		}
		var st customapps.VMStatus
		if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
			t.Fatalf("decode %s: %v", rec.Body.String(), err)
		}
		return st
	}

	// Without a VM backend attached, GET /vm returns available=false, state=stopped.
	if st := readVMStatus(http.MethodGet, "/api/v1/custom-apps/vm-status-test/vm"); st.Available || st.State != customapps.VMStateStopped {
		t.Fatalf("without backend: got %+v", st)
	}

	// Attach VM backend dynamically.
	stub := &stubCustomAppVM{state: customapps.VMStatePaused}
	srv.SetCustomAppVM(stub)

	if st := readVMStatus(http.MethodGet, "/api/v1/custom-apps/vm-status-test/vm"); !st.Available || st.State != customapps.VMStatePaused {
		t.Fatalf("with backend: got %+v", st)
	}

	// Restart -> running.
	if st := readVMStatus(http.MethodPost, "/api/v1/custom-apps/vm-status-test/vm/restart"); st.State != customapps.VMStateRunning || stub.restarts != 1 {
		t.Fatalf("after restart: st=%+v restarts=%d", st, stub.restarts)
	}

	// Stop -> stopped.
	if st := readVMStatus(http.MethodPost, "/api/v1/custom-apps/vm-status-test/vm/stop"); st.State != customapps.VMStateStopped || stub.stops != 1 {
		t.Fatalf("after stop: st=%+v stops=%d", st, stub.stops)
	}

	// Window closed -> 204 No Content.
	closeRec := httptest.NewRecorder()
	h.ServeHTTP(closeRec, httptest.NewRequest(http.MethodPost, "/api/v1/custom-apps/vm-status-test/vm/window-closed", nil))
	if closeRec.Code != http.StatusNoContent || stub.windowClosed != 1 {
		t.Fatalf("POST /vm/window-closed: code=%d count=%d", closeRec.Code, stub.windowClosed)
	}
}
