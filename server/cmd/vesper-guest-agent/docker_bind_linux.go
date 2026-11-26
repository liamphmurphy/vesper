//go:build linux

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

const dockerBindDir = "/run/vesper-binds"

// resolveAndPinBind validates src atomically with openat2(RESOLVE_BENEATH) so
// symlinks cannot escape workspace or scratch, verifies ownership on scratch
// via fstatat(AT_EMPTY_PATH) on the pinned fd, and when g.bindRoot is set
// (root PID 1) bind-mounts /proc/self/fd/<fd> under root-only /run/vesper-binds
// so uid 1000 cannot swap the path before dockerd calls mount(2).
func (g *dockerGuard) resolveAndPinBind(src string) (string, error) {
	if !filepath.IsAbs(src) {
		return "", errors.New("the source must be an absolute path")
	}
	clean := filepath.Clean(src)
	ws := resolvedRoot(g.binds.workspace)
	scratch := resolvedRoot(g.binds.scratch)

	var (
		rootDir     string
		rel         string
		needOwnUID  bool
	)
	switch {
	case within(clean, g.binds.workspace):
		rootDir = ws
		rel = strings.TrimPrefix(strings.TrimPrefix(clean, filepath.Clean(g.binds.workspace)), "/")
	case within(clean, ws):
		rootDir = ws
		rel = strings.TrimPrefix(strings.TrimPrefix(clean, ws), "/")
	case clean == filepath.Clean(g.binds.scratch) || clean == scratch:
		return "", fmt.Errorf("only paths in the checkout (under %s) or your own under %s can be mounted", g.binds.workspace, g.binds.scratch)
	case within(clean, g.binds.scratch):
		rootDir = scratch
		rel = strings.TrimPrefix(strings.TrimPrefix(clean, filepath.Clean(g.binds.scratch)), "/")
		needOwnUID = true
	case within(clean, scratch):
		rootDir = scratch
		rel = strings.TrimPrefix(strings.TrimPrefix(clean, scratch), "/")
		needOwnUID = true
	default:
		return "", fmt.Errorf("only paths in the checkout (under %s) or your own under %s can be mounted", g.binds.workspace, g.binds.scratch)
	}
	if rel == "" {
		rel = "."
	}

	rootFD, err := unix.Open(rootDir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return "", fmt.Errorf("open bind root: %w", err)
	}
	defer unix.Close(rootFD)

	fd, err := unix.Openat2(rootFD, rel, &unix.OpenHow{
		Flags:   unix.O_PATH | unix.O_CLOEXEC,
		Resolve: unix.RESOLVE_BENEATH,
	})
	if err != nil {
		return "", fmt.Errorf("resolve it: %w", err)
	}
	defer unix.Close(fd)

	var st unix.Stat_t
	if err := unix.Fstatat(fd, "", &st, unix.AT_EMPTY_PATH); err != nil {
		return "", err
	}
	if needOwnUID && int(st.Uid) != g.binds.uid {
		return "", fmt.Errorf("only files and folders you created under %s can be mounted", g.binds.scratch)
	}

	isDir := (st.Mode & unix.S_IFMT) == unix.S_IFDIR
	if g.pinBindFD != nil {
		return g.pinBindFD(fd, isDir)
	}
	if g.bindRoot != "" {
		return g.mountPinnedBind(fd, isDir)
	}

	// Non-root test mode: return the canonical path of the already-validated fd.
	real, err := os.Readlink(fmt.Sprintf("/proc/self/fd/%d", fd))
	if err != nil {
		return filepath.Join(rootDir, rel), nil
	}
	return real, nil
}

func (g *dockerGuard) mountPinnedBind(fd int, isDir bool) (string, error) {
	if err := os.MkdirAll(dockerBindDir, 0o700); err != nil {
		return "", fmt.Errorf("create bind root: %w", err)
	}
	_ = os.Chmod(dockerBindDir, 0o700)
	if err := os.MkdirAll(g.bindRoot, 0o700); err != nil {
		return "", fmt.Errorf("create turn bind dir: %w", err)
	}
	_ = os.Chmod(g.bindRoot, 0o700)

	target := filepath.Join(g.bindRoot, strconv.FormatUint(g.bindSeq.Add(1), 10))
	if isDir {
		if err := os.Mkdir(target, 0o700); err != nil {
			return "", fmt.Errorf("create bind mountpoint: %w", err)
		}
	} else {
		f, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
		if err != nil {
			return "", fmt.Errorf("create bind file mountpoint: %w", err)
		}
		_ = f.Close()
	}

	srcFDPath := fmt.Sprintf("/proc/self/fd/%d", fd)
	if err := unix.Mount(srcFDPath, target, "", unix.MS_BIND, ""); err != nil {
		_ = os.Remove(target)
		return "", fmt.Errorf("pin bind mount: %w", err)
	}

	g.pinnedMu.Lock()
	g.pinnedBinds = append(g.pinnedBinds, target)
	g.pinnedMu.Unlock()
	return target, nil
}

func (g *dockerGuard) unmountPinnedBinds() {
	g.pinnedMu.Lock()
	targets := append([]string(nil), g.pinnedBinds...)
	g.pinnedBinds = nil
	g.pinnedMu.Unlock()
	for _, target := range targets {
		_ = unix.Unmount(target, unix.MNT_DETACH)
		_ = os.Remove(target)
	}
	if g.bindRoot != "" {
		_ = os.RemoveAll(g.bindRoot)
	}
}
