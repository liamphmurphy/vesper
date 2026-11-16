// Package prsync polls GitHub for the state of tickets' pull requests
// (docs/dev/plan.md §6.7). No webhooks: a laptop has no public URL. A merged PR moves
// its ticket to Done; one closed without merging flags the ticket for a
// person. Diff stats replace what agents reported.
package prsync

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"regexp"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/runner"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

type Syncer struct {
	Pool    *pgxpool.Pool
	Secrets runner.Revealer
	Tracker *tracker.Service
	Log     *slog.Logger
	BaseURL string        // https://api.github.com (tests point elsewhere)
	MinAge  time.Duration // don't re-poll a PR more often than this
	HTTP    *http.Client
}

var prURL = regexp.MustCompile(`^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)`)

// PR is what GitHub says about one pull request.
type PR struct {
	State     string `json:"state"` // open | closed
	Merged    bool   `json:"merged"`
	Draft     bool   `json:"draft"`
	Additions int32  `json:"additions"`
	Deletions int32  `json:"deletions"`
}

// Run polls every interval until ctx is cancelled.
func (s *Syncer) Run(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		if n, err := s.Once(ctx); err != nil && ctx.Err() == nil {
			s.Log.Warn("pr sync", "err", err)
		} else if n > 0 {
			s.Log.Info("pr sync", "checked", n)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Once checks every open PR not synced within MinAge; it returns how many.
func (s *Syncer) Once(ctx context.Context) (int, error) {
	q := store.New(s.Pool)
	rows, err := q.TicketsWithOpenPRs(ctx, int32(s.MinAge/time.Second))
	if err != nil {
		return 0, err
	}
	for _, t := range rows {
		if err := s.sync(ctx, q, t); err != nil {
			s.Log.Warn("pr sync", "ticket", t.Key, "err", err)
			_ = q.TouchPRSync(ctx, t.ID) // back off until MinAge passes
		}
	}
	pushRows, err := q.PushRequestsWithOpenPRs(ctx, int32(s.MinAge/time.Second))
	if err != nil {
		return len(rows), err
	}
	for _, p := range pushRows {
		if err := s.syncPushRequest(ctx, q, p); err != nil {
			s.Log.Warn("pr sync", "push_request", p.ID, "err", err)
			_ = q.TouchPushRequestPRSync(ctx, p.ID)
		}
	}
	return len(rows) + len(pushRows), nil
}

func (s *Syncer) fetch(ctx context.Context, token, owner, repo string, n int) (PR, error) {
	base := s.BaseURL
	if base == "" {
		base = "https://api.github.com"
	}
	req, err := http.NewRequestWithContext(ctx, "GET", fmt.Sprintf("%s/repos/%s/%s/pulls/%d", base, owner, repo, n), nil)
	if err != nil {
		return PR{}, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	hc := s.HTTP
	if hc == nil {
		hc = &http.Client{Timeout: 15 * time.Second}
	}
	res, err := hc.Do(req)
	if err != nil {
		return PR{}, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return PR{}, fmt.Errorf("github: %s", res.Status)
	}
	var pr PR
	return pr, json.NewDecoder(res.Body).Decode(&pr)
}

func (s *Syncer) fetchPRState(ctx context.Context, workspaceID uuid.UUID, projectID *uuid.UUID, rawURL string) (PR, int, string, bool, error) {
	m := prURL.FindStringSubmatch(rawURL)
	if m == nil {
		return PR{}, 0, "", false, nil
	}
	n, _ := strconv.Atoi(m[3])
	token := ""
	if s.Secrets != nil {
		token, _ = s.Secrets.Reveal(ctx, workspaceID, projectID, "git:pat") // public repos work without
	}
	pr, err := s.fetch(ctx, token, m[1], m[2], n)
	if err != nil {
		return PR{}, 0, "", true, err
	}
	state := "open"
	switch {
	case pr.Merged:
		state = "merged"
	case pr.State == "closed":
		state = "closed"
	case pr.Draft:
		state = "draft"
	}
	return pr, n, state, true, nil
}

func (s *Syncer) syncPushRequest(ctx context.Context, q *store.Queries, p store.PushRequestsWithOpenPRsRow) error {
	_, _, state, valid, err := s.fetchPRState(ctx, p.WorkspaceID, p.ProjectID, *p.PrUrl)
	if err != nil {
		return err
	}
	if !valid {
		return q.TouchPushRequestPRSync(ctx, p.ID)
	}
	return q.UpdatePushRequestPRSync(ctx, store.UpdatePushRequestPRSyncParams{ID: p.ID, PrState: &state})
}

func (s *Syncer) sync(ctx context.Context, q *store.Queries, t store.TicketsWithOpenPRsRow) error {
	pr, n, state, valid, err := s.fetchPRState(ctx, t.WorkspaceID, &t.ProjectID, *t.PrUrl)
	if err != nil {
		return err
	}
	if !valid {
		return q.TouchPRSync(ctx, t.ID)
	}
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		if err := q.UpdatePRSync(ctx, store.UpdatePRSyncParams{ID: t.ID, PrState: &state, PrAdditions: &pr.Additions,
			PrDeletions: &pr.Deletions, PrClosedUnmerged: state == "closed"}); err != nil {
			return err
		}
		payload := map[string]any{"number": n, "url": *t.PrUrl}
		switch state {
		case "merged":
			return tracker.Record(ctx, q, t.WorkspaceID, t.ID, t.EpicID, tracker.Actor{Type: "system"}, runs.VerbPRMerged, payload, nil)
		case "closed":
			return tracker.Record(ctx, q, t.WorkspaceID, t.ID, t.EpicID, tracker.Actor{Type: "system"}, runs.VerbPRClosed, payload, nil)
		}
		return nil
	})
	if err != nil {
		return err
	}
	if state == "merged" && t.Status != "done" {
		done := "done"
		_, err = s.Tracker.Update(ctx, t.WorkspaceID, tracker.Actor{Type: "system"}, t.Key, tracker.Patch{Status: &done})
		if errors.Is(err, tracker.ErrNotFound) {
			return nil
		}
	}
	return err
}
