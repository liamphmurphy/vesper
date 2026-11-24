package customapps

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"maps"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/usersecrets"
)

const (
	hlsPlayPrefix = "vesper-hls:"

	maxHLSStreamsPerApp = 4
	maxHLSStreamsTotal  = 16
	maxHLSPlaylistBytes = 1 << 20  // 1 MiB
	maxHLSSegmentBytes  = 25 << 20 // 25 MiB
	maxHLSSegmentCache  = 256
	defaultHLSStreamTTL = 5 * time.Minute
	hlsMasterCacheTTL   = 10 * time.Second
	hlsMediaCacheTTL    = 750 * time.Millisecond
	hlsToolTimeout      = 20 * time.Second
	hlsSegmentTimeout   = 30 * time.Second
)

// HLSPlayURL is the playVideo URL for an active LAN HLS relay stream; the web
// player resolves it through Vesper's authenticated HLS endpoint before handing
// the LAN playlist URL to a native <video> element (for HLS + AirPlay).
func HLSPlayURL(id uuid.UUID) string { return hlsPlayPrefix + id.String() }

// HLSRelaySpec configures one relayed live HLS stream backed by an app's own
// MCP tool.
type HLSRelaySpec struct {
	Tool          string         `json:"tool"`
	Args          map[string]any `json:"args,omitempty"`
	ProxySegments bool           `json:"proxy_segments,omitempty"`
}

// HLSStream is the public metadata for one active relayed HLS stream.
type HLSStream struct {
	ID            uuid.UUID `json:"id"`
	PlayURL       string    `json:"play_url"`
	LANURL        string    `json:"lan_url"`
	LoopbackURL   string    `json:"loopback_url"`
	ProxySegments bool      `json:"proxy_segments"`
	InAdBreak     bool      `json:"in_ad_break"`
	AdsSkipped    int       `json:"ads_skipped"`
	CreatedAt     time.Time `json:"created_at"`
}

// HLSToolCaller invokes one of a custom app's MCP tools on behalf of an active
// relay stream.
type HLSToolCaller func(ctx context.Context, tool string, args map[string]any) (any, error)

// HLSRelay serves filtered HLS playlists for custom apps on a dedicated,
// ephemeral LAN HTTP listener separate from Vesper's loopback API listener.
// The listener starts only while at least one stream is active and closes as
// soon as the last stream stops or expires, so no LAN port stays open when
// idle and Vesper's API/auth are never exposed on the LAN.
type HLSRelay struct {
	// ListenAddr is the bind address for the dedicated LAN listener.
	// Defaults to "0.0.0.0:0" (ephemeral port on all interfaces). Tests can set
	// "127.0.0.1:0" to stay loopback-only.
	ListenAddr string
	// LANIPFunc returns the advertised LAN IPv4 address. Defaults to detectLANIPv4.
	LANIPFunc func() string
	// Transport overrides outbound fetches when ProxySegments is enabled, for
	// tests; nil uses usersecrets.SafeTransport.
	Transport http.RoundTripper
	// AllowInsecureUpstream permits http:// upstream variant/segment URIs in
	// tests; production strictly requires https://.
	AllowInsecureUpstream bool
	// StreamTTL is how long an idle stream stays registered. Defaults to 5m.
	StreamTTL time.Duration
	// MasterCacheTTL / MediaCacheTTL override playlist cache windows in tests.
	MasterCacheTTL time.Duration
	MediaCacheTTL  time.Duration

	mu           sync.Mutex
	streams      map[uuid.UUID]*relayStream
	byToken      map[string]*relayStream
	media        map[uuid.UUID]*relayMedia
	mediaByToken map[string]*relayMedia
	srv          *http.Server
	port         int
	sweepStop    chan struct{}
	closed       bool
}

type relayStream struct {
	id            uuid.UUID
	token         string
	appID         uuid.UUID
	tool          string
	baseArgs      map[string]any
	proxySegments bool
	callTool      HLSToolCaller
	createdAt     time.Time
	lastAccess    atomic.Int64

	statusMu   sync.RWMutex
	inAdBreak  bool
	adsSkipped int

	masterMu    sync.Mutex
	masterState any
	masterBody  string
	masterAt    time.Time

	varMu    sync.Mutex
	variants []*relayVariant
	varByURL map[string]int

	segMu       sync.Mutex
	segURLByKey map[string]string
	segKeyByURL map[string]string
	segOrder    []string
	segSeq      uint64
}

