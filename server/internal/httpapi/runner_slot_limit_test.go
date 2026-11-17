package httpapi

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func TestRunnerSlotLimitCapsAndLifts(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	if _, err := seed.Run(ctx, pool, seed.Options{}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	for _, id := range []string{"runner-a", "runner-b"} {
		if err := q.Heartbeat(ctx, store.HeartbeatParams{ID: id, Backend: "fake", MaxConcurrent: 4}); err != nil {
			t.Fatal(err)
		}
	}
	h := (&Server{AnonymousAPI: true, Pool: pool, Q: q}).Handler()
	put := func(body string) (int, api.RunnerStatus) {
		t.Helper()
		rec := httptest.NewRecorder()
		req := httptest.NewRequest("PUT", "/api/v1/runner/slot-limit", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		h.ServeHTTP(rec, req)
		var st api.RunnerStatus
		if rec.Code == 200 {
			if err := json.Unmarshal(rec.Body.Bytes(), &st); err != nil {
				t.Fatal(err)
			}
		}
		return rec.Code, st
	}

	code, st := put(`{"limit": 1}`)
	if code != 200 || st.Slots != 2 {
		t.Fatalf("capped: %d slots=%d, want 200 and 1 per runner", code, st.Slots)
	}
	for _, r := range st.Runners {
		if r.SlotLimit == nil || *r.SlotLimit != 1 || r.MaxConcurrent != 4 {
			t.Fatalf("runner %s: %+v", r.Id, r)
		}
	}
	// A heartbeat (the runner's upsert) must keep the cap, not reset it.
	if err := q.Heartbeat(ctx, store.HeartbeatParams{ID: "runner-a", Backend: "fake", MaxConcurrent: 4, Running: 1}); err != nil {
		t.Fatal(err)
	}
	if got, err := q.RunnerSlotLimit(ctx, "runner-a"); err != nil || got == nil || *got != 1 {
		t.Fatalf("after heartbeat: %v %v", got, err)
	}

	code, st = put(`{"limit": null}`)
	if code != 200 || st.Slots != 8 || st.Runners[0].SlotLimit != nil {
		t.Fatalf("lifted: %d %+v", code, st)
	}

	for _, bad := range []string{`{"limit": 0}`, `{"limit": 33}`, `{}`} {
		if code, _ := put(bad); code != 422 && code != 400 {
			t.Fatalf("%s: got %d, want a 4xx", bad, code)
		}
	}
}
