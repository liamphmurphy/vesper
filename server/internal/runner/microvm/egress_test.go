package microvm

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"io"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"golang.org/x/net/dns/dnsmessage"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

func TestIsAllowedPublicIP(t *testing.T) {
	blocked := []string{
		"0.0.0.0",
		"127.0.0.1",
		"10.0.0.1",
		"100.64.0.1",
		"100.100.100.100",
		"169.254.169.254",
		"172.16.0.1",
		"172.31.255.254",
		"192.168.1.1",
		"198.18.0.1",
		"198.19.255.254",
		"224.0.0.1",
		"::1",
		"fc00::1",
		"fd7a:115c:a1e0::1",
		"fe80::1",
		"::ffff:127.0.0.1",
		"::ffff:169.254.169.254",
	}
	for _, s := range blocked {
		if IsAllowedPublicIP(net.ParseIP(s)) {
			t.Errorf("expected %s to be blocked", s)
		}
	}
	allowed := []string{
		"1.1.1.1",
		"8.8.8.8",
		"140.82.112.4",
		"2606:4700:4700::1111",
	}
	for _, s := range allowed {
		if !IsAllowedPublicIP(net.ParseIP(s)) {
			t.Errorf("expected %s to be allowed", s)
		}
	}
}

func makeDNSQuery(t *testing.T, name string, qtype dnsmessage.Type) []byte {
	t.Helper()
	b := dnsmessage.NewBuilder(nil, dnsmessage.Header{ID: 0x1234, RecursionDesired: true})
	_ = b.StartQuestions()
	_ = b.Question(dnsmessage.Question{
		Name:  dnsmessage.MustNewName(name + "."),
		Type:  qtype,
		Class: dnsmessage.ClassINET,
	})
	pkt, err := b.Finish()
	if err != nil {
		t.Fatal(err)
	}
	return pkt
}

func parseDNSResponse(t *testing.T, pkt []byte) (dnsmessage.Header, [][4]byte) {
	t.Helper()
	var p dnsmessage.Parser
	hdr, err := p.Start(pkt)
	if err != nil {
		t.Fatal(err)
	}
	if err := p.SkipAllQuestions(); err != nil {
		t.Fatal(err)
	}
	var ips [][4]byte
	for {
		ah, err := p.AnswerHeader()
		if err == dnsmessage.ErrSectionDone {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		if ah.Type == dnsmessage.TypeA {
			res, err := p.AResource()
			if err != nil {
				t.Fatal(err)
			}
			ips = append(ips, res.A)
		} else {
			if err := p.SkipAnswer(); err != nil {
				t.Fatal(err)
			}
		}
	}
	return hdr, ips
}

func TestEgressDNSBlocksPrivateAndReturnsNODATAForAAAA(t *testing.T) {
	eg := NewEgress(EgressConfig{
		Resolver: func(_ context.Context, host string) ([]net.IP, error) {
			switch host {
			case "rebind.evil":
				return []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("169.254.169.254"), net.ParseIP("100.100.100.100")}, nil
			case "public.example":
				return []net.IP{net.ParseIP("1.1.1.1")}, nil
			}
			return nil, context.DeadlineExceeded
		},
	})
	defer eg.Close()

	// Internal reserved host maps to 198.18.0.1.
	resp, err := eg.HandleDNSPacket(context.Background(), makeDNSQuery(t, InternalAPIHost, dnsmessage.TypeA))
	if err != nil {
		t.Fatal(err)
	}
	hdr, ips := parseDNSResponse(t, resp)
	if hdr.RCode != dnsmessage.RCodeSuccess || len(ips) != 1 || ips[0] != [4]byte{198, 18, 0, 1} {
		t.Fatalf("internal API DNS = %+v %v", hdr.RCode, ips)
	}

	// Host resolving only to private/IMDS/CGNAT IPs must be refused.
	resp, err = eg.HandleDNSPacket(context.Background(), makeDNSQuery(t, "rebind.evil", dnsmessage.TypeA))
	if err != nil {
		t.Fatal(err)
	}
	hdr, ips = parseDNSResponse(t, resp)
	if hdr.RCode == dnsmessage.RCodeSuccess || len(ips) != 0 {
		t.Fatalf("expected refusal for rebind.evil, got rcode=%v ips=%v", hdr.RCode, ips)
	}

	// Public host receives synthetic 198.18.x.x IP and NODATA for AAAA.
	resp, err = eg.HandleDNSPacket(context.Background(), makeDNSQuery(t, "public.example", dnsmessage.TypeA))
	if err != nil {
		t.Fatal(err)
	}
	hdr, ips = parseDNSResponse(t, resp)
	if hdr.RCode != dnsmessage.RCodeSuccess || len(ips) != 1 || ips[0][0] != 198 || (ips[0][1]&0xfe) != 18 {
		t.Fatalf("expected synthetic 198.18/15 IP, got rcode=%v ips=%v", hdr.RCode, ips)
	}

	resp6, err := eg.HandleDNSPacket(context.Background(), makeDNSQuery(t, "public.example", dnsmessage.TypeAAAA))
	if err != nil {
		t.Fatal(err)
	}
	hdr6, ips6 := parseDNSResponse(t, resp6)
	if hdr6.RCode != dnsmessage.RCodeSuccess || len(ips6) != 0 {
		t.Fatalf("expected NOERROR NODATA for AAAA, got rcode=%v ips=%v", hdr6.RCode, ips6)
	}
}

