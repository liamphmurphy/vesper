package customapps

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

const (
	mcpDiscoveryTimeout = 10 * time.Second
	mcpCallTimeout      = 2 * time.Minute
	maxWorkerLineBytes  = 8 << 20
	maxWorkerStderr     = 32 << 10
)

// ApprovalRequiredError indicates an interactive UI MCP call needs explicit
// user approval for a specific capability before proceeding.
type ApprovalRequiredError struct {
	Capability string `json:"capability"`
	Summary    string `json:"summary"`
}

func (e *ApprovalRequiredError) Error() string {
	if e.Summary != "" {
		return e.Summary
	}
	return fmt.Sprintf("approval required for %s", e.Capability)
}

// MCPCallContext supplies host-side dependencies and capability policy for one
// custom app MCP server invocation.
type MCPCallContext struct {
	WorkspaceID       uuid.UUID
	UserID            uuid.UUID
	Slug              string
	AppName           string
	Capabilities      Capabilities
	BundleJS          string
	Interactive       bool
	Approved          bool
	AlwaysAllow       bool
	OnGrantCapability func(ctx context.Context, capKey string) error
	Q                 *store.Queries
	Secrets           *usersecrets.Service
	SecretApprover    func(ctx context.Context, sec store.UserSecret, ck usersecrets.Checked, req usersecrets.Request) error
	SecretLogger      func(ctx context.Context, sec store.UserSecret, ck usersecrets.Checked, req usersecrets.Request, decision string, status *int32, msg string, redactions int, took time.Duration)
	SQLQuery          func(ctx context.Context, query string, params []any) (SQLResult, error)
	APICall           func(ctx context.Context, method, rawPath string, body any) (any, error)
	LookupIP          func(ctx context.Context, host string) ([]net.IP, error)
	PublicFetch       func(ctx context.Context, req usersecrets.Request) (usersecrets.Response, error)
	NodeBinary        string
}

type workerInitMsg struct {
	Type      string         `json:"type"`
	Op        string         `json:"op"`
	Tool      string         `json:"tool,omitempty"`
	Arguments map[string]any `json:"arguments,omitempty"`
}

type workerOutMsg struct {
	Type             string                 `json:"type"`
	ID               int64                  `json:"id,omitempty"`
	Method           string                 `json:"method,omitempty"`
	Params           json.RawMessage        `json:"params,omitempty"`
	OK               bool                   `json:"ok,omitempty"`
	Result           json.RawMessage        `json:"result,omitempty"`
	Error            string                 `json:"error,omitempty"`
	ApprovalRequired *ApprovalRequiredError `json:"approval_required,omitempty"`
}

type workerRPCResult struct {
	Type             string                 `json:"type"`
	ID               int64                  `json:"id"`
	OK               bool                   `json:"ok"`
	Result           any                    `json:"result,omitempty"`
	Error            string                 `json:"error,omitempty"`
	ApprovalRequired *ApprovalRequiredError `json:"approval_required,omitempty"`
}

