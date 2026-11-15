package usersecrets

import (
	"context"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	sendTimeout  = 30 * time.Second
	maxBody      = 1 << 20
	maxResponse  = 1 << 20
	maxRedirects = 5
)

// Request is what a run asks to send. The secret isn't in it anywhere.
type Request struct {
	Method      string
	URL         string
	Headers     map[string]string
	Body        []byte
	ContentType string
}

// Response is what the run gets back, with every copy of the value masked.
type Response struct {
	Status      int               `json:"status"`
	Headers     map[string]string `json:"headers"`
	Body        string            `json:"body"`
	Binary      bool              `json:"binary,omitempty"`
	BodyBase64  string            `json:"body_base64,omitempty"`
	Truncated   bool              `json:"truncated,omitempty"`
	Redactions  int               `json:"redactions,omitempty"`
	ContentType string            `json:"content_type,omitempty"`
}

// Blocked is a request refused before anything was sent. Its text is for the
// run (and the person) and never contains the value.
type Blocked struct{ Reason string }

func (b *Blocked) Error() string { return b.Reason }

func blocked(format string, args ...any) error { return &Blocked{Reason: fmt.Sprintf(format, args...)} }

// Checked is a request that passed every check that doesn't need the person.
type Checked struct {
	Method string
	URL    *url.URL
	Write  bool
	Policy string
}

var methods = []string{http.MethodGet, http.MethodHead, http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete}

// agentHeaders are headers a run may never set: they'd carry or replace a
// credential, confuse the request framing, or let a run pull an echoed value
// back in pieces (Range) or encoded past masking (Accept-Encoding).
var agentHeaders = []string{"authorization", "proxy-authorization", "cookie", "host", "content-length", "transfer-encoding", "connection", "te", "upgrade",
	"range", "if-range", "accept-encoding"}

// headerKey compares header names the way lenient backends do: CGI-style
// servers read X_Api_Key as X-Api-Key, so a run mustn't send that alongside
// the real one.
func headerKey(name string) string { return strings.ReplaceAll(strings.ToLower(name), "_", "-") }

// isLocal is a host on this machine; plain http and private addresses are
// allowed only for these, as for connectors.
func isLocal(host string) bool {
	ip := net.ParseIP(host)
	return host == "localhost" || host == "host.docker.internal" || (ip != nil && ip.IsLoopback())
}

// Check applies the secret's own rules to a request: not expired, a method
// it allows, https to an allowed host, and no headers that would carry or
// replace a credential. Ask is left to the caller.
func (s *Service) Check(sec store.UserSecret, req Request) (Checked, error) {
	var c Checked
	if sec.ExpiresAt != nil && !s.now().Before(*sec.ExpiresAt) {
		return c, blocked("%s has expired. Ask the person to replace it in Customization › Secrets.", sec.Handle)
	}
	if sec.Kind == KindOAuth && sec.SignedInAt == nil {
		return c, notSignedIn(sec)
	}
	if sec.Kind == KindOAuth && sec.OauthError != "" {
		return c, blocked("%s needs signing in again (%s). Ask the person to sign in from Customization › Secrets.", sec.Handle, sec.OauthError)
	}
	c.Method = strings.ToUpper(strings.TrimSpace(req.Method))
	if c.Method == "" {
		c.Method = http.MethodGet
	}
	if !slices.Contains(methods, c.Method) {
		return c, blocked("method must be one of %s", strings.Join(methods, ", "))
	}
	c.Write = c.Method != http.MethodGet && c.Method != http.MethodHead
	c.Policy = sec.ReadPolicy
	if c.Write {
		c.Policy = sec.WritePolicy
	}
	if c.Policy == PolicyOff {
		kind := "read"
		if c.Write {
			kind = "write"
		}
		return c, blocked("%s requests with %s are turned off.", kind, sec.Handle)
	}
	u, err := url.Parse(strings.TrimSpace(req.URL))
	if err != nil || u.Host == "" || len(req.URL) > 4000 {
		return c, blocked("url must be a full URL, e.g. https://%s/path", sec.AllowedHosts[0])
	}
	if u.User != nil {
		return c, blocked("url can't contain credentials")
	}
	host := strings.TrimSuffix(strings.ToLower(u.Hostname()), ".")
	if !slices.Contains(sec.AllowedHosts, host) {
		return c, blocked("%s can only be sent to %s.", sec.Handle, strings.Join(sec.AllowedHosts, ", "))
	}
	if u.Scheme != "https" && !(u.Scheme == "http" && isLocal(host)) {
		return c, blocked("use https (http only works for localhost)")
	}
	if sec.Placement == PlacementQuery && u.Query().Has(sec.PlacementKey) {
		return c, blocked("leave the %s query parameter out: Vesper adds it", sec.PlacementKey)
	}
	for k := range req.Headers {
		lk := headerKey(k)
		if slices.Contains(agentHeaders, lk) || (sec.Placement == PlacementHeader && lk == headerKey(sec.PlacementKey)) {
			return c, blocked("the %s header can't be set: Vesper adds the secret itself", k)
		}
		if strings.ContainsAny(k+req.Headers[k], "\r\n") {
			return c, blocked("header %q has a line break", k)
		}
	}
	if len(req.Body) > maxBody {
		return c, blocked("the body is limited to 1 MB")
	}
	if len(req.Body) > 0 && !c.Write {
		return c, blocked("%s requests can't have a body", c.Method)
	}
	// The person approves the body they can read; bytes that aren't text
	// couldn't be shown to them.
	if !utf8.Valid(req.Body) {
		return c, blocked("the body must be text (UTF-8)")
	}
	u.Host = strings.ToLower(u.Host)
	c.URL = u
	return c, nil
}

