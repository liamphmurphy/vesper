package customapps

import (
	"context"
	"encoding/base64"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

func TestBundleMCPServerRejectsExternalImports(t *testing.T) {
	for _, mod := range []string{"fs", "node:fs", "node:child_process", "https", "axios"} {
		_, err := BundleMCPServer("server.ts", map[string]string{
			"app.tsx":   "export default function App() { return null; }",
			"server.ts": "import x from " + `"` + mod + `"; export default x;`,
		})
		if err == nil || !strings.Contains(err.Error(), "external import") {
			t.Fatalf("expected external import rejection for %q, got %v", mod, err)
		}
	}
}

func TestBundleAndExtractMCPTools(t *testing.T) {
	files := map[string]string{
		"app.tsx":   "export default function App() { return null; }",
		"helper.ts": `export function greet(name: string) { return "hello " + name; }`,
		"server.ts": `
import { defineServer, sql } from "@vesper/server";
import { greet } from "./helper";

export default defineServer({
  tools: {
    hello_world: {
      description: "Say hello to a user",
      inputSchema: {
        type: "object",
        properties: { name: { type: "string" } },
        required: ["name"],
      },
      handler: async ({ name }: { name?: string }) => {
        console.log("stdout redirection check");
        return { message: greet(name || "world") };
      },
    },
  },
});`,
	}

	bundle, err := BundleMCPServer("server.ts", files)
	if err != nil {
		t.Fatalf("BundleMCPServer failed: %v", err)
	}
	tools, err := ExtractMCPTools(context.Background(), "", bundle)
	if err != nil {
		t.Fatalf("ExtractMCPTools failed: %v", err)
	}
	if len(tools) != 1 || tools[0].Name != "hello_world" || tools[0].Description != "Say hello to a user" {
		t.Fatalf("unexpected tools = %+v", tools)
	}

	res, err := CallMCPTool(context.Background(), MCPCallContext{
		Slug:     "test-app",
		AppName:  "Test",
		BundleJS: bundle,
	}, "hello_world", map[string]any{"name": "Liam"})
	if err != nil {
		t.Fatalf("CallMCPTool failed: %v", err)
	}
	m, _ := res.(map[string]any)
	if m["message"] != "hello Liam" {
		t.Fatalf("unexpected result = %#v", res)
	}
}

func TestMCPWorkerSandboxAndCapabilities(t *testing.T) {
	t.Setenv("VESPER_SENSITIVE_HOST_ENV", "do-not-leak-to-worker")

	files := map[string]string{
		"app.tsx": "export default function App() { return null; }",
		"server.ts": `
import { defineServer, sql, fetch } from "@vesper/server";

export default defineServer({
  tools: {
    check_env: {
      description: "Inspect worker environment and permission model",
      handler: async () => {
        const fsBlocked = (() => {
          try {
            const p = process;
            const mod = p.getBuiltinModule ? p.getBuiltinModule("fs") : null;
            if (!mod) return "no-builtin";
            mod.readFileSync("/etc/passwd", "utf8");
            return "read-allowed";
          } catch (e: any) {
            return String(e?.code || e?.message || e);
          }
        })();
        return {
          hasSecretEnv: Boolean(process.env.VESPER_SENSITIVE_HOST_ENV),
          envKeys: Object.keys(process.env).sort(),
          fsBlocked,
        };
      },
    },
    run_sql: {
      description: "Execute SQL via bridge",
      handler: async ({ query }: { query: string }) => {
        return await sql(query, []);
      },
    },
    call_outbound: {
      description: "Call outbound URL via bridge fetch",
      handler: async ({ url }: { url: string }) => {
        const res = await fetch(url);
        return { status: res.status, body: await res.text() };
      },
    },
  },
});`,
	}

	bundle, err := BundleMCPServer("server.ts", files)
	if err != nil {
		t.Fatalf("BundleMCPServer: %v", err)
	}

	// 1. Environment stripped & Node --permission blocks /etc/passwd reads.
	envRes, err := CallMCPTool(context.Background(), MCPCallContext{
		Slug:     "sec-app",
		AppName:  "Sec",
		BundleJS: bundle,
	}, "check_env", nil)
	if err != nil {
		t.Fatalf("check_env: %v", err)
	}
	envMap := envRes.(map[string]any)
	if envMap["hasSecretEnv"] != false {
		t.Fatalf("host env leaked into MCP worker: %#v", envMap)
	}
	if envMap["fsBlocked"] == "read-allowed" {
		t.Fatalf("expected Node --permission to block /etc/passwd read, got %#v", envMap)
	}

	// 2. app.sql:write denied blocks INSERT while app.sql:read allowed passes SELECT.
	_, err = CallMCPTool(context.Background(), MCPCallContext{
		Slug:         "sec-app",
		AppName:      "Sec",
		BundleJS:     bundle,
		Capabilities: Capabilities{"app.sql:read": agentdef.Allowed, "app.sql:write": agentdef.Denied},
		SQLQuery: func(_ context.Context, query string, _ []any) (SQLResult, error) {
			return SQLResult{Columns: []string{"n"}, Rows: []map[string]any{{"n": 1}}}, nil
		},
	}, "run_sql", map[string]any{"query": "INSERT INTO items VALUES (1)"})
	if err == nil || !strings.Contains(err.Error(), "app.sql:write is denied") {
		t.Fatalf("expected app.sql:write denial, got %v", err)
	}

	// 3. app.http:outbound interactive approval prompt -> approved executes SSRF check (blocks loopback).
	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("ok"))
	}))
	defer srv.Close()

	_, err = CallMCPTool(context.Background(), MCPCallContext{
		Slug:         "sec-app",
		AppName:      "Sec",
		BundleJS:     bundle,
		Capabilities: Capabilities{"app.http:outbound": agentdef.RequiresApproval},
		Interactive:  true,
		Approved:     false,
	}, "call_outbound", map[string]any{"url": srv.URL})
	var appReq *ApprovalRequiredError
	if !errors.As(err, &appReq) || appReq.Capability != "app.http:outbound" {
		t.Fatalf("expected ApprovalRequiredError for app.http:outbound, got %v", err)
	}

	_, err = CallMCPTool(context.Background(), MCPCallContext{
		Slug:         "sec-app",
		AppName:      "Sec",
		BundleJS:     bundle,
		Capabilities: Capabilities{"app.http:outbound": agentdef.Allowed},
		LookupIP:     func(context.Context, string) ([]net.IP, error) { return []net.IP{net.ParseIP("127.0.0.1")}, nil },
	}, "call_outbound", map[string]any{"url": "https://private.internal/test"})
	if err == nil || !strings.Contains(err.Error(), "private address") {
		t.Fatalf("expected SSRF private address block, got %v", err)
	}
}

