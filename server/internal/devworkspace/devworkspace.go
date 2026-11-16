package devworkspace

import (
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io/fs"
	"path"
	"regexp"
	"sort"
	"strings"
)

//go:embed all:defaults
var defaultFiles embed.FS

// ProfilePath is the Nix profile inside the persistent /home/node volume
// where the dev workspace installs its editor and toolchain packages.
const ProfilePath = "/home/node/.local/share/vesper-dev/profile"

// RepoSpec is one repository configured to be auto-cloned into /workspace.
type RepoSpec struct {
	RepoURL   string `json:"repo_url"`
	Directory string `json:"directory"`
}

// ConfigHash returns a deterministic hash of the embedded default Nix + LazyVim
// files so Vesper only rebuilds the Nix profile when its defaults change.
func ConfigHash() string {
	var paths []string
	_ = fs.WalkDir(defaultFiles, "defaults", func(p string, d fs.DirEntry, err error) error {
		if err == nil && !d.IsDir() {
			paths = append(paths, p)
		}
		return nil
	})
	sort.Strings(paths)
	h := sha256.New()
	for _, p := range paths {
		b, _ := defaultFiles.ReadFile(p)
		h.Write([]byte(p))
		h.Write([]byte{0})
		h.Write(b)
		h.Write([]byte{0})
	}
	return hex.EncodeToString(h.Sum(nil))[:16]
}

// DeriveRepoDirs assigns collision-free /workspace/<dir> folder names for a
// list of repository URLs.
func DeriveRepoDirs(urls []string) []RepoSpec {
	used := map[string]int{}
	out := make([]RepoSpec, 0, len(urls))
	for _, raw := range urls {
		u := strings.TrimSpace(raw)
		if u == "" {
			continue
		}
		base := sanitizeDirName(path.Base(strings.TrimSuffix(strings.TrimSuffix(u, "/"), ".git")))
		if base == "" || base == "." || base == ".." {
			base = "repo"
		}
		dir := base
		if used[dir] > 0 {
			for i := 2; ; i++ {
				cand := fmt.Sprintf("%s-%d", base, i)
				if used[cand] == 0 {
					dir = cand
					break
				}
			}
		}
		used[dir]++
		out = append(out, RepoSpec{RepoURL: u, Directory: dir})
	}
	return out
}

func sanitizeDirName(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' || r == '.' {
			b.WriteRune(r)
		}
	}
	return b.String()
}

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}

func writeContent(b *strings.Builder, data []byte, destPath string) {
	b.WriteString("mkdir -p " + shellQuote(path.Dir(destPath)) + "\n")
	b.WriteString("printf '%s' " + shellQuote(base64.StdEncoding.EncodeToString(data)) + " | base64 -d > " + shellQuote(destPath) + "\n")
}

func writeEmbeddedFile(b *strings.Builder, embedPath, destPath string) error {
	data, err := defaultFiles.ReadFile(embedPath)
	if err != nil {
		return err
	}
	writeContent(b, data, destPath)
	return nil
}

func validTmuxPrefix(p string) string {
	switch p {
	case "C-a", "C-b", "C-Space", "C-s":
		return p
	default:
		return "C-b"
	}
}

// WriteShellConfigScript writes ~/.zshenv (preserving Nix PATH and ZSH),
// ~/.zshrc (using customZshrc when non-empty, or the default oh-my-zsh config),
// and ~/.tmux.conf (using customTmuxConf when non-empty, or the default config
// with the chosen prefix, reloading a running tmux server).
func WriteShellConfigScript(customZshrc, tmuxPrefix, customTmuxConf string) string {
	var b strings.Builder
	b.WriteString("set -eu\n")
	_ = writeEmbeddedFile(&b, "defaults/zshenv", "/home/node/.zshenv")
	if strings.TrimSpace(customZshrc) != "" {
		writeContent(&b, []byte(customZshrc), "/home/node/.zshrc")
	} else {
		_ = writeEmbeddedFile(&b, "defaults/zshrc", "/home/node/.zshrc")
	}
	if strings.TrimSpace(customTmuxConf) != "" {
		writeContent(&b, []byte(customTmuxConf), "/home/node/.tmux.conf")
	} else {
		tmuxConf, _ := defaultFiles.ReadFile("defaults/tmux.conf")
		prefix := validTmuxPrefix(tmuxPrefix)
		if prefix != "C-b" {
			tmuxConf = append(tmuxConf, []byte("\nunbind C-b\nset -g prefix "+prefix+"\nbind "+prefix+" send-prefix\n")...)
		}
		writeContent(&b, tmuxConf, "/home/node/.tmux.conf")
	}
	b.WriteString("tmux source-file /home/node/.tmux.conf >/dev/null 2>&1 || true\n")
	return b.String()
}

