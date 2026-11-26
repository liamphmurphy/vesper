//go:build !linux

package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

func (g *dockerGuard) resolveAndPinBind(src string) (string, error) {
	if !filepath.IsAbs(src) {
		return "", errors.New("the source must be an absolute path")
	}
	real, err := filepath.EvalSymlinks(src)
	if err != nil {
		return "", fmt.Errorf("resolve it: %w", err)
	}
	workspace, scratch := resolvedRoot(g.binds.workspace), resolvedRoot(g.binds.scratch)
	if within(real, workspace) {
		return real, nil
	}
	if real != scratch && within(real, scratch) {
		fi, err := os.Stat(real)
		if err != nil {
			return "", err
		}
		if st, ok := fi.Sys().(*syscall.Stat_t); ok && int(st.Uid) == g.binds.uid {
			return real, nil
		}
		return "", fmt.Errorf("only files and folders you created under %s can be mounted", g.binds.scratch)
	}
	return "", fmt.Errorf("only paths in the checkout (under %s) or your own under %s can be mounted", g.binds.workspace, g.binds.scratch)
}

func (g *dockerGuard) unmountPinnedBinds() {}
