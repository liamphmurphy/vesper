package usersecrets

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"html"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

// jwt is a token-shaped value whose exp is 2026-11-15T00:00:00Z.
func jwt(t *testing.T) string {
	t.Helper()
	enc := base64.RawURLEncoding.EncodeToString
	return enc([]byte(`{"alg":"HS256"}`)) + "." + enc([]byte(`{"sub":"liam","exp":1794700800}`)) + ".c2lnbmF0dXJlLXRoYXQtaXMtc2VjcmV0"
}

func secret(placement, key string, hosts ...string) store.UserSecret {
	return store.UserSecret{Handle: "acme-jwt", Placement: placement, PlacementKey: key, AllowedHosts: hosts, ReadPolicy: PolicyAllow, WritePolicy: PolicyAsk}
}

func TestJWTExpiry(t *testing.T) {
	got := JWTExpiry(jwt(t))
	if got == nil || !got.Equal(time.Date(2026, 11, 15, 0, 0, 0, 0, time.UTC)) {
		t.Fatalf("exp = %v", got)
	}
	for _, v := range []string{"sk_live_abc123", "a.b.c", "x." + base64.RawURLEncoding.EncodeToString([]byte(`{"sub":"x"}`)) + ".y"} {
		if JWTExpiry(v) != nil {
			t.Errorf("%q has no exp", v)
		}
	}
}

func TestNormalizeHost(t *testing.T) {
	for in, want := range map[string]string{"API.acme.com": "api.acme.com", "https://api.acme.com/v1?x": "api.acme.com", "localhost:8080": "localhost", "api.acme.com.": "api.acme.com", "127.0.0.1": "127.0.0.1"} {
		if got, err := NormalizeHost(in); err != nil || got != want {
			t.Errorf("%q = %q %v, want %q", in, got, err, want)
		}
	}
	for _, in := range []string{"*.acme.com", "", "acme com", "-bad.com"} {
		if _, err := NormalizeHost(in); err == nil {
			t.Errorf("%q accepted", in)
		}
	}
}

func TestCheckRefusesBeforeSending(t *testing.T) {
	s := &Service{Now: func() time.Time { return time.Date(2026, 11, 9, 0, 0, 0, 0, time.UTC) }}
	sec := secret(PlacementQuery, "api_key", "api.acme.com")
	cases := map[string]Request{
		"can only be sent to":  {URL: "https://paste.example.net/u"},
		"lookalike host":       {URL: "https://api.acme.com.evil.net/"},
		"use https":            {URL: "http://api.acme.com/v1"},
		"Authorization header": {URL: "https://api.acme.com/", Headers: map[string]string{"Authorization": "x"}},
		"query parameter out":  {URL: "https://api.acme.com/?api_key=guess"},
		"can't have a body":    {URL: "https://api.acme.com/", Body: []byte("x")},
		"method must be":       {Method: "TRACE", URL: "https://api.acme.com/"},
		"can't contain creds":  {URL: "https://u:p@api.acme.com/"},
		"line break in header": {URL: "https://api.acme.com/", Headers: map[string]string{"X-A": "a\r\nAuthorization: b"}},
		"must be a full URL":   {URL: "/v1/orders"},
	}
	for name, req := range cases {
		if _, err := s.Check(sec, req); err == nil {
			t.Errorf("%s: accepted", name)
		} else if b := (*Blocked)(nil); !errors.As(err, &b) {
			t.Errorf("%s: %T is not Blocked", name, err)
		}
	}
	c, err := s.Check(sec, Request{Method: "post", URL: "https://API.acme.com/v1/refunds", Body: []byte("{}")})
	if err != nil || !c.Write || c.Policy != PolicyAsk || c.Method != "POST" {
		t.Fatalf("write = %+v %v", c, err)
	}
	if c, err = s.Check(sec, Request{URL: "https://api.acme.com/v1/orders"}); err != nil || c.Write || c.Policy != PolicyAllow {
		t.Fatalf("read = %+v %v", c, err)
	}
	off := sec
	off.WritePolicy = PolicyOff
	if _, err := s.Check(off, Request{Method: "DELETE", URL: "https://api.acme.com/x"}); err == nil || !strings.Contains(err.Error(), "turned off") {
		t.Fatalf("off: %v", err)
	}
	expired := sec
	past := time.Date(2026, 11, 8, 0, 0, 0, 0, time.UTC)
	expired.ExpiresAt = &past
	if _, err := s.Check(expired, Request{URL: "https://api.acme.com/"}); err == nil || !strings.Contains(err.Error(), "expired") {
		t.Fatalf("expired: %v", err)
	}
}

