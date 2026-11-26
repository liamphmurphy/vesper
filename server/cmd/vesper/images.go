package main

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
)

type RootfsStatus struct {
	State           string `json:"state"` // "checking", "downloading", "ready", "error"
	Path            string `json:"path,omitempty"`
	ExpectedSHA256  string `json:"expectedSha256,omitempty"`
	DownloadedBytes int64  `json:"downloadedBytes"`
	TotalBytes      int64  `json:"totalBytes"`
	Error           string `json:"error,omitempty"`
}

type ImageManager struct {
	mu          sync.RWMutex
	status      RootfsStatus
	DownloadURL string
	HTTPClient  *http.Client
}

func NewImageManager() *ImageManager {
	return &ImageManager{
		status:     RootfsStatus{State: "checking"},
		HTTPClient: http.DefaultClient,
	}
}

func (m *ImageManager) Status() RootfsStatus {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.status
}

func (m *ImageManager) setStatus(fn func(*RootfsStatus)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	fn(&m.status)
}

// ResolveKernelPath finds the bundled or cached Linux arm64 vmlinux Image.
// Explicit paths win first, then the app bundle next to the running binary so
// rebuilt/upgraded app bundles replace stale images in <dataDir>/images/.
func ResolveKernelPath(explicit, dataDir, exeDir string) string {
	var candidates []string
	if explicit != "" {
		candidates = append(candidates, explicit)
	}
	if exeDir != "" {
		candidates = append(candidates,
			filepath.Join(exeDir, "..", "images", "vmlinux"),
			filepath.Join(exeDir, "images", "vmlinux"),
		)
	}
	if dataDir != "" {
		candidates = append(candidates, filepath.Join(dataDir, "images", "vmlinux"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates, filepath.Join(home, ".cache", "vesper", "images", "vmlinux"))
	}
	for _, c := range candidates {
		if st, err := os.Stat(c); err == nil && !st.IsDir() && st.Size() > 0 {
			return c
		}
	}
	return ""
}

// ExpectedRootfsSHA256 checks VESPER_ROOTFS_SHA256 or a bundled .sha256 sidecar.
// Bundled sidecars next to the binary take precedence over <dataDir>/images/ so
// upgrading the app updates the cached rootfs automatically.
func ExpectedRootfsSHA256(exeDir, dataDir string) string {
	if s := strings.TrimSpace(os.Getenv("VESPER_ROOTFS_SHA256")); s != "" {
		return strings.ToLower(s)
	}
	var candidates []string
	if exeDir != "" {
		candidates = append(candidates,
			filepath.Join(exeDir, "..", "images", "agent-base.erofs.sha256"),
			filepath.Join(exeDir, "images", "agent-base.erofs.sha256"),
		)
	}
	if dataDir != "" {
		candidates = append(candidates, filepath.Join(dataDir, "images", "agent-base.erofs.sha256"))
	}
	for _, p := range candidates {
		if raw, err := os.ReadFile(p); err == nil {
			fields := strings.Fields(string(raw))
			if len(fields) > 0 && len(fields[0]) == 64 {
				return strings.ToLower(fields[0])
			}
		}
	}
	return ""
}

// EnsureRootfs verifies or installs agent-base.erofs into <dataDir>/images/agent-base.erofs,
// supporting local fast-copy sources and HTTP Range-resumed HTTPS download with SHA-256 verification.
func (m *ImageManager) EnsureRootfs(ctx context.Context, explicit, dataDir, sourceDir, exeDir string) (string, error) {
	expected := ExpectedRootfsSHA256(exeDir, dataDir)
	m.setStatus(func(s *RootfsStatus) {
		s.State = "checking"
		s.ExpectedSHA256 = expected
		s.Error = ""
	})

	fail := func(err error) (string, error) {
		m.setStatus(func(s *RootfsStatus) {
			s.State = "error"
			s.Error = err.Error()
		})
		return "", err
	}

	if explicit != "" {
		if ok, err := verifyFileSHA256(explicit, expected); err == nil && ok {
			m.markReady(explicit)
			return explicit, nil
		}
	}

	dstDir := filepath.Join(dataDir, "images")
	if err := os.MkdirAll(dstDir, 0o755); err != nil {
		return fail(err)
	}
	dst := filepath.Join(dstDir, "agent-base.erofs")
	if ok, err := verifyFileSHA256(dst, expected); err == nil && ok {
		m.markReady(dst)
		return dst, nil
	}

	var sources []string
	if sourceDir != "" {
		sources = append(sources, filepath.Join(sourceDir, "agent-base.erofs"))
	}
	if exeDir != "" {
		sources = append(sources, filepath.Join(exeDir, "..", "images", "agent-base.erofs"))
	}
	if home, err := os.UserHomeDir(); err == nil {
		sources = append(sources, filepath.Join(home, ".cache", "vesper", "images", "agent-base.erofs"))
	}
	for _, src := range sources {
		if ok, err := verifyFileSHA256(src, expected); err == nil && ok {
			if err := copyFileAtomic(src, dst, m); err != nil {
				return fail(fmt.Errorf("copy rootfs from %s: %w", src, err))
			}
			m.markReady(dst)
			return dst, nil
		}
	}

	dlURL := m.DownloadURL
	if dlURL == "" {
		dlURL = strings.TrimSpace(os.Getenv("VESPER_ROOTFS_URL"))
	}
	if dlURL == "" {
		return fail(errors.New("agent-base.erofs not found locally and VESPER_ROOTFS_URL is not set"))
	}
	if err := m.downloadWithResume(ctx, dlURL, dst, expected); err != nil {
		return fail(err)
	}
	m.markReady(dst)
	return dst, nil
}

func (m *ImageManager) markReady(p string) {
	var sz int64
	if st, err := os.Stat(p); err == nil {
		sz = st.Size()
	}
	m.setStatus(func(s *RootfsStatus) {
		s.State = "ready"
		s.Path = p
		s.DownloadedBytes = sz
		s.TotalBytes = sz
		s.Error = ""
	})
}

func (m *ImageManager) downloadWithResume(ctx context.Context, rawURL, dst, expectedSHA string) error {
	part := dst + ".part"
	var offset int64
	if st, err := os.Stat(part); err == nil && !st.IsDir() {
		offset = st.Size()
	}

	m.setStatus(func(s *RootfsStatus) {
		s.State = "downloading"
		s.DownloadedBytes = offset
	})

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return err
	}
	if offset > 0 {
		req.Header.Set("Range", "bytes="+strconv.FormatInt(offset, 10)+"-")
	}

	client := m.HTTPClient
	if client == nil {
		client = http.DefaultClient
	}
	res, err := client.Do(req)
	if err != nil {
		return err
	}
	defer res.Body.Close()

	// Reset partial file if server ignores Range or reports range unsatisfied.
	if res.StatusCode == http.StatusRequestedRangeNotSatisfiable {
		_ = os.Remove(part)
		return m.downloadWithResume(ctx, rawURL, dst, expectedSHA)
	}
	if res.StatusCode != http.StatusOK && res.StatusCode != http.StatusPartialContent {
		return fmt.Errorf("download rootfs %s: HTTP %d", rawURL, res.StatusCode)
	}

	appendMode := res.StatusCode == http.StatusPartialContent && offset > 0
	if !appendMode {
		offset = 0
	}
	total := res.ContentLength
	if total >= 0 && appendMode {
		total += offset
	}
	m.setStatus(func(s *RootfsStatus) {
		s.DownloadedBytes = offset
		s.TotalBytes = total
	})

	flags := os.O_CREATE | os.O_WRONLY
	if appendMode {
		flags |= os.O_APPEND
	} else {
		flags |= os.O_TRUNC
	}
	f, err := os.OpenFile(part, flags, 0o644)
	if err != nil {
		return err
	}

	buf := make([]byte, 256<<10)
	cur := offset
	for {
		n, rerr := res.Body.Read(buf)
		if n > 0 {
			if _, werr := f.Write(buf[:n]); werr != nil {
				_ = f.Close()
				return werr
			}
			cur += int64(n)
			m.setStatus(func(s *RootfsStatus) {
				s.DownloadedBytes = cur
			})
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			_ = f.Close()
			return rerr
		}
	}
	if err := f.Close(); err != nil {
		return err
	}

	ok, verr := verifyFileSHA256(part, expectedSHA)
	if verr != nil || !ok {
		_ = os.Remove(part)
		if verr != nil {
			return fmt.Errorf("verify downloaded rootfs: %w", verr)
		}
		return fmt.Errorf("downloaded rootfs sha256 mismatch (want %s)", expectedSHA)
	}
	return os.Rename(part, dst)
}

