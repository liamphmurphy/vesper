package prsync

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	maxFailedChecks    = 20
	maxReviewThreads   = 25
	maxThreadComments  = 10
	maxFeedbackTextLen = 1500
	maxDiffHunkLen     = 800
)

// FailedCheck summarizes one failing GitHub check run on a PR's head commit.
type FailedCheck struct {
	Name       string `json:"name"`
	Conclusion string `json:"conclusion"`
	DetailsURL string `json:"details_url,omitempty"`
	Title      string `json:"title,omitempty"`
	Summary    string `json:"summary,omitempty"`
}

// ReviewComment is one comment in a pull request review thread.
type ReviewComment struct {
	Author    string    `json:"author"`
	Body      string    `json:"body"`
	URL       string    `json:"url,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// ReviewThread is one unresolved inline review conversation on a PR.
type ReviewThread struct {
	ID        string          `json:"id"`
	Path      string          `json:"path"`
	Line      int             `json:"line,omitempty"`
	URL       string          `json:"url,omitempty"`
	DiffHunk  string          `json:"diff_hunk,omitempty"`
	Outdated  bool            `json:"outdated,omitempty"`
	UpdatedAt time.Time       `json:"updated_at"`
	Comments  []ReviewComment `json:"comments"`
}

func (s *Syncer) baseURL() string {
	if s.BaseURL != "" {
		return strings.TrimRight(s.BaseURL, "/")
	}
	return "https://api.github.com"
}

func (s *Syncer) httpClient() *http.Client {
	if s.HTTP != nil {
		return s.HTTP
	}
	return &http.Client{Timeout: 15 * time.Second}
}

func (s *Syncer) doConditionalGET(ctx context.Context, url, token, etag string) (status int, newETag string, body []byte, err error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0, "", nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("User-Agent", "vesper")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	if etag != "" {
		req.Header.Set("If-None-Match", etag)
	}
	res, err := s.httpClient().Do(req)
	if err != nil {
		return 0, "", nil, err
	}
	defer res.Body.Close()

	if res.StatusCode == http.StatusNotModified {
		return http.StatusNotModified, etag, nil, nil
	}
	raw, err := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	if err != nil {
		return res.StatusCode, "", nil, err
	}
	if res.StatusCode != http.StatusOK {
		return res.StatusCode, "", raw, fmt.Errorf("github: %s", res.Status)
	}
	return http.StatusOK, res.Header.Get("ETag"), raw, nil
}

type ghCheckRunsResponse struct {
	CheckRuns []struct {
		ID          int64      `json:"id"`
		Name        string     `json:"name"`
		Status      string     `json:"status"`
		Conclusion  string     `json:"conclusion"`
		DetailsURL  string     `json:"details_url"`
		HTMLURL     string     `json:"html_url"`
		CompletedAt *time.Time `json:"completed_at"`
		Output      struct {
			Title   string `json:"title"`
			Summary string `json:"summary"`
		} `json:"output"`
	} `json:"check_runs"`
}

func isFailingConclusion(c string) bool {
	switch strings.ToLower(strings.TrimSpace(c)) {
	case "failure", "timed_out", "action_required", "startup_failure":
		return true
	}
	return false
}

type checkRunsResult struct {
	notModified bool
	etag        string
	ciState     string
	failed      []FailedCheck
	failedAt    *time.Time
}

func (s *Syncer) fetchCheckRuns(ctx context.Context, token, owner, repo, headSHA, prevETag string) (checkRunsResult, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/commits/%s/check-runs?per_page=100", s.baseURL(), owner, repo, headSHA)
	status, newETag, raw, err := s.doConditionalGET(ctx, url, token, prevETag)
	if err != nil {
		return checkRunsResult{}, err
	}
	if status == http.StatusNotModified {
		return checkRunsResult{notModified: true, etag: prevETag}, nil
	}
	var parsed ghCheckRunsResponse
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return checkRunsResult{}, err
	}
	type latestEntry struct {
		id          int64
		name        string
		status      string
		conclusion  string
		detailsURL  string
		title       string
		summary     string
		completedAt *time.Time
	}
	latestByName := map[string]latestEntry{}
	order := make([]string, 0, len(parsed.CheckRuns))
	for _, cr := range parsed.CheckRuns {
		name := strings.TrimSpace(cr.Name)
		if name == "" {
			continue
		}
		details := cr.DetailsURL
		if details == "" {
			details = cr.HTMLURL
		}
		cur := latestEntry{
			id:          cr.ID,
			name:        name,
			status:      cr.Status,
			conclusion:  cr.Conclusion,
			detailsURL:  details,
			title:       clipRunes(strings.TrimSpace(cr.Output.Title), 200),
			summary:     clipRunes(strings.TrimSpace(cr.Output.Summary), maxFeedbackTextLen),
			completedAt: cr.CompletedAt,
		}
		prev, seen := latestByName[name]
		if !seen {
			order = append(order, name)
			latestByName[name] = cur
			continue
		}
		if newerCheckRun(cur.id, cur.completedAt, prev.id, prev.completedAt) {
			latestByName[name] = cur
		}
	}
	var failed []FailedCheck
	var anyPending bool
	var maxFailTime time.Time
	for _, name := range order {
		cr := latestByName[name]
		if cr.status != "completed" {
			anyPending = true
			continue
		}
		if isFailingConclusion(cr.conclusion) {
			if len(failed) < maxFailedChecks {
				failed = append(failed, FailedCheck{
					Name:       cr.name,
					Conclusion: cr.conclusion,
					DetailsURL: cr.detailsURL,
					Title:      cr.title,
					Summary:    cr.summary,
				})
			}
			if cr.completedAt != nil && cr.completedAt.After(maxFailTime) {
				maxFailTime = *cr.completedAt
			}
		}
	}
	ciState := "unknown"
	var failedAt *time.Time
	switch {
	case len(failed) > 0:
		ciState = "failing"
		if maxFailTime.IsZero() {
			maxFailTime = time.Now().UTC()
		}
		failedAt = &maxFailTime
	case anyPending:
		ciState = "pending"
	case len(latestByName) > 0:
		ciState = "passing"
	}
	return checkRunsResult{etag: newETag, ciState: ciState, failed: failed, failedAt: failedAt}, nil
}

func newerCheckRun(idA int64, atA *time.Time, idB int64, atB *time.Time) bool {
	if atA != nil && atB != nil && !atA.Equal(*atB) {
		return atA.After(*atB)
	}
	if (atA != nil) != (atB != nil) {
		return atA != nil
	}
	return idA > idB
}

const prReviewThreadsGraphQL = `query PRReviewThreads($owner: String!, $repo: String!, $number: Int!) {
  repository(owner: $owner, name: $repo) {
    pullRequest(number: $number) {
      reviewThreads(first: 50) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          comments(first: 20) {
            nodes {
              author { login }
              body
              url
              createdAt
              diffHunk
            }
          }
        }
      }
    }
  }
}`

type prThreadsGraphQLResp struct {
	Data struct {
		Repository *struct {
			PullRequest *struct {
				ReviewThreads struct {
					Nodes []struct {
						ID           string `json:"id"`
						IsResolved   bool   `json:"isResolved"`
						IsOutdated   bool   `json:"isOutdated"`
						Path         string `json:"path"`
						Line         *int   `json:"line"`
						OriginalLine *int   `json:"originalLine"`
						Comments     struct {
							Nodes []struct {
								Author *struct {
									Login string `json:"login"`
								} `json:"author"`
								Body      string    `json:"body"`
								URL       string    `json:"url"`
								CreatedAt time.Time `json:"createdAt"`
								DiffHunk  string    `json:"diffHunk"`
							} `json:"nodes"`
						} `json:"comments"`
					} `json:"nodes"`
				} `json:"reviewThreads"`
			} `json:"pullRequest"`
		} `json:"repository"`
	} `json:"data"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

