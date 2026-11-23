package httpapi

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/gorilla/websocket"
)

func TestCustomAppWSProxy(t *testing.T) {
	// Fake upstream echo WebSocket server.
	upgrader := websocket.Upgrader{CheckOrigin: func(*http.Request) bool { return true }}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		for {
			mt, msg, err := conn.ReadMessage()
			if err != nil {
				return
			}
			if err := conn.WriteMessage(mt, append([]byte("echo:"), msg...)); err != nil {
				return
			}
		}
	}))
	defer upstream.Close()
	upstreamWSURL := "ws" + strings.TrimPrefix(upstream.URL, "http")

	var apiSrv *Server
	e := newChatEnvServer(t, nil, func(s *Server) {
		apiSrv = s
		s.CustomAppWSDialer = func(ctx context.Context, _ string, headers http.Header, protocols []string) (*websocket.Conn, *http.Response, error) {
			d := &websocket.Dialer{Subprotocols: protocols}
			return d.DialContext(ctx, upstreamWSURL, headers)
		}
	})

	e.want("POST", "/custom-apps", map[string]any{
		"slug":     "feed",
		"name":     "Feed",
		"template": "blank",
	}, http.StatusCreated)

	target := url.QueryEscape("wss://irc-ws.chat.twitch.tv:443")

	// 1. Default app.ws:outbound is denied -> 403.
	if code, _ := e.do("GET", "/custom-apps/feed/ws?url="+target, nil); code != http.StatusForbidden {
		t.Fatalf("denied ws proxy = %d, want 403", code)
	}

	// 2. requires_approval blocks unapproved requests -> 403.
	e.want("PATCH", "/custom-apps/feed", map[string]any{
		"capabilities": map[string]any{
			"app.sql:read":    "allowed",
			"app.sql:write":   "allowed",
			"app.ws:outbound": "requires_approval",
		},
	}, http.StatusOK)

	if code, _ := e.do("GET", "/custom-apps/feed/ws?url="+target, nil); code != http.StatusForbidden {
		t.Fatalf("unapproved ws proxy = %d, want 403", code)
	}

	// 3. Allowed mode rejects non-wss and credentialed URLs -> 400.
	e.want("PATCH", "/custom-apps/feed", map[string]any{
		"capabilities": map[string]any{
			"app.sql:read":    "allowed",
			"app.sql:write":   "allowed",
			"app.ws:outbound": "allowed",
		},
	}, http.StatusOK)

	if code, _ := e.do("GET", "/custom-apps/feed/ws?url="+url.QueryEscape("ws://irc-ws.chat.twitch.tv:80"), nil); code != http.StatusBadRequest {
		t.Fatalf("ws:// scheme = %d, want 400", code)
	}
	if code, _ := e.do("GET", "/custom-apps/feed/ws?url="+url.QueryEscape("wss://u:p@irc-ws.chat.twitch.tv:443"), nil); code != http.StatusBadRequest {
		t.Fatalf("credentialed wss url = %d, want 400", code)
	}

	// 4. Allowed mode proxies messages bidirectionally.
	proxyWSURL := "ws" + strings.TrimPrefix(e.srv.URL, "http") + "/api/v1/custom-apps/feed/ws?url=" + target
	clientConn, resp, err := websocket.DefaultDialer.Dial(proxyWSURL, nil)
	if err != nil {
		status := 0
		if resp != nil {
			status = resp.StatusCode
		}
		t.Fatalf("dial proxy ws (status=%d): %v", status, err)
	}
	defer clientConn.Close()

	if err := clientConn.WriteMessage(websocket.TextMessage, []byte("PING :tmi.twitch.tv")); err != nil {
		t.Fatalf("write message: %v", err)
	}
	mt, got, err := clientConn.ReadMessage()
	if err != nil {
		t.Fatalf("read message: %v", err)
	}
	if mt != websocket.TextMessage || string(got) != "echo:PING :tmi.twitch.tv" {
		t.Fatalf("got (%d, %q), want (TextMessage, %q)", mt, string(got), "echo:PING :tmi.twitch.tv")
	}
	_ = clientConn.WriteMessage(websocket.CloseMessage, websocket.FormatCloseMessage(websocket.CloseNormalClosure, "done"))

	// 5. Default SafeTransport blocks loopback/private SSRF targets.
	apiSrv.CustomAppWSDialer = nil
	code, body := e.do("GET", "/custom-apps/feed/ws?url="+url.QueryEscape("wss://127.0.0.1:443/"), nil)
	msg, _ := body["message"].(string)
	if code != http.StatusBadRequest || !strings.Contains(msg, "private address") {
		t.Fatalf("loopback wss = %d %v, want 400 private address", code, body)
	}
}
