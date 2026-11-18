package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

var (
	_ ServiceBackend = (*MicroVM)(nil)
	_ ProxyBackend   = (*MicroVM)(nil)
)

func (b *MicroVM) vmDockerHTTP(rvm *runVM) *http.Client {
	return &http.Client{
		Timeout: 5 * time.Minute,
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
				rvm.mu.Lock()
				vm := rvm.vm
				rvm.mu.Unlock()
				if vm == nil {
					return nil, errors.New("microvm: vm stopped")
				}
				return vm.DialVSock(ctx, guestproto.PortDocker)
			},
		},
	}
}

func (b *MicroVM) dockerDo(ctx context.Context, hc *http.Client, method, path string, body any, out any) (int, []byte, error) {
	var rd io.Reader
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return 0, nil, err
		}
		rd = bytes.NewReader(raw)
	}
	req, err := http.NewRequestWithContext(ctx, method, "http://docker/v1.47"+path, rd)
	if err != nil {
		return 0, nil, err
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	res, err := hc.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer res.Body.Close()
	respBytes, _ := io.ReadAll(io.LimitReader(res.Body, 4<<20))
	if res.StatusCode >= 400 {
		return res.StatusCode, respBytes, fmt.Errorf("guest docker %s %s (%d): %s", method, path, res.StatusCode, strings.TrimSpace(string(respBytes)))
	}
	if out != nil && len(respBytes) > 0 {
		if err := json.Unmarshal(respBytes, out); err != nil {
			return res.StatusCode, respBytes, err
		}
	}
	return res.StatusCode, respBytes, nil
}

func (b *MicroVM) ensureGuestImage(ctx context.Context, hc *http.Client, image string) error {
	code, _, err := b.dockerDo(ctx, hc, http.MethodGet, "/images/"+url.PathEscape(image)+"/json", nil, nil)
	if err == nil && code == http.StatusOK {
		return nil
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, "http://docker/v1.47/images/create?fromImage="+url.QueryEscape(image), nil)
	if err != nil {
		return err
	}
	res, err := hc.Do(req)
	if err != nil {
		return fmt.Errorf("pull %s: %w", image, err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if res.StatusCode >= 400 {
		return fmt.Errorf("pull %s (%d): %s", image, res.StatusCode, strings.TrimSpace(string(body)))
	}
	// Docker streams JSON progress and reports errors inside {"error": "..."}.
	if strings.Contains(string(body), `"errorDetail"`) {
		return fmt.Errorf("pull %s: %s", image, strings.TrimSpace(string(body)))
	}
	return nil
}

func (b *MicroVM) StartDockerProxy(ctx context.Context, runID, _, key string) (*TurnDocker, error) {
	rvm, err := b.acquireVM(ctx, runID)
	if err != nil {
		return nil, err
	}
	released := false
	releaseOnce := func() {
		if !released {
			released = true
			b.releaseVM(rvm)
		}
	}

	if err := rvm.vm.Client().StartDockerd(ctx, b.registryMirrorURL()); err != nil {
		releaseOnce()
		return nil, err
	}
	hc := b.vmDockerHTTP(rvm)
	netName := proxyNetworkName(key)
	_, _, nerr := b.dockerDo(ctx, hc, http.MethodPost, "/networks/create", map[string]any{
		"Name":   netName,
		"Driver": "bridge",
		"Labels": map[string]string{guestproto.DockerGuardLabel: key},
	}, nil)
	if nerr != nil && !strings.Contains(nerr.Error(), "already exists") {
		releaseOnce()
		return nil, nerr
	}

	client := rvm.vm.Client()
	sock, err := client.OpenDockerGuard(ctx, key)
	if err != nil {
		releaseOnce()
		return nil, fmt.Errorf("open the turn's docker guard: %w", err)
	}

	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			defer releaseOnce()
			sctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			// The guest removes everything carrying the turn's label, the
			// network above included.
			if err := client.CloseDockerGuard(sctx, key); err != nil {
				b.logger().Warn("close turn docker guard", "run", runID, "key", key, "err", err)
			}
		})
	}
	return &TurnDocker{
		Network: netName,
		Env: map[string]string{
			"DOCKER_HOST": "unix://" + sock,
			// Ryuk reaps containers by mounting the Docker socket, which the
			// guard refuses; closing the turn removes them instead.
			"TESTCONTAINERS_RYUK_DISABLED": "true",
			// The guard only accepts classic builds: BuildKit's session and
			// gRPC streams can't be inspected.
			"DOCKER_BUILDKIT": "0",
		},
		Stop: stop,
	}, nil
}

func (b *MicroVM) StartServices(ctx context.Context, runID, key string, services []agentdef.Service) (string, func(), error) {
	rvm, err := b.acquireVM(ctx, runID)
	if err != nil {
		return "", nil, err
	}
	released := false
	releaseOnce := func() {
		if !released {
			released = true
			b.releaseVM(rvm)
		}
	}

	netName := serviceNetworkName(key)
	hc := b.vmDockerHTTP(rvm)
	stopContainers, err := b.startGuestServices(ctx, rvm.vm.Client(), hc, netName, key, services)
	if err != nil {
		releaseOnce()
		return "", nil, err
	}
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			defer releaseOnce()
			stopContainers()
		})
	}
	return netName, stop, nil
}

