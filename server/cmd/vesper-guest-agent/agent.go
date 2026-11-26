package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

type execTracker struct {
	mu      sync.RWMutex
	tracked map[int]struct{}
}

func newExecTracker() *execTracker {
	return &execTracker{tracked: make(map[int]struct{})}
}

func (e *execTracker) track(pid int) {
	e.mu.Lock()
	e.tracked[pid] = struct{}{}
	e.mu.Unlock()
}

func (e *execTracker) untrack(pid int) {
	e.mu.Lock()
	delete(e.tracked, pid)
	e.mu.Unlock()
}

func (e *execTracker) isTracked(pid int) bool {
	e.mu.RLock()
	_, ok := e.tracked[pid]
	e.mu.RUnlock()
	return ok
}

type dnsStubConfig struct {
	mu      sync.RWMutex
	aliases map[string]string
}

func newDNSStubConfig() *dnsStubConfig {
	return &dnsStubConfig{aliases: make(map[string]string)}
}

func (d *dnsStubConfig) setAliases(aliases map[string]string) {
	d.mu.Lock()
	defer d.mu.Unlock()
	d.aliases = make(map[string]string, len(aliases))
	for k, v := range aliases {
		d.aliases[strings.ToLower(strings.TrimSuffix(strings.TrimSpace(k), "."))] = v
	}
}

func (d *dnsStubConfig) lookupAlias(name string) (string, bool) {
	norm := strings.ToLower(strings.TrimSuffix(strings.TrimSpace(name), "."))
	d.mu.RLock()
	ip, ok := d.aliases[norm]
	d.mu.RUnlock()
	return ip, ok
}

type agentServer struct {
	log       *slog.Logger
	bootNS    int64
	execs     *execTracker
	dnsStub   *dnsStubConfig
	reqSeq    atomic.Uint64
	shutdown  atomic.Bool
	wg        sync.WaitGroup
	closeOnce sync.Once
	closed    chan struct{}
	// maxAcceptFailures, when positive, makes serve give up after that many
	// Accept errors in a row (see serve).
	maxAcceptFailures int
	// trace logs every request and each exec's lifecycle and connection
	// errors. On in macOS guests, where the log is a file read back through
	// `mac --agent-log`; off in Linux guests, where stderr is the console.
	trace bool
}

// tracef logs at Info when tracing is on.
func (s *agentServer) tracef(msg string, args ...any) {
	if s.trace {
		s.log.Info(msg, args...)
	}
}

func newAgentServer(log *slog.Logger) *agentServer {
	return &agentServer{
		log:     log,
		bootNS:  time.Now().UnixNano(),
		execs:   newExecTracker(),
		dnsStub: newDNSStubConfig(),
		closed:  make(chan struct{}),
	}
}

func (s *agentServer) shutdownRequested() bool { return s.shutdown.Load() }

func (s *agentServer) close() {
	s.closeOnce.Do(func() { close(s.closed) })
}

// acceptBackoff spaces out retries when Accept keeps failing, so a broken
// listener doesn't spin a CPU.
const acceptBackoff = 100 * time.Millisecond

// serve accepts host connections until ctx ends or ln closes. With
// maxAcceptFailures set, that many Accept errors in a row return an error:
// the listener is broken and the agent should exit so its supervisor (launchd
// in a macOS guest) starts a fresh one. As PID 1 in a Linux guest there's no
// supervisor, so there it keeps retrying.
func (s *agentServer) serve(ctx context.Context, ln net.Listener) error {
	failures := 0
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return nil
			}
			failures++
			s.log.Warn("accept failed", "err", err, "in_a_row", failures)
			if s.maxAcceptFailures > 0 && failures >= s.maxAcceptFailures {
				return fmt.Errorf("accept failed %d times in a row: %w", failures, err)
			}
			select {
			case <-ctx.Done():
				return nil
			case <-time.After(acceptBackoff):
			}
			continue
		}
		failures = 0
		s.wg.Add(1)
		go func() {
			defer s.wg.Done()
			defer conn.Close()
			s.handleConn(ctx, conn)
		}()
	}
}

