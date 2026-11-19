package agentapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"path"
	"strings"
	"unicode"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/designs"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

// PDFRenderer renders HTML+CSS into a PDF and optional page preview PNGs.
// *designs.Worker implements it via the bundled Node worker.
type PDFRenderer interface {
	RenderPDF(ctx context.Context, in designs.PDFRenderRequest) (designs.PDFRendered, error)
}

// multiImageResult sends zero or more PNG preview images alongside JSON metadata
// over MCP, and plain JSON (with preview_count) over REST.
type multiImageResult struct {
	PNGs [][]byte
	Meta map[string]any
}

func (r *multiImageResult) MarshalJSON() ([]byte, error) {
	return json.Marshal(r.Meta)
}

func (r *multiImageResult) mcpResult() (*mcp.CallToolResult, error) {
	meta, err := json.Marshal(r.Meta)
	if err != nil {
		return nil, err
	}
	content := make([]mcp.Content, 0, len(r.PNGs)+1)
	for _, png := range r.PNGs {
		content = append(content, &mcp.ImageContent{Data: png, MIMEType: "image/png"})
	}
	content = append(content, &mcp.TextContent{Text: string(meta)})
	return &mcp.CallToolResult{Content: content}, nil
}

type PDFMarginsIn struct {
	Top    string `json:"top,omitempty" jsonschema:"Top margin, e.g. 0.6in or 15mm"`
	Right  string `json:"right,omitempty" jsonschema:"Right margin, e.g. 0.6in or 15mm"`
	Bottom string `json:"bottom,omitempty" jsonschema:"Bottom margin, e.g. 0.6in or 15mm"`
	Left   string `json:"left,omitempty" jsonschema:"Left margin, e.g. 0.6in or 15mm"`
}

type RenderPDFIn struct {
	Title             string        `json:"title,omitempty" jsonschema:"Title shown in the chat card and Library, e.g. Q4 Architecture Review"`
	Filename          string        `json:"filename,omitempty" jsonschema:"PDF file name (.pdf added if omitted), e.g. q4-review.pdf"`
	HTML              string        `json:"html" jsonschema:"HTML document or body fragment to render. Runs offline with scripts disabled (no remote URLs): use inline CSS, SVG, data: URIs, Knowledge attachments (<img src=\"attachment:<asset-id>\"> or attachment:<asset-id>/<filename>), or Library images (library:<library_item_id>). Bundled fonts: Inter, Liberation Serif, Liberation Sans, Liberation Mono."`
	CSS               string        `json:"css,omitempty" jsonschema:"Optional print CSS appended after the base styles (supports @page, Flexbox, Grid, break-inside: avoid, and url(\"attachment:...\") / url(\"library:...\"))"`
	PageSize          string        `json:"page_size,omitempty" jsonschema:"letter (default), a4, legal, tabloid, a5 or a3"`
	WidthIn           *float64      `json:"width_in,omitempty" jsonschema:"Custom page width in inches (2 to 24); give with height_in instead of page_size"`
	HeightIn          *float64      `json:"height_in,omitempty" jsonschema:"Custom page height in inches (2 to 24); give with width_in instead of page_size"`
	Orientation       string        `json:"orientation,omitempty" jsonschema:"portrait (default) or landscape"`
	Margins           *PDFMarginsIn `json:"margins,omitempty" jsonschema:"Page margins (default 0.6in, or 0.8in top/bottom when header_html/footer_html is set)"`
	HeaderHTML        string        `json:"header_html,omitempty" jsonschema:"Optional running header HTML template (supports <span class=\"pageNumber\"></span> and <span class=\"totalPages\"></span>)"`
	FooterHTML        string        `json:"footer_html,omitempty" jsonschema:"Optional running footer HTML template (supports <span class=\"pageNumber\"></span> and <span class=\"totalPages\"></span>)"`
	PrintBackground   *bool         `json:"print_background,omitempty" jsonschema:"Include CSS background colors and graphics; true when omitted"`
	PreviewPages      []int         `json:"preview_pages,omitempty" jsonschema:"1-based page numbers to return as PNG previews for visual QA (up to 4; defaults to [1, 2]). Pass [] to skip previews."`
	PreviewOnly       bool          `json:"preview_only,omitempty" jsonschema:"When true, render and return preview PNGs without saving to Library or Knowledge yet so you can inspect and refine the layout first"`
	AttachToKnowledge bool          `json:"attach_to_knowledge,omitempty" jsonschema:"When true (and not preview_only), also store the PDF as a Knowledge asset and return its ![[attachment:...]] embed to place in a page with create_page or patch_page"`
}

