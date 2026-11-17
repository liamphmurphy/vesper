package runner

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/playground"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// PlaygroundConfig is how a runner serves chats' playgrounds.
type PlaygroundConfig struct {
	// Ports the gateway listens on, one playground each (RUNNER_PLAYGROUND_PORTS).
	// None turns playgrounds off for this runner.
	Ports []int
	// Host is the address the ports listen on; "" means every interface,
	// which a container needs (compose publishes them on loopback only).
	Host string
	// IdleTTL stops a playground nobody has made a request to for this long.
	// 0 means DefaultPlaygroundIdleTTL.
	IdleTTL time.Duration
	// Origins are Vesper's own (WEB_URL, PUBLIC_URL), which may read a
	// playground across origins.
	Origins []string
}

// DefaultPlaygroundIdleTTL is how long an unused playground keeps running.
const DefaultPlaygroundIdleTTL = 30 * time.Minute

// playgroundHost is what a runner process holds of the playgrounds it serves.
type playgroundHost struct {
	gateway *playground.Gateway
	mu      sync.Mutex
	free    []int
	ports   map[uuid.UUID]int  // held playground → its port
	busy    map[uuid.UUID]bool // starting, restarting or stopping
}

func (r *Runner) playgroundBackend() (PlaygroundBackend, bool) {
	pb, ok := r.Backend.(PlaygroundBackend)
	return pb, ok && r.playgrounds != nil
}

// ServePlaygrounds serves the gateway's ports until ctx ends, and marks what
// an earlier runner process of this install held as stopped: Cleanup removed
// its containers. Run calls it after Recover.
func (r *Runner) ServePlaygrounds(ctx context.Context) {
	pb, ok := r.Backend.(PlaygroundBackend)
	if !ok || len(r.Cfg.Playgrounds.Ports) == 0 {
		return
	}
	if err := r.q().StopStackPlaygrounds(ctx, store.StopStackPlaygroundsParams{Stack: refOf(pb.StackName()), Reason: "Vesper's runner restarted"}); err != nil {
		r.Log.Warn("playgrounds: mark the previous runner's stopped", "err", err)
	}
	h := &playgroundHost{
		gateway: &playground.Gateway{
			Session: func(ctx context.Context, token string) (bool, error) { return auth.ValidSession(ctx, r.q(), token) },
			Origins: r.Cfg.Playgrounds.Origins,
			Backend: pb,
			Log:     r.Log,
		},
		ports: map[uuid.UUID]int{},
		busy:  map[uuid.UUID]bool{},
	}
	for _, port := range r.Cfg.Playgrounds.Ports {
		ln, err := net.Listen("tcp", net.JoinHostPort(r.Cfg.Playgrounds.Host, strconv.Itoa(port)))
		if err != nil {
			r.Log.Warn("playgrounds: can't serve port", "port", port, "err", err)
			continue
		}
		srv := &http.Server{Handler: h.gateway.Handler(port), ReadHeaderTimeout: 30 * time.Second}
		go func() { _ = srv.Serve(ln) }()
		go func() {
			<-ctx.Done()
			sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = srv.Shutdown(sctx)
		}()
		h.free = append(h.free, port)
	}
	if len(h.free) > 0 {
		r.playgrounds = h
		r.Log.Info("playgrounds served", "ports", h.free)
		r.wg.Add(1)
		go func() {
			defer r.wg.Done()
			r.pullPlaygroundImages(ctx, pb)
		}()
	}
}

// pullPlaygroundImages pulls, in the background, the service images recent
// playgrounds used that aren't here (a new machine, or a pruned Docker), so
// the next start doesn't wait on the download. One at a time: a start that
// needs an image meanwhile shouldn't share the bandwidth with all of them.
func (r *Runner) pullPlaygroundImages(ctx context.Context, pb PlaygroundBackend) {
	images, err := r.q().RecentPlaygroundImages(ctx, pb.StackName())
	if err != nil {
		if ctx.Err() == nil {
			r.Log.Warn("playgrounds: list recent images", "err", err)
		}
		return
	}
	for _, image := range images {
		pulled, err := pb.PullMissing(ctx, image)
		switch {
		case ctx.Err() != nil:
			return
		case err != nil:
			// Not fatal: a start pulls it again and reports why it can't.
			r.Log.Warn("playgrounds: pull a recent image", "image", image, "err", err)
		case pulled:
			r.Log.Info("playgrounds: pulled a recent image", "image", image)
		}
	}
}

