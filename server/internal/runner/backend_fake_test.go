package runner

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// The fake backend has no isolation, so a harness it has no stand-in for
// must not start, even when a real CLI of that name is on PATH.
func TestFakeRefusesHarnessWithoutStandIn(t *testing.T) {
	path := t.TempDir()
	if err := os.WriteFile(filepath.Join(path, "codex"), []byte("#!/bin/sh\n: >\"$0.ran\"\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", path+":"+os.Getenv("PATH"))
	trueBin, err := exec.LookPath("true")
	if err != nil {
		t.Fatal(err)
	}
	b := &Fake{Dir: t.TempDir(), Bins: map[string]string{"claude": trueBin}}
	if err := b.EnsureWorkspace(context.Background(), "r1"); err != nil {
		t.Fatal(err)
	}
	for _, argv := range [][]string{
		{"codex", "exec"},
		{"sh", "-c", `exec "$@"`, "sh", "codex", "exec"}, // how turns wrap the harness
	} {
		if p, err := b.Start(context.Background(), "r1", ExecSpec{Argv: argv}); err == nil {
			_, _ = p.Wait()
			t.Errorf("%q started without a stand-in", argv)
		}
	}
	if _, err := os.Stat(filepath.Join(path, "codex.ran")); err == nil {
		t.Error("the codex on PATH ran")
	}
	p, err := b.Start(context.Background(), "r1", ExecSpec{Argv: []string{"claude", "-p"}})
	if err != nil {
		t.Fatalf("claude has a stand-in: %v", err)
	}
	if code, err := p.Wait(); err != nil || code != 0 {
		t.Fatalf("stand-in exit %d, %v", code, err)
	}
}
