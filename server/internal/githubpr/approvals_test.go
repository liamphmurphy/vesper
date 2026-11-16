package githubpr_test

import (
	"context"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/githubpr"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func review(state, login, at string) map[string]any {
	return map[string]any{"state": state, "submittedAt": at, "author": map[string]any{"login": login}}
}

func pr(n int, draft bool, reviews ...any) map[string]any {
	return map[string]any{
		"number": n, "title": "PR " + string(rune('A'+n)), "url": "https://github.com/o/r/pull/" + string(rune('0'+n)),
		"isDraft": draft, "repository": map[string]any{"nameWithOwner": "o/r"},
		"latestOpinionatedReviews": map[string]any{"nodes": reviews},
	}
}

func fakeGitHub(t *testing.T, nodes []any) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body struct {
			Variables map[string]string `json:"variables"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Variables["q"] != "is:pr is:open author:@me sort:updated-desc" {
			t.Errorf("query = %q", body.Variables["q"])
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"search": map[string]any{"nodes": nodes}}})
	}))
}

func TestListApprovedKeepsOnlyApprovedWithoutChangesRequested(t *testing.T) {
	srv := fakeGitHub(t, []any{
		pr(1, false, review("APPROVED", "ana", "2026-11-16T10:00:00Z")),
		pr(2, false, review("APPROVED", "ana", "2026-11-16T10:00:00Z"), review("CHANGES_REQUESTED", "bo", "2026-11-16T11:00:00Z")),
		pr(3, false, review("COMMENTED", "ana", "2026-11-16T10:00:00Z")),
		pr(4, true, review("APPROVED", "ana", "2026-11-16T10:00:00Z")),
		pr(5, false),
		pr(6, false, review("APPROVED", "ana", "2026-11-16T10:00:00Z"), review("APPROVED", "cy", "2026-11-16T12:00:00Z")),
	})
	defer srv.Close()
	got, err := (&githubpr.Service{BaseURL: srv.URL}).ListApproved(context.Background(), "tok")
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].Number != 1 || got[1].Number != 6 {
		t.Fatalf("got %+v", got)
	}
	if got[0].Approver != "ana" || got[1].Approver != "cy" || !got[1].ApprovedAt.Equal(time.Date(2026, 11, 16, 12, 0, 0, 0, time.UTC)) {
		t.Fatalf("approver/time wrong: %+v", got)
	}
}

type token string

func (k token) Reveal(context.Context, uuid.UUID, *uuid.UUID, string) (string, error) {
	return string(k), nil
}

func TestApprovalSyncerFeedsInbox(t *testing.T) {
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	u, _ := q.GetLocalUser(ctx)
	if _, err := pool.Exec(ctx, `INSERT INTO secrets (workspace_id, name, nonce, ciphertext) VALUES ($1,'git:pat','\x00','\x00')`, u.WorkspaceID); err != nil {
		t.Fatal(err)
	}
	approvedAt := time.Now().Add(-time.Hour).UTC().Format(time.RFC3339)
	srv := fakeGitHub(t, []any{pr(1, false, review("APPROVED", "ana", approvedAt))})
	defer srv.Close()
	sync := &githubpr.ApprovalSyncer{Queries: q, Secrets: token("tok"), GitHub: &githubpr.Service{BaseURL: srv.URL}, Log: slog.New(slog.NewTextHandler(io.Discard, nil))}
	for range 2 { // polling again must not add a second item
		if err := sync.Once(ctx); err != nil {
			t.Fatal(err)
		}
	}
	rows, err := q.ListInbox(ctx, store.ListInboxParams{UserID: u.ID, WorkspaceID: u.WorkspaceID})
	if err != nil {
		t.Fatal(err)
	}
	var found []store.ListInboxRow
	for _, r := range rows {
		if r.Kind == "pr_approved" {
			found = append(found, r)
		}
	}
	if len(found) != 1 {
		t.Fatalf("pr_approved items = %d, want 1", len(found))
	}
	if found[0].Href != "https://github.com/o/r/pull/1" || found[0].Summary != "Pull request o/r#1 approved by ana" || found[0].Resolved {
		t.Fatalf("item = %+v", found[0])
	}
}
