package agentapi

import (
	"context"
	"encoding/json"
	"errors"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"log/slog"
	"net/http"
	"reflect"
	"slices"
	"strings"
	"time"

	"github.com/google/jsonschema-go/jsonschema"
	"github.com/google/uuid"
	"github.com/modelcontextprotocol/go-sdk/auth"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/broker"
	"github.com/liamphmurphy/vesper/server/internal/runs"
)

type mcpServer = *mcp.Server

func brokerFor(scope string) (broker.Action, bool) { return broker.For(scope) }

// inputSchema is In's inferred schema, except that a UUID is the string it
// decodes from rather than the 16-byte array it's stored as.
func inputSchema[In any]() *jsonschema.Schema {
	s, err := jsonschema.For[In](&jsonschema.ForOptions{TypeSchemas: map[reflect.Type]*jsonschema.Schema{
		reflect.TypeFor[uuid.UUID](): {Type: "string", Format: "uuid"},
	}})
	if err != nil {
		panic(err)
	}
	return s
}

// define binds a typed tool function to both transports.
func define[In any](name, desc string, fn func(context.Context, Deps, agents.Caller, In) (any, error)) Tool {
	original := fn
	fn = func(ctx context.Context, d Deps, c agents.Caller, in In) (any, error) {
		ctx = pageview.Run(ctx)
		if c.Agent.Kind == agents.KindAssistant && c.RunID == nil {
			return nil, apperr.Conflict("the Personal Assistant only works inside chats")
		}
		if c.RunID != nil {
			run, err := d.Q.GetRun(ctx, store.GetRunParams{ID: *c.RunID, WorkspaceID: c.Agent.WorkspaceID})
			if err != nil {
				return nil, err
			}
			if c.Agent.Kind == agents.KindAssistant && run.Purpose != "chat" && run.Purpose != runs.PurposeResearch && run.Purpose != runs.PurposeWorkflow && run.Purpose != runs.PurposeLearning {
				return nil, apperr.Conflict("the Personal Assistant only works inside chats")
			}
			switch {
			case run.Purpose == "chat":
				if !slices.Contains(chatTools, name) {
					return nil, apperr.Conflict("%s isn't available in chats", name)
				}
				session, err := d.Q.ChatSessionForRun(ctx, &run.ID)
				if err != nil {
					return nil, err
				}
				if session.WorkspaceID != c.Agent.WorkspaceID {
					return nil, apperr.ErrNotFound
				}
				ctx = pageview.IncludeAgents(pageview.Person(ctx, session.CreatedBy), true)
				if !slices.Contains(asideTools, name) && isAsideRun(run) {
					return nil, apperr.Conflict("%s isn't available in an aside, which only reads", name)
				}
				if slices.Contains([]string{"completed", "failed", "cancelled"}, run.State) {
					return nil, apperr.Conflict("chat run is %s", run.State)
				}
			case run.Purpose == runs.PurposeResearch:
				if !slices.Contains(researchTools, name) {
					return nil, apperr.Conflict("%s isn't available to researchers", name)
				}
				if run.State != "running" {
					return nil, apperr.Conflict("research run is %s", run.State)
				}
			case run.Purpose == runs.PurposeLearning:
				if !slices.Contains(learningTools, name) {
					return nil, apperr.Conflict("%s isn't available to course runs", name)
				}
				if run.State != "running" {
					return nil, apperr.Conflict("course run is %s", run.State)
				}
			case run.Purpose == runs.PurposeWorkflow:
				if !slices.Contains(workflowToolsFor(run), name) {
					return nil, apperr.Conflict("%s isn't available to workflow steps", name)
				}
				if run.State != "running" {
					return nil, apperr.Conflict("workflow step is %s", run.State)
				}
			case run.TicketID == nil:
				if !slices.Contains(planningTools, name) {
					return nil, apperr.Conflict("planning runs can read context and propose tickets only")
				}
				if run.State != "running" {
					return nil, apperr.Conflict("planning run is %s", run.State)
				}
			case run.ParentRunID != nil:
				// Delegated runs are served subagentTools only; refuse the rest by name.
				if !slices.Contains(subagentTools, name) {
					return nil, apperr.Conflict("%s isn't available to delegated runs", name)
				}
			}
		}
		return original(ctx, d, c, in)
	}
	return Tool{
		Name:        name,
		Description: desc,
		call: func(ctx context.Context, d Deps, c agents.Caller, raw json.RawMessage) (any, error) {
			var in In
			if len(raw) > 0 && string(raw) != "null" {
				if err := json.Unmarshal(raw, &in); err != nil {
					return nil, apperr.Invalid("arguments", "%v", err)
				}
			}
			return fn(ctx, d, c, in)
		},
		addMCP: func(srv mcpServer, d Deps) {
			tool := &mcp.Tool{Name: name, Description: desc, InputSchema: inputSchema[In]()}
			if slices.Contains(agentdef.EagerVesperTools, name) {
				// Claude Code otherwise defers every MCP tool behind tool search.
				tool.Meta = mcp.Meta{"anthropic/alwaysLoad": true}
			}
			mcp.AddTool(srv, tool,
				func(ctx context.Context, req *mcp.CallToolRequest, in In) (*mcp.CallToolResult, any, error) {
					c, ok := callerFrom(req)
					if !ok {
						return nil, nil, errors.New("unauthenticated")
					}
					out, err := fn(ctx, d, c, in)
					if err != nil {
						return nil, nil, toolError(d, name, c, err)
					}
					if res, ok := out.(mcpResultProvider); ok {
						r, err := res.mcpResult()
						return r, nil, err
					}
					return nil, out, nil
				})
		},
	}
}

