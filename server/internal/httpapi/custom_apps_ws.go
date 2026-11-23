package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/customapps"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

const (
	maxCustomAppWSMessageBytes = 1 << 20 // 1 MiB per frame
	customAppWSDialTimeout     = 10 * time.Second
	customAppWSWriteTimeout    = 15 * time.Second
	maxCustomAppWSProtocols    = 4
)

var customAppWSUpgrader = websocket.Upgrader{
	ReadBufferSize:  8192,
	WriteBufferSize: 8192,
	CheckOrigin: func(r *http.Request) bool {
		origin := strings.TrimSpace(r.Header.Get("Origin"))
		if origin == "" {
			return true
		}
		u, err := url.Parse(origin)
		if err != nil {
			return false
		}
		if strings.EqualFold(u.Host, r.Host) {
			return true
		}
		h := strings.ToLower(u.Hostname())
		return h == "localhost" || h == "127.0.0.1" || h == "::1"
	},
}

func writeWSJSONError(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"code": code, "message": msg})
}

func parseCustomAppWSProtocols(raw string) ([]string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return nil, nil
	}
	parts := strings.Split(raw, ",")
	if len(parts) > maxCustomAppWSProtocols {
		return nil, apperr.Invalid("protocols", "at most %d subprotocols allowed", maxCustomAppWSProtocols)
	}
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		if len(p) > 64 || strings.ContainsAny(p, " \t\r\n,;") {
			return nil, apperr.Invalid("protocols", "invalid subprotocol %q", p)
		}
		out = append(out, p)
	}
	return out, nil
}

// handleCustomAppWS proxies a public WSS connection for a custom app UI,
// gated by app.ws:outbound and SSRF-checked via usersecrets.SafeTransport.
func (s *Server) handleCustomAppWS(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	u, _, ws := me(ctx)
	slug := r.PathValue("slug")
	app, err := s.customApps().Get(ctx, ws, u.ID, slug)
	if err != nil {
		if errors.Is(err, apperr.ErrNotFound) {
			writeWSJSONError(w, http.StatusNotFound, "not_found", "custom app not found")
			return
		}
		writeWSJSONError(w, http.StatusInternalServerError, "internal", err.Error())
		return
	}

	switch customapps.ModeFor(app.Capabilities, "app.ws:outbound") {
	case agentdef.Denied:
		writeWSJSONError(w, http.StatusForbidden, "forbidden", fmt.Sprintf("capability app.ws:outbound is denied for custom app %q", app.Slug))
		return
	case agentdef.RequiresApproval:
		if r.URL.Query().Get("approved") != "true" {
			writeWSJSONError(w, http.StatusForbidden, "forbidden", fmt.Sprintf("capability app.ws:outbound requires approval for custom app %q", app.Slug))
			return
		}
	}

	rawURL := strings.TrimSpace(r.URL.Query().Get("url"))
	parsed, err := url.Parse(rawURL)
	if rawURL == "" || len(rawURL) > 2048 || err != nil || parsed.Scheme != "wss" || parsed.Hostname() == "" || parsed.User != nil {
		writeWSJSONError(w, http.StatusBadRequest, "invalid", "url must be a valid wss URL")
		return
	}

	protocols, err := parseCustomAppWSProtocols(r.URL.Query().Get("protocols"))
	if err != nil {
		writeWSJSONError(w, http.StatusBadRequest, "invalid", err.Error())
		return
	}

	dialCtx, cancelDial := context.WithTimeout(ctx, customAppWSDialTimeout)
	defer cancelDial()

	upstreamHeaders := http.Header{"User-Agent": []string{"Vesper"}}
	upstream, upstreamResp, err := s.dialCustomAppWS(dialCtx, parsed.String(), upstreamHeaders, protocols)
	if err != nil {
		if upstreamResp != nil && upstreamResp.Body != nil {
			_ = upstreamResp.Body.Close()
		}
		var b *usersecrets.Blocked
		if errors.As(err, &b) {
			writeWSJSONError(w, http.StatusBadRequest, "invalid", b.Reason)
			return
		}
		writeWSJSONError(w, http.StatusBadGateway, "conflict", fmt.Sprintf("failed to connect upstream: %v", err))
		return
	}
	if upstreamResp != nil && upstreamResp.Body != nil {
		_ = upstreamResp.Body.Close()
	}
	defer upstream.Close()

	var respHeader http.Header
	if proto := upstream.Subprotocol(); proto != "" {
		respHeader = http.Header{"Sec-WebSocket-Protocol": []string{proto}}
	}
	client, err := customAppWSUpgrader.Upgrade(w, r, respHeader)
	if err != nil {
		return
	}
	defer client.Close()

	client.SetReadLimit(maxCustomAppWSMessageBytes)
	upstream.SetReadLimit(maxCustomAppWSMessageBytes)

	pumpWebSockets(ctx, client, upstream)
}

func (s *Server) dialCustomAppWS(ctx context.Context, targetURL string, headers http.Header, protocols []string) (*websocket.Conn, *http.Response, error) {
	if s.CustomAppWSDialer != nil {
		return s.CustomAppWSDialer(ctx, targetURL, headers, protocols)
	}
	safeTransport := usersecrets.SafeTransport(false, nil)
	dialer := &websocket.Dialer{
		NetDialContext:   safeTransport.DialContext,
		HandshakeTimeout: customAppWSDialTimeout,
		Subprotocols:     protocols,
	}
	return dialer.DialContext(ctx, targetURL, headers)
}

func pumpWebSockets(ctx context.Context, client, upstream *websocket.Conn) {
	var once sync.Once
	closeBoth := func(code int, reason string) {
		once.Do(func() {
			msg := websocket.FormatCloseMessage(code, reason)
			deadline := time.Now().Add(2 * time.Second)
			_ = client.WriteControl(websocket.CloseMessage, msg, deadline)
			_ = upstream.WriteControl(websocket.CloseMessage, msg, deadline)
			_ = client.Close()
			_ = upstream.Close()
		})
	}

	done := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			closeBoth(websocket.CloseGoingAway, "context canceled")
		case <-done:
		}
	}()

	var wg sync.WaitGroup
	wg.Add(2)
	forward := func(dst, src *websocket.Conn) {
		defer wg.Done()
		for {
			mt, data, err := src.ReadMessage()
			if err != nil {
				code := websocket.CloseNormalClosure
				reason := ""
				var ce *websocket.CloseError
				if errors.As(err, &ce) && ce.Code >= 1000 && ce.Code <= 4999 && ce.Code != websocket.CloseNoStatusReceived && ce.Code != websocket.CloseAbnormalClosure {
					code = ce.Code
					reason = ce.Text
				}
				closeBoth(code, reason)
				return
			}
			_ = dst.SetWriteDeadline(time.Now().Add(customAppWSWriteTimeout))
			if err := dst.WriteMessage(mt, data); err != nil {
				closeBoth(websocket.CloseGoingAway, "")
				return
			}
		}
	}

	go forward(upstream, client)
	go forward(client, upstream)
	wg.Wait()
	close(done)
}
