package wiki_test

import (
	"errors"
	"testing"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

// LAZYAGENTS-212: every deck and design is a Knowledge page. The page links to the canvas, which
// stays the body (and keeps its versions, reviews and the persona's tools); these tests hold the
// database to that, since the link is kept by triggers rather than by each place a canvas is made.

func (e env) chat(t *testing.T) store.ChatSession {
	t.Helper()
	c, err := e.q.CreateChatSession(e.ctx, store.CreateChatSessionParams{WorkspaceID: e.ws, Title: "Work", CreatedBy: e.me.ID, AgentID: e.atlas.ID, Harness: "claude-code", Model: "opus"})
	if err != nil {
		t.Fatal(err)
	}
	return c
}

func (e env) canvas(t *testing.T, chat uuid.UUID, kind, title string) store.ChatCanvas {
	t.Helper()
	cv, err := e.q.CreateChatCanvas(e.ctx, store.CreateChatCanvasParams{SessionID: chat, Kind: kind, Title: title})
	if err != nil {
		t.Fatal(err)
	}
	return cv
}

func (e env) canvasPage(t *testing.T, canvas uuid.UUID, viewer *uuid.UUID) (store.GetCanvasPageRow, error) {
	t.Helper()
	return e.q.GetCanvasPage(e.ctx, store.GetCanvasPageParams{CanvasID: &canvas, WorkspaceID: e.ws, Viewer: viewer})
}

func TestDecksAndDesignsArePrivatePagesInTheirFolders(t *testing.T) {
	e := setup(t)
	chat := e.chat(t)
	deck := e.canvas(t, chat.ID, "deck", "Q4/Q1 review")
	design := e.canvas(t, chat.ID, "design", "Checkout flow")
	again := e.canvas(t, chat.ID, "deck", "Q4/Q1 review")
	text := e.canvas(t, chat.ID, "text", "Notes")

	for _, c := range []struct {
		canvas uuid.UUID
		path   string
	}{
		// A slash in the title can't make folders.
		{deck.ID, "Slides/Q4-Q1 review"},
		{design.ID, "Designs/Checkout flow"},
		// The same title again gets the next free path.
		{again.ID, "Slides/Q4-Q1 review (2)"},
	} {
		p, err := e.canvasPage(t, c.canvas, &e.me.ID)
		if err != nil {
			t.Fatalf("%s: %v", c.path, err)
		}
		if deref(p.Path) != c.path {
			t.Errorf("path = %q, want %q", deref(p.Path), c.path)
		}
		a, err := e.q.GetArtifact(e.ctx, store.GetArtifactParams{ID: p.ID, WorkspaceID: e.ws, Viewer: &e.me.ID})
		if err != nil {
			t.Fatal(err)
		}
		// A page that opens: private to the chat's owner, published, and attached to the canvas's chat.
		if a.Audience != "private" || a.OwnerUserID == nil || *a.OwnerUserID != e.me.ID || a.CurrentVersionID == nil {
			t.Errorf("%s: audience %s, owner %v, version %v", c.path, a.Audience, a.OwnerUserID, a.CurrentVersionID)
		}
		if a.ChatSessionID == nil || *a.ChatSessionID != chat.ID {
			t.Errorf("%s: chat = %v, want %s", c.path, a.ChatSessionID, chat.ID)
		}
	}
	if _, err := e.canvasPage(t, text.ID, &e.me.ID); !errors.Is(err, pgx.ErrNoRows) {
		t.Errorf("a text canvas got a page: %v", err)
	}

	// Private: nobody else finds it, and the tree lists it with its kind for its owner.
	other := uuid.New()
	if _, err := e.canvasPage(t, deck.ID, &other); !errors.Is(err, pgx.ErrNoRows) {
		t.Errorf("another viewer found the deck's page: %v", err)
	}
	rows, err := e.q.ListNotes(e.ctx, store.ListNotesParams{WorkspaceID: e.ws, Viewer: &e.me.ID})
	if err != nil {
		t.Fatal(err)
	}
	kinds := map[string]string{}
	for _, r := range rows {
		kinds[deref(r.Path)] = r.CanvasKind
	}
	if kinds["Slides/Q4-Q1 review"] != "deck" || kinds["Designs/Checkout flow"] != "design" {
		t.Errorf("tree kinds = %v", kinds)
	}
}

func TestRenamingADeckRenamesItsPageAndDeletingThePageDeletesTheDeck(t *testing.T) {
	e := setup(t)
	chat := e.chat(t)
	deck := e.canvas(t, chat.ID, "deck", "Draft")
	p, err := e.canvasPage(t, deck.ID, &e.me.ID)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := e.svc.Pool.Exec(e.ctx, `UPDATE chat_canvases SET title = 'Board update' WHERE id = $1`, deck.ID); err != nil {
		t.Fatal(err)
	}
	renamed, err := e.canvasPage(t, deck.ID, &e.me.ID)
	if err != nil {
		t.Fatal(err)
	}
	// The title follows the deck; the path stays where the person put it.
	if renamed.Title != "Board update" || deref(renamed.Path) != deref(p.Path) {
		t.Errorf("after rename: %q at %q", renamed.Title, deref(renamed.Path))
	}

	// Retitling the page in Knowledge retitles the deck, so neither undoes the other later.
	if _, err := e.svc.Pool.Exec(e.ctx, `UPDATE artifacts SET title = 'Q4 board update' WHERE id = $1`, p.ID); err != nil {
		t.Fatal(err)
	}
	var deckTitle string
	if err := e.svc.Pool.QueryRow(e.ctx, `SELECT title FROM chat_canvases WHERE id = $1`, deck.ID).Scan(&deckTitle); err != nil || deckTitle != "Q4 board update" {
		t.Errorf("deck title after the page's = %q (%v)", deckTitle, err)
	}

	// Ensuring a page twice (the backfill, then a later insert) still leaves one.
	if _, err := e.svc.Pool.Exec(e.ctx, `SELECT ensure_canvas_page($1)`, deck.ID); err != nil {
		t.Fatal(err)
	}
	var pages int
	if err := e.svc.Pool.QueryRow(e.ctx, `SELECT count(*) FROM artifacts WHERE canvas_id = $1`, deck.ID).Scan(&pages); err != nil || pages != 1 {
		t.Fatalf("pages for the deck = %d (%v)", pages, err)
	}

	if err := e.svc.DeletePageAsUser(e.ctx, e.ws, e.me.ID, p.ID); err != nil {
		t.Fatal(err)
	}
	var canvases int
	if err := e.svc.Pool.QueryRow(e.ctx, `SELECT count(*) FROM chat_canvases WHERE id = $1`, deck.ID).Scan(&canvases); err != nil || canvases != 0 {
		t.Errorf("the deck outlived its page: %d (%v)", canvases, err)
	}
}

func TestKnowledgeQueriesSayWhatAPageHolds(t *testing.T) {
	e := setup(t)
	chat := e.chat(t)
	e.canvas(t, chat.ID, "design", "Checkout flow")
	note := e.save(t, "Product/Onboarding brief", "Calm first five minutes.")
	ctx := pageview.Person(e.ctx, e.me.ID)
	table, err := wiki.QueryPages(ctx, e.q, e.ws, wiki.PageQuery{Limit: 50})
	if err != nil {
		t.Fatal(err)
	}
	kinds := map[string]string{}
	for _, r := range table.Rows {
		kinds[r.Path] = r.Kind
		if r.Kind == "design" && r.CanvasID == nil {
			t.Errorf("%s: a design row without its canvas", r.Path)
		}
	}
	if kinds["Designs/Checkout flow"] != "design" || kinds[*note.Note.Path] != "document" {
		t.Errorf("kinds = %v", kinds)
	}
}
