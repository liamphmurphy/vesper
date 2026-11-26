package main

import (
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func copyTree(t *testing.T, src, dst string) {
	t.Helper()
	err := filepath.WalkDir(src, func(path string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if d.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		if d.Type()&os.ModeSymlink != 0 {
			link, err := os.Readlink(path)
			if err != nil {
				return err
			}
			return os.Symlink(link, target)
		}
		info, err := d.Info()
		if err != nil {
			return err
		}
		data, err := os.ReadFile(path)
		if err != nil {
			return err
		}
		return os.WriteFile(target, data, info.Mode().Perm())
	})
	if err != nil {
		t.Fatalf("copyTree(%s -> %s): %v", src, dst, err)
	}
}

func runBuildImages(t *testing.T, script string, env []string, args ...string) string {
	t.Helper()
	cmd := exec.Command("bash", append([]string{script}, args...)...)
	cmd.Env = append(os.Environ(), env...)
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("build-images.sh %v failed: %v\n%s", args, err, out)
	}
	return string(out)
}

var (
	kernelLineRe = regexp.MustCompile(`(?m)^kernel: ([^\[\n]+)\[inputs=([0-9a-f]{64})\]$`)
	rootfsLineRe = regexp.MustCompile(`(?m)^rootfs: ([^\[\n]+)\[inputs=([0-9a-f]{64})\]$`)
	baseHashRe   = regexp.MustCompile(`(?m)^base_image_inputs=([0-9a-f]{64})$`)
)

func parseCheckOutput(t *testing.T, out string) (kernelStatus, kernelHash, rootfsStatus, rootfsHash, baseHash string) {
	t.Helper()
	km := kernelLineRe.FindStringSubmatch(out)
	if len(km) != 3 {
		t.Fatalf("missing kernel line in output:\n%s", out)
	}
	rm := rootfsLineRe.FindStringSubmatch(out)
	if len(rm) != 3 {
		t.Fatalf("missing rootfs line in output:\n%s", out)
	}
	bm := baseHashRe.FindStringSubmatch(out)
	if len(bm) != 2 {
		t.Fatalf("missing base_image_inputs line in output:\n%s", out)
	}
	return strings.TrimSpace(km[1]), km[2], strings.TrimSpace(rm[1]), rm[2], bm[1]
}

