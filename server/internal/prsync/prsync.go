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

	"github.com/liamphmurphy/vesper/server/internal/pushreq"
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
	Head      struct {
		SHA string `json:"sha"`
		Ref string `json:"ref"`
	} `json:"head"`
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

func (s *Syncer) fetch(ctx context.Context, token, owner, repo string, n int, prevETag string) (pr PR, newETag string, notModified bool, err error) {
	url := fmt.Sprintf("%s/repos/%s/%s/pulls/%d", s.baseURL(), owner, repo, n)
	status, newETag, raw, err := s.doConditionalGET(ctx, url, token, prevETag)
	if err != nil {
		return PR{}, "", false, err
	}
	if status == http.StatusNotModified {
		return PR{}, prevETag, true, nil
	}
	return pr, newETag, false, json.Unmarshal(raw, &pr)
}

type prFetchResult struct {
	pr          PR
	owner       string
	repo        string
	number      int
	state       string
	token       string
	etag        string
	notModified bool
	valid       bool
}

func (s *Syncer) fetchPRState(ctx context.Context, workspaceID uuid.UUID, projectID *uuid.UUID, rawURL, prevETag, prevState string) (prFetchResult, error) {
	m := prURL.FindStringSubmatch(rawURL)
	if m == nil {
		return prFetchResult{}, nil
	}
	n, _ := strconv.Atoi(m[3])
	token := ""
	if s.Secrets != nil {
		token, _ = s.Secrets.Reveal(ctx, workspaceID, projectID, "git:pat") // public repos work without
	}
	pr, newETag, notModified, err := s.fetch(ctx, token, m[1], m[2], n, prevETag)
	if err != nil {
		return prFetchResult{valid: true}, err
	}
	state := prevState
	if state == "" {
		state = "open"
	}
	if !notModified {
		state = "open"
		switch {
		case pr.Merged:
			state = "merged"
		case pr.State == "closed":
			state = "closed"
		case pr.Draft:
			state = "draft"
		}
	}
	return prFetchResult{
		pr:          pr,
		owner:       m[1],
		repo:        m[2],
		number:      n,
		state:       state,
		token:       token,
		etag:        newETag,
		notModified: notModified,
		valid:       true,
	}, nil
}

func derefStr(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

func (s *Syncer) syncPushRequest(ctx context.Context, q *store.Queries, p store.PushRequestsWithOpenPRsRow) error {
	prevFB, hasPrev := s.loadPrevFeedback(ctx, q, p.WorkspaceID, *p.PrUrl)
	prevETag := ""
	if hasPrev {
		prevETag = prevFB.PrEtag
	}
	res, err := s.fetchPRState(ctx, p.WorkspaceID, p.ProjectID, *p.PrUrl, prevETag, derefStr(p.PrState))
	if err != nil {
		return err
	}
	if !res.valid {
		return q.TouchPushRequestPRSync(ctx, p.ID)
	}
	headSHA := prevFB.HeadSha
	if res.notModified {
		if err := q.TouchPushRequestPRSync(ctx, p.ID); err != nil {
			return err
		}
	} else {
		headSHA = res.pr.Head.SHA
		if err := q.UpdatePushRequestPRSync(ctx, store.UpdatePushRequestPRSyncParams{ID: p.ID, PrState: &res.state}); err != nil {
			return err
		}
		if (res.state == "open" || res.state == "draft" || res.state == "merged") && res.token != "" && headSHA != "" {
			gh := &pushreq.GitHub{BaseURL: s.BaseURL, HTTP: s.HTTP, Token: res.token}
			if _, cerr := pushreq.CleanupChatCheckpointsAtPR(ctx, gh, q, p.ChatID, p.RepoUrl, *p.PrUrl, p.Branch, headSHA, p.RunID, true); cerr != nil {
				s.Log.Warn("cleanup chat checkpoints", "push_request", p.ID, "err", cerr)
			}
		}
	}
	s.syncFeedback(ctx, q, p.WorkspaceID, prevFB, hasPrev, res.token, res.owner, res.repo, res.number, *p.PrUrl, res.state, headSHA, res.etag, res.notModified)
	return nil
}

func (s *Syncer) sync(ctx context.Context, q *store.Queries, t store.TicketsWithOpenPRsRow) error {
	prevFB, hasPrev := s.loadPrevFeedback(ctx, q, t.WorkspaceID, *t.PrUrl)
	prevETag := ""
	if hasPrev {
		prevETag = prevFB.PrEtag
	}
	res, err := s.fetchPRState(ctx, t.WorkspaceID, &t.ProjectID, *t.PrUrl, prevETag, derefStr(t.PrState))
	if err != nil {
		return err
	}
	if !res.valid {
		return q.TouchPRSync(ctx, t.ID)
	}
	headSHA := prevFB.HeadSha
	if res.notModified {
		if err := q.TouchPRSync(ctx, t.ID); err != nil {
			return err
		}
	} else {
		headSHA = res.pr.Head.SHA
		err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
			q := store.New(tx)
			if err := q.UpdatePRSync(ctx, store.UpdatePRSyncParams{ID: t.ID, PrState: &res.state, PrAdditions: &res.pr.Additions,
				PrDeletions: &res.pr.Deletions, PrClosedUnmerged: res.state == "closed"}); err != nil {
				return err
			}
			payload := map[string]any{"number": res.number, "url": *t.PrUrl}
			switch res.state {
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
		if res.state == "merged" && t.Status != "done" {
			done := "done"
			_, err = s.Tracker.Update(ctx, t.WorkspaceID, tracker.Actor{Type: "system"}, t.Key, tracker.Patch{Status: &done})
			if errors.Is(err, tracker.ErrNotFound) {
				err = nil
			}
			if err != nil {
				return err
			}
		}
		if (res.state == "open" || res.state == "draft" || res.state == "merged") && res.token != "" && headSHA != "" {
			gh := &pushreq.GitHub{BaseURL: s.BaseURL, HTTP: s.HTTP, Token: res.token}
			if _, cerr := pushreq.CleanupTicketCheckpoints(ctx, gh, q, t.ID, *t.PrUrl, res.pr.Head.Ref, headSHA, nil, false, true); cerr != nil {
				s.Log.Warn("cleanup ticket checkpoints", "ticket", t.Key, "err", cerr)
			}
		}
	}
	s.syncFeedback(ctx, q, t.WorkspaceID, prevFB, hasPrev, res.token, res.owner, res.repo, res.number, *t.PrUrl, res.state, headSHA, res.etag, res.notModified)
	return nil
}
