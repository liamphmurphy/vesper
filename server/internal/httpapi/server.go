// Package httpapi implements the generated REST interfaces and mounts them
// alongside the other HTTP surfaces (MCP, SSE) on one mux.
package httpapi

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net"
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/gorilla/websocket"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/agentapi"
	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/connectors"
	"github.com/liamphmurphy/vesper/server/internal/customapps"
	"github.com/liamphmurphy/vesper/server/internal/designs"
	"github.com/liamphmurphy/vesper/server/internal/githubpr"
	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/realtime"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/speech"
	"github.com/liamphmurphy/vesper/server/internal/statemedia"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
	"github.com/liamphmurphy/vesper/server/internal/usage"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

// Pinger is anything the health endpoint can check.
type Pinger interface {
	Ping(ctx context.Context) error
}

type Server struct {
	Events  *realtime.Hub
	Version string
	Checks  map[string]Pinger
	Pool    *pgxpool.Pool
	Q       *store.Queries
	Tracker *tracker.Service
	Log     *slog.Logger

	Artifacts *artifacts.Service
	Agents    *agents.Service
	Secrets   *secrets.Service
	Runs      *runs.Service
	Wiki      *wiki.Service
	// PublicURL is how agents reach this server (the /mcp link shown with tokens).
	PublicURL      string
	Blobs          *blob.Store
	ArtifactBucket string
	// Exporter writes the whole-instance archive (Settings → Backup & move);
	// nil makes the export endpoint refuse.
	Exporter *transfer.Exporter
	// DesignWorker renders designs; nil leaves renders unavailable.
	DesignWorker *designs.Worker
	// Usage keeps harness plan-usage readings for the activity orb; nil
	// leaves the orb without usage.
	Usage *usage.Service
	// AnonymousAPI serves the person-facing API without a browser session.
	// Tests only: agent containers can reach the API, so a real server must
	// never trust a request just because it arrived.
	AnonymousAPI bool
	// CustomAppImageTransport overrides outbound transport for custom app image
	// proxying in tests; nil uses usersecrets.SafeTransport.
	CustomAppImageTransport http.RoundTripper
	// CustomAppWSDialer overrides outbound WebSocket dialing for custom app WS
	// proxying in tests; nil uses a gorilla/websocket.Dialer backed by usersecrets.SafeTransport.
	CustomAppWSDialer func(ctx context.Context, targetURL string, headers http.Header, protocols []string) (*websocket.Conn, *http.Response, error)
	// CustomAppMediaTransport overrides the transport custom app video downloads
	// use, for tests; nil uses usersecrets.SafeTransport.
	CustomAppMediaTransport http.RoundTripper
	// customAppMedia runs custom app video downloads; built on first use and
	// shared, because downloads outlive the request that starts them.
	customAppMedia     *customapps.Media
	customAppMediaOnce sync.Once
	// CustomAppHLSListenAddr, CustomAppHLSTransport, and
	// CustomAppHLSAllowInsecureUpstream override the LAN HLS relay in tests.
	CustomAppHLSListenAddr            string
	CustomAppHLSTransport             http.RoundTripper
	CustomAppHLSAllowInsecureUpstream bool
	customAppHLS                      *customapps.HLSRelay
	customAppHLSOnce                  sync.Once
	// CustomAppNixResolve overrides Nix package resolution, for tests.
	CustomAppNixResolve func(context.Context, string) (string, error)
	// CustomAppNixScratchDir sets where Nix job scratch directories live.
	CustomAppNixScratchDir string
	// CustomAppNixDisableSandbox disables Seatbelt sandboxing for Nix jobs, for tests.
	CustomAppNixDisableSandbox bool
	customAppNix               *customapps.Nix
	customAppNixOnce           sync.Once
	// GitHubAPIURL is GitHub's REST API for shipping approved pushes;
	// api.github.com when empty (tests point elsewhere).
	GitHubAPIURL string
	GitHubPR     *githubpr.Service
	// RunnerStarting reports whether an in-process runner (vesper app) is
	// still initializing before its first heartbeat.
	RunnerStarting func() bool

	// MediaRegistry overrides the registered media providers (tests inject fake).
	MediaRegistry *media.Registry
	// SpeechBroker shares live pre-synthesized lead clips between an in-process
	// runner and HTTP speech endpoints.
	SpeechBroker    *speech.Broker
	defaultMediaReg *media.Registry
	mediaRegOnce    sync.Once
	musicRun        *media.MusicRunner
	musicRunOnce    sync.Once
	speechQuota     media.SpeechQuota
	// StateMediaPack overrides looppack.Pack for persona state loops (tests
	// stub it so they don't need ffmpeg).
	StateMediaPack statemedia.PackFunc
	stateMediaRun  *statemedia.Runner
	stateMediaOnce sync.Once

	logins       loginLimiter
	apiOnce      sync.Once
	apiMux       http.Handler
	githubPROnce sync.Once
}

