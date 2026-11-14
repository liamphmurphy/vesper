package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/oapi-codegen/nullable"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/canvas"
	"github.com/liamphmurphy/vesper/server/internal/design"
	"github.com/liamphmurphy/vesper/server/internal/designs"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func (s *Server) designs() *designs.Service {
	return &designs.Service{Pool: s.Pool, Runs: s.Runs, Worker: s.DesignWorker, Blobs: s.Blobs, Bucket: s.ArtifactBucket}
}

// myDesign is one of the caller's canvases, and only if it's a design: 404
// for anyone else's and for other kinds.
func (s *Server) myDesign(ctx context.Context, id uuid.UUID) (store.GetMyCanvasRow, error) {
	u, _, ws := me(ctx)
	cv, err := s.Q.GetMyCanvas(ctx, store.GetMyCanvasParams{ID: id, WorkspaceID: ws, UserID: u.ID})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && cv.Kind != canvas.KindDesign) {
		return cv, apperr.ErrNotFound
	}
	return cv, err
}

func nullUUID(id *uuid.UUID) nullable.Nullable[uuid.UUID] {
	if id == nil {
		return nullable.NewNullNullable[uuid.UUID]()
	}
	return nullable.NewNullableWithValue(*id)
}

func designVersionOut(v store.ChatCanvasVersion) api.DesignVersion {
	return api.DesignVersion{Seq: v.Seq, Note: v.Note, AuthorType: api.DesignVersionAuthorType(v.AuthorType), CreatedAt: v.CreatedAt, Body: v.Body}
}

func designSettingsOut(st designs.Settings) api.DesignSettings {
	return api.DesignSettings{DirectEdit: st.DirectEdit, PersonaPaused: st.PersonaPaused, ProjectId: nullUUID(st.ProjectID)}
}

func designProposalOut(p store.DesignProposal) (api.DesignProposal, error) {
	out := api.DesignProposal{Id: p.ID, AgentId: p.AgentID, BaseSeq: p.BaseSeq, Summary: p.Summary, Status: api.DesignProposalStatus(p.Status),
		CreatedAt: p.CreatedAt, ChatId: nullUUID(p.ChatID), RunId: nullUUID(p.RunID), Decisions: []api.DesignDecision{}}
	if err := json.Unmarshal(p.Ops, &out.Ops); err != nil {
		return out, err
	}
	if err := json.Unmarshal(p.Decisions, &out.Decisions); err != nil {
		return out, err
	}
	deps := design.Deps(out.Ops)
	for i := range deps {
		if deps[i] == nil {
			deps[i] = []int{}
		}
	}
	out.Deps = &deps
	if p.ResultSeq != nil {
		out.ResultSeq = nullable.NewNullableWithValue(*p.ResultSeq)
	}
	if p.ResolvedAt != nil {
		out.ResolvedAt = nullable.NewNullableWithValue(*p.ResolvedAt)
	}
	return out, nil
}

func (s *Server) ListDesigns(ctx context.Context, req api.ListDesignsRequestObject) (api.ListDesignsResponseObject, error) {
	u, _, ws := me(ctx)
	var project *uuid.UUID
	if req.Params.Project != nil && *req.Params.Project != "" {
		p, err := s.Q.GetProjectByKey(ctx, store.GetProjectByKeyParams{WorkspaceID: ws, Key: *req.Params.Project})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.Invalid("project", "no such project")
		} else if err != nil {
			return nil, err
		}
		project = &p.ID
	}
	rows, err := s.Q.ListUserDesigns(ctx, store.ListUserDesignsParams{WorkspaceID: ws, UserID: u.ID, ProjectID: project})
	if err != nil {
		return nil, err
	}
	out := make([]api.DesignSummary, 0, len(rows))
	for _, r := range rows {
		pages, frames := design.Summary(r.Body)
		out = append(out, api.DesignSummary{Id: r.ID, Title: r.Title, ChatId: r.ChatID, UpdatedAt: r.UpdatedAt, ProjectId: nullUUID(r.ProjectID),
			Seq: r.Seq, Pages: pages, Frames: frames, PendingProposals: int(r.PendingProposals), PersonaEdited: r.PersonaEdited})
	}
	return api.ListDesigns200JSONResponse{Designs: out}, nil
}

