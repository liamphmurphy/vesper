package runner

import (
	"archive/tar"
	"bufio"
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"

	"github.com/google/uuid"
)

// The outbox is where an image-generating chat copies the pictures it made
// (.lazyagents/outbox in the run's workspace). After each turn the runner
// takes what it finds there, whatever the agent wrote: only regular files,
// within these limits, and the caller sniffs their content.
const (
	outboxDir          = ".lazyagents/outbox"
	OutboxMaxFiles     = 8
	OutboxMaxFileBytes = 20 << 20
)

// OutboxFile is one regular file found directly in a run's outbox.
type OutboxFile struct {
	Name string
	Data []byte
}

// ReadOutbox reads the regular files directly in the outbox, by name, up to
// OutboxMaxFiles of at most OutboxMaxFileBytes each. Anything else (links,
// directories, extra or oversized files) is left alone and described in
// skipped. The agent has finished by now, but its files are still untrusted:
// nothing is followed out of the workspace.
func (l *Fake) ReadOutbox(_ context.Context, runID string) (files []OutboxFile, skipped []string, err error) {
	root, err := os.OpenRoot(l.WorkspaceDir(runID))
	if err != nil {
		return nil, nil, err
	}
	defer root.Close()
	dir, err := root.Open(outboxDir)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil, nil
	}
	if err != nil {
		return nil, nil, err
	}
	entries, err := dir.ReadDir(-1)
	dir.Close()
	if err != nil {
		return nil, nil, err
	}
	sort.Slice(entries, func(i, j int) bool { return entries[i].Name() < entries[j].Name() })
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, ".") {
			continue
		}
		if !e.Type().IsRegular() { // DirEntry types come from lstat: a link is not regular
			skipped = append(skipped, name+": not a regular file")
			continue
		}
		if len(files) >= OutboxMaxFiles {
			skipped = append(skipped, fmt.Sprintf("%s: more than %d files in one turn", name, OutboxMaxFiles))
			continue
		}
		f, err := root.Open(path.Join(outboxDir, name))
		if err != nil {
			skipped = append(skipped, name+": "+err.Error())
			continue
		}
		data, err := io.ReadAll(io.LimitReader(f, OutboxMaxFileBytes+1))
		f.Close()
		switch {
		case err != nil:
			skipped = append(skipped, name+": "+err.Error())
		case len(data) > OutboxMaxFileBytes:
			skipped = append(skipped, fmt.Sprintf("%s: larger than %d MiB", name, OutboxMaxFileBytes>>20))
		default:
			files = append(files, OutboxFile{Name: name, Data: data})
		}
	}
	return files, skipped, nil
}

// RemoveOutbox deletes the named files from the outbox (those just harvested).
func (l *Fake) RemoveOutbox(_ context.Context, runID string, names []string) error {
	root, err := os.OpenRoot(l.WorkspaceDir(runID))
	if err != nil {
		return err
	}
	defer root.Close()
	var errs []error
	for _, n := range names {
		if n == "" || strings.Contains(n, "/") {
			continue
		}
		if err := root.Remove(path.Join(outboxDir, n)); err != nil && !errors.Is(err, os.ErrNotExist) {
			errs = append(errs, err)
		}
	}
	return errors.Join(errs...)
}

// outboxScript runs inside a backend that can only start processes (the microVM):
// it tars the outbox's regular files, applying the same limits as ReadOutbox
// with the shell's own tests (which don't follow links), and reports what it
// skipped on stderr as "skip<TAB>name<TAB>reason". The tar's headers are
// checked again by parseOutboxTar.
var outboxScript = `if [ -L .lazyagents ] || [ -L ` + outboxDir + ` ]; then exit 0; fi
cd ` + outboxDir + ` 2>/dev/null || exit 0
n=0
set --
for f in ./*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  name=${f#./}
  if [ -L "$f" ] || [ ! -f "$f" ]; then printf 'skip\t%s\tnot a regular file\n' "$name" >&2; continue; fi
  if [ "$n" -ge ` + strconv.Itoa(OutboxMaxFiles) + ` ]; then printf 'skip\t%s\tmore than ` + strconv.Itoa(OutboxMaxFiles) + ` files in one turn\n' "$name" >&2; continue; fi
  size=$(wc -c < "$f")
  if [ "$size" -gt ` + strconv.Itoa(OutboxMaxFileBytes) + ` ]; then printf 'skip\t%s\tlarger than ` + strconv.Itoa(OutboxMaxFileBytes>>20) + ` MiB\n' "$name" >&2; continue; fi
  n=$((n + 1))
  set -- "$@" "$f"
done
[ "$#" -gt 0 ] || exit 0
exec tar -cf - -- "$@"
`

