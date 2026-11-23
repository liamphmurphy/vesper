package httpapi

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/google/uuid"
)

// hlsRelayAppServer mirrors Watch Feed's ad-filtered live HLS relay flow:
// start_relay registers the stream with media.relayHLS, and relay serves
// master + ad-filtered media playlists using in-memory relay_state.
const hlsRelayAppServer = `import { defineServer, fetch, media } from "@vesper/server";
export default defineServer({
  tools: {
    start_relay: {
      description: "Start a LAN HLS relay stream",
      inputSchema: { type: "object" },
      handler: async (a) => media.relayHLS({
        tool: "relay",
        args: { upstream: a.upstream },
        proxy_segments: Boolean(a.proxy_segments),
      }),
    },
    stop_relay: {
      description: "Stop a LAN HLS relay stream",
      inputSchema: { type: "object" },
      handler: async (a) => media.stopRelay(a.id),
    },
    relay: {
      description: "Serve master or ad-filtered media playlist for the HLS relay",
      inputSchema: { type: "object" },
      handler: async (a) => {
        if (a.relay_kind === "master") {
          return {
            playlist: "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1280x720\n" + a.upstream + "/media.m3u8\n",
          };
        }
        const prev = (a.relay_state && typeof a.relay_state === "object") ? a.relay_state : { polls: 0 };
        const polls = Number(prev.polls || 0) + 1;
        const lines = [
          "#EXTM3U",
          "#EXT-X-TARGETDURATION:2",
          "#EXT-X-MEDIA-SEQUENCE:" + polls,
          "#EXTINF:2.000,live",
          a.upstream + "/seg" + polls + ".ts",
        ];
        return {
          playlist: lines.join("\n") + "\n",
          state: { polls },
          in_ad_break: polls === 2,
          ads_skipped: 1,
        };
      },
    },
  },
});
`

func TestCustomAppHLSRelayEndToEnd(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/seg") {
			w.Header().Set("Content-Type", "video/mp2t")
			_, _ = w.Write([]byte("SEGMENT:" + r.URL.Path))
			return
		}
		http.NotFound(w, r)
	}))
	t.Cleanup(upstream.Close)

	e := newChatEnvServer(t, nil, func(s *Server) {
		s.CustomAppHLSListenAddr = "127.0.0.1:0"
		s.CustomAppHLSTransport = http.DefaultTransport
		s.CustomAppHLSAllowInsecureUpstream = true
		t.Cleanup(s.CloseCustomApps)
	})
	e.want("POST", "/custom-apps", map[string]any{
		"slug":     "feed",
		"name":     "Feed",
		"manifest": map[string]any{"entry": "app.tsx", "mcp_entry": "server.ts", "tool_scope": "app_only"},
		"files": map[string]string{
			"app.tsx":   "export default function App() { return null; }",
			"server.ts": hlsRelayAppServer,
		},
	}, http.StatusCreated)
	e.want("POST", "/custom-apps", map[string]any{
		"slug":     "other",
		"name":     "Other",
		"template": "blank",
	}, http.StatusCreated)

	call := func(tool string, args map[string]any) (int, map[string]any) {
		return e.do("POST", "/custom-apps/feed/invoke", map[string]any{
			"kind": "mcp", "connector": "self", "tool": tool, "arguments": args,
		})
	}

	// 1. app.media:relay is denied until allowed.
	code, out := call("start_relay", map[string]any{"upstream": upstream.URL})
	if code == http.StatusOK && out["status"] == "ok" {
		t.Fatalf("relay without permission succeeded: %v", out)
	}
	if !strings.Contains(fmt.Sprint(out), "app.media:relay") {
		t.Fatalf("denied relay = %d %v, want it to name app.media:relay", code, out)
	}

	// 2. Grant app.media:relay and start a relayed stream (with proxy_segments=true to test both playlists & segments).
	e.want("PATCH", "/custom-apps/feed", map[string]any{"capabilities": map[string]any{
		"app.sql:read": "allowed", "app.sql:write": "allowed", "app.media:relay": "allowed",
	}}, http.StatusOK)

	code, out = call("start_relay", map[string]any{"upstream": upstream.URL, "proxy_segments": true})
	started, _ := out["result"].(map[string]any)
	if code != http.StatusOK || started == nil {
		t.Fatalf("start_relay = %d %v", code, out)
	}
	id, _ := started["id"].(string)
	if started["play_url"] != "vesper-hls:"+id {
		t.Fatalf("play_url = %v", started["play_url"])
	}

	// 3. Host resolves the stream through the authenticated API; another app cannot see it.
	got := e.want("GET", "/custom-apps/feed/hls/"+id, nil, http.StatusOK)
	lanURL, _ := got["lan_url"].(string)
	if !strings.HasSuffix(lanURL, "/master.m3u8") {
		t.Fatalf("lan_url = %q", lanURL)
	}
	e.want("GET", "/custom-apps/other/hls/"+id, nil, http.StatusNotFound)
	e.want("GET", "/custom-apps/feed/hls/"+uuid.NewString(), nil, http.StatusNotFound)

	// 4. Unauthenticated LAN client (simulating Apple TV) fetches master, variant, and proxied segment.
	res, err := http.Get(lanURL)
	if err != nil {
		t.Fatalf("GET master %s: %v", lanURL, err)
	}
	masterBytes, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || !strings.Contains(string(masterBytes), "variant/0.m3u8") {
		t.Fatalf("master = %d %s", res.StatusCode, string(masterBytes))
	}

	variantURL := strings.TrimSuffix(lanURL, "master.m3u8") + "variant/0.m3u8"
	res, err = http.Get(variantURL)
	if err != nil {
		t.Fatalf("GET variant %s: %v", variantURL, err)
	}
	varBytes, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || !strings.Contains(string(varBytes), "#EXT-X-MEDIA-SEQUENCE:1") || !strings.Contains(string(varBytes), "../seg/1") {
		t.Fatalf("variant = %d %s", res.StatusCode, string(varBytes))
	}

	segURL := strings.TrimSuffix(lanURL, "master.m3u8") + "seg/1"
	res, err = http.Get(segURL)
	if err != nil {
		t.Fatalf("GET seg %s: %v", segURL, err)
	}
	segBytes, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || string(segBytes) != "SEGMENT:/seg1.ts" {
		t.Fatalf("seg = %d %q", res.StatusCode, string(segBytes))
	}

	// 5. Stopping via DELETE removes the stream; LAN URL is no longer served.
	e.want("DELETE", "/custom-apps/feed/hls/"+id, nil, http.StatusNoContent)
	e.want("GET", "/custom-apps/feed/hls/"+id, nil, http.StatusNotFound)
}
