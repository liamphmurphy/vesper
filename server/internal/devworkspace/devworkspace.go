package devworkspace

import (
	"crypto/sha256"
	"embed"
	"encoding/base64"
	"encoding/hex"
	"io/fs"
	"path"
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
		if n := used[dir]; n > 0 {
			dir = base + "-" + string(rune('1'+n))
			for used[dir] > 0 {
				dir += "-x"
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

// WriteShellConfigScript writes ~/.zshenv (preserving Nix PATH and ZSH) and
// ~/.zshrc (using customZshrc when non-empty, or the default oh-my-zsh config).
func WriteShellConfigScript(customZshrc string) string {
	var b strings.Builder
	b.WriteString("set -eu\n")
	_ = writeEmbeddedFile(&b, "defaults/zshenv", "/home/node/.zshenv")
	if strings.TrimSpace(customZshrc) != "" {
		writeContent(&b, []byte(customZshrc), "/home/node/.zshrc")
	} else {
		_ = writeEmbeddedFile(&b, "defaults/zshrc", "/home/node/.zshrc")
	}
	return b.String()
}

// SetupNixScript returns a shell script that writes the default Nix flake,
// LazyVim config, and shell/tmux config into /home/node, then installs the Nix
// profile if the config hash changed or forceRebuild is true (refreshing the
// nixos-unstable flake lock on rebuild).
func SetupNixScript(forceRebuild bool, customZshrc string) string {
	hash := ConfigHash()
	var b strings.Builder
	b.WriteString("set -eu\n")
	b.WriteString("mkdir -p /home/node/.local/share/vesper-dev /home/node/.config/vesper-dev /home/node/.config/nvim/lua/config /home/node/.config/nvim/lua/plugins\n")
	_ = writeEmbeddedFile(&b, "defaults/flake.nix", "/home/node/.config/vesper-dev/flake.nix")
	_ = writeEmbeddedFile(&b, "defaults/tmux.conf", "/home/node/.tmux.conf")
	_ = writeEmbeddedFile(&b, "defaults/profile", "/home/node/.profile")
	_ = writeEmbeddedFile(&b, "defaults/bashrc", "/home/node/.bashrc")
	b.WriteString(WriteShellConfigScript(customZshrc))
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
	b.WriteString("  nix profile install --profile " + shellQuote(ProfilePath) + " path:/home/node/.config/vesper-dev#default\n")
	b.WriteString("  printf '%s\\n' " + shellQuote(hash) + " > " + shellQuote(stamp) + "\n")
	b.WriteString("fi\n")
	b.WriteString("uname -m\n")
	return b.String()
}

// SyncReposScript returns a shell script that clones any missing repositories
// into /workspace/<directory> and fetches existing ones without storing git
// credentials on disk.
func SyncReposScript(repos []RepoSpec, userName, userEmail string) string {
	var b strings.Builder
	b.WriteString("set -eu\n")
	b.WriteString("mkdir -p /workspace\n")
	if len(repos) == 0 {
		return b.String()
	}
	b.WriteString(`helper=""
cleanup_helper() { [ -n "$helper" ] && rm -f "$helper"; }
trap cleanup_helper EXIT
if [ -n "${GH_TOKEN:-}" ]; then
  helper=$(mktemp)
  chmod 700 "$helper"
  printf '#!/bin/sh\necho "username=x-access-token"\necho "password=%s"\n' "$GH_TOKEN" > "$helper"
fi
`)
	for _, r := range repos {
		dest := "/workspace/" + r.Directory
		qDest := shellQuote(dest)
		qURL := shellQuote(r.RepoURL)
		b.WriteString("if [ ! -d " + shellQuote(dest+"/.git") + " ]; then\n")
		b.WriteString("  if [ -n \"$helper\" ]; then\n")
		b.WriteString("    git -c credential.helper= -c \"credential.helper=$helper\" clone --quiet -- " + qURL + " " + qDest + "\n")
		b.WriteString("  else\n")
		b.WriteString("    git clone --quiet -- " + qURL + " " + qDest + "\n")
		b.WriteString("  fi\n")
		if userName != "" {
			b.WriteString("  git -C " + qDest + " config user.name " + shellQuote(userName) + "\n")
		}
		if userEmail != "" {
			b.WriteString("  git -C " + qDest + " config user.email " + shellQuote(userEmail) + "\n")
		}
		b.WriteString("else\n")
		b.WriteString("  if [ -n \"$helper\" ]; then\n")
		b.WriteString("    git -C " + qDest + " -c credential.helper= -c \"credential.helper=$helper\" fetch --quiet --all --prune || true\n")
		b.WriteString("  else\n")
		b.WriteString("    git -C " + qDest + " fetch --quiet --all --prune || true\n")
		b.WriteString("  fi\n")
		b.WriteString("fi\n")
	}
	return b.String()
}
