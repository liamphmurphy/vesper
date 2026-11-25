package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/pageview"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// reviewPins decodes a version's stored review_pins. It never returns nil, so
// the API always sends an array.
func reviewPins(raw []byte) []api.MockupPin {
	var pins []artifacts.ReviewPin
	_ = json.Unmarshal(raw, &pins) // the column defaults to '[]'; bad JSON reads as no pins
	out := make([]api.MockupPin, 0, len(pins))
	for _, p := range pins {
		out = append(out, api.MockupPin{X: p.X, Y: p.Y, Text: p.Text})
	}
	return out
}

// mockupGate is the ticket's mockup gate for the API.
func (s *Server) mockupGate(ctx context.Context, t store.Ticket) (api.MockupGate, error) {
	g, err := artifacts.MockupGate(ctx, s.Q, t)
	if err != nil {
		return api.MockupGate{}, err
	}
	out := api.MockupGate{Required: g.Required, FromEpic: g.FromEpic, Approved: g.Approved, Mockups: make([]api.MockupRef, 0, len(g.Mockups))}
	for _, m := range g.Mockups {
		out.Mockups = append(out.Mockups, api.MockupRef{
			Id: m.ID, Title: m.Title, VersionId: m.VersionID, VersionLabel: m.VersionLabel,
			ReviewState: api.MockupReviewState(m.ReviewState), ReviewNote: m.ReviewNote,
		})
	}
	return out, nil
}

func (s *Server) ReviewArtifactVersion(ctx context.Context, req api.ReviewArtifactVersionRequestObject) (api.ReviewArtifactVersionResponseObject, error) {
	u, _, ws := me(ctx)
	var pins []artifacts.ReviewPin
	if req.Body.Pins != nil {
		for _, p := range *req.Body.Pins {
			pins = append(pins, artifacts.ReviewPin{X: p.X, Y: p.Y, Text: p.Text})
		}
	}
	var snap *artifacts.ReviewSnapshot
	if b := req.Body.Snapshot; b != nil {
		var err error
		if snap, err = artifacts.DecodeReviewSnapshot(b.PngBase64, b.Renderer, b.SourceSha256); err != nil {
			return nil, err
		}
	}
	a, err := s.Runs.ReviewMockup(ctx, ws, u.ID, req.Id, req.VersionId, string(req.Body.Decision), deref(req.Body.Note), pins, snap)
	if err != nil {
		return nil, err
	}
	d, err := s.artifactDetail(ctx, ws, a)
	return api.ReviewArtifactVersion200JSONResponse(d), err
}

func (s *Server) UpdateEpic(ctx context.Context, req api.UpdateEpicRequestObject) (api.UpdateEpicResponseObject, error) {
	_, _, ws := me(ctx)
	var status *string
	if req.Body.Status != nil {
		v := string(*req.Body.Status)
		status = &v
	}
	e, err := s.Tracker.UpdateEpic(ctx, ws, req.Id, status, req.Body.RequiresMockup)
	if err != nil {
		return nil, err
	}
	if req.Body.RequiresMockup != nil && !*req.Body.RequiresMockup {
		if err := s.Runs.ReleaseMockupWaiters(ctx, ws, nil, &e.ID, ""); err != nil {
			return nil, err
		}
	}
	rollups, err := s.epicRollups(ctx, []store.Epic{e})
	if err != nil {
		return nil, err
	}
	return api.UpdateEpic200JSONResponse(toEpic(e, rollups[e.ID])), nil
}

func (s *Server) CreateEpicReview(ctx context.Context, req api.CreateEpicReviewRequestObject) (api.CreateEpicReviewResponseObject, error) {
	_, _, ws := me(ctx)
	t, err := s.Tracker.EnsureEpicReview(ctx, ws, req.Id)
	if err != nil {
		return nil, err
	}
	return api.CreateEpicReview200JSONResponse(toWorkTicket(t)), nil
}

func toWorkTicket(t store.Ticket) api.WorkTicket {
	return api.WorkTicket{Id: t.ID, Key: t.Key, Title: t.Title, Status: api.TicketStatus(t.Status), Priority: api.Priority(t.Priority)}
}

func (r contentResponse) VisitGetArtifactReviewSnapshotResponse(w http.ResponseWriter) error {
	return r.write(w)
}

// GetArtifactReviewSnapshot serves the PNG a reviewer saw, scoped like the
// version's content.
func (s *Server) GetArtifactReviewSnapshot(ctx context.Context, req api.GetArtifactReviewSnapshotRequestObject) (api.GetArtifactReviewSnapshotResponseObject, error) {
	_, _, ws := me(ctx)
	v, err := s.Q.GetArtifactVersion(ctx, store.GetArtifactVersionParams{ID: req.VersionId, ArtifactID: req.Id, WorkspaceID: ws, Viewer: pageview.From(ctx).UserID})
	if errors.Is(err, pgx.ErrNoRows) || err == nil && v.ReviewSnapshotKey == nil {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	o, err := s.Blobs.Get(ctx, s.ArtifactBucket, *v.ReviewSnapshotKey)
	if errors.Is(err, blob.ErrNotFound) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return contentResponse{body: o.Body, closer: o.Body, contentType: "image/png", length: o.ContentLength,
		filename: "review-" + v.Label + ".png", inline: true, cache: "private, max-age=300"}, nil
}
