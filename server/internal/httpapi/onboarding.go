package httpapi

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// The first-run Welcome Wizard: whether it has been finished, and the
// harness step's Verify.

// harnessConnected reports whether chats have a harness to run on. Runs that
// use the host's CLI logins (the local backend) always do; otherwise one of
// the harness key secrets has to exist. Discovery is too slow for every
// profile read, so this only looks for the secret.
func (s *Server) harnessConnected(ctx context.Context, ws uuid.UUID) (bool, error) {
	if s.Runs == nil || !s.Runs.RequireHarnessKey {
		return true, nil
	}
	for _, name := range chatmodels.KeySecret {
		ok, err := s.Q.SecretExists(ctx, store.SecretExistsParams{WorkspaceID: ws, Name: name})
		if err != nil || ok {
			return ok, err
		}
	}
	return false, nil
}

func (s *Server) CompleteOnboarding(ctx context.Context, _ api.CompleteOnboardingRequestObject) (api.CompleteOnboardingResponseObject, error) {
	u, _, ws := me(ctx)
	out, err := s.Q.CompleteOnboarding(ctx, store.CompleteOnboardingParams{ID: u.ID, WorkspaceID: ws})
	if err != nil {
		return nil, err
	}
	p, err := s.toMe(ctx, out)
	return api.CompleteOnboarding200JSONResponse(p), err
}

// checkHarnessCredential checks a pasted credential has the shape the runner
// recognises for its kind (runner.PlanSecrets): a plan login is a Claude
// setup-token, a Codex auth.json, or an Antigravity login bundle; anything
// else is used as an API key. Messages never quote the value.
func checkHarnessCredential(harness string, kind api.HarnessVerifyRequestKind, v string) error {
	if v == "" {
		return apperr.Invalid("credential", "paste a credential first")
	}
	claudeSub := chatmodels.ClaudePlanLogin(v)
	_, codexLogin := chatmodels.ParseCodexAuth(v)
	_, agyLogin := chatmodels.ParseAntigravityAuth(v)
	switch {
	case harness == agentdef.HarnessClaudeCode && kind == api.Subscription && !claudeSub:
		return apperr.Invalid("credential", "a Claude subscription login is ~/.claude/.credentials.json from `claude auth login --claudeai` or a `sk-ant-oat` setup-token")
	case harness == agentdef.HarnessClaudeCode && kind == api.ApiKey && (claudeSub || !strings.HasPrefix(v, "sk-ant-")):
		return apperr.Invalid("credential", "an Anthropic API key starts with sk-ant-")
	case harness == agentdef.HarnessCodex && kind == api.Subscription && !codexLogin:
		return apperr.Invalid("credential", "paste the whole ~/.codex/auth.json from `codex login` (a ChatGPT sign-in)")
	case harness == agentdef.HarnessCodex && kind == api.ApiKey && (codexLogin || !strings.HasPrefix(v, "sk-")):
		return apperr.Invalid("credential", "an OpenAI API key starts with sk-")
	case harness == agentdef.HarnessAntigravity && kind == api.Subscription && !agyLogin:
		return apperr.Invalid("credential", "sign in to Antigravity in Settings to capture a native Antigravity login")
	case harness == agentdef.HarnessAntigravity && kind == api.ApiKey:
		return apperr.Invalid("credential", "Antigravity uses a native Google Antigravity sign-in rather than an API key")
	case kind != api.Subscription && kind != api.ApiKey:
		return apperr.Invalid("kind", "must be subscription or api_key")
	}
	return nil
}

