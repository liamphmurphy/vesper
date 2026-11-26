//go:build linux

package main

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"golang.org/x/sys/unix"
)

const (
	overlayfsSuperMagic = 0x794c7630
	openNoFollowFlag    = syscall.O_NOFOLLOW
)

// bootstrapPID1 prepares mounts, overlayfs pivot_root onto EROFS, cgroup v2,
// and attached virtio-blk / virtiofs disks before serving RPCs.
func bootstrapPID1() error {
	if _, err := os.Stat("/dev/null"); err != nil {
		_ = os.MkdirAll("/dev", 0o755)
		_ = unix.Mount("devtmpfs", "/dev", "devtmpfs", 0, "")
	}

	if !isRootOverlay() {
		if err := pivotToOverlayRoot(); err != nil {
			return fmt.Errorf("pivot overlay root: %w", err)
		}
		// Re-exec ourselves once on the new overlayfs root so PID 1 releases /oldroot text references.
		_ = unix.Exec("/sbin/init", os.Args, os.Environ())
		return errors.New("re-exec /sbin/init after pivot_root failed")
	}

	if err := mountCoreFS(); err != nil {
		return fmt.Errorf("core mounts: %w", err)
	}
	if err := setupCgroupsV2(); err != nil {
		return fmt.Errorf("cgroup2 setup: %w", err)
	}
	if err := mountAttachedDisks(); err != nil {
		return fmt.Errorf("mount disks: %w", err)
	}
	return nil
}

func isRootOverlay() bool {
	var st unix.Statfs_t
	if err := unix.Statfs("/", &st); err != nil {
		return false
	}
	return uint64(st.Type) == overlayfsSuperMagic
}

func pivotToOverlayRoot() error {
	// /mnt exists on the read-only rootfs; mount a writable tmpfs there to hold
	// overlayfs lower/upper/work/merged dirs without touching the read-only /.
	if err := unix.Mount("tmpfs", "/mnt", "tmpfs", 0, "mode=0755"); err != nil {
		return fmt.Errorf("mount tmpfs /mnt: %w", err)
	}
	for _, dir := range []string{"/mnt/lower", "/mnt/upper", "/mnt/work", "/mnt/merged"} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			return err
		}
	}
	// Non-recursive bind of / exposes only the underlying EROFS root at /mnt/lower.
	if err := unix.Mount("/", "/mnt/lower", "", unix.MS_BIND|unix.MS_RDONLY, ""); err != nil {
		return fmt.Errorf("bind / -> /mnt/lower: %w", err)
	}
	opts := "lowerdir=/mnt/lower,upperdir=/mnt/upper,workdir=/mnt/work"
	if err := unix.Mount("overlay", "/mnt/merged", "overlay", 0, opts); err != nil {
		return fmt.Errorf("mount overlay /mnt/merged: %w", err)
	}
	if err := os.MkdirAll("/mnt/merged/oldroot", 0o755); err != nil {
		return err
	}
	if err := os.MkdirAll("/mnt/merged/run", 0o755); err != nil {
		return err
	}
	_ = unix.Mount("", "/", "", unix.MS_REC|unix.MS_PRIVATE, "")
	if err := unix.Chdir("/mnt/merged"); err != nil {
		return err
	}
	if err := unix.PivotRoot(".", "oldroot"); err != nil {
		// Fallback if root was initramfs or kernel rejected pivot_root.
		if merr := unix.Mount(".", "/", "", unix.MS_MOVE, ""); merr != nil {
			return fmt.Errorf("pivot_root (%w) and MS_MOVE (%v)", err, merr)
		}
		if cerr := unix.Chroot("."); cerr != nil {
			return fmt.Errorf("chroot fallback: %w", cerr)
		}
	}
	if err := unix.Chdir("/"); err != nil {
		return err
	}
	_ = unix.Unmount("/oldroot", unix.MNT_DETACH)
	return nil
}