var nixPkgRe = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9._+-]*$`)

// ValidateNixPackage checks that a user-supplied nixpkgs attribute name is
// safe to interpolate into flake.nix.
func ValidateNixPackage(raw string) (string, error) {
	name := strings.TrimSpace(raw)
	if name == "" {
		return "", fmt.Errorf("package name cannot be empty")
	}
	if strings.Contains(name, "..") || strings.HasSuffix(name, ".") || !nixPkgRe.MatchString(name) {
		return "", fmt.Errorf("invalid nixpkgs package name %q", raw)
	}
	return name, nil
}

// EnvHash returns the stamp hash for the embedded defaults plus any extra
// nixpkgs packages, so adding or removing a package invalidates the stamp.
func EnvHash(extraPackages []string) string {
	h := sha256.New()
	h.Write([]byte(ConfigHash()))
	for _, p := range extraPackages {
		h.Write([]byte{0})
		h.Write([]byte(p))
	}
	return hex.EncodeToString(h.Sum(nil))[:16]
}

// RenderFlakeNix returns defaults/flake.nix with any validated extraPackages
// appended to the buildEnv paths using nixpkgs.lib.attrByPath.
func RenderFlakeNix(extraPackages []string) string {
	base, _ := defaultFiles.ReadFile("defaults/flake.nix")
	if len(extraPackages) == 0 {
		return string(base)
	}
	var extra strings.Builder
	for _, p := range extraPackages {
		extra.WriteString("          ] ++ [\n            (nixpkgs.lib.attrByPath (nixpkgs.lib.splitString \".\" " + fmt.Sprintf("%q", p) + ") (throw \"unknown nixpkgs package: " + p + "\") pkgs)\n")
	}
	// Replace the closing `          ];` of `paths = with pkgs; [ ... ];`
	return strings.Replace(string(base), "          ];", strings.TrimPrefix(extra.String(), "          ] ++ ")+"          ];", 1)
}

// SetupNixScript returns a shell script that writes the default Nix flake
// (including any extraPackages), LazyVim config, and shell/tmux config into
// /home/node, then installs the Nix profile if the env hash changed or
// forceRebuild is true (refreshing the nixos-unstable flake lock on rebuild).
func SetupNixScript(forceRebuild bool, customZshrc, tmuxPrefix, customTmuxConf string, extraPackages []string) string {
	hash := EnvHash(extraPackages)
	var b strings.Builder
	b.WriteString("set -eu\n")
	b.WriteString("mkdir -p /home/node/.local/share/vesper-dev /home/node/.config/vesper-dev /home/node/.config/nvim/lua/config /home/node/.config/nvim/lua/plugins\n")
	writeContent(&b, []byte(RenderFlakeNix(extraPackages)), "/home/node/.config/vesper-dev/flake.nix")
	_ = writeEmbeddedFile(&b, "defaults/profile", "/home/node/.profile")
	_ = writeEmbeddedFile(&b, "defaults/bashrc", "/home/node/.bashrc")
	b.WriteString(WriteShellConfigScript(customZshrc, tmuxPrefix, customTmuxConf))
	_ = writeEmbeddedFile(&b, "defaults/nvim/init.lua", "/home/node/.config/nvim/init.lua")
	_ = writeEmbeddedFile(&b, "defaults/nvim/lua/config/lazy.lua", "/home/node/.config/nvim/lua/config/lazy.lua")
	_ = writeEmbeddedFile(&b, "defaults/nvim/lua/config/options.lua", "/home/node/.config/nvim/lua/config/options.lua")
	_ = writeEmbeddedFile(&b, "defaults/nvim/lua/plugins/init.lua", "/home/node/.config/nvim/lua/plugins/init.lua")

	stamp := "/home/node/.local/share/vesper-dev/env.hash"
	lockFile := "/home/node/.config/vesper-dev/flake.lock"
	if forceRebuild {
		b.WriteString("rm -f " + shellQuote(stamp) + " " + shellQuote(lockFile) + "\n")
	}
	b.WriteString("if [ ! -e " + shellQuote(ProfilePath+"/bin/nvim") + " ] || [ \"$(cat " + shellQuote(stamp) + " 2>/dev/null || true)\" != " + shellQuote(hash) + " ]; then\n")
	b.WriteString("  rm -rf " + shellQuote(ProfilePath) + "\n")
	b.WriteString("  nix profile install --profile " + shellQuote(ProfilePath) + " path:/home/node/.config/vesper-dev#default </dev/null\n")
	b.WriteString("  printf '%s\\n' " + shellQuote(hash) + " > " + shellQuote(stamp) + "\n")
	b.WriteString("fi\n")
	b.WriteString("uname -m\n")
	return b.String()
}

// NormalizeRepoURL normalizes a git repository URL to lower-cased host/owner/repo
// without scheme, userinfo, trailing slash, or .git suffix.
func NormalizeRepoURL(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	s = strings.TrimSuffix(s, "/")
	s = strings.TrimSuffix(s, ".git")
	s = strings.ToLower(s)
	for _, prefix := range []string{"https://", "http://", "ssh://"} {
		if strings.HasPrefix(s, prefix) {
			s = strings.TrimPrefix(s, prefix)
			if at := strings.IndexByte(s, '@'); at >= 0 {
				if slash := strings.IndexByte(s, '/'); slash < 0 || at < slash {
					s = s[at+1:]
				}
			}
			return s
		}
	}
	if strings.HasPrefix(s, "git@") {
		s = strings.TrimPrefix(s, "git@")
		s = strings.Replace(s, ":", "/", 1)
	}
	return s
}

// ResolveRepoDir returns the configured /workspace/<dir> for repoURL when it
// matches one of repos, or derives a collision-free directory name.
func ResolveRepoDir(repos []RepoSpec, repoURL string) string {
	want := NormalizeRepoURL(repoURL)
	used := make(map[string]bool, len(repos))
	for _, r := range repos {
		used[r.Directory] = true
		if want != "" && NormalizeRepoURL(r.RepoURL) == want && r.Directory != "" {
			return r.Directory
		}
	}
	derived := DeriveRepoDirs([]string{repoURL})
	base := "repo"
	if len(derived) > 0 && derived[0].Directory != "" {
		base = derived[0].Directory
	}
	dir := base
	for i := 2; used[dir]; i++ {
		dir = fmt.Sprintf("%s-%d", base, i)
	}
	return dir
}

// ValidateBranchName checks that branch is a safe git branch name.
func ValidateBranchName(raw string) (string, error) {
	b := strings.TrimSpace(raw)
	if b == "" {
		return "", fmt.Errorf("branch cannot be empty")
	}
	if strings.HasPrefix(b, "-") || strings.HasPrefix(b, "/") || strings.HasSuffix(b, "/") || strings.HasSuffix(b, ".") || strings.HasSuffix(b, ".lock") {
		return "", fmt.Errorf("invalid branch name %q", raw)
	}
	if strings.Contains(b, "..") || strings.Contains(b, "//") || strings.Contains(b, "@{") || strings.Contains(b, "/.") {
		return "", fmt.Errorf("invalid branch name %q", raw)
	}
	for _, r := range b {
		if r <= 0x20 || r == 0x7f || strings.ContainsRune("~^:?*[\\", r) {
			return "", fmt.Errorf("invalid branch name %q", raw)
		}
	}
	return b, nil
}

func writeCredentialHelperPrelude(b *strings.Builder) {
	b.WriteString(`export GIT_TERMINAL_PROMPT=0
