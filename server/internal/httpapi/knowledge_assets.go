package httpapi

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/jackc/pgx/v5"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

const knowledgeAssetLimit = 512 << 20

func (s *Server) knowledgeAssetRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/knowledge/assets", func(w http.ResponseWriter, r *http.Request) {
		u, _, ws := me(r.Context())
		rows, err := s.Q.SuggestKnowledgeImages(r.Context(), store.SuggestKnowledgeImagesParams{WorkspaceID: ws, Viewer: &u.ID, Query: strings.TrimSpace(r.URL.Query().Get("q"))})
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		type image struct {
			ID          string `json:"id"`
			Title       string `json:"title"`
			Ref         string `json:"ref"`
			ContentType string `json:"content_type"`
		}
		images := make([]image, 0, len(rows))
		for _, asset := range rows {
			images = append(images, image{ID: asset.ID.String(), Title: asset.Filename, Ref: wiki.AttachmentRef(asset.ID, asset.Filename), ContentType: asset.ContentType})
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "private, no-store")
		json.NewEncoder(w).Encode(map[string]any{"images": images})
	})
	mux.HandleFunc("POST /api/v1/knowledge/assets", func(w http.ResponseWriter, r *http.Request) {
		u, _, ws := me(r.Context())
		if s.Blobs == nil {
			s.responseError(w, r, apperr.Conflict("attachment storage is unavailable"))
			return
		}
		file, err := os.CreateTemp("", "vesper-asset-*")
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		defer os.Remove(file.Name())
		defer file.Close()
		hash := sha256.New()
		n, err := io.Copy(io.MultiWriter(file, hash), http.MaxBytesReader(w, r.Body, knowledgeAssetLimit))
		if err != nil {
			s.responseError(w, r, apperr.Invalid("file", "could not read attachment (limit 512 MB): %v", err))
			return
		}
		if n == 0 {
			s.responseError(w, r, apperr.Invalid("file", "is empty"))
			return
		}
		rawName := r.URL.Query().Get("filename")
		if strings.TrimSpace(rawName) == "" {
			rawName = r.Header.Get("X-Filename")
		}
		filename := filepath.Base(strings.ReplaceAll(strings.TrimSpace(rawName), "\\", "/"))
		if filename == "." || filename == ".." || filename == "/" || filename == "" {
			filename = "attachment"
		}
		head := make([]byte, 512)
		file.Seek(0, io.SeekStart)
		read, _ := file.Read(head)
		contentType := wiki.DetectAssetContentType(filename, head[:read])
		file.Seek(0, io.SeekStart)
		digest := fmt.Sprintf("%x", hash.Sum(nil))
		asset, err := s.Wiki.StoreKnowledgeAsset(r.Context(), ws, u.ID, digest, filename, contentType, n, file)
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.WriteHeader(http.StatusCreated)
		json.NewEncoder(w).Encode(map[string]any{
			"id":           asset.ID,
			"ref":          wiki.AttachmentRef(asset.ID, asset.Filename),
			"url":          "/api/v1/knowledge/assets/" + asset.ID.String(),
			"filename":     asset.Filename,
			"content_type": asset.ContentType,
		})
	})
	mux.HandleFunc("GET /api/v1/knowledge/assets/{id}", func(w http.ResponseWriter, r *http.Request) {
		u, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		asset, err := s.Q.GetKnowledgeAsset(r.Context(), store.GetKnowledgeAssetParams{ID: id, WorkspaceID: ws, Viewer: &u.ID})
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				writeError(w, 404, api.NotFound, "not found", "")
			} else {
				s.responseError(w, r, err)
			}
			return
		}
		if s.Blobs == nil {
			s.responseError(w, r, apperr.Conflict("attachment storage is unavailable"))
			return
		}
		object, err := s.Blobs.Get(r.Context(), s.ArtifactBucket, asset.BlobKey)
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		defer object.Body.Close()
		disposition := "attachment"
		if strings.HasPrefix(asset.ContentType, "image/") && asset.ContentType != "image/svg+xml" {
			disposition = "inline"
		}
		w.Header().Set("Content-Disposition", mime.FormatMediaType(disposition, map[string]string{"filename": asset.Filename}))
		w.Header().Set("Content-Type", asset.ContentType)
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.Header().Set("Content-Security-Policy", "default-src 'none'; sandbox")
		w.Header().Set("Cache-Control", "private, no-store")
		io.Copy(w, object.Body)
	})
}
