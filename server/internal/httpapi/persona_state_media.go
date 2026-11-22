package httpapi

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/statemedia"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Persona state loops: photorealistic, transparent Animated WebP loops per
// character state (internal/statemedia), generated in the background and
// served like avatars.

func (s *Server) stateMediaRunner() *statemedia.Runner {
	s.stateMediaOnce.Do(func() {
		s.stateMediaRun = &statemedia.Runner{
			Pool:   s.Pool,
			Blobs:  s.Blobs,
			Bucket: s.ArtifactBucket,
			Resolve: func(ctx context.Context, ws uuid.UUID) (media.VideoGenerator, media.Descriptor, error) {
				return s.mediaService().ResolveVideo(ctx, ws, "")
			},
			Pack: s.StateMediaPack,
			Log:  s.Log,
		}
	})
	return s.stateMediaRun
}

func stateLoopURL(row store.PersonaStateMedia, kind string) *string {
	key := row.BlobKey
	if kind == "head" {
		key = row.HeadKey
	}
	if key == nil {
		return nil
	}
	// The key changes with every new loop, so it busts the cache exactly
	// when the bytes change.
	u := fmt.Sprintf("/api/v1/personas/%s/state-media/%s/%s?v=%s", row.PersonaID, row.State, kind, shortKeyTag(*key))
	return &u
}

// shortKeyTag is a short cache tag from a blob key (its trailing uuid).
func shortKeyTag(key string) string {
	if len(key) > 12 {
		return key[len(key)-12:]
	}
	return key
}

func toPersonaStateMedia(row store.PersonaStateMedia) api.PersonaStateMedia {
	out := api.PersonaStateMedia{
		State:     api.PersonaState(row.State),
		Status:    api.PersonaStateMediaStatus(row.Status),
		Percent:   int(row.Percent),
		LoopUrl:   stateLoopURL(row, "loop"),
		HeadUrl:   stateLoopURL(row, "head"),
		CanTweak:  row.InteractionID != nil && *row.InteractionID != "",
		Error:     row.Error,
		ErrorKind: row.ErrorKind,
		UpdatedAt: row.UpdatedAt,
	}
	if row.StageNote != "" {
		out.StageNote = &row.StageNote
	}
	for _, p := range []struct {
		dst **int
		v   *int32
	}{{&out.Width, row.Width}, {&out.Height, row.Height}, {&out.Frames, row.Frames}, {&out.DurationMs, row.DurationMs}} {
		if p.v != nil {
			n := int(*p.v)
			*p.dst = &n
		}
	}
	out.SizeBytes = row.SizeBytes
	for _, p := range []struct {
		dst **string
		v   string
	}{{&out.Backend, row.Backend}, {&out.ProviderId, row.ProviderID}, {&out.Model, row.Model}, {&out.Tweak, row.Tweak}} {
		if p.v != "" {
			v := p.v
			*p.dst = &v
		}
	}
	return out
}

func toPersonaStateMediaList(rows []store.PersonaStateMedia) api.PersonaStateMediaList {
	out := api.PersonaStateMediaList{States: make([]api.PersonaStateMedia, 0, len(rows))}
	for _, r := range rows {
		out.States = append(out.States, toPersonaStateMedia(r))
	}
	return out
}

// stateMediaSummary is what a Persona carries for playback; nil without rows.
func stateMediaSummary(rows []store.PersonaStateMedia) *api.PersonaStateMediaSummary {
	if len(rows) == 0 {
		return nil
	}
	out := &api.PersonaStateMediaSummary{Loops: map[string]string{}}
	var head *string
	for _, r := range rows {
		if r.Status == "queued" || r.Status == "running" {
			out.Generating = true
		}
		if u := stateLoopURL(r, "loop"); u != nil {
			out.Loops[r.State] = *u
		}
		if h := stateLoopURL(r, "head"); h != nil && (head == nil || r.State == string(statemedia.StateIdle)) {
			head = h
		}
	}
	out.HeadUrl = head
	return out
}

