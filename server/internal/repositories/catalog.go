// Package repositories resolves repository names. Saved sources aid discovery;
// GitHub's credential is the authority on access.
package repositories

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"slices"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

var ownerRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]{0,38}$`)
var repoRE = regexp.MustCompile(`^[A-Za-z0-9_.-]{1,100}$`)

// Organization retains the existing source kind while accepting any GitHub owner.
func Organization(raw string) (string, error) {
	name := strings.ToLower(strings.TrimSpace(raw))
	name = strings.TrimPrefix(name, "https://github.com/")
	name = strings.TrimSuffix(strings.TrimSuffix(name, "/"), "/*")
	if !ownerRE.MatchString(name) {
		return "", apperr.Invalid("name", "enter a GitHub account or organization, optionally followed by /*")
	}
	return name, nil
}

func Canonical(raw string) (string, error) {
	s := strings.ToLower(strings.TrimSpace(raw))
	s = strings.TrimPrefix(s, "https://github.com/")
	s = strings.TrimPrefix(s, "ssh://git@github.com/")
	s = strings.TrimPrefix(s, "git@github.com:")
	s = strings.TrimSuffix(strings.TrimSuffix(s, "/"), ".git")
	owner, repo, ok := strings.Cut(s, "/")
	if !ok || !ownerRE.MatchString(owner) || !repoRE.MatchString(repo) || repo == "." || repo == ".." {
		return "", apperr.Invalid("repository", "enter owner/repository or its GitHub URL")
	}
	return "https://github.com/" + strings.ToLower(owner+"/"+repo) + ".git", nil
}
func Name(url string) string {
	return strings.TrimSuffix(strings.TrimPrefix(url, "https://github.com/"), ".git")
}
func Directory(url string) string { return ".lazyagents/repos/" + Name(url) }

type Revealer interface {
	Reveal(context.Context, uuid.UUID, *uuid.UUID, string) (string, error)
}
type Service struct {
	Q       *store.Queries
	Secrets Revealer
	Client  *http.Client
}
type Owner struct{ WorkspaceID, UserID uuid.UUID }
type Entry struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}
type Source struct {
	Kind string `json:"kind"`
	Name string `json:"name"`
}

func (s *Service) Sources(ctx context.Context, o Owner) ([]Source, error) {
	rows, err := s.Q.ListRepositorySources(ctx, store.ListRepositorySourcesParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID})
	out := []Source{}
	seen := map[string]bool{}
	for _, r := range rows {
		if r.Kind == "repository" {
			if u, e := Canonical(r.Name); e == nil {
				r.Name = u
			}
		}
		key := r.Kind + "/" + r.Name
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, Source{Kind: r.Kind, Name: r.Name})
	}
	return out, err
}
func (s *Service) Save(ctx context.Context, o Owner, kind, name string, remove bool) error {
	original := strings.TrimSpace(name)
	if kind == "repository" && strings.HasSuffix(strings.TrimRight(original, "/"), "/*") {
		kind = "organization"
	}
	var err error
	switch kind {
	case "repository":
		name, err = Canonical(name)
	case "organization":
		name, err = Organization(name)
	default:
		return apperr.Invalid("kind", "choose repository or organization")
	}
	if err != nil && remove && kind == "repository" {
		// Older persona lists could contain public repositories on other forges.
		return s.Q.DeleteRepositorySource(ctx, store.DeleteRepositorySourceParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, Kind: kind, Name: original})
	}
	if err != nil {
		return err
	}
	if remove {
		if kind == "repository" {
			rows, e := s.Q.ListRepositorySources(ctx, store.ListRepositorySourcesParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID})
			if e != nil {
				return e
			}
			for _, r := range rows {
				u, e := Canonical(r.Name)
				if r.Kind == kind && e == nil && u == name {
					if e = s.Q.DeleteRepositorySource(ctx, store.DeleteRepositorySourceParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, Kind: kind, Name: r.Name}); e != nil {
						return e
					}
				}
			}
		}
		return s.Q.DeleteRepositorySource(ctx, store.DeleteRepositorySourceParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, Kind: kind, Name: name})
	}
	return s.Q.AddRepositorySource(ctx, store.AddRepositorySourceParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, Kind: kind, Name: name})
}

var ownerCache = struct {
	sync.Mutex
	rows map[string]cachedOwner
}{rows: map[string]cachedOwner{}}

type cachedOwner struct {
	Entries []Entry
	Expires time.Time
}

func (s *Service) token(ctx context.Context, o Owner) (string, error) {
	if s.Secrets == nil {
		return "", apperr.Conflict("add a GitHub token in Settings → Provider credentials to discover organization repositories")
	}
	token, err := s.Secrets.Reveal(ctx, o.WorkspaceID, nil, "git:pat")
	if err != nil {
		return "", apperr.Conflict("a GitHub token is required; check Settings → Provider credentials")
	}
	return token, nil
}
func (s *Service) get(ctx context.Context, token, path string, dst any) error {
	req, err := http.NewRequestWithContext(ctx, "GET", "https://api.github.com/"+path, nil)
	if err != nil {
		return err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/vnd.github+json")
	client := s.Client
	if client == nil {
		client = &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	}
	res, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("GitHub lookup failed: %w", err)
	}
	defer res.Body.Close()
	if res.StatusCode != 200 {
		return apperr.Invalid("repository", "GitHub returned %d; check the repository or account name and token access", res.StatusCode)
	}
	return json.NewDecoder(io.LimitReader(res.Body, 8<<20)).Decode(dst)
}

// ownerRepos includes public and token-visible private repositories. The
// users/{owner}/repos endpoint alone only lists public repositories.
// OwnerRepos lists all repositories owned by a GitHub user or organization.
func (s *Service) OwnerRepos(ctx context.Context, o Owner, owner string, refresh bool) ([]Entry, error) {
	return s.ownerRepos(ctx, o, strings.TrimSpace(owner), refresh)
}

func (s *Service) ownerRepos(ctx context.Context, o Owner, owner string, refresh bool) ([]Entry, error) {
	token, err := s.token(ctx, o)
	if err != nil {
		return nil, err
	}
	key := fmt.Sprintf("%s/%s/%s/%x", o.WorkspaceID, o.UserID, owner, sha256.Sum256([]byte(token)))
	ownerCache.Lock()
	cached, ok := ownerCache.rows[key]
	ownerCache.Unlock()
	if ok && !refresh && time.Now().Before(cached.Expires) {
		return slices.Clone(cached.Entries), nil
	}
	var account struct {
		Type string `json:"type"`
	}
	if err := s.get(ctx, token, "users/"+owner, &account); err != nil {
		return nil, err
	}
	var endpoints []string
	switch account.Type {
	case "Organization":
		endpoints = []string{"orgs/" + owner + "/repos?type=all"}
	case "User":
		endpoints = []string{"users/" + owner + "/repos?type=owner", "user/repos?affiliation=owner,collaborator&visibility=all"}
	default:
		return nil, apperr.Invalid("name", "GitHub owner must be a user account or organization")
	}
	out := []Entry{}
	seen := map[string]bool{}
	for _, endpoint := range endpoints {
		complete := false
		for page := 1; page <= 100; page++ {
			var rows []struct {
				FullName string `json:"full_name"`
			}
			if err := s.get(ctx, token, fmt.Sprintf("%s&per_page=100&sort=full_name&direction=asc&page=%d", endpoint, page), &rows); err != nil {
				return nil, err
			}
			for _, row := range rows {
				url, err := Canonical(row.FullName)
				if err != nil {
					return nil, errors.New("GitHub returned an invalid repository name")
				}
				name := Name(url)
				repoOwner, _, _ := strings.Cut(name, "/")
				if repoOwner == owner && !seen[url] {
					out = append(out, Entry{Name: name, URL: url})
					seen[url] = true
				}
			}
			if len(rows) < 100 {
				complete = true
				break
			}
		}
		if !complete {
			return nil, apperr.Conflict("owner has too many repositories to list; use owner/repository")
		}
	}
	ownerCache.Lock()
	if len(ownerCache.rows) >= 128 {
		clear(ownerCache.rows)
	}
	ownerCache.rows[key] = cachedOwner{Entries: slices.Clone(out), Expires: time.Now().Add(5 * time.Minute)}
	ownerCache.Unlock()
	return out, nil
}

func (s *Service) Search(ctx context.Context, o Owner, query string, refresh bool) ([]Entry, error) {
	sources, err := s.Sources(ctx, o)
	if err != nil {
		return nil, err
	}
	out := []Entry{}
	seen := map[string]bool{}
	query = strings.ToLower(strings.TrimSpace(query))
	add := func(u string) {
		if canonical, err := Canonical(u); err == nil {
			u = canonical
		}
		if !seen[u] && strings.Contains(strings.ToLower(Name(u)), query) {
			out = append(out, Entry{Name: Name(u), URL: u})
			seen[u] = true
		}
	}
	for _, source := range sources {
		if source.Kind == "repository" {
			add(source.Name)
			continue
		}
		repos, err := s.ownerRepos(ctx, o, source.Name, refresh)
		if err != nil {
			return nil, err
		}
		for _, r := range repos {
			add(r.URL)
		}
	}
	slices.SortFunc(out, func(a, b Entry) int { return strings.Compare(a.Name, b.Name) })
	return out, nil
}
func (s *Service) Resolve(ctx context.Context, o Owner, requested string) (string, error) {
	if strings.Contains(requested, "/") || strings.Contains(requested, ":") {
		return Canonical(requested)
	}
	entries, err := s.Search(ctx, o, requested, false)
	if err != nil {
		return "", err
	}
	matches := []Entry{}
	for _, entry := range entries {
		_, short, _ := strings.Cut(entry.Name, "/")
		if strings.EqualFold(short, strings.TrimSpace(requested)) {
			matches = append(matches, entry)
		}
	}
	if len(matches) == 1 {
		return matches[0].URL, nil
	}
	if len(matches) == 0 {
		return "", apperr.Invalid("repository", "no saved repository named %q; use owner/repository or a URL", requested)
	}
	names := []string{}
	for _, m := range matches {
		names = append(names, m.Name)
	}
	return "", apperr.Invalid("repository", "ambiguous name; choose %s", strings.Join(names, ", "))
}
