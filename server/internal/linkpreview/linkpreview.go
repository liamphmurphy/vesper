// Package linkpreview builds the cards a chat shows when a persona recommends a
// page or video. A persona chooses the URLs, so every request goes through a
// client that can only reach public addresses, with bounded reads.
package linkpreview

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/http"
	"net/netip"
	"net/url"
	"regexp"
	"strings"
	"syscall"
	"time"
	"unicode"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"

	"github.com/liamphmurphy/vesper/server/internal/transcript"
)

const (
	// MaxPerMessage bounds the outbound fetches one reply's recommend fences can cause.
	MaxPerMessage = 4
	// MaxPreviewURLsPerMessage bounds total outbound preview/image fetches across
	// recommend, gallery, product, and citation sources in a single reply.
	MaxPreviewURLsPerMessage = 12
	maxURLBytes              = 2048
	maxPageBytes             = 1 << 20
	maxImageBytes            = 3 << 20
	maxRedirects             = 3
	maxTitle                 = 200
	maxDesc                  = 300
	userAgent                = "VesperBot/1.0 (link preview)"

	KindSite  = "site"
	KindVideo = "video"
	KindImage = "image"
)

var fenceOpen = regexp.MustCompile("^ {0,3}(`{3,}|~{3,})[ \t]*([^`]*)$")

// Recommendation is one recommend fence: a URL and the persona's reason.
type Recommendation struct {
	URL  string
	Note string
}

// Recommended returns the recommend fences in a reply, in order, without
// duplicates or anything that can't be previewed. A fence quoted inside another
// code block doesn't count.
func Recommended(md string) []Recommendation {
	var out []Recommendation
	seen := map[string]bool{}
	lines := strings.Split(md, "\n")
	for i := 0; i < len(lines); i++ {
		m := fenceOpen.FindStringSubmatch(strings.TrimRight(lines[i], "\r"))
		if m == nil {
			continue
		}
		fence, info := m[1], strings.Fields(m[2])
		end := i + 1
		for end < len(lines) && !closes(lines[end], fence) {
			end++
		}
		if len(info) > 0 && strings.EqualFold(info[0], "recommend") && end > i+1 && end < len(lines) {
			u := strings.TrimSpace(lines[i+1])
			if Valid(u) && !seen[u] && len(out) < MaxPerMessage {
				seen[u] = true
				out = append(out, Recommendation{URL: u, Note: clean(strings.Join(lines[i+2:end], " "), maxDesc)})
			}
		}
		i = end
	}
	return out
}

var (
	sourcesHeading = regexp.MustCompile(`(?i)^\s*(?:#{1,6}\s+)?(?:\*\*)?sources(?:\*\*)?\s*:?\s*$`)
	sourceListItem = regexp.MustCompile(`^\s*(?:\d+[.)]|[-*])\s+`)
	sourceItemLink = regexp.MustCompile(`^\s*(?:\d+[.)]|[-*])\s+\[([^\]]*)\]\((https?://[^)\s]+)\)`)
	sourceItemBare = regexp.MustCompile(`^\s*(?:\d+[.)]|[-*])\s+(https?://\S+)`)
)

// Previewable returns all URLs in an assistant reply that Vesper may safely
// fetch server-side for preview cards: recommend fences, gallery and product
// blocks (both image and page URLs), and numbered web links in the closing
// Sources list, deduplicated and capped at MaxPreviewURLsPerMessage.
func Previewable(md string) []Recommendation {
	var out []Recommendation
	seen := map[string]bool{}
	add := func(raw, note string) {
		u := strings.TrimSpace(raw)
		if !Valid(u) || seen[u] || len(out) >= MaxPreviewURLsPerMessage {
			return
		}
		seen[u] = true
		out = append(out, Recommendation{URL: u, Note: clean(note, maxDesc)})
	}

	// 1. Recommend fences keep their original 4-card cap.
	for _, r := range Recommended(md) {
		add(r.URL, r.Note)
	}

	// 2. Gallery and product JSON fences (ignoring fences nested inside outer code blocks).
	lines := strings.Split(md, "\n")
	for i := 0; i < len(lines); i++ {
		m := fenceOpen.FindStringSubmatch(strings.TrimRight(lines[i], "\r"))
		if m == nil {
			continue
		}
		fence, info := m[1], strings.Fields(m[2])
		end := i + 1
		for end < len(lines) && !closes(lines[end], fence) {
			end++
		}
		if len(info) > 0 && end > i+1 && end < len(lines) {
			lang := strings.ToLower(info[0])
			if lang == "gallery" {
				var spec struct {
					Items []struct {
						Image   string `json:"image"`
						URL     string `json:"url"`
						Caption string `json:"caption"`
						Title   string `json:"title"`
					} `json:"items"`
				}
				if json.Unmarshal([]byte(strings.Join(lines[i+1:end], "\n")), &spec) == nil {
					for _, item := range spec.Items {
						note := first(item.Caption, item.Title)
						if item.Image != "" {
							add(item.Image, note)
						}
						if item.URL != "" {
							add(item.URL, note)
						}
					}
				}
			} else if lang == "product" {
				var spec struct {
					Items []struct {
						Name  string `json:"name"`
						Title string `json:"title"`
						Image string `json:"image"`
						URL   string `json:"url"`
					} `json:"items"`
				}
				if json.Unmarshal([]byte(strings.Join(lines[i+1:end], "\n")), &spec) == nil {
					for _, item := range spec.Items {
						note := first(item.Name, item.Title)
						if item.Image != "" {
							add(item.Image, note)
						}
						if item.URL != "" {
							add(item.URL, note)
						}
					}
				}
			}
		}
		i = end
	}

	// 3. Closing Sources: list web links, for inline citation hover cards.
	for i := len(lines) - 1; i >= 0; i-- {
		if !sourcesHeading.MatchString(strings.TrimRight(lines[i], "\r")) {
			continue
		}
		for j := i + 1; j < len(lines) && len(out) < MaxPreviewURLsPerMessage; j++ {
			line := strings.TrimRight(lines[j], "\r")
			if strings.TrimSpace(line) == "" {
				continue
			}
			if m := sourceItemLink.FindStringSubmatch(line); m != nil {
				add(m[2], m[1])
			} else if m := sourceItemBare.FindStringSubmatch(line); m != nil {
				add(strings.TrimRight(m[1], ".,;)>]"), "")
			} else if !sourceListItem.MatchString(line) {
				break
			}
		}
		break
	}

	return out
}