// The upstream sees the secret where the person put it; the run sees only the placeholder.
func TestSendInjectsAndMasks(t *testing.T) {
	value := jwt(t)
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("X-Echo", r.Header.Get("Authorization"))
		w.Header().Set("Set-Cookie", "session=1")
		sig := strings.Split(value, ".")[2]
		_, _ = io.WriteString(w, `{"auth":"`+r.Header.Get("Authorization")+`","sig":"`+sig+`","b64":"`+base64.StdEncoding.EncodeToString([]byte(value))+`"}`)
	}))
	defer up.Close()
	s := &Service{}
	sec := secret(PlacementBearer, "", "127.0.0.1")
	c, err := s.Check(sec, Request{URL: up.URL + "/v1/me"})
	if err != nil {
		t.Fatal(err)
	}
	res, err := s.Send(context.Background(), sec, value, c, Request{})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(res.Body, value) || strings.Contains(res.Body, strings.Split(value, ".")[2]) || strings.Contains(res.Headers["X-Echo"], value) {
		t.Fatalf("value leaked: %s %v", res.Body, res.Headers)
	}
	if !strings.Contains(res.Body, `"auth":"Bearer ‹acme-jwt›"`) || res.Headers["X-Echo"] != "Bearer ‹acme-jwt›" {
		t.Fatalf("not masked as expected: %s %v", res.Body, res.Headers)
	}
	if res.Redactions != 4 {
		t.Errorf("redactions = %d, want body ×3 + header ×1", res.Redactions)
	}
	if _, ok := res.Headers["Set-Cookie"]; ok {
		t.Error("Set-Cookie passed through")
	}
}

func TestSendPlacements(t *testing.T) {
	var got atomic.Value
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		user, pass, _ := r.BasicAuth()
		got.Store(r.Header.Get("X-Api-Key") + "|" + r.URL.Query().Get("api_key") + "|" + user + ":" + pass + "|" + r.URL.Query().Get("page"))
	}))
	defer up.Close()
	s := &Service{}
	for _, tc := range []struct{ placement, key, value, want string }{
		{PlacementHeader, "X-Api-Key", "k-1234567890", "k-1234567890||:|2"},
		{PlacementQuery, "api_key", "q-1234567890", "|q-1234567890|:|2"},
		{PlacementBasic, "", "bot:pw-1234567890", "||bot:pw-1234567890|2"},
	} {
		sec := secret(tc.placement, tc.key, "localhost")
		c, err := s.Check(sec, Request{URL: strings.Replace(up.URL, "127.0.0.1", "localhost", 1) + "/?page=2"})
		if err != nil {
			t.Fatal(err)
		}
		if _, err := s.Send(context.Background(), sec, tc.value, c, Request{}); err != nil {
			t.Fatal(err)
		}
		if got.Load() != tc.want {
			t.Errorf("%s: upstream saw %q, want %q", tc.placement, got.Load(), tc.want)
		}
	}
}

// A redirect off the allowed host comes back as-is; the secret never follows it.
func TestSendDoesNotFollowRedirectsElsewhere(t *testing.T) {
	var hit atomic.Bool
	other := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hit.Store(true) }))
	defer other.Close()
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/same" {
			http.Redirect(w, r, "/final", http.StatusFound)
			return
		}
		if r.URL.Path == "/final" {
			_, _ = io.WriteString(w, "auth="+r.Header.Get("Authorization"))
			return
		}
		http.Redirect(w, r, strings.Replace(other.URL, "127.0.0.1", "localhost", 1), http.StatusFound)
	}))
	defer up.Close()
	s := &Service{}
	sec := secret(PlacementBearer, "", "127.0.0.1")
	c, _ := s.Check(sec, Request{URL: up.URL + "/away"})
	res, err := s.Send(context.Background(), sec, "tok-1234567890", c, Request{})
	if err != nil || res.Status != http.StatusFound || hit.Load() {
		t.Fatalf("away: %d %v followed=%v", res.Status, err, hit.Load())
	}
	c, _ = s.Check(sec, Request{URL: up.URL + "/same"})
	if res, err = s.Send(context.Background(), sec, "tok-1234567890", c, Request{}); err != nil || res.Body != "auth=Bearer ‹acme-jwt›" {
		t.Fatalf("same host: %q %v", res.Body, err)
	}
}