type restPRComment struct {
	ID           int64     `json:"id"`
	InReplyToID  *int64    `json:"in_reply_to_id"`
	Path         string    `json:"path"`
	Line         *int      `json:"line"`
	OriginalLine *int      `json:"original_line"`
	Body         string    `json:"body"`
	DiffHunk     string    `json:"diff_hunk"`
	HTMLURL      string    `json:"html_url"`
	CreatedAt    time.Time `json:"created_at"`
	User         *struct {
		Login string `json:"login"`
	} `json:"user"`
}

type reviewsResult struct {
	notModified bool
	etag        string
	threads     []ReviewThread
	updatedAt   *time.Time
}

func (s *Syncer) fetchReviewThreads(ctx context.Context, token, owner, repo string, prNumber int, prevETag string, prNotModified bool) (reviewsResult, error) {
	url := fmt.Sprintf("%s/repos/%s/%s/pulls/%d/comments?per_page=100", s.baseURL(), owner, repo, prNumber)
	status, newETag, rawREST, err := s.doConditionalGET(ctx, url, token, prevETag)
	if err != nil {
		return reviewsResult{}, err
	}
	if status == http.StatusNotModified && prNotModified {
		return reviewsResult{notModified: true, etag: prevETag}, nil
	}
	etagOut := newETag
	if status == http.StatusNotModified {
		etagOut = prevETag
	}

	threads, ok, gqlErr := s.fetchReviewThreadsGraphQL(ctx, token, owner, repo, prNumber)
	if ok {
		return buildReviewsResult(etagOut, threads), nil
	}
	if status == http.StatusOK {
		var restComments []restPRComment
		if uerr := json.Unmarshal(rawREST, &restComments); uerr != nil {
			return reviewsResult{}, uerr
		}
		return buildReviewsResult(etagOut, groupRESTReviewThreads(restComments)), nil
	}
	return reviewsResult{}, gqlErr
}

