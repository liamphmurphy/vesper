package guestproto

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

// Client calls vesper-guest-agent over PortRPC streams.
type Client struct {
	Dial func(ctx context.Context) (net.Conn, error)
}

func (c *Client) callUnary(ctx context.Context, op string, req, resp any) error {
	conn, err := c.Dial(ctx)
	if err != nil {
		return err
	}
	defer conn.Close()
	if dl, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(dl)
	}
	if err := WriteRequest(conn, 1, op, req); err != nil {
		return err
	}
	return ReadResponse(conn, resp)
}

func (c *Client) Ping(ctx context.Context) (PingResp, error) {
	var out PingResp
	err := c.callUnary(ctx, OpPing, nil, &out)
	return out, err
}

func (c *Client) WriteFiles(ctx context.Context, files []FileWrite) error {
	if len(files) == 0 {
		return nil
	}
	return c.callUnary(ctx, OpWriteFiles, WriteFilesReq{Files: files}, nil)
}

func (c *Client) Stat(ctx context.Context, path string) (StatResp, error) {
	var out StatResp
	err := c.callUnary(ctx, OpStat, StatReq{Path: path}, &out)
	return out, err
}

func (c *Client) WalkDir(ctx context.Context, root string, maxDepth int) ([]DirEntry, error) {
	var out WalkDirResp
	err := c.callUnary(ctx, OpWalkDir, WalkDirReq{Root: root, MaxDepth: maxDepth}, &out)
	return out.Entries, err
}

func (c *Client) UnlinkPaths(ctx context.Context, paths []string, recursive bool) error {
	if len(paths) == 0 {
		return nil
	}
	return c.callUnary(ctx, OpUnlinkPaths, UnlinkPathsReq{Paths: paths, Recursive: recursive}, nil)
}

func (c *Client) SyncAndDropCaches(ctx context.Context) error {
	return c.callUnary(ctx, OpSyncAndDropCaches, nil, nil)
}

// StartNixDaemon starts the in-guest nix-daemon (idempotent).
func (c *Client) StartNixDaemon(ctx context.Context) error {
	return c.callUnary(ctx, OpStartNixDaemon, struct{}{}, nil)
}

func (c *Client) StartDockerd(ctx context.Context, registryMirror string) error {
	return c.callUnary(ctx, OpStartDockerd, StartDockerdReq{RegistryMirror: registryMirror}, nil)
}

// OpenDockerGuard serves a Docker API for one turn (dockerd must be started)
// and returns its unix socket path inside the guest.
func (c *Client) OpenDockerGuard(ctx context.Context, key string) (string, error) {
	var out OpenDockerGuardResp
	err := c.callUnary(ctx, OpOpenDockerGuard, DockerGuardReq{Key: key}, &out)
	return out.Socket, err
}

// CloseDockerGuard stops a turn's Docker guard and removes the containers,
// networks and volumes the turn created. Closing an unknown key cleans up too.
func (c *Client) CloseDockerGuard(ctx context.Context, key string) error {
	return c.callUnary(ctx, OpCloseDockerGuard, DockerGuardReq{Key: key}, nil)
}

func (c *Client) EnsureBridgeAliases(ctx context.Context, aliases map[string]string) error {
	return c.callUnary(ctx, OpEnsureBridgeAliases, EnsureBridgeAliasesReq{Aliases: aliases}, nil)
}

func (c *Client) CheckTCPPort(ctx context.Context, port uint16) (bool, error) {
	var out CheckTCPPortResp
	err := c.callUnary(ctx, OpCheckTCPPort, CheckTCPPortReq{Port: port}, &out)
	return out.Listening, err
}

func (c *Client) Shutdown(ctx context.Context) error {
	return c.callUnary(ctx, OpShutdown, nil, nil)
}

// OpenFile opens a streaming file reader over a dedicated vsock connection.
func (c *Client) OpenFile(ctx context.Context, path string, offset, limit int64) (io.ReadCloser, error) {
	conn, err := c.Dial(ctx)
	if err != nil {
		return nil, err
	}
	if err := WriteRequest(conn, 1, OpReadFile, ReadFileReq{Path: path, Offset: offset, Limit: limit}); err != nil {
		_ = conn.Close()
		return nil, err
	}
	if err := ReadResponse(conn, nil); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return &remoteFileReader{conn: conn}, nil
}

// ReadFile reads up to limit bytes (or whole file if limit <= 0) from the guest.
func (c *Client) ReadFile(ctx context.Context, path string, limit int64) ([]byte, error) {
	rc, err := c.OpenFile(ctx, path, 0, limit)
	if err != nil {
		return nil, err
	}
	defer rc.Close()
	return io.ReadAll(rc)
}

type remoteFileReader struct {
	conn net.Conn
	buf  []byte
	eof  bool
}

func (r *remoteFileReader) Read(p []byte) (int, error) {
	for len(r.buf) == 0 {
		if r.eof {
			return 0, io.EOF
		}
		f, err := ReadFrame(r.conn)
		if err != nil {
			return 0, err
		}
		switch f.Type {
		case FrameFileChunk:
			r.buf = f.Data
		case FrameFileEOF:
			r.eof = true
			return 0, io.EOF
		case FrameFileError:
			r.eof = true
			return 0, errors.New(string(f.Data))
		default:
			return 0, fmt.Errorf("guestproto: unexpected file frame type %d", f.Type)
		}
	}
	n := copy(p, r.buf)
	r.buf = r.buf[n:]
	return n, nil
}