helper=""
cleanup_helper() { [ -n "$helper" ] && rm -f "$helper"; }
trap cleanup_helper EXIT
if [ -n "${GH_TOKEN:-}" ]; then
  helper=$(mktemp)
  chmod 700 "$helper"
  printf '#!/bin/sh\necho "username=x-access-token"\necho "password=%s"\n' "$GH_TOKEN" > "$helper"
fi
git_net() {
  if [ -n "$helper" ]; then
    git -c credential.helper= -c "credential.helper=$helper" "$@" </dev/null
  else
    git "$@" </dev/null
  fi
}
`)
}

func writeGitConfigAuthor(b *strings.Builder, destExpr, userName, userEmail string) {
	if userName != "" {
		b.WriteString("    git -C " + destExpr + " config user.name " + shellQuote(userName) + "\n")
	}
	if userEmail != "" {
		b.WriteString("    git -C " + destExpr + " config user.email " + shellQuote(userEmail) + "\n")
	}
}

const syncConcurrency = 6

// SyncReposScript returns a shell script that clones any missing repositories
// into /workspace/<directory> and fetches existing ones without storing git
// credentials on disk. Repos run with bounded concurrency so large sets finish
// within a single step and report any failing clones together.
func SyncReposScript(repos []RepoSpec, userName, userEmail string) string {
	var b strings.Builder
	b.WriteString("set -eu\numask 022\n")
	b.WriteString("mkdir -p /workspace\n")
	if len(repos) == 0 {
		return b.String()
	}
	writeCredentialHelperPrelude(&b)
	b.WriteString("fail_log=$(mktemp)\n")
	b.WriteString("cleanup_sync() {\n  cleanup_helper\n  rm -f \"$fail_log\"\n}\n")
	b.WriteString("trap cleanup_sync EXIT\n")
	b.WriteString("sync_repo() {\n")
	b.WriteString("  url=\"$1\"\n")
	b.WriteString("  dest=\"$2\"\n")
	b.WriteString("  if [ ! -d \"$dest/.git\" ]; then\n")
	b.WriteString("    if ! err=$(git_net clone --quiet -- \"$url\" \"$dest\" 2>&1); then\n")
	b.WriteString("      printf '%s\\n' \"$dest ($url): $err\" >> \"$fail_log\"\n")
	b.WriteString("      return 1\n")
	b.WriteString("    fi\n")
	writeGitConfigAuthor(&b, "\"$dest\"", userName, userEmail)
	b.WriteString("  else\n")
	b.WriteString("    git_net -C \"$dest\" fetch --quiet --all --prune || true\n")
	b.WriteString("  fi\n")
	b.WriteString("}\n")

	for i := 0; i < len(repos); i += syncConcurrency {
		end := min(i+syncConcurrency, len(repos))
		b.WriteString("pids=\"\"\n")
		for _, r := range repos[i:end] {
			dest := "/workspace/" + r.Directory
			b.WriteString("sync_repo " + shellQuote(r.RepoURL) + " " + shellQuote(dest) + " & pids=\"$pids $!\"\n")
		}
		b.WriteString("for p in $pids; do wait \"$p\" || true; done\n")
	}
	b.WriteString("if [ -s \"$fail_log\" ]; then\n")
	b.WriteString("  cat \"$fail_log\" >&2\n")
	b.WriteString("  exit 1\n")
	b.WriteString("fi\n")
	return b.String()
}

// OpenBranchScript returns a shell script that ensures repoURL is cloned in
// /workspace, safely fetches and checks out branch (refusing to clobber
// uncommitted changes), and opens or focuses a tmux window in that repository.
func OpenBranchScript(repos []RepoSpec, repoURL, branch string, prNumber int, userName, userEmail string) string {
	dir := ResolveRepoDir(repos, repoURL)
	altDir := dir + "-pr"
	normTarget := NormalizeRepoURL(repoURL)
	winName := sanitizeDirName(dir)
	if winName == "" {
		winName = "repo"
	}

	var b strings.Builder
	b.WriteString("set -eu\numask 022\n")
	b.WriteString("mkdir -p /workspace\n")
	writeCredentialHelperPrelude(&b)
	b.WriteString(`norm_url() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's#^ssh://git@([^/]+)/#\1/#; s#^https?://([^@/]+@)?([^/]+)/#\2/#; s#^git@([^:]+):(.*)$#\1/\2#; s#\.git$##; s#/+$##'
}
`)
	b.WriteString("dest=" + shellQuote("/workspace/"+dir) + "\n")
	b.WriteString("target_norm=" + shellQuote(normTarget) + "\n")
	b.WriteString("if [ -d \"$dest/.git\" ]; then\n")
	b.WriteString("  cur_norm=$(norm_url \"$(git -C \"$dest\" remote get-url origin 2>/dev/null || true)\")\n")
	b.WriteString("  if [ -n \"$cur_norm\" ] && [ \"$cur_norm\" != \"$target_norm\" ]; then\n")
	b.WriteString("    dest=" + shellQuote("/workspace/"+altDir) + "\n")
	b.WriteString("  fi\n")
	b.WriteString("fi\n")

	b.WriteString("if [ ! -d \"$dest/.git\" ]; then\n")
	b.WriteString("  git_net clone --quiet -- " + shellQuote(repoURL) + " \"$dest\"\n")
	writeGitConfigAuthor(&b, "\"$dest\"", userName, userEmail)
	b.WriteString("fi\n")

	qBranch := shellQuote(branch)
	b.WriteString("branch=" + qBranch + "\n")
	if prNumber > 0 {
		b.WriteString(fmt.Sprintf("git_net -C \"$dest\" fetch --quiet origin -- \"+refs/heads/$branch:refs/remotes/origin/$branch\" 2>/dev/null || git_net -C \"$dest\" fetch --quiet origin -- \"+refs/pull/%d/head:refs/remotes/origin/$branch\"\n", prNumber))
	} else {
		b.WriteString("git_net -C \"$dest\" fetch --quiet origin -- \"+refs/heads/$branch:refs/remotes/origin/$branch\"\n")
	}

	b.WriteString(`cur_branch=$(git -C "$dest" symbolic-ref --short HEAD 2>/dev/null || true)