// listStateMedia reads a persona's rows, failing any attempt a restart cut off.
func (s *Server) listStateMedia(ctx context.Context, o personas.Owner, persona uuid.UUID) ([]store.PersonaStateMedia, error) {
	if _, err := s.personas().Get(ctx, o, persona); err != nil {
		return nil, err
	}
	rows, err := s.Q.ListPersonaStateMedia(ctx, store.ListPersonaStateMediaParams{PersonaID: persona, WorkspaceID: o.WorkspaceID, UserID: o.UserID})
	if err != nil {
		return nil, err
	}
	return s.stateMediaRunner().RecoverInterrupted(ctx, rows)
}

func (s *Server) ListPersonaStateMedia(ctx context.Context, req api.ListPersonaStateMediaRequestObject) (api.ListPersonaStateMediaResponseObject, error) {
	rows, err := s.listStateMedia(ctx, personaOwner(ctx), req.Id)
	if err != nil {
		return nil, err
	}
	return api.ListPersonaStateMedia200JSONResponse(toPersonaStateMediaList(rows)), nil
}

func (s *Server) GeneratePersonaStateMedia(ctx context.Context, req api.GeneratePersonaStateMediaRequestObject) (api.GeneratePersonaStateMediaResponseObject, error) {
	o := personaOwner(ctx)
	p, err := s.personas().Get(ctx, o, req.Id)
	if err != nil {
		return nil, err
	}
	in := statemedia.StartInput{Owner: o, PersonaID: req.Id}
	var source *uuid.UUID
	if b := req.Body; b != nil {
		if b.States != nil {
			for _, st := range *b.States {
				in.States = append(in.States, statemedia.State(st))
			}
		}
		in.Tweak = deref(b.Tweak)
		source = b.SourceLibraryItemId
	}
	portrait, err := s.statePortrait(ctx, o, p, source)
	if err != nil {
		return nil, err
	}
	in.Source = statemedia.Source{Data: portrait}
	if _, err := s.stateMediaRunner().Start(ctx, in); err != nil {
		return nil, err
	}
	rows, err := s.listStateMedia(ctx, o, req.Id)
	if err != nil {
		return nil, err
	}
	return api.GeneratePersonaStateMedia202JSONResponse(toPersonaStateMediaList(rows)), nil
}

// statePortrait is the image every loop starts and ends on: the Library
// image asked for, else the persona's reference likeness, else its avatar.
func (s *Server) statePortrait(ctx context.Context, o personas.Owner, p store.Persona, source *uuid.UUID) ([]byte, error) {
	if s.Blobs == nil {
		return nil, errNoBlobs
	}
	key := ""
	switch {
	case source != nil:
		item, err := s.Q.GetLibraryItem(ctx, store.GetLibraryItemParams{ID: *source, WorkspaceID: o.WorkspaceID, UserID: o.UserID})
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, apperr.Invalid("source_library_item_id", "no such Library item")
		} else if err != nil {
			return nil, err
		}
		if item.Kind != "image" {
			return nil, apperr.Invalid("source_library_item_id", "pick an image")
		}
		key = item.BlobKey
	default:
		refs, err := s.Q.LibraryReferences(ctx, store.LibraryReferencesParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, PersonaID: &p.ID})
		if err != nil {
			return nil, err
		}
		for _, r := range refs {
			if r.Reference != nil && *r.Reference == "persona" && r.Kind == "image" {
				key = r.BlobKey
			}
		}
		if key == "" && p.AvatarKey != nil {
			key = *p.AvatarKey
		}
	}
	if key == "" {
		return nil, apperr.Conflict("The persona has no portrait to animate. Give it a picture or a reference image first.")
	}
	obj, err := s.Blobs.Get(ctx, s.ArtifactBucket, key)
	if errors.Is(err, blob.ErrNotFound) {
		return nil, apperr.Conflict("The persona's portrait is missing from storage. Set its picture again.")
	} else if err != nil {
		return nil, err
	}
	defer obj.Body.Close()
	b, err := io.ReadAll(io.LimitReader(obj.Body, personas.MaxAvatarSourceBytes+1))
	if err != nil {
		return nil, err
	}
	return b, nil
}