type relayVariant struct {
	index int
	url   string

	mu    sync.Mutex
	state any
	body  string
	at    time.Time
}

func (r *HLSRelay) ttl() time.Duration {
	if r.StreamTTL > 0 {
		return r.StreamTTL
	}
	return defaultHLSStreamTTL
}

func (r *HLSRelay) masterTTL() time.Duration {
	if r.MasterCacheTTL > 0 {
		return r.MasterCacheTTL
	}
	return hlsMasterCacheTTL
}

func (r *HLSRelay) mediaTTL() time.Duration {
	if r.MediaCacheTTL > 0 {
		return r.MediaCacheTTL
	}
	return hlsMediaCacheTTL
}

// Start registers a new relayed HLS stream, starts the ephemeral LAN listener
// if needed, and returns its play_url and LAN/loopback playlist URLs.
func (r *HLSRelay) Start(_ context.Context, appID uuid.UUID, spec HLSRelaySpec, callTool HLSToolCaller) (HLSStream, error) {
	if r == nil {
		return HLSStream{}, errors.New("HLS relay is unavailable")
	}
	tool := strings.TrimSpace(spec.Tool)
	if !toolRe.MatchString(tool) {
		return HLSStream{}, apperr.Invalid("tool", "valid tool name is required")
	}
	if callTool == nil {
		return HLSStream{}, errors.New("HLS relay tool caller is unavailable")
	}

	token, err := randomHex(16)
	if err != nil {
		return HLSStream{}, fmt.Errorf("generate stream token: %w", err)
	}
	now := time.Now().UTC()
	st := &relayStream{
		id:            uuid.New(),
		token:         token,
		appID:         appID,
		tool:          tool,
		baseArgs:      cloneArgs(spec.Args),
		proxySegments: spec.ProxySegments,
		callTool:      callTool,
		createdAt:     now,
		varByURL:      make(map[string]int),
		segURLByKey:   make(map[string]string),
		segKeyByURL:   make(map[string]string),
	}
	st.lastAccess.Store(now.UnixNano())

	r.mu.Lock()
	if r.closed {
		r.mu.Unlock()
		return HLSStream{}, errors.New("HLS relay is closed")
	}
	if r.streams == nil {
		r.streams = make(map[uuid.UUID]*relayStream)
		r.byToken = make(map[string]*relayStream)
	}
	r.evictOverflowLocked(appID)
	if err := r.ensureListenerLocked(); err != nil {
		r.mu.Unlock()
		return HLSStream{}, err
	}
	r.streams[st.id] = st
	r.byToken[st.token] = st
	port := r.port
	r.mu.Unlock()

	return r.snapshot(st, port), nil
}

// Get returns the active stream's metadata if it belongs to appID.
func (r *HLSRelay) Get(appID, id uuid.UUID) (HLSStream, error) {
	if r == nil {
		return HLSStream{}, apperr.ErrNotFound
	}
	r.mu.Lock()
	st := r.streams[id]
	port := r.port
	r.mu.Unlock()
	if st == nil || st.appID != appID {
		return HLSStream{}, apperr.ErrNotFound
	}
	st.lastAccess.Store(time.Now().UnixNano())
	return r.snapshot(st, port), nil
}

// Stop removes one active stream owned by appID and shuts down the LAN listener
// if no streams remain.
func (r *HLSRelay) Stop(appID, id uuid.UUID) error {
	if r == nil {
		return apperr.ErrNotFound
	}
	r.mu.Lock()
	st := r.streams[id]
	if st == nil || st.appID != appID {
		r.mu.Unlock()
		return apperr.ErrNotFound
	}
	delete(r.streams, id)
	delete(r.byToken, st.token)
	oldSrv, oldStop := r.detachIdleListenerLocked()
	r.mu.Unlock()

	shutdownRelayListener(oldSrv, oldStop)
	return nil
}

// Close terminates all active streams and local media relays and closes the LAN listener.
func (r *HLSRelay) Close() {
	if r == nil {
		return
	}
	r.mu.Lock()
	r.closed = true
	r.streams = nil
	r.byToken = nil
	r.media = nil
	r.mediaByToken = nil
	oldSrv := r.srv
	oldStop := r.sweepStop
	r.srv = nil
	r.sweepStop = nil
	r.port = 0
	r.mu.Unlock()

	shutdownRelayListener(oldSrv, oldStop)
}