func (s *Server) VerifyHarness(ctx context.Context, req api.VerifyHarnessRequestObject) (api.VerifyHarnessResponseObject, error) {
	_, _, ws := me(ctx)
	name := string(req.Harness)
	if _, ok := chatmodels.KeySecret[name]; !ok {
		return nil, apperr.Invalid("harness", "unknown harness %q", name)
	}
	cat := s.Runs.ChatCatalog()
	if b := req.Body; b != nil {
		// Runs on the host use its CLI sign-ins and would never check a
		// pasted key, yet the runner would still inject it.
		if !s.Runs.RequireHarnessKey {
			return nil, apperr.Invalid("credential", "this server's runs use the claude, codex and agy sign-ins on its host: sign the CLI in there and verify without pasting")
		}
		v := strings.TrimSpace(b.Credential)
		if err := checkHarnessCredential(name, b.Kind, v); err != nil {
			return nil, err
		}
		if s.Secrets == nil {
			return nil, secrets.ErrNoKey
		}
		if !chatmodels.PlanLogin(name, v) {
			// An API key is checked before it replaces anything.
			models, err := cat.CheckKey(ctx, name, v)
			if err != nil || len(models) == 0 {
				return verifyResult(chatmodels.Harness{UnavailableReason: verifyFailure(err)}), nil
			}
		}
		return s.storeHarnessKey(ctx, cat, ws, name, v)
	}
	h, _, err := cat.Check(ctx, s.Q, ws, name)
	if err != nil {
		return nil, err
	}
	return verifyResult(h), nil
}

func verifyFailure(err error) string {
	if err != nil {
		return err.Error()
	}
	return "no chat models available"
}

// storeHarnessKey stores v as the harness's key and lists its models. A plan
// login can only be listed once stored (a runner reads it), so when that
// fails the earlier value is put back, or the new one removed: a bad paste
// never replaces a working credential. A listing still pending keeps a first
// login, for the next Verify (without a credential) to follow, but never
// replaces an earlier one: nothing would be left to restore if it then failed.
func (s *Server) storeHarnessKey(ctx context.Context, cat chatmodels.Catalog, ws uuid.UUID, name, v string) (api.VerifyHarnessResponseObject, error) {
	u, _, _ := me(ctx)
	secret := chatmodels.KeySecret[name]
	had, err := s.Q.SecretExists(ctx, store.SecretExistsParams{WorkspaceID: ws, Name: secret})
	if err != nil {
		return nil, err
	}
	var prev string
	if had {
		// An unreadable earlier value is nothing worth restoring.
		if prev, err = s.Secrets.Reveal(ctx, ws, nil, secret); err != nil {
			had = false
		}
	}
	saved, err := s.Secrets.Set(ctx, ws, u.ID, secrets.SetInput{Name: secret, Value: v})
	if err != nil {
		return nil, err
	}
	h, _, err := cat.Check(ctx, s.Q, ws, name)
	if err == nil && (h.Available && len(h.Models) > 0 || h.Checking && !had) {
		return verifyResult(h), nil
	}
	if err == nil && h.Checking {
		h = chatmodels.Harness{UnavailableReason: "The runner hasn't listed the new login's models yet, so the working one stays. Try again once the runner is up, or replace it in Settings → Provider credentials."}
	}
	// Restore with a fresh context: the request's may be what failed.
	rctx := context.WithoutCancel(ctx)
	if had {
		_, rerr := s.Secrets.Set(rctx, ws, u.ID, secrets.SetInput{Name: secret, Value: prev})
		err = errors.Join(err, rerr)
	} else {
		_, rerr := s.Q.DeleteSecret(rctx, store.DeleteSecretParams{ID: saved.ID, WorkspaceID: ws})
		err = errors.Join(err, rerr)
	}
	if err != nil {
		return nil, err
	}
	return verifyResult(h), nil
}

func verifyResult(h chatmodels.Harness) api.VerifyHarness200JSONResponse {
	out := api.VerifyHarness200JSONResponse{Ok: h.Available && len(h.Models) > 0}
	out.Models = make([]struct {
		Id    string `json:"id"`
		Label string `json:"label"`
	}, len(h.Models))
	for i, m := range h.Models {
		out.Models[i].Id, out.Models[i].Label = m.ID, m.Label
	}
	if h.Checking {
		out.Checking = &h.Checking
	}
	if !out.Ok && h.UnavailableReason != "" {
		reason := h.UnavailableReason
		out.Error = &reason
	}
	return out
}