func mountCoreFS() error {
	ensureMount := func(src, target, fstype string, flags uintptr, data string, mode os.FileMode) error {
		_ = os.MkdirAll(target, mode)
		if isMountPoint(target) {
			return nil
		}
		return unix.Mount(src, target, fstype, flags, data)
	}
	if err := ensureMount("proc", "/proc", "proc", unix.MS_NOSUID|unix.MS_NODEV|unix.MS_NOEXEC, "", 0o555); err != nil {
		return fmt.Errorf("/proc: %w", err)
	}
	if err := ensureMount("sysfs", "/sys", "sysfs", unix.MS_NOSUID|unix.MS_NODEV|unix.MS_NOEXEC, "", 0o555); err != nil {
		return fmt.Errorf("/sys: %w", err)
	}
	if err := ensureMount("devtmpfs", "/dev", "devtmpfs", 0, "mode=0755", 0o755); err != nil {
		return fmt.Errorf("/dev: %w", err)
	}
	if err := ensureMount("devpts", "/dev/pts", "devpts", unix.MS_NOSUID|unix.MS_NOEXEC, "gid=5,mode=620,ptmxmode=0666", 0o755); err != nil {
		return fmt.Errorf("/dev/pts: %w", err)
	}
	_ = os.Remove("/dev/ptmx")
	_ = os.Symlink("pts/ptmx", "/dev/ptmx")
	// devtmpfs has no /dev/fd or std links (udev makes them elsewhere); bash
	// process substitution needs them, e.g. nixpkgs' patchelf setup hook.
	for name, target := range map[string]string{
		"/dev/fd":     "/proc/self/fd",
		"/dev/stdin":  "/proc/self/fd/0",
		"/dev/stdout": "/proc/self/fd/1",
		"/dev/stderr": "/proc/self/fd/2",
	} {
		if _, err := os.Lstat(name); os.IsNotExist(err) {
			_ = os.Symlink(target, name)
		}
	}
	if err := ensureMount("tmpfs", "/dev/shm", "tmpfs", unix.MS_NOSUID|unix.MS_NODEV, "mode=1777", 0o1777); err != nil {
		return fmt.Errorf("/dev/shm: %w", err)
	}
	// /tmp and /workspace are where turn containers may bind from (see
	// docker_guard.go), and root in a container could leave a setuid or
	// file-capability binary there for the uid-1000 turn to run.
	if err := ensureMount("tmpfs", "/tmp", "tmpfs", unix.MS_NOSUID|unix.MS_NODEV, "mode=1777", 0o1777); err != nil {
		return fmt.Errorf("/tmp: %w", err)
	}
	if err := ensureMount("tmpfs", "/run", "tmpfs", unix.MS_NOSUID|unix.MS_NODEV, "mode=0755", 0o755); err != nil {
		return fmt.Errorf("/run: %w", err)
	}
	_ = unix.Sethostname([]byte("vesper"))
	return nil
}

func isMountPoint(path string) bool {
	var st, pst unix.Stat_t
	if err := unix.Lstat(path, &st); err != nil {
		return false
	}
	if err := unix.Lstat(filepath.Dir(path), &pst); err != nil {
		return false
	}
	return st.Dev != pst.Dev
}

func setupCgroupsV2() error {
	_ = os.MkdirAll("/sys/fs/cgroup", 0o755)
	if !isMountPoint("/sys/fs/cgroup") {
		if err := unix.Mount("cgroup2", "/sys/fs/cgroup", "cgroup2", 0, ""); err != nil {
			return err
		}
	}
	_ = os.MkdirAll("/sys/fs/cgroup/init.scope", 0o755)
	_ = os.WriteFile("/sys/fs/cgroup/init.scope/cgroup.procs", []byte("1\n"), 0o644)
	enableControllers("/sys/fs/cgroup")
	_ = os.MkdirAll("/sys/fs/cgroup/turns", 0o755)
	enableControllers("/sys/fs/cgroup/turns")
	return nil
}