func (h *playgroundHost) take(id uuid.UUID) (int, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.free) == 0 {
		return 0, false
	}
	port := h.free[0]
	h.free = h.free[1:]
	h.ports[id] = port
	h.busy[id] = true
	return port, true
}

// release gives a playground's port back; it isn't busy any more.
func (h *playgroundHost) release(id uuid.UUID) {
	h.mu.Lock()
	defer h.mu.Unlock()
	if port, ok := h.ports[id]; ok {
		h.gateway.Stop(port)
		h.free = append(h.free, port)
		delete(h.ports, id)
	}
	delete(h.busy, id)
}

// claim marks a held playground busy unless it already is.
func (h *playgroundHost) claim(id uuid.UUID) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, held := h.ports[id]; !held || h.busy[id] {
		return false
	}
	h.busy[id] = true
	return true
}

func (h *playgroundHost) done(id uuid.UUID) {
	h.mu.Lock()
	defer h.mu.Unlock()
	delete(h.busy, id)
}

func (h *playgroundHost) port(id uuid.UUID) (int, bool) {
	h.mu.Lock()
	defer h.mu.Unlock()
	p, ok := h.ports[id]
	return p, ok
}

// tickPlaygrounds carries out what was asked of held playgrounds, then
// claims waiting ones whose workspace is here. Starting and stopping run off
// the poll loop: a setup can take minutes.
func (r *Runner) tickPlaygrounds(ctx context.Context) {
	pb, ok := r.playgroundBackend()
	if !ok {
		return
	}
	h := r.playgrounds
	q := r.q()
	held, err := q.HeldPlaygrounds(ctx, &r.Cfg.ID)
	if err != nil {
		if ctx.Err() == nil {
			r.Log.Error("playgrounds: list held", "err", err)
		}
		return
	}
	for _, pg := range held {
		r.refreshPlaygroundOpenAPI(pg)
		if pg.Action != nil && h.claim(pg.ID) {
			r.wg.Add(1)
			go func() {
				defer r.wg.Done()
				r.playgroundAction(ctx, pb, pg)
			}()
		}
	}
	waiting, err := q.StartingPlaygrounds(ctx)
	if err != nil {
		if ctx.Err() == nil {
			r.Log.Error("playgrounds: list waiting", "err", err)
		}
		return
	}
	for _, pg := range waiting {
		if pg.RunID == nil {
			continue
		}
		if has, err := r.Backend.HasWorkspace(ctx, pg.RunID.String()); err != nil || !has {
			continue // another runner's workspace
		}
		port, ok := h.take(pg.ID)
		if !ok {
			msg := fmt.Sprintf("Every playground this runner can serve is in use (%d). Stop one in its chat, then start this one again.", len(r.Cfg.Playgrounds.Ports))
			if err := q.RefusePlayground(ctx, store.RefusePlaygroundParams{ID: pg.ID, Error: &msg}); err != nil && ctx.Err() == nil {
				r.Log.Warn("playgrounds: refuse", "playground", pg.ID, "err", err)
			}
			continue
		}
		claimed, err := q.ClaimPlayground(ctx, store.ClaimPlaygroundParams{ID: pg.ID, RunnerID: &r.Cfg.ID, Stack: refOf(pb.StackName()), Port: refOf(int32(port)), IdleTtlS: refOf(int32(max(1, r.playgroundIdleTTL().Seconds())))})
		if err != nil {
			h.release(pg.ID)
			if !errors.Is(err, pgx.ErrNoRows) && ctx.Err() == nil {
				r.Log.Warn("playgrounds: claim", "playground", pg.ID, "err", err)
			}
			continue
		}
		r.wg.Add(1)
		go func() {
			defer r.wg.Done()
			defer h.done(claimed.ID)
			r.runPlayground(ctx, pb, claimed, port, false)
		}()
	}
}

