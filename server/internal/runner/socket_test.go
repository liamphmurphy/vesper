package runner

import (
	"os"
	"testing"
)

// shortTempDir returns a short temporary directory suitable for Unix domain
// sockets, whose path is capped at 104 bytes on macOS (t.TempDir under
// /var/folders/... exceeds that when combined with a test name or proxy token).
func shortTempDir(t *testing.T) string {
	t.Helper()
	base := ""
	if len(os.TempDir()) > 20 {
		base = "/tmp"
	}
	dir, err := os.MkdirTemp(base, "vr")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(dir) })
	return dir
}
