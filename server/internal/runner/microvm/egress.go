package microvm

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"io"
	"log/slog"
	"net"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

// Reserved internal service hostnames mapped into 198.18.0.0/15.
const (
	InternalAPIHost        = "api.vesper.internal"
	InternalCacheHost      = "cache.vesper.internal"
	InternalGitHost        = "git.vesper.internal"
	InternalPlaygroundHost = "playground.vesper.internal"
)

var (
	internalAPIIP        = [4]byte{198, 18, 0, 1}
	internalCacheIP      = [4]byte{198, 18, 0, 2}
	internalGitIP        = [4]byte{198, 18, 0, 3}
	internalPlaygroundIP = [4]byte{198, 18, 0, 4}
)

var reservedHostToIP = map[string][4]byte{
	InternalAPIHost:        internalAPIIP,
	InternalCacheHost:      internalCacheIP,
	InternalGitHost:        internalGitIP,
	InternalPlaygroundHost: internalPlaygroundIP,
}

var reservedIPToHost = map[[4]byte]string{
	internalAPIIP:        InternalAPIHost,
	internalCacheIP:      InternalCacheHost,
	internalGitIP:        InternalGitHost,
	internalPlaygroundIP: InternalPlaygroundHost,
}

var deniedIPv4CIDRs = mustParseCIDRs(
	"0.0.0.0/8",       // "this" network
	"10.0.0.0/8",      // RFC1918
	"100.64.0.0/10",   // CGNAT & Tailscale
	"127.0.0.0/8",     // loopback
	"169.254.0.0/16",  // link-local & cloud IMDS
	"172.16.0.0/12",   // RFC1918
	"192.0.0.0/24",    // IETF protocol assignments
	"192.0.2.0/24",    // TEST-NET-1
	"192.168.0.0/16",  // RFC1918
	"198.18.0.0/15",   // Vesper synthetic DNS range / benchmarking
	"198.51.100.0/24", // TEST-NET-2
	"203.0.113.0/24",  // TEST-NET-3
	"224.0.0.0/4",     // multicast
	"240.0.0.0/4",     // reserved / broadcast
)

func mustParseCIDRs(cidrs ...string) []*net.IPNet {
	out := make([]*net.IPNet, len(cidrs))
	for i, s := range cidrs {
		_, n, err := net.ParseCIDR(s)
		if err != nil {
			panic(err)
		}
		out[i] = n
	}
	return out
}

// IsAllowedPublicIP reports whether ip is a routable public internet address
// allowed as a destination for VM egress (rejecting loopback, RFC1918, IMDS,
// CGNAT/Tailscale, ULA, and Vesper's synthetic subnet).
func IsAllowedPublicIP(ip net.IP) bool {
	if ip == nil {
		return false
	}
	if ip4 := ip.To4(); ip4 != nil {
		for _, n := range deniedIPv4CIDRs {
			if n.Contains(ip4) {
				return false
			}
		}
		return ip4.IsGlobalUnicast()
	}
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() || ip.IsMulticast() || ip.IsUnspecified() {
		return false
	}
	return true
}

// SyntheticEntry binds a synthetic 198.18.x.x IP to a verified hostname and
// its pinned public IP addresses.
type SyntheticEntry struct {
	Hostname  string
	RealIPs   []net.IP
	ExpiresAt time.Time
}

// SyntheticTable maps public hostnames queried by a microVM to per-VM synthetic
// IPv4 addresses inside 198.18.0.0/15.
type SyntheticTable struct {
	mu      sync.RWMutex
	now     func() time.Time
	ttl     time.Duration
	cursor  uint32 // offset within 198.18.0.0/15 starting at 16
	byHost  map[string][4]byte
	byIP    map[[4]byte]SyntheticEntry
	ringIPs [][4]byte
}

func NewSyntheticTable() *SyntheticTable {
	return &SyntheticTable{
		now:    time.Now,
		ttl:    5 * time.Minute,
		cursor: 16,
		byHost: make(map[string][4]byte),
		byIP:   make(map[[4]byte]SyntheticEntry),
	}
}