// reservedNets are ranges that aren't private by Go's definition but don't
// belong to a public API either.
var reservedNets = func() []*net.IPNet {
	var out []*net.IPNet
	for _, c := range []string{
		"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "198.18.0.0/15", "240.0.0.0/4", // this network, CGNAT, IETF, benchmarking, reserved
		"fec0::/10",      // deprecated site-local
		"2001::/32",      // Teredo: tunnels to an address we can't check
		"64:ff9b:1::/48", // local-use NAT64
	} {
		_, n, _ := net.ParseCIDR(c)
		out = append(out, n)
	}
	return out
}()

// embeddedV4 is the IPv4 address an IPv6 transition address carries: NAT64
// (64:ff9b::/96), 6to4 (2002::/16) and the old IPv4-compatible form (::/96).
func embeddedV4(ip net.IP) net.IP {
	ip16 := ip.To16()
	if ip16 == nil || ip.To4() != nil {
		return nil
	}
	switch {
	case ip16[0] == 0x00 && ip16[1] == 0x64 && ip16[2] == 0xff && ip16[3] == 0x9b && allZero(ip16[4:12]):
		return net.IP(ip16[12:16])
	case ip16[0] == 0x20 && ip16[1] == 0x02:
		return net.IP(ip16[2:6])
	case allZero(ip16[:12]):
		return net.IP(ip16[12:16])
	}
	return nil
}

func allZero(b []byte) bool { return !slices.ContainsFunc(b, func(x byte) bool { return x != 0 }) }

// blockedAddr is an address a request may not reach unless its host is local:
// private networks, link-local (cloud metadata), reserved ranges, and IPv6
// addresses that tunnel to any of those.
func blockedAddr(ip net.IP) bool {
	if v4 := embeddedV4(ip); v4 != nil && blockedAddr(v4) {
		return true
	}
	if slices.ContainsFunc(reservedNets, func(n *net.IPNet) bool { return n.Contains(ip) }) {
		return true
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsUnspecified() ||
		ip.IsMulticast() || ip.IsInterfaceLocalMulticast()
}

// transport dials only addresses it checked, so a hostname can't resolve to
// a public address for the check and a private one for the connection.
func (s *Service) transport(host string) *http.Transport {
	return SafeTransport(isLocal(host), s.LookupIP)
}

// SafeTransport returns an http.Transport that verifies resolved IPs against
// blocked private/reserved ranges unless allowLocal is true.
func SafeTransport(allowLocal bool, lookup func(ctx context.Context, host string) ([]net.IP, error)) *http.Transport {
	if lookup == nil {
		lookup = func(ctx context.Context, h string) ([]net.IP, error) {
			return net.DefaultResolver.LookupIP(ctx, "ip", h)
		}
	}
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	return &http.Transport{
		Proxy:                 nil, // An environment proxy would dial for us, past the address check.
		ForceAttemptHTTP2:     true,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: sendTimeout,
		MaxIdleConns:          1,
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			h, port, err := net.SplitHostPort(addr)
			if err != nil {
				return nil, err
			}
			ips := []net.IP{net.ParseIP(h)}
			if ips[0] == nil {
				if ips, err = lookup(ctx, h); err != nil || len(ips) == 0 {
					return nil, fmt.Errorf("couldn't resolve %s", h)
				}
			}
			for _, ip := range ips {
				if blockedAddr(ip) && !allowLocal {
					return nil, &Blocked{Reason: h + " resolves to a private address"}
				}
			}
			// Every address was checked above; try each, as net.Dial would.
			var last error
			for _, ip := range ips {
				conn, err := dialer.DialContext(ctx, network, net.JoinHostPort(ip.String(), port))
				if err == nil {
					return conn, nil
				}
				last = err
			}
			return nil, last
		},
	}
}

