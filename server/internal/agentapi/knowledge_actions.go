package agentapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

// The rest of what the person does in the Knowledge app, for a persona in
// their chat. Each tool acts for the chat's person and only on what they can
// see. Changes that can't wait as a suggestion (delete, file a capture) follow
// the page's persona controls the way move_page does; review decisions and
// page controls only ever go the cautious way (withdraw your own suggestion,
// pause or require review), so a persona can't approve or unlock its own work.

type DeletePageIn struct {
	Ref string `json:"ref" jsonschema:"The page to delete: its id, title, path or [[link]]"`
}

func deletePageTool(ctx context.Context, d Deps, c agents.Caller, in DeletePageIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "delete_page")
	if err != nil {
		return nil, err
	}
	a, _, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	gone, err := d.Wiki.DeletePageAsPersona(ctx, c.Agent.WorkspaceID, scope.UserID, a.ID)
	if err != nil {
		return nil, err
	}
	return map[string]any{"deleted": gone.ID, "path": gone.Path, "note": "Deleted with its history. Links to it are unresolved again and reattach if a page by that name is made."}, nil
}

type DeleteFolderIn struct {
	Folder string `json:"folder" jsonschema:"The folder to delete with every page under it, e.g. Archive/Old sessions"`
}

func deleteFolderTool(ctx context.Context, d Deps, c agents.Caller, in DeleteFolderIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "delete_folder")
	if err != nil {
		return nil, err
	}
	deleted, err := d.Wiki.DeleteFolderAsPersona(ctx, c.Agent.WorkspaceID, scope.UserID, in.Folder)
	if err != nil {
		return nil, err
	}
	return map[string]any{"deleted": len(deleted), "page_ids": deleted}, nil
}

type PageVersionsIn struct {
	Ref   string `json:"ref" jsonschema:"The page: its id, title, path or [[link]]"`
	Limit int    `json:"limit,omitempty" jsonschema:"Newest versions to list, 1 to 100; 20 when omitted"`
}

func listPageVersions(ctx context.Context, d Deps, c agents.Caller, in PageVersionsIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "list_page_versions")
	if err != nil {
		return nil, err
	}
	a, v, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	rows, err := d.Q.ListArtifactVersions(ctx, store.ListArtifactVersionsParams{ArtifactID: a.ID, Viewer: &scope.UserID})
	if err != nil {
		return nil, err
	}
	limit := in.Limit
	if limit <= 0 || limit > 100 {
		limit = 20
	}
	type version struct {
		ID        uuid.UUID `json:"version_id"`
		Seq       int32     `json:"seq"`
		Label     string    `json:"label"`
		Note      string    `json:"note,omitempty"`
		By        string    `json:"by"`
		CreatedAt string    `json:"created_at"`
		Current   bool      `json:"current,omitempty"`
	}
	out := []version{}
	for _, r := range rows[:min(len(rows), limit)] {
		out = append(out, version{ID: r.ID, Seq: r.Seq, Label: r.Label, Note: r.Note, By: r.CreatedByType, CreatedAt: r.CreatedAt.Format("2006-01-02 15:04"), Current: r.ID == v.ID})
	}
	return map[string]any{"page_id": a.ID, "current_version": v.ID, "versions": out, "more": len(rows) > limit}, nil
}

type RestoreVersionIn struct {
	Ref         string    `json:"ref" jsonschema:"The page: its id, title, path or [[link]]"`
	VersionID   uuid.UUID `json:"version_id" jsonschema:"The earlier version to bring back, from list_page_versions"`
	BaseVersion uuid.UUID `json:"base_version" jsonschema:"The page's current version, so a restore never overwrites an edit you haven't seen"`
}

// restorePageVersion writes an earlier version's text and properties as the
// persona's new version, so the page's controls decide as for any edit.
func restorePageVersion(ctx context.Context, d Deps, c agents.Caller, in RestoreVersionIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "restore_page_version")
	if err != nil {
		return nil, err
	}
	a, v, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	if in.BaseVersion != v.ID {
		return nil, apperr.Conflict("this page changed; read it again before restoring")
	}
	old, err := d.Q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: in.VersionID, ArtifactID: a.ID, WorkspaceID: c.Agent.WorkspaceID, Viewer: &scope.UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.Invalid("version_id", "no version %s on this page", in.VersionID)
	}
	if err != nil {
		return nil, err
	}
	if old.BodyMd == nil {
		return nil, apperr.Invalid("version_id", "not a text version")
	}
	if old.State != artifacts.Published {
		return nil, apperr.Invalid("version_id", "only a published version can be restored, not a suggestion")
	}
	scopes, _, err := scopesFor(ctx, d, c, "")
	if err != nil {
		return nil, err
	}
	result, err := d.Wiki.AgentWrite(ctx, c.Agent, scopes, wiki.Save{Path: *a.Path, Body: *old.BodyMd, Properties: artifacts.DecodeProperties(old.Properties), BaseID: &in.BaseVersion, Note: "Restored " + old.Label})
	if err != nil {
		return nil, err
	}
	return pageWriteSummary(result), nil
}