func (r *remoteFileReader) Close() error {
	return r.conn.Close()
}

// RemoteProcess represents an active process running inside the guest VM.
type RemoteProcess struct {
	conn    net.Conn
	sw      *SyncWriter
	stdoutR *io.PipeReader
	stdoutW *io.PipeWriter
	stderrR *io.PipeReader
	stderrW *io.PipeWriter

	doneOnce sync.Once
	done     chan struct{}
	exit     ExecExit
	exitErr  error
	killOnce sync.Once
}

// StartExec launches a command inside the guest and begins streaming stdio.
func (c *Client) StartExec(ctx context.Context, req ExecReq) (*RemoteProcess, error) {
	conn, err := c.Dial(ctx)
	if err != nil {
		return nil, err
	}
	// ctx bounds starting the process: a guest that takes the request and never
	// answers would otherwise block here forever. Once it's running, the
	// caller's Close (or Wait) governs the stream instead.
	hangUp := context.AfterFunc(ctx, func() { _ = conn.Close() })
	err = WriteRequest(conn, 1, OpExecStart, req)
	if err == nil {
		err = ReadResponse(conn, nil)
	}
	if !hangUp() {
		_ = conn.Close()
		return nil, ctx.Err()
	}
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	outr, outw := io.Pipe()
	errr, errw := io.Pipe()
	rp := &RemoteProcess{
		conn:    conn,
		sw:      NewSyncWriter(conn),
		stdoutR: outr,
		stdoutW: outw,
		stderrR: errr,
		stderrW: errw,
		done:    make(chan struct{}),
	}
	go rp.readLoop()
	return rp, nil
}

func (p *RemoteProcess) readLoop() {
	var exit ExecExit
	var exitErr error
	defer func() {
		p.finish(exit, exitErr)
		_ = p.stdoutW.Close()
		_ = p.stderrW.Close()
		_ = p.conn.Close()
	}()
	for {
		f, err := ReadFrame(p.conn)
		if err != nil {
			exitErr = err
			return
		}
		switch f.Type {
		case FrameStdout:
			if len(f.Data) > 0 {
				if _, werr := p.stdoutW.Write(f.Data); werr != nil {
					// Drain remains optional; keep reading until process exits if caller closed stdout early.
					continue
				}
			}
		case FrameStderr:
			if len(f.Data) > 0 {
				if _, werr := p.stderrW.Write(f.Data); werr != nil {
					continue
				}
			}
		case FrameExecExit:
			if err := json.Unmarshal(f.Data, &exit); err != nil {
				exitErr = err
			}
			return
		default:
			exitErr = fmt.Errorf("guestproto: unexpected exec frame type %d", f.Type)
			return
		}
	}
}

func (p *RemoteProcess) finish(exit ExecExit, err error) {
	p.doneOnce.Do(func() {
		p.exit = exit
		p.exitErr = err
		close(p.done)
	})
}

func (p *RemoteProcess) Stdout() io.Reader { return p.stdoutR }
func (p *RemoteProcess) Stderr() io.Reader { return p.stderrR }

func (p *RemoteProcess) Stdin() io.WriteCloser { return &remoteStdin{sw: p.sw} }

type remoteStdin struct {
	sw     *SyncWriter
	closed bool
}

func (s *remoteStdin) Write(b []byte) (int, error) {
	if s.closed {
		return 0, io.ErrClosedPipe
	}
	if len(b) == 0 {
		return 0, nil
	}
	const chunk = 64 << 10
	written := 0
	for len(b) > 0 {
		n := min(len(b), chunk)
		if err := s.sw.WriteFrame(Frame{Type: FrameStdin, ID: 1, Data: b[:n]}); err != nil {
			return written, err
		}
		written += n
		b = b[n:]
	}
	return written, nil
}

func (s *remoteStdin) Close() error {
	if s.closed {
		return nil
	}
	s.closed = true
	return s.sw.WriteFrame(Frame{Type: FrameStdinEOF, ID: 1})
}

func (p *RemoteProcess) Resize(rows, cols uint16) error {
	return p.sw.WriteFrame(Frame{Type: FrameResize, ID: 1, Data: EncodeResize(rows, cols)})
}

func (p *RemoteProcess) Signal(sig uint32) error {
	return p.sw.WriteFrame(Frame{Type: FrameSignal, ID: 1, Data: EncodeSignal(sig)})
}

// KillGrace is how long Kill waits for the guest to report the exit before it
// hangs up the stream.
const KillGrace = 10 * time.Second

// Kill sends SIGKILL and makes sure Wait returns: if the guest hasn't
// reported the exit within grace (it may be wedged, or the stream backed up
// behind output nobody reads), the stream is closed, and Wait returns an error.
func (p *RemoteProcess) Kill(grace time.Duration) error {
	err := p.Signal(9)
	if err != nil {
		_ = p.Close()
		return err
	}
	p.killOnce.Do(func() {
		time.AfterFunc(grace, func() {
			select {
			case <-p.done:
			default:
				_ = p.Close()
			}
		})
	})
	return nil
}

func (p *RemoteProcess) Wait() (ExecExit, error) {
	<-p.done
	return p.exit, p.exitErr
}

// Close closes the underlying stream connection (unblocking Wait if hung).
func (p *RemoteProcess) Close() error {
	_ = p.stdoutW.Close()
	_ = p.stderrW.Close()
	return p.conn.Close()
}
