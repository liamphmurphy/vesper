// Package macclient is the Linux-guest side of the mac API (guestproto/mac.go):
// it mirrors a git checkout into the run's macOS guest VM, runs commands
// there, and brings files back. cmd/vesper-mac wraps it as `mac`.
package macclient

import (
	"archive/tar"
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"net/http"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

// ErrNotEnabled means this Vesper has no macOS guests (no golden image).
var ErrNotEnabled = errors.New("macOS guest VMs aren't enabled on this Vesper (the host has no macOS golden image; see docs/dev/microvm-architecture.md)")

// Client talks to the run's broker at BaseURL.
type Client struct {
	BaseURL string
	HTTP    *http.Client
	// Status receives progress lines (waiting for a slot, booting).
	Status io.Writer
}

func (c *Client) http() *http.Client {
	if c.HTTP != nil {
		return c.HTTP
	}
	return http.DefaultClient
}

func (c *Client) post(ctx context.Context, p, contentType string, body io.Reader) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.BaseURL, "/")+p, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", contentType)
	res, err := c.http().Do(req)
	if err != nil {
		return nil, err
	}
	if res.StatusCode == http.StatusNotFound {
		res.Body.Close()
		return nil, ErrNotEnabled
	}
	if res.StatusCode/100 != 2 {
		defer res.Body.Close()
		msg, _ := io.ReadAll(io.LimitReader(res.Body, 8<<10))
		return nil, fmt.Errorf("%s: %s", res.Status, strings.TrimSpace(string(msg)))
	}
	return res, nil
}

func (c *Client) postJSON(ctx context.Context, p string, v any) (*http.Response, error) {
	b, err := json.Marshal(v)
	if err != nil {
		return nil, err
	}
	return c.post(ctx, p, "application/json", bytes.NewReader(b))
}

// Start boots the run's macOS VM if it isn't up, reporting progress to Status.
func (c *Client) Start(ctx context.Context) error {
	res, err := c.post(ctx, guestproto.MacPathStart, "application/json", nil)
	if err != nil {
		return err
	}
	defer res.Body.Close()
	sc := bufio.NewScanner(res.Body)
	for sc.Scan() {
		var st guestproto.MacStatus
		if err := json.Unmarshal(sc.Bytes(), &st); err != nil {
			return fmt.Errorf("bad status line %q: %w", sc.Text(), err)
		}
		switch st.Status {
		case "ready":
			return nil
		case "error":
			return errors.New(st.Message)
		default:
			if c.Status != nil && st.Message != "" {
				fmt.Fprintf(c.Status, "mac: %s\n", st.Message)
			}
		}
	}
	if err := sc.Err(); err != nil {
		return err
	}
	return errors.New("the broker ended the start without saying the VM is ready")
}

// ListFiles is the manifest of the git checkout at root: its tracked files and
// the untracked ones git doesn't ignore, with paths relative to workspace
// (which must contain root).
func ListFiles(ctx context.Context, workspace, root string) (guestproto.MacManifest, error) {
	relRoot, err := relSlash(workspace, root)
	if err != nil {
		return guestproto.MacManifest{}, err
	}
	cmd := exec.CommandContext(ctx, "git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	out, err := cmd.Output()
	if err != nil {
		return guestproto.MacManifest{}, fmt.Errorf("git ls-files in %s: %w: %s", root, err, strings.TrimSpace(stderr.String()))
	}
	m := guestproto.MacManifest{Root: relRoot}
	for _, name := range strings.Split(string(out), "\x00") {
		if name == "" {
			continue
		}
		st, err := os.Lstat(filepath.Join(root, name))
		if err != nil {
			// Tracked but deleted in the work tree: it isn't there to send.
			if errors.Is(err, fs.ErrNotExist) {
				continue
			}
			return guestproto.MacManifest{}, err
		}
		// Submodules show up as directories; they're checkouts of their own.
		if !st.Mode().IsRegular() && st.Mode()&fs.ModeSymlink == 0 {
			continue
		}
		m.Files = append(m.Files, guestproto.MacFile{
			Path:    path.Join(relRoot, filepath.ToSlash(name)),
			Size:    st.Size(),
			Mode:    uint32(st.Mode()),
			MtimeNS: st.ModTime().UnixNano(),
		})
	}
	return m, nil
}

// Sync sends the files of m that the macOS copy lacks or has stale, and
// deletes those it has that m (under m.Root) no longer lists. It returns how
// many files it sent.
func (c *Client) Sync(ctx context.Context, workspace string, m guestproto.MacManifest) (int, error) {
	res, err := c.postJSON(ctx, guestproto.MacPathPlan, m)
	if err != nil {
		return 0, fmt.Errorf("plan sync: %w", err)
	}
	var plan guestproto.MacPlanResp
	err = json.NewDecoder(res.Body).Decode(&plan)
	res.Body.Close()
	if err != nil {
		return 0, fmt.Errorf("plan sync: %w", err)
	}

	pr, pw := io.Pipe()
	go func() {
		pw.CloseWithError(writeUpload(pw, workspace, m, plan.Need))
	}()
	res, err = c.post(ctx, guestproto.MacPathUpload, "application/octet-stream", pr)
	_ = pr.Close()
	if err != nil {
		return 0, fmt.Errorf("upload: %w", err)
	}
	res.Body.Close()
	return len(plan.Need), nil
}

func writeUpload(w io.Writer, workspace string, m guestproto.MacManifest, need []string) error {
	if err := guestproto.WriteMacManifest(w, m); err != nil {
		return err
	}
	tw := tar.NewWriter(w)
	for _, rel := range need {
		if err := addToTar(tw, workspace, rel); err != nil {
			return err
		}
	}
	return tw.Close()
}

func addToTar(tw *tar.Writer, workspace, rel string) error {
	full := filepath.Join(workspace, filepath.FromSlash(rel))
	st, err := os.Lstat(full)
	if err != nil {
		return err
	}
	var link string
	if st.Mode()&fs.ModeSymlink != 0 {
		if link, err = os.Readlink(full); err != nil {
			return err
		}
	}
	hdr, err := tar.FileInfoHeader(st, link)
	if err != nil {
		return err
	}
	hdr.Name = rel
	hdr.Uid, hdr.Gid, hdr.Uname, hdr.Gname = 0, 0, "", ""
	hdr.Format = tar.FormatPAX
	if err := tw.WriteHeader(hdr); err != nil {
		return err
	}
	if !st.Mode().IsRegular() {
		return nil
	}
	f, err := os.Open(full)
	if err != nil {
		return err
	}
	defer f.Close()
	// The file may have grown since the manifest; tar wants the header's size.
	_, err = io.CopyN(tw, f, hdr.Size)
	return err
}

// Exec runs req in the macOS VM, streaming its output, and returns its exit code.
func (c *Client) Exec(ctx context.Context, req guestproto.MacExecReq, stdout, stderr io.Writer) (int, error) {
	res, err := c.postJSON(ctx, guestproto.MacPathExec, req)
	if err != nil {
		return -1, err
	}
	defer res.Body.Close()
	return readExecStream(res.Body, stdout, stderr)
}

// readExecStream copies guestproto stdout/stderr frames until the exit frame.
func readExecStream(r io.Reader, stdout, stderr io.Writer) (int, error) {
	br := bufio.NewReader(r)
	for {
		f, err := guestproto.ReadFrame(br)
		if err != nil {
			if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
				return -1, errors.New("the macOS VM connection ended before the command did")
			}
			return -1, err
		}
		switch f.Type {
		case guestproto.FrameStdout:
			if _, err := stdout.Write(f.Data); err != nil {
				return -1, err
			}
		case guestproto.FrameStderr:
			if _, err := stderr.Write(f.Data); err != nil {
				return -1, err
			}
		case guestproto.FrameExecExit:
			var ex guestproto.ExecExit
			if err := json.Unmarshal(f.Data, &ex); err != nil {
				return -1, err
			}
			if ex.Error != "" {
				return ex.Code, errors.New(ex.Error)
			}
			return ex.Code, nil
		default:
			return -1, fmt.Errorf("unexpected frame type %d", f.Type)
		}
	}
}