var logger = slog.Default()

func toolError(d Deps, name string, c agents.Caller, err error) error {
	msg, internal := PublicError(err)
	if internal {
		logger.Error("agent tool", "tool", name, "agent", c.Agent.Handle, "err", err)
	}
	return errors.New(msg)
}

const callerKey = "caller"

func callerFrom(req *mcp.CallToolRequest) (agents.Caller, bool) {
	if req == nil || req.Extra == nil || req.Extra.TokenInfo == nil {
		return agents.Caller{}, false
	}
	c, ok := req.Extra.TokenInfo.Extra[callerKey].(agents.Caller)
	return c, ok
}

// verifier resolves an agent token on every request, so a revoked token stops
// working immediately, even mid-session.
func verifier(d Deps) auth.TokenVerifier {
	return func(ctx context.Context, token string, _ *http.Request) (*auth.TokenInfo, error) {
		c, err := agents.ResolveToken(ctx, d.Q, token)
		if err != nil {
			return nil, auth.ErrInvalidToken
		}
		return &auth.TokenInfo{
			UserID:     c.Agent.ID.String(), // binds MCP sessions to one agent
			Expiration: time.Now().Add(time.Hour),
			Extra:      map[string]any{callerKey: c},
		}, nil
	}
}

// Profiles: each caller kind gets its own tool set and instructions, so
// sub agents and planners don't pay tokens for tools and bookkeeping they
// must not use.
const (
	profileChat = "chat"
	// An aside reads, and changes nothing (runs.ChatCaps.Aside).
	profileAside    = "aside"
	profilePlanning = "planning"
	profileResearch = "research"
	profileLearning = "learning"
	profileWorkflow = "workflow"
	// A workflow step that reads the web gets no workspace tools.
	profileWorkflowWeb = "workflow-web"
	profileSubagent    = "subagent"
	profileLead        = "lead"
	profileFull        = "full"
)

// researchTools is the whole MCP surface of a researcher: the web comes from
// the harness, and it reads nothing in the workspace.
var researchTools = []string{"submit_findings"}

// learningTools is the whole MCP surface of a course run; which of them works
// depends on its role, which the course enforces.
var learningTools = []string{"submit_outline", "submit_lesson", "submit_review"}

// planningTools is the whole MCP surface of a planning run.
var planningTools = []string{"whoami", "get_ticket", "read_artifact", "search_knowledge", "read_page", "get_backlinks", "propose_tickets", "run_subagent", "run_subagents"}

