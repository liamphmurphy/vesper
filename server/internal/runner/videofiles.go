package runner

import (
	"archive/tar"
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/google/uuid"
)

// A chat video's renderer reports through files in the job's directory (see
// runs/chat_videos.go). The runner reads them while the turn runs, so they are
// untrusted the same way the outbox is: only regular files, never through a
// link, within these limits.
const (
	videoMaxProgressBytes = 64 << 10
	videoMaxFrameBytes    = 2 << 20
	videoMaxStillBytes    = 8 << 20
	videoMaxScriptBytes   = 1 << 20
	// VideoMaxOutputBytes caps a finished video.
	VideoMaxOutputBytes = 512 << 20
)

// VideoFilesRequest names what to read for one job: Dir is the job's
// directory and Script the renderer, both relative to the workspace. Known
// maps each path already copied to its stamp; an unchanged file is skipped.
type VideoFilesRequest struct {
	Dir    string
	Script string
	Known  map[string]string
}

// VideoFile is one changed file: Path is relative to the workspace, Stamp
// identifies this version of it (size and modification time).
type VideoFile struct {
	Path  string
	Stamp string
	Data  []byte
}

// videoFileLimit is the most a candidate file may hold, by its path in the
// job's directory ("" for the script).
func videoFileLimit(rel string) int64 {
	switch {
	case rel == "":
		return videoMaxScriptBytes
	case rel == "progress.json":
		return videoMaxProgressBytes
	case strings.HasPrefix(rel, "stills/"):
		return videoMaxStillBytes
	default:
		return videoMaxFrameBytes
	}
}

// videoCandidate reports whether rel (inside the job's directory) is a file
// the runner copies.
func videoCandidate(rel string) bool {
	switch rel {
	case "progress.json", "preview.jpg", "poster.jpg":
		return true
	}
	dir, name := path.Split(rel)
	return (dir == "stills/" || dir == "strip/") && name != "" && !strings.HasPrefix(name, ".")
}

// ReadVideoFiles reads the job's changed files on the host.
func (l *Fake) ReadVideoFiles(_ context.Context, runID string, req VideoFilesRequest) ([]VideoFile, error) {
	root, err := os.OpenRoot(l.WorkspaceDir(runID))
	if err != nil {
		return nil, err
	}
	defer root.Close()
	var out []VideoFile
	read := func(p string, limit int64) error {
		fi, err := root.Lstat(p)
		if errors.Is(err, fs.ErrNotExist) {
			return nil
		}
		if err != nil || !fi.Mode().IsRegular() || fi.Size() > limit {
			return nil // a link, directory or oversized file is left alone
		}
		stamp := fmt.Sprintf("%d:%d", fi.Size(), fi.ModTime().UnixNano())
		if req.Known[p] == stamp {
			return nil
		}
		f, err := root.Open(p)
		if err != nil {
			return nil
		}
		defer f.Close()
		data, err := io.ReadAll(io.LimitReader(f, limit+1))
		if err != nil || int64(len(data)) > limit {
			return nil
		}
		out = append(out, VideoFile{Path: p, Stamp: stamp, Data: data})
		return nil
	}
	if req.Script != "" {
		if err := read(req.Script, videoFileLimit("")); err != nil {
			return nil, err
		}
	}
	if fi, err := root.Lstat(req.Dir); err != nil || !fi.IsDir() {
		return out, nil // not started yet (or not a directory)
	}
	for _, name := range []string{"progress.json", "preview.jpg", "poster.jpg"} {
		if err := read(path.Join(req.Dir, name), videoFileLimit(name)); err != nil {
			return nil, err
		}
	}
	for _, sub := range []string{"stills", "strip"} {
		d, err := root.Open(path.Join(req.Dir, sub))
		if err != nil {
			continue
		}
		fi, err := d.Stat()
		if err != nil || !fi.IsDir() {
			d.Close()
			continue
		}
		entries, err := d.ReadDir(-1)
		d.Close()
		if err != nil {
			continue
		}
		sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
		for _, e := range entries {
			rel := sub + "/" + e.Name()
			if !videoCandidate(rel) || !e.Type().IsRegular() {
				continue
			}
			if err := read(path.Join(req.Dir, rel), videoFileLimit(rel)); err != nil {
				return nil, err
			}
		}
	}
	return out, nil
}