type FileCaptureIn struct {
	Ref    string `json:"ref" jsonschema:"The inbox capture to file: its id, title, path or [[link]]"`
	Folder string `json:"folder,omitempty" jsonschema:"Move it into this folder, keeping its name"`
	Merge  string `json:"merge,omitempty" jsonschema:"Or append it to the end of this page and delete the capture: the page's id, title, path or [[link]]"`
}

func fileCapture(ctx context.Context, d Deps, c agents.Caller, in FileCaptureIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "file_capture")
	if err != nil {
		return nil, err
	}
	if (in.Folder == "") == (in.Merge == "") {
		return nil, apperr.Invalid("folder", "give either folder or merge")
	}
	a, _, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	var merge *uuid.UUID
	if in.Merge != "" {
		target, _, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Merge)
		if err != nil {
			return nil, err
		}
		merge = &target.ID
	}
	res, err := d.Wiki.FileCaptureAsPersona(ctx, c.Agent.WorkspaceID, scope.UserID, c.Agent, a.ID, in.Folder, merge)
	if err != nil {
		return nil, err
	}
	return map[string]any{"id": res.Note.ID, "path": res.Note.Path, "merged": merge != nil, "url": wiki.PageURL(res.Note.ID, res.Note.Title)}, nil
}

type AttachFileIn struct {
	AttachmentID  *uuid.UUID `json:"attachment_id,omitempty" jsonschema:"A file the person sent in this chat (its id from the message)"`
	LibraryItemID *uuid.UUID `json:"library_item_id,omitempty" jsonschema:"Or a file in the person's Library (such as a PDF made with render_pdf or saved with save_file)"`
	Data          string     `json:"data,omitempty" jsonschema:"Or the file's bytes, base64-encoded: something you made, such as an SVG; at most 25 MB"`
	Filename      string     `json:"filename,omitempty" jsonschema:"The file's name, e.g. harbour-map.svg; required with data"`
}

// attachFile stores a file among the person's Knowledge assets and returns the
// embed to place in a page with patch_page, as the editor's upload does.
func attachFile(ctx context.Context, d Deps, c agents.Caller, in AttachFileIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "attach_file")
	if err != nil {
		return nil, err
	}
	sources := 0
	if in.AttachmentID != nil {
		sources++
	}
	if in.LibraryItemID != nil {
		sources++
	}
	if in.Data != "" {
		sources++
	}
	if sources != 1 {
		return nil, apperr.Invalid("attachment_id", "give exactly one of attachment_id, library_item_id or data")
	}
	var asset store.KnowledgeAsset
	switch {
	case in.AttachmentID != nil:
		asset, err = d.Wiki.StoreAttachmentAsset(ctx, c.Agent.WorkspaceID, scope.UserID, *in.AttachmentID)
	case in.LibraryItemID != nil:
		asset, err = d.Wiki.StoreLibraryItemAsset(ctx, c.Agent.WorkspaceID, scope.UserID, *in.LibraryItemID)
	default:
		if strings.TrimSpace(in.Filename) == "" {
			return nil, apperr.Invalid("filename", "is required with data")
		}
		if base64.StdEncoding.DecodedLen(len(in.Data)) > wiki.PersonaAssetLimit+3 {
			return nil, apperr.Invalid("data", "is over the %d MB limit", wiki.PersonaAssetLimit>>20)
		}
		raw, decodeErr := base64.StdEncoding.DecodeString(strings.TrimSpace(in.Data))
		if decodeErr != nil {
			return nil, apperr.Invalid("data", "isn't valid base64: %v", decodeErr)
		}
		asset, err = d.Wiki.StoreAssetBytes(ctx, c.Agent.WorkspaceID, scope.UserID, in.Filename, raw)
	}
	if err != nil {
		return nil, err
	}
	ref := wiki.AttachmentRef(asset.ID, asset.Filename)
	return map[string]any{"asset_id": asset.ID, "content_type": asset.ContentType, "embed": "![[" + ref + "]]", "hint": "Place embed in the page with patch_page; it isn't on any page yet."}, nil
}