// Pull copies paths (relative to workspace) from the macOS VM into workspace,
// overwriting what's there.
func (c *Client) Pull(ctx context.Context, workspace string, paths []string, stderr io.Writer) error {
	res, err := c.postJSON(ctx, guestproto.MacPathPull, guestproto.MacPullReq{Paths: paths})
	if err != nil {
		return err
	}
	defer res.Body.Close()
	pr, pw := io.Pipe()
	extracted := make(chan error, 1)
	go func() {
		err := extractTar(pr, workspace)
		// Unblock the frame reader if extraction stopped early.
		_, _ = io.Copy(io.Discard, pr)
		extracted <- err
	}()
	code, err := readExecStream(res.Body, pw, stderr)
	_ = pw.Close()
	xerr := <-extracted
	if err != nil {
		return err
	}
	if code != 0 {
		return fmt.Errorf("tar in the macOS VM exited %d", code)
	}
	return xerr
}

// extractTar writes regular files, directories and symlinks from r under
// workspace. os.Root keeps every write inside it, symlinks included.
func extractTar(r io.Reader, workspace string) error {
	root, err := os.OpenRoot(workspace)
	if err != nil {
		return err
	}
	defer root.Close()
	tr := tar.NewReader(r)
	for {
		hdr, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return nil
		}
		if err != nil {
			return err
		}
		name, err := guestproto.CleanMacPath(strings.TrimPrefix(hdr.Name, "./"), true)
		if err != nil {
			return err
		}
		if name == "" {
			continue
		}
		mode := fs.FileMode(hdr.Mode).Perm()
		switch hdr.Typeflag {
		case tar.TypeDir:
			if err := root.MkdirAll(name, 0o755); err != nil {
				return err
			}
		case tar.TypeReg:
			if dir := path.Dir(name); dir != "." {
				if err := root.MkdirAll(dir, 0o755); err != nil {
					return err
				}
			}
			_ = root.Remove(name)
			f, err := root.OpenFile(name, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, mode|0o200)
			if err != nil {
				return err
			}
			_, cerr := io.Copy(f, tr)
			if err := f.Close(); cerr == nil {
				cerr = err
			}
			if cerr != nil {
				return cerr
			}
		case tar.TypeSymlink:
			if dir := path.Dir(name); dir != "." {
				if err := root.MkdirAll(dir, 0o755); err != nil {
					return err
				}
			}
			_ = root.Remove(name)
			if err := root.Symlink(hdr.Linkname, name); err != nil {
				return err
			}
		default:
			// Devices, hard links and the like aren't build outputs.
		}
	}
}

func relSlash(base, target string) (string, error) {
	rel, err := filepath.Rel(base, target)
	if err != nil {
		return "", err
	}
	rel = filepath.ToSlash(rel)
	if rel == ".." || strings.HasPrefix(rel, "../") {
		return "", fmt.Errorf("%s isn't inside the workspace %s", target, base)
	}
	if rel == "." {
		return "", nil
	}
	return rel, nil
}

// RelDir is dir relative to workspace, slash-separated, "" for the root.
func RelDir(workspace, dir string) (string, error) { return relSlash(workspace, dir) }