func enableControllers(cgDir string) {
	b, err := os.ReadFile(filepath.Join(cgDir, "cgroup.controllers"))
	if err != nil {
		return
	}
	var want []string
	for _, c := range strings.Fields(string(b)) {
		switch c {
		case "memory", "pids", "cpu":
			want = append(want, "+"+c)
		}
	}
	if len(want) > 0 {
		_ = os.WriteFile(filepath.Join(cgDir, "cgroup.subtree_control"), []byte(strings.Join(want, " ")), 0o644)
	}
}

// workspaceMountFlags: see the /tmp mount in mountCoreFS.
const workspaceMountFlags = unix.MS_NOSUID | unix.MS_NODEV

// diskMountFlags returns the mount flags for an attached ext4 disk. /home/node
// and /nix outlive turns, so a setuid binary or device node placed onto them
// must not elevate privileges in later turns.
func diskMountFlags(target string) uintptr {
	flags := uintptr(unix.MS_NOATIME)
	switch target {
	case "/workspace", "/home/node", "/nix":
		flags |= workspaceMountFlags
	}
	return flags
}

func mountAttachedDisks() error {
	// Optional HostFolders shared workspace over virtiofs (tag "workspace").
	_ = os.MkdirAll("/workspace", 0o777)
	hasVirtioWorkspace := unix.Mount("workspace", "/workspace", "virtiofs", workspaceMountFlags, "") == nil

	blocks, err := filepath.Glob("/dev/vd[b-z]")
	if err != nil {
		return err
	}
	type blockInfo struct{ fsType, label string }
	infos := make([]blockInfo, len(blocks))
	scan := make([]volumeInfo, len(blocks))
	for i, dev := range blocks {
		infos[i].fsType, infos[i].label = detectBlockVolume(dev)
		scan[i] = volumeInfo{infos[i].fsType, infos[i].label}
	}
	persistNix := hasPersistentNix(scan)
	for i, dev := range blocks {
		fsType, label := infos[i].fsType, infos[i].label
		switch fsType {
		case "ext4":
			var target string
			var chownNode bool
			switch label {
			case "vesper-ws", "":
				if hasVirtioWorkspace && label == "vesper-ws" {
					continue
				}
				if label == "" && dev != "/dev/vdb" {
					continue
				}
				target = "/workspace"
				chownNode = true
			case "vesper-home":
				target = "/home/node"
				chownNode = true
			case "vesper-dkr":
				target = "/var/lib/docker"
			case nixDiskLabel:
				if err := mountPersistentNix(dev); err != nil {
					return err
				}
				continue
			default:
				continue
			}
			_ = os.MkdirAll(target, 0o755)
			if err := unix.Mount(dev, target, "ext4", diskMountFlags(target), ""); err != nil {
				return fmt.Errorf("mount %s (%s) on %s: %w", dev, label, target, err)
			}
			if chownNode {
				_ = os.Chown(target, 1000, 1000)
			}
		case "erofs":
			var target string
			switch label {
			case "cache-nix":
				if persistNix {
					continue
				}
				target = "/nix"
			case "cache-gomod":
				target = "/cache/gomod"
			case "cache-npm":
				target = "/cache/npm"
			case "cache-oci":
				target = "/cache/oci"
			default:
				continue
			}
			mountROCacheWithOverlay(dev, target, label)
		}
	}
	_ = os.MkdirAll("/home/node", 0o755)
	_ = os.Chown("/home/node", 1000, 1000)
	_ = os.MkdirAll("/workspace", 0o755)
	_ = os.Chown("/workspace", 1000, 1000)
	return nil
}

const nixDiskLabel = "vesper-nix"

type volumeInfo struct{ fsType, label string }

// hasPersistentNix reports whether an ext4 volume labelled vesper-nix is
// attached. When it is, /nix lives on that disk and the cache-nix EROFS
// overlay must not be stacked on it.
func hasPersistentNix(vols []volumeInfo) bool {
	for _, v := range vols {
		if v.fsType == "ext4" && v.label == nixDiskLabel {
			return true
		}
	}
	return false
}