type PageRefIn struct {
	Ref string `json:"ref" jsonschema:"The page: its id, title, path or [[link]]"`
}

func listPageReviews(ctx context.Context, d Deps, c agents.Caller, in PageRefIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "list_page_reviews")
	if err != nil {
		return nil, err
	}
	a, _, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	rows, err := d.Q.ListPageReviews(ctx, store.ListPageReviewsParams{ID: a.ID, WorkspaceID: c.Agent.WorkspaceID, Viewer: &scope.UserID})
	if err != nil {
		return nil, err
	}
	type review struct {
		VersionID uuid.UUID       `json:"version_id"`
		State     string          `json:"state"`
		Note      string          `json:"note,omitempty"`
		Yours     bool            `json:"yours"`
		Changes   json.RawMessage `json:"changes"`
	}
	out := []review{}
	for _, r := range rows {
		out = append(out, review{VersionID: r.ID, State: r.State, Note: r.Note, Yours: ownVersion(c, r), Changes: json.RawMessage(r.Changes)})
	}
	return map[string]any{"page_id": a.ID, "reviews": out, "hint": "Only the person accepts or rejects changes; you may withdraw your own with withdraw_suggestion."}, nil
}

// ownVersion is whether a version is this persona's work: the chat's agent made it.
func ownVersion(c agents.Caller, v store.ArtifactVersion) bool {
	return v.CreatedByType == "agent" && v.CreatedByID == c.Agent.ID
}

type WithdrawIn struct {
	Ref       string    `json:"ref" jsonschema:"The page: its id, title, path or [[link]]"`
	VersionID uuid.UUID `json:"version_id" jsonschema:"Your pending suggestion or direct edit, from list_page_reviews"`
	Changes   []int     `json:"changes,omitempty" jsonschema:"Indexes of the pending changes to withdraw; every pending one when omitted"`
	Reason    string    `json:"reason,omitempty" jsonschema:"Why, in a few words"`
}

// withdrawSuggestion rejects the persona's own pending changes: a suggestion
// is dropped, a direct edit is undone. Accepting is never a persona's call.
func withdrawSuggestion(ctx context.Context, d Deps, c agents.Caller, in WithdrawIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "withdraw_suggestion")
	if err != nil {
		return nil, err
	}
	a, _, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	v, err := d.Q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: in.VersionID, ArtifactID: a.ID, WorkspaceID: c.Agent.WorkspaceID, Viewer: &scope.UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.Invalid("version_id", "no version %s on this page", in.VersionID)
	}
	if err != nil {
		return nil, err
	}
	if !ownVersion(c, v) {
		return nil, apperr.Conflict("that change isn't yours; only the person decides on it")
	}
	indexes := in.Changes
	if len(indexes) == 0 {
		var changes []artifacts.PageChange
		if err := json.Unmarshal(v.Changes, &changes); err != nil {
			return nil, err
		}
		for i, ch := range changes {
			if ch.State == "pending" {
				indexes = append(indexes, i)
			}
		}
	}
	reason := strings.TrimSpace(in.Reason)
	if reason == "" {
		reason = "Withdrawn by the persona"
	}
	decisions := make([]wiki.ReviewDecision, len(indexes))
	for i, idx := range indexes {
		decisions[i] = wiki.ReviewDecision{Index: idx, Accept: false, Reason: reason}
	}
	if _, err := d.Wiki.ResolveChanges(ctx, c.Agent.WorkspaceID, scope.UserID, a.ID, v.ID, decisions); err != nil {
		return nil, err
	}
	return map[string]any{"page_id": a.ID, "withdrawn": len(decisions)}, nil
}

type PageControlsIn struct {
	Ref         string `json:"ref" jsonschema:"The page: its id, title, path or [[link]]"`
	Pause       bool   `json:"pause,omitempty" jsonschema:"Pause persona edits on the page"`
	ReviewFirst bool   `json:"review_first,omitempty" jsonschema:"Make persona changes wait for the person's review"`
}

