// Package pgembed manages a self-contained, Unix-socket-only PostgreSQL 17
// cluster for single-binary Vesper Desktop runs (zero TCP ports opened).
package pgembed

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/jackc/pgx/v5"
)

type Config struct {
	BinDir    string // Directory with postgres, initdb, pg_isready; falls back to PATH when empty.
	DataDir   string
	SocketDir string // Optional Unix socket dir; auto-created in /tmp when empty or >75 bytes.
	Database  string // Default "vesper".
	User      string // Default "vesper".
	Port      int    // Unix socket filename suffix (.s.PGSQL.<Port>), default 5432. No TCP listener.
	LogPath   string // Optional postgres stderr log file.
	Log       *slog.Logger
}

type Cluster struct {
	cfg        Config
	socketDir  string
	ownSockDir bool
	dsn        string

	cmd     *exec.Cmd
	logFile *os.File
	waitCh  chan error
	stopDo  sync.Once
}

func Start(ctx context.Context, cfg Config) (*Cluster, error) {
	if cfg.DataDir == "" {
		return nil, errors.New("pgembed: DataDir is required")
	}
	if cfg.Database == "" {
		cfg.Database = "vesper"
	}
	if cfg.User == "" {
		cfg.User = "vesper"
	}
	if cfg.Port <= 0 {
		cfg.Port = 5432
	}
	if cfg.Log == nil {
		cfg.Log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}

	initdbBin, err := findBin(cfg.BinDir, "initdb")
	if err != nil {
		return nil, err
	}
	postgresBin, err := findBin(cfg.BinDir, "postgres")
	if err != nil {
		return nil, err
	}
	pgReadyBin, _ := findBin(cfg.BinDir, "pg_isready")

	bundleRoot := ""
	if cfg.BinDir != "" {
		bundleRoot = filepath.Dir(filepath.Clean(cfg.BinDir))
	} else {
		bundleRoot = filepath.Dir(filepath.Dir(postgresBin))
	}
	shareDir := filepath.Join(bundleRoot, "share", "postgresql")
	pkgLibDir := filepath.Join(bundleRoot, "lib", "postgresql")

	if err := os.MkdirAll(cfg.DataDir, 0o700); err != nil {
		return nil, fmt.Errorf("pgembed mkdir DataDir: %w", err)
	}
	_ = os.Chmod(cfg.DataDir, 0o700)

	if err := cleanStalePID(cfg.DataDir); err != nil {
		return nil, err
	}

	sockDir := cfg.SocketDir
	ownSockDir := false
	// macOS sockaddr_un.sun_path is limited to 104 bytes; keep socket path short under /tmp.
	if sockDir == "" || len(filepath.Join(sockDir, fmt.Sprintf(".s.PGSQL.%d", cfg.Port))) >= 96 {
		d, err := os.MkdirTemp("/tmp", "vesper-pg-*")
		if err != nil {
			return nil, fmt.Errorf("pgembed socket dir: %w", err)
		}
		_ = os.Chmod(d, 0o700)
		sockDir = d
		ownSockDir = true
	} else {
		if err := os.MkdirAll(sockDir, 0o700); err != nil {
			return nil, err
		}
		_ = os.Chmod(sockDir, 0o700)
	}

	cleanupSock := func() {
		if ownSockDir && sockDir != "" {
			_ = os.RemoveAll(sockDir)
		}
	}

	if _, err := os.Stat(filepath.Join(cfg.DataDir, "PG_VERSION")); errors.Is(err, os.ErrNotExist) {
		args := []string{
			"-D", cfg.DataDir,
			"--username=" + cfg.User,
			"--auth=trust",
			"--encoding=UTF8",
			"--locale=C",
			"--no-instructions",
		}
		if st, serr := os.Stat(filepath.Join(shareDir, "postgres.bki")); serr == nil && !st.IsDir() {
			args = append(args, "-L", shareDir)
		}
		icmd := exec.CommandContext(ctx, initdbBin, args...)
		icmd.Env = basePGEnv()
		if out, ierr := icmd.CombinedOutput(); ierr != nil {
			cleanupSock()
			return nil, fmt.Errorf("pgembed initdb failed: %w\n%s", ierr, strings.TrimSpace(string(out)))
		}
	}

	args := postgresArgs(cfg, sockDir, pkgLibDir)

	var stderrRing tailBuffer
	stderrRing.limit = 32 << 10
	var logFile *os.File
	var stderrW io.Writer = &stderrRing
	if cfg.LogPath != "" {
		if mkErr := os.MkdirAll(filepath.Dir(cfg.LogPath), 0o755); mkErr == nil {
			if lf, oerr := os.OpenFile(cfg.LogPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600); oerr == nil {
				logFile = lf
				stderrW = io.MultiWriter(&stderrRing, lf)
			}
		}
	}

	cmd := exec.Command(postgresBin, args...)
	cmd.Env = basePGEnv()
	cmd.Stdout = io.Discard
	cmd.Stderr = stderrW
	if err := cmd.Start(); err != nil {
		if logFile != nil {
			_ = logFile.Close()
		}
		cleanupSock()
		return nil, fmt.Errorf("pgembed start postgres: %w", err)
	}

	waitCh := make(chan error, 1)
	go func() {
		waitCh <- cmd.Wait()
		close(waitCh)
	}()

	c := &Cluster{
		cfg:        cfg,
		socketDir:  sockDir,
		ownSockDir: ownSockDir,
		dsn:        buildSocketDSN(cfg.User, cfg.Database, sockDir, cfg.Port),
		cmd:        cmd,
		logFile:    logFile,
		waitCh:     waitCh,
	}

	if err := c.waitReady(ctx, pgReadyBin, &stderrRing); err != nil {
		sctx, scancel := context.WithTimeout(context.Background(), 5*time.Second)
		_ = c.Stop(sctx)
		scancel()
		return nil, err
	}
	if err := c.ensureDatabase(ctx); err != nil {
		sctx, scancel := context.WithTimeout(context.Background(), 5*time.Second)
		_ = c.Stop(sctx)
		scancel()
		return nil, err
	}
	return c, nil
}