func (s *Server) CreateDesign(ctx context.Context, req api.CreateDesignRequestObject) (api.CreateDesignResponseObject, error) {
	u, _, ws := me(ctx)
	var title, starter, project string
	if b := req.Body; b != nil {
		title, project = deref(b.Title), deref(b.Project)
		if b.Starter != nil {
			starter = string(*b.Starter)
		}
	}
	cv, chat, err := s.designs().Create(ctx, ws, u.ID, title, starter, project)
	if err != nil {
		return nil, err
	}
	return api.CreateDesign201JSONResponse(myCanvasOut(cv, chat)), nil
}

func (s *Server) GetDesign(ctx context.Context, req api.GetDesignRequestObject) (api.GetDesignResponseObject, error) {
	cv, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	// A persona turn that ended without publishing its draft hands it over now.
	if err := s.designs().PublishSettled(ctx, &cv.ID, nil); err != nil {
		return nil, err
	}
	cur, err := s.Q.LatestChatCanvasVersion(ctx, cv.ID)
	if err != nil {
		return nil, err
	}
	st, err := s.Q.GetDesignSettings(ctx, cv.ID)
	if err != nil {
		return nil, err
	}
	pending := designs.StatusPending
	ps, err := s.Q.ListDesignProposals(ctx, store.ListDesignProposalsParams{CanvasID: cv.ID, Status: &pending})
	if err != nil {
		return nil, err
	}
	return api.GetDesign200JSONResponse{Id: cv.ID, Kind: api.DesignKind(cv.Kind), Title: cv.Title, ChatId: cv.ChatID, ChatTitle: cv.ChatTitle,
		UpdatedAt: cv.UpdatedAt, ReviewedSeq: &cv.ReviewedSeq, Seq: cur.Seq, Settings: designSettingsOut(st), PendingProposals: len(ps)}, nil
}

func (s *Server) RenameDesign(ctx context.Context, req api.RenameDesignRequestObject) (api.RenameDesignResponseObject, error) {
	cv, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	if err := s.designs().Rename(ctx, cv, req.Body.Title); err != nil {
		return nil, err
	}
	if cv, err = s.myDesign(ctx, req.CanvasId); err != nil {
		return nil, err
	}
	return api.RenameDesign200JSONResponse{Id: cv.ID, Kind: api.MyCanvasKind(cv.Kind), Title: cv.Title, ChatId: cv.ChatID, ChatTitle: cv.ChatTitle, UpdatedAt: cv.UpdatedAt, ReviewedSeq: &cv.ReviewedSeq}, nil
}

func (s *Server) DeleteDesign(ctx context.Context, req api.DeleteDesignRequestObject) (api.DeleteDesignResponseObject, error) {
	cv, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	u, _, ws := me(ctx)
	if err := s.Runs.DeleteAppCanvas(ctx, ws, u.ID, cv.ChatID, cv.ID, designs.AppName); err != nil {
		return nil, err
	}
	return api.DeleteDesign204Response{}, nil
}

func (s *Server) DuplicateDesign(ctx context.Context, req api.DuplicateDesignRequestObject) (api.DuplicateDesignResponseObject, error) {
	src, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	u, _, ws := me(ctx)
	cv, chat, err := s.designs().Duplicate(ctx, ws, u.ID, src)
	if err != nil {
		return nil, err
	}
	return api.DuplicateDesign201JSONResponse(myCanvasOut(cv, chat)), nil
}

func (s *Server) SaveDesign(ctx context.Context, req api.SaveDesignRequestObject) (api.SaveDesignResponseObject, error) {
	cv, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	v, err := s.canvases().Save(ctx, cv.ChatID, cv.ID, req.Body.BaseSeq, req.Body.Body, deref(req.Body.Note), myActor(ctx))
	if err != nil {
		return nil, err
	}
	return api.SaveDesign201JSONResponse(designVersionOut(v)), nil
}

func (s *Server) GetDesignVersion(ctx context.Context, req api.GetDesignVersionRequestObject) (api.GetDesignVersionResponseObject, error) {
	cv, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	v, err := s.Q.GetChatCanvasVersion(ctx, store.GetChatCanvasVersionParams{CanvasID: cv.ID, Seq: req.Seq})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return api.GetDesignVersion200JSONResponse(designVersionOut(v)), nil
}

