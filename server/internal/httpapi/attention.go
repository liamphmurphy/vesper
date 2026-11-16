package httpapi

import (
	"context"
	"errors"
	"maps"
	"regexp"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/links"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

func (s *Server) ListInbox(ctx context.Context, req api.ListInboxRequestObject) (api.ListInboxResponseObject, error) {
	u, _, ws := me(ctx)
	rows, err := s.Q.ListInbox(ctx, store.ListInboxParams{UserID: u.ID, WorkspaceID: ws, Project: req.Params.Project})
	if err != nil {
		return nil, err
	}
	out := api.ListInbox200JSONResponse{Items: make([]api.InboxItem, 0, len(rows))}
	for _, r := range rows {
		if r.Kind == "suggestion" {
			r.Href = links.NoteHref(strings.TrimPrefix(r.Href, "/wiki/"))
		}
		needsYou := inboxNeedsYou(r.Kind, r.Summary)
		if r.Kind == "mention" {
			r.Summary = clip(r.Summary, 240)
		}
		item := api.InboxItem{Id: r.ID, Kind: api.InboxItemKind(r.Kind), NeedsYou: needsYou, Title: r.Title, Summary: r.Summary, Href: r.Href, Project: r.Project, TicketKey: r.TicketKey, CreatedAt: r.CreatedAt, Resolved: r.Resolved, Read: r.Read, RunId: r.RunID, ArtifactId: r.ArtifactID}
		if r.AgentID != nil {
			item.Agent = &api.AgentRef{Id: *r.AgentID, Handle: r.AgentHandle, Name: r.AgentName, ColorIndex: int(r.AgentColorIndex)}
		}
		out.Items = append(out.Items, item)
	}
	return out, nil
}

// inboxNeedsYou sorts an inbox item into the tray's Needs you tab (true, and
// counted on the sidebar badge) or its Updates tab (false): news that asks the
// person nothing. A mention is news unless it asks a question, because a
// comment that asks "@you can you check X?" is a question like any await_human.
func inboxNeedsYou(kind, body string) bool {
	switch kind {
	case "scheduled", "merged", "pr_approved":
		return false
	case "mention":
		return asksQuestion(body)
	}
	return true
}

var (
	codeFence  = regexp.MustCompile("(?s)```.*?(```|$)")
	inlineCode = regexp.MustCompile("`[^`\n]*`")
	quoteLine  = regexp.MustCompile(`(?m)^\s*>.*$`)
	linkURL    = regexp.MustCompile(`https?://\S*[^\s?.,;:!)]`)
)

// asksQuestion: the text has a question mark outside code, links and quoted
// lines (a URL's query string, a code sample or a quoted earlier message
// doesn't ask anything).
func asksQuestion(md string) bool {
	md = codeFence.ReplaceAllString(md, "")
	md = quoteLine.ReplaceAllString(md, "")
	md = inlineCode.ReplaceAllString(md, "")
	md = linkURL.ReplaceAllString(md, "")
	return strings.Contains(md, "?")
}

// clip shortens s to at most n runes.
func clip(s string, n int) string {
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n])
}