func (c *Cluster) DSN() string       { return c.dsn }
func (c *Cluster) SocketDir() string { return c.socketDir }

func (c *Cluster) Stop(ctx context.Context) error {
	var stopErr error
	c.stopDo.Do(func() {
		defer func() {
			if c.logFile != nil {
				_ = c.logFile.Close()
			}
			if c.ownSockDir && c.socketDir != "" {
				_ = os.RemoveAll(c.socketDir)
			}
		}()
		if c.cmd == nil || c.cmd.Process == nil {
			return
		}
		// SIGINT triggers PostgreSQL fast shutdown.
		_ = c.cmd.Process.Signal(syscall.SIGINT)
		select {
		case err := <-c.waitCh:
			if err != nil && !isCleanExit(err) {
				stopErr = err
			}
			return
		case <-ctx.Done():
		case <-time.After(10 * time.Second):
		}

		// Escalate to SIGQUIT (immediate shutdown), then SIGKILL if still stuck.
		_ = c.cmd.Process.Signal(syscall.SIGQUIT)
		select {
		case err := <-c.waitCh:
			if err != nil && !isCleanExit(err) {
				stopErr = err
			}
			return
		case <-time.After(3 * time.Second):
			_ = c.cmd.Process.Kill()
			<-c.waitCh
		}
	})
	return stopErr
}

func (c *Cluster) waitReady(ctx context.Context, pgReadyBin string, errLog *tailBuffer) error {
	wctx, cancel := context.WithTimeout(ctx, 25*time.Second)
	defer cancel()

	maintDSN := buildSocketDSN(c.cfg.User, "postgres", c.socketDir, c.cfg.Port)
	for {
		select {
		case err, ok := <-c.waitCh:
			if !ok {
				err = errors.New("exited unexpectedly")
			}
			return fmt.Errorf("pgembed postgres exited during startup: %w\n%s", err, errLog.String())
		default:
		}

		ready := false
		if pgReadyBin != "" {
			rcmd := exec.CommandContext(wctx, pgReadyBin, "-h", c.socketDir, "-p", strconv.Itoa(c.cfg.Port), "-U", c.cfg.User)
			rcmd.Env = basePGEnv()
			if rcmd.Run() == nil {
				ready = true
			}
		} else {
			pctx, pcancel := context.WithTimeout(wctx, time.Second)
			conn, err := pgx.Connect(pctx, maintDSN)
			pcancel()
			if err == nil {
				_ = conn.Close(context.Background())
				ready = true
			}
		}
		if ready {
			return nil
		}

		select {
		case <-wctx.Done():
			return fmt.Errorf("pgembed timed out waiting for postgres socket %s: %w\n%s", c.socketDir, wctx.Err(), errLog.String())
		case <-time.After(50 * time.Millisecond):
		}
	}
}