func (s *Server) ClearPersonaStateMedia(ctx context.Context, req api.ClearPersonaStateMediaRequestObject) (api.ClearPersonaStateMediaResponseObject, error) {
	o := personaOwner(ctx)
	var state *statemedia.State
	if req.Params.State != nil {
		st := statemedia.State(*req.Params.State)
		state = &st
	}
	if err := s.stateMediaRunner().Clear(ctx, o, req.Id, state); err != nil {
		return nil, err
	}
	rows, err := s.listStateMedia(ctx, o, req.Id)
	if err != nil {
		return nil, err
	}
	return api.ClearPersonaStateMedia200JSONResponse(toPersonaStateMediaList(rows)), nil
}

// stateMediaBlob opens a state's loop or head crop for serving.
func (s *Server) stateMediaBlob(ctx context.Context, persona uuid.UUID, state api.PersonaState, head bool) (avatarResponse, error) {
	o := personaOwner(ctx)
	if !statemedia.Valid(statemedia.State(state)) {
		return avatarResponse{}, apperr.ErrNotFound
	}
	row, err := s.Q.GetPersonaStateMedia(ctx, store.GetPersonaStateMediaParams{PersonaID: persona, State: string(state), WorkspaceID: o.WorkspaceID, UserID: o.UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return avatarResponse{}, apperr.ErrNotFound
	} else if err != nil {
		return avatarResponse{}, err
	}
	key, ct := row.BlobKey, "image/webp"
	if head {
		key, ct = row.HeadKey, "image/png"
	}
	if key == nil {
		return avatarResponse{}, apperr.ErrNotFound
	}
	if s.Blobs == nil {
		return avatarResponse{}, errNoBlobs
	}
	obj, err := s.Blobs.Get(ctx, s.ArtifactBucket, *key)
	if errors.Is(err, blob.ErrNotFound) {
		return avatarResponse{}, apperr.ErrNotFound // replaced since the row was read
	} else if err != nil {
		return avatarResponse{}, err
	}
	// Each loop has its own key and the URL carries it, so the bytes behind a
	// URL never change.
	return avatarResponse{body: obj.Body, contentType: ct, length: obj.ContentLength, cache: "private, max-age=604800, immutable"}, nil
}

func (s *Server) GetPersonaStateLoop(ctx context.Context, req api.GetPersonaStateLoopRequestObject) (api.GetPersonaStateLoopResponseObject, error) {
	return s.stateMediaBlob(ctx, req.Id, req.State, false)
}

func (s *Server) GetPersonaStateHead(ctx context.Context, req api.GetPersonaStateHeadRequestObject) (api.GetPersonaStateHeadResponseObject, error) {
	return s.stateMediaBlob(ctx, req.Id, req.State, true)
}

// VisitGetPersonaStateLoopResponse serves a loop with the avatar headers.
func (r avatarResponse) VisitGetPersonaStateLoopResponse(w http.ResponseWriter) error {
	return r.write(w)
}

// VisitGetPersonaStateHeadResponse serves a head crop with the avatar headers.
func (r avatarResponse) VisitGetPersonaStateHeadResponse(w http.ResponseWriter) error {
	return r.write(w)
}

// personasStateMedia groups the state loops of several personas by persona.
func (s *Server) personasStateMedia(ctx context.Context, ids []uuid.UUID) (map[uuid.UUID][]store.PersonaStateMedia, error) {
	rows, err := s.Q.ListPersonasStateMedia(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := map[uuid.UUID][]store.PersonaStateMedia{}
	for _, r := range rows {
		out[r.PersonaID] = append(out[r.PersonaID], r)
	}
	return out, nil
}

// stateMediaKeys reads a persona's loops before it is deleted, so their
// blobs can be removed once the cascade has dropped the rows.
func (s *Server) stateMediaKeys(ctx context.Context, persona uuid.UUID) []store.PersonaStateMedia {
	rows, err := s.Q.ListPersonasStateMedia(ctx, []uuid.UUID{persona})
	if err != nil {
		s.Log.Warn("read persona state loops before delete", "persona", persona, "err", err)
		return nil
	}
	return rows
}
