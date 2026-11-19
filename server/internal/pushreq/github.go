// Package pushreq ships a branch a persona asked to push from a coding chat,
// once the person approves it (or always allows the repository). The runner
// has already pushed the reviewed commit to a staging branch, so shipping is
// only GitHub API calls: point the branch at that commit, open the pull
// request (or find the one already open), and drop the staging branch. No
// workspace, no persona and no git are involved, which is what lets a card
// be approved after the chat's workspace was cleaned up.
package pushreq

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// DefaultBaseURL is GitHub's REST API.
const DefaultBaseURL = "https://api.github.com"

// GitHub is the slice of the REST API shipping needs. BaseURL and HTTP are
// replaceable for tests.
type GitHub struct {
	BaseURL string
	HTTP    *http.Client
	Token   string
}

// ErrNotFound is GitHub's 404.
var ErrNotFound = errors.New("pushreq: not found on GitHub")

// APIError is any other error response.
type APIError struct {
	Status  int
	Message string
}

func (e *APIError) Error() string { return fmt.Sprintf("GitHub answered %d: %s", e.Status, e.Message) }

var repoRe = regexp.MustCompile(`^(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+?)(?:\.git)?/?$`)

// ParseRepo reads owner and name from a github.com repository URL (https or
// SSH). ok is false for any other host: shipping only talks to GitHub.
func ParseRepo(repoURL string) (owner, name string, ok bool) {
	m := repoRe.FindStringSubmatch(strings.TrimSpace(repoURL))
	if m == nil {
		return "", "", false
	}
	return m[1], m[2], true
}

// HTTPSURL is the https form of a github.com repository URL, the only one the
// runner pushes to with a token.
func HTTPSURL(repoURL string) (string, bool) {
	owner, name, ok := ParseRepo(repoURL)
	if !ok {
		return "", false
	}
	return "https://github.com/" + owner + "/" + name + ".git", true
}

