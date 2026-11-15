package usage

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// ErrSignedOut means the CLI has no plan login to read limits for.
var ErrSignedOut = errors.New("harness CLI is not signed in to a plan")

// ErrOutdated means the CLI predates the request.
var ErrOutdated = errors.New("harness CLI is too old to report usage")

// ProbeTimeout bounds one CLI check.
const ProbeTimeout = 25 * time.Second

// claudeArgs start Claude Code with nothing that could act: no tools, MCP
// servers, settings files, hooks or saved session. Only control requests are sent.
var claudeArgs = []string{"-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
	"--no-session-persistence", "--tools", "", "--strict-mcp-config", "--mcp-config", `{"mcpServers":{}}`,
	"--setting-sources", "", "--settings", `{"disableAllHooks":true}`}

// Argv is the command that answers a harness's usage check, by binary name.
func Argv(harness string) ([]string, error) {
	switch harness {
	case agentdef.HarnessClaudeCode:
		return append([]string{"claude"}, claudeArgs...), nil
	case agentdef.HarnessCodex:
		return []string{"codex", "app-server", "-c", "features.plugins=false"}, nil
	case agentdef.HarnessAntigravity:
		return []string{"agy", "-p", "/usage", "--output-format", "stream-json"}, nil
	}
	return nil, fmt.Errorf("unsupported harness")
}

// Converse asks a running Argv process for its allowance over its stdin and
// stdout.
func Converse(harness string, in io.Writer, out io.Reader) (Snapshot, error) {
	switch harness {
	case agentdef.HarnessClaudeCode:
		return converseClaude(in, out, time.Now)
	case agentdef.HarnessAntigravity:
		return converseAntigravity(out, time.Now)
	default:
		return converseCodex(in, out, time.Now)
	}
}

// Probe reads a harness's allowance through the fake backend's stand-in
// binary (RUNNER_CLAUDE_BIN, RUNNER_CODEX_BIN, RUNNER_ANTIGRAVITY_BIN), over
// the CLI's control protocol. Without one it refuses: the API never runs a real
// CLI on the host. It never sends a prompt, starts inference, or reads credentials.
func Probe(ctx context.Context, harness string) (Snapshot, error) {
	argv, err := Argv(harness)
	if err != nil {
		return Snapshot{}, err
	}
	override := map[string]string{
		agentdef.HarnessClaudeCode:  "RUNNER_CLAUDE_BIN",
		agentdef.HarnessCodex:       "RUNNER_CODEX_BIN",
		agentdef.HarnessAntigravity: "RUNNER_ANTIGRAVITY_BIN",
	}[harness]
	bin := os.Getenv(override)
	if bin == "" {
		return Snapshot{}, fmt.Errorf("usage: %s is not set; only a fake harness is checked on the host", override)
	}
	argv[0] = bin
	ctx, cancel := context.WithTimeout(ctx, ProbeTimeout)
	defer cancel()
	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	// Keep repository instructions, hooks and MCP configs out of the check.
	cmd.Dir = os.TempDir()
	cmd.Stderr = io.Discard
	cmd.Env = probeEnv(os.Environ())
	var stdin io.WriteCloser
	if harness != agentdef.HarnessAntigravity {
		var err error
		stdin, err = cmd.StdinPipe()
		if err != nil {
			return Snapshot{}, err
		}
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		if stdin != nil {
			stdin.Close()
		}
		return Snapshot{}, err
	}
	if err := cmd.Start(); err != nil {
		if stdin != nil {
			stdin.Close()
		}
		return Snapshot{}, fmt.Errorf("harness CLI could not start")
	}
	defer func() {
		if stdin != nil {
			stdin.Close()
		}
		cmd.Process.Kill()
		cmd.Wait()
	}()
	return Converse(harness, stdin, stdout)
}

// probeEnv keeps a parent agent session's variables from steering the check
// and stops the CLI from updating itself mid-check.
func probeEnv(base []string) []string {
	out := make([]string, 0, len(base)+1)
	for _, kv := range base {
		k, _, _ := strings.Cut(kv, "=")
		if k == "CLAUDECODE" || strings.HasPrefix(k, "CLAUDE_CODE_") {
			continue
		}
		out = append(out, kv)
	}
	return append(out, "DISABLE_AUTOUPDATER=1")
}

func scanner(r io.Reader) *bufio.Scanner {
	s := bufio.NewScanner(r)
	s.Buffer(make([]byte, 4096), 4<<20)
	return s
}

