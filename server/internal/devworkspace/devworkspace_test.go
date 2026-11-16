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
	s := SetupNixScript(false, "", "C-b", "", nil)
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
	rebuild := SetupNixScript(true, "", "C-b", "", nil)
	if !strings.Contains(rebuild, "rm -f '/home/node/.local/share/vesper-dev/env.hash' '/home/node/.config/vesper-dev/flake.lock'") {
		t.Fatalf("forceRebuild should remove stamp and flake.lock: %s", rebuild)
	}
	custom := WriteShellConfigScript("export FOO=bar\n", "C-a", "set -g mouse on\n")
	if !strings.Contains(custom, "/home/node/.zshenv") || !strings.Contains(custom, "ZXhwb3J0IEZPTz1iYXIK") || !strings.Contains(custom, "c2V0IC1nIG1vdXNlIG9uCg==") || !strings.Contains(custom, "tmux source-file") {
		t.Fatalf("WriteShellConfigScript should write .zshenv, custom .zshrc, custom .tmux.conf, and reload tmux: %s", custom)
	}
}

func TestValidateNixPackageAndRenderFlake(t *testing.T) {
	for _, good := range []string{"bat", "eza", "python312Packages.pytest", "gcc_multi"} {
		if _, err := ValidateNixPackage(good); err != nil {
			t.Fatalf("ValidateNixPackage(%q) unexpected err: %v", good, err)
		}
	}
	for _, bad := range []string{"", "bat; rm -rf /", "a b", "../foo", "pkgs.\"x\""} {
		if _, err := ValidateNixPackage(bad); err == nil {
			t.Fatalf("ValidateNixPackage(%q) should have failed", bad)
		}
	}
	if EnvHash(nil) == EnvHash([]string{"bat"}) {
		t.Fatal("EnvHash should change when extraPackages changes")
	}
	rendered := RenderFlakeNix([]string{"bat", "python3Packages.ipython"})
	if !strings.Contains(rendered, `"bat"`) || !strings.Contains(rendered, `"python3Packages.ipython"`) {
		t.Fatalf("RenderFlakeNix missing extra packages: %s", rendered)
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

func TestValidateBranchName(t *testing.T) {
	for _, good := range []string{"feat/open-pr", "fix-123", "release/v1.2.3", "user_topic"} {
		if got, err := ValidateBranchName("  " + good + " "); err != nil || got != good {
			t.Fatalf("ValidateBranchName(%q) = (%q, %v)", good, got, err)
		}
	}
	for _, bad := range []string{"", " ", "-rf", "a..b", "a b", "feat~1", "feat:bar", "/leading", "trailing/", "a.lock", "a//b", "a@{0}"} {
		if _, err := ValidateBranchName(bad); err == nil {
			t.Fatalf("ValidateBranchName(%q) should have failed", bad)
		}
	}
}

func TestResolveRepoDir(t *testing.T) {
	repos := []RepoSpec{
		{RepoURL: "https://github.com/liamphmurphy/vesper.git", Directory: "vesper"},
		{RepoURL: "https://github.com/other/app.git", Directory: "app"},
	}
	if got := ResolveRepoDir(repos, "git@github.com:LiamPHMurphy/Vesper"); got != "vesper" {
		t.Fatalf("matched configured repo = %q, want vesper", got)
	}
	if got := ResolveRepoDir(repos, "https://github.com/another/app.git"); got != "app-2" {
		t.Fatalf("disambiguated colliding dir = %q, want app-2", got)
	}
	if got := ResolveRepoDir(repos, "https://github.com/acme/new-repo.git"); got != "new-repo" {
		t.Fatalf("derived new dir = %q, want new-repo", got)
	}
}

func TestOpenBranchScript(t *testing.T) {
	repos := []RepoSpec{{RepoURL: "https://github.com/liamphmurphy/vesper.git", Directory: "vesper"}}
	s := OpenBranchScript(repos, "https://github.com/liamphmurphy/vesper.git", "feat/my-pr", 42, "Liam", "liam@example.com")
	for _, want := range []string{
		"dest='/workspace/vesper'",
		"+refs/heads/$branch:refs/remotes/origin/$branch",
		"+refs/pull/42/head:refs/remotes/origin/$branch",
		"has uncommitted changes",
		"tmux new-window -t dev -n 'vesper' -c \"$dest\"",
		"tmux new-session -d -s dev -n 'vesper' -c \"$dest\"",
	} {
		if !strings.Contains(s, want) {
			t.Fatalf("OpenBranchScript missing %q:\n%s", want, s)
		}
	}
	if strings.Contains(s, "credential.helper store") {
		t.Fatalf("must not store credentials on disk")
	}
}