func (r *HLSRelay) lanIP() string {
	var lanIP string
	if r.LANIPFunc != nil {
		lanIP = strings.TrimSpace(r.LANIPFunc())
	} else if host, _, err := net.SplitHostPort(strings.TrimSpace(r.ListenAddr)); err == nil && (host == "127.0.0.1" || host == "localhost" || host == "::1") {
		lanIP = "127.0.0.1"
	} else {
		lanIP = strings.TrimSpace(detectLANIPv4())
	}
	if lanIP == "" {
		lanIP = "127.0.0.1"
	}
	return lanIP
}

func (r *HLSRelay) snapshot(st *relayStream, port int) HLSStream {
	lanIP := r.lanIP()
	st.statusMu.RLock()
	inAd := st.inAdBreak
	skipped := st.adsSkipped
	st.statusMu.RUnlock()
	return HLSStream{
		ID:            st.id,
		PlayURL:       HLSPlayURL(st.id),
		LANURL:        fmt.Sprintf("http://%s:%d/hls/%s/master.m3u8", lanIP, port, st.token),
		LoopbackURL:   fmt.Sprintf("http://127.0.0.1:%d/hls/%s/master.m3u8", port, st.token),
		ProxySegments: st.proxySegments,
		InAdBreak:     inAd,
		AdsSkipped:    skipped,
		CreatedAt:     st.createdAt,
	}
}

// evictOverflowLocked drops the oldest stream for appID (or globally) when caps
// are reached so switching channels quickly never fails with a limit error.
func (r *HLSRelay) evictOverflowLocked(appID uuid.UUID) {
	for {
		var appCount int
		var oldestApp *relayStream
		for _, s := range r.streams {
			if s.appID == appID {
				appCount++
				if oldestApp == nil || s.lastAccess.Load() < oldestApp.lastAccess.Load() {
					oldestApp = s
				}
			}
		}
		if appCount < maxHLSStreamsPerApp || oldestApp == nil {
			break
		}
		delete(r.streams, oldestApp.id)
		delete(r.byToken, oldestApp.token)
	}
	for len(r.streams) >= maxHLSStreamsTotal {
		var oldest *relayStream
		for _, s := range r.streams {
			if oldest == nil || s.lastAccess.Load() < oldest.lastAccess.Load() {
				oldest = s
			}
		}
		if oldest == nil {
			break
		}
		delete(r.streams, oldest.id)
		delete(r.byToken, oldest.token)
	}
}

func (r *HLSRelay) ensureListenerLocked() error {
	if r.srv != nil {
		return nil
	}
	addr := strings.TrimSpace(r.ListenAddr)
	if addr == "" {
		addr = "0.0.0.0:0"
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return fmt.Errorf("start HLS relay listener on %s: %w", addr, err)
	}
	tcpAddr, ok := ln.Addr().(*net.TCPAddr)
	if !ok {
		_ = ln.Close()
		return errors.New("HLS relay listener did not bind a TCP port")
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/hls/", r.serveHTTP)
	mux.HandleFunc("/media/", r.serveMediaHTTP)
	srv := &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	stopCh := make(chan struct{})
	r.srv = srv
	r.port = tcpAddr.Port
	r.sweepStop = stopCh

	go func() {
		_ = srv.Serve(ln)
	}()
	go r.sweepLoop(stopCh)
	return nil
}

func (r *HLSRelay) detachIdleListenerLocked() (*http.Server, chan struct{}) {
	if len(r.streams) > 0 || len(r.media) > 0 {
		return nil, nil
	}
	oldSrv := r.srv
	oldStop := r.sweepStop
	r.srv = nil
	r.sweepStop = nil
	r.port = 0
	return oldSrv, oldStop
}

func shutdownRelayListener(srv *http.Server, stopCh chan struct{}) {
	if stopCh != nil {
		close(stopCh)
	}
	if srv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Shutdown(ctx)
	}
}

