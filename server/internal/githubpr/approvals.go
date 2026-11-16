package githubpr

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

const authoredSearchQuery = "is:pr is:open author:@me sort:updated-desc"

// Approved is an open pull request the token's user authored that a reviewer
// approved and nobody has asked changes on since.
type Approved struct {
	Repository string
	Number     int
	Title      string
	URL        string
	Approver   string
	ApprovedAt time.Time
}

const authoredGraphQL = `query Authored($q: String!) {
  search(query: $q, type: ISSUE, first: 50) {
    nodes {
      ... on PullRequest {
        number
        title
        url
        isDraft
        repository { nameWithOwner }
        latestOpinionatedReviews(first: 20) {
          nodes {
            state
            submittedAt
            author { login }
          }
        }
      }
    }
  }
}`

type authoredResponse struct {
	Data struct {
		Search struct {
			Nodes []struct {
				Number     int    `json:"number"`
				Title      string `json:"title"`
				URL        string `json:"url"`
				IsDraft    bool   `json:"isDraft"`
				Repository struct {
					NameWithOwner string `json:"nameWithOwner"`
				} `json:"repository"`
				Reviews struct {
					Nodes []struct {
						State       string    `json:"state"`
						SubmittedAt time.Time `json:"submittedAt"`
						Author      *struct {
							Login string `json:"login"`
						} `json:"author"`
					} `json:"nodes"`
				} `json:"latestOpinionatedReviews"`
			} `json:"nodes"`
		} `json:"search"`
	} `json:"data"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

// ListApproved returns the token user's open pull requests that are currently
// approved: at least one reviewer's latest opinion is APPROVED and no one's is
// CHANGES_REQUESTED. latestOpinionatedReviews is one review per reviewer, so a
// later dismissal or changes request is reflected. It is read from the reviews
// rather than reviewDecision, which GitHub leaves empty on a branch that doesn't
// require reviews.
func (s *Service) ListApproved(ctx context.Context, token string) ([]Approved, error) {
	raw, err := s.graphQL(ctx, token, authoredGraphQL, map[string]any{"q": authoredSearchQuery})
	if err != nil {
		return nil, err
	}
	var resp authoredResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		return nil, fmt.Errorf("decode GitHub response: %w", err)
	}
	if len(resp.Errors) > 0 && len(resp.Data.Search.Nodes) == 0 {
		return nil, fmt.Errorf("GitHub GraphQL error: %s", resp.Errors[0].Message)
	}
	var out []Approved
	for _, n := range resp.Data.Search.Nodes {
		if n.Number == 0 || n.URL == "" || n.IsDraft {
			continue
		}
		var latest Approved
		changes := false
		for _, r := range n.Reviews.Nodes {
			switch r.State {
			case "CHANGES_REQUESTED":
				changes = true
			case "APPROVED":
				if r.SubmittedAt.After(latest.ApprovedAt) {
					latest.ApprovedAt = r.SubmittedAt
					latest.Approver = ""
					if r.Author != nil {
						latest.Approver = r.Author.Login
					}
				}
			}
		}
		if changes || latest.ApprovedAt.IsZero() {
			continue
		}
		latest.Repository = n.Repository.NameWithOwner
		latest.Number = n.Number
		latest.Title = n.Title
		latest.URL = n.URL
		out = append(out, latest)
	}
	return out, nil
}

// Revealer reads a stored secret (secrets.Service).
type Revealer interface {
	Reveal(ctx context.Context, ws uuid.UUID, project *uuid.UUID, name string) (string, error)
}

// ApprovalSyncer polls each workspace's GitHub token for approved pull requests
// the user authored and records them for the inbox (ListInbox's pr_approved).
type ApprovalSyncer struct {
	Queries *store.Queries
	Secrets Revealer
	GitHub  *Service
	Log     *slog.Logger
}

// Run polls every interval until ctx is cancelled.
func (a *ApprovalSyncer) Run(ctx context.Context, interval time.Duration) {
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		if err := a.Once(ctx); err != nil && ctx.Err() == nil {
			a.Log.Warn("github approvals", "err", err)
		}
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
	}
}

// Once syncs every workspace that has a GitHub token. A workspace that fails
// doesn't stop the others; the first error is returned.
func (a *ApprovalSyncer) Once(ctx context.Context) error {
	workspaces, err := a.Queries.WorkspacesWithGitHubToken(ctx)
	if err != nil {
		return err
	}
	var first error
	for _, ws := range workspaces {
		if err := a.syncWorkspace(ctx, ws); err != nil {
			a.Log.Warn("github approvals", "workspace", ws, "err", err)
			if first == nil {
				first = err
			}
		}
	}
	return first
}

func (a *ApprovalSyncer) syncWorkspace(ctx context.Context, ws uuid.UUID) error {
	token, err := a.Secrets.Reveal(ctx, ws, nil, "git:pat")
	if err != nil {
		return err
	}
	if strings.TrimSpace(token) == "" {
		return nil
	}
	approved, err := a.GitHub.ListApproved(ctx, token)
	if err != nil {
		return err
	}
	for _, p := range approved {
		if err := a.Queries.UpsertGitHubPRApproval(ctx, store.UpsertGitHubPRApprovalParams{
			WorkspaceID: ws, Repository: p.Repository, Number: int32(p.Number), Title: p.Title,
			Url: p.URL, Approver: p.Approver, ApprovedAt: p.ApprovedAt,
		}); err != nil {
			return err
		}
	}
	return nil
}
