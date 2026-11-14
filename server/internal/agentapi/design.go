package agentapi

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/modelcontextprotocol/go-sdk/mcp"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/canvas"
	"github.com/liamphmurphy/vesper/server/internal/design"
	"github.com/liamphmurphy/vesper/server/internal/designs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// The design_* tools (ADR-designs §3.9). All of them take the canvas_id of a
// design canvas in this chat, and refuse anything else.

// imageResult is a tool result with a PNG: over MCP it's image content plus
// the meta as text; over REST, the meta with the PNG as base64.
type imageResult struct {
	PNG  []byte
	Meta any
}

func (r *imageResult) MarshalJSON() ([]byte, error) {
	raw, err := json.Marshal(r.Meta)
	if err != nil {
		return nil, err
	}
	m := map[string]any{}
	_ = json.Unmarshal(raw, &m)
	m["image_png_base64"] = r.PNG
	return json.Marshal(m)
}

func (r *imageResult) mcpResult() (*mcp.CallToolResult, error) {
	meta, err := json.Marshal(r.Meta)
	if err != nil {
		return nil, err
	}
	return &mcp.CallToolResult{Content: []mcp.Content{&mcp.ImageContent{Data: r.PNG, MIMEType: "image/png"}, &mcp.TextContent{Text: string(meta)}}}, nil
}

// designTarget checks that the canvas is a design in this chat and returns it
// with its current version. During a turn the version's body is the working
// copy: the version with the turn's draft applied, so the persona builds on
// its own unpublished changes (designs/drafts.go).
func designTarget(ctx context.Context, d Deps, c agents.Caller, tool string, id uuid.UUID) (*chatScope, store.ChatCanvas, store.ChatCanvasVersion, error) {
	var v store.ChatCanvasVersion
	s, err := canvasScope(ctx, d, c, tool)
	if err != nil {
		return nil, store.ChatCanvas{}, v, err
	}
	cv, err := getCanvas(ctx, d, s, id)
	if err != nil {
		return nil, cv, v, err
	}
	if cv.Kind != canvas.KindDesign {
		return nil, cv, v, apperr.Invalid("canvas_id", "this %s canvas isn't a design; %s only works on designs", cv.Kind, tool)
	}
	if v, err = d.Q.LatestChatCanvasVersion(ctx, cv.ID); err != nil {
		return nil, cv, v, err
	}
	turn, err := chatTurn(ctx, d, c)
	if err != nil {
		return nil, cv, v, err
	}
	v.Body, err = designs.Working(ctx, d.Q, cv.ID, turn, v.Body)
	return s, cv, v, err
}

// chatTurn is the caller's running chat turn, or nil outside one.
func chatTurn(ctx context.Context, d Deps, c agents.Caller) (*uuid.UUID, error) {
	if c.RunID == nil {
		return nil, nil
	}
	t, err := d.Q.RunningChatTurn(ctx, *c.RunID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	} else if err != nil {
		return nil, err
	}
	return &t.ID, nil
}

func requireDesigns(d Deps) error {
	if d.Designs == nil {
		return apperr.Conflict("designs aren't available on this server")
	}
	return nil
}

type DesignListIn struct {
	Project string `json:"project,omitempty" jsonschema:"Only designs in the project with this key"`
}

func designList(ctx context.Context, d Deps, c agents.Caller, in DesignListIn) (any, error) {
	s, err := canvasScope(ctx, d, c, "design_list")
	if err != nil {
		return nil, err
	}
	rows, err := d.Q.ListChatCanvases(ctx, s.ChatID)
	if err != nil {
		return nil, err
	}
	var ids []uuid.UUID
	for _, r := range rows {
		if r.Kind == canvas.KindDesign {
			ids = append(ids, r.ID)
		}
	}
	pending := map[uuid.UUID]int{}
	if len(ids) > 0 {
		counts, err := d.Q.CountDesignProposalsByCanvas(ctx, ids)
		if err != nil {
			return nil, err
		}
		for _, p := range counts {
			pending[p.CanvasID] = int(p.Pending)
		}
	}
	out := []map[string]any{}
	for _, r := range rows {
		if r.Kind != canvas.KindDesign {
			continue
		}
		set, err := d.Q.GetDesignSettings(ctx, r.ID)
		if err != nil {
			return nil, err
		}
		if in.Project != "" {
			p, err := d.Q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: c.Agent.WorkspaceID, Key: in.Project})
			if err != nil || set.ProjectID == nil || *set.ProjectID != p.ID {
				continue
			}
		}
		v, err := d.Q.LatestChatCanvasVersion(ctx, r.ID)
		if err != nil {
			return nil, err
		}
		pages, frames := design.Summary(v.Body)
		out = append(out, map[string]any{"canvas_id": r.ID, "title": r.Title, "pages": pages, "frames": frames, "version": v.Seq, "updated_at": r.UpdatedAt.Format(time.RFC3339), "pending_proposals": pending[r.ID]})
	}
	return map[string]any{"designs": out}, nil
}