func (r *HLSRelay) sweepLoop(stopCh chan struct{}) {
	interval := r.ttl() / 4
	if interval < 20*time.Millisecond {
		interval = 20 * time.Millisecond
	}
	if interval > 30*time.Second {
		interval = 30 * time.Second
	}
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-stopCh:
			return
		case <-ticker.C:
			now := time.Now()
			cutoff := now.Add(-r.ttl()).UnixNano()
			mediaCutoff := now.Add(-r.mediaRelayTTL()).UnixNano()
			r.mu.Lock()
			for id, st := range r.streams {
				if st.lastAccess.Load() < cutoff {
					delete(r.streams, id)
					delete(r.byToken, st.token)
				}
			}
			for id, m := range r.media {
				if m.lastAccess.Load() < mediaCutoff {
					delete(r.media, id)
					delete(r.mediaByToken, m.token)
				}
			}
			oldSrv, oldStop := r.detachIdleListenerLocked()
			r.mu.Unlock()
			if oldSrv != nil || oldStop != nil {
				// Avoid deadlocking if oldStop == stopCh: shut down server in a goroutine.
				go func(s *http.Server, ch chan struct{}) {
					if ch != nil && ch != stopCh {
						close(ch)
					}
					if s != nil {
						ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
						defer cancel()
						_ = s.Shutdown(ctx)
					}
				}(oldSrv, oldStop)
				if oldStop == stopCh {
					return
				}
			}
		}
	}
}

func (r *HLSRelay) lookupByToken(token string) *relayStream {
	if token == "" {
		return nil
	}
	r.mu.Lock()
	st := r.byToken[token]
	r.mu.Unlock()
	if st != nil {
		st.lastAccess.Store(time.Now().UnixNano())
	}
	return st
}

func (r *HLSRelay) serveHTTP(w http.ResponseWriter, req *http.Request) {
	// Token-gated LAN endpoints serve playlists and public segments with no cookies;
	// permissive CORS lets both native WebKit <video> and browser hls.js clients play.
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Methods", "GET, HEAD, OPTIONS")
	w.Header().Set("Access-Control-Allow-Headers", "Range")
	w.Header().Set("Cache-Control", "no-store")
	if req.Method == http.MethodOptions {
		w.WriteHeader(http.StatusNoContent)
		return
	}
	if req.Method != http.MethodGet && req.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	rest := strings.TrimPrefix(req.URL.Path, "/hls/")
	parts := strings.Split(rest, "/")
	if len(parts) < 2 {
		http.NotFound(w, req)
		return
	}
	st := r.lookupByToken(parts[0])
	if st == nil {
		http.NotFound(w, req)
		return
	}

	switch {
	case len(parts) == 2 && parts[1] == "master.m3u8":
		r.serveMaster(w, req, st)
	case len(parts) == 3 && parts[1] == "variant" && strings.HasSuffix(parts[2], ".m3u8"):
		idxStr := strings.TrimSuffix(parts[2], ".m3u8")
		idx, err := strconv.Atoi(idxStr)
		if err != nil || idx < 0 {
			http.NotFound(w, req)
			return
		}
		r.serveVariant(w, req, st, idx)
	case len(parts) == 3 && parts[1] == "seg":
		r.serveSegment(w, req, st, parts[2])
	default:
		http.NotFound(w, req)
	}
}

func (r *HLSRelay) serveMaster(w http.ResponseWriter, req *http.Request, st *relayStream) {
	st.masterMu.Lock()
	defer st.masterMu.Unlock()

	if st.masterBody != "" && time.Since(st.masterAt) < r.masterTTL() {
		writePlaylist(w, req, st.masterBody)
		return
	}

	args := cloneArgs(st.baseArgs)
	args["relay_kind"] = "master"
	args["relay_state"] = st.masterState

	tctx, cancel := context.WithTimeout(req.Context(), hlsToolTimeout)
	defer cancel()
	raw, err := st.callTool(tctx, st.tool, args)
	if err != nil {
		http.Error(w, fmt.Sprintf("relay master failed: %v", err), http.StatusBadGateway)
		return
	}
	resp, err := parseRelayToolResult(raw)
	if err != nil {
		http.Error(w, fmt.Sprintf("invalid relay master result: %v", err), http.StatusBadGateway)
		return
	}
	if resp.HasState {
		st.masterState = resp.State
	}
	if strings.TrimSpace(resp.Playlist) == "" {
		w.Header().Set("Retry-After", "2")
		http.Error(w, "master playlist unavailable", http.StatusServiceUnavailable)
		return
	}

	rewritten, err := rewriteMasterPlaylist(resp.Playlist, resp.BaseURL, r.AllowInsecureUpstream, func(upstream string) int {
		return st.registerVariant(upstream)
	})
	if err != nil {
		http.Error(w, fmt.Sprintf("invalid master playlist: %v", err), http.StatusBadGateway)
		return
	}
	st.masterBody = rewritten
	st.masterAt = time.Now()
	writePlaylist(w, req, rewritten)
}