// mountPersistentNix mounts the vesper-nix disk, seeds it once from the
// image's /nix, and bind-mounts it over /nix. The atomic rename of nix.tmp to
// nix is the "seeded" marker, so a crash mid-copy simply reseeds.
func mountPersistentNix(dev string) error {
	const mnt = "/run/vesper-nix"
	if err := os.MkdirAll(mnt, 0o755); err != nil {
		return err
	}
	if err := unix.Mount(dev, mnt, "ext4", diskMountFlags("/nix"), ""); err != nil {
		return fmt.Errorf("mount %s (%s) on %s: %w", dev, nixDiskLabel, mnt, err)
	}
	store := filepath.Join(mnt, "nix")
	if _, err := os.Stat(store); err != nil {
		if !os.IsNotExist(err) {
			return err
		}
		tmp := filepath.Join(mnt, "nix.tmp")
		if err := os.RemoveAll(tmp); err != nil {
			return fmt.Errorf("clean %s: %w", tmp, err)
		}
		if err := os.MkdirAll(tmp, 0o755); err != nil {
			return err
		}
		if out, err := exec.Command("cp", "-a", "/nix/.", tmp+"/").CombinedOutput(); err != nil {
			return fmt.Errorf("seed nix disk: %w: %s", err, out)
		}
		if err := os.Rename(tmp, store); err != nil {
			return fmt.Errorf("seed nix disk: %w", err)
		}
	}
	if err := unix.Mount(store, "/nix", "", unix.MS_BIND, ""); err != nil {
		return fmt.Errorf("bind %s on /nix: %w", store, err)
	}
	return nil
}

func mountROCacheWithOverlay(dev, target, label string) {
	lower := filepath.Join("/run/cache-ro", label)
	upper := filepath.Join("/tmp/cache-ovl", label, "upper")
	work := filepath.Join("/tmp/cache-ovl", label, "work")
	_ = os.MkdirAll(lower, 0o755)
	_ = os.MkdirAll(upper, 0o755)
	_ = os.MkdirAll(work, 0o755)
	_ = os.MkdirAll(target, 0o755)
	if err := unix.Mount(dev, lower, "erofs", unix.MS_RDONLY, ""); err != nil {
		return
	}
	_ = unix.Mount("overlay", target, "overlay", workspaceMountFlags, fmt.Sprintf("lowerdir=%s,upperdir=%s,workdir=%s", lower, upper, work))
}

func detectBlockVolume(dev string) (fsType, label string) {
	f, err := os.Open(dev)
	if err != nil {
		return "", ""
	}
	defer f.Close()
	buf := make([]byte, 2048)
	if _, err := f.ReadAt(buf, 0); err != nil {
		return "", ""
	}
	// ext4 superblock starts at offset 1024. Magic 0xEF53 at +0x38, s_volume_name[16] at +0x78.
	if binary.LittleEndian.Uint16(buf[1024+0x38:1024+0x3a]) == 0xEF53 {
		return "ext4", strings.TrimRight(string(bytes.SplitN(buf[1024+0x78:1024+0x78+16], []byte{0}, 2)[0]), "\x00")
	}
	// EROFS superblock starts at offset 1024. Magic 0xE0F5E1E2 at +0, volume_name[16] at +48.
	if binary.LittleEndian.Uint32(buf[1024:1028]) == 0xE0F5E1E2 {
		return "erofs", strings.TrimRight(string(bytes.SplitN(buf[1024+48:1024+64], []byte{0}, 2)[0]), "\x00")
	}
	return "", ""
}

// startOrphanReaper reaps adopted zombie orphans (PPid == 1) without racing
// os/exec Wait on tracked direct child processes.
func startOrphanReaper(ctx context.Context, execs *execTracker) {
	ch := make(chan os.Signal, 32)
	signal.Notify(ch, syscall.SIGCHLD)
	go func() {
		defer signal.Stop(ch)
		for {
			select {
			case <-ctx.Done():
				return
			case <-ch:
				reapUntrackedOrphans(execs)
			}
		}
	}()
}