// ExtractMCPTools runs a freshly bundled custom app MCP server under Node's
// permission sandbox with all host RPCs denied to validate and extract its tool list.
func ExtractMCPTools(ctx context.Context, nodeBinary, bundleJS string) ([]MCPToolSpec, error) {
	if strings.TrimSpace(bundleJS) == "" {
		return nil, nil
	}
	tctx, cancel := context.WithTimeout(ctx, mcpDiscoveryTimeout)
	defer cancel()

	raw, err := runMCPWorker(tctx, nodeBinary, bundleJS, workerInitMsg{
		Type: "init",
		Op:   "list_tools",
	}, func(_ context.Context, _ string, _ json.RawMessage) (any, error) {
		return nil, errors.New("host RPC calls are not permitted during tool discovery")
	})
	if err != nil {
		return nil, apperr.Invalid("files", "MCP server load error: %v", err)
	}
	var parsed struct {
		Tools []MCPToolSpec `json:"tools"`
	}
	if err := json.Unmarshal(raw, &parsed); err != nil {
		return nil, apperr.Invalid("files", "invalid MCP tool manifest: %v", err)
	}
	if len(parsed.Tools) == 0 {
		return nil, apperr.Invalid("files", "MCP server must export at least one tool")
	}
	seen := make(map[string]struct{}, len(parsed.Tools))
	for i := range parsed.Tools {
		t := &parsed.Tools[i]
		t.Name = strings.TrimSpace(t.Name)
		t.Description = strings.TrimSpace(t.Description)
		if !toolRe.MatchString(t.Name) {
			return nil, apperr.Invalid("files", "invalid MCP tool name %q", t.Name)
		}
		if _, dup := seen[t.Name]; dup {
			return nil, apperr.Invalid("files", "duplicate MCP tool %q", t.Name)
		}
		seen[t.Name] = struct{}{}
		if t.Description == "" {
			return nil, apperr.Invalid("files", "MCP tool %q must have a non-empty description", t.Name)
		}
		if t.InputSchema == nil {
			t.InputSchema = map[string]any{"type": "object", "properties": map[string]any{}}
		}
		if t.InputSchema["type"] != "object" {
			t.InputSchema["type"] = "object"
		}
	}
	return parsed.Tools, nil
}

// CallMCPTool executes a named tool inside a sandboxed Node v24 permission worker
// and services capability-gated host RPCs over stdio.
func CallMCPTool(ctx context.Context, mc MCPCallContext, tool string, args map[string]any) (any, error) {
	if strings.TrimSpace(mc.BundleJS) == "" {
		return nil, apperr.Conflict("custom app %q does not define an MCP server", mc.Slug)
	}
	if args == nil {
		args = map[string]any{}
	}
	tctx := ctx
	var cancel context.CancelFunc
	if _, hasDeadline := ctx.Deadline(); !hasDeadline {
		tctx, cancel = context.WithTimeout(ctx, mcpCallTimeout)
		defer cancel()
	}
	raw, err := runMCPWorker(tctx, mc.NodeBinary, mc.BundleJS, workerInitMsg{
		Type:      "init",
		Op:        "call_tool",
		Tool:      tool,
		Arguments: args,
	}, func(rpcCtx context.Context, method string, params json.RawMessage) (any, error) {
		return handleWorkerRPC(rpcCtx, &mc, method, params)
	})
	if err != nil {
		return nil, err
	}
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var out any
	if err := json.Unmarshal(raw, &out); err != nil {
		return string(raw), nil
	}
	return out, nil
}