func (t *SyntheticTable) LookupHost(host string) ([4]byte, bool) {
	norm := normalizeHostname(host)
	if ip, ok := reservedHostToIP[norm]; ok {
		return ip, true
	}
	t.mu.RLock()
	defer t.mu.RUnlock()
	ip, ok := t.byHost[norm]
	if !ok {
		return [4]byte{}, false
	}
	ent, ok := t.byIP[ip]
	if !ok || t.now().After(ent.ExpiresAt) {
		return [4]byte{}, false
	}
	return ip, true
}

func (t *SyntheticTable) Allocate(host string, realIPs []net.IP) [4]byte {
	norm := normalizeHostname(host)
	if ip, ok := reservedHostToIP[norm]; ok {
		return ip
	}
	pinned := make([]net.IP, len(realIPs))
	for i, ip := range realIPs {
		pinned[i] = append(net.IP(nil), ip...)
	}
	exp := t.now().Add(t.ttl)

	t.mu.Lock()
	defer t.mu.Unlock()
	if existing, ok := t.byHost[norm]; ok {
		t.byIP[existing] = SyntheticEntry{Hostname: norm, RealIPs: pinned, ExpiresAt: exp}
		return existing
	}

	const maxOffset = (2 << 16) - 2 // 198.18.0.16 .. 198.19.255.254
	off := t.cursor
	t.cursor++
	if t.cursor > maxOffset {
		t.cursor = 16
	}
	ip := [4]byte{198, byte(18 + (off >> 16)), byte((off >> 8) & 0xff), byte(off & 0xff)}
	if old, occupied := t.byIP[ip]; occupied && old.Hostname != norm {
		delete(t.byHost, old.Hostname)
	}
	t.byHost[norm] = ip
	t.byIP[ip] = SyntheticEntry{Hostname: norm, RealIPs: pinned, ExpiresAt: exp}
	return ip
}

func (t *SyntheticTable) LookupIP(ip [4]byte) (SyntheticEntry, bool) {
	if host, ok := reservedIPToHost[ip]; ok {
		return SyntheticEntry{Hostname: host}, true
	}
	t.mu.RLock()
	defer t.mu.RUnlock()
	ent, ok := t.byIP[ip]
	if !ok || t.now().After(ent.ExpiresAt) {
		return SyntheticEntry{}, false
	}
	return ent, true
}

func normalizeHostname(h string) string {
	return strings.ToLower(strings.TrimSuffix(strings.TrimSpace(h), "."))
}

// EgressConfig configures the host-side DNS and TCP egress proxy for one VM.
type EgressConfig struct {
	Log               *slog.Logger
	APIHandler        http.Handler
	CacheHandler      http.Handler
	GitHandler        http.Handler
	PlaygroundHandler http.Handler
	Resolver          func(ctx context.Context, host string) ([]net.IP, error)
	DialTimeout       time.Duration
	// Optional static host -> host:port overrides used only in tests.
	TestUpstreams map[string]string
}

// Egress enforces hostname-pinned outbound TCP and internal service routing
// for a NIC-less microVM over AF_VSOCK.
type Egress struct {
	cfg   EgressConfig
	table *SyntheticTable
	log   *slog.Logger

	dynMu             sync.RWMutex
	cacheHandler      http.Handler
	gitHandler        http.Handler
	playgroundHandler http.Handler

	servers   []*http.Server
	listeners []*memListener
	closeOnce sync.Once
	closed    chan struct{}
}

func NewEgress(cfg EgressConfig) *Egress {
	if cfg.Log == nil {
		cfg.Log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}
	if cfg.Resolver == nil {
		cfg.Resolver = func(ctx context.Context, host string) ([]net.IP, error) {
			return net.DefaultResolver.LookupIP(ctx, "ip4", host)
		}
	}
	if cfg.DialTimeout <= 0 {
		cfg.DialTimeout = 10 * time.Second
	}
	e := &Egress{
		cfg:               cfg,
		table:             NewSyntheticTable(),
		log:               cfg.Log,
		cacheHandler:      cfg.CacheHandler,
		gitHandler:        cfg.GitHandler,
		playgroundHandler: cfg.PlaygroundHandler,
		closed:            make(chan struct{}),
	}
	e.mountHTTPService(internalAPIIP, blockInternalAPI(cfg.APIHandler))
	e.mountDynamicHTTPService(internalCacheIP, func() http.Handler {
		e.dynMu.RLock()
		defer e.dynMu.RUnlock()
		return e.cacheHandler
	})
	e.mountDynamicHTTPService(internalGitIP, func() http.Handler {
		e.dynMu.RLock()
		defer e.dynMu.RUnlock()
		return e.gitHandler
	})
	e.mountDynamicHTTPService(internalPlaygroundIP, func() http.Handler {
		e.dynMu.RLock()
		defer e.dynMu.RUnlock()
		return e.playgroundHandler
	})
	return e
}

