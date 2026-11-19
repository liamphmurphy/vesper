package agentapi

import (
	"context"
	"encoding/base64"
	"errors"
	htmlstd "html"
	"mime"
	"net/http"
	"path"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

const (
	// Bounds on server-side image inlining for render_pdf so a single call
	// stays within the Node PDF worker's 48 MB request limit after base64 expansion.
	maxPDFSingleAssetBytes   = 15 << 20 // 15 MB per image
	maxPDFTotalAssetBytes    = 25 << 20 // 25 MB unique raw image bytes per PDF
	maxPDFTotalExpandedBytes = 40 << 20 // 40 MB combined rewritten HTML/CSS/templates
)

type pdfAssetRef struct {
	Raw  string
	Kind string // "attachment" or "library"
	ID   uuid.UUID
}

type pdfAssetKey struct {
	Kind string
	ID   uuid.UUID
}

type pdfAssetLoadFunc func(ctx context.Context, ref pdfAssetRef) (mimeType, filename string, data []byte, err error)

type pdfAssetLoader struct {
	load     pdfAssetLoadFunc
	cache    map[pdfAssetKey]string
	totalRaw int64
}

func newPDFAssetLoader(load pdfAssetLoadFunc) *pdfAssetLoader {
	return &pdfAssetLoader{
		load:  load,
		cache: map[pdfAssetKey]string{},
	}
}

func newWikiPDFAssetLoader(w *wiki.Service, ws, userID uuid.UUID) *pdfAssetLoader {
	return newPDFAssetLoader(func(ctx context.Context, ref pdfAssetRef) (string, string, []byte, error) {
		if w == nil {
			return "", "", nil, apperr.Conflict("Knowledge storage isn't available here")
		}
		switch ref.Kind {
		case "attachment":
			asset, data, err := w.ReadKnowledgeAsset(ctx, ws, userID, ref.ID, maxPDFSingleAssetBytes)
			if err != nil {
				return "", "", nil, err
			}
			return asset.ContentType, asset.Filename, data, nil
		case "library":
			item, data, err := w.ReadLibraryItem(ctx, ws, userID, ref.ID, maxPDFSingleAssetBytes)
			if err != nil {
				return "", "", nil, err
			}
			name := item.Filename
			if strings.TrimSpace(name) == "" {
				name = item.Title
			}
			return item.ContentType, name, data, nil
		default:
			return "", "", nil, apperr.ErrNotFound
		}
	})
}

func (l *pdfAssetLoader) resolve(ctx context.Context, field string, ref pdfAssetRef) (string, error) {
	key := pdfAssetKey{Kind: ref.Kind, ID: ref.ID}
	if uri, ok := l.cache[key]; ok {
		return uri, nil
	}
	declaredMIME, filename, data, err := l.load(ctx, ref)
	if err != nil {
		switch {
		case errors.Is(err, apperr.ErrNotFound), errors.Is(err, blob.ErrNotFound):
			return "", apperr.Invalid(field, "unknown or inaccessible %s %q", ref.Kind, ref.Raw)
		case errors.Is(err, wiki.ErrAssetTooLarge):
			return "", apperr.Invalid(field, "%s %q exceeds the %d MB per-image limit", ref.Kind, ref.Raw, maxPDFSingleAssetBytes>>20)
		case errors.Is(err, wiki.ErrAssetNoFile):
			return "", apperr.Invalid(field, "%s %q has no image file", ref.Kind, ref.Raw)
		default:
			return "", err
		}
	}
	if len(data) == 0 {
		return "", apperr.Invalid(field, "cannot embed %q: image is empty", ref.Raw)
	}
	if int64(len(data)) > maxPDFSingleAssetBytes {
		return "", apperr.Invalid(field, "%s %q exceeds the %d MB per-image limit", ref.Kind, ref.Raw, maxPDFSingleAssetBytes>>20)
	}
	if l.totalRaw+int64(len(data)) > maxPDFTotalAssetBytes {
		return "", apperr.Invalid(field, "embedded images exceed the %d MB total limit (while resolving %q)", maxPDFTotalAssetBytes>>20, ref.Raw)
	}
	imgMIME, ok := normalizePDFImageMIME(declaredMIME, filename, data)
	if !ok {
		if imgMIME == "" {
			imgMIME = "unknown"
		}
		return "", apperr.Invalid(field, "cannot embed %q as an image: content type %s is not a supported image", ref.Raw, imgMIME)
	}
	l.totalRaw += int64(len(data))
	uri := "data:" + imgMIME + ";base64," + base64.StdEncoding.EncodeToString(data)
	l.cache[key] = uri
	return uri, nil
}

// resolvePDFInputs inlines attachment: and library: image references across all
// HTML/CSS inputs server-side so the PDF renderer remains strictly offline.
func resolvePDFInputs(ctx context.Context, loader *pdfAssetLoader, html, css, headerHTML, footerHTML string) (string, string, string, string, error) {
	resolve := func(ctx context.Context, field string, ref pdfAssetRef) (string, error) {
		return loader.resolve(ctx, field, ref)
	}
	outHTML, err := rewritePDFHTML(ctx, "html", html, resolve)
	if err != nil {
		return "", "", "", "", err
	}
	outCSS, _, err := rewritePDFCSS(ctx, "css", css, resolve)
	if err != nil {
		return "", "", "", "", err
	}
	outHeader, err := rewritePDFHTML(ctx, "header_html", headerHTML, resolve)
	if err != nil {
		return "", "", "", "", err
	}
	outFooter, err := rewritePDFHTML(ctx, "footer_html", footerHTML, resolve)
	if err != nil {
		return "", "", "", "", err
	}
	if len(outHTML)+len(outCSS)+len(outHeader)+len(outFooter) > maxPDFTotalExpandedBytes {
		return "", "", "", "", apperr.Invalid("html", "document with embedded images exceeds the %d MB render limit", maxPDFTotalExpandedBytes>>20)
	}
	return outHTML, outCSS, outHeader, outFooter, nil
}

func parsePDFAssetRef(field, raw string) (pdfAssetRef, bool, error) {
	trimmed := strings.TrimSpace(raw)
	switch {
	case hasFoldPrefix(trimmed, "attachment:"):
		rest := trimmed[len("attachment:"):]
		idPart, _, _ := strings.Cut(rest, "/")
		id, err := uuid.Parse(idPart)
		if err != nil {
			return pdfAssetRef{}, true, apperr.Invalid(field, "invalid attachment reference %q: expected attachment:<asset-id> or attachment:<asset-id>/<filename>", trimmed)
		}
		return pdfAssetRef{Raw: trimmed, Kind: "attachment", ID: id}, true, nil
	case hasFoldPrefix(trimmed, "library:"):
		rest := trimmed[len("library:"):]
		idPart, _, _ := strings.Cut(rest, "/")
		id, err := uuid.Parse(idPart)
		if err != nil {
			return pdfAssetRef{}, true, apperr.Invalid(field, "invalid library reference %q: expected library:<library_item_id>", trimmed)
		}
		return pdfAssetRef{Raw: trimmed, Kind: "library", ID: id}, true, nil
	default:
		return pdfAssetRef{}, false, nil
	}
}

func normalizePDFImageMIME(declared, filename string, data []byte) (string, bool) {
	mt := cleanMIME(declared)
	if mt == "" || mt == "application/octet-stream" {
		mt = cleanMIME(http.DetectContentType(data))
	}
	if mt == "image/jpg" {
		mt = "image/jpeg"
	}
	if mt != "image/svg+xml" && looksLikeSVG(filename, data) && (mt == "" || mt == "application/octet-stream" || strings.HasPrefix(mt, "text/") || mt == "application/xml") {
		mt = "image/svg+xml"
	}
	switch mt {
	case "image/jpeg", "image/png", "image/webp", "image/gif", "image/svg+xml", "image/avif", "image/bmp", "image/x-icon", "image/vnd.microsoft.icon":
		return mt, true
	default:
		return mt, false
	}
}

func cleanMIME(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if mt, _, err := mime.ParseMediaType(raw); err == nil {
		return strings.ToLower(strings.TrimSpace(mt))
	}
	return strings.ToLower(raw)
}

func looksLikeSVG(filename string, data []byte) bool {
	if !strings.EqualFold(path.Ext(strings.TrimSpace(filename)), ".svg") {
		return false
	}
	head := strings.ToLower(string(data[:min(len(data), 512)]))
	return strings.Contains(head, "<svg")
}

func hasFoldPrefix(s, prefix string) bool {
	return len(s) >= len(prefix) && strings.EqualFold(s[:len(prefix)], prefix)
}

func containsAssetScheme(s string) bool {
	if s == "" {
		return false
	}
	lower := strings.ToLower(s)
	return strings.Contains(lower, "attachment:") || strings.Contains(lower, "library:")
}

type resolveAssetFunc func(ctx context.Context, field string, ref pdfAssetRef) (string, error)

// rewritePDFHTML scans HTML start tags and <style> blocks, replacing Vesper
// attachment:/library: references in image attributes and CSS url() functions
// while preserving untouched markup verbatim (including SVG attribute casing).
func rewritePDFHTML(ctx context.Context, field, src string, resolve resolveAssetFunc) (string, error) {
	if !containsAssetScheme(src) {
		return src, nil
	}
	var out strings.Builder
	out.Grow(len(src))
	i := 0
	for i < len(src) {
		lt := strings.IndexByte(src[i:], '<')
		if lt < 0 {
			out.WriteString(src[i:])
			break
		}
		out.WriteString(src[i : i+lt])
		i += lt

		// Comments: <!-- ... -->
		if strings.HasPrefix(src[i:], "<!--") {
			end := strings.Index(src[i+4:], "-->")
			if end < 0 {
				out.WriteString(src[i:])
				break
			}
			out.WriteString(src[i : i+4+end+3])
			i += 4 + end + 3
			continue
		}
		// CDATA: <![CDATA[ ... ]]>
		if strings.HasPrefix(src[i:], "<![CDATA[") {
			end := strings.Index(src[i+9:], "]]>")
			if end < 0 {
				out.WriteString(src[i:])
				break
			}
			out.WriteString(src[i : i+9+end+3])
			i += 9 + end + 3
			continue
		}
		// Closing tags, doctypes, processing instructions, or bare '<'.
		if i+1 >= len(src) || !isASCIILetter(src[i+1]) {
			if i+1 < len(src) && (src[i+1] == '/' || src[i+1] == '!' || src[i+1] == '?') {
				gt := strings.IndexByte(src[i+2:], '>')
				if gt < 0 {
					out.WriteString(src[i:])
					break
				}
				out.WriteString(src[i : i+2+gt+1])
				i += 2 + gt + 1
				continue
			}
			out.WriteByte('<')
			i++
			continue
		}

		// Start tag: <tagName ...>
		nameStart := i + 1
		nameEnd := nameStart
		for nameEnd < len(src) && isTagNameChar(src[nameEnd]) {
			nameEnd++
		}
		tagLower := strings.ToLower(src[nameStart:nameEnd])

		rewrittenTag, tagEnd, selfClosing, err := rewriteHTMLStartTag(ctx, field, src, i, nameEnd, tagLower, resolve)
		if err != nil {
			return "", err
		}
		out.WriteString(rewrittenTag)
		i = tagEnd

		if selfClosing {
			continue
		}
		switch tagLower {
		case "style":
			closeIdx := findClosingTag(src, i, "style")
			var inner string
			if closeIdx < 0 {
				inner = src[i:]
				i = len(src)
			} else {
				inner = src[i:closeIdx]
				i = closeIdx
			}
			rewrittenCSS, _, err := rewritePDFCSS(ctx, field, inner, resolve)
			if err != nil {
				return "", err
			}
			out.WriteString(rewrittenCSS)
		case "script", "textarea", "title":
			closeIdx := findClosingTag(src, i, tagLower)
			if closeIdx < 0 {
				out.WriteString(src[i:])
				i = len(src)
			} else {
				out.WriteString(src[i:closeIdx])
				i = closeIdx
			}
		}
	}
	return out.String(), nil
}

func rewriteHTMLStartTag(ctx context.Context, field, src string, tagStart, pos int, tagLower string, resolve resolveAssetFunc) (string, int, bool, error) {
	var out strings.Builder
	last := tagStart
	selfClosing := false

	for pos < len(src) {
		for pos < len(src) && isASCIIWhitespace(src[pos]) {
			pos++
		}
		if pos >= len(src) {
			break
		}
		if src[pos] == '>' {
			pos++
			break
		}
		if src[pos] == '/' {
			if pos+1 < len(src) && src[pos+1] == '>' {
				selfClosing = true
				pos += 2
				break
			}
			pos++
			continue
		}

		attrNameStart := pos
		for pos < len(src) && !isASCIIWhitespace(src[pos]) && src[pos] != '=' && src[pos] != '>' && src[pos] != '/' {
			pos++
		}
		attrLower := strings.ToLower(src[attrNameStart:pos])

		wsAfterName := pos
		for wsAfterName < len(src) && isASCIIWhitespace(src[wsAfterName]) {
			wsAfterName++
		}
		if wsAfterName >= len(src) || src[wsAfterName] != '=' {
			// Boolean attribute without a value.
			pos = wsAfterName
			continue
		}
		pos = wsAfterName + 1
		for pos < len(src) && isASCIIWhitespace(src[pos]) {
			pos++
		}
		if pos >= len(src) {
			break
		}

		var quote byte
		valSpanStart := pos
		valStart, valEnd := pos, pos
		if src[pos] == '"' || src[pos] == '\'' {
			quote = src[pos]
			pos++
			valStart = pos
			for pos < len(src) && src[pos] != quote {
				pos++
			}
			valEnd = pos
			if pos < len(src) {
				pos++ // consume closing quote
			}
		} else {
			valStart = pos
			for pos < len(src) && !isASCIIWhitespace(src[pos]) && src[pos] != '>' {
				if src[pos] == '/' && pos+1 < len(src) && src[pos+1] == '>' {
					break
				}
				pos++
			}
			valEnd = pos
		}
		valSpanEnd := pos

		rawVal := src[valStart:valEnd]
		switch {
		case isImageURLAttr(tagLower, attrLower):
			unescaped := htmlstd.UnescapeString(rawVal)
			ref, ok, err := parsePDFAssetRef(field, unescaped)
			if err != nil {
				return "", 0, false, err
			}
			if ok {
				uri, err := resolve(ctx, field, ref)
				if err != nil {
					return "", 0, false, err
				}
				out.WriteString(src[last:valSpanStart])
				if quote == 0 {
					out.WriteByte('"')
					out.WriteString(uri)
					out.WriteByte('"')
				} else {
					out.WriteByte(quote)
					out.WriteString(uri)
					out.WriteByte(quote)
				}
				last = valSpanEnd
			}
		case attrLower == "srcset" && (tagLower == "img" || tagLower == "source"):
			unescaped := htmlstd.UnescapeString(rawVal)
			rewritten, changed, err := rewriteSrcset(ctx, field, unescaped, resolve)
			if err != nil {
				return "", 0, false, err
			}
			if changed {
				out.WriteString(src[last:valSpanStart])
				writeQuotedAttr(&out, quote, rewritten)
				last = valSpanEnd
			}
		case attrLower == "style":
			unescaped := htmlstd.UnescapeString(rawVal)
			rewritten, changed, err := rewritePDFCSS(ctx, field, unescaped, resolve)
			if err != nil {
				return "", 0, false, err
			}
			if changed {
				out.WriteString(src[last:valSpanStart])
				writeQuotedAttr(&out, quote, rewritten)
				last = valSpanEnd
			}
		}
	}

	if last == tagStart {
		return src[tagStart:pos], pos, selfClosing, nil
	}
	out.WriteString(src[last:pos])
	return out.String(), pos, selfClosing, nil
}

func isImageURLAttr(tagLower, attrLower string) bool {
	switch attrLower {
	case "src", "poster":
		return true
	case "href", "xlink:href":
		return tagLower == "image" || tagLower == "feimage"
	default:
		return false
	}
}

func writeQuotedAttr(out *strings.Builder, quote byte, val string) {
	if quote == 0 {
		quote = '"'
	}
	out.WriteByte(quote)
	for i := 0; i < len(val); i++ {
		switch val[i] {
		case '&':
			out.WriteString("&amp;")
		case '"':
			if quote == '"' {
				out.WriteString("&quot;")
			} else {
				out.WriteByte('"')
			}
		case '\'':
			if quote == '\'' {
				out.WriteString("&#39;")
			} else {
				out.WriteByte('\'')
			}
		default:
			out.WriteByte(val[i])
		}
	}
	out.WriteByte(quote)
}

func rewriteSrcset(ctx context.Context, field, srcset string, resolve resolveAssetFunc) (string, bool, error) {
	if !containsAssetScheme(srcset) {
		return srcset, false, nil
	}
	parts := strings.Split(srcset, ",")
	changed := false
	for i, part := range parts {
		trimmed := strings.TrimSpace(part)
		if trimmed == "" {
			continue
		}
		fields := strings.Fields(trimmed)
		if len(fields) == 0 {
			continue
		}
		ref, ok, err := parsePDFAssetRef(field, fields[0])
		if err != nil {
			return "", false, err
		}
		if !ok {
			continue
		}
		uri, err := resolve(ctx, field, ref)
		if err != nil {
			return "", false, err
		}
		fields[0] = uri
		parts[i] = strings.Join(fields, " ")
		changed = true
	}
	if !changed {
		return srcset, false, nil
	}
	return strings.Join(parts, ", "), true, nil
}

// rewritePDFCSS rewrites CSS url(...) references to attachment: or library:
// assets while ignoring CSS comments and string literals outside url().
func rewritePDFCSS(ctx context.Context, field, src string, resolve resolveAssetFunc) (string, bool, error) {
	if !containsAssetScheme(src) {
		return src, false, nil
	}
	var out strings.Builder
	out.Grow(len(src))
	changed := false
	i := 0
	for i < len(src) {
		// CSS comment /* ... */
		if i+1 < len(src) && src[i] == '/' && src[i+1] == '*' {
			end := strings.Index(src[i+2:], "*/")
			if end < 0 {
				out.WriteString(src[i:])
				break
			}
			out.WriteString(src[i : i+2+end+2])
			i += 2 + end + 2
			continue
		}
		// CSS string literal outside url(...)
		if src[i] == '"' || src[i] == '\'' {
			end := scanCSSString(src, i)
			out.WriteString(src[i:end])
			i = end
			continue
		}
		// Check for url( not preceded by an identifier character.
		if (src[i] == 'u' || src[i] == 'U') && hasFoldPrefix(src[i:], "url(") && (i == 0 || !isCSSIdentChar(src[i-1])) {
			arg, nextIdx, ok := parseCSSURL(src, i+4)
			if ok {
				ref, matched, err := parsePDFAssetRef(field, arg)
				if err != nil {
					return "", false, err
				}
				if matched {
					uri, err := resolve(ctx, field, ref)
					if err != nil {
						return "", false, err
					}
					out.WriteString("url(")
					out.WriteString(uri)
					out.WriteByte(')')
					changed = true
					i = nextIdx
					continue
				}
				out.WriteString(src[i:nextIdx])
				i = nextIdx
				continue
			}
		}
		out.WriteByte(src[i])
		i++
	}
	if !changed {
		return src, false, nil
	}
	return out.String(), true, nil
}

func scanCSSString(src string, start int) int {
	quote := src[start]
	i := start + 1
	for i < len(src) {
		if src[i] == '\\' && i+1 < len(src) {
			i += 2
			continue
		}
		if src[i] == quote {
			return i + 1
		}
		i++
	}
	return len(src)
}

func parseCSSURL(src string, pos int) (string, int, bool) {
	for pos < len(src) && isASCIIWhitespace(src[pos]) {
		pos++
	}
	if pos >= len(src) {
		return "", 0, false
	}
	var arg string
	if src[pos] == '"' || src[pos] == '\'' {
		quote := src[pos]
		pos++
		var b strings.Builder
		closed := false
		for pos < len(src) {
			if src[pos] == '\\' && pos+1 < len(src) {
				b.WriteByte(src[pos+1])
				pos += 2
				continue
			}
			if src[pos] == quote {
				pos++
				closed = true
				break
			}
			b.WriteByte(src[pos])
			pos++
		}
		if !closed {
			return "", 0, false
		}
		arg = b.String()
		for pos < len(src) && isASCIIWhitespace(src[pos]) {
			pos++
		}
		if pos >= len(src) || src[pos] != ')' {
			return "", 0, false
		}
		return arg, pos + 1, true
	}
	end := strings.IndexByte(src[pos:], ')')
	if end < 0 {
		return "", 0, false
	}
	arg = strings.TrimSpace(src[pos : pos+end])
	return arg, pos + end + 1, true
}

func findClosingTag(src string, start int, tagLower string) int {
	for i := start; i < len(src); i++ {
		idx := strings.Index(src[i:], "</")
		if idx < 0 {
			return -1
		}
		pos := i + idx
		after := pos + 2
		if after+len(tagLower) <= len(src) && strings.EqualFold(src[after:after+len(tagLower)], tagLower) {
			next := after + len(tagLower)
			if next == len(src) || isASCIIWhitespace(src[next]) || src[next] == '>' || src[next] == '/' {
				return pos
			}
		}
		i = after
	}
	return -1
}

func isASCIILetter(b byte) bool {
	return (b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z')
}

func isTagNameChar(b byte) bool {
	return isASCIILetter(b) || (b >= '0' && b <= '9') || b == '-' || b == ':' || b == '_'
}

func isCSSIdentChar(b byte) bool {
	return isASCIILetter(b) || (b >= '0' && b <= '9') || b == '-' || b == '_'
}

func isASCIIWhitespace(b byte) bool {
	return b == ' ' || b == '\t' || b == '\n' || b == '\r' || b == '\f'
}
