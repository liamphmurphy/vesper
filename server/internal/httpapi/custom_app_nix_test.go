package httpapi

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"
)

func TestCustomAppNixApprovalMountsAndMediaImport(t *testing.T) {
	pkgDir := t.TempDir()
	binDir := filepath.Join(pkgDir, "bin")
	if err := os.MkdirAll(binDir, 0o755); err != nil {
		t.Fatal(err)
	}
	clipBytes := append([]byte("\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2avc1mp41"), bytes.Repeat([]byte("frame"), 4000)...)
	script := `#!/bin/sh
set -eu
case "${1:-}" in
  start-clip)
    /bin/cat .mounts/cookies > cookie_seen.txt
    printf '\000\000\000\030ftypisom\000\000\002\000isomiso2avc1mp41' > clip.mp4
    i=0
    while [ "$i" -lt 4000 ]; do
      printf 'frame' >> clip.mp4
      i=$((i + 1))
    done
    ;;
  ping)
    printf 'pong\n'
    ;;
esac
`
	if err := os.WriteFile(filepath.Join(binDir, "demo"), []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	hostDir := t.TempDir()
	cookiesHostPath := filepath.Join(hostDir, "cookies.txt")
	if err := os.WriteFile(cookiesHostPath, []byte("SID=top-secret-host-cookie"), 0o600); err != nil {
		t.Fatal(err)
	}

	f := newFakeBlobs(t)
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Blobs = f.Store
		s.ArtifactBucket = avatarBucket
		s.CustomAppNixScratchDir = filepath.Join(t.TempDir(), "nix-scratch")
		s.CustomAppNixResolve = func(_ context.Context, pkg string) (string, error) {
			if pkg == "demo" {
				return pkgDir, nil
			}
			return "", fmt.Errorf("unknown package %s", pkg)
		}
		t.Cleanup(s.CloseCustomApps)
	})

	const nixServer = `import { defineServer, nix, media } from "@vesper/server";
export default defineServer({
  tools: {
    start_clip: {
      description: "Start background Nix job reading cookies mount",
      inputSchema: { type: "object" },
      handler: async () => nix.start({ packages: ["demo"], command: "demo", args: ["start-clip"], mounts: ["cookies"] }),
    },
    check_job: {
      description: "Check job status",
      inputSchema: { type: "object" },
      handler: async (a: any) => nix.status(a.id),
    },
    read_job_file: {
      description: "Read file from job",
      inputSchema: { type: "object" },
      handler: async (a: any) => nix.readFile(a.id, a.path),
    },
    import_clip: {
      description: "Import produced MP4",
      inputSchema: { type: "object" },
      handler: async (a: any) => media.import(a.id, a.path),
    },
  },
});
`

	// 1. Create app requesting nix:demo:allowed and mount "cookies".
	// nix:demo must be capped at requires_approval.
	created := e.want("POST", "/custom-apps", map[string]any{
		"slug": "feed",
		"name": "Feed",
		"manifest": map[string]any{
			"entry":      "app.tsx",
			"mcp_entry":  "server.ts",
			"tool_scope": "chats",
			"requested_capabilities": map[string]any{
				"nix:demo":           "allowed",
				"app.media:download": "allowed",
			},
			"requested_mounts": []map[string]any{
				{"name": "cookies", "description": "YouTube cookies.txt"},
			},
		},
		"files": map[string]string{
			"app.tsx":   "export default function App() { return null; }",
			"server.ts": nixServer,
		},
	}, http.StatusCreated)
	caps := created["capabilities"].(map[string]any)
	if caps["nix:demo"] != "requires_approval" {
		t.Fatalf("nix:demo cap = %v, want requires_approval", caps["nix:demo"])
	}

	// 2. Invoking start_clip prompts for approval of nix:demo; always_allow persists "allowed".
	prompt := e.want("POST", "/custom-apps/feed/invoke", map[string]any{
		"kind":      "mcp",
		"connector": "self",
		"tool":      "start_clip",
	}, http.StatusOK)
	if prompt["status"] != "approval_required" || prompt["capability"] != "nix:demo" {
		t.Fatalf("expected approval_required for nix:demo, got %v", prompt)
	}

	// Even once approved, missing mount returns conflict naming Permissions.
	code, missingMount := e.do("POST", "/custom-apps/feed/invoke", map[string]any{
		"kind":         "mcp",
		"connector":    "self",
		"tool":         "start_clip",
		"approved":     true,
		"always_allow": true,
	})
	if code == http.StatusOK || !strings.Contains(fmt.Sprint(missingMount), "Permissions") {
		t.Fatalf("expected missing mount error, got %d %v", code, missingMount)
	}
	detail := e.want("GET", "/custom-apps/feed", nil, http.StatusOK)
	if detail["capabilities"].(map[string]any)["nix:demo"] != "allowed" {
		t.Fatalf("expected nix:demo persisted as allowed, got %v", detail["capabilities"])
	}

	// 3. Configure mount + allow app.media:download via PATCH, then run job + import clip.
	e.want("PATCH", "/custom-apps/feed", map[string]any{
		"mounts": map[string]string{"cookies": cookiesHostPath},
		"capabilities": map[string]any{
			"app.sql:read":       "allowed",
			"app.sql:write":      "allowed",
			"nix:demo":           "allowed",
			"app.media:download": "allowed",
		},
	}, http.StatusOK)

	started := e.want("POST", "/custom-apps/feed/invoke", map[string]any{
		"kind":      "mcp",
		"connector": "self",
		"tool":      "start_clip",
	}, http.StatusOK)
	jobID := started["result"].(map[string]any)["id"].(string)

	var job map[string]any
	deadline := time.Now().Add(10 * time.Second)
	for time.Now().Before(deadline) {
		out := e.want("POST", "/custom-apps/feed/invoke", map[string]any{
			"kind":      "mcp",
			"connector": "self",
			"tool":      "check_job",
			"arguments": map[string]any{"id": jobID},
		}, http.StatusOK)
		job = out["result"].(map[string]any)
		if job["state"] != "resolving" && job["state"] != "running" {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if job["state"] != "done" {
		t.Fatalf("job did not finish cleanly: %v", job)
	}

	cookieRead := e.want("POST", "/custom-apps/feed/invoke", map[string]any{
		"kind":      "mcp",
		"connector": "self",
		"tool":      "read_job_file",
		"arguments": map[string]any{"id": jobID, "path": "cookie_seen.txt"},
	}, http.StatusOK)
	if cookieRead["result"].(map[string]any)["content"] != "SID=top-secret-host-cookie" {
		t.Fatalf("unexpected cookie_seen.txt = %v", cookieRead)
	}

	imported := e.want("POST", "/custom-apps/feed/invoke", map[string]any{
		"kind":      "mcp",
		"connector": "self",
		"tool":      "import_clip",
		"arguments": map[string]any{"id": jobID, "path": "clip.mp4"},
	}, http.StatusOK)
	mediaID := imported["result"].(map[string]any)["id"].(string)

	// Serve whole MP4 (200) and byte range (206).
	mediaPath := "/api/v1/custom-apps/feed/media/" + mediaID + "/content"
	res, err := http.Get(e.srv.URL + mediaPath)
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != http.StatusOK || res.Header.Get("Content-Type") != "video/mp4" || !bytes.Equal(body, clipBytes) {
		t.Fatalf("GET media = %d ct=%q len=%d want=%d", res.StatusCode, res.Header.Get("Content-Type"), len(body), len(clipBytes))
	}

	req, _ := http.NewRequest("GET", e.srv.URL+mediaPath, nil)
	req.Header.Set("Range", "bytes=8-15")
	rres, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	rbody, _ := io.ReadAll(rres.Body)
	rres.Body.Close()
	if rres.StatusCode != http.StatusPartialContent || !bytes.Equal(rbody, clipBytes[8:16]) {
		t.Fatalf("range GET media = %d %q", rres.StatusCode, rbody)
	}

	// 4. Agent API surfaces configured_mounts (names only, never host paths) and cannot overwrite mounts.
	chatToken := e.canvasToken(uuid.MustParse(e.newChat(nil)["id"].(string)))
	tcode, gotApp := e.tool(chatToken, "get_custom_app", map[string]any{"slug": "feed", "omit_files": true})
	if tcode != http.StatusOK {
		t.Fatalf("get_custom_app = %d %v", tcode, gotApp)
	}
	if strings.Contains(fmt.Sprint(gotApp), cookiesHostPath) {
		t.Fatalf("get_custom_app leaked raw host mount path: %v", gotApp)
	}
	cfgMounts, _ := gotApp["configured_mounts"].([]any)
	if len(cfgMounts) != 1 || cfgMounts[0] != "cookies" {
		t.Fatalf("configured_mounts = %v, want [cookies]", gotApp["configured_mounts"])
	}

	tcode, listOut := e.tool(chatToken, "list_custom_apps", map[string]any{})
	if tcode != http.StatusOK || strings.Contains(fmt.Sprint(listOut), cookiesHostPath) {
		t.Fatalf("list_custom_apps = %d %v", tcode, listOut)
	}

	// Updating via agent tool leaves host mounts intact.
	tcode, upOut := e.tool(chatToken, "update_custom_app", map[string]any{
		"slug":   "feed",
		"mounts": map[string]string{"cookies": "/etc/passwd"},
		"files":  map[string]string{"app.tsx": "export default function App() { return <div>v2</div>; }"},
	})
	if tcode != http.StatusOK {
		t.Fatalf("update_custom_app = %d %v", tcode, upOut)
	}
	afterDetail := e.want("GET", "/custom-apps/feed", nil, http.StatusOK)
	if afterDetail["mounts"].(map[string]any)["cookies"] != cookiesHostPath {
		t.Fatalf("agent update overwrote mounts: %v", afterDetail["mounts"])
	}
}