var _ api.StrictServerInterface = (*Server)(nil)

func (s *Server) mountAPIRoutes(mux *http.ServeMux) {
	s.knowledgeRoutes(mux)
	s.dockChatRoutes(mux)
	s.httpClientRoutes(mux)
	s.browserExtensionRoutes(mux)
	s.speechRoutes(mux)
	strict := api.NewStrictHandlerWithOptions(s, nil, api.StrictHTTPServerOptions{
		RequestErrorHandlerFunc: func(w http.ResponseWriter, r *http.Request, err error) {
			writeError(w, http.StatusBadRequest, api.Invalid, err.Error(), "")
		},
		ResponseErrorHandlerFunc: s.responseError,
	})
	api.HandlerWithOptions(strict, api.StdHTTPServerOptions{
		BaseURL:    "/api/v1",
		BaseRouter: mux,
		ErrorHandlerFunc: func(w http.ResponseWriter, r *http.Request, err error) {
			writeError(w, http.StatusBadRequest, api.Invalid, err.Error(), "")
		},
	})
}

func (s *Server) internalAPIHandler() http.Handler {
	s.apiOnce.Do(func() {
		mux := http.NewServeMux()
		s.mountAPIRoutes(mux)
		s.apiMux = mux
	})
	return s.apiMux
}

// Handler returns the root HTTP handler.
func (s *Server) Handler() http.Handler {
	if s.Log == nil {
		s.Log = slog.Default()
	}
	mux := http.NewServeMux()
	s.mountAPIRoutes(mux)
	mux.HandleFunc("GET /api/v1/custom-apps/{slug}/ws", s.handleCustomAppWS)
	if s.Events != nil {
		mux.Handle("GET /events", s.Events)
	}
	// Agent API (docs/dev/plan.md §5.2): bearer agent tokens, not the local user.
	deps := s.agentDeps()
	mux.Handle("/mcp", agentapi.MCPHandler(deps, s.Version, s.Log))
	connMCP := agentapi.ConnectorHandler(deps, s.Version)
	customAppMCP := agentapi.CustomAppMCPHandler(deps, s.Version)
	mux.HandleFunc("/mcp/connectors/{slug}", func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.PathValue("slug"), agentdef.CustomAppMCPPrefix) {
			customAppMCP.ServeHTTP(w, r)
			return
		}
		connMCP.ServeHTTP(w, r)
	})
	// More specific than {slug}, so it wins; no connector slug can contain "_".
	mux.Handle("/mcp/connectors/"+agentdef.SecretsMCPName, agentapi.SecretsHandler(deps, s.Version))
	mux.HandleFunc("GET "+connectors.CallbackPath, s.connectorCallback)
	mux.Handle("/api/v1/agent/", agentapi.RESTHandler(deps))
	mux.HandleFunc("GET "+SignInPath, s.signIn)
	mux.HandleFunc("GET "+AuthStatusPath, s.authStatus)
	mux.HandleFunc("POST "+AuthSetupPath, s.authSetup)
	mux.HandleFunc("POST "+AuthLoginPath, s.authLogin)
	return requestLog(s.Log, s.signedIn(s.localUser(mux)))
}

// personFacing reports whether a path serves the person's browser, as opposed
// to agents (bearer tokens on /mcp and /api/v1/agent/), probes, sign-in
// itself (the link and the password routes) and the connector OAuth callback (a cross-site redirect, so it
// arrives without the SameSite=Strict cookie; its one-time state protects it).
func personFacing(path string) bool {
	switch {
	case path == "/events":
		return true
	case !strings.HasPrefix(path, "/api/"):
		return false
	case path == "/api/v1/health", path == SignInPath, path == AuthStatusPath, path == AuthSetupPath, path == AuthLoginPath, path == connectors.CallbackPath, strings.HasPrefix(path, "/api/v1/agent/"):
		return false
	case strings.HasPrefix(path, browserExtensionPrefix):
		// The Safari extension: its own bearer token (browserExtensionAuth), not a session.
		return false
	}
	return true
}

