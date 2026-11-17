package microvm

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

// CacheStoreConfig configures host-side pull-through caches served to microVMs
// at http://cache.vesper.internal (strictly downward: guest VMs can read-through
// host upstream fetches but can never push or pollute shared caches).
type CacheStoreConfig struct {
	Dir         string
	GoUpstream  string // default https://proxy.golang.org
	NPMUpstream string // default https://registry.npmjs.org
	NixUpstream string // default https://cache.nixos.org
	OCIUpstream string // default https://registry-1.docker.io
	HTTPClient  *http.Client
}

// CacheStore manages immutable host-side caches and signed Nix binary cache
// metadata plus background EROFS snapshot compaction.
type CacheStore struct {
	cfg        CacheStoreConfig
	client     *http.Client
	nixKeyName string
	nixPubKey  string // "<name>:<base64-pubkey>"
	nixPrivKey ed25519.PrivateKey

	writeMu   sync.Mutex
	compactMu sync.Mutex
}

const (
	CacheKindGoMod = "gomod"
	CacheKindNPM   = "npm"
	CacheKindNix   = "nix"
	CacheKindOCI   = "oci"
)

func NewCacheStore(cfg CacheStoreConfig) (*CacheStore, error) {
	if cfg.Dir == "" {
		return nil, errors.New("microvm: cache Dir is required")
	}
	if cfg.GoUpstream == "" {
		cfg.GoUpstream = "https://proxy.golang.org"
	}
	if cfg.NPMUpstream == "" {
		cfg.NPMUpstream = "https://registry.npmjs.org"
	}
	if cfg.NixUpstream == "" {
		cfg.NixUpstream = "https://cache.nixos.org"
	}
	if cfg.OCIUpstream == "" {
		cfg.OCIUpstream = "https://registry-1.docker.io"
	}
	for _, k := range []string{CacheKindGoMod, CacheKindNPM, CacheKindNix, CacheKindOCI, "erofs"} {
		if err := os.MkdirAll(filepath.Join(cfg.Dir, k), 0o755); err != nil {
			return nil, err
		}
	}
	hc := cfg.HTTPClient
	if hc == nil {
		hc = &http.Client{Timeout: 60 * time.Second}
	}
	cs := &CacheStore{cfg: cfg, client: hc, nixKeyName: "vesper-cache-1"}
	if err := cs.loadOrCreateNixKey(); err != nil {
		return nil, fmt.Errorf("nix cache key: %w", err)
	}
	return cs, nil
}

func (c *CacheStore) NixPublicKey() string { return c.nixPubKey }

func (c *CacheStore) loadOrCreateNixKey() error {
	keyPath := filepath.Join(c.cfg.Dir, "nix-cache-key.ed25519")
	if b, err := os.ReadFile(keyPath); err == nil {
		raw, derr := base64.StdEncoding.DecodeString(strings.TrimSpace(string(b)))
		if derr == nil && len(raw) == ed25519.PrivateKeySize {
			priv := ed25519.PrivateKey(raw)
			pub := priv.Public().(ed25519.PublicKey)
			c.nixPrivKey = priv
			c.nixPubKey = c.nixKeyName + ":" + base64.StdEncoding.EncodeToString(pub)
			return nil
		}
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	if err := os.WriteFile(keyPath, []byte(base64.StdEncoding.EncodeToString(priv)+"\n"), 0o600); err != nil {
		return err
	}
	c.nixPrivKey = priv
	c.nixPubKey = c.nixKeyName + ":" + base64.StdEncoding.EncodeToString(pub)
	return nil
}

// ServeHTTP handles read-only pull-through requests for /goproxy/, /npm/, /nix/, and /v2/.
func (c *CacheStore) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	// Strictly downward: guests can never mutate host cache state.
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "vesper cache is read-only from inside microVMs", http.StatusMethodNotAllowed)
		return
	}
	p := path.Clean("/" + r.URL.Path)
	if strings.Contains(r.URL.Path, "..") {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	switch {
	case strings.HasPrefix(p, "/goproxy/"):
		c.handleGoProxy(w, r, strings.TrimPrefix(r.URL.Path, "/goproxy"))
	case strings.HasPrefix(p, "/npm/"):
		c.handleNPM(w, r, strings.TrimPrefix(r.URL.Path, "/npm"))
	case strings.HasPrefix(p, "/nix/"):
		c.handleNix(w, r, strings.TrimPrefix(r.URL.Path, "/nix"))
	case p == "/v2" || strings.HasPrefix(p, "/v2/"):
		c.handleOCI(w, r)
	default:
		http.NotFound(w, r)
	}
}

