package pushreq

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

// StagingPrefix names the branches the runner stages reviewed commits on,
// under the namespace Vesper already pushes checkpoints to.
const StagingPrefix = "vesper-checkpoint/push/"

// StagingBranch is where request id's commit waits for the person.
func StagingBranch(id fmt.Stringer) string { return StagingPrefix + id.String() }

// Commit is one commit a request ships, as the card lists it.
type Commit struct {
	SHA     string `json:"sha"`
	Subject string `json:"subject"`
}

// Result is what shipping did.
type Result struct {
	PRNumber int
	PRURL    string
	PRState  string
	Opened   bool // false: the branch already had an open pull request, now updated
}

// Refusal is a reason shipping can't go ahead that the person should read
// (the branch moved, the token can't push): the request fails with it, as
// opposed to an error on the way, which leaves nothing changed either.
type Refusal struct{ Reason string }

func (r *Refusal) Error() string { return r.Reason }

// Ship points the request's branch at its reviewed commit and opens its pull
// request. It never force-pushes: a branch that moved since the persona
// staged the commit is refused, and the persona is asked to build on it.
func Ship(ctx context.Context, gh *GitHub, r store.PushRequest) (Result, error) {
	owner, name, ok := ParseRepo(r.RepoUrl)
	if !ok {
		return Result{}, &Refusal{"Vesper only pushes to github.com repositories."}
	}
	if r.HeadSha == nil || r.BaseBranch == nil || *r.HeadSha == "" || *r.BaseBranch == "" {
		return Result{}, &Refusal{"This request was never staged, so there is nothing to push."}
	}
	sha, base := *r.HeadSha, *r.BaseBranch
	current, err := gh.BranchSHA(ctx, owner, name, r.Branch)
	if err != nil {
		return Result{}, refuse(err)
	}
	switch {
	case current == "":
		err = gh.CreateBranch(ctx, owner, name, r.Branch, sha)
	case current != sha:
		err = gh.FastForward(ctx, owner, name, r.Branch, sha)
		var api *APIError
		if errors.As(err, &api) && api.Status == http.StatusUnprocessableEntity {
			return Result{}, &Refusal{fmt.Sprintf("%s moved on GitHub since this was staged, and Vesper never force-pushes. Ask the persona to build on the branch's latest commit and request the push again.", r.Branch)}
		}
	}
	if err != nil {
		return Result{}, refuse(err)
	}
	out := Result{}
	pr, err := gh.OpenPullRequest(ctx, owner, name, r.Branch)
	if err != nil {
		return Result{}, refuse(err)
	}
	if pr == nil {
		title := strings.TrimSpace(r.Title)
		if title == "" {
			title = r.Branch
		}
		if pr, err = gh.CreatePullRequest(ctx, owner, name, r.Branch, base, title, r.Body, r.Draft); err != nil {
			return Result{}, refuse(err)
		}
		out.Opened = true
	}
	out.PRNumber, out.PRURL = pr.Number, pr.HTMLURL
	if pr.Draft || (out.Opened && r.Draft) {
		out.PRState = "draft"
	} else {
		out.PRState = "open"
	}
	if r.StagingRef != nil && *r.StagingRef != "" {
		// Best effort: the branch already shipped, a leftover staging branch is only clutter.
		_ = gh.DeleteBranch(ctx, owner, name, *r.StagingRef)
	}
	return out, nil
}

// refuse turns GitHub's answers that a person can act on into refusals.
func refuse(err error) error {
	var api *APIError
	if errors.As(err, &api) {
		switch api.Status {
		case http.StatusUnauthorized:
			return &Refusal{"GitHub rejected the token in Settings → Connections & secrets (git:pat): " + api.Message}
		case http.StatusForbidden:
			return &Refusal{"The GitHub token can't push to this repository: " + api.Message}
		case http.StatusUnprocessableEntity:
			return &Refusal{"GitHub refused: " + api.Message}
		}
	}
	if errors.Is(err, ErrNotFound) {
		return &Refusal{"GitHub can't find the repository with this token (it may lack access)."}
	}
	return err
}

// Discard drops a declined or replaced request's staging branch, best effort.
func Discard(ctx context.Context, gh *GitHub, r store.PushRequest) {
	owner, name, ok := ParseRepo(r.RepoUrl)
	if !ok || r.StagingRef == nil || *r.StagingRef == "" {
		return
	}
	_ = gh.DeleteBranch(ctx, owner, name, *r.StagingRef)
}

// Finish records how shipping a claimed request went: pushed with its pull
// request, or failed with the refusal's reason. Any other error is recorded
// too, as a failure the person can retry by asking again; the request is
// never left claimed.
func Finish(ctx context.Context, q *store.Queries, r store.PushRequest, res Result, shipErr error) (store.PushRequest, error) {
	if shipErr != nil {
		msg := shipErr.Error()
		var refusal *Refusal
		if !errors.As(shipErr, &refusal) {
			msg = "Pushing failed: " + msg
		}
		return q.FinishPushRequest(ctx, store.FinishPushRequestParams{ID: r.ID, State: "failed", Error: &msg})
	}
	n := int32(res.PRNumber)
	prState := res.PRState
	if prState == "" {
		if r.Draft {
			prState = "draft"
		} else {
			prState = "open"
		}
	}
	out, err := q.FinishPushRequest(ctx, store.FinishPushRequestParams{ID: r.ID, State: "pushed", PrUrl: &res.PRURL, PrNumber: &n, PrState: &prState})
	if err != nil {
		return out, err
	}
	return out, q.AddChatWorkBranch(ctx, store.AddChatWorkBranchParams{ChatID: r.ChatID, RepoUrl: r.RepoUrl, Branch: r.Branch})
}
