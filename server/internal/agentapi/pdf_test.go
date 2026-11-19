package agentapi

import (
	"slices"
	"strings"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/agents"
)

func TestAssistantPDFSectionNamesTools(t *testing.T) {
	for _, tool := range []string{"render_pdf", "attach_file", "create_page", "patch_page"} {
		if !strings.Contains(agents.AssistantPDFSection, tool) {
			t.Errorf("PDF section doesn't mention %s", tool)
		}
		if !slices.Contains(chatTools, tool) {
			t.Errorf("PDF section names %s, which chats don't have", tool)
		}
	}
}

func TestMultiImageResultMCPContent(t *testing.T) {
	r := &multiImageResult{
		PNGs: [][]byte{[]byte("png-1"), []byte("png-2")},
		Meta: map[string]any{"pages": 2, "detail": "2 pages · Letter"},
	}
	res, err := r.mcpResult()
	if err != nil {
		t.Fatal(err)
	}
	if len(res.Content) != 3 {
		t.Fatalf("got %d content blocks, want 3", len(res.Content))
	}
	for i, want := range []string{"png-1", "png-2"} {
		img, ok := res.Content[i].(*mcp.ImageContent)
		if !ok || img.MIMEType != "image/png" || string(img.Data) != want {
			t.Fatalf("content[%d] = %#v, want PNG %q", i, res.Content[i], want)
		}
	}
	txt, ok := res.Content[2].(*mcp.TextContent)
	if !ok || txt.Text == "" {
		t.Fatalf("content[2] = %#v, want non-empty JSON text", res.Content[2])
	}
}

func TestPDFFilenameAndDetailFormatting(t *testing.T) {
	if got := pdfFilename("", "Q4 Architecture Review!"); got != "q4-architecture-review.pdf" {
		t.Fatalf("pdfFilename from title = %q", got)
	}
	if got := pdfFilename("brief", ""); got != "brief.pdf" {
		t.Fatalf("pdfFilename without ext = %q", got)
	}
	if got := pdfFilename("Report.PDF", ""); got != "Report.PDF" {
		t.Fatalf("pdfFilename preserves .PDF = %q", got)
	}
	if got := pdfFilename("", ""); got != "document.pdf" {
		t.Fatalf("pdfFilename fallback = %q", got)
	}
	if got := formatPDFDetail(1, "Letter"); got != "1 page · Letter" {
		t.Fatalf("singular detail = %q", got)
	}
	if got := formatPDFDetail(4, "A4 landscape"); got != "4 pages · A4 landscape" {
		t.Fatalf("plural detail = %q", got)
	}
}