func (s *Syncer) fetchReviewThreadsGraphQL(ctx context.Context, token, owner, repo string, prNumber int) ([]ReviewThread, bool, error) {
	payload, err := json.Marshal(map[string]any{
		"query": prReviewThreadsGraphQL,
		"variables": map[string]any{
			"owner":  owner,
			"repo":   repo,
			"number": prNumber,
		},
	})
	if err != nil {
		return nil, false, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.baseURL()+"/graphql", bytes.NewReader(payload))
	if err != nil {
		return nil, false, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "vesper")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	res, err := s.httpClient().Do(req)
	if err != nil {
		return nil, false, err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	if err != nil {
		return nil, false, err
	}
	if res.StatusCode != http.StatusOK {
		return nil, false, fmt.Errorf("github graphql: %s", res.Status)
	}
	var resp prThreadsGraphQLResp
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, false, err
	}
	if resp.Data.Repository == nil || resp.Data.Repository.PullRequest == nil {
		if len(resp.Errors) > 0 {
			return nil, false, fmt.Errorf("github graphql: %s", resp.Errors[0].Message)
		}
		return nil, false, nil
	}
	var out []ReviewThread
	for _, n := range resp.Data.Repository.PullRequest.ReviewThreads.Nodes {
		if n.IsResolved || len(n.Comments.Nodes) == 0 {
			continue
		}
		line := 0
		if n.Line != nil && *n.Line > 0 {
			line = *n.Line
		} else if n.OriginalLine != nil && *n.OriginalLine > 0 {
			line = *n.OriginalLine
		}
		var comments []ReviewComment
		var diffHunk, firstURL string
		var latest time.Time
		for _, c := range n.Comments.Nodes {
			if firstURL == "" {
				firstURL = c.URL
			}
			if diffHunk == "" && c.DiffHunk != "" {
				diffHunk = clipRunes(c.DiffHunk, maxDiffHunkLen)
			}
			if c.CreatedAt.After(latest) {
				latest = c.CreatedAt
			}
			if len(comments) < maxThreadComments {
				author := "reviewer"
				if c.Author != nil && c.Author.Login != "" {
					author = c.Author.Login
				}
				comments = append(comments, ReviewComment{
					Author:    author,
					Body:      clipRunes(strings.TrimSpace(c.Body), maxFeedbackTextLen),
					URL:       c.URL,
					CreatedAt: c.CreatedAt,
				})
			}
		}
		if len(comments) == 0 {
			continue
		}
		out = append(out, ReviewThread{
			ID:        n.ID,
			Path:      n.Path,
			Line:      line,
			URL:       firstURL,
			DiffHunk:  diffHunk,
			Outdated:  n.IsOutdated,
			UpdatedAt: latest,
			Comments:  comments,
		})
		if len(out) >= maxReviewThreads {
			break
		}
	}
	return out, true, nil
}