func (c *CacheStore) cachePathFor(kind, rel string) (string, bool) {
	cleaned := path.Clean("/" + rel)
	if cleaned == "/" || strings.Contains(cleaned, "..") {
		return "", false
	}
	// Hash ultra-long paths to stay well within host filesystem limits while keeping structure readable.
	relOS := filepath.FromSlash(strings.TrimPrefix(cleaned, "/"))
	full := filepath.Join(c.cfg.Dir, kind, relOS)
	root := filepath.Join(c.cfg.Dir, kind) + string(filepath.Separator)
	if !strings.HasPrefix(full, root) {
		return "", false
	}
	return full, true
}

func (c *CacheStore) serveCachedOrFetch(w http.ResponseWriter, r *http.Request, kind, keyRel, upstreamURL string, ttl time.Duration, verify func([]byte) error, transform func([]byte) []byte) {
	diskPath, ok := c.cachePathFor(kind, keyRel)
	if !ok {
		http.Error(w, "bad cache key", http.StatusBadRequest)
		return
	}
	if info, err := os.Stat(diskPath); err == nil && !info.IsDir() {
		if ttl == 0 || time.Since(info.ModTime()) < ttl {
			w.Header().Set("X-Vesper-Cache", "HIT")
			http.ServeFile(w, r, diskPath)
			return
		}
	}

	req, err := http.NewRequestWithContext(r.Context(), r.Method, upstreamURL, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	if acc := r.Header.Get("Accept"); acc != "" {
		req.Header.Set("Accept", acc)
	}
	res, err := c.client.Do(req)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer res.Body.Close()

	if res.StatusCode != http.StatusOK {
		w.WriteHeader(res.StatusCode)
		if r.Method == http.MethodGet {
			_, _ = io.Copy(w, res.Body)
		}
		return
	}
	if r.Method == http.MethodHead {
		copyContentHeaders(w, res.Header)
		w.Header().Set("X-Vesper-Cache", "MISS")
		w.WriteHeader(http.StatusOK)
		return
	}

	body, err := io.ReadAll(io.LimitReader(res.Body, 512<<20))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	if verify != nil {
		if verr := verify(body); verr != nil {
			http.Error(w, "upstream verification failed: "+verr.Error(), http.StatusBadGateway)
			return
		}
	}
	if transform != nil {
		body = transform(body)
	}
	_ = c.writeAtomic(diskPath, body)
	w.Header().Set("X-Vesper-Cache", "MISS")
	copyContentHeaders(w, res.Header)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(body)
}

func (c *CacheStore) writeAtomic(dst string, data []byte) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(dst), ".tmp-*")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if _, err := tmp.Write(data); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Chmod(0o644); err != nil {
		_ = tmp.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	return os.Rename(tmpPath, dst)
}

func copyContentHeaders(w http.ResponseWriter, h http.Header) {
	for _, k := range []string{"Content-Type", "Docker-Content-Digest", "Content-Length"} {
		if v := h.Get(k); v != "" {
			w.Header().Set(k, v)
		}
	}
}

func (c *CacheStore) handleGoProxy(w http.ResponseWriter, r *http.Request, rel string) {
	ttl := time.Duration(0) // .info, .mod, .zip are immutable
	if strings.HasSuffix(rel, "/@v/list") || strings.HasSuffix(rel, "/@latest") {
		ttl = 5 * time.Minute
	}
	keyRel := rel
	if strings.HasSuffix(rel, "/@v/list") {
		keyRel = rel + ".txt"
	} else if strings.HasSuffix(rel, "/@latest") {
		keyRel = rel + ".json"
	}
	upstream := strings.TrimRight(c.cfg.GoUpstream, "/") + rel
	c.serveCachedOrFetch(w, r, CacheKindGoMod, keyRel, upstream, ttl, nil, nil)
}

func (c *CacheStore) handleNPM(w http.ResponseWriter, r *http.Request, rel string) {
	isTarball := strings.HasSuffix(rel, ".tgz")
	ttl := 5 * time.Minute
	keyRel := rel
	if isTarball {
		ttl = 0
	} else {
		keyRel = strings.TrimRight(rel, "/") + "/metadata.json"
	}
	upstream := strings.TrimRight(c.cfg.NPMUpstream, "/") + rel
	upstreamBase := strings.TrimRight(c.cfg.NPMUpstream, "/")
	mirrorBase := "http://" + InternalCacheHost + "/npm"
	var transform func([]byte) []byte
	if !isTarball {
		transform = func(b []byte) []byte {
			return bytes.ReplaceAll(b, []byte(upstreamBase), []byte(mirrorBase))
		}
	}
	c.serveCachedOrFetch(w, r, CacheKindNPM, keyRel, upstream, ttl, nil, transform)
}