func TestMCPWorkerFetchBinaryAndDataURL(t *testing.T) {
	pngBytes := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0x00, 0x01, 0x02, 0xff}
	pngB64 := base64.StdEncoding.EncodeToString(pngBytes)
	svgBody := `<svg xmlns="http://www.w3.org/2000/svg"/>`

	files := map[string]string{
		"app.tsx": "export default function App() { return null; }",
		"server.ts": `
import { defineServer, fetch } from "@vesper/server";

export default defineServer({
  tools: {
    fetch_asset: {
      description: "Fetch image or text asset and inspect binary helpers",
      handler: async ({ url, mime }: { url: string; mime?: string }) => {
        const res = await fetch(url);
        const ab = await res.arrayBuffer();
        const bytes = await res.bytes();
        return {
          status: res.status,
          contentType: res.contentType,
          body: await res.text(),
          bodyBase64: res.bodyBase64,
          base64: await res.base64(),
          dataUrl: await res.dataUrl(mime),
          abLen: ab.byteLength,
          bytesArray: Array.from(bytes),
        };
      },
    },
  },
});`,
	}

	bundle, err := BundleMCPServer("server.ts", files)
	if err != nil {
		t.Fatalf("BundleMCPServer: %v", err)
	}

	mc := MCPCallContext{
		Slug:         "news",
		AppName:      "News",
		BundleJS:     bundle,
		Capabilities: Capabilities{"app.http:outbound": agentdef.Allowed},
		PublicFetch: func(_ context.Context, req usersecrets.Request) (usersecrets.Response, error) {
			switch req.URL {
			case "https://cdn.example.test/thumb.png":
				return usersecrets.Response{
					Status:      200,
					Headers:     map[string]string{"Content-Type": "image/png; charset=binary"},
					ContentType: "image/png; charset=binary",
					Body:        "(12 bytes of image/png; charset=binary, not shown)",
					Binary:      true,
					BodyBase64:  pngB64,
				}, nil
			case "https://cdn.example.test/empty.png":
				return usersecrets.Response{
					Status:      200,
					Headers:     map[string]string{"Content-Type": "image/png"},
					ContentType: "image/png",
					Body:        "(0 bytes of image/png, not shown)",
					Binary:      true,
				}, nil
			default:
				return usersecrets.Response{
					Status:      200,
					Headers:     map[string]string{"Content-Type": "image/svg+xml"},
					ContentType: "image/svg+xml",
					Body:        svgBody,
				}, nil
			}
		},
	}

	// 1. Binary PNG returns exact base64, dataUrl, ArrayBuffer, and Uint8Array.
	res, err := CallMCPTool(context.Background(), mc, "fetch_asset", map[string]any{"url": "https://cdn.example.test/thumb.png"})
	if err != nil {
		t.Fatalf("thumb.png: %v", err)
	}
	m := res.(map[string]any)
	if m["base64"] != pngB64 || m["bodyBase64"] != pngB64 {
		t.Fatalf("unexpected base64 fields: %#v", m)
	}
	if m["dataUrl"] != "data:image/png;base64,"+pngB64 {
		t.Fatalf("unexpected dataUrl: %v", m["dataUrl"])
	}
	if int(m["abLen"].(float64)) != len(pngBytes) {
		t.Fatalf("abLen = %v, want %d", m["abLen"], len(pngBytes))
	}
	gotBytes := m["bytesArray"].([]any)
	if len(gotBytes) != len(pngBytes) {
		t.Fatalf("bytesArray len = %d, want %d", len(gotBytes), len(pngBytes))
	}
	for i, b := range pngBytes {
		if byte(gotBytes[i].(float64)) != b {
			t.Fatalf("byte[%d] = %v, want %d", i, gotBytes[i], b)
		}
	}

	// 2. Empty binary response decodes to 0 bytes (never encodes the placeholder summary).
	res, err = CallMCPTool(context.Background(), mc, "fetch_asset", map[string]any{"url": "https://cdn.example.test/empty.png"})
	if err != nil {
		t.Fatalf("empty.png: %v", err)
	}
	m = res.(map[string]any)
	if m["base64"] != "" || int(m["abLen"].(float64)) != 0 || m["dataUrl"] != "data:image/png;base64," {
		t.Fatalf("empty.png = %#v", m)
	}

	// 3. Textual SVG also supports base64() and dataUrl() with optional mime override.
	res, err = CallMCPTool(context.Background(), mc, "fetch_asset", map[string]any{
		"url":  "https://cdn.example.test/icon.svg",
		"mime": "image/svg+xml;charset=utf-8",
	})
	if err != nil {
		t.Fatalf("icon.svg: %v", err)
	}
	m = res.(map[string]any)
	svgB64 := base64.StdEncoding.EncodeToString([]byte(svgBody))
	if m["base64"] != svgB64 || m["dataUrl"] != "data:image/svg+xml;charset=utf-8;base64,"+svgB64 {
		t.Fatalf("icon.svg = %#v", m)
	}
}