// OpenWorkspaceFile opens one regular file of the workspace for reading,
// with its size; fs.ErrNotExist if it isn't there.
func (l *Fake) OpenWorkspaceFile(_ context.Context, runID, rel string, limit int64) (io.ReadCloser, int64, error) {
	root, err := os.OpenRoot(l.WorkspaceDir(runID))
	if err != nil {
		return nil, 0, err
	}
	defer root.Close()
	fi, err := root.Lstat(rel)
	if err != nil {
		return nil, 0, err
	}
	if !fi.Mode().IsRegular() {
		return nil, 0, fmt.Errorf("%s isn't a regular file", rel)
	}
	if fi.Size() > limit {
		return nil, 0, fmt.Errorf("%s is larger than %d MiB", rel, limit>>20)
	}
	f, err := root.Open(rel)
	if err != nil {
		return nil, 0, err
	}
	return f, fi.Size(), nil
}

// videoFilesScript lists a job's files inside a start-only backend (the microVM),
// with the same rules as Fake.ReadVideoFiles in the shell's own tests (which
// don't follow links): "$1" is the job's directory, "$2" the script ("" for
// none), then known stamps as path=stamp. It tars the changed files and
// prints "stamp<TAB>path<TAB>stamp" on stderr for each.
var videoFilesScript = `dir=$1; script=$2; shift 2
known=$(printf '%s\n' "$@")
root=$(pwd -P)
emit() {
  p=$1; limit=$2
  [ -f "$p" ] && [ ! -L "$p" ] || return 0
  case "$(realpath "$p" 2>/dev/null)" in "$root"/*) ;; *) return 0 ;; esac
  size=$(wc -c < "$p") || return 0
  [ "$size" -le "$limit" ] || return 0
  stamp="$size:$(stat -c %Y "$p" 2>/dev/null)"
  if printf '%s\n' "$known" | grep -qxF -- "$p=$stamp"; then return 0; fi
  printf 'stamp\t%s\t%s\n' "$p" "$stamp" >&2
  files="$files
$p"
}
files=
[ -n "$script" ] && emit "$script" ` + strconv.Itoa(videoMaxScriptBytes) + `
linked=0
d=$dir
while [ "$d" != "." ] && [ "$d" != "/" ]; do [ -L "$d" ] && linked=1; d=$(dirname "$d"); done
if [ "$linked" = 0 ] && [ -d "$dir" ]; then
  emit "$dir/progress.json" ` + strconv.Itoa(videoMaxProgressBytes) + `
  emit "$dir/preview.jpg" ` + strconv.Itoa(videoMaxFrameBytes) + `
  emit "$dir/poster.jpg" ` + strconv.Itoa(videoMaxFrameBytes) + `
  for sub in stills strip; do
    [ -d "$dir/$sub" ] && [ ! -L "$dir/$sub" ] || continue
    if [ "$sub" = stills ]; then lim=` + strconv.Itoa(videoMaxStillBytes) + `; else lim=` + strconv.Itoa(videoMaxFrameBytes) + `; fi
    for f in "$dir/$sub"/*; do
      case "${f##*/}" in .*|'*') continue ;; esac
      emit "$f" "$lim"
    done
  done
fi
[ -n "$files" ] || exit 0
printf '%s\n' "$files" | sed '/^$/d' | tar -cf - -T -
`