func (r *HLSRelay) serveVariant(w http.ResponseWriter, req *http.Request, st *relayStream, idx int) {
	v := st.getVariant(idx)
	if v == nil {
		http.NotFound(w, req)
		return
	}

	v.mu.Lock()
	defer v.mu.Unlock()

	if v.body != "" && time.Since(v.at) < r.mediaTTL() {
		writePlaylist(w, req, v.body)
		return
	}

	args := cloneArgs(st.baseArgs)
	args["relay_kind"] = "media"
	args["relay_url"] = v.url
	args["relay_variant"] = idx
	args["relay_state"] = v.state

	tctx, cancel := context.WithTimeout(req.Context(), hlsToolTimeout)
	defer cancel()
	raw, err := st.callTool(tctx, st.tool, args)
	if err != nil {
		http.Error(w, fmt.Sprintf("relay variant failed: %v", err), http.StatusBadGateway)
		return
	}
	resp, err := parseRelayToolResult(raw)
	if err != nil {
		http.Error(w, fmt.Sprintf("invalid relay variant result: %v", err), http.StatusBadGateway)
		return
	}
	if resp.HasState {
		v.state = resp.State
	}
	if resp.HasAdInfo {
		st.statusMu.Lock()
		st.inAdBreak = resp.InAdBreak
		if resp.AdsSkipped > 0 {
			st.adsSkipped += resp.AdsSkipped
		}
		st.statusMu.Unlock()
	}
	if strings.TrimSpace(resp.Playlist) == "" {
		w.Header().Set("Retry-After", "2")
		http.Error(w, "playlist temporarily empty", http.StatusServiceUnavailable)
		return
	}

	baseURL := resp.BaseURL
	if baseURL == "" {
		baseURL = v.url
	}
	var proxySeg func(string) string
	if st.proxySegments {
		proxySeg = func(upstream string) string {
			return "../seg/" + st.registerSegment(upstream)
		}
	}
	rewritten, err := rewriteMediaPlaylist(resp.Playlist, baseURL, r.AllowInsecureUpstream, proxySeg)
	if err != nil {
		http.Error(w, fmt.Sprintf("invalid media playlist: %v", err), http.StatusBadGateway)
		return
	}
	v.body = rewritten
	v.at = time.Now()
	writePlaylist(w, req, rewritten)
}

func (r *HLSRelay) serveSegment(w http.ResponseWriter, req *http.Request, st *relayStream, key string) {
	if !st.proxySegments {
		http.NotFound(w, req)
		return
	}
	upstream := st.lookupSegment(key)
	if upstream == "" {
		http.NotFound(w, req)
		return
	}

	rt := r.Transport
	if rt == nil {
		t := usersecrets.SafeTransport(false, nil)
		defer t.CloseIdleConnections()
		rt = t
	}
	client := &http.Client{
		Timeout:   hlsSegmentTimeout,
		Transport: rt,
		CheckRedirect: func(next *http.Request, via []*http.Request) error {
			if len(via) >= 5 {
				return errors.New("too many redirects")
			}
			if _, err := validateRelayUpstreamURL(next.URL.String(), "", r.AllowInsecureUpstream); err != nil {
				return err
			}
			return nil
		},
	}

	outReq, err := http.NewRequestWithContext(req.Context(), req.Method, upstream, nil)
	if err != nil {
		http.Error(w, "invalid segment request", http.StatusBadGateway)
		return
	}
	outReq.Header.Set("User-Agent", "Mozilla/5.0")
	if rng := req.Header.Get("Range"); rng != "" {
		outReq.Header.Set("Range", rng)
	}
	res, err := client.Do(outReq)
	if err != nil {
		http.Error(w, fmt.Sprintf("fetch segment: %v", err), http.StatusBadGateway)
		return
	}
	defer res.Body.Close()

	if res.StatusCode != http.StatusOK && res.StatusCode != http.StatusPartialContent {
		http.Error(w, fmt.Sprintf("upstream returned HTTP %d", res.StatusCode), http.StatusBadGateway)
		return
	}
	ct := res.Header.Get("Content-Type")
	if ct == "" {
		if strings.Contains(upstream, ".m4s") || strings.Contains(upstream, ".mp4") {
			ct = "video/mp4"
		} else {
			ct = "video/mp2t"
		}
	}
	w.Header().Set("Content-Type", ct)
	if cr := res.Header.Get("Content-Range"); cr != "" {
		w.Header().Set("Content-Range", cr)
	}
	if ar := res.Header.Get("Accept-Ranges"); ar != "" {
		w.Header().Set("Accept-Ranges", ar)
	}
	if res.ContentLength >= 0 && res.ContentLength <= maxHLSSegmentBytes {
		w.Header().Set("Content-Length", strconv.FormatInt(res.ContentLength, 10))
	}
	w.WriteHeader(res.StatusCode)
	if req.Method == http.MethodHead {
		return
	}
	_, _ = io.Copy(w, io.LimitReader(res.Body, maxHLSSegmentBytes))
}

