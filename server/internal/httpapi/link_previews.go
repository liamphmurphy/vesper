package httpapi

import (
	"bytes"
	"context"
	"crypto/sha256"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/linkpreview"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// linkPreviews fetches recommended pages; tests point it at a fake.
var linkPreviews interface {
	Fetch(ctx context.Context, url string) linkpreview.Preview
} = linkpreview.New()

// A fetch that found nothing may have been a blip, so it's retried after this.
const linkPreviewRetry = 24 * time.Hour

func linkPreviewKey(ws uuid.UUID, url string) string {
	return fmt.Sprintf("link-previews/%s/%x", ws, sha256.Sum256([]byte(url)))
}

// ListLinkPreviews returns the cards for the recommend fences in one of the
// caller's replies. Only URLs in the stored reply are fetched, so this can't be
// used to make the server request an arbitrary address.
func (s *Server) ListLinkPreviews(ctx context.Context, req api.ListLinkPreviewsRequestObject) (api.ListLinkPreviewsResponseObject, error) {
	u, _, ws := me(ctx)
	m, err := s.Q.GetChatMessage(ctx, req.MessageId)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	if _, err := s.ownChat(ctx, m.SessionID); err != nil {
		return nil, err
	}
	out := api.LinkPreviews{Previews: []api.LinkPreview{}}
	if m.Role != "assistant" {
		return api.ListLinkPreviews200JSONResponse(out), nil
	}
	recs := linkpreview.Previewable(m.BodyMd)
	rows := make([]store.LinkPreview, len(recs))
	errs := make([]error, len(recs))
	urls := make([]string, len(recs))
	var wg sync.WaitGroup
	for i, r := range recs {
		urls[i] = r.URL
		wg.Go(func() { rows[i], errs[i] = s.linkPreview(ctx, ws, r.URL) })
	}
	wg.Wait()
	if err := errors.Join(errs...); err != nil {
		return nil, err
	}
	saved, err := s.Q.SavedLibraryLinks(ctx, store.SavedLibraryLinksParams{WorkspaceID: ws, UserID: u.ID, Urls: urls})
	if err != nil {
		return nil, err
	}
	for _, r := range rows {
		p := toLinkPreview(r)
		p.Saved = slices.Contains(saved, r.Url)
		out.Previews = append(out.Previews, p)
	}
	return api.ListLinkPreviews200JSONResponse(out), nil
}

// linkPreview returns the stored preview, fetching it the first time.
func (s *Server) linkPreview(ctx context.Context, ws uuid.UUID, url string) (store.LinkPreview, error) {
	row, err := s.Q.GetLinkPreview(ctx, store.GetLinkPreviewParams{WorkspaceID: ws, Url: url})
	if err == nil && (row.Title != "" || row.BlobKey != "" || time.Since(row.FetchedAt) < linkPreviewRetry) {
		return row, nil
	}
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return row, err
	}
	p := linkPreviews.Fetch(ctx, url)
	var key string
	if p.Image != nil {
		key = linkPreviewKey(ws, url)
		if err := s.Blobs.Put(ctx, s.ArtifactBucket, key, bytes.NewReader(p.Image), int64(len(p.Image)), p.ImageType); err != nil {
			return row, err
		}
	}
	return s.Q.UpsertLinkPreview(ctx, store.UpsertLinkPreviewParams{WorkspaceID: ws, Url: url, Kind: p.Kind, Title: p.Title, Description: p.Description,
		Site: p.Site, VideoID: p.VideoID, BlobKey: key, ImageType: p.ImageType})
}

func toLinkPreview(r store.LinkPreview) api.LinkPreview {
	out := api.LinkPreview{Url: r.Url, Kind: api.LinkPreviewKind(r.Kind), Title: r.Title, Description: r.Description, Site: r.Site}
	if r.VideoID != "" {
		out.VideoId = &r.VideoID
	}
	if r.BlobKey != "" {
		src := fmt.Sprintf("/api/v1/link-previews/%s/image", r.ID)
		out.ImageUrl = &src
	}
	return out
}

// GetLinkPreviewImage serves a stored preview image, so the browser never
// contacts the recommended site just by showing the card.
func (s *Server) GetLinkPreviewImage(ctx context.Context, req api.GetLinkPreviewImageRequestObject) (api.GetLinkPreviewImageResponseObject, error) {
	_, _, ws := me(ctx)
	r, err := s.Q.GetLinkPreviewByID(ctx, store.GetLinkPreviewByIDParams{ID: req.Id, WorkspaceID: ws})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && r.BlobKey == "") {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	o, err := s.Blobs.Get(ctx, s.ArtifactBucket, r.BlobKey)
	if errors.Is(err, blob.ErrNotFound) {
		return nil, apperr.ErrNotFound
	} else if err != nil {
		return nil, err
	}
	return avatarResponse{body: o.Body, contentType: r.ImageType, length: o.ContentLength}, nil
}

// VisitGetLinkPreviewImageResponse serves a preview image with the avatar headers.
func (r avatarResponse) VisitGetLinkPreviewImageResponse(w http.ResponseWriter) error {
	return r.write(w)
}
