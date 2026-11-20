package httpapi

import (
	"bytes"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

// mediaApp's server.ts exposes the media API as tools, the way Watch Feed uses it.
const mediaAppServer = `import { defineServer, media } from "@vesper/server";
export default defineServer({
  tools: {
    grab: { description: "Download a video", inputSchema: { type: "object" }, handler: async (a) => media.download(a.url) },
    check: { description: "Download status", inputSchema: { type: "object" }, handler: async (a) => media.status(a.id) },
    drop: { description: "Delete a download", inputSchema: { type: "object" }, handler: async (a) => media.delete(a.id) },
  },
});
`

type mediaTestEnv struct {
	*chatEnv
	site *httptest.Server
	clip []byte
}

func newMediaTestEnv(t *testing.T) *mediaTestEnv {
	t.Helper()
	clip := bytes.Repeat([]byte("frame"), 20_000)
	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/clip.mp4":
			w.Header().Set("Content-Type", "video/mp4")
			_, _ = w.Write(clip)
		default:
			w.Header().Set("Content-Type", "text/html")
			_, _ = w.Write([]byte("<html></html>"))
		}
	}))
	t.Cleanup(site.Close)
	f := newFakeBlobs(t)
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Blobs = f.Store
		s.ArtifactBucket = avatarBucket
		// The test site is on loopback, which the SSRF-checked transport refuses.
		s.CustomAppMediaTransport = http.DefaultTransport
		t.Cleanup(func() {
			if m := s.mediaDownloads(); m != nil {
				m.Close()
			}
		})
	})
	e.want("POST", "/custom-apps", map[string]any{
		"slug":     "feed",
		"name":     "Feed",
		"manifest": map[string]any{"entry": "app.tsx", "mcp_entry": "server.ts", "tool_scope": "app_only"},
		"files": map[string]string{
			"app.tsx":   "export default function App() { return null; }",
			"server.ts": mediaAppServer,
		},
	}, http.StatusCreated)
	return &mediaTestEnv{chatEnv: e, site: site, clip: clip}
}

func (e *mediaTestEnv) call(tool string, args map[string]any) (int, map[string]any) {
	e.t.Helper()
	return e.do("POST", "/custom-apps/feed/invoke", map[string]any{"kind": "mcp", "connector": "self", "tool": tool, "arguments": args})
}

func (e *mediaTestEnv) allowMedia(mode string) {
	e.t.Helper()
	e.want("PATCH", "/custom-apps/feed", map[string]any{"capabilities": map[string]any{
		"app.sql:read": "allowed", "app.sql:write": "allowed", "app.media:download": mode,
	}}, http.StatusOK)
}

// waitDone polls the app's check tool until the download leaves "downloading".
func (e *mediaTestEnv) waitDone(id string) map[string]any {
	e.t.Helper()
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		code, out := e.call("check", map[string]any{"id": id})
		item, _ := out["result"].(map[string]any)
		if code != http.StatusOK || item == nil {
			e.t.Fatalf("check = %d %v", code, out)
		}
		if item["state"] != "downloading" {
			return item
		}
		time.Sleep(20 * time.Millisecond)
	}
	e.t.Fatal("download did not finish")
	return nil
}

func TestCustomAppMediaDownloadNeedsPermission(t *testing.T) {
	e := newMediaTestEnv(t)

	// app.media:download is denied until the person allows it.
	code, out := e.call("grab", map[string]any{"url": e.site.URL + "/clip.mp4"})
	if code == http.StatusOK && out["status"] == "ok" {
		t.Fatalf("download without permission succeeded: %v", out)
	}
	if !strings.Contains(fmt.Sprint(out), "app.media:download") {
		t.Fatalf("denied download = %d %v, want it to name app.media:download", code, out)
	}

	e.allowMedia("allowed")
	code, out = e.call("grab", map[string]any{"url": e.site.URL + "/clip.mp4"})
	started, _ := out["result"].(map[string]any)
	if code != http.StatusOK || started == nil || started["state"] != "downloading" {
		t.Fatalf("grab = %d %v", code, out)
	}
	id := started["id"].(string)
	if started["play_url"] != "vesper-media:"+id {
		t.Fatalf("play_url = %v", started["play_url"])
	}
	done := e.waitDone(id)
	if done["state"] != "done" || done["bytes_done"] != float64(len(e.clip)) {
		t.Fatalf("finished as %v", done)
	}

	// A page is not a video file.
	code, out = e.call("grab", map[string]any{"url": e.site.URL + "/watch"})
	if code == http.StatusOK && out["status"] == "ok" {
		t.Fatalf("page download succeeded: %v", out)
	}

	code, out = e.call("drop", map[string]any{"id": id})
	if code != http.StatusOK {
		t.Fatalf("drop = %d %v", code, out)
	}
	if code, out = e.call("check", map[string]any{"id": id}); code == http.StatusOK && out["status"] == "ok" {
		t.Fatalf("check after drop = %d %v, want an error", code, out)
	}
}
