package githubpr_test

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/githubpr"
)

func TestListReviewRequestsClassifiesAndCaches(t *testing.T) {
	var calls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls.Add(1)
		if r.URL.Path != "/graphql" || r.Method != http.MethodPost {
			t.Fatalf("unexpected %s %s", r.Method, r.URL.Path)
		}
		if got := r.Header.Get("Authorization"); got != "Bearer ghp_test" {
			t.Fatalf("auth = %q", got)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": map[string]any{
				"viewer": map[string]any{"login": "Liam"},
				"search": map[string]any{
					"nodes": []any{
						map[string]any{
							"number":    414,
							"title":     "feat: code review dock",
							"url":       "https://github.com/liamphmurphy/vesper/pull/414",
							"isDraft":   false,
							"additions": 412,
							"deletions": 89,
							"createdAt": "2026-11-16T12:00:00Z",
							"updatedAt": "2026-11-16T13:00:00Z",
							"repository": map[string]any{
								"nameWithOwner": "liamphmurphy/vesper",
							},
							"author": map[string]any{
								"login":     "alex",
								"avatarUrl": "https://avatars.githubusercontent.com/u/1?v=4",
							},
							"reviewRequests": map[string]any{
								"nodes": []any{
									map[string]any{"requestedReviewer": map[string]any{"__typename": "User", "login": "liam"}},
								},
							},
						},
						map[string]any{
							"number":    19,
							"title":     "chore: bump nix",
							"url":       "https://github.com/liamphmurphy/os-setup/pull/19",
							"isDraft":   true,
							"additions": 12,
							"deletions": 12,
							"createdAt": "2026-11-15T12:00:00Z",
							"updatedAt": "2026-11-16T08:00:00Z",
							"repository": map[string]any{
								"nameWithOwner": "liamphmurphy/os-setup",
							},
							"author": nil,
							"reviewRequests": map[string]any{
								"nodes": []any{
									map[string]any{"requestedReviewer": map[string]any{"__typename": "Team", "slug": "platform"}},
									map[string]any{"requestedReviewer": map[string]any{"__typename": "Team", "slug": "platform"}},
								},
							},
						},
					},
				},
			},
		})
	}))
	defer srv.Close()

	now := time.Date(2026, 11, 16, 13, 30, 0, 0, time.UTC)
	svc := &githubpr.Service{
		BaseURL: srv.URL,
		TTL:     time.Minute,
		Now:     func() time.Time { return now },
	}
	ws := uuid.New()

	feed, err := svc.ListReviewRequests(context.Background(), ws, "ghp_test", false)
	if err != nil {
		t.Fatalf("ListReviewRequests: %v", err)
	}
	if calls.Load() != 1 {
		t.Fatalf("calls = %d, want 1", calls.Load())
	}
	if feed.ViewerLogin != "Liam" || len(feed.Items) != 2 {
		t.Fatalf("unexpected feed: %+v", feed)
	}
	first := feed.Items[0]
	if first.ID != "liamphmurphy/vesper#414" || !first.Direct || first.Team || first.AuthorLogin != "alex" {
		t.Fatalf("first item = %+v", first)
	}
	second := feed.Items[1]
	if second.Direct || !second.Team || !second.Draft || second.AuthorLogin != "ghost" || len(second.Teams) != 1 || second.Teams[0] != "@platform" {
		t.Fatalf("second item = %+v", second)
	}

	// Second call within TTL uses cache.
	if _, err := svc.ListReviewRequests(context.Background(), ws, "ghp_test", false); err != nil {
		t.Fatalf("cached call: %v", err)
	}
	if calls.Load() != 1 {
		t.Fatalf("calls after cache hit = %d, want 1", calls.Load())
	}

	// Refresh bypasses cache.
	if _, err := svc.ListReviewRequests(context.Background(), ws, "ghp_test", true); err != nil {
		t.Fatalf("refresh call: %v", err)
	}
	if calls.Load() != 2 {
		t.Fatalf("calls after refresh = %d, want 2", calls.Load())
	}
}

func TestListReviewRequestsHandlesErrors(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusUnauthorized)
		_ = json.NewEncoder(w).Encode(map[string]string{"message": "Bad credentials"})
	}))
	defer srv.Close()

	svc := &githubpr.Service{BaseURL: srv.URL}
	if _, err := svc.ListReviewRequests(context.Background(), uuid.New(), "bad", false); err == nil {
		t.Fatal("expected error on 401")
	}
}
