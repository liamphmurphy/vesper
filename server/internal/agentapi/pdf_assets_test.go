package agentapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"strings"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

var (
	sampleJPEG = []byte{0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0x00, 0x01, 0x01, 0x00, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0xff, 0xd9}
	samplePNG  = []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n', 0x00, 0x00, 0x00, 0x0d, 'I', 'H', 'D', 'R'}
	sampleWebP = func() []byte {
		b, _ := base64.StdEncoding.DecodeString("UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")
		return b
	}()
	sampleSVG = []byte(`<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><circle cx="5" cy="5" r="4"/></svg>`)
)

func TestResolvePDFInputsRewritesAttachmentsAndLibrary(t *testing.T) {
	jpegID := uuid.New()
	pngID := uuid.New()
	webpID := uuid.New()
	svgID := uuid.New()
	libID := uuid.New()

	type assetEntry struct {
		mime, filename string
		data           []byte
	}
	store := map[pdfAssetKey]assetEntry{
		{Kind: "attachment", ID: jpegID}: {mime: "image/jpeg", filename: "cyric.jpg", data: sampleJPEG},
		{Kind: "attachment", ID: pngID}:  {mime: "image/png", filename: "My Portrait (1).png", data: samplePNG},
		{Kind: "attachment", ID: webpID}: {mime: "application/octet-stream", filename: "Mortal_Kelemvor.webp", data: sampleWebP},
		{Kind: "attachment", ID: svgID}:  {mime: "text/plain; charset=utf-8", filename: "crest.svg", data: sampleSVG},
		{Kind: "library", ID: libID}:     {mime: "image/png", filename: "map.png", data: samplePNG},
	}

	calls := map[pdfAssetKey]int{}
	loader := newPDFAssetLoader(func(_ context.Context, ref pdfAssetRef) (string, string, []byte, error) {
		k := pdfAssetKey{Kind: ref.Kind, ID: ref.ID}
		calls[k]++
		entry, ok := store[k]
		if !ok {
			return "", "", nil, apperr.ErrNotFound
		}
		return entry.mime, entry.filename, entry.data, nil
	})

	html := `<!doctype html>
<html>
<head>
<style>
/* url(attachment:00000000-0000-0000-0000-000000000000) ignored comment */
.hero { background-image: url("attachment:` + webpID.String() + `/Mortal_Kelemvor.webp"); }
.note::after { content: "url(attachment:not-real)"; }
</style>
</head>
<body>
<!-- <img src="attachment:00000000-0000-0000-0000-000000000000"> -->
<p>Literal text: attachment:not-a-uuid should not be touched.</p>
<a href="attachment:not-a-uuid">Link untouched</a>
<img alt="a > b" src="attachment:` + jpegID.String() + `">
<img src='attachment:` + pngID.String() + `/My Portrait (1).png' />
<img src=attachment:` + webpID.String() + `/>
<img src="library:` + libID.String() + `" srcset="library:` + libID.String() + ` 2x">
<svg viewBox="0 0 100 100"><image href="attachment:` + svgID.String() + `/crest.svg" preserveAspectRatio="xMidYMid meet"/></svg>
<div style="background: url(&quot;attachment:` + jpegID.String() + `/cyric.jpg&quot;) no-repeat"></div>
</body>
</html>`
	css := `.banner { background: url('attachment:` + pngID.String() + `') center/cover; }`
	header := `<img src="attachment:` + svgID.String() + `" style="height:16px">`
	footer := `<img src="library:` + libID.String() + `">`

	outHTML, outCSS, outHeader, outFooter, err := resolvePDFInputs(t.Context(), loader, html, css, header, footer)
	if err != nil {
		t.Fatalf("resolvePDFInputs error = %v", err)
	}

	jpegURI := "data:image/jpeg;base64," + base64.StdEncoding.EncodeToString(sampleJPEG)
	pngURI := "data:image/png;base64," + base64.StdEncoding.EncodeToString(samplePNG)
	webpURI := "data:image/webp;base64," + base64.StdEncoding.EncodeToString(sampleWebP)
	svgURI := "data:image/svg+xml;base64," + base64.StdEncoding.EncodeToString(sampleSVG)

	for _, want := range []string{
		`<img alt="a > b" src="` + jpegURI + `">`,
		`<img src='` + pngURI + `' />`,
		`<img src="` + webpURI + `"/>`,
		`<img src="` + pngURI + `" srcset="` + pngURI + ` 2x">`,
		`<svg viewBox="0 0 100 100"><image href="` + svgURI + `" preserveAspectRatio="xMidYMid meet"/></svg>`,
		`background-image: url(` + webpURI + `);`,
		`style="background: url(` + jpegURI + `) no-repeat"`,
		`<!-- <img src="attachment:00000000-0000-0000-0000-000000000000"> -->`,
		`<p>Literal text: attachment:not-a-uuid should not be touched.</p>`,
		`<a href="attachment:not-a-uuid">Link untouched</a>`,
	} {
		if !strings.Contains(outHTML, want) {
			t.Errorf("outHTML missing %q\ngot:\n%s", want, outHTML)
		}
	}
	if !strings.Contains(outCSS, "url("+pngURI+")") {
		t.Errorf("outCSS = %q, want data URI", outCSS)
	}
	if !strings.Contains(outHeader, `src="`+svgURI+`"`) {
		t.Errorf("outHeader = %q, want SVG data URI", outHeader)
	}
	if !strings.Contains(outFooter, `src="`+pngURI+`"`) {
		t.Errorf("outFooter = %q, want PNG data URI", outFooter)
	}

	// Each unique asset should be loaded once even when referenced across HTML/CSS/header/footer.
	for k, n := range calls {
		if n != 1 {
			t.Errorf("asset %v loaded %d times, want 1", k, n)
		}
	}
}