dirty=$(git -C "$dest" status --porcelain)
if [ "$cur_branch" = "$branch" ]; then
  head_sha=$(git -C "$dest" rev-parse HEAD)
  remote_sha=$(git -C "$dest" rev-parse "refs/remotes/origin/$branch")
  if [ "$head_sha" != "$remote_sha" ]; then
    if git -C "$dest" merge-base --is-ancestor "$head_sha" "$remote_sha"; then
      git -C "$dest" merge --ff-only --quiet "refs/remotes/origin/$branch"
    else
      printf '%s\n' "Local branch '$branch' in $dest has diverged from origin/$branch." >&2
      exit 1
    fi
  fi
else
  if [ -n "$dirty" ]; then
    printf '%s\n' "$dest has uncommitted changes on ${cur_branch:-HEAD}; commit or stash them before switching to $branch." >&2
    exit 1
  fi
  if git -C "$dest" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$dest" checkout --quiet "$branch"
    git -C "$dest" merge --ff-only --quiet "refs/remotes/origin/$branch"
  else
    git -C "$dest" checkout --quiet -b "$branch" --track "refs/remotes/origin/$branch"
  fi
fi
export TERM=xterm-256color COLORTERM=truecolor
if [ -x ` + shellQuote(ProfilePath+"/bin/zsh") + ` ]; then
  export SHELL=` + shellQuote(ProfilePath+"/bin/zsh") + `
fi
pane_cmd='if command -v nvim >/dev/null 2>&1; then nvim .; fi; if command -v zsh >/dev/null 2>&1; then exec zsh; else exec bash; fi'
if command -v tmux >/dev/null 2>&1; then
  if tmux has-session -t dev 2>/dev/null; then
    tmux new-window -t dev -n ` + shellQuote(winName) + ` -c "$dest" "$pane_cmd"
  else
    tmux new-session -d -s dev -n ` + shellQuote(winName) + ` -c "$dest" "$pane_cmd"
  fi
fi
`)
	return b.String()
}