// subagentTools is the whole MCP surface of a delegated run: its brief is
// already in hand, so no claiming, planning or step bookkeeping.
var subagentTools = []string{"get_ticket", "search_memory", "read_memory", "read_artifact", "create_artifact", "comment", "request_approval", "wait_for_approval", "run_gated", "await_human", "search_knowledge", "find_pattern", "propose_pattern", "list_proposed_patterns", "read_page", "write_note", "get_backlinks", "complete_run", "run_subagent", "run_subagents"}

// leadHidden are the tools a managed ticket run never needs: usage is reported
// by the runner, the ticket is already assigned, and changing personal memory belongs
// to chats with a person (a run may only search and read its slice, memory.ScopeRun).
var leadHidden = []string{"submit_outline", "submit_lesson", "submit_review", "submit_workflow_output", "list_workflows", "read_workflow", "propose_workflow_edit", "submit_findings", "submit_research_report", "report_usage", "next_ticket", "save_memory", "update_memory", "forget_memory", "search_chats", "read_chat", "search_repositories", "use_repository", "request_push", "set_chat_title", "list_tickets", "list_projects", "list_runs", "get_run", "generate_image", "start_video", "update_video", "finish_video", "fail_video", "start_audio", "update_audio", "finish_audio", "fail_audio", "generate_music", "save_file", "render_pdf", "start_playground", "playground_status", "stop_playground", "set_playground_openapi", "get_video_transcript", "propose_persona", "propose_persona_character", "list_saved_links", "save_link", "browser_snapshot", "search_library", "read_library_item", "list_inbox", "canvas_create", "canvas_patch", "canvas_read", "canvas_list", "canvas_comment", "canvas_reply", "design_list", "design_outline", "design_read", "design_render", "design_patch", "design_import", "design_comments", "design_comment", "design_reply", "design_create", "list_connectors", "list_secret_names", "create_space", "create_scheduled_task", "list_scheduled_tasks", "update_scheduled_task", "delete_scheduled_task", "create_learning_module", "list_learning_modules", "get_learning_progress", "design_flows", "design_components", "design_tokens", "design_inspect", "design_link_ticket", "list_custom_apps", "get_custom_app", "create_custom_app", "update_custom_app", "delete_custom_app", "custom_app_sql", "http_list_workspaces", "http_get_workspace", "http_save_request", "http_run_request"}

// profileFor must stay consistent with the checks in define().
func profileFor(run store.Run) string {
	switch {
	case run.Purpose == "chat":
		if isAsideRun(run) {
			return profileAside
		}
		return profileChat
	case run.Purpose == runs.PurposeResearch:
		return profileResearch
	case run.Purpose == runs.PurposeLearning:
		return profileLearning
	case run.Purpose == runs.PurposeWorkflow:
		if workflowStepHasWeb(run) {
			return profileWorkflowWeb
		}
		return profileWorkflow
	case run.TicketID == nil:
		return profilePlanning
	case run.ParentRunID != nil:
		return profileSubagent
	}
	return profileLead
}

func profileTools(profile string) []Tool {
	var out []Tool
	for _, t := range Tools {
		var ok bool
		switch profile {
		case profileChat:
			ok = slices.Contains(chatTools, t.Name)
		case profileAside:
			ok = slices.Contains(asideTools, t.Name)
		case profilePlanning:
			ok = slices.Contains(planningTools, t.Name)
		case profileResearch:
			ok = slices.Contains(researchTools, t.Name)
		case profileLearning:
			ok = slices.Contains(learningTools, t.Name)
		case profileWorkflow:
			ok = slices.Contains(workflowTools, t.Name)
		case profileWorkflowWeb:
			ok = slices.Contains(workflowWebTools, t.Name)
		case profileSubagent:
			ok = slices.Contains(subagentTools, t.Name)
		case profileLead:
			ok = !slices.Contains(leadHidden, t.Name)
		default:
			ok = true
		}
		if ok {
			out = append(out, t)
		}
	}
	return out
}