type DesignOutlineIn struct {
	CanvasID uuid.UUID `json:"canvas_id"`
	Page     string    `json:"page,omitempty" jsonschema:"Only this page (p_…); every page when omitted"`
	Depth    int       `json:"depth,omitempty" jsonschema:"How many levels of nodes to list below the page; 3 when omitted. Deeper nodes show as child_count"`
}

func designOutline(ctx context.Context, d Deps, c agents.Caller, in DesignOutlineIn) (any, error) {
	_, cv, v, err := designTarget(ctx, d, c, "design_outline", in.CanvasID)
	if err != nil {
		return nil, err
	}
	if err := requireDesigns(d); err != nil {
		return nil, err
	}
	if in.Depth < 0 || in.Depth > 32 {
		return nil, apperr.Invalid("depth", "use 1 to 32")
	}
	boxes, boxErr := d.Designs.Boxes(ctx, v.Body, in.Page)
	pages, err := design.Outline(v.Body, in.Page, in.Depth, boxes)
	if err != nil {
		return nil, err
	}
	out := map[string]any{"canvas_id": cv.ID, "title": cv.Title, "version": v.Seq, "boxes": "computed by the renderer, in page coordinates", "pages": pages}
	if boxErr != nil {
		out["boxes"] = "stored: the renderer is unavailable, so these are the saved x, y, w and h (parents' offsets added) and may be stale for auto-layout children"
	}
	return out, nil
}

type DesignReadIn struct {
	CanvasID uuid.UUID `json:"canvas_id"`
	NodeIDs  []string  `json:"node_ids,omitempty" jsonschema:"The nodes (n_…) to read in full, with their children; at most 50. Give this or page"`
	Page     string    `json:"page,omitempty" jsonschema:"Read a page's top-level nodes in full instead. Give this or node_ids"`
}

func designRead(ctx context.Context, d Deps, c agents.Caller, in DesignReadIn) (any, error) {
	_, cv, v, err := designTarget(ctx, d, c, "design_read", in.CanvasID)
	if err != nil {
		return nil, err
	}
	r, err := design.ReadNodes(v.Body, in.NodeIDs, in.Page)
	if err != nil {
		return nil, err
	}
	return map[string]any{"canvas_id": cv.ID, "version": v.Seq, "mode": r.Mode, "nodes": r.Nodes, "links": r.Links, "truncated": r.Truncated}, nil
}

type DesignRenderIn struct {
	CanvasID uuid.UUID `json:"canvas_id"`
	NodeID   string    `json:"node_id,omitempty" jsonschema:"Render this node (n_…)"`
	Page     string    `json:"page,omitempty" jsonschema:"Render this whole page (p_…). With neither node_id nor page, the first page"`
	Scale    float64   `json:"scale,omitempty" jsonschema:"1 to 3; 1 when omitted"`
}

func designRender(ctx context.Context, d Deps, c agents.Caller, in DesignRenderIn) (any, error) {
	_, cv, v, err := designTarget(ctx, d, c, "design_render", in.CanvasID)
	if err != nil {
		return nil, err
	}
	if err := requireDesigns(d); err != nil {
		return nil, err
	}
	if in.NodeID != "" && in.Page != "" {
		return nil, apperr.Invalid("page", "give node_id or page, not both")
	}
	if in.Scale != 0 && (in.Scale < 1 || in.Scale > 3) {
		return nil, apperr.Invalid("scale", "use 1 to 3")
	}
	if in.NodeID != "" && !design.HasNode(v.Body, in.NodeID) {
		return nil, apperr.Invalid("node_id", "no node %s in this design", in.NodeID)
	}
	if in.Page != "" && !design.HasPage(v.Body, in.Page) {
		return nil, apperr.Invalid("page", "no page %s in this design", in.Page)
	}
	r, err := d.Designs.Render(ctx, cv.ID, v.Body, in.NodeID, in.Page, in.Scale)
	var rejected *designs.RejectedError
	switch {
	case errors.As(err, &rejected):
		return map[string]any{"render": "unavailable", "message": "render unavailable: " + rejected.Message}, nil
	case errors.Is(err, designs.ErrUnavailable):
		return map[string]any{"render": "unavailable", "message": "render unavailable: the design renderer isn't reachable right now; carry on from design_read"}, nil
	case err != nil:
		return nil, err
	}
	return &imageResult{PNG: r.PNG, Meta: map[string]any{"w": r.W, "h": r.H, "version": v.Seq}}, nil
}

