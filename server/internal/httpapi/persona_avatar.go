package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"slices"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Persona avatars (ADR Decision 4). They live in the blob bucket under
// personas/<workspace>/<user>/<persona>/<uuid>, outside chat_attachments, so
// the per-person upload cap and the unsent-attachment sweep never see them.
// A replaced or removed avatar's blob is deleted after the row commits.

var errNoBlobs = errors.New("blob storage is not configured")

// readAvatar reads the multipart body's single file part, at most
// MaxAvatarBytes. It stops reading as soon as the file is over the limit and
// refuses any other field, so it never reads an unbounded body.
func readAvatar(mr *multipart.Reader) ([]byte, error) {
	if mr == nil {
		return nil, apperr.Invalid("file", "required")
	}
	part, err := mr.NextPart()
	if errors.Is(err, io.EOF) {
		return nil, apperr.Invalid("file", "required")
	}
	if err != nil {
		return nil, apperr.Invalid("body", "malformed multipart form")
	}
	defer part.Close()
	if name := part.FormName(); name != "file" {
		return nil, apperr.Invalid("file", "send only the file field (got %q)", name)
	}
	b, err := io.ReadAll(io.LimitReader(part, personas.MaxAvatarBytes+1))
	if err != nil {
		return nil, apperr.Invalid("body", "malformed multipart form")
	}
	if len(b) > personas.MaxAvatarBytes {
		return nil, personas.AvatarTooLarge()
	}
	return b, nil
}

// avatarRefused renders a 413 or 415 from CheckAvatar or readAvatar; other
// errors go through the shared error mapping.
func avatarRefused(err error) (api.UploadPersonaAvatarResponseObject, error) {
	body, status, ok := avatarRefusal(err)
	if !ok {
		return nil, err
	}
	if status == http.StatusRequestEntityTooLarge {
		return api.UploadPersonaAvatar413JSONResponse(body), nil
	}
	return api.UploadPersonaAvatar415JSONResponse(body), nil
}

// avatarRefusal is the error body and status (413 or 415) for an upload
// refused by CheckAvatar or readAvatar; ok is false for any other error.
func avatarRefusal(err error) (body api.Error, status int, ok bool) {
	var ae *personas.AvatarError
	if !errors.As(err, &ae) {
		return body, 0, false
	}
	field := "file"
	return api.Error{Code: api.Invalid, Message: ae.Msg, Field: &field}, ae.Status, true
}

func (s *Server) deleteAvatarBlob(ctx context.Context, key *string) {
	if key == nil || s.Blobs == nil {
		return
	}
	// The row no longer points here; a leftover blob is unreachable, so a
	// failure only costs storage.
	if err := s.Blobs.Delete(context.WithoutCancel(ctx), s.ArtifactBucket, *key); err != nil {
		s.Log.Warn("delete persona avatar", "key", *key, "err", err)
	}
}

func (s *Server) UploadPersonaAvatar(ctx context.Context, req api.UploadPersonaAvatarRequestObject) (api.UploadPersonaAvatarResponseObject, error) {
	o := personaOwner(ctx)
	// 404 before reading the body for someone else's persona.
	if _, err := s.personas().Get(ctx, o, req.Id); err != nil {
		return nil, err
	}
	b, err := readAvatar(req.Body)
	if err != nil {
		return avatarRefused(err)
	}
	// The declared part Content-Type and filename are ignored: the type is sniffed.
	ct, err := personas.CheckAvatar(b)
	if err != nil {
		return avatarRefused(err)
	}
	if s.Blobs == nil {
		return nil, errNoBlobs
	}
	key := personas.AvatarKey(o, req.Id)
	if err := s.Blobs.Put(ctx, s.ArtifactBucket, key, bytes.NewReader(b), int64(len(b)), ct); err != nil {
		return nil, err
	}
	p, old, err := s.personas().SetAvatar(ctx, o, req.Id, &key, &ct)
	if err != nil {
		// Deleted meanwhile, or the write failed: nothing points at the new blob.
		s.deleteAvatarBlob(ctx, &key)
		return nil, err
	}
	s.deleteAvatarBlob(ctx, old)
	out, err := s.toPersona(ctx, p)
	return api.UploadPersonaAvatar200JSONResponse(out), err
}