func seedFakeImages(t *testing.T, imgDir, kernelHash, rootfsHash string) {
	t.Helper()
	if err := os.MkdirAll(imgDir, 0o755); err != nil {
		t.Fatal(err)
	}
	write := func(name, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(imgDir, name), []byte(body), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	write("vmlinux", "fake-kernel")
	write("vmlinux.sha256", strings.Repeat("a", 64)+"  vmlinux\n")
	write("vmlinux.inputs.sha256", kernelHash+"\n")
	write("agent-base.erofs", "fake-rootfs")
	write("agent-base.erofs.sha256", strings.Repeat("b", 64)+"  agent-base.erofs\n")
	write("agent-base.erofs.inputs.sha256", rootfsHash+"\n")
}

func TestBuildImagesAutoDetect(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	// Copy only the inputs build-images.sh inspects into a temp repo so we can mutate
	// individual files without touching the real checkout.
	tmpRepo := t.TempDir()
	for _, relDir := range []string{
		"deploy/microvm",
		"deploy/agent-base",
		"server/cmd/vesper-guest-agent",
		"server/cmd/vesper-mac",
		"server/internal/guestproto",
		"server/internal/macclient",
		"server/internal/runner/microvm",
	} {
		copyTree(t, filepath.Join(repoRoot, relDir), filepath.Join(tmpRepo, relDir))
	}
	for _, relFile := range []string{"server/go.mod", "server/go.sum"} {
		data, err := os.ReadFile(filepath.Join(repoRoot, relFile))
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(tmpRepo, relFile), data, 0o644); err != nil {
			t.Fatal(err)
		}
	}

	script := filepath.Join(tmpRepo, "deploy", "microvm", "build-images.sh")
	imgDir := filepath.Join(t.TempDir(), "images")
	baseEnv := []string{"VESPER_IMAGES_DIR=" + imgDir}

	// 1. Empty image dir requires rebuilding both.
	out := runBuildImages(t, script, baseEnv, "--auto", "--check")
	ks, kHash, rs, rHash, bHash := parseCheckOutput(t, out)
	if !strings.HasPrefix(ks, "rebuild (vmlinux missing)") {
		t.Fatalf("expected missing vmlinux rebuild, got %q", ks)
	}
	if !strings.HasPrefix(rs, "rebuild (agent-base.erofs missing)") {
		t.Fatalf("expected missing rootfs rebuild, got %q", rs)
	}

	// 2. Seeding matching outputs + sidecars marks both up-to-date, and --auto skips Docker completely.
	seedFakeImages(t, imgDir, kHash, rHash)
	out = runBuildImages(t, script, baseEnv, "--auto", "--check")
	ks, _, rs, _, _ = parseCheckOutput(t, out)
	if ks != "up-to-date" || rs != "up-to-date" {
		t.Fatalf("expected both up-to-date, got kernel=%q rootfs=%q", ks, rs)
	}
	// Run without --check with a broken DOCKER_HOST to prove Docker isn't invoked when up-to-date.
	out = runBuildImages(t, script, append(baseEnv, "DOCKER_HOST=unix:///nonexistent-docker.sock"), "--auto")
	if !strings.Contains(out, "Kernel up to date") || !strings.Contains(out, "Rootfs up to date") {
		t.Fatalf("expected up-to-date messages without Docker, got:\n%s", out)
	}

	// 3. --auto --force forces both.
	out = runBuildImages(t, script, baseEnv, "--auto", "--force", "--check")
	ks, _, rs, _, _ = parseCheckOutput(t, out)
	if ks != "rebuild (forced)" || rs != "rebuild (forced)" {
		t.Fatalf("expected forced rebuilds, got kernel=%q rootfs=%q", ks, rs)
	}

	// 4. Missing sidecar triggers only the affected image.
	if err := os.Remove(filepath.Join(imgDir, "vmlinux.sha256")); err != nil {
		t.Fatal(err)
	}
	out = runBuildImages(t, script, baseEnv, "--auto", "--check")
	ks, _, rs, _, _ = parseCheckOutput(t, out)
	if ks != "rebuild (vmlinux.sha256 missing)" || rs != "up-to-date" {
		t.Fatalf("expected kernel-only rebuild for missing sha256, got kernel=%q rootfs=%q", ks, rs)
	}
	seedFakeImages(t, imgDir, kHash, rHash)

	// 5. Backwards-compatible CI mode (without --auto): existing vmlinux without .inputs.sha256 is reused.
	if err := os.Remove(filepath.Join(imgDir, "vmlinux.inputs.sha256")); err != nil {
		t.Fatal(err)
	}
	out = runBuildImages(t, script, baseEnv, "--kernel", "--rootfs", "--check")
	ks, _, rs, _, _ = parseCheckOutput(t, out)
	if ks != "up-to-date" || rs != "rebuild (requested)" {
		t.Fatalf("expected CI mode to reuse cached vmlinux and build rootfs, got kernel=%q rootfs=%q", ks, rs)
	}
	seedFakeImages(t, imgDir, kHash, rHash)

	// 6. Changing VESPER_KERNEL_VERSION invalidates kernel only.
	out = runBuildImages(t, script, append(baseEnv, "VESPER_KERNEL_VERSION=6.12.999"), "--auto", "--check")
	ks, kHash2, rs, rHash2, _ := parseCheckOutput(t, out)
	if ks != "rebuild (kernel inputs changed)" || rs != "up-to-date" {
		t.Fatalf("expected kernel-only rebuild on version bump, got kernel=%q rootfs=%q", ks, rs)
	}
	if kHash2 == kHash || rHash2 != rHash {
		t.Fatalf("expected only kernel hash to change")
	}

	appendLine := func(rel, line string) {
		t.Helper()
		p := filepath.Join(tmpRepo, rel)
		orig, err := os.ReadFile(p)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, append(orig, []byte(line)...), 0o644); err != nil {
			t.Fatal(err)
		}
	}

	// 7. Editing _test.go or _darwin.go must NOT trigger a rootfs rebuild.
	appendLine("server/cmd/vesper-guest-agent/agent_test.go", "\n// test-only comment\n")
	appendLine("server/internal/runner/microvm/driver_darwin.go", "\n// darwin-only comment\n")
	out = runBuildImages(t, script, baseEnv, "--auto", "--check")
	ks, _, rs, _, _ = parseCheckOutput(t, out)
	if ks != "up-to-date" || rs != "up-to-date" {
		t.Fatalf("expected test/darwin edits not to invalidate images, got kernel=%q rootfs=%q", ks, rs)
	}

	// 8. Editing a transitive Go dependency of vesper-guest-agent invalidates rootfs only.
	appendLine("server/internal/guestproto/proto.go", "\n// proto change\n")
	out = runBuildImages(t, script, baseEnv, "--auto", "--check")
	ks, _, rs, rHashAfterProto, bHashAfterProto := parseCheckOutput(t, out)
	if ks != "up-to-date" || rs != "rebuild (rootfs inputs changed)" {
		t.Fatalf("expected rootfs-only rebuild after guestproto edit, got kernel=%q rootfs=%q", ks, rs)
	}
	if bHashAfterProto != bHash {
		t.Fatalf("guestproto edit should not change base_image_inputs")
	}
	seedFakeImages(t, imgDir, kHash, rHashAfterProto)

	// 9. Editing deploy/agent-base/Dockerfile invalidates base_image_inputs and rootfs, not kernel.
	appendLine("deploy/agent-base/Dockerfile", "\n# base image change\n")
	out = runBuildImages(t, script, baseEnv, "--auto", "--check")
	ks, _, rs, rHashAfterBase, bHashAfterBase := parseCheckOutput(t, out)
	if ks != "up-to-date" || rs != "rebuild (rootfs inputs changed)" {
		t.Fatalf("expected rootfs rebuild after agent-base edit, got kernel=%q rootfs=%q", ks, rs)
	}
	if bHashAfterBase == bHashAfterProto {
		t.Fatalf("expected base_image_inputs to change after agent-base edit")
	}
	seedFakeImages(t, imgDir, kHash, rHashAfterBase)

	// 10. Editing kernel.fragment.config invalidates kernel only.
	appendLine("deploy/microvm/kernel.fragment.config", "\n# kernel config change\n")
	out = runBuildImages(t, script, baseEnv, "--auto", "--check")
	ks, _, rs, _, _ = parseCheckOutput(t, out)
	if ks != "rebuild (kernel inputs changed)" || rs != "up-to-date" {
		t.Fatalf("expected kernel-only rebuild after kernel.fragment.config edit, got kernel=%q rootfs=%q", ks, rs)
	}
}
