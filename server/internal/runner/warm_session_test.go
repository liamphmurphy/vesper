package runner

import (
	"context"
	"io"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/harness"
)

type stubPersistentSession struct {
	alive  atomic.Bool
	closed atomic.Bool
	stdin  io.Closer
}

func (s *stubPersistentSession) RunTurn(context.Context, harness.Turn, harness.SessionCallbacks) (harness.Result, error) {
	return harness.Result{}, nil
}
func (s *stubPersistentSession) Alive() bool { return s.alive.Load() }
func (s *stubPersistentSession) Close() error {
	s.alive.Store(false)
	s.closed.Store(true)
	if s.stdin != nil {
		_ = s.stdin.Close()
	}
	return nil
}

type stubWarmProc struct {
	stdinW  *stubStdinCloser
	stdoutR *io.PipeReader
	stdoutW *io.PipeWriter
	stderrR *io.PipeReader
	stderrW *io.PipeWriter
	done    chan struct{}
}

type stubStdinCloser struct {
	onClose func()
}

func (s *stubStdinCloser) Write(b []byte) (int, error) { return len(b), nil }
func (s *stubStdinCloser) Close() error {
	if s.onClose != nil {
		s.onClose()
	}
	return nil
}

func newStubWarmProc() *stubWarmProc {
	or, ow := io.Pipe()
	er, ew := io.Pipe()
	p := &stubWarmProc{stdoutR: or, stdoutW: ow, stderrR: er, stderrW: ew, done: make(chan struct{})}
	p.stdinW = &stubStdinCloser{onClose: func() { _ = p.Kill() }}
	return p
}

func (p *stubWarmProc) Stdin() io.WriteCloser { return p.stdinW }
func (p *stubWarmProc) Stdout() io.Reader     { return p.stdoutR }
func (p *stubWarmProc) Stderr() io.Reader     { return p.stderrR }
func (p *stubWarmProc) Interrupt() error      { return nil }
func (p *stubWarmProc) Kill() error {
	_ = p.stdoutW.Close()
	_ = p.stderrW.Close()
	select {
	case <-p.done:
	default:
		close(p.done)
	}
	return nil
}
func (p *stubWarmProc) Wait() (int, error) {
	_ = p.Kill()
	<-p.done
	return 0, nil
}

func TestWarmSessionFingerprint(t *testing.T) {
	spec := agentdef.Resolved{
		Harness:        agentdef.HarnessClaudeCode,
		Model:          "claude-sonnet-4-6",
		Skills:         []agentdef.Skill{{Name: "b", Body: "B"}, {Name: "a", Body: "A"}},
		HarnessOptions: map[string]string{"effort": "low", "readonly": "true"},
	}
	files := map[string][]byte{"a.txt": []byte("one"), "b.txt": []byte("two")}
	env := map[string]string{"K1": "V1", "K2": "V2"}

	fp1 := warmSessionFingerprint(spec, "/ws", []byte("instructions"), files, env)
	spec2 := spec
	spec2.Skills = []agentdef.Skill{{Name: "a", Body: "A"}, {Name: "b", Body: "B"}}
	fp2 := warmSessionFingerprint(spec2, "/ws", []byte("instructions"), files, env)
	if fp1 != fp2 {
		t.Fatalf("fingerprint should be order-independent: %s vs %s", fp1, fp2)
	}

	spec3 := spec
	spec3.HarnessOptions = map[string]string{"effort": "high", "readonly": "true"}
	if fp3 := warmSessionFingerprint(spec3, "/ws", []byte("instructions"), files, env); fp3 == fp1 {
		t.Fatal("changing effort must invalidate fingerprint")
	}

	if fp4 := warmSessionFingerprint(spec, "/ws", []byte("updated memory index"), files, env); fp4 == fp1 {
		t.Fatal("changing instructions section must invalidate fingerprint")
	}
}

func TestWarmSessionPoolLifecycle(t *testing.T) {
	var pool warmSessionPool
	runID := uuid.New()
	agentID := uuid.New()
	tokID := uuid.New()

	var revoked atomic.Int32
	proc := newStubWarmProc()
	sess := &stubPersistentSession{stdin: proc.Stdin()}
	sess.alive.Store(true)

	ws := newWarmSession(runID, "fp-1", proc, nil, sess, agentID, tokID, nil, func(a, tk uuid.UUID) {
		if a == agentID && tk == tokID {
			revoked.Add(1)
		}
	})
	pool.put(ws, 2*time.Second)

	// Matching fingerprint hits and hands back the live session without revoking its token.
	got := pool.take(runID, "fp-1")
	if got != ws || revoked.Load() != 0 {
		t.Fatalf("expected warm hit with 0 revocations (got=%v revoked=%d)", got, revoked.Load())
	}

	// Re-park with a short TTL and verify idle expiry closes the session and revokes the token.
	pool.put(got, 60*time.Millisecond)
	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && revoked.Load() == 0 {
		time.Sleep(10 * time.Millisecond)
	}
	if revoked.Load() != 1 || !sess.closed.Load() {
		t.Fatalf("expected idle expiry close+revoke (revoked=%d closed=%v)", revoked.Load(), sess.closed.Load())
	}

	// Fingerprint mismatch evicts the parked session and revokes its token.
	proc2 := newStubWarmProc()
	sess2 := &stubPersistentSession{stdin: proc2.Stdin()}
	sess2.alive.Store(true)
	ws2 := newWarmSession(runID, "fp-1", proc2, nil, sess2, agentID, tokID, nil, func(uuid.UUID, uuid.UUID) {
		revoked.Add(1)
	})
	pool.put(ws2, 5*time.Second)
	if hit := pool.take(runID, "fp-2"); hit != nil {
		t.Fatalf("expected miss on changed fingerprint, got %v", hit)
	}
	deadline = time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) && revoked.Load() < 2 {
		time.Sleep(10 * time.Millisecond)
	}
	if revoked.Load() != 2 || !sess2.closed.Load() {
		t.Fatalf("expected mismatch eviction close+revoke (revoked=%d closed=%v)", revoked.Load(), sess2.closed.Load())
	}
}
