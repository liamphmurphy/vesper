// Package githubpr fetches open GitHub pull requests awaiting the connected
// user's review. It uses GitHub's GraphQL search API so a single request returns
// PR metadata and distinguishes direct user review requests from team requests.
package githubpr

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
)

const (
	DefaultBaseURL = "https://api.github.com"
	DefaultTTL     = 60 * time.Second
	searchQuery    = "is:pr is:open review-requested:@me sort:updated-desc"
)

// ReviewRequest is one open pull request awaiting the user's review.
type ReviewRequest struct {
	ID              string
	Number          int
	Title           string
	URL             string
	Repository      string
	AuthorLogin     string
	AuthorAvatarURL string
	Draft           bool
	Direct          bool
	Team            bool
	Teams           []string
	Additions       int
	Deletions       int
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// Feed is the response returned for a workspace's review requests.
type Feed struct {
	ViewerLogin string
	SyncedAt    time.Time
	Items       []ReviewRequest
}

// Service fetches and caches GitHub PR review requests per workspace token.
type Service struct {
	BaseURL string
	HTTP    *http.Client
	TTL     time.Duration
	Now     func() time.Time

	mu    sync.Mutex
	cache map[string]cachedFeed
}

type cachedFeed struct {
	feed    Feed
	expires time.Time
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Service) ttl() time.Duration {
	if s.TTL > 0 {
		return s.TTL
	}
	return DefaultTTL
}

// ListReviewRequests returns open PRs requesting review from the token's user,
// serving a short-lived cache unless refresh is true.
func (s *Service) ListReviewRequests(ctx context.Context, workspaceID uuid.UUID, token string, refresh bool) (Feed, error) {
	key := fmt.Sprintf("%s/%x", workspaceID, sha256.Sum256([]byte(token)))
	now := s.now()
	if !refresh {
		s.mu.Lock()
		cached, ok := s.cache[key]
		s.mu.Unlock()
		if ok && now.Before(cached.expires) {
			return cloneFeed(cached.feed), nil
		}
	}

	feed, err := s.fetch(ctx, token, now)
	if err != nil {
		return Feed{}, err
	}

	s.mu.Lock()
	if s.cache == nil {
		s.cache = map[string]cachedFeed{}
	}
	s.cache[key] = cachedFeed{feed: cloneFeed(feed), expires: now.Add(s.ttl())}
	s.mu.Unlock()
	return feed, nil
}

func cloneFeed(f Feed) Feed {
	out := f
	out.Items = slices.Clone(f.Items)
	for i := range out.Items {
		out.Items[i].Teams = slices.Clone(out.Items[i].Teams)
	}
	return out
}

const reviewRequestsGraphQL = `query ReviewRequests($q: String!) {
  viewer { login }
  search(query: $q, type: ISSUE, first: 30) {
    nodes {
      ... on PullRequest {
        number
        title
        url
        isDraft
        additions
        deletions
        createdAt
        updatedAt
        repository { nameWithOwner }
        author { login avatarUrl }
        reviewRequests(first: 20) {
          nodes {
            requestedReviewer {
              __typename
              ... on User { login }
              ... on Team { slug }
            }
          }
        }
      }
    }
  }
}`

type graphQLRequest struct {
	Query     string         `json:"query"`
	Variables map[string]any `json:"variables"`
}

type graphQLResponse struct {
	Data struct {
		Viewer struct {
			Login string `json:"login"`
		} `json:"viewer"`
		Search struct {
			Nodes []struct {
				Number     int       `json:"number"`
				Title      string    `json:"title"`
				URL        string    `json:"url"`
				IsDraft    bool      `json:"isDraft"`
				Additions  int       `json:"additions"`
				Deletions  int       `json:"deletions"`
				CreatedAt  time.Time `json:"createdAt"`
				UpdatedAt  time.Time `json:"updatedAt"`
				Repository struct {
					NameWithOwner string `json:"nameWithOwner"`
				} `json:"repository"`
				Author *struct {
					Login     string `json:"login"`
					AvatarURL string `json:"avatarUrl"`
				} `json:"author"`
				ReviewRequests struct {
					Nodes []struct {
						RequestedReviewer *struct {
							TypeName string `json:"__typename"`
							Login    string `json:"login"`
							Slug     string `json:"slug"`
						} `json:"requestedReviewer"`
					} `json:"nodes"`
				} `json:"reviewRequests"`
			} `json:"nodes"`
		} `json:"search"`
	} `json:"data"`
	Errors []struct {
		Message string `json:"message"`
	} `json:"errors"`
}

func (s *Service) fetch(ctx context.Context, token string, now time.Time) (Feed, error) {
	base := s.BaseURL
	if base == "" {
		base = DefaultBaseURL
	}
	payload, err := json.Marshal(graphQLRequest{
		Query:     reviewRequestsGraphQL,
		Variables: map[string]any{"q": searchQuery},
	})
	if err != nil {
		return Feed{}, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(base, "/")+"/graphql", bytes.NewReader(payload))
	if err != nil {
		return Feed{}, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", "vesper")

	client := s.HTTP
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second}
	}
	res, err := client.Do(req)
	if err != nil {
		return Feed{}, fmt.Errorf("GitHub lookup failed: %w", err)
	}
	defer res.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	if err != nil {
		return Feed{}, err
	}
	if res.StatusCode != http.StatusOK {
		var apiErr struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(raw, &apiErr)
		if apiErr.Message != "" {
			return Feed{}, fmt.Errorf("GitHub answered %d: %s", res.StatusCode, apiErr.Message)
		}
		return Feed{}, fmt.Errorf("GitHub answered %d", res.StatusCode)
	}

	var resp graphQLResponse
	if err := json.Unmarshal(raw, &resp); err != nil {
		return Feed{}, fmt.Errorf("decode GitHub response: %w", err)
	}
	if len(resp.Errors) > 0 && len(resp.Data.Search.Nodes) == 0 {
		return Feed{}, fmt.Errorf("GitHub GraphQL error: %s", resp.Errors[0].Message)
	}

	viewer := resp.Data.Viewer.Login
	items := make([]ReviewRequest, 0, len(resp.Data.Search.Nodes))
	for _, n := range resp.Data.Search.Nodes {
		if n.Number == 0 || n.URL == "" {
			continue
		}
		var direct, team bool
		var teams []string
		seenTeam := map[string]bool{}
		for _, rr := range n.ReviewRequests.Nodes {
			if rr.RequestedReviewer == nil {
				continue
			}
			switch rr.RequestedReviewer.TypeName {
			case "User":
				if viewer != "" && strings.EqualFold(rr.RequestedReviewer.Login, viewer) {
					direct = true
				}
			case "Team":
				if slug := rr.RequestedReviewer.Slug; slug != "" {
					team = true
					tag := "@" + slug
					if !seenTeam[tag] {
						seenTeam[tag] = true
						teams = append(teams, tag)
					}
				}
			}
		}
		// If reviewRequests was truncated past 20 entries and neither matched,
		// keep the PR visible under Direct rather than dropping it from both toggles.
		if !direct && !team {
			direct = true
		}

		authorLogin := "ghost"
		authorAvatar := ""
		if n.Author != nil && n.Author.Login != "" {
			authorLogin = n.Author.Login
			authorAvatar = n.Author.AvatarURL
		}

		items = append(items, ReviewRequest{
			ID:              fmt.Sprintf("%s#%d", n.Repository.NameWithOwner, n.Number),
			Number:          n.Number,
			Title:           n.Title,
			URL:             n.URL,
			Repository:      n.Repository.NameWithOwner,
			AuthorLogin:     authorLogin,
			AuthorAvatarURL: authorAvatar,
			Draft:           n.IsDraft,
			Direct:          direct,
			Team:            team,
			Teams:           teams,
			Additions:       n.Additions,
			Deletions:       n.Deletions,
			CreatedAt:       n.CreatedAt,
			UpdatedAt:       n.UpdatedAt,
		})
	}

	return Feed{
		ViewerLogin: viewer,
		SyncedAt:    now,
		Items:       items,
	}, nil
}
