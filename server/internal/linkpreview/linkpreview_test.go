package linkpreview

import (
	"bytes"
	"context"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"reflect"
	"strings"
	"testing"
)

func TestRecommendedReadsOnlyRealFences(t *testing.T) {
	md := strings.Join([]string{
		"Try these:", "```recommend", "https://a.example/x", "Why.", "```",
		"~~~ recommend", "https://www.youtube.com/watch?v=dQw4w9WgXcQ", "~~~",
		"```recommend", "https://a.example/x", "```",
		"```recommend", "ftp://a.example", "```",
		"```recommend", "https://u:p@a.example", "```",
		"````md", "```recommend", "https://quoted.example", "```", "````",
		"```go", "https://code.example", "```",
		"```recommend", "https://unclosed.example",
	}, "\n")
	want := []Recommendation{{URL: "https://a.example/x", Note: "Why."}, {URL: "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}}
	if got := Recommended(md); !reflect.DeepEqual(got, want) {
		t.Fatalf("got %v", got)
	}
	var many strings.Builder
	for _, c := range "abcdef" {
		many.WriteString("```recommend\nhttps://" + string(c) + ".example\n```\n")
	}
	if got := Recommended(many.String()); len(got) != MaxPerMessage {
		t.Fatalf("got %d", len(got))
	}
}

func TestPublicRefusesInternalAddresses(t *testing.T) {
	for _, a := range []string{"127.0.0.1", "10.1.2.3", "172.16.0.1", "192.168.1.1", "169.254.169.254", "100.64.0.1", "0.0.0.0", "::1", "fe80::1", "fc00::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1", "64:ff9b::a00:1", "2002:a00:1::", "224.0.0.1"} {
		if public(netip.MustParseAddr(a)) {
			t.Errorf("%s allowed", a)
		}
	}
	for _, a := range []string{"93.184.216.34", "2606:4700:4700::1111"} {
		if !public(netip.MustParseAddr(a)) {
			t.Errorf("%s refused", a)
		}
	}
}

func TestDefaultClientCannotReachLocalServers(t *testing.T) {
	hit := false
	srv := httptest.NewServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) { hit = true }))
	defer srv.Close()
	if p := New().Fetch(context.Background(), srv.URL); p.Title != "" || hit {
		t.Fatalf("reached local server: %+v", p)
	}
	if guardDial("tcp4", "93.184.216.34:22", nil) == nil {
		t.Fatal("port 22 allowed")
	}
	if err := guardDial("tcp4", "93.184.216.34:443", nil); err != nil {
		t.Fatal(err)
	}
}

func TestRedirectToUnusableURLStops(t *testing.T) {
	f := New()
	req := httptest.NewRequest("GET", "ftp://a.example/", nil)
	if f.HTTP.CheckRedirect(req, nil) == nil {
		t.Fatal("ftp redirect followed")
	}
	ok := httptest.NewRequest("GET", "https://a.example/", nil)
	if f.HTTP.CheckRedirect(ok, make([]*http.Request, maxRedirects)) == nil {
		t.Fatal("redirect limit ignored")
	}
}

var png = append([]byte("\x89PNG\r\n\x1a\n"), bytes.Repeat([]byte{0}, 32)...)

func fetcher(t *testing.T, h http.HandlerFunc) (*Fetcher, string) {
	t.Helper()
	srv := httptest.NewServer(h)
	t.Cleanup(srv.Close)
	return &Fetcher{HTTP: srv.Client(), OEmbedBase: srv.URL}, srv.URL
}

func TestSiteReadsMetadataAndResolvesItsImage(t *testing.T) {
	f, base := fetcher(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/img.png" {
			w.Write(png)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write([]byte(`<html><head><title>Fallback</title><meta property="og:title" content=" Quiet
		 routes "><meta name="description" content="Plain"><meta property="og:description" content="Best"><meta property="og:site_name" content="Atlas"><meta property="og:image" content="/img.png"></head><body><meta property="og:title" content="late"></body></html>`))
	})
	p := f.Fetch(context.Background(), base+"/page")
	if p.Kind != KindSite || p.Title != "Quiet routes" || p.Description != "Best" || p.Site != "Atlas" || p.ImageType != "image/png" || len(p.Image) == 0 {
		t.Fatalf("%+v", p)
	}
}