func (st *relayStream) registerVariant(upstream string) int {
	st.varMu.Lock()
	defer st.varMu.Unlock()
	if idx, ok := st.varByURL[upstream]; ok {
		return idx
	}
	idx := len(st.variants)
	st.variants = append(st.variants, &relayVariant{index: idx, url: upstream})
	st.varByURL[upstream] = idx
	return idx
}

func (st *relayStream) getVariant(idx int) *relayVariant {
	st.varMu.Lock()
	defer st.varMu.Unlock()
	if idx < 0 || idx >= len(st.variants) {
		return nil
	}
	return st.variants[idx]
}

func (st *relayStream) registerSegment(upstream string) string {
	st.segMu.Lock()
	defer st.segMu.Unlock()
	if k, ok := st.segKeyByURL[upstream]; ok {
		return k
	}
	st.segSeq++
	k := strconv.FormatUint(st.segSeq, 36)
	st.segURLByKey[k] = upstream
	st.segKeyByURL[upstream] = k
	st.segOrder = append(st.segOrder, k)
	for len(st.segOrder) > maxHLSSegmentCache {
		evictKey := st.segOrder[0]
		st.segOrder = st.segOrder[1:]
		if u, ok := st.segURLByKey[evictKey]; ok {
			delete(st.segURLByKey, evictKey)
			delete(st.segKeyByURL, u)
		}
	}
	return k
}

func (st *relayStream) lookupSegment(key string) string {
	st.segMu.Lock()
	defer st.segMu.Unlock()
	return st.segURLByKey[key]
}

type relayToolResult struct {
	Playlist   string
	BaseURL    string
	State      any
	HasState   bool
	InAdBreak  bool
	AdsSkipped int
	HasAdInfo  bool
}

func parseRelayToolResult(raw any) (relayToolResult, error) {
	if s, ok := raw.(string); ok {
		return relayToolResult{Playlist: s}, nil
	}
	m, ok := raw.(map[string]any)
	if !ok {
		return relayToolResult{}, errors.New("tool must return an object with playlist")
	}
	var out relayToolResult
	if p, ok := m["playlist"].(string); ok {
		out.Playlist = p
	} else if t, ok := m["text"].(string); ok {
		out.Playlist = t
	}
	if b, ok := m["base_url"].(string); ok {
		out.BaseURL = strings.TrimSpace(b)
	}
	if st, ok := m["state"]; ok {
		out.State = st
		out.HasState = true
	}
	if v, ok := m["in_ad_break"].(bool); ok {
		out.InAdBreak = v
		out.HasAdInfo = true
	}
	if v, ok := m["ads_skipped"].(float64); ok && v >= 0 {
		out.AdsSkipped = int(v)
		out.HasAdInfo = true
	}
	return out, nil
}

func writePlaylist(w http.ResponseWriter, req *http.Request, body string) {
	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusOK)
	if req.Method == http.MethodHead {
		return
	}
	_, _ = io.WriteString(w, body)
}

var hlsAttrURIRe = regexp.MustCompile(`URI="([^"]+)"`)