// collectScript copies the images a Codex thread saved ($1 is the thread id)
// from Codex's own folder into the outbox, under the limits ReadOutbox applies:
// regular image files only, no links followed at either end, nothing
// overwritten. Codex saves every image it makes to
// $CODEX_HOME/generated_images/<thread id>/ (codex-cli 0.167.0), so this hands
// the image over without the step's model having to phrase a copy the policy
// hook accepts.
var collectScript = `thread=$1
case "$thread" in ""|.*|*/*) exit 2 ;; esac
src=${CODEX_HOME:-$HOME/.codex}/generated_images
if [ -L "$src" ] || [ ! -d "$src" ] || [ -L "$src/$thread" ] || [ ! -d "$src/$thread" ]; then exit 0; fi
if [ -L .lazyagents ] || [ -L ` + outboxDir + ` ]; then exit 0; fi
mkdir -p ` + outboxDir + ` || exit 1
n=0
for f in "$src/$thread"/*; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  name=${f##*/}
  case "$name" in .*|-*) continue ;; esac
  case "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" in *.png|*.jpg|*.jpeg|*.webp|*.gif) ;; *) continue ;; esac
  [ "$n" -lt ` + strconv.Itoa(OutboxMaxFiles) + ` ] || break
  [ "$(wc -c < "$f")" -le ` + strconv.Itoa(OutboxMaxFileBytes) + ` ] || continue
  [ -e "` + outboxDir + `/$name" ] && continue
  cp -- "$f" "` + outboxDir + `/$name" || exit 1
  n=$((n + 1))
done
`

// codexThreadID matches what Codex reports as a thread id, so it can name a
// directory without escaping it.
var codexThreadID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)

// collectGeneratedImages runs collectScript in the run's workspace, through
// the backend so it sees the same home the step's Codex wrote to.
func collectGeneratedImages(ctx context.Context, b Backend, runID, thread string) error {
	if !codexThreadID.MatchString(thread) {
		return fmt.Errorf("runner: bad Codex thread id %q", thread)
	}
	_, _, err := outboxExec(ctx, b, runID, "sh", "-c", collectScript, "sh", thread)
	return err
}

// parseOutboxTar reads the regular files directly named in the script's tar.
func parseOutboxTar(r io.Reader) ([]OutboxFile, error) {
	var out []OutboxFile
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
		if h.Typeflag != tar.TypeReg || h.Size > OutboxMaxFileBytes || name != path.Base(name) || strings.HasPrefix(name, ".") || len(out) >= OutboxMaxFiles {
			continue
		}
		data, err := io.ReadAll(io.LimitReader(tr, OutboxMaxFileBytes+1))
		if err != nil {
			return nil, err
		}
		out = append(out, OutboxFile{Name: name, Data: data})
	}
}

// outboxExec runs argv in the run's workspace on a start-only backend and returns
// its stdout and stderr.
func outboxExec(ctx context.Context, b Backend, runID string, argv ...string) (stdout, stderr []byte, err error) {
	proc, err := b.Start(ctx, runID, ExecSpec{Name: "lazyagents-outbox-" + runID + "-" + uuid.NewString()[:8], Argv: argv})
	if err != nil {
		return nil, nil, err
	}
	// Bounded: the script already limits what it emits, this stops anything else.
	const limit = OutboxMaxFiles*(OutboxMaxFileBytes+1024) + 1<<20
	var wg sync.WaitGroup
	var outB, errB []byte
	wg.Add(2)
	go func() { defer wg.Done(); outB, _ = io.ReadAll(io.LimitReader(proc.Stdout(), limit)) }()
	go func() { defer wg.Done(); errB, _ = io.ReadAll(io.LimitReader(proc.Stderr(), 1<<20)) }()
	wg.Wait()
	code, err := proc.Wait()
	if c, ok := proc.(io.Closer); ok {
		_ = c.Close()
	}
	if err == nil && code != 0 {
		err = fmt.Errorf("exit %d: %s", code, strings.TrimSpace(string(errB)))
	}
	return outB, errB, err
}

