package runner

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"slices"
	"sort"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// DefaultWarmSessionTTL keeps a chat's initialized stdio harness process alive
// across back-to-back turns (e.g. Live Voice) so follow-up messages skip CLI
// boot, MCP handshake, and session resume/load.
const DefaultWarmSessionTTL = 3 * time.Minute

type warmSession struct {
	runID       uuid.UUID
	fingerprint string
	proc        Process
	procCancel  context.CancelFunc
	sess        harness.PersistentSession
	agentID     uuid.UUID
	tokenID     uuid.UUID
	sensitive   map[string]string
	onRevoke    func(agentID, tokenID uuid.UUID)

	stderrMu   sync.Mutex
	stderrBuf  bytes.Buffer
	stderrDone chan struct{}

	idleMu    sync.Mutex
	idleTimer *time.Timer
	closeOnce sync.Once
}

func newWarmSession(runID uuid.UUID, fp string, proc Process, procCancel context.CancelFunc, sess harness.PersistentSession, agentID, tokenID uuid.UUID, sensitive map[string]string, onRevoke func(agentID, tokenID uuid.UUID)) *warmSession {
	ws := &warmSession{
		runID:       runID,
		fingerprint: fp,
		proc:        proc,
		procCancel:  procCancel,
		sess:        sess,
		agentID:     agentID,
		tokenID:     tokenID,
		sensitive:   sensitive,
		onRevoke:    onRevoke,
		stderrDone:  make(chan struct{}),
	}
	go func() {
		defer close(ws.stderrDone)
		sc := bufio.NewScanner(proc.Stderr())
		sc.Buffer(make([]byte, 64<<10), 4<<20)
		for sc.Scan() {
			ws.stderrMu.Lock()
			if ws.stderrBuf.Len() < 1<<20 {
				ws.stderrBuf.WriteString("[stderr] ")
				ws.stderrBuf.Write(sc.Bytes())
				ws.stderrBuf.WriteByte('\n')
			}
			ws.stderrMu.Unlock()
		}
		_, _ = io.Copy(io.Discard, proc.Stderr())
	}()
	return ws
}

func (w *warmSession) resetStderr() {
	w.stderrMu.Lock()
	w.stderrBuf.Reset()
	w.stderrMu.Unlock()
}

func (w *warmSession) takeStderr() []byte {
	w.stderrMu.Lock()
	defer w.stderrMu.Unlock()
	if w.stderrBuf.Len() == 0 {
		return nil
	}
	out := append([]byte(nil), w.stderrBuf.Bytes()...)
	w.stderrBuf.Reset()
	return out
}

func (w *warmSession) stopTimer() {
	w.idleMu.Lock()
	if w.idleTimer != nil {
		w.idleTimer.Stop()
		w.idleTimer = nil
	}
	w.idleMu.Unlock()
}

func (w *warmSession) close() {
	w.closeOnce.Do(func() {
		w.stopTimer()
		if w.sess != nil {
			_ = w.sess.Close()
		}
		if w.proc != nil {
			waitDone := make(chan struct{})
			go func() {
				_, _ = io.Copy(io.Discard, w.proc.Stdout())
				_, _ = w.proc.Wait()
				close(waitDone)
			}()
			select {
			case <-waitDone:
			case <-time.After(2 * time.Second):
				_ = w.proc.Kill()
				if w.procCancel != nil {
					w.procCancel()
				}
				select {
				case <-waitDone:
				case <-time.After(2 * time.Second):
				}
			}
			select {
			case <-w.stderrDone:
			case <-time.After(time.Second):
			}
		}
		if w.procCancel != nil {
			w.procCancel()
		}
		if w.onRevoke != nil && w.tokenID != uuid.Nil {
			w.onRevoke(w.agentID, w.tokenID)
		}
	})
}

type warmSessionPool struct {
	mu       sync.Mutex
	sessions map[uuid.UUID]*warmSession
}

func (p *warmSessionPool) take(runID uuid.UUID, fingerprint string) *warmSession {
	p.mu.Lock()
	ws := p.sessions[runID]
	if ws != nil {
		delete(p.sessions, runID)
	}
	p.mu.Unlock()
	if ws == nil {
		return nil
	}
	ws.stopTimer()
	if ws.fingerprint == fingerprint && ws.sess.Alive() {
		return ws
	}
	go ws.close()
	return nil
}

