package runner

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

// A housekeeping script that hangs (a checkpoint push on a dead network) is
// killed at ScriptTimeout instead of holding the sweep or a run's start.
func TestRunScriptTimesOut(t *testing.T) {
	old := ScriptTimeout
	ScriptTimeout = 200 * time.Millisecond
	t.Cleanup(func() { ScriptTimeout = old })
	r := &Runner{Backend: &Fake{Dir: t.TempDir()}}
	start := time.Now()
	_, err := r.runScript(context.Background(), uuid.New(), "hang", "sleep 30", nil)
	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("runScript err = %v, want a timeout", err)
	}
	if d := time.Since(start); d > 10*time.Second {
		t.Fatalf("runScript took %s", d)
	}
}
