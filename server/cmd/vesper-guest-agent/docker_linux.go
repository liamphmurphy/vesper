//go:build linux

package main

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

const (
	dockerRawSock  = "/var/run/docker-raw.sock"
	containerdSock = "/run/containerd/containerd.sock"
)

var (
	dockerMu      sync.Mutex
	dockerStarted bool
	dockerMirror  string
)

func ensureDockerd(ctx context.Context, log *slog.Logger, execs *execTracker, registryMirror string) error {
	dockerMu.Lock()
	defer dockerMu.Unlock()

	if dockerStarted && pingUnixHTTP(dockerRawSock) && (registryMirror == "" || registryMirror == dockerMirror) {
		return nil
	}

	_ = os.MkdirAll("/etc/docker", 0o755)
	_ = os.MkdirAll("/var/lib/docker", 0o755)
	_ = os.MkdirAll("/var/run", 0o755)
	_ = os.MkdirAll("/run/containerd", 0o755)

	if !pingUnixSocketExists(containerdSock) {
		cd := exec.Command("containerd")
		cdOut, _ := os.OpenFile("/var/log/containerd.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if cdOut != nil {
			cd.Stdout = cdOut
			cd.Stderr = cdOut
		}
		if err := startTrackedChild(execs, cd); err != nil {
			return fmt.Errorf("start containerd: %w", err)
		}
		if err := waitForFile(ctx, containerdSock, 10*time.Second); err != nil {
			return fmt.Errorf("containerd socket: %w", err)
		}
	}

	if !pingUnixHTTP(dockerRawSock) {
		cfg := map[string]any{
			"data-root":      "/var/lib/docker",
			"dns":            []string{guestDummyIP},
			"storage-driver": "overlay2",
			"hosts":          []string{"unix://" + dockerRawSock},
			"containerd":     containerdSock,
		}
		if registryMirror != "" {
			cfg["registry-mirrors"] = []string{registryMirror}
			if host, err := extractHostPort(registryMirror); err == nil {
				cfg["insecure-registries"] = []string{host}
			}
			dockerMirror = registryMirror
		}
		cfgBytes, _ := json.MarshalIndent(cfg, "", "  ")
		if err := os.WriteFile("/etc/docker/daemon.json", cfgBytes, 0o644); err != nil {
			return err
		}

		dd := exec.Command("dockerd", "--config-file=/etc/docker/daemon.json")
		ddOut, _ := os.OpenFile("/var/log/dockerd.log", os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
		if ddOut != nil {
			dd.Stdout = ddOut
			dd.Stderr = ddOut
		}
		if err := startTrackedChild(execs, dd); err != nil {
			return fmt.Errorf("start dockerd: %w", err)
		}

		deadline := time.Now().Add(20 * time.Second)
		for time.Now().Before(deadline) {
			if pingUnixHTTP(dockerRawSock) {
				break
			}
			if ctx.Err() != nil {
				return ctx.Err()
			}
			time.Sleep(100 * time.Millisecond)
		}
		if !pingUnixHTTP(dockerRawSock) {
			logTail, _ := os.ReadFile("/var/log/dockerd.log")
			return fmt.Errorf("dockerd did not become ready: %s", string(logTail))
		}
	}

	if !dockerStarted {
		if err := startDockerVSockBridge(log); err != nil {
			return fmt.Errorf("docker vsock bridge: %w", err)
		}
		dockerStarted = true
	}
	return nil
}

func extractHostPort(rawURL string) (string, error) {
	u := strings.TrimPrefix(rawURL, "http://")
	u = strings.TrimPrefix(u, "https://")
	host := strings.SplitN(u, "/", 2)[0]
	if host == "" {
		return "", errors.New("empty host")
	}
	return host, nil
}

func pingUnixSocketExists(p string) bool {
	c, err := net.DialTimeout("unix", p, 200*time.Millisecond)
	if err != nil {
		return false
	}
	_ = c.Close()
	return true
}

func pingUnixHTTP(sock string) bool {
	hc := &http.Client{
		Timeout: 500 * time.Millisecond,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				return (&net.Dialer{}).DialContext(ctx, "unix", sock)
			},
		},
	}
	res, err := hc.Get("http://docker/_ping")
	if err != nil {
		return false
	}
	_ = res.Body.Close()
	return res.StatusCode == http.StatusOK
}

func waitForFile(ctx context.Context, p string, d time.Duration) error {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if pingUnixSocketExists(p) {
			return nil
		}
		if ctx.Err() != nil {
			return ctx.Err()
		}
		time.Sleep(50 * time.Millisecond)
	}
	return fmt.Errorf("timed out waiting for %s", p)
}