func (s *Server) ReadInboxItem(ctx context.Context, req api.ReadInboxItemRequestObject) (api.ReadInboxItemResponseObject, error) {
	if req.Body == nil || len(req.Body.Id) == 0 || len(req.Body.Id) > 200 {
		return nil, &tracker.ValidationError{Field: "id", Msg: "invalid item id"}
	}
	u, _, _ := me(ctx)
	if err := s.Q.ReadInboxItem(ctx, store.ReadInboxItemParams{UserID: u.ID, ItemID: req.Body.Id}); err != nil {
		return nil, err
	}
	return api.ReadInboxItem204Response{}, nil
}
func (s *Server) Search(ctx context.Context, req api.SearchRequestObject) (api.SearchResponseObject, error) {
	ctx = pageview.IncludeAgents(ctx, deref(req.Params.IncludeAgent))
	u, _, ws := me(ctx)
	out := api.Search200JSONResponse{Hits: []api.SearchHit{}, Counts: map[string]int{}}
	text := strings.TrimSpace(req.Params.Q)
	if text == "" {
		return out, nil
	}
	if len(text) > 500 {
		return nil, &tracker.ValidationError{Field: "q", Msg: "query too long"}
	}
	var project *store.Project
	if req.Params.Project != nil && *req.Params.Project != "" {
		p, err := s.Q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: *req.Params.Project})
		if errors.Is(err, pgx.ErrNoRows) {
			return out, nil
		}
		if err != nil {
			return nil, err
		}
		project = &p
	}
	// Each type is capped so a common one can't push the rest out of the
	// palette; asking for one type lifts the cap so its chip can list them all.
	kind := ""
	if req.Params.Kind != nil {
		if !req.Params.Kind.Valid() {
			return nil, &tracker.ValidationError{Field: "kind", Msg: "unknown type"}
		}
		kind = string(*req.Params.Kind)
	}
	perKind := 8
	if kind != "" {
		perKind = 50
	}
	var projectID *uuid.UUID
	if project != nil {
		projectID = &project.ID
	}
	if kind == "" || kind == "ticket" || kind == "page" || kind == "artifact" {
		var groups []string
		if kind != "" {
			groups = []string{kind}
		}
		hits, counts, err := wiki.SearchPalette(ctx, s.Q, ws, text, groups, projectID, perKind)
		if err != nil {
			return nil, err
		}
		for _, h := range hits {
			out.Hits = append(out.Hits, api.SearchHit{Target: toTarget(h.Target), Snippet: h.Snippet, Score: float32(h.Score), Detail: nonEmpty(h.Detail), UpdatedAt: &h.UpdatedAt})
		}
		maps.Copy(out.Counts, counts)
	}
	// Chats matched by title, so a chat whose messages also match is counted once.
	titled := map[uuid.UUID]bool{}
	if kind != "ticket" && kind != "page" && kind != "artifact" {
		var only *string
		if kind != "" {
			only = &kind
		}
		targets, err := s.Q.SearchAttentionTargets(ctx, store.SearchAttentionTargetsParams{
			WorkspaceID: ws, UserID: u.ID, Q: text, Project: req.Params.Project, OnlyKind: only, PerKind: int32(perKind), Lim: int32(5 * perKind),
		})
		if err != nil {
			return nil, err
		}
		for _, t := range targets {
			id, href, at := t.ID, t.Href, t.At
			target := api.LinkTarget{Kind: api.LinkTargetKind(t.Kind), Id: &id, Title: t.Title, Href: &href}
			if t.Status != "" {
				status := t.Status
				target.Status = &status
			}
			out.Hits = append(out.Hits, api.SearchHit{Target: target, Snippet: "", Score: float32(t.Score), Detail: nonEmpty(t.Detail), UpdatedAt: &at})
			out.Counts[t.Kind] = int(t.Total)
			if t.Kind == "chat" {
				titled[t.ID] = true
			}
		}
	}
	// Message text is the costliest search, so it waits for a real word.
	if len(text) < 3 || (kind != "" && kind != "chat") {
		return out, nil
	}
	messages, err := s.Q.SearchChatMessages(ctx, store.SearchChatMessagesParams{Query: text, WorkspaceID: ws, UserID: u.ID, RowLimit: int32(perKind)})
	if err != nil {
		return nil, err
	}
	for _, m := range messages {
		if m.Archived || (project != nil && (m.ProjectKey == nil || *m.ProjectKey != project.Key)) {
			continue
		}
		// The chat is the target and the message its anchor, so the palette can
		// list a chat's matching messages under it.
		chatID, anchor, href, at := m.SessionID, m.ID.String(), "/chat/"+m.SessionID.String()+"?message="+m.ID.String(), m.CreatedAt
		snippet := strings.NewReplacer("\ue000", "«", "\ue001", "»").Replace(m.Snippet)
		author := "You"
		if m.Role != "user" {
			author = "Assistant"
			if m.PersonaName != nil {
				author = *m.PersonaName
			}
		}
		if !titled[chatID] {
			titled[chatID] = true
			out.Counts["chat"]++
		}
		// Below title matches: a word somewhere in a conversation is weak evidence.
		out.Hits = append(out.Hits, api.SearchHit{
			Target:  api.LinkTarget{Kind: api.LinkTargetKind("chat"), Id: &chatID, Anchor: &anchor, Title: m.ChatTitle, Href: &href},
			Snippet: snippet, Score: 0.05, Detail: &author, UpdatedAt: &at,
		})
	}
	return out, nil
}