var profileInstructions = map[string]string{
	profileResearch:    `You are a researcher working for Vesper. Your question and AGENTS.md are your instructions; report through submit_findings.`,
	profileLearning:    `You are one step of building a Vesper learning module. Your task and AGENTS.md are your instructions; report through the submit tool they name.`,
	profileWorkflow:    `You are one step of a Vesper workflow. Your task and AGENTS.md are your instructions; report through submit_workflow_output.`,
	profileWorkflowWeb: `You are one step of a Vesper workflow. Your task and AGENTS.md are your instructions; report through submit_workflow_output.`,
	profileChat:        `You are answering a person in a Vesper chat. Your instructions are in AGENTS.md. Use the Vesper tools to look up project context and manage tickets when asked.`,
	profileAside:       `You are answering an aside in a Vesper chat: one question about a reply that is still running. Use the Vesper tools only to read; you can't change anything here.`,
	profilePlanning:    `This is a Vesper planning run. Follow the planner instructions returned by whoami: read context and finish with propose_tickets; do not claim a ticket.`,
	profileSubagent:    `You are a sub agent: a main agent delegated one task to you through Vesper. Your task brief and AGENTS.md are your instructions.`,
	profileLead: `You are working through Vesper, the tracker your team uses to supervise agents.
Your run instructions are in AGENTS.md, so you don't need whoami. Call claim_ticket; it returns the ticket, so skip get_ticket. Read only relevant attached context; reuse local context instead of fetching it again. post_plan once before editing (step 1 starts current); update_step(n, done) advances to the next step. Tick several criteria at once with check_criterion ns.
Scopes marked requires_approval need request_approval first; brokered ones (like db:migrate) run via
run_gated after approval. When you need a person, comment and call await_human.
Verify every acceptance criterion and check it only with evidence. Implement or delegate any gaps.
Once all criteria are satisfied, commit and push changes within your authorized scopes, record the PR with set_pr,
and finish with complete_run(status=done). Delegate a review only when the change is risky or large.`,
	profileFull: `You are working through Vesper, the tracker your team uses to supervise agents.
For planning runs, follow the planner instructions returned by whoami: read context and finish with propose_tickets; do not claim a ticket.
For ticket execution, start with whoami, then claim_ticket (it returns the ticket, so skip get_ticket). Read attached artifacts with read_artifact before
planning, then post_plan before editing anything and call update_step(n, done) as steps finish (done advances to the next step).
Scopes marked requires_approval need request_approval first; brokered ones (like db:migrate) run via
run_gated after approval. When you need a person, comment and call await_human.
Verify every acceptance criterion and check it only with evidence. Implement or delegate any gaps.
Once all criteria are satisfied, commit and push changes within your authorized scopes, record the PR with set_pr,
and finish with complete_run(status=done).`,
}

// MCPHandler serves the Agent API over streamable HTTP at /mcp.
func MCPHandler(d Deps, version string, log *slog.Logger) http.Handler {
	if log != nil {
		logger = log
	}
	servers := map[string]*mcp.Server{}
	for profile, text := range profileInstructions {
		srv := mcp.NewServer(&mcp.Implementation{Name: "lazyagents", Version: version}, &mcp.ServerOptions{Instructions: text})
		for _, t := range profileTools(profile) {
			t.addMCP(srv, d)
		}
		servers[profile] = srv
	}
	// The SDK calls this on every request, so keep it to one primary-key lookup.
	h := mcp.NewStreamableHTTPHandler(func(r *http.Request) *mcp.Server {
		info := auth.TokenInfoFromContext(r.Context())
		if info == nil {
			return nil
		}
		c, _ := info.Extra[callerKey].(agents.Caller)
		if c.RunID == nil {
			return servers[profileFull]
		}
		run, err := d.Q.GetRun(r.Context(), store.GetRunParams{ID: *c.RunID, WorkspaceID: c.Agent.WorkspaceID})
		if err != nil {
			return nil // fail closed: the SDK answers 400
		}
		return servers[profileFor(run)]
	}, &mcp.StreamableHTTPOptions{
		// Off, by the user's decision (2026-11-02). The SDK rejects non-localhost
		// Host headers on loopback connections (DNS rebinding), but run
		// containers reach an API on the host as host.docker.internal, which
		// Docker Desktop and OrbStack deliver over loopback. Rebinding needs an
		// endpoint that trusts ambient browser credentials; every /mcp request
		// must carry an agent bearer token, checked before this handler runs.
		DisableLocalhostProtection: true,
	})
	return auth.RequireBearerToken(verifier(d), nil)(h)
}

