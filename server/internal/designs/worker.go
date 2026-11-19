package designs

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/design"
)

// DefaultWorkerURL is where the design worker lives in the compose stack.
const DefaultWorkerURL = "http://web:3000/internal/designs"

// WorkerTimeout bounds one call to the worker.
const WorkerTimeout = 15 * time.Second

// ErrUnavailable means the worker can't be reached or isn't configured. Callers
// degrade ("render unavailable") rather than fail the request.
var ErrUnavailable = errors.New("the design renderer is unavailable")

// Worker is the client of the Node design worker (web/lib/designs/worker.ts):
// it renders a design body to a PNG and computes settled node boxes.
type Worker struct {
	URL    string // DESIGN_WORKER_URL
	Token  string // DESIGN_WORKER_TOKEN; unset means unavailable
	Client *http.Client
	// Backoff is the pause before the one retry of a busy (503) worker.
	Backoff time.Duration
}

// Box is a node's box in page coordinates.
type Box = design.Box

// LaidPage is one page's node boxes.
type LaidPage struct {
	ID    string         `json:"id"`
	Boxes map[string]Box `json:"boxes"`
}

// RenderRequest is what to draw: the whole page or one node, at a scale, with
// the design's images as data URIs keyed by asset id.
type RenderRequest struct {
	Body   string            `json:"body"`
	Node   string            `json:"node,omitempty"`
	Page   string            `json:"page,omitempty"`
	Scale  float64           `json:"scale,omitempty"`
	Assets map[string]string `json:"assets,omitempty"`
}

// Rendered is a PNG and its size in design pixels.
type Rendered struct {
	PNG  []byte
	W, H int
}

// RejectedError is the worker refusing a request (400) or timing out (504):
// a message worth showing, unlike an outage.
type RejectedError struct {
	Status  int
	Message string
}

func (e *RejectedError) Error() string { return e.Message }

// Available reports whether calls can be attempted at all.
func (w *Worker) Available() bool { return w != nil && w.Token != "" }

func (w *Worker) base() string {
	if w.URL == "" {
		return DefaultWorkerURL
	}
	return strings.TrimRight(w.URL, "/")
}