// localUser attaches the acting user to every API request. There is one
// person for now (docs/dev/plan.md §5.4): a signed-in browser acts as the
// workspace's first user.
func (s *Server) localUser(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/api/v1/health" || !strings.HasPrefix(r.URL.Path, "/api/") || strings.HasPrefix(r.URL.Path, "/api/v1/agent/") {
			next.ServeHTTP(w, r)
			return
		}
		u, err := s.Q.GetLocalUser(r.Context())
		if errors.Is(err, pgx.ErrNoRows) {
			writeError(w, http.StatusServiceUnavailable, api.NoUser, "no workspace user yet: restart the API to seed one", "")
			return
		}
		if err != nil {
			s.Log.Error("local user lookup", "err", err)
			writeError(w, http.StatusInternalServerError, api.Internal, "internal error", "")
			return
		}
		next.ServeHTTP(w, r.WithContext(auth.WithUser(r.Context(), u)))
	})
}

func (s *Server) responseError(w http.ResponseWriter, r *http.Request, err error) {
	var ve *tracker.ValidationError
	var ce *apperr.ConflictError
	switch {
	case errors.As(err, &ve):
		writeError(w, http.StatusUnprocessableEntity, api.Invalid, ve.Error(), ve.Field)
	case errors.As(err, &ce):
		writeError(w, http.StatusConflict, api.Conflict, err.Error(), ce.Field)
	case errors.Is(err, secrets.ErrNoKey):
		writeError(w, http.StatusConflict, api.Conflict, "Set SECRETS_KEY (openssl rand -base64 32) and restart the API to store secrets", "")
	case errors.Is(err, tracker.ErrNotFound):
		writeError(w, http.StatusNotFound, api.NotFound, "not found", "")
	default:
		s.Log.Error("handler", "method", r.Method, "path", r.URL.Path, "err", err)
		writeError(w, http.StatusInternalServerError, api.Internal, "internal error", "")
	}
}

func writeError(w http.ResponseWriter, status int, code api.ErrorCode, msg, field string) {
	e := api.Error{Code: code, Message: msg}
	if field != "" {
		e.Field = &field
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(e)
}

func (s *Server) GetHealth(ctx context.Context, _ api.GetHealthRequestObject) (api.GetHealthResponseObject, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()

	var (
		mu     sync.Mutex
		wg     sync.WaitGroup
		checks = make(map[string]api.HealthCheck, len(s.Checks))
	)
	for name, p := range s.Checks {
		wg.Go(func() {
			start := time.Now()
			err := p.Ping(ctx)
			ms := int(time.Since(start).Milliseconds())
			c := api.HealthCheck{Ok: err == nil, LatencyMs: &ms}
			if err != nil {
				msg := err.Error()
				c.Error = &msg
			}
			mu.Lock()
			checks[name] = c
			mu.Unlock()
		})
	}
	wg.Wait()

	h := api.Health{Status: api.HealthStatusOk, Version: s.Version, Checks: checks}
	for _, c := range checks {
		if !c.Ok {
			h.Status = api.HealthStatusDegraded
			return api.GetHealth503JSONResponse(h), nil
		}
	}
	return api.GetHealth200JSONResponse(h), nil
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (r *statusRecorder) WriteHeader(code int) {
	r.status = code
	r.ResponseWriter.WriteHeader(code)
}

// Unwrap lets http.ResponseController reach the underlying writer
// (streaming MCP responses, deadlines).
func (r *statusRecorder) Unwrap() http.ResponseWriter { return r.ResponseWriter }

// Flush keeps SSE streaming working through the logging wrapper.
func (r *statusRecorder) Flush() {
	if f, ok := r.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

// Hijack keeps WebSocket upgrades working through the logging wrapper.
func (r *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	if h, ok := r.ResponseWriter.(http.Hijacker); ok {
		return h.Hijack()
	}
	return nil, nil, errors.New("http.Hijacker not supported")
}

func requestLog(log *slog.Logger, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		rec := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(rec, r)
		log.Info("http", "method", r.Method, "path", r.URL.Path, "status", rec.status, "ms", time.Since(start).Milliseconds())
	})
}