func pdfFilename(filename, title string) string {
	raw := strings.TrimSpace(filename)
	if raw == "" {
		raw = slugifyPDFName(title)
	}
	if raw == "" {
		raw = "document"
	}
	if !strings.EqualFold(path.Ext(raw), ".pdf") {
		raw += ".pdf"
	}
	name := runs.ChatAttachmentName(raw)
	if name == "" {
		return "document.pdf"
	}
	if !strings.EqualFold(path.Ext(name), ".pdf") {
		name += ".pdf"
	}
	return name
}

func slugifyPDFName(s string) string {
	var b strings.Builder
	prevDash := false
	for _, r := range strings.ToLower(strings.TrimSpace(s)) {
		switch {
		case unicode.IsLetter(r) || unicode.IsDigit(r):
			b.WriteRune(r)
			prevDash = false
		case !prevDash && b.Len() > 0:
			b.WriteByte('-')
			prevDash = true
		}
		if b.Len() >= 80 {
			break
		}
	}
	return strings.Trim(b.String(), "-")
}

func formatPDFDetail(pages int, pageSize string) string {
	unit := "pages"
	if pages == 1 {
		unit = "page"
	}
	if strings.TrimSpace(pageSize) == "" {
		return fmt.Sprintf("%d %s", pages, unit)
	}
	return fmt.Sprintf("%d %s · %s", pages, unit, strings.TrimSpace(pageSize))
}