func runMCPWorker(
	ctx context.Context,
	nodeBinary string,
	bundleJS string,
	initMsg workerInitMsg,
	onRPC func(context.Context, string, json.RawMessage) (any, error),
) (json.RawMessage, error) {
	bin := strings.TrimSpace(nodeBinary)
	if bin == "" {
		var err error
		bin, err = exec.LookPath("node")
		if err != nil {
			return nil, apperr.Conflict("node runtime is required to run custom app MCP servers")
		}
	}
	tmpDir, err := os.MkdirTemp("", "vesper-app-mcp-*")
	if err != nil {
		return nil, err
	}
	defer os.RemoveAll(tmpDir)
	realTmpDir := tmpDir
	if resolved, err := filepath.EvalSymlinks(tmpDir); err == nil {
		realTmpDir = resolved
	}

	bundlePath := filepath.Join(realTmpDir, "server.cjs")
	if err := os.WriteFile(bundlePath, []byte(bundleJS), 0o400); err != nil {
		return nil, err
	}

	cmd := exec.CommandContext(ctx, bin, "--permission", "--preserve-symlinks-main", "--allow-fs-read="+realTmpDir, bundlePath)
	cmd.Dir = realTmpDir
	cmd.Env = []string{"NODE_NO_WARNINGS=1", "TZ=UTC"}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	var stderr limitedBuffer
	stderr.limit = maxWorkerStderr
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start MCP worker: %w", err)
	}

	writeLine := func(v any) error {
		b, err := json.Marshal(v)
		if err != nil {
			return err
		}
		_, err = stdin.Write(append(b, '\n'))
		return err
	}

	if err := writeLine(initMsg); err != nil {
		_ = stdin.Close()
		_ = cmd.Wait()
		return nil, fmt.Errorf("send worker init: %w", err)
	}

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 0, 64<<10), maxWorkerLineBytes)

	var finalResult json.RawMessage
	var workerErr error

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}
		var msg workerOutMsg
		if err := json.Unmarshal([]byte(line), &msg); err != nil {
			workerErr = fmt.Errorf("invalid worker output: %w", err)
			break
		}
		switch msg.Type {
		case "rpc":
			res, rpcErr := onRPC(ctx, msg.Method, msg.Params)
			reply := workerRPCResult{Type: "rpc_result", ID: msg.ID, OK: rpcErr == nil}
			if rpcErr != nil {
				var appReq *ApprovalRequiredError
				if errors.As(rpcErr, &appReq) {
					reply.ApprovalRequired = appReq
				}
				reply.Error = rpcErr.Error()
			} else {
				reply.Result = res
			}
			if werr := writeLine(reply); werr != nil {
				workerErr = fmt.Errorf("reply to worker RPC: %w", werr)
			}
		case "done":
			if msg.OK {
				finalResult = msg.Result
			} else if msg.ApprovalRequired != nil {
				workerErr = msg.ApprovalRequired
			} else if msg.Error != "" {
				workerErr = errors.New(msg.Error)
			} else {
				workerErr = errors.New("MCP tool failed")
			}
		default:
			workerErr = fmt.Errorf("unknown worker message type %q", msg.Type)
		}
		if msg.Type == "done" || workerErr != nil {
			break
		}
	}

	_ = stdin.Close()
	if scanErr := scanner.Err(); scanErr != nil && workerErr == nil {
		workerErr = fmt.Errorf("read worker output: %w", scanErr)
	}
	waitErr := cmd.Wait()
	if workerErr != nil {
		return nil, workerErr
	}
	if ctx.Err() != nil {
		return nil, ctx.Err()
	}
	if waitErr != nil {
		detail := strings.TrimSpace(stderr.String())
		if detail != "" {
			return nil, fmt.Errorf("MCP worker failed: %s", detail)
		}
		return nil, fmt.Errorf("MCP worker failed: %w", waitErr)
	}
	if finalResult == nil && len(bytes.TrimSpace(finalResult)) == 0 && strings.TrimSpace(stderr.String()) != "" && workerErr == nil {
		// Standard error-free exit with undefined result returns null.
		return json.RawMessage("null"), nil
	}
	return finalResult, nil
}

func checkWorkerCapability(ctx context.Context, mc *MCPCallContext, capKey, summary string) error {
	mode := ModeFor(mc.Capabilities, capKey)
	switch mode {
	case agentdef.Allowed:
		return nil
	case agentdef.Denied:
		return fmt.Errorf("capability %s is denied for custom app %q", capKey, mc.Slug)
	case agentdef.RequiresApproval:
		if mc.Interactive {
			if !mc.Approved {
				return &ApprovalRequiredError{Capability: capKey, Summary: summary}
			}
			if mc.AlwaysAllow && mc.OnGrantCapability != nil {
				_ = mc.OnGrantCapability(ctx, capKey)
				if mc.Capabilities == nil {
					mc.Capabilities = Capabilities{}
				}
				mc.Capabilities[capKey] = agentdef.Allowed
			}
			return nil
		}
		return fmt.Errorf("capability %s requires approval for custom app %q; allow it in /apps/%s Permissions", capKey, mc.Slug, mc.Slug)
	default:
		return fmt.Errorf("capability %s is not allowed", capKey)
	}
}

