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