func (e *Egress) SetGitHandler(h http.Handler) {
	e.dynMu.Lock()
	e.gitHandler = h
	e.dynMu.Unlock()
}

func (e *Egress) SetPlaygroundHandler(h http.Handler) {
	e.dynMu.Lock()
	e.playgroundHandler = h
	e.dynMu.Unlock()
}

func (e *Egress) mountDynamicHTTPService(ip [4]byte, lookup func() http.Handler) {
	e.mountHTTPService(ip, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := lookup()
		if h == nil {
			http.NotFound(w, r)
			return
		}
		h.ServeHTTP(w, r)
	}))
}

func (e *Egress) Table() *SyntheticTable { return e.table }

func (e *Egress) mountHTTPService(ip [4]byte, handler http.Handler) {
	if handler == nil {
		return
	}
	ln := newMemListener(&net.TCPAddr{IP: net.IPv4(ip[0], ip[1], ip[2], ip[3]), Port: 80})
	srv := &http.Server{Handler: handler}
	e.listeners = append(e.listeners, ln)
	e.servers = append(e.servers, srv)
	go func() { _ = srv.Serve(ln) }()
}

func blockInternalAPI(h http.Handler) http.Handler {
	if h == nil {
		return nil
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		p := r.URL.Path
		if p == "/internal" || strings.HasPrefix(p, "/internal/") {
			http.NotFound(w, r)
			return
		}
		h.ServeHTTP(w, r)
	})
}

func (e *Egress) Close() error {
	e.closeOnce.Do(func() {
		close(e.closed)
		for _, ln := range e.listeners {
			_ = ln.Close()
		}
		for _, s := range e.servers {
			_ = s.Close()
		}
	})
	return nil
}

// Listeners returns the PortEgressDNS and PortEgressTCP vsock handlers to
// wire into VMConfig.Listeners.
func (e *Egress) Listeners() map[uint32]VSockHandler {
	return map[uint32]VSockHandler{
		guestproto.PortEgressDNS: e.ServeDNSConn,
		guestproto.PortEgressTCP: e.ServeTCPConn,
	}
}