// runPlayground starts a held playground fresh and serves it. reset keeps
// started_at and the branch: only the data is new.
func (r *Runner) runPlayground(ctx context.Context, pb PlaygroundBackend, pg store.Playground, port int, reset bool) {
	h := r.playgrounds
	q := r.q()
	var spec playground.Spec
	if err := json.Unmarshal(pg.Spec, &spec); err != nil {
		r.failPlayground(ctx, pb, pg, err)
		return
	}
	if err := spec.Validate(); err != nil {
		r.failPlayground(ctx, pb, pg, err)
		return
	}
	h.gateway.Stop(port)
	timer := newStepTimer(r.Log.With("playground", pg.ID))
	step := func(s string) {
		timer.step(s)
		if err := q.SetPlaygroundStep(ctx, store.SetPlaygroundStepParams{ID: pg.ID, RunnerID: &r.Cfg.ID, Step: s}); err != nil && ctx.Err() == nil {
			r.Log.Warn("playgrounds: step", "playground", pg.ID, "err", err)
		}
	}
	addrs, err := pb.StartPlayground(ctx, PlaygroundRun{ID: pg.ID, RunID: pg.RunID.String(), Spec: spec}, step)
	timer.done(err)
	if err != nil {
		r.failPlayground(ctx, pb, pg, err)
		return
	}
	if reset {
		err = q.SetPlaygroundDataReset(ctx, store.SetPlaygroundDataResetParams{ID: pg.ID, RunnerID: &r.Cfg.ID})
	} else {
		_, err = q.SetPlaygroundRunning(ctx, store.SetPlaygroundRunningParams{ID: pg.ID, RunnerID: &r.Cfg.ID, Branch: r.playgroundBranchIn(ctx, pg.RunID.String(), spec.Directory)})
	}
	if errors.Is(err, pgx.ErrNoRows) {
		// Stopped or failed by someone else meanwhile.
		_ = pb.StopPlayground(ctx, pg.ID)
		h.release(pg.ID)
		return
	}
	if err != nil {
		r.Log.Warn("playgrounds: mark running", "playground", pg.ID, "err", err)
	}
	if spec.OpenAPI != "" {
		spec.OpenAPI = path.Join(spec.Directory, spec.OpenAPI)
	}
	h.gateway.Serve(port, &playground.Live{ID: pg.ID, Spec: spec, Addrs: addrs})
}

// playgroundAction carries out a reset, restart or stop asked of a held
// playground.
func (r *Runner) playgroundAction(ctx context.Context, pb PlaygroundBackend, pg store.Playground) {
	h := r.playgrounds
	defer h.done(pg.ID)
	action := *pg.Action
	if action == "stop" {
		r.stopPlayground(ctx, pb, pg.ID, "Stopped")
		return
	}
	port, ok := h.port(pg.ID)
	if !ok {
		return
	}
	if action == "reset" {
		if err := r.q().SetPlaygroundStep(ctx, store.SetPlaygroundStepParams{ID: pg.ID, RunnerID: &r.Cfg.ID, Step: "Resetting data"}); err != nil && ctx.Err() == nil {
			r.Log.Warn("playgrounds: step", "playground", pg.ID, "err", err)
		}
	}
	r.runPlayground(ctx, pb, pg, port, action == "reset")
	if err := r.q().ClearPlaygroundAction(ctx, store.ClearPlaygroundActionParams{ID: pg.ID, RunnerID: &r.Cfg.ID, Action: &action}); err != nil && ctx.Err() == nil {
		r.Log.Warn("playgrounds: clear action", "playground", pg.ID, "err", err)
	}
}

func (r *Runner) stopPlayground(ctx context.Context, pb PlaygroundBackend, id uuid.UUID, reason string) {
	r.playgrounds.gateway.Stop(r.playgroundPort(id))
	if err := pb.StopPlayground(ctx, id); err != nil {
		r.Log.Warn("playgrounds: remove containers", "playground", id, "err", err)
	}
	if err := r.q().StopPlayground(context.WithoutCancel(ctx), store.StopPlaygroundParams{ID: id, RunnerID: &r.Cfg.ID, Reason: reason}); err != nil {
		r.Log.Warn("playgrounds: mark stopped", "playground", id, "err", err)
	}
	r.playgrounds.release(id)
}