func verifyFileSHA256(path, wantHex string) (bool, error) {
	st, err := os.Stat(path)
	if err != nil || st.IsDir() || st.Size() == 0 {
		if err == nil {
			return false, errors.New("empty file")
		}
		return false, err
	}
	if wantHex == "" {
		return true, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return false, err
	}
	got := hex.EncodeToString(h.Sum(nil))
	return strings.EqualFold(got, wantHex), nil
}

func copyFileAtomic(src, dst string, mgr *ImageManager) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	var total int64
	if st, err := in.Stat(); err == nil {
		total = st.Size()
	}
	part := dst + ".part"
	if runtime.GOOS == "darwin" {
		_ = os.Remove(part)
		if exec.Command("cp", "-c", src, part).Run() == nil {
			_ = os.Chmod(part, 0o644)
			if mgr != nil {
				mgr.setStatus(func(s *RootfsStatus) {
					s.State = "downloading"
					s.TotalBytes = total
					s.DownloadedBytes = total
				})
			}
			return os.Rename(part, dst)
		}
		_ = os.Remove(part)
	}
	out, err := os.OpenFile(part, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if mgr != nil {
		mgr.setStatus(func(s *RootfsStatus) {
			s.State = "downloading"
			s.TotalBytes = total
			s.DownloadedBytes = 0
		})
	}
	buf := make([]byte, 512<<10)
	var copied int64
	for {
		n, rerr := in.Read(buf)
		if n > 0 {
			if _, werr := out.Write(buf[:n]); werr != nil {
				_ = out.Close()
				_ = os.Remove(part)
				return werr
			}
			copied += int64(n)
			if mgr != nil {
				mgr.setStatus(func(s *RootfsStatus) { s.DownloadedBytes = copied })
			}
		}
		if rerr == io.EOF {
			break
		}
		if rerr != nil {
			_ = out.Close()
			_ = os.Remove(part)
			return rerr
		}
	}
	if err := out.Close(); err != nil {
		_ = os.Remove(part)
		return err
	}
	return os.Rename(part, dst)
}