func converseClaude(in io.Writer, out io.Reader, now func() time.Time) (Snapshot, error) {
	send := json.NewEncoder(in)
	for _, req := range []map[string]any{
		{"type": "control_request", "request_id": "initialize", "request": map[string]any{"subtype": "initialize"}},
		{"type": "control_request", "request_id": "usage", "request": map[string]any{"subtype": "get_usage", "skip_behaviors": true}},
	} {
		if err := send.Encode(req); err != nil {
			return Snapshot{}, err
		}
	}
	s := scanner(out)
	for s.Scan() {
		var msg struct {
			Type     string `json:"type"`
			Response struct {
				Subtype   string          `json:"subtype"`
				RequestID string          `json:"request_id"`
				Error     string          `json:"error"`
				Response  json.RawMessage `json:"response"`
			} `json:"response"`
		}
		if json.Unmarshal(s.Bytes(), &msg) != nil || msg.Type != "control_response" || msg.Response.RequestID != "usage" {
			continue
		}
		if msg.Response.Subtype != "success" {
			e := strings.ToLower(msg.Response.Error)
			if strings.Contains(e, "unsupported") || strings.Contains(e, "unknown") {
				return Snapshot{}, ErrOutdated
			}
			return Snapshot{}, fmt.Errorf("claude usage request failed")
		}
		snap := ParseClaudeUsage(msg.Response.Response, now())
		if !snap.Available {
			return snap, ErrSignedOut
		}
		return snap, nil
	}
	return Snapshot{}, fmt.Errorf("claude ended before reporting usage")
}

func converseCodex(in io.Writer, out io.Reader, now func() time.Time) (Snapshot, error) {
	send := json.NewEncoder(in)
	if err := send.Encode(map[string]any{"id": 1, "method": "initialize", "params": map[string]any{"clientInfo": map[string]string{"name": "vesper_usage", "version": "1.0"}, "capabilities": map[string]any{}}}); err != nil {
		return Snapshot{}, err
	}
	s := scanner(out)
	for s.Scan() {
		var msg struct {
			ID    int `json:"id"`
			Error *struct {
				Code    int    `json:"code"`
				Message string `json:"message"`
			} `json:"error"`
			Result json.RawMessage `json:"result"`
		}
		if json.Unmarshal(s.Bytes(), &msg) != nil || msg.ID == 0 {
			continue // notifications
		}
		if msg.Error != nil {
			m := strings.ToLower(msg.Error.Message)
			switch {
			case msg.Error.Code == -32601 || strings.Contains(m, "unknown variant") || strings.Contains(m, "method not found"):
				return Snapshot{}, ErrOutdated
			case strings.Contains(m, "authentication") || strings.Contains(m, "not logged in"):
				return Snapshot{Harness: agentdef.HarnessCodex, ObservedAt: now(), Windows: []Window{}}, ErrSignedOut
			}
			return Snapshot{}, fmt.Errorf("codex usage request failed")
		}
		switch msg.ID {
		case 1:
			if err := send.Encode(map[string]any{"method": "initialized"}); err != nil {
				return Snapshot{}, err
			}
			if err := send.Encode(map[string]any{"id": 2, "method": "account/rateLimits/read"}); err != nil {
				return Snapshot{}, err
			}
		case 2:
			snap := ParseCodexRateLimits(msg.Result, now())
			if !snap.Available {
				return snap, fmt.Errorf("codex reported no plan limits")
			}
			return snap, nil
		}
	}
	return Snapshot{}, fmt.Errorf("codex ended before reporting usage")
}

func converseAntigravity(out io.Reader, now func() time.Time) (Snapshot, error) {
	s := scanner(out)
	for s.Scan() {
		line := s.Bytes()
		var msg struct {
			Event   string `json:"event"`
			Command *struct {
				Name string `json:"name"`
			} `json:"command"`
			Result *struct {
				Status  string `json:"status"`
				Error   string `json:"error"`
				Command *struct {
					Name string `json:"name"`
				} `json:"command"`
			} `json:"result"`
		}
		if json.Unmarshal(line, &msg) != nil {
			continue
		}
		if msg.Event == "command_result" && msg.Command != nil && msg.Command.Name == "usage" {
			return ParseAntigravityUsage(line, now()), nil
		}
		if msg.Event == "result" && msg.Result != nil {
			if strings.EqualFold(msg.Result.Status, "ERROR") {
				e := strings.ToLower(msg.Result.Error)
				switch {
				case strings.Contains(e, "auth") || strings.Contains(e, "login") || strings.Contains(e, "logged in") || strings.Contains(e, "sign in") || strings.Contains(e, "unauthorized") || strings.Contains(e, "credential"):
					return Snapshot{Harness: agentdef.HarnessAntigravity, ObservedAt: now(), Windows: []Window{}}, ErrSignedOut
				case strings.Contains(e, "unknown command") || strings.Contains(e, "unsupported"):
					return Snapshot{}, ErrOutdated
				}
				return Snapshot{}, fmt.Errorf("antigravity usage request failed")
			}
			if msg.Result.Command != nil && msg.Result.Command.Name == "usage" {
				return ParseAntigravityUsage(line, now()), nil
			}
			return Snapshot{Harness: agentdef.HarnessAntigravity, ObservedAt: now(), Windows: []Window{}}, nil
		}
	}
	return Snapshot{}, fmt.Errorf("antigravity ended before reporting usage")
}
