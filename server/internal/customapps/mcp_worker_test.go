package customapps

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
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