// SendPublic makes a bounded outbound HTTPS request (no secret attached)
// blocking private/loopback/reserved IPs via SafeTransport.
func SendPublic(ctx context.Context, req Request, lookup func(ctx context.Context, host string) ([]net.IP, error)) (Response, error) {
	t := SafeTransport(false, lookup)
	defer t.CloseIdleConnections()
	return sendPublic(ctx, req, t)
}

func sendPublic(ctx context.Context, req Request, transport http.RoundTripper) (Response, error) {
	method := strings.ToUpper(strings.TrimSpace(req.Method))
	if method == "" {
		method = http.MethodGet
	}
	if !slices.Contains(methods, method) {
		return Response{}, blocked("method must be one of %s", strings.Join(methods, ", "))
	}
	u, err := url.Parse(strings.TrimSpace(req.URL))
	if err != nil || u.Host == "" || len(req.URL) > 4000 {
		return Response{}, blocked("url must be a full https URL")
	}
	if u.User != nil {
		return Response{}, blocked("url can't contain credentials")
	}
	if u.Scheme != "https" {
		return Response{}, blocked("outbound fetch requires https")
	}
	for k := range req.Headers {
		if strings.ContainsAny(k+req.Headers[k], "\r\n") {
			return Response{}, blocked("header %q has a line break", k)
		}
		lk := headerKey(k)
		if lk == "host" || lk == "content-length" || lk == "transfer-encoding" || lk == "connection" {
			return Response{}, blocked("header %q cannot be set", k)
		}
	}
	if len(req.Body) > maxBody {
		return Response{}, blocked("the body is limited to 1 MB")
	}
	write := method != http.MethodGet && method != http.MethodHead
	if len(req.Body) > 0 && !write {
		return Response{}, blocked("%s requests can't have a body", method)
	}
	ctx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	var body io.Reader
	if len(req.Body) > 0 {
		body = strings.NewReader(string(req.Body))
	}
	out, err := http.NewRequestWithContext(ctx, method, u.String(), body)
	if err != nil {
		return Response{}, err
	}
	for k, v := range req.Headers {
		out.Header.Set(k, v)
	}
	if len(req.Body) > 0 && req.ContentType != "" && out.Header.Get("Content-Type") == "" {
		out.Header.Set("Content-Type", req.ContentType)
	}
	out.Header.Set("User-Agent", "Vesper")
	client := &http.Client{
		Transport: transport,
		CheckRedirect: func(next *http.Request, via []*http.Request) error {
			if write || len(via) >= maxRedirects || next.URL.Scheme != "https" {
				return http.ErrUseLastResponse
			}
			return nil
		},
	}
	res, err := client.Do(out)
	if err != nil {
		var b *Blocked
		if errors.As(err, &b) {
			return Response{}, b
		}
		if errors.Is(err, context.DeadlineExceeded) {
			return Response{}, errors.New("the request timed out after 30 s")
		}
		return Response{}, err
	}
	defer res.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(res.Body, maxResponse+1))
	if err != nil {
		return Response{}, fmt.Errorf("reading the response: %w", err)
	}
	truncated := len(raw) > maxResponse
	if truncated {
		raw = raw[:maxResponse]
	}
	contentType := res.Header.Get("Content-Type")
	resp := Response{Status: res.StatusCode, Headers: map[string]string{}, ContentType: contentType, Truncated: truncated}
	for k, vs := range res.Header {
		if strings.EqualFold(k, "Set-Cookie") {
			continue
		}
		resp.Headers[k] = strings.Join(vs, ", ")
	}
	if textual(contentType, raw) {
		resp.Body = string(raw)
	} else {
		resp.Binary = true
		resp.Body = fmt.Sprintf("(%d bytes of %s, not shown)", len(raw), contentType)
		if len(raw) > 0 {
			resp.BodyBase64 = base64.StdEncoding.EncodeToString(raw)
		}
	}
	return resp, nil
}