func groupRESTReviewThreads(comments []restPRComment) []ReviewThread {
	byRoot := map[int64]*ReviewThread{}
	var order []int64
	for _, c := range comments {
		rootID := c.ID
		if c.InReplyToID != nil && *c.InReplyToID > 0 {
			rootID = *c.InReplyToID
		}
		th, ok := byRoot[rootID]
		if !ok {
			if len(order) >= maxReviewThreads {
				continue
			}
			line := 0
			if c.Line != nil && *c.Line > 0 {
				line = *c.Line
			} else if c.OriginalLine != nil && *c.OriginalLine > 0 {
				line = *c.OriginalLine
			}
			th = &ReviewThread{
				ID:       fmt.Sprintf("rest-%d", rootID),
				Path:     c.Path,
				Line:     line,
				URL:      c.HTMLURL,
				DiffHunk: clipRunes(c.DiffHunk, maxDiffHunkLen),
			}
			byRoot[rootID] = th
			order = append(order, rootID)
		}
		if c.CreatedAt.After(th.UpdatedAt) {
			th.UpdatedAt = c.CreatedAt
		}
		if len(th.Comments) < maxThreadComments {
			author := "reviewer"
			if c.User != nil && c.User.Login != "" {
				author = c.User.Login
			}
			th.Comments = append(th.Comments, ReviewComment{
				Author:    author,
				Body:      clipRunes(strings.TrimSpace(c.Body), maxFeedbackTextLen),
				URL:       c.HTMLURL,
				CreatedAt: c.CreatedAt,
			})
		}
	}
	out := make([]ReviewThread, 0, len(order))
	for _, id := range order {
		if th := byRoot[id]; len(th.Comments) > 0 {
			out = append(out, *th)
		}
	}
	return out
}

func buildReviewsResult(etag string, threads []ReviewThread) reviewsResult {
	var maxAt time.Time
	for _, th := range threads {
		if th.UpdatedAt.After(maxAt) {
			maxAt = th.UpdatedAt
		}
	}
	var updatedAt *time.Time
	if len(threads) > 0 && !maxAt.IsZero() {
		updatedAt = &maxAt
	}
	return reviewsResult{etag: etag, threads: threads, updatedAt: updatedAt}
}

func (s *Syncer) loadPrevFeedback(ctx context.Context, q *store.Queries, workspaceID uuid.UUID, prURL string) (store.PrFeedback, bool) {
	row, err := q.GetPRFeedback(ctx, store.GetPRFeedbackParams{WorkspaceID: workspaceID, PrUrl: prURL})
	if errors.Is(err, pgx.ErrNoRows) || err != nil {
		return store.PrFeedback{}, false
	}
	return row, true
}