func TestEgressTCPBlocksRawIPsEnforcesSNIAndRoutesInternalAPI(t *testing.T) {
	mux := http.NewServeMux()
	mux.HandleFunc("/mcp", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "mcp-ok")
	})
	mux.HandleFunc("/internal/secret", func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "leaked")
	})

	tlsSrv := newSelfSignedHTTPSServer(t, "allowed.example", http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "tls-ok")
	}))
	defer tlsSrv.Close()

	eg := NewEgress(EgressConfig{
		APIHandler: mux,
		TestUpstreams: map[string]string{
			"allowed.example": strings.TrimPrefix(tlsSrv.URL, "https://"),
		},
	})
	defer eg.Close()

	// 1. Raw literal IP (not allocated by synthetic table) must be closed immediately.
	client, srv := net.Pipe()
	go eg.ServeTCPConn(srv)
	_ = guestproto.WriteEgressTCPHeader(client, net.ParseIP("1.1.1.1"), 443)
	buf := make([]byte, 16)
	_ = client.SetReadDeadline(time.Now().Add(500 * time.Millisecond))
	n, err := client.Read(buf)
	client.Close()
	if err == nil || n != 0 {
		t.Fatalf("expected immediate close on raw IP, got n=%d err=%v", n, err)
	}

	// 2. api.vesper.internal allows /mcp and forces /internal/* to 404.
	hc := &http.Client{
		Transport: &http.Transport{
			DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
				c, s := net.Pipe()
				go eg.ServeTCPConn(s)
				_ = guestproto.WriteEgressTCPHeader(c, net.ParseIP("198.18.0.1"), 80)
				return c, nil
			},
		},
	}
	res, err := hc.Get("http://api.vesper.internal/mcp")
	if err != nil {
		t.Fatal(err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || string(body) != "mcp-ok" {
		t.Fatalf("/mcp got %d %q", res.StatusCode, body)
	}
	res2, err := hc.Get("http://api.vesper.internal/internal/secret")
	if err != nil {
		t.Fatal(err)
	}
	res2.Body.Close()
	if res2.StatusCode != 404 {
		t.Fatalf("/internal/secret got %d, want 404", res2.StatusCode)
	}

	// 3. Allocate synthetic IP for allowed.example; mismatched SNI rejected, matching SNI allowed.
	resp, err := eg.HandleDNSPacket(context.Background(), makeDNSQuery(t, "allowed.example", dnsmessage.TypeA))
	if err != nil {
		t.Fatal(err)
	}
	_, ips := parseDNSResponse(t, resp)
	synthIP := net.IPv4(ips[0][0], ips[0][1], ips[0][2], ips[0][3])

	dialSynth := func(sni string) error {
		c, s := net.Pipe()
		go eg.ServeTCPConn(s)
		if err := guestproto.WriteEgressTCPHeader(c, synthIP, 443); err != nil {
			return err
		}
		tc := tls.Client(c, &tls.Config{ServerName: sni, InsecureSkipVerify: true})
		defer tc.Close()
		if err := tc.Handshake(); err != nil {
			return err
		}
		_, err := tc.Write([]byte("GET / HTTP/1.0\r\nHost: " + sni + "\r\n\r\n"))
		return err
	}
	if err := dialSynth("evil.example"); err == nil {
		t.Fatal("expected SNI mismatch on :443 to fail handshake")
	}
	if err := dialSynth("allowed.example"); err != nil {
		t.Fatalf("matching SNI failed: %v", err)
	}
}

func newSelfSignedHTTPSServer(t *testing.T, dnsName string, h http.Handler) *httptest.Server {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: dnsName},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		DNSNames:     []string{dnsName},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewUnstartedServer(h)
	srv.TLS = &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{der}, PrivateKey: key}}}
	srv.StartTLS()
	return srv
}

func TestEgressRoutesMacHostToItsHandler(t *testing.T) {
	eg := NewEgress(EgressConfig{})
	defer eg.Close()

	resp, err := eg.HandleDNSPacket(context.Background(), makeDNSQuery(t, InternalMacHost, dnsmessage.TypeA))
	if err != nil {
		t.Fatal(err)
	}
	if hdr, ips := parseDNSResponse(t, resp); hdr.RCode != dnsmessage.RCodeSuccess || len(ips) != 1 || ips[0] != internalMacIP {
		t.Fatalf("mac host DNS = %v %v", hdr.RCode, ips)
	}

	hc := &http.Client{Transport: &http.Transport{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			c, s := net.Pipe()
			go eg.ServeTCPConn(s)
			_ = guestproto.WriteEgressTCPHeader(c, net.IP(internalMacIP[:]), 80)
			return c, nil
		},
	}}
	get := func() (int, string) {
		t.Helper()
		res, err := hc.Get("http://" + InternalMacHost + "/v1/start")
		if err != nil {
			t.Fatal(err)
		}
		defer res.Body.Close()
		b, _ := io.ReadAll(res.Body)
		return res.StatusCode, string(b)
	}
	// Off until a run's broker is attached: `mac` reads 404 as "not enabled".
	if code, _ := get(); code != http.StatusNotFound {
		t.Fatalf("no handler: status %d, want 404", code)
	}
	eg.SetMacHandler(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "mac:"+r.URL.Path)
	}))
	if code, body := get(); code != 200 || body != "mac:/v1/start" {
		t.Fatalf("with handler: %d %q", code, body)
	}
}