func readOutboxExec(ctx context.Context, b Backend, runID string) ([]OutboxFile, []string, error) {
	out, errOut, err := outboxExec(ctx, b, runID, "sh", "-c", outboxScript)
	if err != nil {
		return nil, nil, err
	}
	var skipped []string
	sc := bufio.NewScanner(bytes.NewReader(errOut))
	for sc.Scan() {
		if parts := strings.SplitN(sc.Text(), "\t", 3); len(parts) == 3 && parts[0] == "skip" {
			skipped = append(skipped, parts[1]+": "+parts[2])
		}
	}
	files, err := parseOutboxTar(bytes.NewReader(out))
	return files, skipped, err
}

func removeOutboxExec(ctx context.Context, b Backend, runID string, names []string) error {
	var safe []string
	for _, n := range names {
		if n != "" && !strings.Contains(n, "/") {
			safe = append(safe, n)
		}
	}
	if len(safe) == 0 {
		return nil
	}
	argv := append([]string{"sh", "-c", `cd ` + outboxDir + ` && for f in "$@"; do rm -f -- "./$f"; done`, "sh"}, safe...)
	_, _, err := outboxExec(ctx, b, runID, argv...)
	return err
}

// collectAntigravityScript copies the images an Antigravity conversation saved
// into the outbox, with collectScript's limits. $1 is the conversation id and
// the rest are image paths its tools said they saved. Antigravity keeps a
// conversation's artifacts under its own home (~/.gemini/…/<conversation id>/;
// the exact layout isn't documented), so both ways in are confined to that
// folder: a path must lie under $HOME/.gemini with no ".." and the conversation
// directories are found by name inside it. Links are never followed. Files are
// named agy-<conversation>-<name> so two jobs' "image.png" don't collide.
var collectAntigravityScript = `conv=$1; shift
case "$conv" in ""|.*|*/*) exit 2 ;; esac
root=${HOME:-/nonexistent}/.gemini
if [ -L "$root" ] || [ ! -d "$root" ]; then exit 0; fi
if [ -L .lazyagents ] || [ -L ` + outboxDir + ` ]; then exit 0; fi
mkdir -p ` + outboxDir + ` || exit 1
n=0
tag=$(printf '%s' "$conv" | cut -c1-8)
take() {
  f=$1
  [ -f "$f" ] && [ ! -L "$f" ] || return 0
  name=${f##*/}
  case "$name" in .*|-*) return 0 ;; esac
  case "$(printf '%s' "$name" | tr 'A-Z' 'a-z')" in *.png|*.jpg|*.jpeg|*.webp|*.gif) ;; *) return 0 ;; esac
  [ "$n" -lt ` + strconv.Itoa(OutboxMaxFiles) + ` ] || return 0
  [ "$(wc -c < "$f")" -le ` + strconv.Itoa(OutboxMaxFileBytes) + ` ] || return 0
  dest=` + outboxDir + `/agy-$tag-$name
  [ -e "$dest" ] && return 0
  cp -- "$f" "$dest" || return 1
  n=$((n + 1))
}
for f in "$@"; do
  case "$f" in "$root"/*) ;; *) continue ;; esac
  case "/$f/" in *"/../"*|*"/./"*) continue ;; esac
  take "$f" || exit 1
done
if [ "$n" -eq 0 ]; then
  for d in $(find "$root" -maxdepth 6 -type d -name "$conv" 2>/dev/null | head -n 4); do
    [ -L "$d" ] && continue
    for f in "$d"/* "$d"/*/*; do take "$f" || exit 1; done
  done
fi
`

// antigravityConversationID matches what agy reports as a conversation id, so
// it can name a directory without escaping it.
var antigravityConversationID = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_-]*$`)

// collectAntigravityImages runs collectAntigravityScript in the run's
// workspace, through the backend so it sees the home the step's agy wrote to.
func collectAntigravityImages(ctx context.Context, b Backend, runID, conversation string, paths []string) error {
	if !antigravityConversationID.MatchString(conversation) {
		return fmt.Errorf("runner: bad Antigravity conversation id %q", conversation)
	}
	argv := append([]string{"sh", "-c", collectAntigravityScript, "sh", conversation}, paths...)
	_, _, err := outboxExec(ctx, b, runID, argv...)
	return err
}
