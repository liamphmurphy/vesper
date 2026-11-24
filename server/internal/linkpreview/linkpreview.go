// Package linkpreview builds the cards a chat shows when a persona recommends a
// page or video. A persona chooses the URLs, so every request goes through a
// client that can only reach public addresses, with bounded reads.
package linkpreview

import (
	"bytes"
	"context"
	"encoding/binary"
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
	maxRedirects             = 5
	maxImageCandidates       = 4
	maxJSONLDScripts         = 16
	maxJSONLDBytes           = 256 << 10
	maxTitle                 = 200
	maxDesc                  = 300
	userAgent                = "VesperBot/1.0 (link preview)"
	browserUserAgent         = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
	pageAccept               = "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
	imageAccept              = "image/webp,image/jpeg,image/png,image/gif,image/avif;q=0.8,*/*;q=0.5"

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
	body, _, err := f.get(ctx, f.OEmbedBase+"/oembed?format=json&url="+url.QueryEscape(target), maxPageBytes, getOpts{})
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
	p.Image, p.ImageType = f.image(ctx, o.ThumbnailURL, target)
	return p
}

func (f *Fetcher) site(ctx context.Context, raw string) Preview {
	p := Preview{Kind: KindSite}
	body, ct, err := f.get(ctx, raw, maxImageBytes, getOpts{accept: pageAccept})
	if err != nil {
		return p
	}
	// Direct raster images (for gallery/product cards) are verified by bytes, never by header,
	// and SVG is refused so scriptable markup can never be served back as an image.
	if detected := detectImageType(body); detected != "" {
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
	pm := parsePage(body)
	m := pm.meta
	p.Title = clean(first(m["og:title"], m["twitter:title"], m["title"], pm.ldTitle), maxTitle)
	p.Description = clean(first(m["og:description"], m["twitter:description"], m["description"], pm.ldDescription), maxDesc)
	p.Site = clean(m["og:site_name"], maxTitle)
	if base, err := url.Parse(raw); err == nil {
		var rawRefs []string
		rawRefs = append(rawRefs, pm.productImages...)
		rawRefs = append(rawRefs, m["og:image:secure_url"], m["og:image"], m["twitter:image"], m["twitter:image:src"])
		rawRefs = append(rawRefs, pm.otherLDImages...)
		rawRefs = append(rawRefs, pm.linkImages...)
		seen := map[string]bool{}
		tried := 0
		for _, ref := range rawRefs {
			ref = strings.TrimSpace(ref)
			if ref == "" {
				continue
			}
			u, err := base.Parse(ref)
			if err != nil {
				continue
			}
			target := u.String()
			if seen[target] || !Valid(target) {
				continue
			}
			seen[target] = true
			if img, imgType := f.image(ctx, target, raw); img != nil {
				p.Image, p.ImageType = img, imgType
				break
			}
			tried++
			if tried >= maxImageCandidates {
				break
			}
		}
	}
	return p
}

// image downloads a raster image, or nothing. The type comes from the bytes,
// never the server's header, and SVG isn't accepted.
func (f *Fetcher) image(ctx context.Context, raw, referer string) ([]byte, string) {
	if !Valid(raw) {
		return nil, ""
	}
	body, _, err := f.get(ctx, raw, maxImageBytes, getOpts{accept: imageAccept, referer: referer, isImage: true})
	if err != nil {
		return nil, ""
	}
	if ct := detectImageType(body); ct != "" {
		return body, ct
	}
	return nil, ""
}

// detectImageType sniffs raster image formats from magic bytes only, never from
// HTTP headers, so SVG or scriptable markup can never be served as an image.
func detectImageType(body []byte) string {
	switch ct := http.DetectContentType(body); ct {
	case "image/png", "image/jpeg", "image/gif", "image/webp":
		return ct
	}
	if isAVIF(body) {
		return "image/avif"
	}
	return ""
}

// isAVIF reports whether b begins with an ISO BMFF ftyp box declaring an AVIF
// major or compatible brand.
func isAVIF(b []byte) bool {
	if len(b) < 12 || string(b[4:8]) != "ftyp" {
		return false
	}
	boxSize := int(binary.BigEndian.Uint32(b[0:4]))
	if boxSize < 12 || boxSize > len(b) {
		boxSize = len(b)
	}
	if boxSize > 64 {
		boxSize = 64
	}
	if major := string(b[8:12]); major == "avif" || major == "avis" {
		return true
	}
	for off := 16; off+4 <= boxSize; off += 4 {
		if brand := string(b[off : off+4]); brand == "avif" || brand == "avis" {
			return true
		}
	}
	return false
}

type getOpts struct {
	accept  string
	referer string
	ua      string
	isImage bool
}

// get reads a 200 response of at most limit bytes; a larger one is an error.
// If the server rejects the default bot User-Agent with 403 or 406, it retries
// once with a standard browser User-Agent.
func (f *Fetcher) get(ctx context.Context, raw string, limit int64, opts getOpts) ([]byte, string, error) {
	body, ct, status, err := f.doGet(ctx, raw, limit, opts)
	if err != nil && opts.ua == "" && (status == http.StatusForbidden || status == http.StatusNotAcceptable) {
		opts.ua = browserUserAgent
		body, ct, _, err = f.doGet(ctx, raw, limit, opts)
	}
	return body, ct, err
}

func (f *Fetcher) doGet(ctx context.Context, raw string, limit int64, opts getOpts) ([]byte, string, int, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	if err != nil {
		return nil, "", 0, err
	}
	ua := opts.ua
	if ua == "" {
		ua = userAgent
	}
	req.Header.Set("User-Agent", ua)
	req.Header.Set("Accept-Language", "en-US,en;q=0.9")
	if opts.accept != "" {
		req.Header.Set("Accept", opts.accept)
	}
	if opts.referer != "" {
		req.Header.Set("Referer", opts.referer)
	}
	if opts.ua == browserUserAgent {
		if opts.isImage {
			req.Header.Set("Sec-Fetch-Dest", "image")
			req.Header.Set("Sec-Fetch-Mode", "no-cors")
		} else {
			req.Header.Set("Sec-Fetch-Dest", "document")
			req.Header.Set("Sec-Fetch-Mode", "navigate")
			req.Header.Set("Sec-Fetch-Site", "none")
		}
	}
	res, err := f.HTTP.Do(req)
	if err != nil {
		return nil, "", 0, err
	}
	defer res.Body.Close()
	if res.StatusCode != http.StatusOK {
		return nil, "", res.StatusCode, fmt.Errorf("status %d", res.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(res.Body, limit+1))
	if err != nil {
		return nil, "", res.StatusCode, err
	}
	// A page's metadata is at its top, so a long page is still usable; an image isn't.
	if int64(len(body)) > limit {
		if limit == maxImageBytes {
			mt, _, _ := mime.ParseMediaType(res.Header.Get("Content-Type"))
			if mt != "text/html" && mt != "application/xhtml+xml" {
				return nil, "", res.StatusCode, errors.New("too large")
			}
		}
		body = body[:limit]
	}
	return bytes.Clone(body), res.Header.Get("Content-Type"), res.StatusCode, nil
}

type pageMeta struct {
	meta          map[string]string
	productImages []string
	otherLDImages []string
	linkImages    []string
	ldTitle       string
	ldDescription string
}

// parsePage reads <title>, <meta>, and image <link> tags from <head>, plus
// application/ld+json <script> blocks anywhere in the bounded HTML document.
func parsePage(page []byte) pageMeta {
	out := pageMeta{meta: map[string]string{}}
	z := html.NewTokenizer(bytes.NewReader(page))
	inBody := false
	inTitle := false
	inJSONLD := false
	scripts := 0
	var ldBuf bytes.Buffer
	for {
		tokType := z.Next()
		switch tokType {
		case html.ErrorToken:
			return out
		case html.TextToken:
			if inTitle && !inBody && out.meta["title"] == "" {
				out.meta["title"] = string(z.Text())
			} else if inJSONLD && ldBuf.Len() <= maxJSONLDBytes {
				ldBuf.Write(z.Text())
			}
		case html.EndTagToken:
			t := z.Token()
			switch t.DataAtom {
			case atom.Title:
				inTitle = false
			case atom.Script:
				if inJSONLD {
					inJSONLD = false
					if ldBuf.Len() > 0 && ldBuf.Len() <= maxJSONLDBytes {
						parseJSONLD(ldBuf.Bytes(), &out)
					}
					ldBuf.Reset()
				}
			}
		case html.StartTagToken, html.SelfClosingTagToken:
			t := z.Token()
			switch t.DataAtom {
			case atom.Body:
				inBody = true
			case atom.Title:
				if !inBody && tokType == html.StartTagToken {
					inTitle = true
				}
			case atom.Meta:
				if inBody {
					continue
				}
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
				if name = strings.ToLower(strings.TrimSpace(name)); name != "" && out.meta[name] == "" {
					out.meta[name] = content
				}
			case atom.Link:
				if inBody {
					continue
				}
				var rel, as, href string
				for _, a := range t.Attr {
					switch strings.ToLower(a.Key) {
					case "rel":
						rel = strings.ToLower(strings.TrimSpace(a.Val))
					case "as":
						as = strings.ToLower(strings.TrimSpace(a.Val))
					case "href":
						href = strings.TrimSpace(a.Val)
					}
				}
				if href != "" && (hasRelToken(rel, "image_src") || (hasRelToken(rel, "preload") && as == "image")) {
					out.linkImages = append(out.linkImages, href)
				}
			case atom.Script:
				if tokType != html.StartTagToken || scripts >= maxJSONLDScripts {
					continue
				}
				for _, a := range t.Attr {
					if strings.ToLower(a.Key) == "type" {
						if mt, _, _ := mime.ParseMediaType(a.Val); strings.EqualFold(mt, "application/ld+json") {
							inJSONLD = true
							scripts++
							ldBuf.Reset()
						}
						break
					}
				}
			}
		}
	}
}

func hasRelToken(rel, want string) bool {
	for _, tok := range strings.Fields(rel) {
		if tok == want {
			return true
		}
	}
	return false
}

func parseJSONLD(raw []byte, out *pageMeta) {
	var doc any
	if json.Unmarshal(raw, &doc) != nil {
		return
	}
	walkJSONLD(doc, out, 0)
}

func walkJSONLD(node any, out *pageMeta, depth int) {
	if depth > 6 {
		return
	}
	switch v := node.(type) {
	case []any:
		for _, item := range v {
			walkJSONLD(item, out, depth+1)
		}
	case map[string]any:
		if graph, ok := v["@graph"]; ok {
			walkJSONLD(graph, out, depth+1)
		}
		if hasLDType(v["@type"], "product", "productgroup", "individualproduct") {
			out.productImages = append(out.productImages, extractLDImages(v["image"], 0)...)
			if out.ldTitle == "" {
				if name, ok := v["name"].(string); ok && strings.TrimSpace(name) != "" {
					out.ldTitle = name
				}
			}
			if out.ldDescription == "" {
				if desc, ok := v["description"].(string); ok && strings.TrimSpace(desc) != "" {
					out.ldDescription = desc
				}
			}
			if variants, ok := v["hasVariant"]; ok {
				walkJSONLD(variants, out, depth+1)
			}
			return
		}
		if hasLDType(v["@type"], "article", "newsarticle", "blogposting", "review", "recipe", "webpage", "itempage", "videoobject", "offer") {
			out.otherLDImages = append(out.otherLDImages, extractLDImages(v["image"], 0)...)
			out.otherLDImages = append(out.otherLDImages, extractLDImages(v["thumbnailUrl"], 0)...)
		}
	}
}

func hasLDType(raw any, want ...string) bool {
	match := func(s string) bool {
		s = strings.ToLower(strings.TrimSpace(s))
		s = strings.TrimPrefix(s, "https://schema.org/")
		s = strings.TrimPrefix(s, "http://schema.org/")
		for _, w := range want {
			if s == w {
				return true
			}
		}
		return false
	}
	switch v := raw.(type) {
	case string:
		return match(v)
	case []any:
		for _, item := range v {
			if s, ok := item.(string); ok && match(s) {
				return true
			}
		}
	}
	return false
}

func extractLDImages(raw any, depth int) []string {
	if raw == nil || depth > 4 {
		return nil
	}
	switch v := raw.(type) {
	case string:
		if s := strings.TrimSpace(v); s != "" && !strings.HasPrefix(s, "#") {
			return []string{s}
		}
	case []any:
		var out []string
		for _, item := range v {
			out = append(out, extractLDImages(item, depth+1)...)
		}
		return out
	case map[string]any:
		for _, k := range []string{"url", "contentUrl", "@id"} {
			if s, ok := v[k].(string); ok {
				if s = strings.TrimSpace(s); s != "" && !strings.HasPrefix(s, "#") {
					return []string{s}
				}
			}
		}
	}
	return nil
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