func handleWorkerRPC(ctx context.Context, mc *MCPCallContext, method string, raw json.RawMessage) (any, error) {
	switch method {
	case "sql":
		var in struct {
			Query  string `json:"query"`
			Params []any  `json:"params"`
		}
		if err := json.Unmarshal(raw, &in); err != nil {
			return nil, err
		}
		if strings.TrimSpace(in.Query) == "" {
			return nil, apperr.Invalid("query", "SQL query is required")
		}
		ro, err := ClassifySQL(in.Query)
		if err != nil {
			return nil, err
		}
		capKey := "app.sql:write"
		summary := fmt.Sprintf("Run SQLite write query in %s", mc.AppName)
		if ro {
			capKey = "app.sql:read"
			summary = fmt.Sprintf("Run read-only SQLite query in %s", mc.AppName)
		}
		if err := checkWorkerCapability(ctx, mc, capKey, summary); err != nil {
			return nil, err
		}
		if mc.SQLQuery == nil {
			return nil, errors.New("SQL database is unavailable")
		}
		return mc.SQLQuery(ctx, in.Query, in.Params)

	case "api":
		var in struct {
			Method string `json:"method"`
			Path   string `json:"path"`
			Body   any    `json:"body"`
		}
		if err := json.Unmarshal(raw, &in); err != nil {
			return nil, err
		}
		m := strings.ToUpper(strings.TrimSpace(in.Method))
		if m == "" {
			m = http.MethodGet
		}
		capKey := "vesper.api:write"
		if m == http.MethodGet || m == http.MethodHead {
			capKey = "vesper.api:read"
		}
		if err := checkWorkerCapability(ctx, mc, capKey, fmt.Sprintf("%s %s", m, strings.TrimSpace(in.Path))); err != nil {
			return nil, err
		}
		if mc.APICall == nil {
			return nil, errors.New("Vesper API bridge is unavailable")
		}
		return mc.APICall(ctx, m, in.Path, in.Body)

	case "http_fetch":
		var in struct {
			URL     string            `json:"url"`
			Method  string            `json:"method"`
			Headers map[string]string `json:"headers"`
			Body    string            `json:"body"`
			JSON    any               `json:"json"`
		}
		if err := json.Unmarshal(raw, &in); err != nil {
			return nil, err
		}
		if err := checkWorkerCapability(ctx, mc, "app.http:outbound", fmt.Sprintf("Outbound HTTPS %s %s", strings.ToUpper(strings.TrimSpace(in.Method)), strings.TrimSpace(in.URL))); err != nil {
			return nil, err
		}
		req, err := toUserSecretRequest(in.Method, in.URL, in.Headers, in.Body, in.JSON)
		if err != nil {
			return nil, err
		}
		if mc.PublicFetch != nil {
			return mc.PublicFetch(ctx, req)
		}
		return usersecrets.SendPublic(ctx, req, mc.LookupIP)

	case "secret_fetch":
		var in struct {
			Secret  string            `json:"secret"`
			URL     string            `json:"url"`
			Method  string            `json:"method"`
			Headers map[string]string `json:"headers"`
			Body    string            `json:"body"`
			JSON    any               `json:"json"`
		}
		if err := json.Unmarshal(raw, &in); err != nil {
			return nil, err
		}
		handle := strings.TrimSpace(in.Secret)
		capKey := "secret:" + handle
		if handle == "*" || ValidCapabilityKey(capKey) != nil {
			return nil, apperr.Invalid("secret", "invalid secret handle %q", handle)
		}
		if err := checkWorkerCapability(ctx, mc, capKey, fmt.Sprintf("Send authenticated request using secret %q to %s", handle, strings.TrimSpace(in.URL))); err != nil {
			return nil, err
		}
		if mc.Secrets == nil || mc.Q == nil {
			return nil, errors.New("secrets service is unavailable")
		}
		sec, err := mc.Q.GetUserSecretByHandle(ctx, store.GetUserSecretByHandleParams{
			WorkspaceID: mc.WorkspaceID,
			UserID:      mc.UserID,
			Handle:      handle,
		})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, fmt.Errorf("no secret with handle %q", handle)
		}
		if err != nil {
			return nil, err
		}
		req, err := toUserSecretRequest(in.Method, in.URL, in.Headers, in.Body, in.JSON)
		if err != nil {
			return nil, err
		}
		ck, err := mc.Secrets.Check(sec, req)
		if err != nil {
			if mc.SecretLogger != nil {
				mc.SecretLogger(ctx, sec, ck, req, "blocked", nil, err.Error(), 0, 0)
			}
			return nil, err
		}
		decision := "auto"
		if ck.Policy == usersecrets.PolicyAsk {
			if mc.Interactive {
				if !mc.Approved {
					return nil, &ApprovalRequiredError{
						Capability: capKey,
						Summary:    fmt.Sprintf("Secret %q is set to ask; allow sending %s %s", handle, ck.Method, ck.URL.String()),
					}
				}
				decision = "approved"
			} else if mc.SecretApprover != nil {
				if err := mc.SecretApprover(ctx, sec, ck, req); err != nil {
					if mc.SecretLogger != nil {
						mc.SecretLogger(ctx, sec, ck, req, "denied", nil, err.Error(), 0, 0)
					}
					return nil, err
				}
				decision = "approved"
				// Reload secret in case rules changed while waiting for approval.
				sec, err = mc.Q.GetUserSecretByHandle(ctx, store.GetUserSecretByHandleParams{
					WorkspaceID: mc.WorkspaceID,
					UserID:      mc.UserID,
					Handle:      handle,
				})
				if err != nil {
					return nil, errors.New("access to this secret was removed while waiting")
				}
				if ck, err = mc.Secrets.Check(sec, req); err != nil {
					if mc.SecretLogger != nil {
						mc.SecretLogger(ctx, sec, ck, req, "blocked", nil, err.Error(), 0, 0)
					}
					return nil, err
				}
			} else {
				return nil, fmt.Errorf("secret %q is set to ask; set its policy to allow or run from a chat where it can ask", handle)
			}
		}
		val, err := mc.Secrets.Value(ctx, sec)
		if err != nil {
			var b *usersecrets.Blocked
			reason, msg := "couldn't decrypt the secret", errors.New("couldn't decrypt secret; ask the person to replace it")
			switch {
			case errors.As(err, &b):
				reason, msg = b.Reason, b
			case sec.Kind == usersecrets.KindOAuth:
				reason, msg = "couldn't refresh the token", errors.New("couldn't get a fresh token from the secret's sign-in provider; try again shortly")
			}
			if mc.SecretLogger != nil {
				mc.SecretLogger(ctx, sec, ck, req, "blocked", nil, reason, 0, 0)
			}
			return nil, msg
		}
		start := time.Now()
		res, err := mc.Secrets.Send(ctx, sec, val, ck, req)
		took := time.Since(start)
		if err != nil {
			if mc.SecretLogger != nil {
				var b *usersecrets.Blocked
				dec := decision
				if errors.As(err, &b) {
					dec = "blocked"
				}
				mc.SecretLogger(ctx, sec, ck, req, dec, nil, err.Error(), 0, took)
			}
			return nil, err
		}
		status := int32(res.Status)
		if mc.SecretLogger != nil {
			mc.SecretLogger(ctx, sec, ck, req, decision, &status, "", res.Redactions, took)
		}
		return res, nil

	default:
		return nil, fmt.Errorf("unknown host RPC method %q", method)
	}
}

func toUserSecretRequest(method, rawURL string, headers map[string]string, rawBody string, jsonBody any) (usersecrets.Request, error) {
	req := usersecrets.Request{
		Method:  strings.TrimSpace(method),
		URL:     strings.TrimSpace(rawURL),
		Headers: headers,
	}
	if jsonBody != nil {
		if rawBody != "" {
			return req, apperr.Invalid("body", "pass json or body, not both")
		}
		b, err := json.Marshal(jsonBody)
		if err != nil {
			return req, apperr.Invalid("json", "invalid json body")
		}
		req.Body = b
		req.ContentType = "application/json"
	} else if rawBody != "" {
		req.Body = []byte(rawBody)
	}
	return req, nil
}

type limitedBuffer struct {
	buf   bytes.Buffer
	limit int
}

func (l *limitedBuffer) Write(p []byte) (int, error) {
	rem := l.limit - l.buf.Len()
	if rem > 0 {
		if len(p) > rem {
			l.buf.Write(p[:rem])
		} else {
			l.buf.Write(p)
		}
	}
	return len(p), nil
}

func (l *limitedBuffer) String() string {
	return l.buf.String()
}