func readVideoFilesExec(ctx context.Context, b Backend, runID string, req VideoFilesRequest) ([]VideoFile, error) {
	argv := []string{"sh", "-c", videoFilesScript, "video-files", req.Dir, req.Script}
	keys := make([]string, 0, len(req.Known))
	for p := range req.Known {
		keys = append(keys, p)
	}
	sort.Strings(keys)
	for _, p := range keys {
		argv = append(argv, p+"="+req.Known[p])
	}
	out, errOut, err := outboxExec(ctx, b, runID, argv...)
	if err != nil {
		return nil, err
	}
	stamps := map[string]string{}
	sc := bufio.NewScanner(strings.NewReader(string(errOut)))
	for sc.Scan() {
		if parts := strings.SplitN(sc.Text(), "\t", 3); len(parts) == 3 && parts[0] == "stamp" {
			stamps[path.Clean(parts[1])] = parts[2]
		}
	}
	return parseVideoFilesTar(strings.NewReader(string(out)), req, stamps)
}

// parseVideoFilesTar reads the regular files the script named, checking each
// header against what was asked for again.
func parseVideoFilesTar(r io.Reader, req VideoFilesRequest, stamps map[string]string) ([]VideoFile, error) {
	var out []VideoFile
	tr := tar.NewReader(r)
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			return out, nil
		}
		if err != nil {
			return nil, err
		}
		name := path.Clean(h.Name)
		var limit int64
		switch {
		case req.Script != "" && name == path.Clean(req.Script):
			limit = videoFileLimit("")
		case strings.HasPrefix(name, path.Clean(req.Dir)+"/") && videoCandidate(strings.TrimPrefix(name, path.Clean(req.Dir)+"/")):
			limit = videoFileLimit(strings.TrimPrefix(name, path.Clean(req.Dir)+"/"))
		default:
			continue
		}
		if h.Typeflag != tar.TypeReg || h.Size > limit {
			continue
		}
		data, err := io.ReadAll(io.LimitReader(tr, limit+1))
		if err != nil {
			return nil, err
		}
		out = append(out, VideoFile{Path: name, Stamp: stamps[name], Data: data})
	}
}

// workspaceFileScript prints a regular file's size on its own line, then the file.
const workspaceFileScript = `p=$1
[ -f "$p" ] && [ ! -L "$p" ] || { echo "missing" >&2; exit 3; }
root=$(pwd -P)
case "$(realpath "$p")" in "$root"/*) ;; *) echo "outside the workspace" >&2; exit 4 ;; esac
wc -c < "$p"
exec cat -- "$p"
`

// execFile is a file streamed out of a start-only backend.
type execFile struct {
	r    *bufio.Reader
	proc Process
	once sync.Once
}

func (f *execFile) Read(p []byte) (int, error) { return f.r.Read(p) }

func (f *execFile) Close() error {
	f.once.Do(func() {
		_ = f.proc.Kill()
		_, _ = f.proc.Wait()
		if c, ok := f.proc.(io.Closer); ok {
			_ = c.Close()
		}
	})
	return nil
}

func openWorkspaceFileExec(ctx context.Context, b Backend, runID, rel string, limit int64) (io.ReadCloser, int64, error) {
	proc, err := b.Start(ctx, runID, ExecSpec{Name: "lazyagents-file-" + runID + "-" + uuid.NewString()[:8], Argv: []string{"sh", "-c", workspaceFileScript, "workspace-file", rel}})
	if err != nil {
		return nil, 0, err
	}
	go func() { _, _ = io.Copy(io.Discard, io.LimitReader(proc.Stderr(), 1<<20)) }()
	f := &execFile{r: bufio.NewReader(proc.Stdout()), proc: proc}
	line, err := f.r.ReadString('\n')
	if err != nil {
		f.Close()
		code, _ := proc.Wait()
		if code == 3 {
			return nil, 0, fs.ErrNotExist
		}
		return nil, 0, fmt.Errorf("%s couldn't be read (exit %d)", rel, code)
	}
	size, err := strconv.ParseInt(strings.TrimSpace(line), 10, 64)
	if err != nil || size < 0 {
		f.Close()
		return nil, 0, fmt.Errorf("%s couldn't be read", rel)
	}
	if size > limit {
		f.Close()
		return nil, 0, fmt.Errorf("%s is larger than %d MiB", rel, limit>>20)
	}
	return f, size, nil
}