func TestEgressAllowPublicGate(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "public-ok")
	}))
	defer up.Close()

	allow := false
	resolved := 0
	eg := NewEgress(EgressConfig{
		AllowPublic: func() bool { return allow },
		CacheHandler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			_, _ = io.WriteString(w, "cache-ok")
		}),
		Resolver: func(context.Context, string) ([]net.IP, error) {
			resolved++
			return []net.IP{net.IPv4(93, 184, 216, 34)}, nil
		},
		TestUpstreams: map[string]string{
			"public.example": strings.TrimPrefix(up.URL, "http://"),
		},
	})
	defer eg.Close()

	// 1. Public DNS refused while AllowPublic is false, and resolver is not called.
	resp, err := eg.HandleDNSPacket(context.Background(), makeDNSQuery(t, "public.example", dnsmessage.TypeA))
	if err != nil {
		t.Fatal(err)
	}
	if hdr, ips := parseDNSResponse(t, resp); hdr.RCode != dnsmessage.RCodeRefused || len(ips) != 0 {
		t.Fatalf("public DNS while denied = rcode %v ips %v, want REFUSED", hdr.RCode, ips)
	}
	if resolved != 0 {
		t.Fatalf("resolver called %d times while public egress denied", resolved)
	}

	// 2. Internal host (cache.vesper.internal) remains reachable while public egress is denied.
	cacheResp, err := eg.HandleDNSPacket(context.Background(), makeDNSQuery(t, InternalCacheHost, dnsmessage.TypeA))
	if err != nil {
		t.Fatal(err)
	}
	if hdr, ips := parseDNSResponse(t, cacheResp); hdr.RCode != dnsmessage.RCodeSuccess || len(ips) != 1 || ips[0] != internalCacheIP {
		t.Fatalf("cache DNS while public denied = %v %v", hdr.RCode, ips)
	}
	cacheClient := &http.Client{Transport: &http.Transport{
		DialContext: func(context.Context, string, string) (net.Conn, error) {
			c, s := net.Pipe()
			go eg.ServeTCPConn(s)
			_ = guestproto.WriteEgressTCPHeader(c, net.IP(internalCacheIP[:]), 80)
			return c, nil
		},
	}}
	res, err := cacheClient.Get("http://" + InternalCacheHost + "/nix-cache-info")
	if err != nil {
		t.Fatalf("cache HTTP while public denied: %v", err)
	}
	body, _ := io.ReadAll(res.Body)
	res.Body.Close()
	if res.StatusCode != 200 || string(body) != "cache-ok" {
		t.Fatalf("cache response = %d %q", res.StatusCode, body)
	}

	// 3. Flip AllowPublic true: DNS resolves and TCP dial succeeds.
	allow = true
	resp, err = eg.HandleDNSPacket(context.Background(), makeDNSQuery(t, "public.example", dnsmessage.TypeA))
	if err != nil {
		t.Fatal(err)
	}
	hdr, ips := parseDNSResponse(t, resp)
	if hdr.RCode != dnsmessage.RCodeSuccess || len(ips) != 1 {
		t.Fatalf("public DNS while allowed = %v %v", hdr.RCode, ips)
	}
	synthIP := net.IPv4(ips[0][0], ips[0][1], ips[0][2], ips[0][3])

	dialPublic := func() (string, error) {
		hc := &http.Client{Transport: &http.Transport{
			DisableKeepAlives: true,
			DialContext: func(context.Context, string, string) (net.Conn, error) {
				c, s := net.Pipe()
				go eg.ServeTCPConn(s)
				if err := guestproto.WriteEgressTCPHeader(c, synthIP, 80); err != nil {
					return nil, err
				}
				return c, nil
			},
		}}
		r, err := hc.Get("http://public.example/")
		if err != nil {
			return "", err
		}
		defer r.Body.Close()
		b, err := io.ReadAll(r.Body)
		return string(b), err
	}
	if got, err := dialPublic(); err != nil || got != "public-ok" {
		t.Fatalf("public HTTP while allowed = %q, %v", got, err)
	}

	// 4. Revoke AllowPublic: previously resolved synthetic IP is immediately blocked.
	allow = false
	if got, err := dialPublic(); err == nil {
		t.Fatalf("expected public HTTP after revocation to fail, got %q", got)
	}
}
