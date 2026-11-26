//go:build linux || darwin

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

// openFileNoFollowUnderRoot walks rel under rootDir component-by-component
// with O_NOFOLLOW|O_DIRECTORY (creating missing parent dirs and fchown'ing
// only newly created dirs), then opens the leaf with O_NOFOLLOW. Any symlink
// component (absolute or relative, intermediate or leaf) fails with ELOOP.
func openFileNoFollowUnderRoot(rootDir, rel string, mode os.FileMode, uid, gid int) (*os.File, error) {
	if rel == "" || rel == "." {
		return nil, fmt.Errorf("cannot write directly to root %q", rootDir)
	}
	dirfd, err := unix.Open(rootDir, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_CLOEXEC, 0)
	if err != nil {
		return nil, err
	}
	defer func() {
		if dirfd >= 0 {
			_ = unix.Close(dirfd)
		}
	}()

	parts := strings.Split(filepath.ToSlash(filepath.Clean(rel)), "/")
	for _, p := range parts {
		if p == "" || p == "." || p == ".." {
			return nil, fmt.Errorf("invalid relative guest path %q", rel)
		}
	}

	for _, part := range parts[:len(parts)-1] {
		nextFD, oerr := unix.Openat(dirfd, part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
		if errors.Is(oerr, unix.ENOENT) {
			if merr := unix.Mkdirat(dirfd, part, 0o755); merr != nil && !errors.Is(merr, unix.EEXIST) {
				return nil, merr
			}
			nextFD, oerr = unix.Openat(dirfd, part, unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC, 0)
			if oerr == nil && (uid > 0 || gid > 0) {
				_ = unix.Fchown(nextFD, uid, gid)
			}
		}
		if oerr != nil {
			return nil, fmt.Errorf("open dir %q under %s: %w", part, rootDir, oerr)
		}
		_ = unix.Close(dirfd)
		dirfd = nextFD
	}

	base := parts[len(parts)-1]
	fd, err := unix.Openat(dirfd, base, unix.O_WRONLY|unix.O_CREAT|unix.O_TRUNC|unix.O_NOFOLLOW|unix.O_CLOEXEC, uint32(mode))
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), filepath.Join(rootDir, rel)), nil
}