// setPageControls only tightens a page's persona controls: a persona may
// pause itself or ask for review, never lift either; the person does that.
func setPageControls(ctx context.Context, d Deps, c agents.Caller, in PageControlsIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "set_page_controls")
	if err != nil {
		return nil, err
	}
	if !in.Pause && !in.ReviewFirst {
		return nil, apperr.Invalid("pause", "set pause or review_first; only the person can lift them, in the Knowledge app")
	}
	a, _, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	direct := a.PersonaDirect && !in.ReviewFirst
	paused := a.PersonaPaused || in.Pause
	updated, err := d.Q.SetPageControls(ctx, store.SetPageControlsParams{ID: a.ID, WorkspaceID: c.Agent.WorkspaceID, Viewer: &scope.UserID, Direct: direct, Paused: paused})
	if err != nil {
		return nil, err
	}
	return map[string]any{"page_id": updated.ID, "direct": updated.PersonaDirect, "paused": updated.PersonaPaused}, nil
}

func attachChatToPage(ctx context.Context, d Deps, c agents.Caller, in PageRefIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "attach_chat_to_page")
	if err != nil {
		return nil, err
	}
	a, _, err := wiki.OpenPage(ctx, d.Q, c.Agent.WorkspaceID, in.Ref)
	if err != nil {
		return nil, err
	}
	if err := d.Q.SetPageChat(ctx, store.SetPageChatParams{ID: a.ID, WorkspaceID: c.Agent.WorkspaceID, Viewer: &scope.UserID, ChatID: &scope.ChatID}); err != nil {
		return nil, err
	}
	return map[string]any{"page_id": a.ID, "chat_id": scope.ChatID, "note": "This chat now opens beside the page."}, nil
}

type PromoteCanvasIn struct {
	CanvasID uuid.UUID `json:"canvas_id" jsonschema:"A text canvas in this chat"`
	Folder   string    `json:"folder,omitempty" jsonschema:"The folder for the new page; the top level when omitted"`
}

// promoteCanvas is the canvas's "Save to Knowledge": the canvas becomes a
// private page with its history and comments, and the canvas is removed.
func promoteCanvas(ctx context.Context, d Deps, c agents.Caller, in PromoteCanvasIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "promote_canvas")
	if err != nil {
		return nil, err
	}
	res, err := d.Wiki.MoveCanvasToPage(ctx, c.Agent.WorkspaceID, scope.UserID, scope.ChatID, in.CanvasID, in.Folder)
	if err != nil {
		return nil, err
	}
	return map[string]any{"id": res.Note.ID, "path": res.Note.Path, "url": wiki.PageURL(res.Note.ID, res.Note.Title), "note": "The canvas is now this page; edit it with patch_page from here on."}, nil
}

type GraphIn struct {
	Folder string `json:"folder,omitempty" jsonschema:"Only pages under this folder"`
	Limit  int    `json:"limit,omitempty" jsonschema:"At most this many pages, 1 to 500; 200 when omitted"`
}

// knowledgeGraph is the graph view as data: pages and the links between them.
func knowledgeGraph(ctx context.Context, d Deps, c agents.Caller, in GraphIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "knowledge_graph")
	if err != nil {
		return nil, err
	}
	params := store.KnowledgeNetworkNodesParams{WorkspaceID: c.Agent.WorkspaceID, Viewer: &scope.UserID}
	nodes, err := d.Q.KnowledgeNetworkNodes(ctx, params)
	if err != nil {
		return nil, err
	}
	links, err := d.Q.KnowledgeNetworkLinks(ctx, store.KnowledgeNetworkLinksParams(params))
	if err != nil {
		return nil, err
	}
	limit := in.Limit
	if limit <= 0 || limit > 500 {
		limit = 200
	}
	folder := strings.Trim(strings.TrimSpace(in.Folder), "/")
	type node struct {
		ID    uuid.UUID `json:"id"`
		Title string    `json:"title"`
		Path  string    `json:"path"`
	}
	type edge struct {
		From       uuid.UUID  `json:"from"`
		To         *uuid.UUID `json:"to,omitempty"`
		Unresolved string     `json:"unresolved,omitempty"`
	}
	kept := map[uuid.UUID]bool{}
	outNodes, outLinks := []node{}, []edge{}
	truncated := false
	for _, n := range nodes {
		p := ""
		if n.Path != nil {
			p = *n.Path
		}
		if folder != "" && !strings.HasPrefix(p+"/", folder+"/") {
			continue
		}
		if len(outNodes) == limit {
			truncated = true
			break
		}
		kept[n.ID] = true
		outNodes = append(outNodes, node{ID: n.ID, Title: n.Title, Path: p})
	}
	for _, l := range links {
		if !kept[l.SourceID] {
			continue
		}
		switch {
		case l.TargetKind == "unresolved":
			outLinks = append(outLinks, edge{From: l.SourceID, Unresolved: l.TargetText})
		case l.TargetID != nil && *l.TargetID != l.SourceID && kept[*l.TargetID]:
			outLinks = append(outLinks, edge{From: l.SourceID, To: l.TargetID})
		}
	}
	return map[string]any{"pages": outNodes, "links": outLinks, "truncated": truncated}, nil
}