const patchOpsHelp = `Each op is {op, ...fields, why}. Ids you leave out are minted for you. Ops: add_page {page:{name}, after?}; set_page {id, name?, background?}; remove_page {id}; add_node {parent (page or container id), after? or before? (a sibling id), node: a node or subtree}; set_node {id, fields: {...}} (a merge patch; not paragraphs or children); move_node {id, parent?, after? or before?, x?, y?}; remove_node {id} (also removes its connectors and links); set_text {id, text | paragraphs}; connect {from, to, label?, route?, stroke?, end_arrow?}; add_sticky {page, x, y, text, color?}; add_link {from, to, trigger?, transition?}; set_link {id, ...}; remove_link {id}; create_component {id, name?}; instantiate {component, parent, x, y, overrides?}; set_overrides {id, overrides}; detach {id}; set_token {set, name, mode, value}; link_ticket / unlink_ticket {node, ticket}. Colours are "$token" or "#RRGGBB". why says in a few words what the change is for, and is what the person reads when they review it`

type DesignPatchIn struct {
	CanvasID    uuid.UUID   `json:"canvas_id"`
	BaseVersion int32       `json:"base_version" jsonschema:"The design version these ops are based on (from design_read or design_list). Refused if the design has moved on"`
	Summary     string      `json:"summary" jsonschema:"What this patch does, in a few words; the person sees it as the suggestion's title"`
	Ops         []design.Op `json:"ops" jsonschema:"1 to 100 ops, applied in order; all succeed or none do. See the tool description for the ops"`
}

func proposeOut(cv uuid.UUID, p designs.Proposed, n int) map[string]any {
	if p.Proposal.Status == designs.StatusDraft {
		return map[string]any{"canvas_id": cv, "ops": n, "nodes": p.Nodes, "drafted": true,
			"next": "Drafted. Keep going until the design is finished: design_read, design_outline and design_render show your draft, and the person sees only the result, once your reply ends. Then tell them in a sentence what you made."}
	}
	if p.Version != nil {
		return map[string]any{"canvas_id": cv, "proposal_id": p.Proposal.ID, "version": p.Version.Seq, "applied": true, "ops": n, "nodes": p.Nodes}
	}
	return map[string]any{"canvas_id": cv, "proposal_id": p.Proposal.ID, "ops": n, "nodes": p.Nodes, "pending_review": true,
		"next": "The design is unchanged until the person reviews these. Tell them what you suggested in a sentence, then wait for their review."}
}

func propose(ctx context.Context, d Deps, c agents.Caller, s *chatScope, id uuid.UUID, base int32, summary string, ops []design.Op) (any, error) {
	if err := requireDesigns(d); err != nil {
		return nil, err
	}
	turn, err := chatTurn(ctx, d, c)
	if err != nil {
		return nil, err
	}
	p, err := d.Designs.Propose(ctx, designs.Patch{CanvasID: id, ChatID: s.ChatID, RunID: c.RunID, TurnID: turn, AgentID: c.Agent.ID, Base: base, Summary: summary, Ops: ops})
	if err != nil {
		return nil, err
	}
	return proposeOut(id, p, len(ops)), nil
}

func designPatch(ctx context.Context, d Deps, c agents.Caller, in DesignPatchIn) (any, error) {
	s, _, _, err := designTarget(ctx, d, c, "design_patch", in.CanvasID)
	if err != nil {
		return nil, err
	}
	return propose(ctx, d, c, s, in.CanvasID, in.BaseVersion, in.Summary, in.Ops)
}

// designCanvasPatch is canvas_patch on a design: the same suggestion route as
// design_patch, so the generic tool can't skip the person's review.
func designCanvasPatch(ctx context.Context, d Deps, c agents.Caller, s *chatScope, in CanvasPatchIn) (any, error) {
	if len(in.Ops) == 0 {
		return nil, apperr.Invalid("ops", "provide 1 to 100 ops")
	}
	return propose(ctx, d, c, s, in.CanvasID, in.BaseVersion, in.Note, canvas.DesignOps(in.Ops))
}

type DesignCommentsIn struct {
	CanvasID uuid.UUID `json:"canvas_id"`
	OpenOnly bool      `json:"open_only,omitempty" jsonschema:"Only threads still waiting on you (status open)"`
}