func (r *Runner) playgroundPort(id uuid.UUID) int {
	p, _ := r.playgrounds.port(id)
	return p
}

func (r *Runner) failPlayground(ctx context.Context, pb PlaygroundBackend, pg store.Playground, err error) {
	msg, log := err.Error(), ""
	var perr *PlaygroundError
	if errors.As(err, &perr) {
		msg, log = perr.Msg, perr.Log
	}
	if stopErr := pb.StopPlayground(ctx, pg.ID); stopErr != nil {
		r.Log.Warn("playgrounds: remove containers", "playground", pg.ID, "err", stopErr)
	}
	if err := r.q().FailPlayground(context.WithoutCancel(ctx), store.FailPlaygroundParams{ID: pg.ID, RunnerID: &r.Cfg.ID, Error: &msg, ErrorLog: log}); err != nil {
		r.Log.Warn("playgrounds: mark failed", "playground", pg.ID, "err", err)
	}
	r.playgrounds.release(pg.ID)
}

// playgroundBranch is the branch the workspace has checked out, for the
// person's orientation; "" when it can't be read.
func (r *Runner) playgroundBranch(ctx context.Context, runID string) string {
	return r.playgroundBranchIn(ctx, runID, "")
}
func (r *Runner) playgroundBranchIn(ctx context.Context, runID, dir string) string {
	rc, _, err := r.Backend.OpenWorkspaceFile(ctx, runID, path.Join(dir, ".git/HEAD"), 1024)
	if err != nil {
		return ""
	}
	defer rc.Close()
	b, _ := io.ReadAll(io.LimitReader(rc, 1024))
	ref, ok := strings.CutPrefix(strings.TrimSpace(string(b)), "ref: refs/heads/")
	if !ok {
		return ""
	}
	return ref
}

// sweepPlaygrounds records when each served playground was last used, stops
// those idle past the TTL, and removes containers of playgrounds this
// process doesn't hold (a chat deleted while its playground ran).
func (r *Runner) sweepPlaygrounds(ctx context.Context) {
	pb, ok := r.playgroundBackend()
	if !ok {
		return
	}
	h := r.playgrounds
	ttl := r.playgroundIdleTTL()
	h.mu.Lock()
	held := make(map[uuid.UUID]int, len(h.ports))
	for id, port := range h.ports {
		held[id] = port
	}
	h.mu.Unlock()
	q := r.q()
	for id, port := range held {
		live := h.gateway.Serving(port)
		if live == nil || live.ID != id {
			continue // still starting
		}
		used := live.LastUsed()
		if err := q.TouchPlaygrounds(ctx, store.TouchPlaygroundsParams{Ids: []uuid.UUID{id}, UsedAt: &used}); err != nil && ctx.Err() == nil {
			r.Log.Warn("playgrounds: record use", "playground", id, "err", err)
		}
		if time.Since(used) > ttl && h.claim(id) {
			r.stopPlayground(ctx, pb, id, fmt.Sprintf("Stopped after %d min unused", max(1, int(ttl.Minutes()))))
		}
	}
	running, err := pb.RunningPlaygrounds(ctx)
	if err != nil {
		return
	}
	for _, id := range running {
		if _, ok := held[id]; !ok {
			if err := pb.StopPlayground(ctx, id); err != nil {
				r.Log.Warn("playgrounds: remove orphan", "playground", id, "err", err)
			}
		}
	}
}

