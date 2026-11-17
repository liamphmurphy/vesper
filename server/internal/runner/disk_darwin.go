//go:build darwin

package runner

import (
	"errors"
	"io"
	"os"

	"golang.org/x/sys/unix"
)

// cloneFile copies src to dst using APFS copy-on-write clonefile(2) when on the
// same filesystem, falling back to sparse file copy across filesystems.
func cloneFile(src, dst string) error {
	_ = os.Remove(dst)
	if err := unix.Clonefile(src, dst, 0); err == nil {
		return nil
	} else if !errors.Is(err, unix.EXDEV) && !errors.Is(err, unix.ENOTSUP) && !errors.Is(err, unix.EINVAL) {
		return err
	}
	return sparseCopyFile(src, dst)
}

func sparseCopyFile(src, dst string) error {
	sf, err := os.Open(src)
	if err != nil {
		return err
	}
	defer sf.Close()
	info, err := sf.Stat()
	if err != nil {
		return err
	}
	df, err := os.OpenFile(dst, os.O_CREATE|os.O_RDWR|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	defer func() {
		if err != nil {
			_ = df.Close()
			_ = os.Remove(dst)
		}
	}()
	if err = df.Truncate(info.Size()); err != nil {
		return err
	}
	buf := make([]byte, 64<<10)
	var offset int64
	for {
		n, rerr := sf.Read(buf)
		if n > 0 {
			if !isAllZero(buf[:n]) {
				if _, werr := df.WriteAt(buf[:n], offset); werr != nil {
					err = werr
					return err
				}
			}
			offset += int64(n)
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			err = rerr
			return err
		}
	}
	return df.Close()
}

func isAllZero(b []byte) bool {
	for _, v := range b {
		if v != 0 {
			return false
		}
	}
	return true
}
