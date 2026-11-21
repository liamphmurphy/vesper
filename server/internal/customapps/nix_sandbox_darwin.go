//go:build darwin

package customapps

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// nixSandboxCommand writes a macOS Seatbelt profile that limits writes to
// jobRoot (and /dev/null, /dev/zero, /dev/dtracehelper) while allowing reads on
// standard OS paths, resolved Nix store packages, and read-only host mounts.
func nixSandboxCommand(jobRoot string, roPaths []string, cmdPath string, args []string) (string, []string, error) {
	realRoot, err := filepath.EvalSymlinks(jobRoot)
	if err != nil {
		return "", nil, fmt.Errorf("resolve job root for sandbox: %w", err)
	}
	var roRules strings.Builder
	seen := map[string]bool{}
	addRO := func(raw string) error {
		p := strings.TrimSpace(raw)
		if p == "" {
			return nil
		}
		if eval, err := filepath.EvalSymlinks(p); err == nil {
			p = eval
		}
		lit, err := seatbeltLiteral(p)
		if err != nil {
			return err
		}
		if seen[lit] {
			return nil
		}
		seen[lit] = true
		fmt.Fprintf(&roRules, "  (subpath %s)\n", lit)
		return nil
	}

	for _, sysPath := range []string{
		"/nix",
		"/usr",
		"/bin",
		"/sbin",
		"/System",
		"/Library/Preferences",
		"/private/etc",
		"/private/var/db",
		"/dev",
	} {
		if err := addRO(sysPath); err != nil {
			return "", nil, err
		}
	}
	for _, p := range roPaths {
		if err := addRO(p); err != nil {
			return "", nil, err
		}
	}

	rootLit, err := seatbeltLiteral(realRoot)
	if err != nil {
		return "", nil, err
	}
	profile := fmt.Sprintf(`(version 1)
(deny default)
(allow process-exec*)
(allow process-fork)
(allow signal)
(allow sysctl-read)
(allow mach-lookup)
(allow ipc-posix-shm*)
(allow network*)
(allow file-read-metadata)
(allow file-ioctl)
(allow file-read*
%s)
(allow file-read* file-write*
  (subpath %s)
  (literal "/dev/null")
  (literal "/dev/zero")
  (literal "/dev/dtracehelper")
)
`, roRules.String(), rootLit)

	profilePath := filepath.Join(realRoot, "profile.sb")
	if err := os.WriteFile(profilePath, []byte(profile), 0o400); err != nil {
		return "", nil, fmt.Errorf("write sandbox profile: %w", err)
	}
	outArgs := make([]string, 0, 3+len(args))
	outArgs = append(outArgs, "-f", profilePath, cmdPath)
	outArgs = append(outArgs, args...)
	return "/usr/bin/sandbox-exec", outArgs, nil
}

func seatbeltLiteral(s string) (string, error) {
	for i := 0; i < len(s); i++ {
		if s[i] < 0x20 || s[i] == 0x7f {
			return "", fmt.Errorf("path contains control character and cannot enter sandbox profile")
		}
	}
	var b strings.Builder
	b.Grow(len(s) + 2)
	b.WriteByte('"')
	for i := 0; i < len(s); i++ {
		switch s[i] {
		case '\\', '"':
			b.WriteByte('\\')
		}
		b.WriteByte(s[i])
	}
	b.WriteByte('"')
	return b.String(), nil
}