// dockerGuardDir holds one socket per turn. It is traversable but not
// listable, so a process can open only a socket whose name it was given.
const dockerGuardDir = "/run/vesper-docker"

var (
	guardsMu sync.Mutex
	guards   = map[string]*http.Server{}
)

func rawDockerTransport() http.RoundTripper {
	return &http.Transport{
		DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
			return (&net.Dialer{}).DialContext(ctx, "unix", dockerRawSock)
		},
	}
}

// openDockerGuard serves the turn's Docker API on its own socket. Opening a
// key that is already open returns the same socket.
func openDockerGuard(key string) (string, error) {
	if !guardKeyRe.MatchString(key) {
		return "", fmt.Errorf("invalid docker guard key %q", key)
	}
	sock := filepath.Join(dockerGuardDir, key+".sock")
	guardsMu.Lock()
	defer guardsMu.Unlock()
	if _, ok := guards[key]; ok {
		return sock, nil
	}
	if err := os.MkdirAll(dockerGuardDir, 0o711); err != nil {
		return "", err
	}
	if err := os.Chmod(dockerGuardDir, 0o711); err != nil {
		return "", err
	}
	_ = os.Remove(sock)
	ln, err := net.Listen("unix", sock)
	if err != nil {
		return "", err
	}
	// Turns run as uid 1000.
	if err := os.Chmod(sock, 0o666); err != nil {
		_ = ln.Close()
		return "", err
	}
	srv := &http.Server{Handler: newDockerGuard(key, rawDockerTransport()), ReadHeaderTimeout: 30 * time.Second}
	guards[key] = srv
	go func() { _ = srv.Serve(ln) }()
	return sock, nil
}

// closeDockerGuard stops the turn's socket, then removes what it created.
func closeDockerGuard(ctx context.Context, key string) error {
	if !guardKeyRe.MatchString(key) {
		return fmt.Errorf("invalid docker guard key %q", key)
	}
	guardsMu.Lock()
	srv := guards[key]
	delete(guards, key)
	guardsMu.Unlock()
	if srv != nil {
		_ = srv.Close()
	}
	_ = os.Remove(filepath.Join(dockerGuardDir, key+".sock"))
	if !pingUnixSocketExists(dockerRawSock) {
		return nil // dockerd never started: nothing to remove
	}
	return cleanupDockerTurn(ctx, rawDockerTransport(), key)
}

func startDockerVSockBridge(log *slog.Logger) error {
	ln, err := listenVSock(guestproto.PortDocker)
	if err != nil {
		return err
	}
	go func() {
		for {
			c, aerr := ln.Accept()
			if aerr != nil {
				return
			}
			// Security: accept PortDocker connections strictly from host CID 2.
			if vc, ok := c.(*vsockConn); !ok || vc.remote.cid != 2 {
				_ = c.Close()
				continue
			}
			go bridgeUnix(log, c, dockerRawSock)
		}
	}()
	return nil
}

func bridgeUnix(log *slog.Logger, client net.Conn, sockPath string) {
	defer client.Close()
	up, err := net.Dial("unix", sockPath)
	if err != nil {
		log.Debug("bridge unix dial failed", "sock", sockPath, "err", err)
		return
	}
	defer up.Close()

	var wg sync.WaitGroup
	wg.Add(2)
	go func() {
		defer wg.Done()
		_, _ = io.Copy(up, client)
		if uc, ok := up.(*net.UnixConn); ok {
			_ = uc.CloseWrite()
		}
	}()
	go func() {
		defer wg.Done()
		_, _ = io.Copy(client, up)
		if vc, ok := client.(*vsockConn); ok {
			_ = shutdownVSockWrite(vc)
		}
	}()
	wg.Wait()
}

func startTrackedChild(execs *execTracker, cmd *exec.Cmd) error {
	if execs == nil {
		if err := cmd.Start(); err != nil {
			return err
		}
		go func() { _ = cmd.Wait() }()
		return nil
	}
	execs.mu.Lock()
	err := cmd.Start()
	var pid int
	if err == nil && cmd.Process != nil {
		pid = cmd.Process.Pid
		execs.tracked[pid] = struct{}{}
	}
	execs.mu.Unlock()
	if err != nil {
		return err
	}
	go func() {
		_ = cmd.Wait()
		if pid > 0 {
			execs.untrack(pid)
		}
	}()
	return nil
}