func closes(line, fence string) bool {
	t := strings.TrimSpace(line)
	return len(t) >= len(fence) && t[0] == fence[0] && strings.Trim(t, fence[:1]) == ""
}

// Valid reports whether a URL may be previewed: http(s), with a host and no
// embedded credentials.
func Valid(raw string) bool {
	if raw == "" || len(raw) > maxURLBytes {
		return false
	}
	u, err := url.Parse(raw)
	return err == nil && (u.Scheme == "https" || u.Scheme == "http") && u.Hostname() != "" && u.User == nil
}

// Preview is what a card shows. An empty Title means nothing could be read,
// and the card falls back to the URL.
type Preview struct {
	Kind        string
	Title       string
	Description string
	Site        string
	VideoID     string
	Image       []byte
	ImageType   string
}

// Fetcher reads previews. OEmbedBase is overridable for tests.
type Fetcher struct {
	HTTP       *http.Client
	OEmbedBase string
}

// New returns a Fetcher restricted to public addresses on the web ports.
func New() *Fetcher {
	d := &net.Dialer{Timeout: 5 * time.Second, Control: guardDial}
	return &Fetcher{
		OEmbedBase: "https://www.youtube.com",
		HTTP: &http.Client{
			Timeout: 12 * time.Second,
			// No proxy: it would make the dial guard check the proxy, not the target.
			Transport: &http.Transport{DialContext: d.DialContext, TLSHandshakeTimeout: 5 * time.Second, ResponseHeaderTimeout: 8 * time.Second, DisableKeepAlives: true},
			CheckRedirect: func(req *http.Request, via []*http.Request) error {
				if len(via) >= maxRedirects {
					return errors.New("too many redirects")
				}
				if !Valid(req.URL.String()) {
					return errors.New("redirect to an unusable URL")
				}
				return nil
			},
		},
	}
}

// guardDial runs after DNS resolution, on the address about to be connected
// to, so a public name resolving to a private address (or a redirect to one) is
// refused too.
func guardDial(_, address string, _ syscall.RawConn) error {
	host, port, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}
	if port != "80" && port != "443" {
		return fmt.Errorf("port %s not allowed", port)
	}
	ip, err := netip.ParseAddr(host)
	if err != nil {
		return err
	}
	if !public(ip) {
		return fmt.Errorf("address %s not allowed", ip)
	}
	return nil
}

var blocked = func() []netip.Prefix {
	var out []netip.Prefix
	for _, p := range []string{"0.0.0.0/8", "100.64.0.0/10", "192.0.0.0/24", "192.0.2.0/24", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24", "240.0.0.0/4", "64:ff9b::/96", "100::/64", "2001:db8::/32", "2002::/16"} {
		out = append(out, netip.MustParsePrefix(p))
	}
	return out
}()

func public(ip netip.Addr) bool {
	ip = ip.Unmap().WithZone("")
	if !ip.IsGlobalUnicast() || ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast() {
		return false
	}
	for _, p := range blocked {
		if p.Contains(ip) {
			return false
		}
	}
	return true
}

// Fetch builds the preview for a URL. Remote failures aren't errors: they give
// a preview with no Title.
func (f *Fetcher) Fetch(ctx context.Context, raw string) Preview {
	if id, err := transcript.VideoID(raw); err == nil {
		return f.video(ctx, id)
	}
	return f.site(ctx, raw)
}