// renderPDF renders HTML/CSS to a PDF via the sandboxed Node worker, saves it
// to the person's Library (and optionally Knowledge assets), and returns PNG
// previews of the rendered pages so any persona can visually QA its work.
func renderPDF(ctx context.Context, d Deps, c agents.Caller, in RenderPDFIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "render_pdf")
	if err != nil {
		return nil, err
	}
	if strings.TrimSpace(in.HTML) == "" {
		return nil, apperr.Invalid("html", "is required")
	}
	if (in.WidthIn == nil) != (in.HeightIn == nil) {
		return nil, apperr.Invalid("width_in", "give both width_in and height_in, or neither")
	}
	if in.WidthIn != nil && strings.TrimSpace(in.PageSize) != "" {
		return nil, apperr.Invalid("page_size", "give either page_size or width_in/height_in, not both")
	}
	if in.PreviewOnly && in.AttachToKnowledge {
		return nil, apperr.Invalid("attach_to_knowledge", "cannot attach to Knowledge while preview_only is true")
	}
	if len(in.PreviewPages) > 4 {
		return nil, apperr.Invalid("preview_pages", "request at most 4 preview pages at a time")
	}
	if d.PDF == nil {
		return nil, apperr.Conflict("the PDF renderer isn't configured on this server")
	}
	if !in.PreviewOnly && d.Files == nil {
		return nil, apperr.Conflict("saving files isn't available here")
	}
	if in.AttachToKnowledge && d.Wiki == nil {
		return nil, apperr.Conflict("Knowledge storage isn't available here")
	}

	resolvedHTML, resolvedCSS, resolvedHeader, resolvedFooter, err := resolvePDFInputs(
		ctx,
		newWikiPDFAssetLoader(d.Wiki, c.Agent.WorkspaceID, scope.UserID),
		in.HTML, in.CSS, in.HeaderHTML, in.FooterHTML,
	)
	if err != nil {
		return nil, err
	}

	req := designs.PDFRenderRequest{
		HTML:            resolvedHTML,
		CSS:             resolvedCSS,
		Orientation:     strings.TrimSpace(in.Orientation),
		HeaderHTML:      resolvedHeader,
		FooterHTML:      resolvedFooter,
		PrintBackground: in.PrintBackground,
		PreviewPages:    in.PreviewPages,
	}
	if in.WidthIn != nil {
		req.PageSize = map[string]float64{"width_in": *in.WidthIn, "height_in": *in.HeightIn}
	} else if s := strings.TrimSpace(in.PageSize); s != "" {
		req.PageSize = s
	}
	if in.Margins != nil {
		m := map[string]string{}
		if s := strings.TrimSpace(in.Margins.Top); s != "" {
			m["top"] = s
		}
		if s := strings.TrimSpace(in.Margins.Right); s != "" {
			m["right"] = s
		}
		if s := strings.TrimSpace(in.Margins.Bottom); s != "" {
			m["bottom"] = s
		}
		if s := strings.TrimSpace(in.Margins.Left); s != "" {
			m["left"] = s
		}
		if len(m) > 0 {
			req.Margins = m
		}
	}

	rendered, err := d.PDF.RenderPDF(ctx, req)
	var rejected *designs.RejectedError
	switch {
	case errors.As(err, &rejected):
		return nil, apperr.Invalid("html", "%s", rejected.Message)
	case errors.Is(err, designs.ErrUnavailable):
		return nil, apperr.Conflict("PDF renderer unavailable: %s", err.Error())
	case err != nil:
		return nil, err
	}

	previewNums := make([]int, 0, len(rendered.Previews))
	pngs := make([][]byte, 0, len(rendered.Previews))
	for _, p := range rendered.Previews {
		previewNums = append(previewNums, p.Page)
		pngs = append(pngs, p.PNG)
	}

	detail := formatPDFDetail(rendered.Pages, rendered.PageSize)
	if in.PreviewOnly {
		meta := map[string]any{
			"preview_only":    true,
			"pages":           rendered.Pages,
			"page_size":       rendered.PageSize,
			"size_bytes":      len(rendered.PDF),
			"detail":          detail,
			"previewed_pages": previewNums,
			"next":            "Inspect the preview page images for layout, spacing and page breaks. When ready, call render_pdf again with preview_only false to save it.",
		}
		return &multiImageResult{PNGs: pngs, Meta: meta}, nil
	}

	name := pdfFilename(in.Filename, in.Title)
	title := strings.TrimSpace(in.Title)
	if title == "" {
		title = strings.TrimSuffix(name, path.Ext(name))
	}
	l, err := d.Files.KeepChatFileWithDetail(ctx, scope.UserID, c.Agent.WorkspaceID, &scope.ChatID, scope.PersonaID, title, name, detail, rendered.PDF)
	if err != nil {
		return nil, err
	}

	meta := map[string]any{
		"library_item_id": l.ID,
		"title":           l.Title,
		"filename":        l.Filename,
		"pages":           rendered.Pages,
		"page_size":       rendered.PageSize,
		"size_bytes":      l.SizeBytes,
		"detail":          l.Detail,
		"previewed_pages": previewNums,
		"tell_the_person": "Saved to the person's Library under Files. Include a fenced ```pdf block containing only the library_item_id so the chat shows a preview card with download.",
	}
	if in.AttachToKnowledge {
		asset, aerr := d.Wiki.StoreAssetBytes(ctx, c.Agent.WorkspaceID, scope.UserID, l.Filename, rendered.PDF)
		if aerr != nil {
			return nil, aerr
		}
		ref := wiki.AttachmentRef(asset.ID, asset.Filename)
		meta["knowledge_asset_id"] = asset.ID
		meta["knowledge_embed"] = "![[" + ref + "]]"
		meta["knowledge_hint"] = "Place knowledge_embed in a Knowledge page with create_page or patch_page."
	}
	return &multiImageResult{PNGs: pngs, Meta: meta}, nil
}