func (w *Worker) post(ctx context.Context, path string, in any) (*http.Response, []byte, error) {
	if !w.Available() {
		return nil, nil, ErrUnavailable
	}
	raw, err := json.Marshal(in)
	if err != nil {
		return nil, nil, err
	}
	client := w.Client
	if client == nil {
		client = &http.Client{Timeout: WorkerTimeout}
	}
	backoff := w.Backoff
	if backoff == 0 {
		backoff = 400 * time.Millisecond
	}
	for attempt := 0; ; attempt++ {
		req, err := http.NewRequestWithContext(ctx, http.MethodPost, w.base()+path, bytes.NewReader(raw))
		if err != nil {
			return nil, nil, err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Authorization", "Bearer "+w.Token)
		res, err := client.Do(req)
		if err != nil {
			if ctx.Err() != nil {
				return nil, nil, ctx.Err()
			}
			return nil, nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
		}
		body, err := io.ReadAll(io.LimitReader(res.Body, 64<<20))
		res.Body.Close()
		if err != nil {
			return nil, nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
		}
		if res.StatusCode == http.StatusServiceUnavailable && attempt == 0 {
			select {
			case <-time.After(backoff):
				continue
			case <-ctx.Done():
				return nil, nil, ctx.Err()
			}
		}
		return res, body, nil
	}
}

// failure turns a non-200 reply into an error.
func failure(res *http.Response, body []byte) error {
	var m struct {
		Message string `json:"message"`
	}
	_ = json.Unmarshal(body, &m)
	switch res.StatusCode {
	case http.StatusBadRequest, http.StatusGatewayTimeout:
		if m.Message == "" {
			m.Message = "the renderer couldn't draw this design"
		}
		return &RejectedError{Status: res.StatusCode, Message: m.Message}
	}
	// 401 (wrong token), 503 (still busy after the retry), 5xx: not the design's fault.
	return fmt.Errorf("%w: worker answered %d %s", ErrUnavailable, res.StatusCode, m.Message)
}

// Render draws a design, a page or one node as a PNG.
func (w *Worker) Render(ctx context.Context, in RenderRequest) (Rendered, error) {
	res, body, err := w.post(ctx, "/render", in)
	if err != nil {
		return Rendered{}, err
	}
	if res.StatusCode != http.StatusOK {
		return Rendered{}, failure(res, body)
	}
	out := Rendered{PNG: body}
	out.W, _ = strconv.Atoi(res.Header.Get("X-Design-Width"))
	out.H, _ = strconv.Atoi(res.Header.Get("X-Design-Height"))
	return out, nil
}

// Layout computes settled node boxes in page coordinates, for every page or
// for one.
func (w *Worker) Layout(ctx context.Context, body, page string) ([]LaidPage, error) {
	in := map[string]string{"body": body}
	if page != "" {
		in["page"] = page
	}
	res, raw, err := w.post(ctx, "/layout", in)
	if err != nil {
		return nil, err
	}
	if res.StatusCode != http.StatusOK {
		return nil, failure(res, raw)
	}
	var out struct {
		Pages []LaidPage `json:"pages"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("%w: unreadable layout reply", ErrUnavailable)
	}
	return out.Pages, nil
}

// Inspect asks the worker for a node's Inspect output (web/lib/designs/inspect.ts):
// code for target css, tailwind or react, with spacing, type, tokens and assets.
func (w *Worker) Inspect(ctx context.Context, body, node, target string) (map[string]any, error) {
	res, raw, err := w.post(ctx, "/inspect", map[string]string{"body": body, "node": node, "target": target})
	if err != nil {
		return nil, err
	}
	if res.StatusCode != http.StatusOK {
		return nil, failure(res, raw)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("%w: unreadable inspect reply", ErrUnavailable)
	}
	return out, nil
}

// ImportRequest is design_import's input to the worker: Mermaid or SVG text
// for a page of the design in Body, at (X, Y) or right of the page's content.
type ImportRequest struct {
	Body    string   `json:"body"`
	Page    string   `json:"page"`
	X       *float64 `json:"x,omitempty"`
	Y       *float64 `json:"y,omitempty"`
	Mermaid *string  `json:"mermaid,omitempty"`
	SVG     *string  `json:"svg,omitempty"`
}

// Imported is the node the text became (a section or group subtree, already
// valid in the design) and what was skipped.
type Imported struct {
	Node     map[string]any `json:"node"`
	Warnings []string       `json:"warnings"`
}

// Import turns Mermaid or SVG text into a node for the page. Text the worker
// can't import comes back as a RejectedError naming the problem.
func (w *Worker) Import(ctx context.Context, in ImportRequest) (Imported, error) {
	var out Imported
	res, raw, err := w.post(ctx, "/import", in)
	if err != nil {
		return out, err
	}
	if res.StatusCode != http.StatusOK {
		return out, failure(res, raw)
	}
	if err := json.Unmarshal(raw, &out); err != nil || out.Node == nil {
		return out, fmt.Errorf("%w: unreadable import reply", ErrUnavailable)
	}
	return out, nil
}

// PDFWorkerTimeout bounds one HTML/CSS -> PDF render call (including page preview rasterisation).
const PDFWorkerTimeout = 35 * time.Second

// PDFRenderRequest is what the PDF renderer turns into a PDF document.
type PDFRenderRequest struct {
	HTML            string `json:"html"`
	CSS             string `json:"css,omitempty"`
	PageSize        any    `json:"page_size,omitempty"`
	Orientation     string `json:"orientation,omitempty"`
	Margins         any    `json:"margins,omitempty"`
	HeaderHTML      string `json:"header_html,omitempty"`
	FooterHTML      string `json:"footer_html,omitempty"`
	PrintBackground *bool  `json:"print_background,omitempty"`
	PreviewPages    []int  `json:"preview_pages,omitempty"`
}

// PDFPreview is one rasterised page of a rendered PDF for visual inspection.
type PDFPreview struct {
	Page   int
	Width  int
	Height int
	PNG    []byte
}

// PDFRendered is the rendered PDF bytes, page count, page size label, and preview PNGs.
type PDFRendered struct {
	PDF      []byte
	Pages    int
	PageSize string
	Previews []PDFPreview
}

// RenderPDF renders HTML+CSS to a PDF via the Node worker's /pdf endpoint.
func (w *Worker) RenderPDF(ctx context.Context, in PDFRenderRequest) (PDFRendered, error) {
	if !w.Available() {
		return PDFRendered{}, ErrUnavailable
	}
	// Use a generous client timeout for headless Chromium rendering when no custom client is injected.
	ww := *w
	if ww.Client == nil {
		ww.Client = &http.Client{Timeout: PDFWorkerTimeout}
	}
	res, raw, err := ww.post(ctx, "/pdf", in)
	if err != nil {
		return PDFRendered{}, err
	}
	if res.StatusCode != http.StatusOK {
		return PDFRendered{}, failure(res, raw)
	}
	var wire struct {
		PDFBase64 string `json:"pdf_base64"`
		Pages     int    `json:"pages"`
		PageSize  string `json:"page_size"`
		Previews  []struct {
			Page      int    `json:"page"`
			Width     int    `json:"width"`
			Height    int    `json:"height"`
			PNGBase64 string `json:"png_base64"`
		} `json:"previews"`
	}
	if err := json.Unmarshal(raw, &wire); err != nil || wire.PDFBase64 == "" {
		return PDFRendered{}, fmt.Errorf("%w: unreadable PDF reply", ErrUnavailable)
	}
	pdfBytes, err := base64.StdEncoding.DecodeString(wire.PDFBase64)
	if err != nil {
		return PDFRendered{}, fmt.Errorf("%w: invalid PDF bytes", ErrUnavailable)
	}
	previews := make([]PDFPreview, 0, len(wire.Previews))
	for _, p := range wire.Previews {
		pngBytes, derr := base64.StdEncoding.DecodeString(p.PNGBase64)
		if derr != nil {
			continue
		}
		previews = append(previews, PDFPreview{Page: p.Page, Width: p.Width, Height: p.Height, PNG: pngBytes})
	}
	pages := wire.Pages
	if pages < 1 {
		pages = 1
	}
	return PDFRendered{PDF: pdfBytes, Pages: pages, PageSize: wire.PageSize, Previews: previews}, nil
}