func (g *GitHub) do(ctx context.Context, method, path string, in, out any) error {
	base := g.BaseURL
	if base == "" {
		base = DefaultBaseURL
	}
	var body io.Reader
	if in != nil {
		b, err := json.Marshal(in)
		if err != nil {
			return err
		}
		body = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(base, "/")+path, body)
	if err != nil {
		return err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	req.Header.Set("Authorization", "Bearer "+g.Token)
	if in != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	client := g.HTTP
	if client == nil {
		client = &http.Client{Timeout: 30 * time.Second}
	}
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if err != nil {
		return err
	}
	if res.StatusCode == http.StatusNotFound {
		return ErrNotFound
	}
	if res.StatusCode >= 300 {
		var e struct {
			Message string `json:"message"`
			Errors  []struct {
				Message string `json:"message"`
			} `json:"errors"`
		}
		_ = json.Unmarshal(raw, &e)
		msg := e.Message
		for _, x := range e.Errors {
			if x.Message != "" {
				msg += ": " + x.Message
			}
		}
		if msg == "" {
			msg = http.StatusText(res.StatusCode)
		}
		return &APIError{Status: res.StatusCode, Message: msg}
	}
	if out != nil && len(raw) > 0 {
		return json.Unmarshal(raw, out)
	}
	return nil
}

func refPath(owner, name, branch string) string {
	return "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(name) + "/git/refs/heads/" + escapeBranch(branch)
}

// escapeBranch keeps a branch's slashes: GitHub's ref endpoints take them as path segments.
func escapeBranch(branch string) string {
	parts := strings.Split(branch, "/")
	for i, p := range parts {
		parts[i] = url.PathEscape(p)
	}
	return strings.Join(parts, "/")
}

// BranchSHA is the commit a branch points at, or "" when it doesn't exist.
func (g *GitHub) BranchSHA(ctx context.Context, owner, name, branch string) (string, error) {
	var ref struct {
		Object struct {
			SHA string `json:"sha"`
		} `json:"object"`
	}
	path := "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(name) + "/git/ref/heads/" + escapeBranch(branch)
	if err := g.do(ctx, "GET", path, nil, &ref); err != nil {
		if errors.Is(err, ErrNotFound) {
			return "", nil
		}
		return "", err
	}
	return ref.Object.SHA, nil
}

// CreateBranch makes branch at sha.
func (g *GitHub) CreateBranch(ctx context.Context, owner, name, branch, sha string) error {
	return g.do(ctx, "POST", "/repos/"+url.PathEscape(owner)+"/"+url.PathEscape(name)+"/git/refs",
		map[string]any{"ref": "refs/heads/" + branch, "sha": sha}, nil)
}

// FastForward moves branch to sha. GitHub refuses (422) unless sha descends
// from the branch's tip: shipping never rewrites what's already there.
func (g *GitHub) FastForward(ctx context.Context, owner, name, branch, sha string) error {
	return g.do(ctx, "PATCH", refPath(owner, name, branch), map[string]any{"sha": sha, "force": false}, nil)
}

// DeleteBranch removes branch; one already gone is fine.
func (g *GitHub) DeleteBranch(ctx context.Context, owner, name, branch string) error {
	err := g.do(ctx, "DELETE", refPath(owner, name, branch), nil, nil)
	var api *APIError
	if errors.Is(err, ErrNotFound) || (errors.As(err, &api) && api.Status == http.StatusUnprocessableEntity) {
		return nil
	}
	return err
}

// PullRequest is the part of one shipping and checkpoint cleanup report.
type PullRequest struct {
	Number  int    `json:"number"`
	HTMLURL string `json:"html_url"`
	Draft   bool   `json:"draft"`
	State   string `json:"state"`
	Merged  bool   `json:"merged"`
	Head    struct {
		SHA string `json:"sha"`
		Ref string `json:"ref"`
	} `json:"head"`
}

var prURLRe = regexp.MustCompile(`^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)/pull/(\d+)(?:[/?#].*)?$`)

// ParsePRURL extracts owner, repository name, and pull request number from a GitHub PR URL.
func ParsePRURL(raw string) (owner, name string, number int, ok bool) {
	m := prURLRe.FindStringSubmatch(strings.TrimSpace(raw))
	if m == nil {
		return "", "", 0, false
	}
	n, err := strconv.Atoi(m[3])
	if err != nil || n <= 0 {
		return "", "", 0, false
	}
	return m[1], m[2], n, true
}

// GetPullRequest fetches a pull request by number.
func (g *GitHub) GetPullRequest(ctx context.Context, owner, name string, number int) (*PullRequest, error) {
	var pr PullRequest
	path := "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(name) + "/pulls/" + strconv.Itoa(number)
	if err := g.do(ctx, "GET", path, nil, &pr); err != nil {
		return nil, err
	}
	return &pr, nil
}

// CommitTreeSHA returns the tree SHA recorded on commit sha.
func (g *GitHub) CommitTreeSHA(ctx context.Context, owner, name, sha string) (string, error) {
	var c struct {
		Tree struct {
			SHA string `json:"sha"`
		} `json:"tree"`
	}
	path := "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(name) + "/git/commits/" + url.PathEscape(sha)
	if err := g.do(ctx, "GET", path, nil, &c); err != nil {
		return "", err
	}
	return c.Tree.SHA, nil
}

// CompareCommit is one commit entry in a GitHub compare response.
type CompareCommit struct {
	SHA    string `json:"sha"`
	Commit struct {
		Tree struct {
			SHA string `json:"sha"`
		} `json:"tree"`
	} `json:"commit"`
}

// CompareFile is one changed file entry in a GitHub compare response.
type CompareFile struct {
	Filename         string `json:"filename"`
	PreviousFilename string `json:"previous_filename"`
	Status           string `json:"status"`
	SHA              string `json:"sha"`
}

// CompareResult is the subset of GitHub's compare endpoint used to verify
// whether a PR head contains all changes in a checkpoint.
type CompareResult struct {
	Status          string          `json:"status"` // identical | ahead | behind | diverged
	AheadBy         int             `json:"ahead_by"`
	BehindBy        int             `json:"behind_by"`
	BaseCommit      CompareCommit   `json:"base_commit"`
	MergeBaseCommit CompareCommit   `json:"merge_base_commit"`
	Commits         []CompareCommit `json:"commits"`
	Files           []CompareFile   `json:"files"`
}

// Compare runs GitHub's three-dot compare between base and head.
func (g *GitHub) Compare(ctx context.Context, owner, name, base, head string) (*CompareResult, error) {
	var res CompareResult
	path := "/repos/" + url.PathEscape(owner) + "/" + url.PathEscape(name) + "/compare/" + escapeBranch(base) + "..." + escapeBranch(head)
	if err := g.do(ctx, "GET", path, nil, &res); err != nil {
		return nil, err
	}
	return &res, nil
}

// OpenPullRequest is the open pull request from branch, if there is one.
func (g *GitHub) OpenPullRequest(ctx context.Context, owner, name, branch string) (*PullRequest, error) {
	var prs []PullRequest
	q := url.Values{"state": {"open"}, "head": {owner + ":" + branch}, "per_page": {"1"}}
	if err := g.do(ctx, "GET", "/repos/"+url.PathEscape(owner)+"/"+url.PathEscape(name)+"/pulls?"+q.Encode(), nil, &prs); err != nil {
		return nil, err
	}
	if len(prs) == 0 {
		return nil, nil
	}
	return &prs[0], nil
}

// CreatePullRequest opens one from head into base.
func (g *GitHub) CreatePullRequest(ctx context.Context, owner, name, head, base, title, body string, draft bool) (*PullRequest, error) {
	var pr PullRequest
	err := g.do(ctx, "POST", "/repos/"+url.PathEscape(owner)+"/"+url.PathEscape(name)+"/pulls",
		map[string]any{"title": title, "head": head, "base": base, "body": body, "draft": draft}, &pr)
	if err != nil {
		return nil, err
	}
	return &pr, nil
}