func rewriteMasterPlaylist(text, baseURL string, allowInsecure bool, registerVariant func(string) int) (string, error) {
	if len(text) > maxHLSPlaylistBytes {
		return "", errors.New("master playlist exceeds size limit")
	}
	cleaned := strings.TrimPrefix(text, "\ufeff")
	lines := strings.Split(strings.ReplaceAll(cleaned, "\r\n", "\n"), "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "#EXTM3U" {
		return "", errors.New("master playlist must start with #EXTM3U")
	}
	out := make([]string, 0, len(lines))
	for _, rawLine := range lines {
		trimmed := strings.TrimSpace(rawLine)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			if strings.HasPrefix(trimmed, "#EXT-X-MEDIA:") || strings.HasPrefix(trimmed, "#EXT-X-I-FRAME-STREAM-INF:") {
				var rewriteErr error
				replaced := hlsAttrURIRe.ReplaceAllStringFunc(trimmed, func(match string) string {
					if rewriteErr != nil {
						return match
					}
					sub := hlsAttrURIRe.FindStringSubmatch(match)
					if len(sub) != 2 {
						return match
					}
					resolved, err := validateRelayUpstreamURL(sub[1], baseURL, allowInsecure)
					if err != nil {
						rewriteErr = err
						return match
					}
					idx := registerVariant(resolved)
					return fmt.Sprintf(`URI="variant/%d.m3u8"`, idx)
				})
				if rewriteErr != nil {
					return "", rewriteErr
				}
				out = append(out, replaced)
			} else {
				out = append(out, trimmed)
			}
			continue
		}
		resolved, err := validateRelayUpstreamURL(trimmed, baseURL, allowInsecure)
		if err != nil {
			return "", err
		}
		idx := registerVariant(resolved)
		out = append(out, fmt.Sprintf("variant/%d.m3u8", idx))
	}
	return strings.Join(out, "\n") + "\n", nil
}

func rewriteMediaPlaylist(text, baseURL string, allowInsecure bool, proxySeg func(string) string) (string, error) {
	if len(text) > maxHLSPlaylistBytes {
		return "", errors.New("media playlist exceeds size limit")
	}
	cleaned := strings.TrimPrefix(text, "\ufeff")
	lines := strings.Split(strings.ReplaceAll(cleaned, "\r\n", "\n"), "\n")
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "#EXTM3U" {
		return "", errors.New("media playlist must start with #EXTM3U")
	}
	out := make([]string, 0, len(lines))
	for _, rawLine := range lines {
		trimmed := strings.TrimSpace(rawLine)
		if trimmed == "" {
			continue
		}
		if strings.HasPrefix(trimmed, "#") {
			if strings.HasPrefix(trimmed, "#EXT-X-MAP:") || strings.HasPrefix(trimmed, "#EXT-X-KEY:") {
				var rewriteErr error
				replaced := hlsAttrURIRe.ReplaceAllStringFunc(trimmed, func(match string) string {
					if rewriteErr != nil {
						return match
					}
					sub := hlsAttrURIRe.FindStringSubmatch(match)
					if len(sub) != 2 {
						return match
					}
					resolved, err := validateRelayUpstreamURL(sub[1], baseURL, allowInsecure)
					if err != nil {
						rewriteErr = err
						return match
					}
					target := resolved
					if proxySeg != nil {
						target = proxySeg(resolved)
					}
					return fmt.Sprintf(`URI="%s"`, target)
				})
				if rewriteErr != nil {
					return "", rewriteErr
				}
				out = append(out, replaced)
			} else {
				out = append(out, trimmed)
			}
			continue
		}
		resolved, err := validateRelayUpstreamURL(trimmed, baseURL, allowInsecure)
		if err != nil {
			return "", err
		}
		if proxySeg != nil {
			out = append(out, proxySeg(resolved))
		} else {
			out = append(out, resolved)
		}
	}
	return strings.Join(out, "\n") + "\n", nil
}

func validateRelayUpstreamURL(rawURI, baseURL string, allowInsecure bool) (string, error) {
	s := strings.TrimSpace(rawURI)
	if s == "" || strings.ContainsAny(s, "\x00\r\n\"") {
		return "", errors.New("invalid playlist URI")
	}
	u, err := url.Parse(s)
	if err != nil {
		return "", fmt.Errorf("invalid playlist URI: %w", err)
	}
	if !u.IsAbs() {
		if baseURL == "" {
			return "", fmt.Errorf("relative playlist URI %q requires base_url", s)
		}
		bu, err := url.Parse(baseURL)
		if err != nil || !bu.IsAbs() {
			return "", errors.New("invalid playlist base_url")
		}
		u = bu.ResolveReference(u)
	}
	host := strings.ToLower(u.Hostname())
	if host == "" || u.User != nil {
		return "", fmt.Errorf("disallowed playlist URI %q", u.String())
	}
	if !allowInsecure {
		if host == "localhost" || strings.HasSuffix(host, ".localhost") || strings.HasSuffix(host, ".local") {
			return "", fmt.Errorf("playlist URI host %q is not allowed", host)
		}
		if ip := net.ParseIP(host); ip != nil && (ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified()) {
			return "", fmt.Errorf("playlist URI IP %q is not allowed", host)
		}
	}
	switch u.Scheme {
	case "https":
		return u.String(), nil
	case "http":
		if allowInsecure {
			return u.String(), nil
		}
		return "", fmt.Errorf("playlist URI must use https: %q", u.String())
	default:
		return "", fmt.Errorf("unsupported playlist URI scheme %q", u.Scheme)
	}
}