func (s *Syncer) syncFeedback(
	ctx context.Context, q *store.Queries, workspaceID uuid.UUID,
	prev store.PrFeedback, hasPrev bool,
	token, owner, repo string, prNumber int, rawPRURL, state, headSHA, newPRETag string, prNotModified bool,
) {
	if state != "open" && state != "draft" {
		return
	}
	if headSHA == "" && hasPrev {
		headSHA = prev.HeadSha
	}
	prETag := newPRETag
	if prETag == "" && hasPrev {
		prETag = prev.PrEtag
	}

	ciState := "unknown"
	var failedCount int32
	failedJSON := []byte("[]")
	var ciFailedAt *time.Time
	checksETag := ""
	if hasPrev && headSHA == prev.HeadSha {
		ciState = prev.CiState
		failedCount = prev.FailedChecksCount
		failedJSON = prev.FailedChecks
		ciFailedAt = prev.CiFailedAt
		checksETag = prev.ChecksEtag
	}
	if headSHA != "" {
		res, err := s.fetchCheckRuns(ctx, token, owner, repo, headSHA, checksETag)
		if err != nil {
			s.Log.Warn("pr sync check-runs", "pr", rawPRURL, "err", err)
		} else if !res.notModified {
			checksETag = res.etag
			ciState = res.ciState
			failedCount = int32(len(res.failed))
			if res.failed == nil {
				failedJSON = []byte("[]")
			} else if raw, merr := json.Marshal(res.failed); merr == nil {
				failedJSON = raw
			}
			if ciState == "failing" {
				if hasPrev && prev.CiState == "failing" && headSHA == prev.HeadSha && sameFailedCheckNames(prev.FailedChecks, res.failed) && prev.CiFailedAt != nil {
					ciFailedAt = prev.CiFailedAt
				} else {
					ciFailedAt = res.failedAt
				}
			} else {
				ciFailedAt = nil
			}
		}
	}

	reviewsETag := ""
	unresolvedCount := int32(0)
	threadsJSON := []byte("[]")
	var reviewUpdatedAt *time.Time
	if hasPrev {
		reviewsETag = prev.ReviewsEtag
		unresolvedCount = prev.UnresolvedThreads
		threadsJSON = prev.ReviewThreads
		reviewUpdatedAt = prev.ReviewUpdatedAt
	}
	revRes, err := s.fetchReviewThreads(ctx, token, owner, repo, prNumber, reviewsETag, prNotModified)
	if err != nil {
		s.Log.Warn("pr sync review threads", "pr", rawPRURL, "err", err)
	} else if !revRes.notModified {
		reviewsETag = revRes.etag
		unresolvedCount = int32(len(revRes.threads))
		if revRes.threads == nil {
			threadsJSON = []byte("[]")
		} else if raw, merr := json.Marshal(revRes.threads); merr == nil {
			threadsJSON = raw
		}
		reviewUpdatedAt = revRes.updatedAt
	}

	if _, err := q.UpsertPRFeedback(ctx, store.UpsertPRFeedbackParams{
		WorkspaceID:       workspaceID,
		PrUrl:             rawPRURL,
		HeadSha:           headSHA,
		PrEtag:            prETag,
		ChecksEtag:        checksETag,
		ReviewsEtag:       reviewsETag,
		CiState:           ciState,
		FailedChecksCount: failedCount,
		FailedChecks:      failedJSON,
		UnresolvedThreads: unresolvedCount,
		ReviewThreads:     threadsJSON,
		CiFailedAt:        ciFailedAt,
		ReviewUpdatedAt:   reviewUpdatedAt,
	}); err != nil {
		s.Log.Warn("pr sync upsert feedback", "pr", rawPRURL, "err", err)
	}
}

func sameFailedCheckNames(prevRaw []byte, next []FailedCheck) bool {
	var prev []FailedCheck
	if json.Unmarshal(prevRaw, &prev) != nil || len(prev) != len(next) {
		return false
	}
	a := make([]string, len(prev))
	for i, c := range prev {
		a[i] = c.Name
	}
	b := make([]string, len(next))
	for i, c := range next {
		b[i] = c.Name
	}
	slices.Sort(a)
	slices.Sort(b)
	return slices.Equal(a, b)
}

func clipRunes(s string, maxRunes int) string {
	r := []rune(s)
	if len(r) <= maxRunes {
		return s
	}
	return string(r[:maxRunes-1]) + "…"
}