// An allowed public hostname that resolves to a private address is refused
// at dial time, so DNS can't point a secret at the internal network.
func TestSendBlocksPrivateAddresses(t *testing.T) {
	var hit atomic.Bool
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hit.Store(true) }))
	defer up.Close()
	port := up.URL[strings.LastIndex(up.URL, ":")+1:]
	s := &Service{LookupIP: func(context.Context, string) ([]net.IP, error) { return []net.IP{net.ParseIP("127.0.0.1")}, nil }}
	sec := secret(PlacementBearer, "", "api.acme.test")
	u, _ := url.Parse("https://api.acme.test:" + port + "/")
	_, err := s.Send(context.Background(), sec, "tok-1234567890", Checked{Method: "GET", URL: u}, Request{})
	var b *Blocked
	if !errors.As(err, &b) || !strings.Contains(err.Error(), "private address") || hit.Load() {
		t.Fatalf("err = %v, hit = %v", err, hit.Load())
	}
	for _, ip := range []string{"10.0.0.1", "169.254.169.254", "192.168.1.1", "100.64.0.1", "::1", "fd00::1", "0.0.0.0"} {
		if !blockedAddr(net.ParseIP(ip)) {
			t.Errorf("%s not blocked", ip)
		}
	}
	if blockedAddr(net.ParseIP("93.184.216.34")) {
		t.Error("public address blocked")
	}
}

// Error text that would contain a query-placed value is masked too.
func TestSendMasksErrors(t *testing.T) {
	s := &Service{}
	sec := secret(PlacementQuery, "api_key", "localhost")
	// Nothing listens on port 1.
	c, err := s.Check(sec, Request{URL: "http://localhost:1/x"})
	if err != nil {
		t.Fatal(err)
	}
	_, err = s.Send(context.Background(), sec, "q-secret-1234567890", c, Request{})
	if err == nil || strings.Contains(err.Error(), "q-secret-1234567890") {
		t.Fatalf("err = %v", err)
	}
}

// Echoes an allowed host could send back, each of which once leaked part or
// all of the value past masking.
func TestSendMasksEchoesThatUsedToLeak(t *testing.T) {
	const value = "sk/live+AB12cd34EF56gh78"
	echo := func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/split":
			// Padding puts the value across the 1 MB cut.
			w.Header().Set("Content-Type", "text/plain")
			_, _ = io.WriteString(w, strings.Repeat("a", maxResponse-10)+value)
		case "/encoded":
			w.Header().Set("Content-Type", "application/json")
			_, _ = io.WriteString(w, `{"json":"sk\/live+AB12cd34EF56gh78","pct":"sk%2flive%2bAB12cd34EF56gh78","hex":"`+hex.EncodeToString([]byte(value))+`","html":"`+html.EscapeString(value)+`"}`)
		case "/ctype":
			w.Header().Set("Content-Type", "application/octet-stream; token="+value)
			_, _ = w.Write([]byte{0, 1, 2})
		}
	}
	up := httptest.NewServer(http.HandlerFunc(echo))
	defer up.Close()
	s := &Service{}
	sec := secret(PlacementBearer, "", "127.0.0.1")
	leaks := func(text string) bool {
		for _, frag := range []string{value[:6], value[6:12], "AB12cd34", hex.EncodeToString([]byte(value))[:12]} {
			if strings.Contains(text, frag) {
				return true
			}
		}
		return false
	}
	for _, path := range []string{"/split", "/encoded", "/ctype"} {
		c, err := s.Check(sec, Request{URL: up.URL + path})
		if err != nil {
			t.Fatal(err)
		}
		res, err := s.Send(context.Background(), sec, value, c, Request{})
		if err != nil {
			t.Fatal(err)
		}
		if leaks(res.Body) || leaks(res.ContentType) || leaks(fmt.Sprint(res.Headers)) {
			t.Errorf("%s leaked: content-type %q, body …%q", path, res.ContentType, res.Body[max(0, len(res.Body)-60):])
		}
		if path == "/split" && (!res.Truncated || len(res.Body) > maxResponse) {
			t.Errorf("split: truncated=%v len=%d", res.Truncated, len(res.Body))
		}
	}
	// A value too short to tell from ordinary text is still masked.
	short := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "auth="+r.Header.Get("Authorization"))
	}))
	defer short.Close()
	c, _ := s.Check(sec, Request{URL: short.URL})
	if res, err := s.Send(context.Background(), sec, "k3y9", c, Request{}); err != nil || strings.Contains(res.Body, "k3y9") {
		t.Fatalf("short value: %q %v", res.Body, err)
	}
}