// A tool result is one JSON line on the worker's stdout. The worker used to exit straight after
// writing it, before a write larger than the pipe buffer had flushed, so a big result (a ~1 MB
// video segment as base64) reached the host cut short as invalid JSON.
func TestMCPWorkerReturnsLargeResultsWhole(t *testing.T) {
	bundle, err := BundleMCPServer("server.ts", map[string]string{
		"app.tsx": "export default function App() { return null; }",
		"server.ts": `
import { defineServer } from "@vesper/server";
export default defineServer({
  tools: {
    big: { description: "big", inputSchema: { type: "object" }, handler: async () => ({ data: "x".repeat(3 * 1024 * 1024) + "end" }) },
  },
});`,
	})
	if err != nil {
		t.Fatalf("BundleMCPServer: %v", err)
	}
	res, err := CallMCPTool(context.Background(), MCPCallContext{Slug: "big-app", AppName: "Big", BundleJS: bundle}, "big", nil)
	if err != nil {
		t.Fatalf("CallMCPTool: %v", err)
	}
	data, _ := res.(map[string]any)["data"].(string)
	if len(data) != 3*1024*1024+3 || !strings.HasSuffix(data, "end") {
		t.Fatalf("result length = %d, want %d ending in \"end\"", len(data), 3*1024*1024+3)
	}
}

// A plain fetch may return up to 25 MB, about 33 MB once base64-encoded in a tool result, so the
// result line has to fit that (it used to stop at 8 MB).
func TestMCPWorkerReturnsFetchSizedResults(t *testing.T) {
	bundle, err := BundleMCPServer("server.ts", map[string]string{
		"app.tsx": "export default function App() { return null; }",
		"server.ts": `
import { defineServer } from "@vesper/server";
export default defineServer({
  tools: {
    big: { description: "big", inputSchema: { type: "object" }, handler: async () => ({ data: "x".repeat(34 * 1024 * 1024) }) },
  },
});`,
	})
	if err != nil {
		t.Fatalf("BundleMCPServer: %v", err)
	}
	res, err := CallMCPTool(context.Background(), MCPCallContext{Slug: "big-app", AppName: "Big", BundleJS: bundle}, "big", nil)
	if err != nil {
		t.Fatalf("CallMCPTool: %v", err)
	}
	if data, _ := res.(map[string]any)["data"].(string); len(data) != 34*1024*1024 {
		t.Fatalf("result length = %d, want %d", len(data), 34*1024*1024)
	}
}

// A result over the limit fails at once with a clear error, instead of the worker blocking on a
// pipe nobody reads until the call times out.
func TestMCPWorkerOversizedResultFailsFast(t *testing.T) {
	bundle, err := BundleMCPServer("server.ts", map[string]string{
		"app.tsx": "export default function App() { return null; }",
		"server.ts": `
import { defineServer } from "@vesper/server";
export default defineServer({
  tools: {
    huge: { description: "huge", inputSchema: { type: "object" }, handler: async () => ({ data: "x".repeat(45 * 1024 * 1024) }) },
  },
});`,
	})
	if err != nil {
		t.Fatalf("BundleMCPServer: %v", err)
	}
	start := time.Now()
	_, err = CallMCPTool(context.Background(), MCPCallContext{Slug: "huge-app", AppName: "Huge", BundleJS: bundle}, "huge", nil)
	if err == nil || !strings.Contains(err.Error(), "larger than the 40 MB limit") {
		t.Fatalf("err = %v, want the size limit error", err)
	}
	if took := time.Since(start); took > 20*time.Second {
		t.Fatalf("took %s to fail; it should fail as soon as the limit is hit", took)
	}
}