func (b *MicroVM) startGuestServices(ctx context.Context, client *guestproto.Client, hc *http.Client, netName, key string, services []agentdef.Service) (func(), error) {
	if err := client.StartDockerd(ctx, b.registryMirrorURL()); err != nil {
		return nil, err
	}
	_, _, nerr := b.dockerDo(ctx, hc, http.MethodPost, "/networks/create", map[string]any{
		"Name":   netName,
		"Driver": "bridge",
	}, nil)
	if nerr != nil && !strings.Contains(nerr.Error(), "already exists") {
		return nil, nerr
	}

	var started []string
	var stopOnce sync.Once
	stop := func() {
		stopOnce.Do(func() {
			sctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
			defer cancel()
			_ = client.EnsureBridgeAliases(sctx, nil)
			for _, id := range started {
				_, _, _ = b.dockerDo(sctx, hc, http.MethodDelete, "/containers/"+url.PathEscape(id)+"?force=true&v=true", nil, nil)
			}
			_, _, _ = b.dockerDo(sctx, hc, http.MethodDelete, "/networks/"+url.PathEscape(netName), nil, nil)
		})
	}

	aliases := map[string]string{}
	for _, s := range services {
		pCtx, cancel := context.WithTimeout(ctx, servicePullTimeout)
		perr := b.ensureGuestImage(pCtx, hc, s.Image)
		cancel()
		if perr != nil {
			stop()
			return nil, fmt.Errorf("service %s: %w", s.Name, perr)
		}

		tmpfs := map[string]string{}
		for _, tdir := range s.Tmpfs {
			tmpfs[tdir] = "rw"
		}
		envList := make([]string, 0, len(s.Env))
		for k, v := range s.Env {
			envList = append(envList, k+"="+v)
		}
		body := map[string]any{
			"Image": s.Image,
			"Cmd":   s.Command,
			"User":  s.User,
			"Env":   envList,
			"HostConfig": map[string]any{
				"NetworkMode":    netName,
				"Tmpfs":          tmpfs,
				"SecurityOpt":    []string{"no-new-privileges:true"},
				"ReadonlyRootfs": false,
			},
			"NetworkingConfig": map[string]any{
				"EndpointsConfig": map[string]any{
					netName: map[string]any{"Aliases": []string{s.Name}},
				},
			},
		}
		if len(s.Healthcheck) > 0 {
			body["Healthcheck"] = map[string]any{
				"Test":        s.Healthcheck,
				"Interval":    int64(time.Second),
				"Timeout":     int64(2 * time.Second),
				"Retries":     30,
				"StartPeriod": int64(500 * time.Millisecond),
			}
		}

		cname := serviceContainerName(key, s.Name)
		var created struct {
			ID string `json:"Id"`
		}
		if _, _, err := b.dockerDo(ctx, hc, http.MethodPost, "/containers/create?name="+url.QueryEscape(cname), body, &created); err != nil {
			stop()
			return nil, fmt.Errorf("service %s create: %w", s.Name, err)
		}
		started = append(started, created.ID)
		if _, _, err := b.dockerDo(ctx, hc, http.MethodPost, "/containers/"+url.PathEscape(created.ID)+"/start", nil, nil); err != nil {
			stop()
			return nil, fmt.Errorf("service %s start: %w", s.Name, err)
		}

		ip, err := b.waitGuestServiceReady(ctx, hc, created.ID, netName, s)
		if err != nil {
			stop()
			return nil, fmt.Errorf("service %s: %w", s.Name, err)
		}
		if ip != "" {
			aliases[s.Name] = ip
		}
	}

	if err := client.EnsureBridgeAliases(ctx, aliases); err != nil {
		stop()
		return nil, fmt.Errorf("register guest service DNS aliases: %w", err)
	}
	return stop, nil
}

func (b *MicroVM) waitGuestServiceReady(ctx context.Context, hc *http.Client, id, netName string, s agentdef.Service) (string, error) {
	wctx, cancel := context.WithTimeout(ctx, ServiceReadyTimeout)
	defer cancel()
	for {
		var info struct {
			State struct {
				Status   string `json:"Status"`
				Running  bool   `json:"Running"`
				ExitCode int    `json:"ExitCode"`
				Health   *struct {
					Status string `json:"Status"`
				} `json:"Health"`
			} `json:"State"`
			NetworkSettings struct {
				Networks map[string]struct {
					IPAddress string `json:"IPAddress"`
				} `json:"Networks"`
			} `json:"NetworkSettings"`
		}
		if _, _, err := b.dockerDo(wctx, hc, http.MethodGet, "/containers/"+url.PathEscape(id)+"/json", nil, &info); err != nil {
			return "", err
		}
		if !info.State.Running && info.State.Status == "exited" {
			return "", fmt.Errorf("exited unexpectedly (code %d)", info.State.ExitCode)
		}
		ip := info.NetworkSettings.Networks[netName].IPAddress
		if info.State.Running {
			if len(s.Healthcheck) == 0 && ip != "" {
				return ip, nil
			}
			if info.State.Health != nil && info.State.Health.Status == "healthy" && ip != "" {
				return ip, nil
			}
			if info.State.Health != nil && info.State.Health.Status == "unhealthy" {
				return "", errors.New("healthcheck failed")
			}
		}
		select {
		case <-wctx.Done():
			return "", fmt.Errorf("timed out waiting for service %s", s.Name)
		case <-time.After(servicePoll):
		}
	}
}

func (b *MicroVM) registryMirrorURL() string {
	if b.CacheStore == nil && b.CacheHandler == nil {
		return ""
	}
	return "http://" + microvm.InternalCacheHost
}