func designComments(ctx context.Context, d Deps, c agents.Caller, in DesignCommentsIn) (any, error) {
	_, cv, v, err := designTarget(ctx, d, c, "design_comments", in.CanvasID)
	if err != nil {
		return nil, err
	}
	rows, err := d.Q.ListChatCanvasComments(ctx, cv.ID)
	if err != nil {
		return nil, err
	}
	replies := map[uuid.UUID][]map[string]any{}
	for _, r := range rows {
		if r.ParentID != nil && r.Status != "draft" {
			replies[*r.ParentID] = append(replies[*r.ParentID], map[string]any{"reply_id": r.ID, "from": r.AuthorType, "body": r.Body})
		}
	}
	threads := []map[string]any{}
	for _, r := range rows {
		if r.ParentID != nil || r.Status == "draft" || (in.OpenOnly && r.Status != "open") {
			continue
		}
		var a canvas.Anchor
		if err := json.Unmarshal(r.Anchor, &a); err != nil {
			return nil, err
		}
		t := map[string]any{"comment_id": r.ID, "from": r.AuthorType, "body": r.Body, "status": r.Status, "node": a.Node, "node_name": a.Label, "target_lost": r.TargetLost, "replies": append([]map[string]any{}, replies[r.ID]...)}
		if a.Point != nil {
			t["x"], t["y"] = a.Point.X, a.Point.Y
		}
		threads = append(threads, t)
	}
	return map[string]any{"canvas_id": cv.ID, "version": v.Seq, "threads": threads}, nil
}

type DesignCommentIn struct {
	CanvasID uuid.UUID `json:"canvas_id"`
	NodeID   string    `json:"node_id" jsonschema:"The node (n_…) the comment is about"`
	Body     string    `json:"body" jsonschema:"Your comment"`
	X        *float64  `json:"x,omitempty" jsonschema:"Where in the node's box, as a fraction 0 to 1 across; give with y"`
	Y        *float64  `json:"y,omitempty" jsonschema:"Where in the node's box, as a fraction 0 to 1 down; give with x"`
}

func designComment(ctx context.Context, d Deps, c agents.Caller, in DesignCommentIn) (any, error) {
	s, _, _, err := designTarget(ctx, d, c, "design_comment", in.CanvasID)
	if err != nil {
		return nil, err
	}
	if (in.X == nil) != (in.Y == nil) {
		return nil, apperr.Invalid("x", "give both x and y, or neither")
	}
	ac := canvas.AgentComment{Node: in.NodeID, Body: in.Body}
	if in.X != nil {
		ac.Point = &canvas.Point{X: *in.X, Y: *in.Y}
	}
	svc := canvas.Service{Pool: d.Runs.Pool}
	r, err := svc.AddAgentComment(ctx, s.ChatID, in.CanvasID, ac, canvas.Actor{Type: "agent", ID: c.Agent.ID})
	if err != nil {
		return nil, err
	}
	return map[string]any{"comment_id": r.ID, "node": in.NodeID}, nil
}

type DesignReplyIn struct {
	CanvasID  uuid.UUID `json:"canvas_id"`
	CommentID uuid.UUID `json:"comment_id"`
	Body      string    `json:"body" jsonschema:"Your reply"`
	Addressed bool      `json:"addressed,omitempty" jsonschema:"You have made the change this comment asked for (or answered it)"`
}

func designReply(ctx context.Context, d Deps, c agents.Caller, in DesignReplyIn) (any, error) {
	s, _, _, err := designTarget(ctx, d, c, "design_reply", in.CanvasID)
	if err != nil {
		return nil, err
	}
	svc := canvas.Service{Pool: d.Runs.Pool}
	r, err := svc.Reply(ctx, s.ChatID, in.CanvasID, in.CommentID, in.Body, in.Addressed, canvas.Actor{Type: "agent", ID: c.Agent.ID})
	if err != nil {
		return nil, err
	}
	return map[string]any{"reply_id": r.ID, "addressed": in.Addressed}, nil
}

type DesignCreateIn struct {
	Title   string `json:"title" jsonschema:"What the design is, e.g. Onboarding flow (at most 200 characters)"`
	Project string `json:"project,omitempty" jsonschema:"Key of the project the design belongs to; the chat's project when omitted"`
	Starter string `json:"starter,omitempty" jsonschema:"blank (default), mobile-flow, web-flow, diagram or wireframe"`
}

