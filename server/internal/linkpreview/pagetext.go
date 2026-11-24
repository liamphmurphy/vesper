package linkpreview

import (
	"bytes"
	"context"
	"errors"
	"mime"
	"strings"
	"unicode/utf8"

	"golang.org/x/net/html"
	"golang.org/x/net/html/atom"
)

// maxPageTextBytes bounds a page read for its text (a space source).
const maxPageTextBytes = 3 << 20

// ErrNoText says a page was read but had no text to keep.
var ErrNoText = errors.New("the page has no readable text")

// PageText reads a public page once and returns its title and readable text:
// an HTML page's visible text with block elements on their own lines, or a
// plain-text or Markdown page as it is. Like Fetch it only reaches public
// addresses on the web ports.
func (f *Fetcher) PageText(ctx context.Context, raw string) (title, text string, err error) {
	if !Valid(raw) {
		return "", "", errors.New("not a usable http(s) address")
	}
	body, ct, _, err := f.get(ctx, f.fetchClient(), raw, maxPageTextBytes, getOpts{accept: pageAccept})
	if err != nil {
		return "", "", err
	}
	mt, _, _ := mime.ParseMediaType(ct)
	switch mt {
	case "text/html", "application/xhtml+xml", "":
		if mt == "" && !looksHTML(body) {
			return "", "", errors.New("the page isn't HTML or text")
		}
		title, text = htmlText(body)
	case "text/plain", "text/markdown", "text/x-markdown", "text/csv", "application/json":
		if !utf8.Valid(body) {
			return "", "", errors.New("the page isn't UTF-8 text")
		}
		text = strings.TrimSpace(string(body))
	default:
		return "", "", errors.New("the page isn't HTML or text")
	}
	title = clean(title, maxTitle)
	if strings.TrimSpace(text) == "" {
		return title, "", ErrNoText
	}
	return title, text, nil
}

func looksHTML(b []byte) bool {
	head := bytes.ToLower(bytes.TrimSpace(b[:min(len(b), 512)]))
	return bytes.HasPrefix(head, []byte("<!doctype html")) || bytes.HasPrefix(head, []byte("<html"))
}

// skipped elements hold no reading text.
var skipped = map[atom.Atom]bool{atom.Script: true, atom.Style: true, atom.Noscript: true, atom.Svg: true, atom.Template: true,
	atom.Nav: true, atom.Footer: true, atom.Iframe: true, atom.Form: true, atom.Button: true, atom.Select: true, atom.Head: true}

// block elements start a new line.
var block = map[atom.Atom]bool{atom.P: true, atom.Div: true, atom.Br: true, atom.Li: true, atom.Tr: true, atom.H1: true, atom.H2: true,
	atom.H3: true, atom.H4: true, atom.H5: true, atom.H6: true, atom.Section: true, atom.Article: true, atom.Header: true, atom.Main: true,
	atom.Blockquote: true, atom.Pre: true, atom.Table: true, atom.Ul: true, atom.Ol: true, atom.Dd: true, atom.Dt: true, atom.Figcaption: true}

// htmlText walks a page's tokens for its <title> and visible text.
func htmlText(page []byte) (title, text string) {
	z := html.NewTokenizer(bytes.NewReader(page))
	var b strings.Builder
	skip, inTitle := 0, false
	newline := func() {
		s := b.String()
		if s != "" && !strings.HasSuffix(s, "\n") {
			b.WriteByte('\n')
		}
	}
	for {
		switch z.Next() {
		case html.ErrorToken:
			return title, tidyLines(b.String())
		case html.TextToken:
			if inTitle && title == "" {
				title = string(z.Text())
				continue
			}
			if skip > 0 {
				continue
			}
			if t := strings.Join(strings.Fields(string(z.Text())), " "); t != "" {
				if s := b.String(); s != "" && !strings.HasSuffix(s, "\n") && !strings.HasSuffix(s, " ") {
					b.WriteByte(' ')
				}
				b.WriteString(t)
			}
		case html.StartTagToken, html.SelfClosingTagToken:
			tt := z.Token()
			switch a := tt.DataAtom; {
			case a == atom.Title:
				inTitle = tt.Type == html.StartTagToken
			case skipped[a]:
				// A self-closing one (<svg/>) has no end tag to wait for.
				if tt.Type == html.StartTagToken {
					skip++
				}
			case block[a]:
				newline()
			}
		case html.EndTagToken:
			name, _ := z.TagName()
			a := atom.Lookup(name)
			switch {
			case a == atom.Title:
				inTitle = false
			case skipped[a]:
				if skip > 0 {
					skip--
				}
			case block[a]:
				newline()
			}
		}
	}
}

// tidyLines trims each line and drops runs of blank lines.
func tidyLines(s string) string {
	var out []string
	for _, line := range strings.Split(s, "\n") {
		if line = strings.TrimSpace(line); line != "" {
			out = append(out, line)
		}
	}
	return strings.Join(out, "\n")
}