func (c *Cluster) ensureDatabase(ctx context.Context) error {
	maintDSN := buildSocketDSN(c.cfg.User, "postgres", c.socketDir, c.cfg.Port)
	conn, err := pgx.Connect(ctx, maintDSN)
	if err != nil {
		return fmt.Errorf("pgembed connect maintenance db: %w", err)
	}
	var exists bool
	if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM pg_database WHERE datname = $1)`, c.cfg.Database).Scan(&exists); err != nil {
		_ = conn.Close(ctx)
		return fmt.Errorf("pgembed check database: %w", err)
	}
	if !exists {
		quotedDB := pgx.Identifier{c.cfg.Database}.Sanitize()
		quotedUser := pgx.Identifier{c.cfg.User}.Sanitize()
		if _, err := conn.Exec(ctx, fmt.Sprintf("CREATE DATABASE %s OWNER %s", quotedDB, quotedUser)); err != nil {
			_ = conn.Close(ctx)
			return fmt.Errorf("pgembed create database %s: %w", c.cfg.Database, err)
		}
	}
	_ = conn.Close(ctx)
	return nil
}

func postgresArgs(cfg Config, sockDir, pkgLibDir string) []string {
	args := []string{
		"-D", cfg.DataDir,
		"-k", sockDir,
		"-h", "", // Disable TCP listening entirely; Unix socket only.
		"-p", strconv.Itoa(cfg.Port),
		"-c", "unix_socket_permissions=0700",
		"-c", "shared_buffers=64MB",
		"-c", "max_connections=64",
		"-c", "timezone=UTC",
		"-c", "log_timezone=UTC",
		// Reduce background daemon timer wakeups (defaults are 200ms / 60s / 5min)
		// without relaxing synchronous commit durability.
		"-c", "bgwriter_delay=2000ms",
		"-c", "wal_writer_delay=2000ms",
		"-c", "autovacuum_naptime=5min",
		"-c", "checkpoint_timeout=15min",
	}
	if pkgLibDir != "" {
		if st, serr := os.Stat(pkgLibDir); serr == nil && st.IsDir() {
			args = append(args, "-c", "dynamic_library_path="+pkgLibDir)
		}
	}
	return args
}

func buildSocketDSN(user, dbName, sockDir string, port int) string {
	u := url.URL{
		Scheme: "postgres",
		User:   url.User(user),
		Path:   "/" + dbName,
	}
	q := url.Values{}
	q.Set("host", sockDir)
	q.Set("port", strconv.Itoa(port))
	q.Set("sslmode", "disable")
	u.RawQuery = q.Encode()
	return u.String()
}

func findBin(binDir, name string) (string, error) {
	if binDir != "" {
		p := filepath.Join(binDir, name)
		st, err := os.Stat(p)
		if err != nil || st.IsDir() {
			return "", fmt.Errorf("pgembed: missing %s in %s", name, binDir)
		}
		return p, nil
	}
	p, err := exec.LookPath(name)
	if err != nil {
		return "", fmt.Errorf("pgembed: %s not found on PATH: %w", name, err)
	}
	return p, nil
}

func basePGEnv() []string {
	return []string{
		"PATH=/usr/bin:/bin",
		"LC_ALL=C",
		"LANG=C",
		"PGCLIENTENCODING=UTF8",
	}
}

func cleanStalePID(dataDir string) error {
	pidPath := filepath.Join(dataDir, "postmaster.pid")
	raw, err := os.ReadFile(pidPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	firstLine, _, _ := strings.Cut(string(raw), "\n")
	pid, perr := strconv.Atoi(strings.TrimSpace(firstLine))
	if perr != nil || pid <= 0 {
		return os.Remove(pidPath)
	}
	if err := syscall.Kill(pid, 0); errors.Is(err, syscall.ESRCH) {
		return os.Remove(pidPath)
	}
	return fmt.Errorf("pgembed: postgres (pid %d) is already using %s", pid, dataDir)
}

func isCleanExit(err error) bool {
	var ee *exec.ExitError
	return errors.As(err, &ee) && ee.ExitCode() == 0
}

type tailBuffer struct {
	mu    sync.Mutex
	limit int
	buf   bytes.Buffer
}

func (b *tailBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.buf.Len()+len(p) > b.limit {
		b.buf.Reset()
	}
	b.buf.Write(p)
	return len(p), nil
}

func (b *tailBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return strings.TrimSpace(b.buf.String())
}