func TestCheckRefusesHeadersThatDefeatMasking(t *testing.T) {
	s := &Service{}
	sec := secret(PlacementHeader, "X-Api-Key", "api.acme.com")
	for _, h := range []string{"Range", "If-Range", "Accept-Encoding", "X_Api_Key", "x-api-key"} {
		if _, err := s.Check(sec, Request{URL: "https://api.acme.com/", Headers: map[string]string{h: "x"}}); err == nil {
			t.Errorf("%s accepted", h)
		}
	}
	if _, err := s.Check(sec, Request{Method: "POST", URL: "https://api.acme.com/", Body: []byte{0xff, 0xfe}}); err == nil {
		t.Error("a body the person couldn't read was accepted")
	}
}

// A write's 307 would resend the approved body, with the secret, to a path
// nobody approved.
func TestSendDoesNotFollowRedirectsOnWrites(t *testing.T) {
	var resent atomic.Bool
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/elsewhere" {
			resent.Store(true)
			return
		}
		http.Redirect(w, r, "/elsewhere", http.StatusTemporaryRedirect)
	}))
	defer up.Close()
	s := &Service{}
	sec := secret(PlacementBearer, "", "127.0.0.1")
	c, _ := s.Check(sec, Request{Method: "POST", URL: up.URL + "/refunds", Body: []byte("{}")})
	res, err := s.Send(context.Background(), sec, "tok-1234567890", c, Request{Body: []byte("{}")})
	if err != nil || res.Status != http.StatusTemporaryRedirect || resent.Load() {
		t.Fatalf("status %d, err %v, resent %v", res.Status, err, resent.Load())
	}
}

func TestBlockedAddrCoversTransitionAndReservedRanges(t *testing.T) {
	for _, ip := range []string{"64:ff9b::a00:1", "64:ff9b::a9fe:a9fe", "2002:a00:1::1", "::a00:1", "fec0::1", "198.18.0.1", "240.0.0.1", "2001:0:5ef5:79fd::1", "64:ff9b:1::1"} {
		if !blockedAddr(net.ParseIP(ip)) {
			t.Errorf("%s not blocked", ip)
		}
	}
	// Transition addresses that carry a public IPv4 stay reachable.
	for _, ip := range []string{"64:ff9b::5db8:d822", "2002:5db8:d822::1", "2606:4700::1111"} {
		if blockedAddr(net.ParseIP(ip)) {
			t.Errorf("%s blocked", ip)
		}
	}
}

