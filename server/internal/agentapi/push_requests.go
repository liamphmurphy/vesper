package agentapi

import (
	"context"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// A coding chat's turn holds no credential that can push. The persona commits
// on a work branch and asks with request_push; when the turn ends the runner
// stages the branch's tip, and the person approves the push and pull request
// on a card (or has said to always allow the repository). See package pushreq.

// maxOpenPushRequests bounds the push cards waiting in one chat.
const maxOpenPushRequests = 10

type RequestPushIn struct {
	Repository string `json:"repository,omitempty" jsonschema:"Repository URL or checkout directory; the chat's active repository when omitted"`
	Branch     string `json:"branch" jsonschema:"The local work branch to push, named TYPE/short-description; commit everything on it first"`
	Title      string `json:"title" jsonschema:"Pull request title: imperative, at most 72 characters"`
	Body       string `json:"body,omitempty" jsonschema:"Pull request description in Markdown"`
	Draft      bool   `json:"draft,omitempty" jsonschema:"Open the pull request as a draft"`
}

func requestPush(ctx context.Context, d Deps, c agents.Caller, in RequestPushIn) (any, error) {
	s, err := requireChat(ctx, d, c)
	if err != nil {
		return nil, err
	}
	ws := c.Agent.WorkspaceID
	run, err := d.Q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: ws})
	if err != nil {
		return nil, err
	}
	spec, err := runs.Spec(run)
	if err != nil {
		return nil, err
	}
	if spec.Mode("repo:write") != agentdef.Allowed {
		return nil, apperr.Conflict("this chat can't write code")
	}
	in.Branch = strings.TrimSpace(in.Branch)
	in.Title = strings.TrimSpace(in.Title)
	if !personas.ValidWorkBranch(in.Branch) {
		return nil, apperr.Invalid("branch", "name a work branch TYPE/short-description (feat/..., fix/..., chore/...)")
	}
	if in.Title == "" || len([]rune(in.Title)) > 200 {
		return nil, apperr.Invalid("title", "required, at most 200 characters")
	}
	if len(in.Body) > 60000 {
		return nil, apperr.Invalid("body", "at most 60000 characters")
	}
	chat, err := d.Q.GetChatSession(ctx, store.GetChatSessionParams{ID: s.ChatID, WorkspaceID: ws})
	if err != nil {
		return nil, err
	}
	repos, err := d.Q.ChatRepositories(ctx, s.ChatID)
	if err != nil {
		return nil, err
	}
	want := strings.TrimSpace(in.Repository)
	if want == "" && chat.RepoUrl != nil {
		want = *chat.RepoUrl
	}
	var repo *store.ChatRepository
	for i := range repos {
		r := repos[i]
		if r.RepoUrl == want || r.Directory == want || strings.TrimSuffix(r.RepoUrl, ".git") == strings.TrimSuffix(want, ".git") {
			repo = &r
			break
		}
	}
	if repo == nil {
		return nil, apperr.Invalid("repository", "not attached to this chat; use_repository first")
	}
	n, err := d.Q.CountOpenPushRequests(ctx, s.ChatID)
	if err != nil {
		return nil, err
	}
	if n >= maxOpenPushRequests {
		return nil, apperr.Conflict("%d push requests already wait in this chat; ask the person to decide those first", n)
	}
	turn, err := chatTurn(ctx, d, c)
	if err != nil {
		return nil, err
	}
	r, err := d.Q.CreatePushRequest(ctx, store.CreatePushRequestParams{
		WorkspaceID: ws, UserID: s.UserID, ChatID: s.ChatID, RunID: c.RunID, TurnID: turn, PersonaID: s.PersonaID, AgentID: c.Agent.ID,
		RepoUrl: repo.RepoUrl, Branch: in.Branch, Title: in.Title, Body: in.Body, Draft: in.Draft,
	})
	if err != nil {
		return nil, err
	}
	superseded, err := d.Q.SupersedePushRequests(ctx, store.SupersedePushRequestsParams{ChatID: s.ChatID, RepoUrl: repo.RepoUrl, Branch: in.Branch, ID: r.ID})
	if err != nil {
		return nil, err
	}
	if d.DiscardPush != nil {
		for _, old := range superseded {
			if old.StagingRef != nil && *old.StagingRef != "" {
				d.DiscardPush(ctx, old)
			}
		}
	}
	auto := false
	if p, err := d.Q.GetRepositoryPushPolicy(ctx, store.GetRepositoryPushPolicyParams{UserID: s.UserID, RepoUrl: repo.RepoUrl}); err == nil {
		auto = p.AutoPush
	}
	tell := "Requested, not pushed. When your turn ends Vesper stages the commit at the tip of " + in.Branch +
		" (uncommitted changes are left out, so commit everything first) and the person approves the push and pull request on a card in this chat. Don't say it's pushed or that a pull request exists; the Repositories section of your next turn shows how it went."
	if auto {
		tell = "Requested. The person always allows pushes to this repository: when your turn ends Vesper stages the commit at the tip of " + in.Branch +
			" (uncommitted changes are left out, so commit everything first), pushes it and opens the pull request. Say it will be pushed when your turn ends, not that it's done."
	}
	return map[string]any{"request_id": r.ID, "state": r.State, "repository": repo.RepoUrl, "branch": in.Branch, "tell_the_person": tell}, nil
}