// avatarFromAttachment makes a stored image, such as one generated in a chat,
// the persona's avatar (personas.AvatarFromImage), replacing any it had.
func (s *Server) avatarFromAttachment(ctx context.Context, o personas.Owner, persona uuid.UUID, att store.ChatAttachment) error {
	if s.Blobs == nil {
		return errNoBlobs
	}
	obj, err := s.Blobs.Get(ctx, s.ArtifactBucket, att.BlobKey)
	if err != nil {
		return err
	}
	src, err := io.ReadAll(io.LimitReader(obj.Body, personas.MaxAvatarSourceBytes+1))
	obj.Body.Close()
	if err != nil {
		return err
	}
	b, ct, err := personas.AvatarFromImage(src)
	if err != nil {
		return err
	}
	key := personas.AvatarKey(o, persona)
	if err := s.Blobs.Put(ctx, s.ArtifactBucket, key, bytes.NewReader(b), int64(len(b)), ct); err != nil {
		return err
	}
	_, old, err := s.personas().SetAvatar(ctx, o, persona, &key, &ct)
	if err != nil {
		// Deleted meanwhile, or the write failed: nothing points at the new blob.
		s.deleteAvatarBlob(ctx, &key)
		return err
	}
	s.deleteAvatarBlob(ctx, old)
	return nil
}

func (s *Server) DeletePersonaAvatar(ctx context.Context, req api.DeletePersonaAvatarRequestObject) (api.DeletePersonaAvatarResponseObject, error) {
	p, old, err := s.personas().SetAvatar(ctx, personaOwner(ctx), req.Id, nil, nil)
	if err != nil {
		return nil, err
	}
	s.deleteAvatarBlob(ctx, old)
	out, err := s.toPersona(ctx, p)
	return api.DeletePersonaAvatar200JSONResponse(out), err
}

func decodeFallbackPNG(b64 *string) ([]byte, string, error) {
	if b64 == nil {
		return nil, "", nil
	}
	raw := strings.TrimSpace(*b64)
	if raw == "" {
		return nil, "", nil
	}
	raw = strings.TrimPrefix(raw, "data:image/png;base64,")
	if base64.StdEncoding.DecodedLen(len(raw)) > personas.MaxAvatarBytes+4 {
		return nil, "", personas.AvatarTooLarge()
	}
	b, err := base64.StdEncoding.DecodeString(raw)
	if err != nil {
		return nil, "", apperr.Invalid("fallback_png_base64", "invalid base64 PNG")
	}
	ct, err := personas.CheckAvatar(b)
	if err != nil {
		var ae *personas.AvatarError
		if errors.As(err, &ae) {
			if ae.Status == http.StatusRequestEntityTooLarge {
				return nil, "", err
			}
			return nil, "", apperr.Invalid("fallback_png_base64", "%s", ae.Msg)
		}
		return nil, "", err
	}
	if ct != "image/png" {
		return nil, "", apperr.Invalid("fallback_png_base64", "fallback avatar must be a PNG")
	}
	return b, ct, nil
}

func (s *Server) storeCharacterFallback(ctx context.Context, o personas.Owner, persona uuid.UUID, pngBytes []byte, ct string) error {
	if len(pngBytes) == 0 || s.Blobs == nil {
		return nil
	}
	key := personas.AvatarKey(o, persona)
	if err := s.Blobs.Put(ctx, s.ArtifactBucket, key, bytes.NewReader(pngBytes), int64(len(pngBytes)), ct); err != nil {
		return err
	}
	_, old, err := s.personas().SetCharacterFallback(ctx, o, persona, key, ct)
	if err != nil {
		s.deleteAvatarBlob(ctx, &key)
		return err
	}
	s.deleteAvatarBlob(ctx, old)
	return nil
}