type ImportIn struct {
	ImportID uuid.UUID `json:"import_id" jsonschema:"The vault import, from import_vault or list_imports"`
	Policy   string    `json:"policy,omitempty" jsonschema:"confirm_import only: what to do with pages that already exist: skip, replace or keep_both"`
}

func knowledgeImportSummary(job store.KnowledgeImport) map[string]any {
	return map[string]any{"import_id": job.ID, "state": job.State, "folder": job.Folder, "policy": job.Policy, "files_done": job.FilesDone, "error": job.Error, "plan": json.RawMessage(job.Plan), "report": json.RawMessage(job.Report)}
}

func listImports(ctx context.Context, d Deps, c agents.Caller, _ struct{}) (any, error) {
	scope, err := personChatScope(ctx, d, c, "list_imports")
	if err != nil {
		return nil, err
	}
	jobs, err := d.Q.ListKnowledgeImports(ctx, store.ListKnowledgeImportsParams{WorkspaceID: c.Agent.WorkspaceID, UserID: scope.UserID})
	if err != nil {
		return nil, err
	}
	out := []map[string]any{}
	for _, j := range jobs {
		out = append(out, knowledgeImportSummary(j))
	}
	return map[string]any{"imports": out}, nil
}

func confirmImport(ctx context.Context, d Deps, c agents.Caller, in ImportIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "confirm_import")
	if err != nil {
		return nil, err
	}
	if in.Policy != "skip" && in.Policy != "replace" && in.Policy != "keep_both" {
		return nil, apperr.Invalid("policy", "choose skip, replace or keep_both")
	}
	job, err := d.Q.ConfirmKnowledgeImport(ctx, store.ConfirmKnowledgeImportParams{ID: in.ImportID, WorkspaceID: c.Agent.WorkspaceID, UserID: scope.UserID, Policy: in.Policy})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, importStateError(ctx, d, c, scope, in.ImportID, "only a dry run waiting for confirmation can be confirmed")
	}
	if err != nil {
		return nil, err
	}
	return knowledgeImportSummary(job), nil
}

func cancelImport(ctx context.Context, d Deps, c agents.Caller, in ImportIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "cancel_import")
	if err != nil {
		return nil, err
	}
	job, err := d.Q.CancelKnowledgeImport(ctx, store.CancelKnowledgeImportParams{ID: in.ImportID, WorkspaceID: c.Agent.WorkspaceID, UserID: scope.UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, importStateError(ctx, d, c, scope, in.ImportID, "only an import that hasn't been confirmed can be canceled; undo a finished one")
	}
	if err != nil {
		return nil, err
	}
	return knowledgeImportSummary(job), nil
}

func undoImport(ctx context.Context, d Deps, c agents.Caller, in ImportIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "undo_import")
	if err != nil {
		return nil, err
	}
	if err := d.Wiki.UndoVault(ctx, c.Agent.WorkspaceID, scope.UserID, in.ImportID); err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, importStateError(ctx, d, c, scope, in.ImportID, "only a finished import can be undone")
		}
		return nil, err
	}
	job, err := d.Q.GetKnowledgeImport(ctx, store.GetKnowledgeImportParams{ID: in.ImportID, WorkspaceID: c.Agent.WorkspaceID, UserID: scope.UserID})
	if err != nil {
		return nil, err
	}
	return knowledgeImportSummary(job), nil
}

// importStateError tells a missing import from one in the wrong state, as
// the Knowledge app's import endpoints do.
func importStateError(ctx context.Context, d Deps, c agents.Caller, scope *chatScope, id uuid.UUID, wrongState string) error {
	_, err := d.Q.GetKnowledgeImport(ctx, store.GetKnowledgeImportParams{ID: id, WorkspaceID: c.Agent.WorkspaceID, UserID: scope.UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return apperr.ErrNotFound
	}
	if err != nil {
		return err
	}
	return apperr.Conflict("%s", wrongState)
}