// designCreate is design_create (ADR-designs §3.9): a new design in this
// chat, which the person sees open beside the conversation.
func designCreate(ctx context.Context, d Deps, c agents.Caller, in DesignCreateIn) (any, error) {
	s, err := canvasScope(ctx, d, c, "design_create")
	if err != nil {
		return nil, err
	}
	chat, err := d.Q.GetChatSession(ctx, store.GetChatSessionParams{ID: s.ChatID, WorkspaceID: c.Agent.WorkspaceID})
	if err != nil {
		return nil, err
	}
	turn, err := chatTurn(ctx, d, c)
	if err != nil {
		return nil, err
	}
	svc := designs.Service{Pool: d.Runs.Pool}
	cv, v, err := svc.CreateInChat(ctx, c.Agent.WorkspaceID, chat, in.Title, in.Starter, in.Project, canvas.Actor{Type: "agent", ID: c.Agent.ID}, c.RunID, turn)
	if err != nil {
		return nil, err
	}
	return map[string]any{"canvas_id": cv.ID, "title": cv.Title, "version": v.Seq, "url": "/apps/designs/" + cv.ID.String()}, nil
}

type DesignImportIn struct {
	CanvasID    uuid.UUID `json:"canvas_id"`
	BaseVersion int32     `json:"base_version,omitempty" jsonschema:"The design version you last read; refused if the design has moved on. The current version when omitted"`
	Page        string    `json:"page" jsonschema:"The page (p_…) to import into"`
	X           *float64  `json:"x,omitempty" jsonschema:"Where the import's top-left goes on the page; with y. Right of the page's content when omitted"`
	Y           *float64  `json:"y,omitempty" jsonschema:"With x"`
	Mermaid     string    `json:"mermaid,omitempty" jsonschema:"A Mermaid flowchart (flowchart or graph TD/LR/…): it becomes a section of shapes and routed connectors, laid out automatically"`
	SVG         string    `json:"svg,omitempty" jsonschema:"SVG markup: its rects, circles, ellipses, lines, polylines, polygons, paths and text become a group of design nodes"`
	Why         string    `json:"why,omitempty" jsonschema:"What the import is for, in a few words; the person reads it when they review"`
}

// designImport is design_import (ADR-designs §3.9): the worker turns the text
// into one node, which goes through the same route as design_patch (one
// add_node op), so it's a suggestion unless direct edit is on. Text the
// worker can't import is refused with the problem named, and nothing changes.
func designImport(ctx context.Context, d Deps, c agents.Caller, in DesignImportIn) (any, error) {
	s, cv, v, err := designTarget(ctx, d, c, "design_import", in.CanvasID)
	if err != nil {
		return nil, err
	}
	if err := requireDesigns(d); err != nil {
		return nil, err
	}
	field, kind := "mermaid", "Mermaid flowchart"
	req := designs.ImportRequest{Body: v.Body, Page: in.Page, X: in.X, Y: in.Y}
	switch {
	case in.Mermaid != "" && in.SVG != "":
		return nil, apperr.Invalid("mermaid", "give mermaid or svg, not both")
	case in.Mermaid != "":
		req.Mermaid = &in.Mermaid
	case in.SVG != "":
		req.SVG = &in.SVG
		field, kind = "svg", "SVG"
	default:
		return nil, apperr.Invalid("mermaid", "give the mermaid or svg text to import")
	}
	if (in.X == nil) != (in.Y == nil) {
		return nil, apperr.Invalid("x", "give both x and y, or neither")
	}
	if in.Page == "" || !design.HasPage(v.Body, in.Page) {
		return nil, apperr.Invalid("page", "no page %q in this design; design_outline lists the pages", in.Page)
	}
	base := in.BaseVersion
	if base == 0 {
		base = v.Seq
	} else if base != v.Seq {
		return nil, apperr.Conflict("this design is at version %d, not %d; read it again and redo the import", v.Seq, base)
	}
	imp, err := d.Designs.Import(ctx, req)
	var rejected *designs.RejectedError
	switch {
	case errors.As(err, &rejected):
		return nil, apperr.Invalid(field, "%s", rejected.Message)
	case errors.Is(err, designs.ErrUnavailable):
		return nil, apperr.Conflict("the design worker isn't reachable right now, so nothing was imported; try again shortly")
	case err != nil:
		return nil, err
	}
	why := in.Why
	if why == "" {
		why = "Import a " + kind
	}
	name, _ := imp.Node["name"].(string)
	summary := "Import " + kind
	if name != "" && name != "Imported flowchart" && name != "Imported SVG" {
		summary += ": " + name
	}
	op := design.Op{"op": "add_node", "parent": in.Page, "node": imp.Node, "why": why}
	out, err := propose(ctx, d, c, s, cv.ID, base, summary, []design.Op{op})
	if err != nil {
		return nil, err
	}
	m := out.(map[string]any)
	m["node_id"] = imp.Node["id"]
	m["warnings"] = append([]string{}, imp.Warnings...)
	return m, nil
}