// inject adds the secret to an outgoing request, exactly where the person said.
func inject(r *http.Request, sec store.UserSecret, value string) {
	switch sec.Placement {
	case PlacementBearer:
		r.Header.Set("Authorization", "Bearer "+value)
	case PlacementHeader:
		r.Header.Set(sec.PlacementKey, value)
	case PlacementQuery:
		q := r.URL.Query()
		q.Set(sec.PlacementKey, value)
		r.URL.RawQuery = q.Encode()
	case PlacementBasic:
		user, pass, _ := strings.Cut(value, ":")
		r.SetBasicAuth(user, pass)
	}
}

// Send makes a checked request with the secret added. The value is masked as
// ‹handle› in the response body, its headers and any error text.
func (s *Service) Send(ctx context.Context, sec store.UserSecret, value string, c Checked, req Request) (Response, error) {
	mask := newMasker(sec, value)
	ctx, cancel := context.WithTimeout(ctx, sendTimeout)
	defer cancel()
	var body io.Reader
	if len(req.Body) > 0 {
		body = strings.NewReader(string(req.Body))
	}
	out, err := http.NewRequestWithContext(ctx, c.Method, c.URL.String(), body)
	if err != nil {
		return Response{}, errors.New(mask.text(err.Error()))
	}
	for k, v := range req.Headers {
		out.Header.Set(k, v)
	}
	if len(req.Body) > 0 && req.ContentType != "" && out.Header.Get("Content-Type") == "" {
		out.Header.Set("Content-Type", req.ContentType)
	}
	out.Header.Set("User-Agent", "Vesper")
	inject(out, sec, value)
	host := c.URL.Hostname()
	t := s.transport(host)
	defer t.CloseIdleConnections()
	client := &http.Client{Transport: t, CheckRedirect: func(next *http.Request, via []*http.Request) error {
		// Only reads, and only to the same host and scheme: anywhere else the run
		// gets the 3xx and the secret stays where it was allowed. A write's 307
		// would resend its body to a path the person didn't approve.
		if c.Write || len(via) >= maxRedirects || !strings.EqualFold(next.URL.Hostname(), host) || next.URL.Scheme != c.URL.Scheme {
			return http.ErrUseLastResponse
		}
		if sec.Placement == PlacementQuery {
			q := next.URL.Query()
			q.Set(sec.PlacementKey, value)
			next.URL.RawQuery = q.Encode()
		} else {
			inject(next, sec, value)
		}
		return nil
	}}
	res, err := client.Do(out)
	if err != nil {
		var b *Blocked
		if errors.As(err, &b) {
			return Response{}, b
		}
		if errors.Is(err, context.DeadlineExceeded) {
			return Response{}, errors.New("the request timed out after 30 s")
		}
		return Response{}, errors.New(mask.text(err.Error()))
	}
	defer res.Body.Close()
	// Read past the cap by the longest masked form, so a value that starts
	// before the cap is whole when it's masked; see maskedPrefix.
	raw, err := io.ReadAll(io.LimitReader(res.Body, int64(maxResponse+mask.longest())))
	if err != nil {
		return Response{}, errors.New(mask.text("reading the response: " + err.Error()))
	}
	contentType := res.Header.Get("Content-Type")
	resp := Response{Status: res.StatusCode, Headers: map[string]string{}, ContentType: mask.text(contentType)}
	for k, vs := range res.Header {
		if strings.EqualFold(k, "Set-Cookie") {
			continue
		}
		resp.Headers[mask.text(k)] = mask.text(strings.Join(vs, ", "))
	}
	if textual(contentType, raw) {
		resp.Body, resp.Truncated = mask.maskedPrefix(raw, maxResponse)
	} else {
		resp.Body = fmt.Sprintf("(%d bytes of %s, not shown)", len(raw), resp.ContentType)
	}
	resp.Redactions = mask.count
	return resp, nil
}

