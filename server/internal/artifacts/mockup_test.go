package artifacts_test

import (
	"context"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

const wireframe = `<?xml version="1.0"?>
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="400" height="300" viewBox="0 0 400 300">
  <title>Checkout</title>
  <defs><rect id="btn" width="80" height="24"/></defs>
  <rect x="10" y="10" width="380" height="280" fill="#fff" stroke="#000" style="fill:#fff"/>
  <use href="#btn" x="20" y="250"/>
  <image xlink:href="data:image/png;base64,AAAA" width="10" height="10"/>
  <text x="20" y="40">Pay <tspan>zorblax</tspan></text>
</svg>`

const inkscape = `<?xml version="1.0" encoding="UTF-8" standalone="no"?>
<svg xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:cc="http://creativecommons.org/ns#"
  xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" xmlns:svg="http://www.w3.org/2000/svg"
  xmlns="http://www.w3.org/2000/svg" xmlns:sodipodi="http://sodipodi.sourceforge.net/DTD/sodipodi-0.dtd"
  xmlns:inkscape="http://www.inkscape.org/namespaces/inkscape" width="100" height="50" inkscape:version="1.2">
  <sodipodi:namedview id="base" pagecolor="#ffffff" inkscape:zoom="1"/>
  <metadata><rdf:RDF><cc:Work rdf:about=""><dc:format>image/svg+xml</dc:format></cc:Work></rdf:RDF></metadata>
  <defs><linearGradient id="grad"/></defs>
  <svg:rect id="r" width="100" height="50" style="fill:url(#grad);stroke:#000" inkscape:label="box"/>
</svg>`

func TestValidSVG(t *testing.T) {
	cases := []struct {
		name string
		svg  string
		ok   bool
	}{
		{"wireframe", wireframe, true},
		{"minimal", `<svg xmlns="http://www.w3.org/2000/svg"/>`, true},
		{"script", `<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>`, false},
		{"onload attribute", `<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>`, false},
		{"onclick on child", `<svg xmlns="http://www.w3.org/2000/svg"><rect onclick="x()"/></svg>`, false},
		{"foreignObject", `<svg xmlns="http://www.w3.org/2000/svg"><foreignObject><div/></foreignObject></svg>`, false},
		{"iframe", `<svg xmlns="http://www.w3.org/2000/svg"><iframe/></svg>`, false},
		{"javascript href", `<svg xmlns="http://www.w3.org/2000/svg"><a href="javascript:alert(1)"><rect/></a></svg>`, false},
		{"javascript xlink href", `<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><a xlink:href="javascript:alert(1)"><rect/></a></svg>`, false},
		{"external href", `<svg xmlns="http://www.w3.org/2000/svg"><image href="https://evil.example/x.png"/></svg>`, false},
		{"svg data href", `<svg xmlns="http://www.w3.org/2000/svg"><image href="data:image/svg+xml;base64,AAAA"/></svg>`, false},
		{"css import", `<svg xmlns="http://www.w3.org/2000/svg"><style>@import url(https://evil.example/a.css);</style></svg>`, false},
		{"css external url", `<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill:url(https://evil.example/p)"/></svg>`, false},
		{"doctype", `<!DOCTYPE svg [<!ENTITY x "y">]><svg xmlns="http://www.w3.org/2000/svg"/>`, false},
		{"non-svg root", `<html><body/></html>`, false},
		{"not xml", `just words`, false},
		{"malformed", `<svg><rect></svg>`, false},
		{"animated href", `<svg xmlns="http://www.w3.org/2000/svg"><a><animate attributeName="href" values="#a"/><rect/></a></svg>`, false},
		{"set javascript", `<svg xmlns="http://www.w3.org/2000/svg"><a><set attributeName="xlink:href" to="java	script:alert(1)"/></a></svg>`, false},
		{"javascript in values", `<svg xmlns="http://www.w3.org/2000/svg"><rect><animate attributeName="fill" values="javascript:alert(1)"/></rect></svg>`, false},
		{"style child resets", `<svg xmlns="http://www.w3.org/2000/svg"><style><a/>@import url(https://e/x.css)</style></svg>`, false},
		{"css escaped url", `<svg xmlns="http://www.w3.org/2000/svg"><style>rect{fill:u\72l(https://e/p)}</style></svg>`, false},
		{"css escaped import", `<svg xmlns="http://www.w3.org/2000/svg"><style>@\69mport "https://e/x.css";</style></svg>`, false},
		{"style attr escape", `<svg xmlns="http://www.w3.org/2000/svg"><rect style="fill:u\72l(https://e/p)"/></svg>`, false},
		{"fill external url", `<svg xmlns="http://www.w3.org/2000/svg"><rect fill="url(https://e/p)"/></svg>`, false},
		{"filter external url", `<svg xmlns="http://www.w3.org/2000/svg"><rect filter="url('https://e/f.svg#x')"/></svg>`, false},
		{"xhtml img", `<svg xmlns="http://www.w3.org/2000/svg"><h:img xmlns:h="http://www.w3.org/1999/xhtml" src="https://e"/></svg>`, false},
		{"xhtml form", `<svg xmlns="http://www.w3.org/2000/svg"><h:form xmlns:h="http://www.w3.org/1999/xhtml" action="https://e"/></svg>`, false},
		{"mathml", `<svg xmlns="http://www.w3.org/2000/svg"><m:math xmlns:m="http://www.w3.org/1998/Math/MathML"/></svg>`, false},
		{"src attribute", `<svg xmlns="http://www.w3.org/2000/svg"><rect src="https://e"/></svg>`, false},
		{"fill local url", `<svg xmlns="http://www.w3.org/2000/svg"><defs><linearGradient id="grad"/></defs><rect fill="url(#grad)"/></svg>`, true},
		{"inkscape export", inkscape, true},
		{"animate fill ok", `<svg xmlns="http://www.w3.org/2000/svg"><rect><animate attributeName="fill" values="red;blue" dur="1s"/></rect></svg>`, true},
	}
	for _, c := range cases {
		err := artifacts.ValidSVG(c.svg)
		if (err == nil) != c.ok {
			t.Errorf("%s: ok=%v err=%v", c.name, c.ok, err)
		}
	}
	if got := artifacts.SVGText(wireframe); !strings.Contains(got, "Checkout") || !strings.Contains(got, "Pay zorblax") {
		t.Errorf("SVGText = %q", got)
	}
}

func TestCreateMockup(t *testing.T) {
	f := setup(t)
	ctx := context.Background()

	a, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "mockup", Title: "Checkout", Content: md(wireframe)})
	if err != nil {
		t.Fatal(err)
	}
	a, _ = f.q.GetArtifact(ctx, store.GetArtifactParams{ID: a.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
	v, err := f.q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
	if err != nil {
		t.Fatal(err)
	}
	// The style attribute is rewritten into presentation attributes (profile
	// v1); nothing else about the source changes.
	normalized := strings.Replace(wireframe, ` style="fill:#fff"`, "", 1)
	if v.BodyMd == nil || *v.BodyMd != normalized || v.ContentType != "image/svg+xml" {
		t.Fatalf("stored %v %q: %v", v.BodyMd != nil, v.ContentType, deref(v.BodyMd))
	}
	if v.ReviewState == nil || *v.ReviewState != "pending" {
		t.Fatalf("review state = %v", v.ReviewState)
	}
	if got := outline(t, f, a); len(got) != 0 {
		t.Fatalf("a mockup has no outline: %+v", got)
	}
	if list, err := f.q.ListArtifacts(ctx, store.ListArtifactsParams{WorkspaceID: f.ws, Q: ptr("zorblax"), Viewer: pageview.From(ctx).UserID, IncludeAgent: pageview.From(ctx).IncludeAgent}); err != nil || len(list) != 1 {
		t.Fatalf("search over svg text: %d %v", len(list), err)
	}

	// An uploaded .svg is read into text like markdown.
	file := &artifacts.File{Name: "login.svg", ContentType: "image/svg+xml", Size: int64(len(wireframe)), Body: strings.NewReader(wireframe)}
	b, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "mockup", Content: artifacts.Content{File: file}})
	if err != nil {
		t.Fatal(err)
	}
	if b.Title != "login" {
		t.Errorf("title from file name = %q", b.Title)
	}
	b, _ = f.q.GetArtifact(ctx, store.GetArtifactParams{ID: b.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
	bv, _ := f.q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *b.CurrentVersionID, ArtifactID: b.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
	if bv.BodyMd == nil || bv.BlobKey != nil || len(f.blobs.objs) != 0 {
		t.Fatal("svg file should be stored as text, not a blob")
	}

	// Anything else is rejected, as are unsafe documents and markdown versions.
	png := &artifacts.File{Name: "shot.png", ContentType: "image/png", Size: 3, Body: strings.NewReader("abc")}
	if _, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "mockup", Title: "x", Content: artifacts.Content{File: png}}); err == nil {
		t.Error("png accepted as a mockup")
	}
	if _, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "mockup", Title: "x", Content: md(`<svg onload="x()"/>`)}); err == nil {
		t.Error("unsafe svg accepted")
	}
	if _, err := f.svc.AddVersion(ctx, f.ws, f.maya, a.ID, artifacts.NewVersion{Content: md("# markdown")}); err == nil {
		t.Error("markdown accepted as a mockup version")
	}
	// Safe SVG outside profile v1 is refused with what to change.
	blurred := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10"><rect width="10" height="10" filter="url(#f)"/></svg>`
	if _, err := f.svc.AddVersion(ctx, f.ws, f.maya, a.ID, artifacts.NewVersion{Content: md(blurred)}); err == nil || !strings.Contains(err.Error(), "attribute filter isn't allowed") {
		t.Errorf("filter accepted as a mockup version: %v", err)
	}
	// Simple CSS is stored as presentation attributes.
	styled := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
  <style>.card { fill: #EEF2FF; stroke: #4F46E5 }</style>
  <rect class="card" width="10" height="10"/>
</svg>`
	if _, err := f.svc.AddVersion(ctx, f.ws, f.maya, a.ID, artifacts.NewVersion{Content: md(styled)}); err != nil {
		t.Fatal(err)
	}
	a, _ = f.q.GetArtifact(ctx, store.GetArtifactParams{ID: a.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
	v2, _ := f.q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *a.CurrentVersionID, ArtifactID: a.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
	if want := `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10">
  <rect width="10" height="10" fill="#EEF2FF" stroke="#4F46E5"/>
</svg>`; deref(v2.BodyMd) != want {
		t.Errorf("stored %q, want %q", deref(v2.BodyMd), want)
	}
	// An .svg design stays a blob.
	d, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "design", Title: "Icon", Content: artifacts.Content{File: &artifacts.File{Name: "i.svg", ContentType: "image/svg+xml", Size: 5, Body: strings.NewReader("<svg>")}}})
	if err != nil {
		t.Fatal(err)
	}
	d, _ = f.q.GetArtifact(ctx, store.GetArtifactParams{ID: d.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
	if dv, _ := f.q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: *d.CurrentVersionID, ArtifactID: d.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID}); dv.BlobKey == nil {
		t.Error("design svg should stay a blob")
	}
	// ...and an SVG file can be a new version of a design or a report.
	if _, err := f.svc.AddVersion(ctx, f.ws, f.maya, d.ID, artifacts.NewVersion{Content: artifacts.Content{File: &artifacts.File{Name: "i2.svg", ContentType: "image/svg+xml", Size: 5, Body: strings.NewReader("<svg>")}}}); err != nil {
		t.Errorf("svg file version of a design: %v", err)
	}
}

func TestMockupGate(t *testing.T) {
	f := setup(t)
	ctx := context.Background()
	epics, _ := f.q.ListEpics(ctx, f.ws)
	var epic store.Epic
	for _, e := range epics {
		if e.Name == "Refunds API" {
			epic = e
		}
	}
	newTicket := func(inEpic bool, requires bool) store.Ticket {
		in := tracker.NewTicket{ProjectKey: "PAY", Title: "UI work", RequiresMockup: requires}
		if inEpic {
			in.EpicID = &epic.ID
		}
		tk, err := f.tr.Create(ctx, f.ws, tracker.UserActor(f.maya.ID), in)
		if err != nil {
			t.Fatal(err)
		}
		return tk
	}
	gate := func(tk store.Ticket) artifacts.Gate {
		tk, _ = f.q.GetTicketByID(ctx, tk.ID)
		g, err := artifacts.MockupGate(ctx, f.q, tk)
		if err != nil {
			t.Fatal(err)
		}
		return g
	}

	plain := newTicket(false, false)
	if g := gate(plain); g.Required || !g.Unblocked() {
		t.Fatalf("plain ticket gate = %+v", g)
	}
	flagged := newTicket(false, true)
	if g := gate(flagged); !g.Required || g.FromEpic || g.Approved || g.Unblocked() {
		t.Fatalf("flagged gate = %+v", g)
	}

	inEpic := newTicket(true, false)
	if _, err := f.tr.SetEpicRequiresMockup(ctx, f.ws, epic.ID, true); err != nil {
		t.Fatal(err)
	}
	if g := gate(inEpic); !g.Required || !g.FromEpic {
		t.Fatalf("epic-required gate = %+v", g)
	}

	// An epic-level mockup is a candidate; approving its current version opens the gate.
	m, err := f.svc.Create(ctx, f.ws, f.maya, artifacts.NewArtifact{ProjectKey: "PAY", Type: "mockup", Title: "Refund screen", EpicID: &epic.ID, Content: md(wireframe)})
	if err != nil {
		t.Fatal(err)
	}
	g := gate(inEpic)
	if len(g.Mockups) != 1 || g.Mockups[0].ReviewState != "pending" || g.Approved {
		t.Fatalf("epic mockup gate = %+v", g)
	}
	if len(gate(flagged).Mockups) != 0 {
		t.Fatal("epic mockup leaked to a ticket outside the epic")
	}
	approve := func() {
		m, _ = f.q.GetArtifact(ctx, store.GetArtifactParams{ID: m.ID, WorkspaceID: f.ws, Viewer: pageview.From(ctx).UserID})
		state := "approved"
		if _, err := f.q.ReviewArtifactVersion(ctx, store.ReviewArtifactVersionParams{ID: *m.CurrentVersionID, ReviewState: &state, ReviewedByUserID: &f.maya.ID, ReviewPins: []byte("[]")}); err != nil {
			t.Fatal(err)
		}
	}
	approve()
	if g := gate(inEpic); !g.Approved || !g.Unblocked() {
		t.Fatalf("approved gate = %+v", g)
	}
	// A new version resets to pending and closes the gate again.
	if _, err := f.svc.AddVersion(ctx, f.ws, f.maya, m.ID, artifacts.NewVersion{Content: md(wireframe + "\n")}); err != nil {
		t.Fatal(err)
	}
	if g := gate(inEpic); g.Approved || g.Mockups[0].ReviewState != "pending" || g.Mockups[0].VersionLabel != "v2" {
		t.Fatalf("after new version = %+v", g)
	}

	// An attached mockup counts for the flagged ticket.
	if err := f.tr.AttachArtifact(ctx, f.ws, tracker.UserActor(f.maya.ID), flagged.Key, m.ID, "context"); err != nil {
		t.Fatal(err)
	}
	approve()
	if g := gate(flagged); !g.Approved || len(g.Mockups) != 1 {
		t.Fatalf("attached gate = %+v", g)
	}
}