func (p *warmSessionPool) put(ws *warmSession, ttl time.Duration) {
	if ws == nil || ttl <= 0 || !ws.sess.Alive() {
		if ws != nil {
			go ws.close()
		}
		return
	}
	p.mu.Lock()
	if p.sessions == nil {
		p.sessions = make(map[uuid.UUID]*warmSession)
	}
	prev := p.sessions[ws.runID]
	p.sessions[ws.runID] = ws
	p.mu.Unlock()
	if prev != nil && prev != ws {
		go prev.close()
	}
	ws.idleMu.Lock()
	ws.idleTimer = time.AfterFunc(ttl, func() {
		p.evictIf(ws.runID, ws)
	})
	ws.idleMu.Unlock()
}

func (p *warmSessionPool) evictIf(runID uuid.UUID, target *warmSession) {
	p.mu.Lock()
	ws := p.sessions[runID]
	if ws != target {
		p.mu.Unlock()
		return
	}
	delete(p.sessions, runID)
	p.mu.Unlock()
	ws.close()
}

func (p *warmSessionPool) evict(runID uuid.UUID) {
	p.mu.Lock()
	ws := p.sessions[runID]
	delete(p.sessions, runID)
	p.mu.Unlock()
	if ws != nil {
		ws.close()
	}
}

func (p *warmSessionPool) closeAll() {
	p.mu.Lock()
	all := p.sessions
	p.sessions = nil
	p.mu.Unlock()
	var wg sync.WaitGroup
	for _, ws := range all {
		wg.Add(1)
		go func(w *warmSession) {
			defer wg.Done()
			w.close()
		}(ws)
	}
	wg.Wait()
}

// CloseWarmSessions shuts down every parked warm harness process and revokes
// its token.
func (r *Runner) CloseWarmSessions() {
	r.warmSessions.closeAll()
}

func (r *Runner) revokeToken(agentID, tokenID uuid.UUID) {
	if r.Pool == nil || tokenID == uuid.Nil {
		return
	}
	qctx, cancel := context.WithTimeout(context.Background(), controlTimeout)
	defer cancel()
	_ = agents.RevokeToken(qctx, r.q(), agentID, tokenID)
}

func warmSessionEligible(r *Runner, c runCtx, h harness.Harness, spec agentdef.Resolved, handoff string, turn store.RunTurn) bool {
	if r.Cfg.WarmSessionTTL <= 0 || c.run.Purpose != "chat" || handoff != "" || turn.Trigger == "delegation" {
		return false
	}
	if _, ok := h.(harness.PersistentSessionHarness); !ok {
		return false
	}
	if c.chatRepoAtStart != nil && *c.chatRepoAtStart != "" {
		return false
	}
	if spec.Harness == agentdef.HarnessAntigravity && spec.HarnessOptions[agentdef.OptionImageGeneration] == "true" {
		return false
	}
	return true
}

func warmSessionFingerprint(spec agentdef.Resolved, dir string, section []byte, files map[string][]byte, env map[string]string) string {
	h := sha256.New()
	write := func(parts ...string) {
		for _, p := range parts {
			_, _ = h.Write([]byte(p))
			_, _ = h.Write([]byte{0})
		}
	}
	write(spec.Harness, spec.Model, dir)
	_, _ = h.Write(section)
	_, _ = h.Write([]byte{0})

	optKeys := make([]string, 0, len(spec.HarnessOptions))
	for k := range spec.HarnessOptions {
		optKeys = append(optKeys, k)
	}
	sort.Strings(optKeys)
	for _, k := range optKeys {
		write("opt", k, spec.HarnessOptions[k])
	}

	skills := slices.Clone(spec.Skills)
	sort.Slice(skills, func(i, j int) bool {
		if skills[i].Name != skills[j].Name {
			return skills[i].Name < skills[j].Name
		}
		return skills[i].Body < skills[j].Body
	})
	for _, s := range skills {
		write("skill", s.Name, s.Description, s.Body)
	}

	fileKeys := make([]string, 0, len(files))
	for k := range files {
		fileKeys = append(fileKeys, k)
	}
	sort.Strings(fileKeys)
	for _, k := range fileKeys {
		write("file", k)
		_, _ = h.Write(files[k])
		_, _ = h.Write([]byte{0})
	}

	envKeys := make([]string, 0, len(env))
	for k := range env {
		envKeys = append(envKeys, k)
	}
	sort.Strings(envKeys)
	for _, k := range envKeys {
		write("env", k, env[k])
	}
	return hex.EncodeToString(h.Sum(nil))
}