func textual(contentType string, raw []byte) bool {
	ct := strings.ToLower(contentType)
	for _, t := range []string{"text/", "json", "xml", "javascript", "x-www-form-urlencoded", "yaml", "csv"} {
		if strings.Contains(ct, t) {
			return true
		}
	}
	return ct == "" && !slices.Contains(raw, 0) && strings.ToValidUTF8(string(raw), "") == string(raw)
}

// masker replaces a value, and the forms it's commonly echoed in, with a
// placeholder, counting how many it replaced.
type masker struct {
	forms []string
	label string
	count int
}

var percentHex = regexp.MustCompile(`%[0-9A-F]{2}`)

// encodings are the forms a server commonly echoes a value back in: URL and
// path escaping (either hex case), JSON and HTML escaping, base64 and hex.
func encodings(v string) []string {
	jsonEsc, _ := json.Marshal(v)
	out := []string{
		v,
		url.QueryEscape(v), url.PathEscape(v),
		string(jsonEsc[1 : len(jsonEsc)-1]), strings.ReplaceAll(v, "/", `\/`),
		html.EscapeString(v),
		base64.StdEncoding.EncodeToString([]byte(v)), base64.RawStdEncoding.EncodeToString([]byte(v)),
		base64.URLEncoding.EncodeToString([]byte(v)), base64.RawURLEncoding.EncodeToString([]byte(v)),
		hex.EncodeToString([]byte(v)), strings.ToUpper(hex.EncodeToString([]byte(v))),
	}
	for _, e := range out[1:3] {
		out = append(out, percentHex.ReplaceAllStringFunc(e, strings.ToLower))
	}
	return out
}

func newMasker(sec store.UserSecret, value string) *masker {
	m := &masker{label: "‹" + sec.Handle + "›"}
	add := func(f string, min int) {
		if len(f) >= min && !slices.Contains(m.forms, f) {
			m.forms = append(m.forms, f)
		}
	}
	for _, v := range []string{value, strings.TrimSpace(value)} {
		// The value itself is always masked, however short: masking ordinary
		// text by mistake is harmless; leaking a short value isn't.
		add(v, 1)
		for _, e := range encodings(v) {
			add(e, 4)
		}
	}
	if sec.Placement == PlacementBasic {
		if _, pass, ok := strings.Cut(value, ":"); ok {
			add(pass, 1)
			for _, e := range encodings(pass) {
				add(e, 4)
			}
		}
	}
	// A JWT's header and claims aren't secret, but its signature is: mask it
	// even when it comes back on its own.
	if parts := strings.Split(strings.TrimSpace(value), "."); len(parts) == 3 && len(parts[2]) >= 16 {
		add(parts[2], 16)
	}
	// Longest first, so a whole value is replaced before a part of it.
	slices.SortFunc(m.forms, func(a, b string) int { return len(b) - len(a) })
	return m
}

func (m *masker) longest() int {
	if len(m.forms) == 0 {
		return 0
	}
	return len(m.forms[0])
}

// maskedPrefix masks a body read up to limit+longest bytes and returns at
// most limit bytes of it. Masking runs before the cut, and the bytes read
// past limit are dropped after it: an occurrence that starts before limit is
// whole in what was read, so it's masked; one that starts after is dropped,
// so no fragment of a value survives the cut.
func (m *masker) maskedPrefix(raw []byte, limit int) (string, bool) {
	if len(raw) <= limit {
		return m.text(string(raw)), false
	}
	masked := m.text(string(raw))
	masked = masked[:len(masked)-(len(raw)-limit)]
	return strings.ToValidUTF8(masked, ""), true
}

func (m *masker) text(s string) string {
	for _, f := range m.forms {
		if n := strings.Count(s, f); n > 0 {
			m.count += n
			s = strings.ReplaceAll(s, f, m.label)
		}
	}
	return s
}