func TestResolvePDFInputsErrorsNameReference(t *testing.T) {
	missingID := uuid.New()
	pdfID := uuid.New()
	bigID := uuid.New()
	noFileID := uuid.New()
	blobGoneID := uuid.New()

	loader := func() *pdfAssetLoader {
		return newPDFAssetLoader(func(_ context.Context, ref pdfAssetRef) (string, string, []byte, error) {
			switch ref.ID {
			case pdfID:
				return "application/pdf", "report.pdf", []byte("%PDF-1.4"), nil
			case bigID:
				return "image/png", "huge.png", nil, wiki.ErrAssetTooLarge
			case noFileID:
				return "", "link", nil, wiki.ErrAssetNoFile
			case blobGoneID:
				return "", "", nil, blob.ErrNotFound
			default:
				return "", "", nil, apperr.ErrNotFound
			}
		})
	}

	cases := []struct {
		name      string
		html, css string
		wantSub   string
	}{
		{
			name:    "malformed attachment uuid",
			html:    `<img src="attachment:not-a-uuid/foo.png">`,
			wantSub: "attachment:not-a-uuid/foo.png",
		},
		{
			name:    "malformed library uuid",
			html:    `<img src="library:bogus">`,
			wantSub: "library:bogus",
		},
		{
			name:    "unknown attachment with filename",
			html:    `<img src="attachment:` + missingID.String() + `/cyric.jpg">`,
			wantSub: "attachment:" + missingID.String() + "/cyric.jpg",
		},
		{
			name:    "missing blob treated as inaccessible",
			html:    `<img src="attachment:` + blobGoneID.String() + `">`,
			wantSub: "attachment:" + blobGoneID.String(),
		},
		{
			name:    "non-image attachment rejected",
			html:    `<img src="attachment:` + pdfID.String() + `/report.pdf">`,
			wantSub: "application/pdf",
		},
		{
			name:    "oversized attachment rejected",
			html:    `<img src="attachment:` + bigID.String() + `/huge.png">`,
			wantSub: "attachment:" + bigID.String() + "/huge.png",
		},
		{
			name:    "library link without file rejected",
			html:    `<img src="library:` + noFileID.String() + `">`,
			wantSub: "library:" + noFileID.String(),
		},
		{
			name:    "unknown attachment in css",
			html:    `<div class="bg"></div>`,
			css:     `.bg { background: url(attachment:` + missingID.String() + `); }`,
			wantSub: "attachment:" + missingID.String(),
		},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			_, _, _, _, err := resolvePDFInputs(t.Context(), loader(), tc.html, tc.css, "", "")
			if err == nil {
				t.Fatalf("expected error, got nil")
			}
			var inv *apperr.ValidationError
			if !errors.As(err, &inv) {
				t.Fatalf("err = %T (%v), want *apperr.ValidationError", err, err)
			}
			if !strings.Contains(err.Error(), tc.wantSub) {
				t.Fatalf("err = %q, want substring %q", err.Error(), tc.wantSub)
			}
		})
	}
}

func TestResolvePDFInputsEnforcesTotalSizeCap(t *testing.T) {
	id1, id2, id3 := uuid.New(), uuid.New(), uuid.New()
	chunk := bytes.Repeat([]byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}, (10<<20)/8) // 10 MB each
	loader := newPDFAssetLoader(func(_ context.Context, _ pdfAssetRef) (string, string, []byte, error) {
		return "image/png", "big.png", chunk, nil
	})
	html := `<img src="attachment:` + id1.String() + `"><img src="attachment:` + id2.String() + `"><img src="attachment:` + id3.String() + `">`
	_, _, _, _, err := resolvePDFInputs(t.Context(), loader, html, "", "", "")
	if err == nil || !strings.Contains(err.Error(), id3.String()) {
		t.Fatalf("expected total-size error naming 3rd asset, got %v", err)
	}
}