func (s *agentServer) handleConn(ctx context.Context, conn net.Conn) {
	f, err := guestproto.ReadFrame(conn)
	if err != nil {
		return
	}
	if f.Type != guestproto.FrameReq {
		_ = writeRPCError(conn, f.ID, fmt.Sprintf("unexpected initial frame type %d", f.Type))
		return
	}
	var req guestproto.Request
	if err := json.Unmarshal(f.Data, &req); err != nil {
		_ = writeRPCError(conn, f.ID, fmt.Sprintf("invalid request: %v", err))
		return
	}
	s.tracef("request", "op", req.Op)

	switch req.Op {
	case guestproto.OpPing:
		_ = writeRPCOK(conn, f.ID, guestproto.PingResp{Version: agentVersion, BootTimeNS: s.bootNS})
	case guestproto.OpWriteFiles:
		var in guestproto.WriteFilesReq
		if err := json.Unmarshal(req.V, &in); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		if err := writeGuestFiles(in.Files); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		_ = writeRPCOK(conn, f.ID, nil)
	case guestproto.OpStat:
		var in guestproto.StatReq
		if err := json.Unmarshal(req.V, &in); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		resp := statGuestFile(in.Path)
		_ = writeRPCOK(conn, f.ID, resp)
	case guestproto.OpReadFile:
		var in guestproto.ReadFileReq
		if err := json.Unmarshal(req.V, &in); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		s.handleReadFile(conn, f.ID, in)
	case guestproto.OpWalkDir:
		var in guestproto.WalkDirReq
		if err := json.Unmarshal(req.V, &in); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		entries, err := walkGuestDir(in.Root, in.MaxDepth)
		if err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		_ = writeRPCOK(conn, f.ID, guestproto.WalkDirResp{Entries: entries})
	case guestproto.OpUnlinkPaths:
		var in guestproto.UnlinkPathsReq
		if err := json.Unmarshal(req.V, &in); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		if err := unlinkGuestPaths(in.Paths, in.Recursive); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		_ = writeRPCOK(conn, f.ID, nil)
	case guestproto.OpSyncAndDropCaches:
		if err := syncAndDropCaches(); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		_ = writeRPCOK(conn, f.ID, nil)
	case guestproto.OpStartDockerd:
		var in guestproto.StartDockerdReq
		if len(req.V) > 0 {
			_ = json.Unmarshal(req.V, &in)
		}
		if err := ensureDockerd(ctx, s.log, s.execs, in.RegistryMirror); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		_ = writeRPCOK(conn, f.ID, nil)
	case guestproto.OpOpenDockerGuard:
		var in guestproto.DockerGuardReq
		if err := json.Unmarshal(req.V, &in); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		sock, err := openDockerGuard(in.Key)
		if err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		_ = writeRPCOK(conn, f.ID, guestproto.OpenDockerGuardResp{Socket: sock})
	case guestproto.OpCloseDockerGuard:
		var in guestproto.DockerGuardReq
		if err := json.Unmarshal(req.V, &in); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		if err := closeDockerGuard(ctx, in.Key); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		_ = writeRPCOK(conn, f.ID, nil)
	case guestproto.OpStartNixDaemon:
		if err := ensureNixDaemon(ctx, s.execs); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		_ = writeRPCOK(conn, f.ID, nil)
	case guestproto.OpEnsureBridgeAliases:
		var in guestproto.EnsureBridgeAliasesReq
		if err := json.Unmarshal(req.V, &in); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		s.dnsStub.setAliases(in.Aliases)
		_ = writeRPCOK(conn, f.ID, nil)
	case guestproto.OpCheckTCPPort:
		var in guestproto.CheckTCPPortReq
		if err := json.Unmarshal(req.V, &in); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		listening := checkLocalTCPPort(in.Port)
		_ = writeRPCOK(conn, f.ID, guestproto.CheckTCPPortResp{Listening: listening})
	case guestproto.OpShutdown:
		s.shutdown.Store(true)
		_ = syncAndDropCaches()
		_ = writeRPCOK(conn, f.ID, map[string]bool{"ok": true})
		powerOffGuest()
	case guestproto.OpExecStart:
		var in guestproto.ExecReq
		if err := json.Unmarshal(req.V, &in); err != nil {
			_ = writeRPCError(conn, f.ID, err.Error())
			return
		}
		s.handleExec(ctx, conn, f.ID, in)
	default:
		_ = writeRPCError(conn, f.ID, fmt.Sprintf("unknown op %q", req.Op))
	}
}

