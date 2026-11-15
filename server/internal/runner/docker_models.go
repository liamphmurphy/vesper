package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// ModelLister lists the models a plan login offers. The Docker API image has
// no harness CLI, so the runner does it for the API (tickModelListings).
type ModelLister interface {
	// claim names the listing's container, so no two listings share one.
	// login is the saved harness secret; codexScope is where a refreshed
	// Codex login is stored (CodexAuthScope).
	ListModels(ctx context.Context, claim, harness, login, codexScope string) ([]chatmodels.Model, error)
}

const (
	listModelsTimeout = 60 * time.Second
	// maxConcurrentListings caps the throwaway containers listing at once.
	maxConcurrentListings = 4
	// listExitWait is how long the CLI gets to exit after its stdin closes.
	listExitWait = 5 * time.Second
)

// ListModels runs the harness CLI's model-listing protocol in a throwaway
// container with the sign-in sandbox (no volumes) and the saved login.
func (d *Docker) ListModels(ctx context.Context, claim, harness, login, codexScope string) ([]chatmodels.Model, error) {
	argv, err := chatmodels.DiscoveryArgv(harness)
	if err != nil {
		return nil, err
	}
	timeout := d.ModelsTimeout
	if timeout <= 0 {
		timeout = listModelsTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	var models []chatmodels.Model
	err = d.converseCLI(ctx, "models", claim, harness, login, codexScope, argv, func(in io.Writer, out io.Reader) error {
		var err error
		models, err = chatmodels.ListOverStdio(harness, in, out)
		return err
	})
	return models, err
}

// converseCLI runs argv in a throwaway container named for kind and claim,
// with the sign-in sandbox (no volumes) and the saved login: Claude's token in
// the environment, Codex's auth.json as a file. converse talks to the CLI over
// its stdin and stdout; ctx's deadline bounds the whole exchange. A login
// Codex refreshed meanwhile is saved under codexScope.
func (d *Docker) converseCLI(ctx context.Context, kind, claim, harness, login, codexScope string, argv []string, converse func(in io.Writer, out io.Reader) error) error {
	// Ends the stream watcher below when the exchange is over, whatever ctx is.
	ctx, cancel := context.WithCancel(ctx)
	defer cancel()
	env := []string{}
	if harness == agentdef.HarnessClaudeCode && chatmodels.ClaudeOAuthToken(login) {
		env = append(env, ClaudeOAuthEnv+"="+login)
	}
	openStdin := harness != agentdef.HarnessAntigravity
	body := map[string]any{
		"Image": d.Image, "Cmd": argv, "Env": env, "WorkingDir": homePath,
		"Labels": d.labels(kind + "-" + harness),
		"Tty":    false, "OpenStdin": openStdin, "StdinOnce": openStdin, "AttachStdin": openStdin, "AttachStdout": true, "AttachStderr": true,
		"HostConfig": d.hostConfig([]map[string]any{}),
	}
	var created struct{ ID string }
	name := url.QueryEscape("vesper-" + kind + "-" + claim)
	if _, err := d.do(ctx, "POST", "/containers/create?name="+name, jsonBody(body), "application/json", &created); err != nil {
		return err
	}
	started := false
	var stream io.ReadWriteCloser
	defer func() {
		// The caller's context may be what ended; cleanup must still happen.
		cctx, ccancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer ccancel()
		if started {
			// Closing stdin makes the CLI exit. Codex may rotate its token until
			// then, so the login is only read back once the container is done.
			stream.Close()
			wctx, wcancel := context.WithTimeout(context.Background(), listExitWait)
			_, _ = d.do(wctx, "POST", "/containers/"+created.ID+"/wait", nil, "", nil)
			wcancel()
			if harness == agentdef.HarnessClaudeCode && d.SaveClaudeAuth != nil {
				if _, ok := chatmodels.ParseClaudeAuth(login); ok {
					if next, ok := d.refreshedClaudeAuth(cctx, created.ID, login); ok {
						if err := d.SaveClaudeAuth(cctx, codexScope, next); err != nil {
							slog.Warn("save refreshed claude login", "err", err)
						}
					}
				}
			}
			if harness == agentdef.HarnessCodex && d.SaveCodexAuth != nil {
				// Codex rotates its refresh token, so a refreshed login must be kept.
				if next, ok := d.refreshedCodexAuth(cctx, created.ID, login); ok {
					if err := d.SaveCodexAuth(cctx, codexScope, next); err != nil {
						slog.Warn("save refreshed codex login", "err", err)
					}
				}
			}
		}
		_, _ = d.do(cctx, "POST", "/containers/"+created.ID+"/kill?signal=SIGKILL", nil, "", nil)
		_, _ = d.do(cctx, "DELETE", "/containers/"+created.ID+"?force=1", nil, "", nil)
	}()
	var authTar io.Reader
	var tarErr error
	switch harness {
	case agentdef.HarnessClaudeCode:
		if _, ok := chatmodels.ParseClaudeAuth(login); ok {
			authTar, tarErr = claudeAuthTar(login)
		}
	case agentdef.HarnessCodex:
		authTar, tarErr = codexAuthTar(login)
	case agentdef.HarnessAntigravity:
		authTar, tarErr = antigravityAuthTar(login)
	}
	if tarErr != nil {
		return tarErr
	}
	if authTar != nil {
		// A login never travels in the environment: it is a file, as in turns.
		if _, err := d.do(ctx, "PUT", "/containers/"+created.ID+"/archive?path="+url.QueryEscape(homePath), authTar, "application/x-tar", nil); err != nil {
			return err
		}
	}
	st, err := d.attachLogin(created.ID, true)
	if err != nil {
		return err
	}
	stream = st
	defer st.Close()
	if _, err := d.do(ctx, "POST", "/containers/"+created.ID+"/start", nil, "", nil); err != nil {
		return err
	}
	started = true
	// Closing the stream is what unblocks a read when the time runs out.
	go func() { <-ctx.Done(); st.Close() }()
	var stderr cappedBuffer
	stderr.limit = 4 << 10
	r, w := io.Pipe()
	demuxDone := make(chan struct{})
	go func() {
		defer close(demuxDone)
		w.CloseWithError(demux(st, w, &stderr))
	}()
	defer r.Close()
	err = converse(st, r)
	if err != nil {
		// Wait for demux to stop before reading stderr (st.Close unblocks it).
		st.Close()
		<-demuxDone
		if msg := cleanCLIStderr(stderr.buf.String()); msg != "" {
			return fmt.Errorf("%w: %s", err, msg)
		}
	}
	return err
}

type cappedBuffer struct {
	limit int
	buf   bytes.Buffer
}

func (w *cappedBuffer) Write(p []byte) (int, error) {
	if rem := w.limit - w.buf.Len(); rem > 0 {
		w.buf.Write(p[:min(len(p), rem)])
	}
	return len(p), nil
}

func cleanCLIStderr(raw string) string {
	var lines []string
	for _, line := range strings.Split(raw, "\n") {
		if i := strings.LastIndexByte(line, '\r'); i >= 0 {
			line = line[i+1:]
		}
		if line = strings.TrimSpace(line); line != "" {
			lines = append(lines, line)
		}
	}
	return strings.Join(lines, "; ")
}

// expireModelListings marks every saved model listing as due, so the next
// picker load queues a new one. A runner starting may bring a different
// harness CLI, and its aliases ("fable") can resolve to newer models; a
// listing's freshness otherwise depends only on the login. The saved models
// are still served while the new listing runs. Failure only delays the
// refresh until the listing expires on its own, so it doesn't stop the runner.
func (r *Runner) expireModelListings(ctx context.Context) {
	if _, ok := r.Backend.(ModelLister); !ok {
		return
	}
	if _, err := r.q().ExpireModelListings(ctx); err != nil && ctx.Err() == nil {
		r.Log.Warn("expire model listings", "err", err)
	}
}

// tickModelListings answers the model-listing requests the API queued for plan
// logins (chatmodels.QueuedListings). Like sign-ins they take no run slot.
func (r *Runner) tickModelListings(ctx context.Context) {
	ml, ok := r.Backend.(ModelLister)
	if !ok || r.Secrets == nil {
		return
	}
	q := r.q()
	for r.listings.Add(1) <= maxConcurrentListings {
		l, err := q.ClaimModelListing(ctx, &r.Cfg.ID)
		if err != nil {
			r.listings.Add(-1)
			if !errors.Is(err, pgx.ErrNoRows) && ctx.Err() == nil {
				r.Log.Error("claim model listing", "err", err)
			}
			return
		}
		r.wg.Add(1)
		go func() {
			defer r.wg.Done()
			defer r.listings.Add(-1)
			r.runModelListing(ctx, ml, l)
		}()
	}
	r.listings.Add(-1) // the attempt that found the cap reached
}

func (r *Runner) runModelListing(parent context.Context, ml ModelLister, l store.HarnessModelListing) {
	q := r.q()
	// The caller's context may be what ended; the outcome is still recorded.
	// Each write gets its own deadline: listing can outlast any shared one.
	record := func() (context.Context, context.CancelFunc) {
		return context.WithTimeout(context.WithoutCancel(parent), 10*time.Second)
	}
	fail := func(msg string) {
		ctx, cancel := record()
		defer cancel()
		if _, err := q.FailModelListing(ctx, store.FailModelListingParams{ClaimID: l.ClaimID, Error: msg}); err != nil {
			r.Log.Warn("fail model listing", "workspace", l.WorkspaceID, "harness", l.Harness, "err", err)
		}
	}
	login, err := r.Secrets.Reveal(parent, l.WorkspaceID, nil, chatmodels.KeySecret[l.Harness])
	if parent.Err() != nil {
		return // shutting down: the claim times out and another runner retries
	}
	label := "Claude"
	planLogin := chatmodels.ClaudePlanLogin(login)
	badMsg := "The saved login isn't a Claude or ChatGPT plan login."
	switch l.Harness {
	case agentdef.HarnessCodex:
		label = "ChatGPT"
		_, planLogin = chatmodels.ParseCodexAuth(login)
	case agentdef.HarnessAntigravity:
		label = "Antigravity"
		_, planLogin = chatmodels.ParseAntigravityAuth(login)
		badMsg = "The saved login isn't a valid Antigravity login."
	}
	if err != nil || !planLogin {
		fail(badMsg)
		return
	}
	models, err := ml.ListModels(parent, l.ClaimID.String(), l.Harness, login, CodexAuthScope(l.WorkspaceID, nil))
	if err != nil {
		// The error can carry CLI output; keep it out of the database.
		r.Log.Warn("list models", "workspace", l.WorkspaceID, "harness", l.Harness, "err", err)
		if parent.Err() == nil {
			fail("Couldn't list models with the saved " + label + " login. Sign in again in Settings.")
		}
		return
	}
	if len(models) == 0 {
		fail("No chat models available.")
		return
	}
	b, err := json.Marshal(models)
	if err != nil {
		fail("Couldn't list models with the saved " + label + " login. Sign in again in Settings.")
		return
	}
	ctx, cancel := record()
	defer cancel()
	if _, err := q.FinishModelListing(ctx, store.FinishModelListingParams{ClaimID: l.ClaimID, Models: b}); err != nil {
		r.Log.Warn("finish model listing", "workspace", l.WorkspaceID, "harness", l.Harness, "err", err)
	}
}
