package wiki_test

import (
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

func embedsByRef(t *testing.T, embeds []wiki.Embed) map[string]wiki.Embed {
	t.Helper()
	out := map[string]wiki.Embed{}
	for _, e := range embeds {
		out[e.Ref] = e
	}
	return out
}

// Block, heading and whole-page embeds resolve to the target's text for the
// person, and a run reading the same body never gets a private target's text.
func TestEmbedsResolveBlocksAndHidePrivateTargetsFromRuns(t *testing.T) {
	e := setup(t)
	person := pageview.Person(e.ctx, e.me.ID)
	_, err := e.svc.SaveAsUser(person, e.ws, e.me.ID, wiki.Save{Path: "Embeds/Secret plan", Body: "# Secret plan\n\nIntro.\n\n## Route\n\nGo by the north gate.\n\nMeet at the ferry at dawn. ^arrival\n\n- Bring the map ^map-item\n", Audience: "private"})
	if err != nil {
		t.Fatal(err)
	}
	body := "![[Secret plan#^arrival]]\n\n![[Secret plan#^map-item]]\n\n![[Secret plan#Route]]\n\n![[Secret plan]]\n"
	host, err := e.svc.SaveAsUser(person, e.ws, e.me.ID, wiki.Save{Path: "Embeds/Host", Body: body, Audience: "shared"})
	if err != nil {
		t.Fatal(err)
	}

	got, err := wiki.ResolvePageEmbeds(person, e.q, e.ws, host.Note.ID, body)
	if err != nil {
		t.Fatal(err)
	}
	byRef := embedsByRef(t, got)
	for ref, want := range map[string]string{
		"![[Secret plan#^arrival]]":  "Meet at the ferry at dawn.",
		"![[Secret plan#^map-item]]": "Bring the map",
		"![[Secret plan#Route]]":     "Go by the north gate.",
		"![[Secret plan]]":           "Intro.",
	} {
		emb := byRef[ref]
		if !emb.Available || emb.Kind != "page" || !strings.Contains(emb.Markdown, want) {
			t.Errorf("%s resolved to %+v, want page containing %q", ref, emb, want)
		}
	}
	if strings.Contains(byRef["![[Secret plan#^arrival]]"].Markdown, "north gate") {
		t.Errorf("block embed leaked the rest of the page: %q", byRef["![[Secret plan#^arrival]]"].Markdown)
	}

	run, err := wiki.ResolvePageEmbeds(pageview.Run(e.ctx), e.q, e.ws, host.Note.ID, body)
	if err != nil {
		t.Fatal(err)
	}
	for _, emb := range run {
		if emb.Available || emb.Markdown != "" {
			t.Errorf("run received embedded private content: %+v", emb)
		}
	}
}

// A Designs frame and a Library image embed in a page for their owner, and
// resolve to nothing for a run, which has no person to own them.
func TestEmbedsResolveDesignFramesAndLibraryItems(t *testing.T) {
	e := setup(t)
	person := pageview.Person(e.ctx, e.me.ID)
	chat, err := e.q.CreateChatSession(person, store.CreateChatSessionParams{WorkspaceID: e.ws, CreatedBy: e.me.ID, AgentID: e.atlas.ID, Title: "Designs", Harness: "codex", Model: "test", Effort: "high"})
	if err != nil {
		t.Fatal(err)
	}
	canvas, err := e.q.CreateChatCanvas(person, store.CreateChatCanvasParams{SessionID: chat.ID, Kind: "design", Title: "Harbour flow"})
	if err != nil {
		t.Fatal(err)
	}
	design := `{"schema":1,"mode":"light","assets":{},"links":[],"token_sets":{},"pages":[{"id":"p_main","name":"Main","children":[{"id":"n_dock","type":"frame","name":"Dock","x":0,"y":0,"w":100,"h":80,"children":[]}]}]}`
	if _, err = e.q.CreateChatCanvasVersion(person, store.CreateChatCanvasVersionParams{CanvasID: canvas.ID, Seq: 1, Body: design, AuthorType: "user", AuthorID: e.me.ID}); err != nil {
		t.Fatal(err)
	}
	item, err := e.q.CreateLibraryItem(person, store.CreateLibraryItemParams{WorkspaceID: e.ws, UserID: e.me.ID, Kind: "image", Title: "Harbour map", Filename: "map.png", ContentType: "image/png", SizeBytes: 68, BlobKey: "library/map.png"})
	if err != nil {
		t.Fatal(err)
	}
	frame := "![[design:" + canvas.ID.String() + "#n_dock]]"
	image := "![[library:" + item.ID.String() + "]]"
	body := frame + "\n\n" + image + "\n"

	got, err := wiki.ResolveEmbeds(person, e.q, e.ws, body)
	if err != nil {
		t.Fatal(err)
	}
	byRef := embedsByRef(t, got)
	if d := byRef[frame]; !d.Available || d.Kind != "design" || d.Data["name"] != "Dock" {
		t.Errorf("design frame embed = %+v", d)
	}
	if l := byRef[image]; !l.Available || l.Kind != "image" || l.ContentType != "image/png" || !strings.Contains(l.URL, item.ID.String()) {
		t.Errorf("library embed = %+v", l)
	}

	run, err := wiki.ResolveEmbeds(pageview.Run(e.ctx), e.q, e.ws, body)
	if err != nil {
		t.Fatal(err)
	}
	for _, emb := range run {
		if emb.Available {
			t.Errorf("run resolved a person's embed: %+v", emb)
		}
	}
}

func TestEmbedsResolveObsidianFilenameWithWidthAndVisibility(t *testing.T) {
	e := setup(t)
	person := pageview.Person(e.ctx, e.me.ID)
	asset, err := e.q.PutKnowledgeAsset(person, store.PutKnowledgeAssetParams{
		WorkspaceID: e.ws,
		OwnerUserID: e.me.ID,
		ContentHash: "obsidian-img-hash",
		BlobKey:     "knowledge-assets/test/img.png",
		Filename:    "map.png",
		ContentType: "image/png",
		SizeBytes:   128,
	})
	if err != nil {
		t.Fatal(err)
	}

	body := "![[map.png|400]]\n\n![[attachments/map.png|320x200]]\n\n![[missing.png|400]]\n"
	got, err := wiki.ResolveEmbeds(person, e.q, e.ws, body)
	if err != nil {
		t.Fatal(err)
	}
	byRef := embedsByRef(t, got)
	for _, ref := range []string{"![[map.png|400]]", "![[attachments/map.png|320x200]]"} {
		emb := byRef[ref]
		if !emb.Available || emb.Kind != "file" || emb.Title != "map.png" || !strings.Contains(emb.URL, asset.ID.String()) {
			t.Errorf("%s resolved to %+v, want map.png asset", ref, emb)
		}
	}
	if missing := byRef["![[missing.png|400]]"]; missing.Available {
		t.Errorf("missing.png unexpectedly resolved: %+v", missing)
	}

	// A run with no person viewer cannot resolve private unreferenced attachments by filename.
	run, err := wiki.ResolveEmbeds(pageview.Run(e.ctx), e.q, e.ws, body)
	if err != nil {
		t.Fatal(err)
	}
	for _, emb := range run {
		if emb.Available {
			t.Errorf("run resolved private attachment %+v", emb)
		}
	}
}
