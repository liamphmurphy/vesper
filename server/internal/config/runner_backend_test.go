package config

import "testing"

// Only isolating backends (docker, microvm) run real harnesses. The fake backend runs
// on the host with no isolation, so it's accepted only with a stand-in for
// every harness; "local" (real CLIs on the host) is gone.
func TestRunnerBackendIsIsolatingOrFake(t *testing.T) {
	for _, tc := range []struct {
		backend, claude, codex string
		ok                     bool
		wantMCP                string
		wantIsolates           bool
	}{
		{"docker", "", "", true, "http://api:8000/mcp", true},
		{"microvm", "", "", true, "http://api.vesper.internal/mcp", true},
		{"fake", "/fake/claude", "/fake/codex", true, "http://localhost:8000/mcp", false},
		{"fake", "/fake/claude", "", false, "", false},
		{"fake", "", "/fake/codex", false, "", false},
		{"fake", "", "", false, "", false},
		{"local", "", "", false, "", false},
		{"local", "/fake/claude", "/fake/codex", false, "", false},
	} {
		t.Setenv("RUNNER_BACKEND", tc.backend)
		t.Setenv("RUNNER_CLAUDE_BIN", tc.claude)
		t.Setenv("RUNNER_CODEX_BIN", tc.codex)
		cfg, err := Load()
		if tc.ok && err != nil {
			t.Errorf("%s claude=%q codex=%q: %v", tc.backend, tc.claude, tc.codex, err)
			continue
		}
		if !tc.ok && err == nil {
			t.Errorf("%s claude=%q codex=%q: accepted", tc.backend, tc.claude, tc.codex)
			continue
		}
		if tc.ok {
			if cfg.Runner.MCPURL != tc.wantMCP {
				t.Errorf("%s MCPURL = %q, want %q", tc.backend, cfg.Runner.MCPURL, tc.wantMCP)
			}
			if got := IsolatesBackend(cfg.Runner.Backend); got != tc.wantIsolates {
				t.Errorf("IsolatesBackend(%q) = %v, want %v", tc.backend, got, tc.wantIsolates)
			}
		}
	}
}

func TestBlobDirLoaded(t *testing.T) {
	t.Setenv("BLOB_DIR", "/tmp/vesper-blobs")
	cfg, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if cfg.S3.Dir != "/tmp/vesper-blobs" {
		t.Fatalf("S3.Dir = %q, want /tmp/vesper-blobs", cfg.S3.Dir)
	}
}
