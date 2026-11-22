package harness

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"sync"
)

const sessionMaxScanBytes = 32 << 20

// ErrSteerUnsupported indicates that the running harness session cannot accept
// mid-turn steering input (by protocol capability or current turn state).
var ErrSteerUnsupported = errors.New("harness session does not support mid-turn steering")

// PolicyFunc authorizes a single tool call in-process. Returning allow=false
// denies the tool with reason. Implementations must fail closed.
type PolicyFunc func(ctx context.Context, tool string, input map[string]any) (allow bool, reason string)

// SessionControl lets the runner request a protocol-native interrupt or
// mid-turn steer before falling back to OS signals or turn replacement.
type SessionControl interface {
	Interrupt() error
	Steer(message string) error
}

// SessionCallbacks delivers normalized events, session IDs, raw stdout lines,
// protocol control handles, and in-process tool authorization callbacks during
// a bidirectional harness session.
type SessionCallbacks struct {
	OnEvent         func(Event)
	OnTextDelta     func(string)
	OnSession       func(string)
	OnContextTokens func(int64)
	OnRaw           func([]byte)
	OnControl       func(SessionControl)
	CheckTool       PolicyFunc
}

// SessionHarness drives a turn over bidirectional stdio pipes.
type SessionHarness interface {
	Harness
	SessionInvocation(ws Workspace, t Turn) (Invocation, error)
	RunSession(ctx context.Context, stdin io.WriteCloser, stdout io.Reader, ws Workspace, t Turn, cb SessionCallbacks) (Result, error)
}

// PersistentSession is an already-initialized bidirectional harness process
// kept alive across consecutive chat turns to skip CLI boot, MCP connection,
// and session resume/load on follow-up messages.
type PersistentSession interface {
	// RunTurn sends one turn over the open session and returns once it finishes.
	// Callers must not invoke RunTurn concurrently on the same session.
	RunTurn(ctx context.Context, t Turn, cb SessionCallbacks) (Result, error)
	// Alive reports whether the underlying stdio stream is still usable.
	Alive() bool
	// Close closes stdin so the harness process exits cleanly.
	Close() error
}

// PersistentSessionHarness is optionally implemented by harnesses that can
// keep a bidirectional stdio process warm across consecutive turns.
type PersistentSessionHarness interface {
	SessionHarness
	OpenSession(ctx context.Context, stdin io.WriteCloser, stdout io.Reader, ws Workspace, t Turn, cb SessionCallbacks) (PersistentSession, error)
}

// lineWriter serializes NDJSON writes and Close across goroutines so concurrent
// Interrupt() control calls and normal RPC replies never interleave bytes.
type lineWriter struct {
	mu     sync.Mutex
	w      io.WriteCloser
	closed bool
}

func newLineWriter(w io.WriteCloser) *lineWriter {
	return &lineWriter{w: w}
}

func (lw *lineWriter) writeJSON(v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	b = append(b, '\n')
	lw.mu.Lock()
	defer lw.mu.Unlock()
	if lw.closed || lw.w == nil {
		return io.ErrClosedPipe
	}
	_, err = lw.w.Write(b)
	return err
}

func (lw *lineWriter) Close() error {
	lw.mu.Lock()
	defer lw.mu.Unlock()
	if lw.closed || lw.w == nil {
		return nil
	}
	lw.closed = true
	return lw.w.Close()
}

func checkPolicy(ctx context.Context, fn PolicyFunc, noTools bool, tool string, input map[string]any) (bool, string) {
	if noTools {
		return false, "This turn has no tools"
	}
	if fn == nil {
		return false, "Vesper tool policy is unavailable. Do not run this tool; end the turn and ask for help."
	}
	if input == nil {
		input = map[string]any{}
	}
	allow, reason := fn(ctx, tool, input)
	if !allow && reason == "" {
		reason = "Vesper denied the tool"
	}
	return allow, reason
}