func writeRPCOK(w io.Writer, id uint32, v any) error {
	var raw json.RawMessage
	if v != nil {
		b, err := json.Marshal(v)
		if err != nil {
			return err
		}
		raw = b
	}
	b, err := json.Marshal(guestproto.Response{ID: id, V: raw})
	if err != nil {
		return err
	}
	return guestproto.WriteFrame(w, guestproto.Frame{Type: guestproto.FrameResp, ID: id, Data: b})
}

func writeRPCError(w io.Writer, id uint32, msg string) error {
	b, _ := json.Marshal(guestproto.Response{ID: id, Err: msg})
	return guestproto.WriteFrame(w, guestproto.Frame{Type: guestproto.FrameResp, ID: id, Data: b})
}

// guestWritableRoots are directory trees that untrusted turns (uid 1000) can
// write to. Root-privileged file ops targeting paths inside these trees are
// confined with os.Root + O_NOFOLLOW so guest-planted symlinks cannot redirect
// writes, chowns, reads, or unlinks onto system files (e.g. /etc).
var guestWritableRoots = []string{"/workspace", "/home/node", "/tmp"}

func confinedRootFor(absPath string) (rootDir, rel string, ok bool) {
	clean := filepath.Clean(absPath)
	for _, r := range guestWritableRoots {
		rc := filepath.Clean(r)
		if clean == rc {
			return rc, ".", true
		}
		prefix := rc + string(filepath.Separator)
		if rc == string(filepath.Separator) {
			prefix = rc
		}
		if strings.HasPrefix(clean, prefix) {
			return rc, strings.TrimPrefix(clean, prefix), true
		}
	}
	return "", "", false
}

func mkdirAllChown(dir string, mode os.FileMode, uid, gid int) error {
	clean := filepath.Clean(dir)
	var missing []string
	cur := clean
	for {
		if _, err := os.Stat(cur); err == nil {
			break
		}
		missing = append(missing, cur)
		parent := filepath.Dir(cur)
		if parent == cur {
			break
		}
		cur = parent
	}
	for i := len(missing) - 1; i >= 0; i-- {
		if err := os.Mkdir(missing[i], mode); err != nil && !os.IsExist(err) {
			return err
		}
		if uid > 0 || gid > 0 {
			_ = os.Lchown(missing[i], uid, gid)
		}
	}
	return nil
}

func writeGuestFileConfined(rootDir, rel string, fw guestproto.FileWrite, mode os.FileMode) error {
	f, err := openFileNoFollowUnderRoot(rootDir, rel, mode, fw.UID, fw.GID)
	if err != nil {
		return err
	}
	defer f.Close()
	fi, err := f.Stat()
	if err != nil {
		return err
	}
	if !fi.Mode().IsRegular() {
		return fmt.Errorf("refusing to write non-regular file %q", fw.Path)
	}
	if _, err := f.Write(fw.Data); err != nil {
		return err
	}
	if err := f.Chmod(mode); err != nil {
		return err
	}
	if fw.UID > 0 || fw.GID > 0 {
		if err := f.Chown(fw.UID, fw.GID); err != nil {
			return err
		}
	}
	return f.Close()
}

func writeGuestFiles(files []guestproto.FileWrite) error {
	for _, fw := range files {
		if fw.Path == "" || !filepath.IsAbs(fw.Path) {
			return fmt.Errorf("invalid guest file path %q", fw.Path)
		}
		mode := os.FileMode(fw.Mode)
		if mode == 0 {
			mode = 0o644
		}
		if rootDir, rel, ok := confinedRootFor(fw.Path); ok {
			if err := writeGuestFileConfined(rootDir, rel, fw, mode); err != nil {
				return err
			}
			continue
		}
		if err := mkdirAllChown(filepath.Dir(fw.Path), 0o755, fw.UID, fw.GID); err != nil {
			return err
		}
		f, err := os.OpenFile(fw.Path, os.O_WRONLY|os.O_CREATE|os.O_TRUNC|openNoFollowFlag, mode)
		if err != nil {
			return err
		}
		if _, err := f.Write(fw.Data); err != nil {
			_ = f.Close()
			return err
		}
		_ = f.Chmod(mode)
		if fw.UID > 0 || fw.GID > 0 {
			_ = f.Chown(fw.UID, fw.GID)
		}
		if err := f.Close(); err != nil {
			return err
		}
	}
	return nil
}

