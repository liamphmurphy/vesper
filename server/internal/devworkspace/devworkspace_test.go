package devworkspace

import (
	"strings"
	"testing"
)

func TestConfigHashDeterministic(t *testing.T) {
	h1 := ConfigHash()
	h2 := ConfigHash()
	if len(h1) != 16 || h1 != h2 {
		t.Fatalf("unexpected hash: %q vs %q", h1, h2)
	}
}

func TestDeriveRepoDirsDisambiguates(t *testing.T) {
	got := DeriveRepoDirs([]string{
		"https://github.com/liamphmurphy/vesper.git",
		"https://github.com/other/vesper",
		"https://github.com/liamphmurphy/os-setup",
	})
	if len(got) != 3 {
		t.Fatalf("got %d repos, want 3", len(got))
	}
	if got[0].Directory != "vesper" || got[1].Directory != "vesper-2" || got[2].Directory != "os-setup" {
		t.Fatalf("unexpected dirs: %+v", got)
	}
}

func TestSetupNixScriptEmbedsDefaultsAndForceRebuild(t *testing.T) {
	s := SetupNixScript(false, "", "C-b", "")
	for _, want := range []string{
		"/home/node/.config/vesper-dev/flake.nix",
		"/home/node/.config/nvim/init.lua",
		"/home/node/.tmux.conf",
		"/home/node/.zshenv",
		"/home/node/.zshrc",
		"/home/node/.bashrc",
		"/home/node/.profile",
		"nix profile install --profile",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("SetupNixScript missing %q", want)
		}
	}
	rebuild := SetupNixScript(true, "", "C-b", "")
	if !strings.Contains(rebuild, "rm -f '/home/node/.local/share/vesper-dev/env.hash' '/home/node/.config/vesper-dev/flake.lock'") {
		t.Fatalf("forceRebuild should remove stamp and flake.lock: %s", rebuild)
	}
	custom := WriteShellConfigScript("export FOO=bar\n", "C-a", "set -g mouse on\n")
	if !strings.Contains(custom, "/home/node/.zshenv") || !strings.Contains(custom, "ZXhwb3J0IEZPTz1iYXIK") || !strings.Contains(custom, "c2V0IC1nIG1vdXNlIG9uCg==") || !strings.Contains(custom, "tmux source-file") {
		t.Fatalf("WriteShellConfigScript should write .zshenv, custom .zshrc, custom .tmux.conf, and reload tmux: %s", custom)
	}
}

func TestSyncReposScriptClonesAndFetchesWithoutStoringTokens(t *testing.T) {
	s := SyncReposScript([]RepoSpec{{RepoURL: "https://github.com/liamphmurphy/vesper.git", Directory: "vesper"}}, "Liam", "liam@example.com")
	if !strings.Contains(s, "clone --quiet -- 'https://github.com/liamphmurphy/vesper.git' '/workspace/vesper'") {
		t.Fatalf("missing clone command: %s", s)
	}
	if !strings.Contains(s, "fetch --quiet --all --prune") {
		t.Fatalf("missing fetch command: %s", s)
	}
	if strings.Contains(s, "credential.helper store") {
		t.Fatalf("must not store credentials on disk")
	}
}