// runWarmTurn executes one turn against an already-open PersistentSession,
// returning whether any output/activity arrived before exit (so a dead parked
// session can transparently retry on a cold start).
func (r *Runner) runWarmTurn(
	ctx context.Context,
	c runCtx,
	ws *warmSession,
	turn harness.Turn,
	remaining time.Duration,
	check harness.PolicyFunc,
	onSession func(string),
	onTextDelta func(string),
	recordContext bool,
) (res harness.Result, rawBytes []byte, exitCode int, sawActivity bool, err error) {
	writeContext := func(wctx context.Context, n int64) {
		qctx, cancel := context.WithTimeout(wctx, controlTimeout)
		defer cancel()
		if err := r.q().SetRunContextTokens(qctx, store.SetRunContextTokensParams{ID: c.run.ID, ContextTokens: n}); err != nil {
			r.Log.Warn("record context tokens", "run", c.run.ID, "err", err)
		}
	}

	ws.resetStderr()
	readCtx, cancelReads := context.WithCancel(ctx)
	defer cancelReads()
	toolCtx, cancelTools := context.WithCancel(readCtx)
	defer cancelTools()

	var raw bytes.Buffer
	var rawMu sync.Mutex
	appendRaw := func(prefix string, b []byte) {
		rawMu.Lock()
		defer rawMu.Unlock()
		if raw.Len() < 64<<20 {
			raw.WriteString(prefix)
			raw.Write(b)
			raw.WriteByte('\n')
		}
	}

	var ctrl atomic.Pointer[harness.SessionControl]
	var activity atomic.Bool
	cw := &contextWriter{write: func(n int64) { writeContext(readCtx, n) }}
	var opening openingLine
	streamErrors := make(chan error, 2)

	ch := make(chan pendingRunEvent, runEventBatchMaxEvents*2)
	var flusher sync.WaitGroup
	flusher.Add(1)
	go func() {
		defer flusher.Done()
		r.flushRunEvents(readCtx, c.run.ID, ch)
	}()

	stop := r.supervise(ctx, c, ws.proc, remaining, streamErrors, func() harness.SessionControl {
		if p := ctrl.Load(); p != nil {
			return *p
		}
		return nil
	})

	turnRes, turnErr := ws.sess.RunTurn(readCtx, turn, harness.SessionCallbacks{
		OnRaw: func(line []byte) {
			activity.Store(true)
			appendRaw("", line)
		},
		OnEvent: func(e harness.Event) {
			activity.Store(true)
			payload, b := redactPayload(e.Payload, ws.sensitive)
			opening.see(e.Type, payload)
			select {
			case ch <- pendingRunEvent{typ: e.Type, payload: b}:
			case <-readCtx.Done():
			}
		},
		OnTextDelta: func(delta string) {
			activity.Store(true)
			if onTextDelta != nil {
				onTextDelta(delta)
			}
		},
		OnSession: func(s string) {
			if onSession != nil {
				onSession(s)
			}
		},
		OnContextTokens: func(n int64) {
			if recordContext {
				cw.observe(n)
			}
		},
		OnControl: func(sc harness.SessionControl) {
			if sc != nil {
				ctrl.Store(&sc)
			}
		},
		CheckTool: func(_ context.Context, tool string, input map[string]any) (bool, string) {
			if check == nil {
				return false, "Vesper tool policy unavailable"
			}
			return check(toolCtx, tool, input)
		},
	})
	cancelTools()
	close(ch)
	flusher.Wait()

	expired, supErr := stop()
	for len(streamErrors) > 0 {
		supErr = errors.Join(supErr, <-streamErrors)
	}
	if turnErr != nil {
		err = errors.Join(turnErr, supErr)
	} else {
		err = supErr
	}
	if expired && c.run.Purpose != "chat" {
		endCtx, cancel := context.WithTimeout(context.WithoutCancel(ctx), controlTimeout)
		r.end(endCtx, c, "cancelled", "Stopped: reached the "+c.spec.Budget.MaxRuntime+" runtime limit.", runs.VerbRunCancelled)
		cancel()
	}

	if stderrBytes := ws.takeStderr(); len(stderrBytes) > 0 {
		appendRaw("", bytes.TrimRight(stderrBytes, "\n"))
	}

	turnRes.Opening = opening.line
	if recordContext {
		if n := turnRes.Usage.ContextTokens; n > 0 || !agentdef.CapsOf(c.spec.Harness).ReportsContextTokens {
			writeContext(context.WithoutCancel(ctx), n)
		}
	}
	if err != nil {
		exitCode = 1
	}
	return turnRes, raw.Bytes(), exitCode, activity.Load(), err
}
