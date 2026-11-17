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

func (s *agentServer) serve(ctx context.Context, ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil || errors.Is(err, net.ErrClosed) {
				return
			}
			continue
		}
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
		if err := ensureDockerd(ctx, s.log, in.RegistryMirror); err != nil {
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

func writeGuestFiles(files []guestproto.FileWrite) error {
	for _, fw := range files {
		if fw.Path == "" || !filepath.IsAbs(fw.Path) {
			return fmt.Errorf("invalid guest file path %q", fw.Path)
		}
		if err := os.MkdirAll(filepath.Dir(fw.Path), 0o755); err != nil {
			return err
		}
		mode := os.FileMode(fw.Mode)
		if mode == 0 {
			mode = 0o644
		}
		if err := os.WriteFile(fw.Path, fw.Data, mode); err != nil {
			return err
		}
		if fw.UID > 0 || fw.GID > 0 {
			_ = os.Chown(fw.Path, fw.UID, fw.GID)
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

func (s *agentServer) handleReadFile(conn net.Conn, id uint32, in guestproto.ReadFileReq) {
	f, err := os.Open(in.Path)
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
		if recursive {
			err = os.RemoveAll(p)
		} else {
			err = os.Remove(p)
			if errors.Is(err, os.ErrNotExist) {
				err = nil
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

	if in.TTY {
		setupChildSysProcAttr(cmd, in.UID, in.GID, true)
		s.execs.mu.Lock()
		ptyMaster, err = startPTY(cmd, in.Rows, in.Cols)
		if err == nil && cmd.Process != nil {
			s.execs.tracked[cmd.Process.Pid] = struct{}{}
		}
		s.execs.mu.Unlock()
		if err != nil {
			_ = writeRPCError(conn, id, err.Error())
			_ = killAndCheckOOM(cgPath)
			return
		}
		stdinW = ptyMaster
		stdoutR = ptyMaster
	} else {
		setupChildSysProcAttr(cmd, in.UID, in.GID, false)
		if stdinW, err = cmd.StdinPipe(); err != nil {
			_ = writeRPCError(conn, id, err.Error())
			return
		}
		if stdoutR, err = cmd.StdoutPipe(); err != nil {
			_ = writeRPCError(conn, id, err.Error())
			return
		}
		if stderrR, err = cmd.StderrPipe(); err != nil {
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
		if err != nil {
			_ = writeRPCError(conn, id, err.Error())
			_ = killAndCheckOOM(cgPath)
			return
		}
	}

	if cmd.Process != nil && cgPath != "" {
		if err := addPidToCgroup(cgPath, cmd.Process.Pid); err != nil {
			s.log.Warn("attach pid to cgroup", "pid", cmd.Process.Pid, "err", err)
		}
	}

	if err := writeRPCOK(conn, id, nil); err != nil {
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
			exit.Code = ee.ExitCode()
		} else {
			exit.Code = 1
			exit.Error = waitErr.Error()
		}
	}
	if ctx.Err() != nil && exit.Error == "" && exit.Code == 0 {
		exit.Code = 130
	}
	_ = guestproto.WriteJSONFrame(sw, guestproto.FrameExecExit, id, exit)
}