func (c *CacheStore) handleNix(w http.ResponseWriter, r *http.Request, rel string) {
	if rel == "/nix-cache-info" {
		w.Header().Set("Content-Type", "text/x-nix-cache-info")
		_, _ = io.WriteString(w, "StoreDir: /nix/store\nWantMassQuery: 1\nPriority: 30\n")
		return
	}
	upstream := strings.TrimRight(c.cfg.NixUpstream, "/") + rel
	var transform func([]byte) []byte
	ttl := time.Duration(0)
	if strings.HasSuffix(rel, ".narinfo") {
		transform = func(b []byte) []byte { return c.signNarInfo(b) }
	}
	c.serveCachedOrFetch(w, r, CacheKindNix, rel, upstream, ttl, nil, transform)
}

func (c *CacheStore) signNarInfo(raw []byte) []byte {
	fields := map[string]string{}
	var outLines []string
	hasSig := false
	for _, line := range strings.Split(strings.TrimRight(string(raw), "\n"), "\n") {
		if k, v, ok := strings.Cut(line, ":"); ok {
			key := strings.TrimSpace(k)
			val := strings.TrimSpace(v)
			fields[key] = val
			if key == "Sig" && strings.HasPrefix(val, c.nixKeyName+":") {
				hasSig = true
			}
		}
		outLines = append(outLines, line)
	}
	if !hasSig && fields["StorePath"] != "" && fields["NarHash"] != "" && fields["NarSize"] != "" {
		var refs []string
		for _, r := range strings.Fields(fields["References"]) {
			if strings.HasPrefix(r, "/nix/store/") {
				refs = append(refs, r)
			} else {
				refs = append(refs, "/nix/store/"+r)
			}
		}
		fp := fmt.Sprintf("1;%s;%s;%s;%s", fields["StorePath"], fields["NarHash"], fields["NarSize"], strings.Join(refs, " "))
		sig := ed25519.Sign(c.nixPrivKey, []byte(fp))
		outLines = append(outLines, "Sig: "+c.nixKeyName+":"+base64.StdEncoding.EncodeToString(sig))
	}
	return []byte(strings.Join(outLines, "\n") + "\n")
}

var ociBlobDigestRe = regexp.MustCompile(`/blobs/(sha256:[0-9a-f]{64})$`)

func (c *CacheStore) handleOCI(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/v2" || r.URL.Path == "/v2/" {
		w.Header().Set("Docker-Distribution-Api-Version", "registry/2.0")
		w.WriteHeader(http.StatusOK)
		return
	}
	if m := ociBlobDigestRe.FindStringSubmatch(r.URL.Path); len(m) == 2 {
		digest := m[1]
		hexDigest := strings.TrimPrefix(digest, "sha256:")
		diskPath, ok := c.cachePathFor(CacheKindOCI, "blobs/"+hexDigest)
		if ok {
			if st, err := os.Stat(diskPath); err == nil && !st.IsDir() {
				w.Header().Set("X-Vesper-Cache", "HIT")
				w.Header().Set("Docker-Content-Digest", digest)
				http.ServeFile(w, r, diskPath)
				return
			}
		}
		upstreamURL := strings.TrimRight(c.cfg.OCIUpstream, "/") + r.URL.Path
		res, err := c.doOCIUpstream(r.Context(), r.Method, upstreamURL, r.Header.Get("Accept"))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer res.Body.Close()
		if res.StatusCode != http.StatusOK {
			w.WriteHeader(res.StatusCode)
			_, _ = io.Copy(w, res.Body)
			return
		}
		if r.Method == http.MethodHead {
			copyContentHeaders(w, res.Header)
			w.Header().Set("X-Vesper-Cache", "MISS")
			w.WriteHeader(http.StatusOK)
			return
		}
		body, err := io.ReadAll(io.LimitReader(res.Body, 512<<20))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		sum := sha256.Sum256(body)
		if hex.EncodeToString(sum[:]) != hexDigest {
			http.Error(w, "OCI blob digest mismatch", http.StatusBadGateway)
			return
		}
		if ok {
			_ = c.writeAtomic(diskPath, body)
		}
		copyContentHeaders(w, res.Header)
		w.Header().Set("Docker-Content-Digest", digest)
		w.Header().Set("X-Vesper-Cache", "MISS")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(body)
		return
	}

	// Manifest / tag references proxy through (not cached immutably so tags stay fresh).
	upstreamURL := strings.TrimRight(c.cfg.OCIUpstream, "/") + r.URL.RequestURI()
	res, err := c.doOCIUpstream(r.Context(), r.Method, upstreamURL, r.Header.Get("Accept"))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer res.Body.Close()
	copyContentHeaders(w, res.Header)
	w.WriteHeader(res.StatusCode)
	if r.Method != http.MethodHead {
		_, _ = io.Copy(w, res.Body)
	}
}