func statGuestFile(p string) guestproto.StatResp {
	st, err := os.Stat(p)
	if err != nil {
		return guestproto.StatResp{Exists: false}
	}
	return guestproto.StatResp{
		Exists:        true,
		IsDir:         st.IsDir(),
		IsRegular:     st.Mode().IsRegular(),
		Size:          st.Size(),
		Mode:          uint32(st.Mode()),
		ModTimeUnixNS: st.ModTime().UnixNano(),
	}
}

func openGuestFileForRead(p string) (*os.File, error) {
	clean := filepath.Clean(p)
	// ~/.nix-profile is legitimately a symlink chain into /nix/store.
	if clean == "/home/node/.nix-profile/manifest.json" {
		real, err := filepath.EvalSymlinks(clean)
		if err != nil {
			return nil, err
		}
		for _, allowedRoot := range []string{"/home/node", "/nix/store"} {
			prefix := allowedRoot + string(filepath.Separator)
			if strings.HasPrefix(real, prefix) {
				root, err := os.OpenRoot(allowedRoot)
				if err != nil {
					return nil, err
				}
				defer root.Close()
				return root.Open(strings.TrimPrefix(real, prefix))
			}
		}
		return nil, fmt.Errorf("refusing symlink target outside /home/node or /nix/store: %q", clean)
	}
	if rootDir, rel, ok := confinedRootFor(clean); ok {
		if rel == "." || rel == "" {
			return nil, fmt.Errorf("cannot read directory root %q", rootDir)
		}
		root, err := os.OpenRoot(rootDir)
		if err != nil {
			return nil, err
		}
		defer root.Close()
		f, err := root.Open(rel)
		if err != nil {
			return nil, err
		}
		fi, err := f.Stat()
		if err != nil {
			_ = f.Close()
			return nil, err
		}
		if !fi.Mode().IsRegular() {
			_ = f.Close()
			return nil, fmt.Errorf("refusing to read non-regular file %q", clean)
		}
		return f, nil
	}
	return os.Open(clean)
}

func (s *agentServer) handleReadFile(conn net.Conn, id uint32, in guestproto.ReadFileReq) {
	f, err := openGuestFileForRead(in.Path)
	if err != nil {
		_ = writeRPCError(conn, id, err.Error())
		return
	}
	defer f.Close()
	if in.Offset > 0 {
		if _, err := f.Seek(in.Offset, io.SeekStart); err != nil {
			_ = writeRPCError(conn, id, err.Error())
			return
		}
	}
	if err := writeRPCOK(conn, id, nil); err != nil {
		return
	}
	var rd io.Reader = f
	if in.Limit > 0 {
		rd = io.LimitReader(f, in.Limit)
	}
	buf := make([]byte, 64<<10)
	for {
		n, rerr := rd.Read(buf)
		if n > 0 {
			if werr := guestproto.WriteFrame(conn, guestproto.Frame{
				Type: guestproto.FrameFileChunk,
				ID:   id,
				Data: buf[:n],
			}); werr != nil {
				return
			}
		}
		if rerr == io.EOF {
			_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameFileEOF, ID: id})
			return
		}
		if rerr != nil {
			_ = guestproto.WriteFrame(conn, guestproto.Frame{
				Type: guestproto.FrameFileError,
				ID:   id,
				Data: []byte(rerr.Error()),
			})
			return
		}
	}
}

func walkGuestDir(root string, maxDepth int) ([]guestproto.DirEntry, error) {
	if _, err := os.Stat(root); err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var out []guestproto.DirEntry
	err := filepath.WalkDir(root, func(p string, d fs.DirEntry, werr error) error {
		if werr != nil {
			return nil
		}
		if p == root {
			return nil
		}
		rel, err := filepath.Rel(root, p)
		if err != nil {
			return nil
		}
		if maxDepth > 0 {
			depth := strings.Count(filepath.ToSlash(rel), "/") + 1
			if depth > maxDepth {
				if d.IsDir() {
					return filepath.SkipDir
				}
				return nil
			}
		}
		info, ierr := d.Info()
		if ierr != nil {
			return nil
		}
		out = append(out, guestproto.DirEntry{
			Rel:           filepath.ToSlash(rel),
			IsDir:         d.IsDir(),
			Size:          info.Size(),
			Mode:          uint32(info.Mode()),
			ModTimeUnixNS: info.ModTime().UnixNano(),
		})
		return nil
	})
	sort.Slice(out, func(i, j int) bool { return out[i].Rel < out[j].Rel })
	return out, err
}

