package harness

import (
	_ "embed"
	"fmt"
	"net/url"
	"path"
	"path/filepath"
	"strings"
)

//go:embed tool_hook.py
var toolHook []byte

//go:embed no_tools_hook.py
var noToolsHook []byte

const toolHookPath = ".lazyagents/tool-policy.py"

func hookEnvironment(ws Workspace) (map[string]string, error) {
	u, err := url.Parse(ws.MCPURL)
	if err != nil || u.Scheme == "" || u.Host == "" {
		return nil, fmt.Errorf("harness: invalid MCP URL")
	}
	u.Path = path.Join(strings.TrimSuffix(u.Path, "/mcp"), "api/v1/agent/tool-policy")
	u.RawQuery = ""
	u.Fragment = ""
	hookPath, err := filepath.Abs(filepath.Join(ws.Dir, toolHookPath))
	if err != nil {
		return nil, fmt.Errorf("harness: resolve policy hook path: %w", err)
	}
	// Hooks execute inside the workspace, so a relative workspace path would
	// otherwise be appended to itself. Container paths are already absolute.
	command := "python3 '" + strings.ReplaceAll(hookPath, "'", "'\"'\"'") + "'"
	return map[string]string{
		"LAZYAGENTS_POLICY_URL": u.String(), "LAZYAGENTS_POLICY_TOKEN": ws.Token,
		"LAZYAGENTS_POLICY_HOOK_PATH": hookPath, "LAZYAGENTS_POLICY_HOOK_COMMAND": command,
	}, nil
}