func (e *Egress) ServeDNSConn(conn net.Conn) {
	defer conn.Close()
	for {
		pkt, err := guestproto.ReadDNSFrame(conn)
		if err != nil || len(pkt) == 0 {
			return
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		resp, err := e.HandleDNSPacket(ctx, pkt)
		cancel()
		if err != nil || len(resp) == 0 {
			return
		}
		if err := guestproto.WriteDNSFrame(conn, resp); err != nil {
			return
		}
	}
}

func (e *Egress) HandleDNSPacket(ctx context.Context, pkt []byte) ([]byte, error) {
	var p dnsmessage.Parser
	hdr, err := p.Start(pkt)
	if err != nil {
		return nil, err
	}
	q, err := p.Question()
	if err != nil {
		return nil, err
	}
	respHdr := dnsmessage.Header{
		ID:                 hdr.ID,
		Response:           true,
		RecursionDesired:   hdr.RecursionDesired,
		RecursionAvailable: true,
		RCode:              dnsmessage.RCodeSuccess,
	}

	host := normalizeHostname(q.Name.String())
	if reservedIP, isReserved := reservedHostToIP[host]; isReserved {
		b := dnsmessage.NewBuilder(nil, respHdr)
		_ = b.StartQuestions()
		_ = b.Question(q)
		_ = b.StartAnswers()
		if q.Type == dnsmessage.TypeA {
			_ = b.AResource(
				dnsmessage.ResourceHeader{Name: q.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60},
				dnsmessage.AResource{A: reservedIP},
			)
		}
		return b.Finish()
	}

	// Empty NODATA for AAAA (and non-A) so dual-stack clients dial synthetic A.
	if q.Type != dnsmessage.TypeA {
		b := dnsmessage.NewBuilder(nil, respHdr)
		_ = b.StartQuestions()
		_ = b.Question(q)
		return b.Finish()
	}

	var allowed []net.IP
	if e.cfg.TestUpstreams != nil {
		if _, ok := e.cfg.TestUpstreams[host]; ok {
			// Still allocate synthetic entry while recording sentinel allowed marker; Dial uses TestUpstreams override.
			synth := e.table.Allocate(host, nil)
			return buildDNSAResponse(respHdr, q, synth)
		}
	}

	ips, rerr := e.cfg.Resolver(ctx, host)
	if rerr == nil {
		for _, ip := range ips {
			if ip4 := ip.To4(); ip4 != nil && IsAllowedPublicIP(ip4) {
				allowed = append(allowed, ip4)
			}
		}
	}
	if len(allowed) == 0 {
		respHdr.RCode = dnsmessage.RCodeRefused
		if rerr != nil {
			respHdr.RCode = dnsmessage.RCodeNameError
		}
		b := dnsmessage.NewBuilder(nil, respHdr)
		_ = b.StartQuestions()
		_ = b.Question(q)
		return b.Finish()
	}

	synth := e.table.Allocate(host, allowed)
	return buildDNSAResponse(respHdr, q, synth)
}

func buildDNSAResponse(hdr dnsmessage.Header, q dnsmessage.Question, ip [4]byte) ([]byte, error) {
	b := dnsmessage.NewBuilder(nil, hdr)
	_ = b.StartQuestions()
	_ = b.Question(q)
	_ = b.StartAnswers()
	_ = b.AResource(
		dnsmessage.ResourceHeader{Name: q.Name, Type: dnsmessage.TypeA, Class: dnsmessage.ClassINET, TTL: 60},
		dnsmessage.AResource{A: ip},
	)
	return b.Finish()
}

func (e *Egress) ServeTCPConn(conn net.Conn) {
	closedByCallee := false
	defer func() {
		if !closedByCallee {
			_ = conn.Close()
		}
	}()

	dstIP, dstPort, err := guestproto.ReadEgressTCPHeader(conn)
	if err != nil {
		return
	}

	if _, isReserved := reservedIPToHost[dstIP]; isReserved {
		if e.handleInternalTCP(conn, dstIP, dstPort) {
			closedByCallee = true
		}
		return
	}

	ent, ok := e.table.LookupIP(dstIP)
	if !ok || ent.Hostname == "" {
		e.log.Debug("egress rejected unknown or raw IP", "ip", dstIP, "port", dstPort)
		return
	}

	var clientConn net.Conn = conn
	if dstPort == 443 {
		sni, wrapped, err := peekTLSSNI(conn)
		if err != nil || sni == "" || !strings.EqualFold(sni, ent.Hostname) {
			e.log.Debug("egress rejected TLS SNI mismatch", "want", ent.Hostname, "got", sni, "err", err)
			return
		}
		clientConn = wrapped
	}

	up, err := e.dialPinned(ent, dstPort)
	if err != nil {
		e.log.Debug("egress upstream dial failed", "host", ent.Hostname, "port", dstPort, "err", err)
		return
	}
	defer up.Close()

	spliceTCP(clientConn, up)
}

func (e *Egress) handleInternalTCP(conn net.Conn, ip [4]byte, port uint16) bool {
	if port != 80 {
		return false
	}
	var idx int
	switch ip {
	case internalAPIIP:
		idx = 0
	case internalCacheIP:
		idx = 1
	case internalGitIP:
		idx = 2
	case internalPlaygroundIP:
		idx = 3
	default:
		return false
	}
	for _, ln := range e.listeners {
		addr, _ := ln.Addr().(*net.TCPAddr)
		if addr != nil && len(addr.IP.To4()) == 4 {
			b := addr.IP.To4()
			if [4]byte{b[0], b[1], b[2], b[3]} == ip {
				_ = idx
				return ln.enqueue(conn)
			}
		}
	}
	return false
}

func (e *Egress) dialPinned(ent SyntheticEntry, port uint16) (net.Conn, error) {
	if target, ok := e.cfg.TestUpstreams[ent.Hostname]; ok {
		return (&net.Dialer{Timeout: e.cfg.DialTimeout}).Dial("tcp", target)
	}
	if len(ent.RealIPs) == 0 {
		return nil, errors.New("egress: no pinned public IPs")
	}
	dialer := &net.Dialer{
		Timeout: e.cfg.DialTimeout,
		Control: func(network, address string, c syscall.RawConn) error {
			host, _, err := net.SplitHostPort(address)
			if err != nil {
				return err
			}
			parsed := net.ParseIP(host)
			if !IsAllowedPublicIP(parsed) {
				return errors.New("egress: destination blocked by public IP policy")
			}
			return nil
		},
	}
	var lastErr error
	portStr := strconv.Itoa(int(port))
	for _, ip := range ent.RealIPs {
		c, err := dialer.Dial("tcp", net.JoinHostPort(ip.String(), portStr))
		if err == nil {
			return c, nil
		}
		lastErr = err
	}
	return nil, lastErr
}

var errPeekDone = errors.New("tls sni captured")

func peekTLSSNI(conn net.Conn) (string, net.Conn, error) {
	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	defer func() { _ = conn.SetReadDeadline(time.Time{}) }()

	var captured bytes.Buffer
	var sni string
	pc := &peekCaptureConn{inner: conn, buf: &captured, limit: 16 << 10}
	tlsSrv := tls.Server(pc, &tls.Config{
		GetConfigForClient: func(chi *tls.ClientHelloInfo) (*tls.Config, error) {
			sni = chi.ServerName
			return nil, errPeekDone
		},
	})
	_ = tlsSrv.Handshake()
	wrapped := &prefixConn{
		Reader: io.MultiReader(bytes.NewReader(captured.Bytes()), conn),
		Conn:   conn,
	}
	if sni == "" {
		return "", wrapped, errors.New("missing TLS ClientHello SNI")
	}
	return sni, wrapped, nil
}

type peekCaptureConn struct {
	inner net.Conn
	buf   *bytes.Buffer
	limit int
}

func (p *peekCaptureConn) Read(b []byte) (int, error) {
	if p.buf.Len() >= p.limit {
		return 0, io.ErrShortBuffer
	}
	n, err := p.inner.Read(b)
	if n > 0 {
		p.buf.Write(b[:n])
	}
	return n, err
}

func (p *peekCaptureConn) Write([]byte) (int, error)          { return 0, errPeekDone }
func (p *peekCaptureConn) Close() error                       { return nil }
func (p *peekCaptureConn) LocalAddr() net.Addr                { return p.inner.LocalAddr() }
func (p *peekCaptureConn) RemoteAddr() net.Addr               { return p.inner.RemoteAddr() }
func (p *peekCaptureConn) SetDeadline(t time.Time) error      { return p.inner.SetDeadline(t) }
func (p *peekCaptureConn) SetReadDeadline(t time.Time) error  { return p.inner.SetReadDeadline(t) }
func (p *peekCaptureConn) SetWriteDeadline(t time.Time) error { return nil }

type prefixConn struct {
	io.Reader
	net.Conn
}

func (c *prefixConn) Read(b []byte) (int, error) { return c.Reader.Read(b) }

func spliceTCP(a, b net.Conn) {
	var wg sync.WaitGroup
	wg.Add(2)
	copySide := func(dst, src net.Conn) {
		defer wg.Done()
		_, _ = io.Copy(dst, src)
		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		}
	}
	go copySide(b, a)
	go copySide(a, b)
	wg.Wait()
}

type memListener struct {
	addr   net.Addr
	conns  chan net.Conn
	closed chan struct{}
	once   sync.Once
}

func newMemListener(addr net.Addr) *memListener {
	return &memListener{
		addr:   addr,
		conns:  make(chan net.Conn, 64),
		closed: make(chan struct{}),
	}
}

func (l *memListener) enqueue(c net.Conn) bool {
	select {
	case <-l.closed:
		return false
	case l.conns <- c:
		return true
	}
}

func (l *memListener) Accept() (net.Conn, error) {
	select {
	case <-l.closed:
		return nil, net.ErrClosed
	case c := <-l.conns:
		return c, nil
	}
}

func (l *memListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return nil
}

func (l *memListener) Addr() net.Addr { return l.addr }
