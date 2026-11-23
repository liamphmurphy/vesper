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
	if b, _ := f.image(context.Background(), base+"/big.png"); b != nil {
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
