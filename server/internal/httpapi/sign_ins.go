package httpapi

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// signInTTL bounds a sign-in: the device codes Codex and GitHub hand out
// expire after 15 minutes.
const signInTTL = 15 * time.Minute

func toSignIn(s store.SignIn) api.SignIn {
	return api.SignIn{
		Id: s.ID, Provider: api.SignInProvider(s.Provider), Status: api.SignInStatus(s.Status),
		Url: s.Url, UserCode: s.UserCode, Error: s.Error, ExpiresAt: s.ExpiresAt,
		NeedsCode: (s.Provider == "claude" || s.Provider == "antigravity") && s.Status == "running" && s.Url != "" && s.PastedCode == nil,
	}
}

func (s *Server) StartSignIn(ctx context.Context, req api.StartSignInRequestObject) (api.StartSignInResponseObject, error) {
	u, _, ws := me(ctx)
	p := req.Body.Provider
	if p != api.SignInProviderClaude && p != api.SignInProviderCodex && p != api.SignInProviderGithub && p != api.SignInProviderAntigravity {
		return nil, apperr.Invalid("provider", "must be claude, codex, github or antigravity")
	}
	if s.Secrets.Box == nil {
		return nil, apperr.Conflict("Secrets can't be stored until SECRETS_KEY is set.")
	}
	live, err := s.Q.LiveIsolatingRunnerExists(ctx)
	if err != nil {
		return nil, err
	}
	if !live {
		return nil, apperr.Conflict("Signing in from Settings needs an active Vesper runner. Start Vesper or add the key by hand.")
	}
	var out store.SignIn
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := s.Q.WithTx(tx)
		if err := q.ExpireSignIns(ctx); err != nil {
			return err
		}
		if err := q.CancelActiveSignIns(ctx, store.CancelActiveSignInsParams{WorkspaceID: ws, Provider: string(p)}); err != nil {
			return err
		}
		out, err = q.CreateSignIn(ctx, store.CreateSignInParams{WorkspaceID: ws, Provider: string(p), RequestedBy: u.ID, ExpiresAt: time.Now().Add(signInTTL)})
		return err
	})
	if err != nil {
		return nil, err
	}
	return api.StartSignIn201JSONResponse(toSignIn(out)), nil
}

func (s *Server) GetSignIn(ctx context.Context, req api.GetSignInRequestObject) (api.GetSignInResponseObject, error) {
	_, _, ws := me(ctx)
	if err := s.Q.ExpireSignIns(ctx); err != nil {
		return nil, err
	}
	row, err := s.Q.GetSignIn(ctx, store.GetSignInParams{ID: req.Id, WorkspaceID: ws})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return api.GetSignIn200JSONResponse(toSignIn(row)), nil
}

func (s *Server) SubmitSignInCode(ctx context.Context, req api.SubmitSignInCodeRequestObject) (api.SubmitSignInCodeResponseObject, error) {
	_, _, ws := me(ctx)
	code := strings.TrimSpace(req.Body.Code)
	// The CLI reads it from a terminal: one line of printable text.
	if code == "" || len(code) > 2000 || strings.ContainsFunc(code, func(r rune) bool { return r < 0x20 || r == 0x7f }) {
		return nil, apperr.Invalid("code", "must be the single-line code from the sign-in page")
	}
	row, err := s.Q.SubmitSignInCode(ctx, store.SubmitSignInCodeParams{ID: req.Id, WorkspaceID: ws, PastedCode: &code})
	if err != nil {
		if !errors.Is(err, pgx.ErrNoRows) {
			return nil, err
		}
		if _, gerr := s.Q.GetSignIn(ctx, store.GetSignInParams{ID: req.Id, WorkspaceID: ws}); errors.Is(gerr, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
		return nil, apperr.Conflict("This sign-in isn't waiting for a code any more.")
	}
	return api.SubmitSignInCode200JSONResponse(toSignIn(row)), nil
}

func (s *Server) CancelSignIn(ctx context.Context, req api.CancelSignInRequestObject) (api.CancelSignInResponseObject, error) {
	_, _, ws := me(ctx)
	n, err := s.Q.CancelSignIn(ctx, store.CancelSignInParams{ID: req.Id, WorkspaceID: ws})
	if err != nil {
		return nil, err
	}
	if n == 0 { // already ended, or not this workspace's
		if _, err := s.Q.GetSignIn(ctx, store.GetSignInParams{ID: req.Id, WorkspaceID: ws}); errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.ErrNotFound
		}
	}
	return api.CancelSignIn204Response{}, nil
}