func TestSendPublicBinaryAndText(t *testing.T) {
	pngBytes := []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0x00, 0x01, 0x02, 0xff}
	exactCap := bytes.Repeat([]byte{0xab}, maxPublicResponse)
	overCap := bytes.Repeat([]byte{0xcd}, maxPublicResponse+32)
	// A 1080p60 Twitch segment is about 2 MB; a custom app's fetch used to cut it at 1 MB.
	segment := bytes.Repeat([]byte{0x47}, 2<<20)

	srv := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/thumb.png":
			w.Header().Set("Content-Type", "image/png; charset=binary")
			w.Header().Set("Set-Cookie", "track=1")
			_, _ = w.Write(pngBytes)
		case "/empty.png":
			w.Header().Set("Content-Type", "image/png")
		case "/exact.bin":
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = w.Write(exactCap)
		case "/over.bin":
			w.Header().Set("Content-Type", "application/octet-stream")
			_, _ = w.Write(overCap)
		case "/segment.ts":
			w.Header().Set("Content-Type", "video/mp2t")
			_, _ = w.Write(segment)
		case "/icon.svg":
			w.Header().Set("Content-Type", "image/svg+xml")
			_, _ = io.WriteString(w, `<svg xmlns="http://www.w3.org/2000/svg"/>`)
		}
	}))
	defer srv.Close()

	// Binary image populates Binary + BodyBase64 while keeping summary Body and stripping Set-Cookie.
	res, err := sendPublic(context.Background(), Request{URL: srv.URL + "/thumb.png"}, srv.Client().Transport)
	if err != nil {
		t.Fatalf("thumb.png: %v", err)
	}
	if !res.Binary || res.Truncated {
		t.Fatalf("unexpected flags: binary=%v truncated=%v", res.Binary, res.Truncated)
	}
	if _, hasCookie := res.Headers["Set-Cookie"]; hasCookie {
		t.Fatal("Set-Cookie leaked")
	}
	if res.Body != fmt.Sprintf("(%d bytes of image/png; charset=binary, not shown)", len(pngBytes)) {
		t.Fatalf("unexpected summary body: %q", res.Body)
	}
	got, err := base64.StdEncoding.DecodeString(res.BodyBase64)
	if err != nil || !bytes.Equal(got, pngBytes) {
		t.Fatalf("decoded BodyBase64 = %x (%v), want %x", got, err, pngBytes)
	}

	// Empty binary response marks Binary=true with empty BodyBase64.
	res, err = sendPublic(context.Background(), Request{URL: srv.URL + "/empty.png"}, srv.Client().Transport)
	if err != nil {
		t.Fatalf("empty.png: %v", err)
	}
	if !res.Binary || res.BodyBase64 != "" || res.Truncated {
		t.Fatalf("empty.png = %+v", res)
	}

	// Exact maxPublicResponse bytes (25 MB, a 1080p video segment fits) is not truncated; exceeding it sets
	// Truncated=true and caps BodyBase64.
	res, err = sendPublic(context.Background(), Request{URL: srv.URL + "/exact.bin"}, srv.Client().Transport)
	if err != nil || res.Truncated {
		t.Fatalf("exact.bin: truncated=%v err=%v", res.Truncated, err)
	}
	res, err = sendPublic(context.Background(), Request{URL: srv.URL + "/over.bin"}, srv.Client().Transport)
	if err != nil || !res.Truncated {
		t.Fatalf("over.bin: truncated=%v err=%v", res.Truncated, err)
	}
	if got, _ := base64.StdEncoding.DecodeString(res.BodyBase64); len(got) != maxPublicResponse {
		t.Fatalf("over.bin decoded len = %d, want %d", len(got), maxPublicResponse)
	}

	res, err = sendPublic(context.Background(), Request{URL: srv.URL + "/segment.ts"}, srv.Client().Transport)
	if err != nil || res.Truncated {
		t.Fatalf("segment.ts: truncated=%v err=%v", res.Truncated, err)
	}
	if got, _ := base64.StdEncoding.DecodeString(res.BodyBase64); len(got) != len(segment) {
		t.Fatalf("segment.ts decoded len = %d, want %d", len(got), len(segment))
	}

	// Textual image (SVG) stays in Body without BodyBase64.
	res, err = sendPublic(context.Background(), Request{URL: srv.URL + "/icon.svg"}, srv.Client().Transport)
	if err != nil {
		t.Fatalf("icon.svg: %v", err)
	}
	if res.Binary || res.BodyBase64 != "" || !strings.Contains(res.Body, "<svg") {
		t.Fatalf("icon.svg = %+v", res)
	}

	// Non-HTTPS and private IPs remain blocked on SendPublic.
	if _, err := SendPublic(context.Background(), Request{URL: "http://example.com/a.png"}, nil); err == nil {
		t.Fatal("expected http:// to be blocked")
	}
}