func (s *Server) UpdateDesignSettings(ctx context.Context, req api.UpdateDesignSettingsRequestObject) (api.UpdateDesignSettingsResponseObject, error) {
	cv, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	st, err := s.designs().UpdateSettings(ctx, cv.ID, req.Body.DirectEdit, req.Body.PersonaPaused)
	if err != nil {
		return nil, err
	}
	return api.UpdateDesignSettings200JSONResponse(designSettingsOut(st)), nil
}

func (s *Server) ListDesignProposals(ctx context.Context, req api.ListDesignProposalsRequestObject) (api.ListDesignProposalsResponseObject, error) {
	cv, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	if err := s.designs().PublishSettled(ctx, &cv.ID, nil); err != nil {
		return nil, err
	}
	var status *string
	if req.Params.Status != nil {
		st := string(*req.Params.Status)
		status = &st
	}
	rows, err := s.Q.ListDesignProposals(ctx, store.ListDesignProposalsParams{CanvasID: cv.ID, Status: status})
	if err != nil {
		return nil, err
	}
	out := make([]api.DesignProposal, 0, len(rows))
	for _, r := range rows {
		p, err := designProposalOut(r)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return api.ListDesignProposals200JSONResponse{Proposals: out}, nil
}

func (s *Server) ResolveDesignProposal(ctx context.Context, req api.ResolveDesignProposalRequestObject) (api.ResolveDesignProposalResponseObject, error) {
	cv, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	u, _, ws := me(ctx)
	ds := make([]designs.Decision, len(req.Body.Decisions))
	for i, d := range req.Body.Decisions {
		ds[i] = designs.Decision{I: d.I, State: string(d.State), Reason: deref(d.Reason)}
	}
	r, err := s.designs().Resolve(ctx, cv, ws, u.ID, req.ProposalId, ds)
	if err != nil {
		return nil, err
	}
	p, err := designProposalOut(r.Proposal)
	if err != nil {
		return nil, err
	}
	out := api.ResolveDesignProposal200JSONResponse{Proposal: p}
	if r.Version != nil {
		v := designVersionOut(*r.Version)
		out.Version = &v
	}
	return out, nil
}

func (s *Server) UploadDesignAsset(ctx context.Context, req api.UploadDesignAssetRequestObject) (api.UploadDesignAssetResponseObject, error) {
	cv, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	if s.Blobs == nil {
		return nil, errNoBlobs
	}
	if req.Body == nil {
		return nil, apperr.Invalid("file", "required")
	}
	part, err := req.Body.NextPart()
	if errors.Is(err, io.EOF) {
		return nil, apperr.Invalid("file", "required")
	} else if err != nil {
		return nil, apperr.Invalid("body", "malformed multipart form")
	}
	defer part.Close()
	if part.FormName() != "file" {
		return nil, apperr.Invalid("file", "send only the file field (got %q)", part.FormName())
	}
	u, _, ws := me(ctx)
	a, err := designs.ReadAsset(part, ws, u.ID)
	if err != nil {
		return nil, err
	}
	// The same image already stored for this person costs nothing more.
	have, err := s.Q.UserHasDesignBlob(ctx, store.UserHasDesignBlobParams{WorkspaceID: ws, UserID: u.ID, BlobKey: a.Key})
	if err != nil {
		return nil, err
	}
	if !have {
		generated, err := s.Q.ChatGeneratedImageBytes(ctx, store.ChatGeneratedImageBytesParams{WorkspaceID: ws, UserID: u.ID})
		if err != nil {
			return nil, err
		}
		decks, err := s.Q.DeckAssetBytes(ctx, store.DeckAssetBytesParams{WorkspaceID: ws, UserID: u.ID})
		if err != nil {
			return nil, err
		}
		designBytes, err := s.Q.DesignAssetBytes(ctx, store.DesignAssetBytesParams{WorkspaceID: ws, UserID: u.ID})
		if err != nil {
			return nil, err
		}
		// Best effort: parallel uploads can each pass this check (as with Library saves).
		if generated+decks+designBytes+int64(len(a.Bytes)) > runs.MaxGeneratedImageStorageBytes {
			return nil, apperr.Invalid("file", "your Library is full (1 GB): remove designs, decks or items you no longer need")
		}
	}
	// The row goes in before the blob is written, so the sweep sees this
	// reference and leaves the shared blob alone.
	row, err := s.designs().AddAsset(ctx, store.CreateDesignAssetParams{CanvasID: cv.ID, ID: design.NewID("a"), WorkspaceID: ws, UserID: u.ID,
		BlobKey: a.Key, Mime: a.Mime, Width: int32(a.Width), Height: int32(a.Height), SizeBytes: int64(len(a.Bytes))})
	if err != nil {
		return nil, err
	}
	if err := s.Blobs.Put(ctx, s.ArtifactBucket, a.Key, bytes.NewReader(a.Bytes), int64(len(a.Bytes)), a.Mime); err != nil {
		// Removing the row queues the key for the sweep.
		_ = s.Q.DeleteDesignAsset(context.WithoutCancel(ctx), store.DeleteDesignAssetParams{CanvasID: cv.ID, ID: row.ID})
		return nil, err
	}
	return api.UploadDesignAsset201JSONResponse{Id: row.ID, Mime: api.DeckAssetMime(row.Mime), W: int(row.Width), H: int(row.Height)}, nil
}

func (s *Server) GetDesignAsset(ctx context.Context, req api.GetDesignAssetRequestObject) (api.GetDesignAssetResponseObject, error) {
	cv, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	a, err := s.Q.GetDesignAsset(ctx, store.GetDesignAssetParams{CanvasID: cv.ID, ID: req.AssetId})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if s.Blobs == nil {
		return nil, errNoBlobs
	}
	obj, err := s.Blobs.Get(ctx, s.ArtifactBucket, a.BlobKey)
	if errors.Is(err, blob.ErrNotFound) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return avatarResponse{body: obj.Body, contentType: a.Mime, length: obj.ContentLength, cache: "private, max-age=31536000, immutable"}, nil
}

// RenderDesign draws a node or page of the design's current version as a PNG
// through the design worker. Worker trouble is a 503 with a message, never a
// broken image.
func (s *Server) RenderDesign(ctx context.Context, req api.RenderDesignRequestObject) (api.RenderDesignResponseObject, error) {
	cv, err := s.myDesign(ctx, req.CanvasId)
	if err != nil {
		return nil, err
	}
	node, page := deref(req.Params.Node), deref(req.Params.Page)
	if node != "" && page != "" {
		return nil, apperr.Invalid("page", "give node or page, not both")
	}
	scale := 1.0
	if req.Params.Scale != nil {
		if scale = float64(*req.Params.Scale); scale < 1 || scale > 3 {
			return nil, apperr.Invalid("scale", "use 1 to 3")
		}
	}
	cur, err := s.Q.LatestChatCanvasVersion(ctx, cv.ID)
	if err != nil {
		return nil, err
	}
	if node != "" && !design.HasNode(cur.Body, node) {
		return nil, apperr.Invalid("node", "no node %s in this design", node)
	}
	if page != "" && !design.HasPage(cur.Body, page) {
		return nil, apperr.Invalid("page", "no page %s in this design", page)
	}
	r, err := s.designs().Render(ctx, cv.ID, cur.Body, node, page, scale)
	var rejected *designs.RejectedError
	switch {
	case errors.As(err, &rejected):
		return api.RenderDesign422JSONResponse(api.Error{Code: api.Invalid, Message: rejected.Message}), nil
	case errors.Is(err, designs.ErrUnavailable):
		return api.RenderDesign503JSONResponse(api.Error{Code: api.Internal, Message: "The design renderer isn't available right now. Try again in a moment."}), nil
	case err != nil:
		return nil, err
	}
	nosniff := "nosniff"
	return api.RenderDesign200ImagepngResponse{Body: bytes.NewReader(r.PNG), ContentLength: int64(len(r.PNG)),
		Headers: api.RenderDesign200ResponseHeaders{XContentTypeOptions: &nosniff, XDesignWidth: &r.W, XDesignHeight: &r.H}}, nil
}