func (f *Fetcher) video(ctx context.Context, id string) Preview {
	p := Preview{Kind: KindVideo, VideoID: id}
	target := "https://www.youtube.com/watch?v=" + id
	body, _, err := f.get(ctx, f.OEmbedBase+"/oembed?format=json&url="+url.QueryEscape(target), maxPageBytes)
	if err != nil {
		return p
	}
	var o struct {
		Title        string `json:"title"`
		AuthorName   string `json:"author_name"`
		ThumbnailURL string `json:"thumbnail_url"`
	}
	if json.Unmarshal(body, &o) != nil {
		return p
	}
	p.Title, p.Site = clean(o.Title, maxTitle), clean(o.AuthorName, maxTitle)
	p.Image, p.ImageType = f.image(ctx, o.ThumbnailURL)
	return p
}

func (f *Fetcher) site(ctx context.Context, raw string) Preview {
	p := Preview{Kind: KindSite}
	body, ct, err := f.get(ctx, raw, maxImageBytes)
	if err != nil {
		return p
	}
	// Direct raster images (for gallery/product cards) are verified by bytes, never by header,
	// and SVG is refused so scriptable markup can never be served back as an image.
	switch detected := http.DetectContentType(body); detected {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		var host string
		if u, err := url.Parse(raw); err == nil {
			host = strings.TrimPrefix(u.Hostname(), "www.")
		}
		return Preview{Kind: KindImage, Site: clean(host, maxTitle), Image: body, ImageType: detected}
	}
	if int64(len(body)) > maxPageBytes {
		body = body[:maxPageBytes]
	}
	if mt, _, _ := mime.ParseMediaType(ct); mt != "text/html" && mt != "application/xhtml+xml" {
		return p
	}
	m := parseMeta(body)
	p.Title = clean(first(m["og:title"], m["twitter:title"], m["title"]), maxTitle)
	p.Description = clean(first(m["og:description"], m["twitter:description"], m["description"]), maxDesc)
	p.Site = clean(m["og:site_name"], maxTitle)
	if ref := first(m["og:image:secure_url"], m["og:image"], m["twitter:image"]); ref != "" && p.Title != "" {
		if base, err := url.Parse(raw); err == nil {
			if u, err := base.Parse(strings.TrimSpace(ref)); err == nil {
				p.Image, p.ImageType = f.image(ctx, u.String())
			}
		}
	}
	return p
}

// image downloads a raster image, or nothing. The type comes from the bytes,
// never the server's header, and SVG isn't accepted.
func (f *Fetcher) image(ctx context.Context, raw string) ([]byte, string) {
	if !Valid(raw) {
		return nil, ""
	}
	body, _, err := f.get(ctx, raw, maxImageBytes)
	if err != nil {
		return nil, ""
	}
	switch ct := http.DetectContentType(body); ct {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		return body, ct
	}
	return nil, ""
}

// get reads a 200 response of at most limit bytes; a larger one is an error.
func (f *Fetcher) get(ctx context.Context, raw string, limit int64) ([]byte, string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	if err != nil {
		return nil, "", err
	}
	req.Header.Set("User-Agent", userAgent)
	res, err := f.HTTP.Do(req)
	if err != nil {
		return nil, "", err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, "", fmt.Errorf("status %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, limit+1))
	if err != nil {
		return nil, "", err
	}
	// A page's metadata is at its top, so a long page is still usable; an image isn't.
	if int64(len(body)) > limit {
		if limit == maxImageBytes {
			mt, _, _ := mime.ParseMediaType(res.Header.Get("Content-Type"))
			if mt != "text/html" && mt != "application/xhtml+xml" {
				return nil, "", errors.New("too large")
			}
		}
		body = body[:limit]
	}
	return bytes.Clone(body), res.Header.Get("Content-Type"), nil
}

// parseMeta reads <title> and the <meta> name/property tags, stopping at <body>.
func parseMeta(page []byte) map[string]string {
	out := map[string]string{}
	z := html.NewTokenizer(bytes.NewReader(page))
	inTitle := false
	for {
		switch z.Next() {
		case html.ErrorToken:
			return out
		case html.TextToken:
			if inTitle && out["title"] == "" {
				out["title"] = string(z.Text())
			}
		case html.EndTagToken:
			inTitle = false
		case html.StartTagToken, html.SelfClosingTagToken:
			t := z.Token()
			switch t.DataAtom {
			case atom.Body:
				return out
			case atom.Title:
				inTitle = true
			case atom.Meta:
				var name, content string
				for _, a := range t.Attr {
					switch strings.ToLower(a.Key) {
					case "property":
						name = a.Val
					case "name":
						if name == "" {
							name = a.Val
						}
					case "content":
						content = a.Val
					}
				}
				if name = strings.ToLower(strings.TrimSpace(name)); name != "" && out[name] == "" {
					out[name] = content
				}
			}
		}
	}
}

func first(vals ...string) string {
	for _, v := range vals {
		if strings.TrimSpace(v) != "" {
			return v
		}
	}
	return ""
}

// clean collapses whitespace, drops control characters and truncates.
func clean(s string, limit int) string {
	s = strings.Join(strings.Fields(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) && !unicode.IsSpace(r) {
			return -1
		}
		return r
	}, strings.ToValidUTF8(s, ""))), " ")
	if r := []rune(s); len(r) > limit {
		return strings.TrimSpace(string(r[:limit-1])) + "…"
	}
	return s
}