// refreshPlaygroundOpenAPI points a served playground's API tab at the
// document its row now names (one the persona just inferred) without a
// restart.
func (r *Runner) refreshPlaygroundOpenAPI(pg store.Playground) {
	port, ok := r.playgrounds.port(pg.ID)
	if !ok {
		return
	}
	live := r.playgrounds.gateway.Serving(port)
	if live == nil || live.ID != pg.ID {
		return
	}
	var spec playground.Spec
	if json.Unmarshal(pg.Spec, &spec) != nil {
		return
	}
	if spec.OpenAPI != "" {
		spec.OpenAPI = path.Join(spec.Directory, spec.OpenAPI)
	}
	if ref := (playground.OpenAPIRef{Path: spec.OpenAPI, Inferred: spec.OpenAPIInferred, Commit: spec.OpenAPICommit}); ref != live.OpenAPI() {
		live.SetOpenAPI(ref)
	}
}

// turnPlayground puts a chat's turn on its running playground's network, so
// the agent can use the app as the person does (curl, or a browser it
// drives), through the gateway at PLAYGROUND_URL. The token admits it, and
// is redacted from the run's events like its other secrets; the person can
// open the playground anyway, so a reply that quotes it gives nothing away.
func (r *Runner) turnPlayground(ctx context.Context, c runCtx, env, sensitive map[string]string) []string {
	pb, ok := r.playgroundBackend()
	if !ok || c.run.Purpose != "chat" {
		return nil
	}
	pgs, err := r.q().PlaygroundsForRun(ctx, &c.run.ID)
	if err != nil {
		r.Log.Warn("playgrounds: for the turn", "run", c.run.ID, "err", err)
		return nil
	}
	for _, pg := range pgs {
		port, held := r.playgrounds.port(pg.ID)
		if pg.State != "running" || !held {
			continue
		}
		live := r.playgrounds.gateway.Serving(port)
		if live == nil || live.ID != pg.ID {
			continue
		}
		base := fmt.Sprintf("http://%s:%d", PlaygroundHost, port)
		env["PLAYGROUND_URL"] = base
		env["PLAYGROUND_TOKEN"] = live.Token
		env["PLAYGROUND_ENTER_URL"] = base + playground.ReservedPrefix + "/enter?token=" + live.Token
		sensitive["PLAYGROUND_TOKEN"] = live.Token
		return []string{pb.PlaygroundNetwork(pg.ID)}
	}
	return nil
}

func (r *Runner) playgroundIdleTTL() time.Duration {
	if r.Cfg.Playgrounds.IdleTTL <= 0 {
		return DefaultPlaygroundIdleTTL
	}
	return r.Cfg.Playgrounds.IdleTTL
}

// stopRunPlaygrounds stops the playgrounds running a workspace about to be
// removed.
func (r *Runner) stopRunPlaygrounds(ctx context.Context, runID uuid.UUID) {
	pb, ok := r.playgroundBackend()
	if !ok {
		return
	}
	pgs, err := r.q().PlaygroundsForRun(ctx, &runID)
	if err != nil {
		return
	}
	for _, pg := range pgs {
		if _, held := r.playgrounds.port(pg.ID); held {
			r.stopPlayground(ctx, pb, pg.ID, "The chat went idle and its workspace was cleaned up")
		}
	}
}

// stepTimer logs how long each step of a playground's start took, and the
// whole start, so a slow one shows where its time went. The row only keeps
// the current step.
type stepTimer struct {
	log     *slog.Logger
	now     func() time.Time
	began   time.Time
	current string
	since   time.Time
}

func newStepTimer(log *slog.Logger) *stepTimer {
	t := &stepTimer{log: log, now: time.Now}
	t.began = t.now()
	return t
}

func (t *stepTimer) step(name string) {
	t.finishStep()
	t.current, t.since = name, t.now()
}

func (t *stepTimer) finishStep() {
	if t.current != "" {
		t.log.Info("playground step", "step", t.current, "took", t.now().Sub(t.since).Round(time.Millisecond))
	}
	t.current = ""
}

// done ends the last step and logs the start as a whole; err is why it
// failed, or nil.
func (t *stepTimer) done(err error) {
	failedAt := t.current
	t.finishStep()
	took := t.now().Sub(t.began).Round(time.Millisecond)
	if err != nil {
		t.log.Info("playground start failed", "at", failedAt, "took", took)
		return
	}
	t.log.Info("playground started", "took", took)
}

func refOf[T any](v T) *T { return &v }