// RESTHandler mirrors the tools at POST /api/v1/agent/tools/{name} (JSON
// arguments in, JSON result out) and lists them at GET /api/v1/agent/tools.
func RESTHandler(d Deps) http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("POST /api/v1/agent/tool-policy", func(w http.ResponseWriter, r *http.Request) {
		c := r.Context().Value(restCallerKey{}).(agents.Caller)
		var in runs.ToolCheck
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&in); err != nil {
			writeJSON(w, 400, map[string]string{"decision": "deny", "reason": "Invalid tool policy input"})
			return
		}
		var out runs.ToolDecision
		var err error
		if rawJob := strings.TrimSpace(r.Header.Get("X-Vesper-Subagent-Job")); rawJob != "" {
			out, err = checkSubagentJobPolicy(r.Context(), d, c, rawJob, in)
		} else {
			out, err = d.Runs.CheckTool(r.Context(), c, in)
		}
		if err != nil {
			writeJSON(w, 503, map[string]string{"decision": "deny", "reason": "Tool policy unavailable; retry after the service recovers"})
			return
		}
		writeJSON(w, 200, out)
	})
	mux.HandleFunc("GET /api/v1/agent/tools", func(w http.ResponseWriter, r *http.Request) {
		list := make([]map[string]string, len(Tools))
		for i, t := range Tools {
			list[i] = map[string]string{"name": t.Name, "description": t.Description}
		}
		writeJSON(w, http.StatusOK, map[string]any{"tools": list})
	})
	mux.HandleFunc("POST /api/v1/agent/tools/{name}", func(w http.ResponseWriter, r *http.Request) {
		c := r.Context().Value(restCallerKey{}).(agents.Caller)
		t, ok := ByName[r.PathValue("name")]
		if !ok {
			writeJSON(w, http.StatusNotFound, map[string]string{"code": "not_found", "message": "no such tool"})
			return
		}
		var raw json.RawMessage
		if r.ContentLength != 0 {
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&raw); err != nil {
				writeJSON(w, http.StatusBadRequest, map[string]string{"code": "invalid", "message": "body must be JSON arguments"})
				return
			}
		}
		out, err := t.call(r.Context(), d, c, raw)
		if err != nil {
			msg, internal := PublicError(err)
			if internal {
				logger.Error("agent tool", "tool", t.Name, "agent", c.Agent.Handle, "err", err)
			}
			status := http.StatusInternalServerError
			switch {
			case errors.As(err, new(*apperr.ValidationError)):
				status = http.StatusUnprocessableEntity
			case errors.As(err, new(*apperr.ConflictError)):
				status = http.StatusConflict
			case msg == "not found":
				status = http.StatusNotFound
			}
			writeJSON(w, status, map[string]string{"code": "error", "message": msg})
			return
		}
		writeJSON(w, http.StatusOK, out)
	})
	return requireAgent(d, mux)
}

type restCallerKey struct{}

func requireAgent(d Deps, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
		if !ok {
			w.Header().Set("WWW-Authenticate", `Bearer realm="vesper"`)
			writeJSON(w, http.StatusUnauthorized, map[string]string{"code": "unauthenticated", "message": "send Authorization: Bearer vsp_…"})
			return
		}
		c, err := agents.ResolveToken(r.Context(), d.Q, strings.TrimSpace(tok))
		if err != nil {
			writeJSON(w, http.StatusUnauthorized, map[string]string{"code": "unauthenticated", "message": "invalid or revoked token"})
			return
		}
		next.ServeHTTP(w, r.WithContext(context.WithValue(r.Context(), restCallerKey{}, c)))
	})
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