func unlinkGuestPaths(paths []string, recursive bool) error {
	var firstErr error
	for _, p := range paths {
		if p == "" || p == "/" {
			continue
		}
		var err error
		if rootDir, rel, ok := confinedRootFor(p); ok {
			if rel == "." || rel == "" {
				continue
			}
			root, oerr := os.OpenRoot(rootDir)
			if oerr != nil {
				if !errors.Is(oerr, os.ErrNotExist) && firstErr == nil {
					firstErr = oerr
				}
				continue
			}
			if recursive {
				err = root.RemoveAll(rel)
			} else {
				err = root.Remove(rel)
				if errors.Is(err, os.ErrNotExist) {
					err = nil
				}
			}
			_ = root.Close()
		} else {
			if recursive {
				err = os.RemoveAll(p)
			} else {
				err = os.Remove(p)
				if errors.Is(err, os.ErrNotExist) {
					err = nil
				}
			}
		}
		if err != nil && firstErr == nil {
			firstErr = err
		}
	}
	return firstErr
}

func (s *agentServer) handleExec(ctx context.Context, conn net.Conn, id uint32, in guestproto.ExecReq) {
	if len(in.Argv) == 0 {
		_ = writeRPCError(conn, id, "empty argv")
		return
	}
	if err := writeGuestFiles(in.Files); err != nil {
		_ = writeRPCError(conn, id, err.Error())
		return
	}
	cgName := in.CgroupName
	if cgName == "" {
		cgName = fmt.Sprintf("turn-%d", s.reqSeq.Add(1))
	}
	cgPath, err := applyCgroupLimits(cgName, in.MemoryLimitBytes, in.PidsLimit)
	if err != nil {
		s.log.Warn("cgroup setup failed", "name", cgName, "err", err)
	}

	cmd := exec.Command(in.Argv[0], in.Argv[1:]...)
	if in.Dir != "" {
		cmd.Dir = in.Dir
	}
	envMap := map[string]string{}
	for _, kv := range os.Environ() {
		if k, v, ok := strings.Cut(kv, "="); ok {
			envMap[k] = v
		}
	}
	for k, v := range in.Env {
		envMap[k] = v
	}
	cmd.Env = make([]string, 0, len(envMap))
	for k, v := range envMap {
		cmd.Env = append(cmd.Env, k+"="+v)
	}
	sort.Strings(cmd.Env)

	var ptyMaster *os.File
	var stdinW io.WriteCloser
	var stdoutR, stderrR io.ReadCloser
	var cgroupAttached bool

	if in.TTY {
		cgCleanup, attached := setupChildSysProcAttr(cmd, in.UID, in.GID, true, cgPath)
		cgroupAttached = attached
		s.execs.mu.Lock()
		ptyMaster, err = startPTY(cmd, in.Rows, in.Cols)
		if err == nil && cmd.Process != nil {
			s.execs.tracked[cmd.Process.Pid] = struct{}{}
		}
		s.execs.mu.Unlock()
		cgCleanup()
		if err != nil {
			_ = writeRPCError(conn, id, err.Error())
			_ = killAndCheckOOM(cgPath)
			return
		}
		stdinW = ptyMaster
		stdoutR = ptyMaster
	} else {
		cgCleanup, attached := setupChildSysProcAttr(cmd, in.UID, in.GID, false, cgPath)
		cgroupAttached = attached
		if stdinW, err = cmd.StdinPipe(); err != nil {
			cgCleanup()
			_ = writeRPCError(conn, id, err.Error())
			return
		}
		if stdoutR, err = cmd.StdoutPipe(); err != nil {
			cgCleanup()
			_ = writeRPCError(conn, id, err.Error())
			return
		}
		if stderrR, err = cmd.StderrPipe(); err != nil {
			cgCleanup()
			_ = writeRPCError(conn, id, err.Error())
			return
		}
		// Hold execTracker write lock across Start so orphan reaper cannot see an untracked PID.
		s.execs.mu.Lock()
		err = cmd.Start()
		if err == nil && cmd.Process != nil {
			s.execs.tracked[cmd.Process.Pid] = struct{}{}
		}
		s.execs.mu.Unlock()
		cgCleanup()
		if err != nil {
			_ = writeRPCError(conn, id, err.Error())
			_ = killAndCheckOOM(cgPath)
			return
		}
	}

	if cmd.Process != nil && cgPath != "" && !cgroupAttached {
		if err := addPidToCgroup(cgPath, cmd.Process.Pid); err != nil {
			s.log.Warn("attach pid to cgroup", "pid", cmd.Process.Pid, "err", err)
		}
	}

	started := time.Now()
	if cmd.Process != nil {
		s.tracef("exec started", "id", id, "argv0", in.Argv[0], "uid", in.UID, "tty", in.TTY, "pid", cmd.Process.Pid)
	}
	if err := writeRPCOK(conn, id, nil); err != nil {
		s.tracef("exec start reply failed", "id", id, "err", err)
		_ = signalProcessGroup(cmd, 9)
		_, _ = cmd.Process.Wait()
		if cmd.Process != nil {
			s.execs.untrack(cmd.Process.Pid)
		}
		_ = killAndCheckOOM(cgPath)
		return
	}

	sw := guestproto.NewSyncWriter(conn)
	var streamWG sync.WaitGroup
	streamReader := func(typ uint8, r io.ReadCloser) {
		if r == nil {
			return
		}
		streamWG.Add(1)
		go func() {
			defer streamWG.Done()
			buf := make([]byte, 32<<10)
			for {
				n, rerr := r.Read(buf)
				if n > 0 {
					chunk := make([]byte, n)
					copy(chunk, buf[:n])
					if werr := sw.WriteFrame(guestproto.Frame{Type: typ, ID: id, Data: chunk}); werr != nil {
						s.tracef("exec output write failed", "id", id, "frame", typ, "err", werr)
						return
					}
				}
				if rerr != nil {
					return
				}
			}
		}()
	}
	streamReader(guestproto.FrameStdout, stdoutR)
	streamReader(guestproto.FrameStderr, stderrR)

	// Host -> guest stdin/resize/signal pump until connection closes.
	go func() {
		defer func() {
			if !in.TTY && stdinW != nil {
				_ = stdinW.Close()
			}
		}()
		for {
			rf, rerr := guestproto.ReadFrame(conn)
			if rerr != nil {
				s.tracef("exec connection read ended", "id", id, "err", rerr)
				// Host closed or disconnected unexpectedly -> terminate child group.
				_ = signalProcessGroup(cmd, 9)
				return
			}
			switch rf.Type {
			case guestproto.FrameStdin:
				if stdinW != nil && len(rf.Data) > 0 {
					_, _ = stdinW.Write(rf.Data)
				}
			case guestproto.FrameStdinEOF:
				if !in.TTY && stdinW != nil {
					_ = stdinW.Close()
					stdinW = nil
				} else if ptyMaster != nil {
					_, _ = ptyMaster.Write([]byte{0x04}) // Ctrl-D
				}
			case guestproto.FrameResize:
				if ptyMaster != nil {
					if rows, cols, derr := guestproto.DecodeResize(rf.Data); derr == nil {
						_ = resizePTY(ptyMaster, rows, cols)
					}
				}
			case guestproto.FrameSignal:
				if sig, derr := guestproto.DecodeSignal(rf.Data); derr == nil {
					_ = signalProcessGroup(cmd, sig)
				}
			}
		}
	}()

	if !in.TTY {
		streamWG.Wait()
	}
	waitErr := cmd.Wait()
	if cmd.Process != nil {
		s.execs.untrack(cmd.Process.Pid)
	}
	if ptyMaster != nil {
		_ = ptyMaster.Close()
		streamWG.Wait()
	}

	oom := killAndCheckOOM(cgPath)
	exit := guestproto.ExecExit{OOMKilled: oom}
	if waitErr != nil {
		var ee *exec.ExitError
		if errors.As(waitErr, &ee) {
			if ws, ok := ee.Sys().(syscall.WaitStatus); ok && ws.Signaled() {
				exit.Code = 128 + int(ws.Signal())
			} else {
				exit.Code = ee.ExitCode()
			}
		} else {
			exit.Code = 1
			exit.Error = waitErr.Error()
		}
	}
	if ctx.Err() != nil && exit.Error == "" && exit.Code == 0 {
		exit.Code = 130
	}
	werr := guestproto.WriteJSONFrame(sw, guestproto.FrameExecExit, id, exit)
	s.tracef("exec finished", "id", id, "code", exit.Code, "error", exit.Error, "took", time.Since(started).Round(time.Millisecond), "exit_frame_err", werr)
}