func TestSiteFallsBackAndRefusesNonImages(t *testing.T) {
	f, base := fetcher(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/evil.svg":
			w.Header().Set("Content-Type", "image/png")
			w.Write([]byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>1</script></svg>`))
		case "/file":
			w.Header().Set("Content-Type", "application/pdf")
			w.Write([]byte("%PDF"))
		case "/gone":
			w.WriteHeader(404)
		default:
			w.Header().Set("Content-Type", "text/html")
			w.Write([]byte(`<title>Just a <b>title</title><meta property="og:image" content="/evil.svg">`))
		}
	})
	ctx := context.Background()
	if p := f.Fetch(ctx, base+"/"); p.Title == "" || p.Image != nil {
		t.Fatalf("%+v", p)
	}
	if p := f.Fetch(ctx, base+"/file"); p.Title != "" {
		t.Fatalf("%+v", p)
	}
	if p := f.Fetch(ctx, base+"/gone"); p.Title != "" {
		t.Fatalf("%+v", p)
	}
}

func TestOversizedImageIsDropped(t *testing.T) {
	f, base := fetcher(t, func(w http.ResponseWriter, r *http.Request) { w.Write(append(png, make([]byte, maxImageBytes)...)) })
	if b, _ := f.image(context.Background(), nil, base+"/big.png", ""); b != nil {
		t.Fatal("kept oversized image")
	}
}

func TestVideoUsesOEmbed(t *testing.T) {
	var f *Fetcher
	var base string
	f, base = fetcher(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/thumb.jpg" {
			w.Write(png)
			return
		}
		if r.URL.Path != "/oembed" || r.URL.Query().Get("url") != "https://www.youtube.com/watch?v=dQw4w9WgXcQ" {
			t.Errorf("request %s", r.URL)
		}
		w.Write([]byte(`{"title":"A talk","author_name":"Lab","thumbnail_url":"` + base + `/thumb.jpg"}`))
	})
	p := f.Fetch(context.Background(), "https://youtu.be/dQw4w9WgXcQ?t=4")
	if p.Kind != KindVideo || p.VideoID != "dQw4w9WgXcQ" || p.Title != "A talk" || p.Site != "Lab" || p.Image == nil {
		t.Fatalf("%+v", p)
	}
}

func TestFetchDirectRasterImageAndRejectSVG(t *testing.T) {
	f, base := fetcher(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/photo.png":
			w.Header().Set("Content-Type", "image/png")
			w.Write(png)
		case "/bad.svg":
			w.Header().Set("Content-Type", "image/svg+xml")
			w.Write([]byte(`<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`))
		}
	})
	p := f.Fetch(context.Background(), base+"/photo.png")
	if p.Kind != KindImage || p.ImageType != "image/png" || len(p.Image) == 0 {
		t.Fatalf("expected direct raster image, got %+v", p)
	}
	bad := f.Fetch(context.Background(), base+"/bad.svg")
	if bad.Image != nil || bad.Kind == KindImage {
		t.Fatalf("svg must not be accepted as an image: %+v", bad)
	}
}

var avif = []byte{
	0x00, 0x00, 0x00, 0x1c, // box size = 28
	'f', 't', 'y', 'p',
	'm', 'i', 'f', '1', // major brand
	0x00, 0x00, 0x00, 0x00, // minor version
	'm', 'i', 'f', '1',
	'a', 'v', 'i', 'f', // compatible brand
	'm', 'i', 'a', 'f',
}

func TestSiteRetriesWithBrowserUAOn403AndSendsImageReferer(t *testing.T) {
	var sawPageUA []string
	var imgReferer, imgAccept string
	f, base := fetcher(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/product":
			sawPageUA = append(sawPageUA, r.Header.Get("User-Agent"))
			if strings.Contains(r.Header.Get("User-Agent"), "VesperBot") {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			w.Header().Set("Content-Type", "text/html")
			w.Write([]byte(`<html><head><title>Widget</title><meta property="og:image" content="/cdn/widget.avif"></head></html>`))
		case "/cdn/widget.avif":
			imgReferer = r.Header.Get("Referer")
			imgAccept = r.Header.Get("Accept")
			if imgReferer == "" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			w.Header().Set("Content-Type", "image/avif")
			w.Write(avif)
		}
	})
	p := f.Fetch(context.Background(), base+"/product")
	if p.Title != "Widget" || p.ImageType != "image/avif" || len(p.Image) == 0 {
		t.Fatalf("expected retry + avif with referer, got %+v (UAs=%v referer=%q)", p, sawPageUA, imgReferer)
	}
	if len(sawPageUA) != 2 || !strings.Contains(imgAccept, "image/webp") || imgReferer != base+"/product" {
		t.Fatalf("unexpected headers: UAs=%v accept=%q referer=%q", sawPageUA, imgAccept, imgReferer)
	}
}

func TestFetchDirectAVIFImageAndRejectMP4(t *testing.T) {
	mp4 := []byte{
		0x00, 0x00, 0x00, 0x14,
		'f', 't', 'y', 'p',
		'i', 's', 'o', 'm',
		0x00, 0x00, 0x02, 0x00,
		'i', 's', 'o', 'm',
	}
	f, base := fetcher(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/photo.avif":
			w.Write(avif)
		case "/clip.mp4":
			w.Write(mp4)
		}
	})
	if p := f.Fetch(context.Background(), base+"/photo.avif"); p.Kind != KindImage || p.ImageType != "image/avif" || len(p.Image) == 0 {
		t.Fatalf("expected direct avif image, got %+v", p)
	}
	if p := f.Fetch(context.Background(), base+"/clip.mp4"); p.Image != nil || p.Kind == KindImage {
		t.Fatalf("mp4 must not be accepted as an image: %+v", p)
	}
}

func TestSiteExtractsJSONLDProductImageInBody(t *testing.T) {
	f, base := fetcher(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/prod.png":
			w.Write(png)
		case "/logo.svg":
			w.Write([]byte(`<svg xmlns="http://www.w3.org/2000/svg"></svg>`))
		default:
			w.Header().Set("Content-Type", "text/html")
			w.Write([]byte(`<html><head><meta property="og:image" content="/logo.svg"></head><body>` +
				`<script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"Organization","name":"Shop"},{"@type":"Product","name":"Mechanical Keyboard","description":"Tactile switches","image":[{"@type":"ImageObject","url":"/prod.png"}]}]}</script>` +
				`</body></html>`))
		}
	})
	p := f.Fetch(context.Background(), base+"/item")
	if p.Title != "Mechanical Keyboard" || p.Description != "Tactile switches" || p.ImageType != "image/png" || len(p.Image) == 0 {
		t.Fatalf("expected JSON-LD product metadata and image, got %+v", p)
	}
}

func TestSiteFallsBackAcrossImageCandidatesAndWithoutTitle(t *testing.T) {
	f, base := fetcher(t, func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/missing.png":
			w.WriteHeader(http.StatusNotFound)
		case "/logo.svg":
			w.Write([]byte(`<svg xmlns="http://www.w3.org/2000/svg"></svg>`))
		case "/real.png":
			w.Write(png)
		default:
			w.Header().Set("Content-Type", "text/html")
			w.Write([]byte(`<html><head>` +
				`<meta property="og:image" content="/missing.png">` +
				`<meta name="twitter:image:src" content="/logo.svg">` +
				`<link rel="image_src" href="/real.png">` +
				`</head></html>`))
		}
	})
	p := f.Fetch(context.Background(), base+"/no-title")
	if p.ImageType != "image/png" || len(p.Image) == 0 {
		t.Fatalf("expected fallback to link[rel=image_src] even without title, got %+v", p)
	}
}

func TestSiteCrossHostRedirectUsesFinalURLAndEphemeralCookies(t *testing.T) {
	var imgReferer, imgCookie string
	var secondFetchCookie string
	storeSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/gate":
			http.SetCookie(w, &http.Cookie{Name: "sid", Value: "ok", Path: "/"})
			http.Redirect(w, r, "/products/brewer", http.StatusFound)
		case "/products/brewer":
			c, err := r.Cookie("sid")
			if err != nil || c.Value != "ok" {
				http.Redirect(w, r, "/gate", http.StatusFound)
				return
			}
			w.Header().Set("Content-Type", "text/html")
			w.Write([]byte(`<html><head><title>Brewer</title><meta property="og:image" content="/img/brewer.png"></head></html>`))
		case "/img/brewer.png":
			imgReferer = r.Header.Get("Referer")
			if c, err := r.Cookie("sid"); err == nil {
				imgCookie = c.Value
			}
			if imgReferer == "" || !strings.HasPrefix(imgReferer, "http://"+r.Host+"/") || imgCookie != "ok" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			w.Write(png)
		case "/check-cookie":
			if c, err := r.Cookie("sid"); err == nil {
				secondFetchCookie = c.Value
			}
			w.Header().Set("Content-Type", "text/html")
			w.Write([]byte(`<html><head><title>Fresh</title></head></html>`))
		}
	}))
	t.Cleanup(storeSrv.Close)

	redirSrv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, storeSrv.URL+"/gate", http.StatusFound)
	}))
	t.Cleanup(redirSrv.Close)

	f := &Fetcher{HTTP: storeSrv.Client(), OEmbedBase: storeSrv.URL}
	p := f.Fetch(context.Background(), redirSrv.URL+"/grounding-api-redirect/abc")
	if p.Title != "Brewer" || p.ImageType != "image/png" || len(p.Image) == 0 {
		t.Fatalf("expected redirected product preview with image, got %+v (referer=%q cookie=%q)", p, imgReferer, imgCookie)
	}
	if wantRef := storeSrv.URL + "/products/brewer"; imgReferer != wantRef {
		t.Fatalf("expected Referer=%q (final URL), got %q", wantRef, imgReferer)
	}
	wantHost := strings.TrimPrefix(strings.TrimPrefix(storeSrv.URL, "http://"), "www.")
	// Hostname() strips port.
	if i := strings.IndexByte(wantHost, ':'); i >= 0 {
		wantHost = wantHost[:i]
	}
	if p.Site != wantHost {
		t.Fatalf("expected fallback Site=%q from final URL, got %q", wantHost, p.Site)
	}

	// Ephemeral cookie jar must not leak cookies across independent Fetch calls.
	f.Fetch(context.Background(), storeSrv.URL+"/check-cookie")
	if secondFetchCookie != "" {
		t.Fatalf("cookie leaked across Fetch calls: %q", secondFetchCookie)
	}
}

func TestSiteParsesJSONLDPastOneMiB(t *testing.T) {
	padding := strings.Repeat("<div>padding</div>", 70000) // ~1.26 MiB
	f, base := fetcher(t, func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/big.png" {
			w.Write(png)
			return
		}
		w.Header().Set("Content-Type", "text/html")
		w.Write([]byte(`<html><head></head><body>` + padding + `<script type="application/ld+json">{"@type":"Product","name":"Big Page Brewer","image":"/big.png"}</script></body></html>`))
	})
	p := f.Fetch(context.Background(), base+"/heavy")
	if p.Title != "Big Page Brewer" || p.ImageType != "image/png" || len(p.Image) == 0 {
		t.Fatalf("expected JSON-LD past 1 MiB to be parsed, got %+v", p)
	}
}

func TestPreviewableExtractsGalleryProductAndSourcesWithCap(t *testing.T) {
	md := strings.Join([]string{
		"Check these out:",
		"```gallery",
		`{"title":"Photos","items":[{"image":"https://cdn.example/a.jpg","url":"https://news.example/a","caption":"First"},{"image":"ftp://bad.example/x.jpg"}]}`,
		"```",
		"```product",
		`{"title":"Gear","items":[{"name":"Keyboard","url":"https://shop.example/kb","image":"https://cdn.example/kb.png","price":"$149"}]}`,
		"```",
		"````md",
		"```gallery",
		`{"items":[{"image":"https://nested.example/ignore.png"}]}`,
		"```",
		"````",
		"",
		"Sources:",
		"1. [Review](https://review.example/kb)",
		"2. [[Internal Wiki Page]]",
		"3. https://bare.example/spec.",
	}, "\n")
	got := Previewable(md)
	var urls []string
	for _, r := range got {
		urls = append(urls, r.URL)
	}
	want := []string{
		"https://cdn.example/a.jpg",
		"https://news.example/a",
		"https://cdn.example/kb.png",
		"https://shop.example/kb",
		"https://review.example/kb",
		"https://bare.example/spec",
	}
	if !reflect.DeepEqual(urls, want) {
		t.Fatalf("got %v, want %v", urls, want)
	}

	// Cap enforcement at MaxPreviewURLsPerMessage.
	var many strings.Builder
	many.WriteString("```gallery\n{\"items\":[")
	for i := 0; i < 20; i++ {
		if i > 0 {
			many.WriteByte(',')
		}
		many.WriteString(`{"image":"https://img` + string(rune('a'+i)) + `.example/x.png"}`)
	}
	many.WriteString("]}\n```\n")
	if capped := Previewable(many.String()); len(capped) != MaxPreviewURLsPerMessage {
		t.Fatalf("expected cap %d, got %d", MaxPreviewURLsPerMessage, len(capped))
	}
}