func reapUntrackedOrphans(execs *execTracker) {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return
	}
	for _, ent := range entries {
		if !ent.IsDir() {
			continue
		}
		pid, err := strconv.Atoi(ent.Name())
		if err != nil || pid <= 1 || execs.isTracked(pid) {
			continue
		}
		stat, err := os.ReadFile(filepath.Join("/proc", ent.Name(), "stat"))
		if err != nil {
			continue
		}
		// format: pid (comm) state ppid ...
		rp := bytes.LastIndexByte(stat, ')')
		if rp < 0 || rp+2 >= len(stat) {
			continue
		}
		fields := strings.Fields(string(stat[rp+2:]))
		if len(fields) >= 2 && fields[0] == "Z" && fields[1] == "1" {
			// Double-check under tracked lock just before Wait4.
			if !execs.isTracked(pid) {
				var ws unix.WaitStatus
				_, _ = unix.Wait4(pid, &ws, unix.WNOHANG, nil)
			}
		}
	}
}

func applyCgroupLimits(name string, memoryBytes, pidsLimit int64) (string, error) {
	dir := filepath.Join("/sys/fs/cgroup/turns", filepath.Base(name))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	if memoryBytes > 0 {
		_ = os.WriteFile(filepath.Join(dir, "memory.max"), []byte(strconv.FormatInt(memoryBytes, 10)), 0o644)
		_ = os.WriteFile(filepath.Join(dir, "memory.swap.max"), []byte("0"), 0o644)
	}
	if pidsLimit > 0 {
		_ = os.WriteFile(filepath.Join(dir, "pids.max"), []byte(strconv.FormatInt(pidsLimit, 10)), 0o644)
	}
	return dir, nil
}

func addPidToCgroup(dir string, pid int) error {
	return os.WriteFile(filepath.Join(dir, "cgroup.procs"), []byte(strconv.Itoa(pid)), 0o644)
}

func killAndCheckOOM(dir string) bool {
	if dir == "" {
		return false
	}
	var oom bool
	if b, err := os.ReadFile(filepath.Join(dir, "memory.events")); err == nil {
		for _, line := range strings.Split(string(b), "\n") {
			fields := strings.Fields(line)
			if len(fields) == 2 && (fields[0] == "oom" || fields[0] == "oom_kill") {
				if v, _ := strconv.ParseInt(fields[1], 10, 64); v > 0 {
					oom = true
				}
			}
		}
	}
	_ = os.WriteFile(filepath.Join(dir, "cgroup.kill"), []byte("1"), 0o644)
	for i := 0; i < 20; i++ {
		if err := os.Remove(dir); err == nil || errors.Is(err, os.ErrNotExist) {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	return oom
}

func setupChildSysProcAttr(cmd *exec.Cmd, uid, gid int, useTTY bool, cgPath string) (cleanup func(), attachedViaFD bool) {
	attr := &syscall.SysProcAttr{
		Setsid:  useTTY,
		Setpgid: !useTTY,
	}
	if uid > 0 || gid > 0 {
		attr.Credential = &syscall.Credential{Uid: uint32(uid), Gid: uint32(gid)}
	}
	cleanup = func() {}
	if cgPath != "" {
		if cgDir, err := os.Open(cgPath); err == nil {
			attr.UseCgroupFD = true
			attr.CgroupFD = int(cgDir.Fd())
			attachedViaFD = true
			cleanup = func() { _ = cgDir.Close() }
		}
	}
	cmd.SysProcAttr = attr
	return cleanup, attachedViaFD
}

func signalProcessGroup(cmd *exec.Cmd, sig uint32) error {
	if cmd == nil || cmd.Process == nil || sig == 0 {
		return nil
	}
	// Signal negative PID to target the entire process group / session leader group.
	return unix.Kill(-cmd.Process.Pid, unix.Signal(sig))
}

func syncAndDropCaches() error {
	unix.Sync()
	if err := os.WriteFile("/proc/sys/vm/drop_caches", []byte("3\n"), 0o644); err != nil {
		return err
	}
	return nil
}

func powerOffGuest() {
	unix.Sync()
	_ = unix.Reboot(unix.LINUX_REBOOT_CMD_POWER_OFF)
}
