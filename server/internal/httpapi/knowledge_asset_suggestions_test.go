package httpapi

import (
	"fmt"
	"strings"
	"testing"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

func TestKnowledgeImageSuggestionsFilterTypeAndVisibility(t *testing.T) {
	e := newChatEnv(t)
	ctx := t.Context()
	other, err := e.q.CreateUser(ctx, store.CreateUserParams{WorkspaceID: e.me.WorkspaceID, Name: "Other", Email: "other@example.com"})
	if err != nil {
		t.Fatal(err)
	}
	put := func(owner uuid.UUID, name, mime string) store.KnowledgeAsset {
		t.Helper()
		asset, err := e.q.PutKnowledgeAsset(ctx, store.PutKnowledgeAssetParams{WorkspaceID: e.me.WorkspaceID, OwnerUserID: owner, ContentHash: uuid.NewString(), BlobKey: uuid.NewString(), Filename: name, ContentType: mime, SizeBytes: 1})
		if err != nil {
			t.Fatal(err)
		}
		return asset
	}
	own := put(e.me.ID, "Map.PNG", "image/png")
	shared := put(other.ID, "shared-map.svg", "image/svg+xml")
	hidden := put(other.ID, "private-map.jpg", "image/jpeg")
	disguised := put(e.me.ID, "fake-map.png", "application/pdf")
	foreignWorkspace, err := e.q.CreateWorkspace(ctx, store.CreateWorkspaceParams{Name: "Other", Slug: "other-images"})
	if err != nil {
		t.Fatal(err)
	}
	foreign, err := e.q.PutKnowledgeAsset(ctx, store.PutKnowledgeAssetParams{WorkspaceID: foreignWorkspace.ID, OwnerUserID: e.me.ID, ContentHash: "foreign", BlobKey: "foreign", Filename: "foreign-map.png", ContentType: "image/png", SizeBytes: 1})
	if err != nil {
		t.Fatal(err)
	}
	// Referenced assets follow the same visibility as downloading or embedding them.
	for _, item := range []struct {
		asset    store.KnowledgeAsset
		audience string
	}{{shared, "shared"}, {hidden, "private"}} {
		page := e.want("POST", "/knowledge/pages", map[string]any{"title": item.audience, "audience": item.audience}, 200)
		if _, err := e.pool.Exec(ctx, `INSERT INTO page_asset_refs(version_id,asset_id) VALUES ($1,$2)`, page["version_id"], item.asset.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := e.pool.Exec(ctx, `UPDATE artifacts SET owner_user_id=$2 WHERE id=$1`, page["id"], other.ID); err != nil {
			t.Fatal(err)
		}
	}
	out := e.want("GET", "/knowledge/assets?q=MAP", nil, 200)
	images := out["images"].([]any)
	if len(images) != 2 {
		t.Fatalf("image suggestions: %v", out)
	}
	raw := fmtJSON(out)
	for _, id := range []uuid.UUID{own.ID, shared.ID} {
		if !strings.Contains(raw, id.String()) {
			t.Fatalf("missing visible image %s: %s", id, raw)
		}
	}
	for _, id := range []uuid.UUID{hidden.ID, disguised.ID, foreign.ID} {
		if strings.Contains(raw, id.String()) {
			t.Fatalf("leaked private or non-image asset %s: %s", id, raw)
		}
	}
	if !strings.Contains(raw, wiki.AttachmentRef(own.ID, own.Filename)) {
		t.Fatalf("missing usable embed ref: %s", raw)
	}
	if got := e.want("GET", "/knowledge/assets?q=missing", nil, 200); len(got["images"].([]any)) != 0 {
		t.Fatalf("unrelated images: %v", got)
	}

	// The list is capped even when many images match.
	for i := 0; i < 15; i++ {
		put(e.me.ID, fmt.Sprintf("extra-map-%d.png", i), "image/png")
	}
	if got := e.want("GET", "/knowledge/assets", nil, 200); len(got["images"].([]any)) != 12 {
		t.Fatalf("uncapped suggestions: %v", got)
	}
}

func TestKnowledgeAttachmentsListAllTypesAndVisibility(t *testing.T) {
	e := newChatEnv(t)
	ctx := t.Context()
	other, err := e.q.CreateUser(ctx, store.CreateUserParams{WorkspaceID: e.me.WorkspaceID, Name: "Other", Email: "other-att@example.com"})
	if err != nil {
		t.Fatal(err)
	}
	put := func(owner uuid.UUID, name, mime string, size int64) store.KnowledgeAsset {
		t.Helper()
		asset, err := e.q.PutKnowledgeAsset(ctx, store.PutKnowledgeAssetParams{
			WorkspaceID: e.me.WorkspaceID,
			OwnerUserID: owner,
			ContentHash: uuid.NewString(),
			BlobKey:     uuid.NewString(),
			Filename:    name,
			ContentType: mime,
			SizeBytes:   size,
		})
		if err != nil {
			t.Fatal(err)
		}
		return asset
	}

	img := put(e.me.ID, "photo.png", "image/png", 1024)
	vid := put(e.me.ID, "demo.mp4", "video/mp4", 4096)
	aud := put(e.me.ID, "note.m4a", "audio/mp4", 2048)
	pdf := put(e.me.ID, "spec.pdf", "application/pdf", 8192)
	shared := put(other.ID, "shared.pdf", "application/pdf", 512)
	hidden := put(other.ID, "secret.mp4", "video/mp4", 512)

	for _, item := range []struct {
		asset    store.KnowledgeAsset
		audience string
	}{{shared, "shared"}, {hidden, "private"}} {
		page := e.want("POST", "/knowledge/pages", map[string]any{"title": item.audience, "audience": item.audience}, 200)
		if _, err := e.pool.Exec(ctx, `INSERT INTO page_asset_refs(version_id,asset_id) VALUES ($1,$2)`, page["version_id"], item.asset.ID); err != nil {
			t.Fatal(err)
		}
		if _, err := e.pool.Exec(ctx, `UPDATE artifacts SET owner_user_id=$2 WHERE id=$1`, page["id"], other.ID); err != nil {
			t.Fatal(err)
		}
	}

	out := e.want("GET", "/knowledge/attachments", nil, 200)
	if out["folder"] != "attachments" {
		t.Fatalf("folder = %v, want attachments", out["folder"])
	}
	items := out["attachments"].([]any)
	if len(items) != 5 {
		t.Fatalf("expected 5 visible attachments (img, vid, aud, pdf, shared), got %d: %v", len(items), out)
	}
	raw := fmtJSON(out)
	for _, id := range []uuid.UUID{img.ID, vid.ID, aud.ID, pdf.ID, shared.ID} {
		if !strings.Contains(raw, id.String()) {
			t.Fatalf("missing visible attachment %s: %s", id, raw)
		}
	}
	if strings.Contains(raw, hidden.ID.String()) {
		t.Fatalf("leaked private attachment %s: %s", hidden.ID, raw)
	}
	if !strings.Contains(raw, `"path":"attachments/demo.mp4"`) {
		t.Fatalf("missing attachments folder path: %s", raw)
	}

	// Filtering by query narrows by filename case-insensitively.
	filtered := e.want("GET", "/knowledge/attachments?q=DEMO", nil, 200)
	if len(filtered["attachments"].([]any)) != 1 {
		t.Fatalf("expected 1 filtered attachment, got %v", filtered)
	}
}

func TestKnowledgeAttachmentsUsageRenameAndDelete(t *testing.T) {
	d, srv := newKnowledgeAssetsEnv(t)
	e := d.chatEnv
	ctx := t.Context()

	other, err := e.q.CreateUser(ctx, store.CreateUserParams{WorkspaceID: e.me.WorkspaceID, Name: "Other", Email: "other-mgmt@example.com"})
	if err != nil {
		t.Fatal(err)
	}

	// Upload two owned attachments via the real blob-backed endpoint.
	img, err := srv.Wiki.StoreAssetBytes(ctx, e.me.WorkspaceID, e.me.ID, "shot.png", []byte("\x89PNG\r\n\x1a\nfake-png-data"))
	if err != nil {
		t.Fatal(err)
	}
	orphan, err := srv.Wiki.StoreAssetBytes(ctx, e.me.WorkspaceID, e.me.ID, "unused.pdf", []byte("%PDF-1.7\nbody"))
	if err != nil {
		t.Fatal(err)
	}
	// Shared attachment owned by another user.
	sharedAsset, err := srv.Wiki.StoreAssetBytes(ctx, e.me.WorkspaceID, other.ID, "shared-spec.pdf", []byte("%PDF-1.7\nshared"))
	if err != nil {
		t.Fatal(err)
	}
	sharedPage := e.want("POST", "/knowledge/pages", map[string]any{"title": "Shared Host", "audience": "shared"}, 200)
	if _, err := e.pool.Exec(ctx, `INSERT INTO page_asset_refs(version_id,asset_id) VALUES ($1,$2)`, sharedPage["version_id"], sharedAsset.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(ctx, `UPDATE artifacts SET owner_user_id=$2 WHERE id=$1`, sharedPage["id"], other.ID); err != nil {
		t.Fatal(err)
	}

	// Reference img in two pages: one via attachment:<id>/name|400, one via Obsidian filename ![[shot.png|300]].
	p1 := e.want("POST", "/knowledge/pages", map[string]any{
		"title":   "Doc One",
		"body_md": "![[" + wiki.AttachmentRef(img.ID, img.Filename) + "|400]]\n",
	}, 200)
	p2 := e.want("POST", "/knowledge/pages", map[string]any{
		"title":   "Doc Two",
		"body_md": "![[shot.png|300]]\n",
	}, 200)

	findAtt := func(id uuid.UUID) map[string]any {
		t.Helper()
		list := e.want("GET", "/knowledge/attachments", nil, 200)["attachments"].([]any)
		for _, item := range list {
			m := item.(map[string]any)
			if m["id"] == id.String() {
				return m
			}
		}
		return nil
	}

	imgMeta := findAtt(img.ID)
	if imgMeta == nil || int(imgMeta["usage_count"].(float64)) != 2 || imgMeta["is_owner"] != true {
		t.Fatalf("expected shot.png used in 2 docs and owned, got %v", imgMeta)
	}
	orphanMeta := findAtt(orphan.ID)
	if orphanMeta == nil || int(orphanMeta["usage_count"].(float64)) != 0 {
		t.Fatalf("expected unused.pdf orphaned (0 docs), got %v", orphanMeta)
	}
	sharedMeta := findAtt(sharedAsset.ID)
	if sharedMeta == nil || sharedMeta["is_owner"] != false || int(sharedMeta["usage_count"].(float64)) != 1 {
		t.Fatalf("expected shared-spec.pdf is_owner=false usage=1, got %v", sharedMeta)
	}

	// Updating Doc Two to remove the embed drops usage_count from 2 to 1 (old versions don't inflate count).
	e.want("PUT", "/knowledge/pages/"+p2["id"].(string), map[string]any{
		"body_md":         "No image anymore.",
		"base_version_id": p2["version_id"],
	}, 200)
	if got := int(findAtt(img.ID)["usage_count"].(float64)); got != 1 {
		t.Fatalf("usage_count after removal = %d, want 1", got)
	}

	// Rename owned attachment succeeds and updates path + title while keeping existing embed resolving.
	renamed := e.want("PATCH", "/knowledge/attachments/"+img.ID.String(), map[string]any{"filename": "architecture.png"}, 200)
	if renamed["filename"] != "architecture.png" || renamed["path"] != "attachments/architecture.png" {
		t.Fatalf("unexpected rename response: %v", renamed)
	}
	p1Fetched := e.want("GET", "/knowledge/pages/"+p1["id"].(string), nil, 200)
	embeds := p1Fetched["embeds"].([]any)
	if len(embeds) != 1 || embeds[0].(map[string]any)["title"] != "architecture.png" || embeds[0].(map[string]any)["available"] != true {
		t.Fatalf("existing embed did not reflect renamed filename: %v", embeds)
	}

	// Invalid rename returns 422; renaming another user's shared attachment returns 403.
	if code, _ := e.do("PATCH", "/knowledge/attachments/"+img.ID.String(), map[string]any{"filename": "bad/name.png"}); code != 422 {
		t.Fatalf("invalid filename rename = %d, want 422", code)
	}
	if code, _ := e.do("PATCH", "/knowledge/attachments/"+sharedAsset.ID.String(), map[string]any{"filename": "hijacked.pdf"}); code != 403 {
		t.Fatalf("non-owner rename = %d, want 403", code)
	}

	// Deleting another user's shared attachment returns 403.
	if code, _ := e.do("DELETE", "/knowledge/attachments/"+sharedAsset.ID.String(), nil); code != 403 {
		t.Fatalf("non-owner delete = %d, want 403", code)
	}

	// Deleting owned attachment succeeds, removes it from listing, and cleans up the blob.
	delRes := e.want("DELETE", "/knowledge/attachments/"+orphan.ID.String(), nil, 200)
	if delRes["deleted"] != orphan.ID.String() {
		t.Fatalf("unexpected delete response: %v", delRes)
	}
	if findAtt(orphan.ID) != nil {
		t.Fatalf("deleted attachment still listed")
	}
	if _, err := d.blobs.Get(ctx, avatarBucket, orphan.BlobKey); err == nil {
		t.Fatalf("expected blob %s to be deleted after removing unshared attachment", orphan.BlobKey)
	}
}

func TestKnowledgeHeadingsEndpointAndVisibility(t *testing.T) {
	e := newChatEnv(t)
	ctx := t.Context()

	other, err := e.q.CreateUser(ctx, store.CreateUserParams{WorkspaceID: e.me.WorkspaceID, Name: "Other", Email: "other-head@example.com"})
	if err != nil {
		t.Fatal(err)
	}

	own := e.want("POST", "/knowledge/pages", map[string]any{
		"title":   "Campaign Notes",
		"path":    "DnD/Campaign Notes",
		"body_md": "# Session One\n\nIntro ^b1\n\n## Tavern Ambush\n\nRoll initiative.\n",
	}, 200)
	hidden := e.want("POST", "/knowledge/pages", map[string]any{
		"title":    "Private Other",
		"audience": "private",
		"body_md":  "# Secret Heading\n",
	}, 200)
	if _, err := e.pool.Exec(ctx, `UPDATE artifacts SET owner_user_id=$2 WHERE id=$1`, hidden["id"], other.ID); err != nil {
		t.Fatal(err)
	}

	out := e.want("GET", "/knowledge/headings", nil, 200)
	headings := out["headings"].([]any)
	raw := fmtJSON(out)
	if !strings.Contains(raw, "Session One") || !strings.Contains(raw, "Tavern Ambush") {
		t.Fatalf("missing expected headings: %s", raw)
	}
	if strings.Contains(raw, "Secret Heading") {
		t.Fatalf("leaked private heading: %s", raw)
	}
	if strings.Contains(raw, "^b1") {
		t.Fatalf("block anchor should not appear in headings: %s", raw)
	}
	if len(headings) < 2 {
		t.Fatalf("expected at least 2 headings, got %d", len(headings))
	}

	filtered := e.want("GET", "/knowledge/headings?q=ambush", nil, 200)["headings"].([]any)
	if len(filtered) != 1 || filtered[0].(map[string]any)["page_id"] != own["id"] {
		t.Fatalf("filtered headings = %v, want Tavern Ambush on %v", filtered, own["id"])
	}
}