func (s *Server) SetPersonaCharacter(ctx context.Context, req api.SetPersonaCharacterRequestObject) (api.SetPersonaCharacterResponseObject, error) {
	if req.Body == nil {
		return nil, apperr.Invalid("body", "required")
	}
	o := personaOwner(ctx)
	if _, err := s.personas().Get(ctx, o, req.Id); err != nil {
		return nil, err
	}
	checked, err := personas.CheckCharacterSVG(req.Body.CharacterSvg)
	if err != nil {
		return nil, err
	}
	pngBytes, ct, err := decodeFallbackPNG(req.Body.FallbackPngBase64)
	if err != nil {
		var ae *personas.AvatarError
		if errors.As(err, &ae) && ae.Status == http.StatusRequestEntityTooLarge {
			field := "fallback_png_base64"
			return api.SetPersonaCharacter413JSONResponse(api.Error{Code: api.Invalid, Message: ae.Msg, Field: &field}), nil
		}
		return nil, err
	}
	var keyPtr, ctPtr *string
	if len(pngBytes) > 0 {
		if s.Blobs == nil {
			return nil, errNoBlobs
		}
		k := personas.AvatarKey(o, req.Id)
		if err := s.Blobs.Put(ctx, s.ArtifactBucket, k, bytes.NewReader(pngBytes), int64(len(pngBytes)), ct); err != nil {
			return nil, err
		}
		keyPtr, ctPtr = &k, &ct
	}
	p, old, err := s.personas().SetCharacter(ctx, o, req.Id, checked, keyPtr, ctPtr)
	if err != nil {
		s.deleteAvatarBlob(ctx, keyPtr)
		return nil, err
	}
	s.deleteAvatarBlob(ctx, old)
	out, err := s.toPersona(ctx, p)
	return api.SetPersonaCharacter200JSONResponse(out), err
}

func (s *Server) DeletePersonaCharacter(ctx context.Context, req api.DeletePersonaCharacterRequestObject) (api.DeletePersonaCharacterResponseObject, error) {
	p, old, err := s.personas().ClearCharacter(ctx, personaOwner(ctx), req.Id)
	if err != nil {
		return nil, err
	}
	s.deleteAvatarBlob(ctx, old)
	out, err := s.toPersona(ctx, p)
	return api.DeletePersonaCharacter200JSONResponse(out), err
}

func (s *Server) GetPersonaAvatar(ctx context.Context, req api.GetPersonaAvatarRequestObject) (api.GetPersonaAvatarResponseObject, error) {
	p, err := s.personas().Get(ctx, personaOwner(ctx), req.Id)
	if err != nil {
		return nil, err
	}
	// Only ever serve one of the sniffed image types, whatever the row says.
	if p.AvatarKey == nil || p.AvatarContentType == nil || !slices.Contains(personas.AvatarTypes, *p.AvatarContentType) {
		return nil, apperr.ErrNotFound
	}
	if s.Blobs == nil {
		return nil, errNoBlobs
	}
	obj, err := s.Blobs.Get(ctx, s.ArtifactBucket, *p.AvatarKey)
	if errors.Is(err, blob.ErrNotFound) {
		return nil, apperr.ErrNotFound // replaced or deleted since the row was read
	} else if err != nil {
		return nil, err
	}
	return avatarResponse{body: obj.Body, contentType: *p.AvatarContentType, length: obj.ContentLength}, nil
}

// avatarResponse serves avatar bytes with the stored (sniffed) type and
// headers that stop the browser from treating them as anything but an
// image. The URL carries ?v=<revision>, so a long private cache is safe.
type avatarResponse struct {
	body        io.ReadCloser
	contentType string
	length      int64
	cache       string // Cache-Control; a day when empty
}

func (r avatarResponse) VisitGetPersonaAvatarResponse(w http.ResponseWriter) error {
	return r.write(w)
}

// VisitGetDeckAssetResponse serves a deck image with the same headers.
func (r avatarResponse) VisitGetDeckAssetResponse(w http.ResponseWriter) error {
	return r.write(w)
}

// VisitGetDesignAssetResponse serves a design image with the same headers.
func (r avatarResponse) VisitGetDesignAssetResponse(w http.ResponseWriter) error {
	return r.write(w)
}

// VisitGetUserAvatarResponse serves a profile picture with the same headers.
func (r avatarResponse) VisitGetUserAvatarResponse(w http.ResponseWriter) error {
	return r.write(w)
}

func (r avatarResponse) write(w http.ResponseWriter) error {
	defer r.body.Close()
	h := w.Header()
	h.Set("Content-Type", r.contentType)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Content-Security-Policy", "default-src 'none'; sandbox")
	h.Set("Content-Disposition", "inline")
	cache := r.cache
	if cache == "" {
		cache = "private, max-age=86400"
	}
	h.Set("Cache-Control", cache)
	if r.length > 0 {
		h.Set("Content-Length", fmt.Sprint(r.length))
	}
	w.WriteHeader(http.StatusOK)
	_, err := io.Copy(w, r.body)
	return err
}