// detectLANIPv4 returns the best local-network IPv4 address for AirPlay devices
// on the same Wi-Fi/LAN to reach this machine, skipping loopback, VPN tunnels
// (point-to-point), and link-local addresses. Falls back to "127.0.0.1".
func detectLANIPv4() string {
	var routeIP net.IP
	if conn, err := net.DialTimeout("udp4", "1.1.1.1:80", 200*time.Millisecond); err == nil {
		if addr, ok := conn.LocalAddr().(*net.UDPAddr); ok {
			routeIP = addr.IP.To4()
		}
		_ = conn.Close()
	}

	ifaces, err := net.Interfaces()
	if err != nil {
		if routeIP != nil && isRFC1918(routeIP) {
			return routeIP.String()
		}
		return "127.0.0.1"
	}

	var fallback string
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 || iface.Flags&net.FlagPointToPoint != 0 {
			continue
		}
		if isVirtualInterface(iface.Name) {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, a := range addrs {
			ipNet, ok := a.(*net.IPNet)
			if !ok {
				continue
			}
			ip4 := ipNet.IP.To4()
			if ip4 == nil || !isRFC1918(ip4) {
				continue
			}
			if routeIP != nil && ip4.Equal(routeIP) {
				return ip4.String()
			}
			if fallback == "" {
				fallback = ip4.String()
			}
		}
	}
	if fallback != "" {
		return fallback
	}
	if routeIP != nil && isRFC1918(routeIP) {
		return routeIP.String()
	}
	return "127.0.0.1"
}

func isRFC1918(ip net.IP) bool {
	ip4 := ip.To4()
	if ip4 == nil {
		return false
	}
	return ip4[0] == 10 ||
		(ip4[0] == 172 && ip4[1] >= 16 && ip4[1] <= 31) ||
		(ip4[0] == 192 && ip4[1] == 168)
}

func isVirtualInterface(name string) bool {
	n := strings.ToLower(name)
	for _, pfx := range []string{"utun", "awdl", "llw", "anpi", "bridge", "docker", "veth", "br-", "virbr", "tailscale", "wg"} {
		if strings.HasPrefix(n, pfx) {
			return true
		}
	}
	return false
}

func cloneArgs(in map[string]any) map[string]any {
	out := make(map[string]any, len(in)+4)
	maps.Copy(out, in)
	return out
}

func randomHex(nBytes int) (string, error) {
	b := make([]byte, nBytes)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return hex.EncodeToString(b), nil
}

// handleHLSRelayRPC serves server.ts's media.relayHLS and media.stopRelay.
// Starting a relay needs app.media:relay; stopping one touches only this app's
// own stream, so cleanup still works after the permission is revoked.
func handleHLSRelayRPC(ctx context.Context, mc *MCPCallContext, method string, raw json.RawMessage) (any, error) {
	if mc.HLSRelay == nil || mc.AppID == uuid.Nil {
		return nil, errors.New("HLS relay is unavailable")
	}
	if method == "media_stop_relay" {
		var in struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(raw, &in); err != nil {
			return nil, err
		}
		id, err := uuid.Parse(strings.TrimSpace(in.ID))
		if err != nil {
			return nil, apperr.Invalid("id", "invalid relay stream id")
		}
		if err := mc.HLSRelay.Stop(mc.AppID, id); err != nil {
			return nil, err
		}
		return map[string]any{"stopped": id}, nil
	}

	var spec HLSRelaySpec
	if err := json.Unmarshal(raw, &spec); err != nil {
		return nil, err
	}
	tool := strings.TrimSpace(spec.Tool)
	if err := checkWorkerCapability(ctx, mc, "app.media:relay", fmt.Sprintf("Relay live HLS playlists on your local network via %s", tool)); err != nil {
		return nil, err
	}
	return mc.HLSRelay.Start(ctx, mc.AppID, spec, mc.RelayToolCaller)
}