func (c *CacheStore) doOCIUpstream(ctx context.Context, method, rawURL, accept string) (*http.Response, error) {
	makeReq := func(tok string) (*http.Request, error) {
		req, err := http.NewRequestWithContext(ctx, method, rawURL, nil)
		if err != nil {
			return nil, err
		}
		if accept != "" {
			req.Header.Set("Accept", accept)
		}
		if tok != "" {
			req.Header.Set("Authorization", "Bearer "+tok)
		}
		return req, nil
	}
	req, err := makeReq("")
	if err != nil {
		return nil, err
	}
	res, err := c.client.Do(req)
	if err != nil || res.StatusCode != http.StatusUnauthorized {
		return res, err
	}
	wwwAuth := res.Header.Get("Www-Authenticate")
	_ = res.Body.Close()
	tok, err := fetchBearerToken(ctx, c.client, wwwAuth)
	if err != nil {
		return nil, fmt.Errorf("oci auth: %w", err)
	}
	req2, err := makeReq(tok)
	if err != nil {
		return nil, err
	}
	return c.client.Do(req2)
}

func fetchBearerToken(ctx context.Context, hc *http.Client, challenge string) (string, error) {
	if !strings.HasPrefix(challenge, "Bearer ") {
		return "", errors.New("unsupported auth challenge")
	}
	params := map[string]string{}
	for _, part := range strings.Split(strings.TrimPrefix(challenge, "Bearer "), ",") {
		k, v, ok := strings.Cut(strings.TrimSpace(part), "=")
		if ok {
			params[strings.TrimSpace(k)] = strings.Trim(strings.TrimSpace(v), `"`)
		}
	}
	realm := params["realm"]
	if realm == "" {
		return "", errors.New("missing bearer realm")
	}
	u, err := url.Parse(realm)
	if err != nil {
		return "", err
	}
	q := u.Query()
	if params["service"] != "" {
		q.Set("service", params["service"])
	}
	if params["scope"] != "" {
		q.Set("scope", params["scope"])
	}
	u.RawQuery = q.Encode()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u.String(), nil)
	if err != nil {
		return "", err
	}
	res, err := hc.Do(req)
	if err != nil {
		return "", err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return "", fmt.Errorf("token status %d", res.StatusCode)
	}
	b, _ := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	for _, key := range []string{`"token":"`, `"access_token":"`} {
		if _, rest, ok := strings.Cut(string(b), key); ok {
			if tok, _, ok := strings.Cut(rest, `"`); ok {
				return tok, nil
			}
		}
	}
	return "", errors.New("no token in bearer response")
}

// LatestEROFSDrives returns read-only cache EROFS drives for newly booted VMs.
func (c *CacheStore) LatestEROFSDrives() []DriveSpec {
	erofsDir := filepath.Join(c.cfg.Dir, "erofs")
	entries, err := os.ReadDir(erofsDir)
	if err != nil {
		return nil
	}
	latest := map[string]string{}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".erofs") {
			continue
		}
		for _, kind := range []string{CacheKindGoMod, CacheKindNPM, CacheKindNix, CacheKindOCI} {
			if strings.HasPrefix(e.Name(), "cache-"+kind+"-") {
				if prev := latest[kind]; e.Name() > prev {
					latest[kind] = e.Name()
				}
			}
		}
	}
	var out []DriveSpec
	kinds := make([]string, 0, len(latest))
	for k := range latest {
		kinds = append(kinds, k)
	}
	sort.Strings(kinds)
	for _, k := range kinds {
		out = append(out, DriveSpec{Path: filepath.Join(erofsDir, latest[k]), ReadOnly: true})
	}
	return out
}

// CompactToEROFS packs a cache kind directory into a generation-stamped EROFS
// drive if mkfs.erofs is available.
func (c *CacheStore) CompactToEROFS(ctx context.Context, kind string) (string, error) {
	c.compactMu.Lock()
	defer c.compactMu.Unlock()

	mkfs, err := exec.LookPath("mkfs.erofs")
	if err != nil {
		return "", err
	}
	srcDir := filepath.Join(c.cfg.Dir, kind)
	if _, err := os.Stat(srcDir); err != nil {
		return "", err
	}
	outName := fmt.Sprintf("cache-%s-%d.erofs", kind, time.Now().UnixNano())
	dst := filepath.Join(c.cfg.Dir, "erofs", outName)
	tmp := dst + ".tmp"
	_ = os.Remove(tmp)
	// EROFS volume label max 16 bytes: cache-gomod, cache-npm, cache-nix, cache-oci
	label := "cache-" + kind
	cmd := exec.CommandContext(ctx, mkfs, "-L", label, tmp, srcDir)
	if out, err := cmd.CombinedOutput(); err != nil {
		_ = os.Remove(tmp)
		return "", fmt.Errorf("mkfs.erofs: %w (%s)", err, string(out))
	}
	if err := os.Rename(tmp, dst); err != nil {
		_ = os.Remove(tmp)
		return "", err
	}
	return dst, nil
}
