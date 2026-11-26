package httpapi

import (
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"github.com/google/uuid"
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

type knowledgeAttachmentUsageDTO struct {
	ID    string `json:"id"`
	Title string `json:"title"`
	Path  string `json:"path"`
}

type knowledgeAttachmentDTO struct {
	ID          string                        `json:"id"`
	Filename    string                        `json:"filename"`
	Title       string                        `json:"title"`
	Path        string                        `json:"path"`
	Ref         string                        `json:"ref"`
	URL         string                        `json:"url"`
	ContentType string                        `json:"content_type"`
	SizeBytes   int64                         `json:"size_bytes"`
	CreatedAt   string                        `json:"created_at"`
	UsageCount  int                           `json:"usage_count"`
	UsedIn      []knowledgeAttachmentUsageDTO `json:"used_in"`
	IsOwner     bool                          `json:"is_owner"`
}

func makeKnowledgeAttachmentDTO(id, ownerID, viewerID uuid.UUID, filename, contentType string, sizeBytes int64, createdAt string, usedIn []knowledgeAttachmentUsageDTO) knowledgeAttachmentDTO {
	if usedIn == nil {
		usedIn = []knowledgeAttachmentUsageDTO{}
	}
	return knowledgeAttachmentDTO{
		ID:          id.String(),
		Filename:    filename,
		Title:       filename,
		Path:        wiki.AttachmentFolderPath(filename),
		Ref:         wiki.AttachmentRef(id, filename),
		URL:         "/api/v1/knowledge/assets/" + id.String(),
		ContentType: contentType,
		SizeBytes:   sizeBytes,
		CreatedAt:   createdAt,
		UsageCount:  len(usedIn),
		UsedIn:      usedIn,
		IsOwner:     ownerID == viewerID,
	}
}

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
	mux.HandleFunc("GET /api/v1/knowledge/attachments", func(w http.ResponseWriter, r *http.Request) {
		u, _, ws := me(r.Context())
		rows, err := s.Q.ListKnowledgeAssets(r.Context(), store.ListKnowledgeAssetsParams{
			WorkspaceID: ws,
			Viewer:      &u.ID,
			Query:       strings.TrimSpace(r.URL.Query().Get("q")),
		})
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		usages, err := s.Q.ListKnowledgeAssetUsages(r.Context(), store.ListKnowledgeAssetUsagesParams{
			WorkspaceID: ws,
			Viewer:      &u.ID,
		})
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		usedByAsset := make(map[uuid.UUID][]knowledgeAttachmentUsageDTO, len(rows))
		for _, usage := range usages {
			path := ""
			if usage.Path != nil {
				path = *usage.Path
			}
			usedByAsset[usage.AssetID] = append(usedByAsset[usage.AssetID], knowledgeAttachmentUsageDTO{
				ID:    usage.PageID.String(),
				Title: usage.Title,
				Path:  path,
			})
		}
		attachments := make([]knowledgeAttachmentDTO, 0, len(rows))
		for _, asset := range rows {
			attachments = append(attachments, makeKnowledgeAttachmentDTO(
				asset.ID,
				asset.OwnerUserID,
				u.ID,
				asset.Filename,
				asset.ContentType,
				asset.SizeBytes,
				asset.CreatedAt.UTC().Format("2006-01-02T15:04:05Z07:00"),
				usedByAsset[asset.ID],
			))
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "private, no-store")
		json.NewEncoder(w).Encode(map[string]any{
			"folder":      wiki.AttachmentFolder,
			"attachments": attachments,
		})
	})
	mux.HandleFunc("PATCH /api/v1/knowledge/attachments/{id}", func(w http.ResponseWriter, r *http.Request) {
		u, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		var body struct {
			Filename string `json:"filename"`
		}
		if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16<<10)).Decode(&body); err != nil {
			writeError(w, http.StatusBadRequest, api.Invalid, "invalid json body", "")
			return
		}
		asset, err := s.Wiki.RenameKnowledgeAsset(r.Context(), ws, u.ID, id, body.Filename)
		if err != nil {
			if errors.Is(err, wiki.ErrAttachmentForbidden) {
				writeError(w, http.StatusForbidden, api.Forbidden, err.Error(), "")
				return
			}
			s.responseError(w, r, err)
			return
		}
		usages, err := s.Q.ListKnowledgeAssetUsagesForAsset(r.Context(), store.ListKnowledgeAssetUsagesForAssetParams{
			AssetID:     asset.ID,
			WorkspaceID: ws,
			Viewer:      &u.ID,
		})
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		usedIn := make([]knowledgeAttachmentUsageDTO, 0, len(usages))
		for _, usage := range usages {
			path := ""
			if usage.Path != nil {
				path = *usage.Path
			}
			usedIn = append(usedIn, knowledgeAttachmentUsageDTO{
				ID:    usage.PageID.String(),
				Title: usage.Title,
				Path:  path,
			})
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "private, no-store")
		json.NewEncoder(w).Encode(makeKnowledgeAttachmentDTO(
			asset.ID,
			asset.OwnerUserID,
			u.ID,
			asset.Filename,
			asset.ContentType,
			asset.SizeBytes,
			asset.CreatedAt.UTC().Format("2006-01-02T15:04:05Z07:00"),
			usedIn,
		))
	})
	mux.HandleFunc("DELETE /api/v1/knowledge/attachments/{id}", func(w http.ResponseWriter, r *http.Request) {
		u, _, ws := me(r.Context())
		id, err := knowledgeID(r, "id")
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		deleted, err := s.Wiki.DeleteKnowledgeAsset(r.Context(), ws, u.ID, id)
		if err != nil {
			if errors.Is(err, wiki.ErrAttachmentForbidden) {
				writeError(w, http.StatusForbidden, api.Forbidden, err.Error(), "")
				return
			}
			s.responseError(w, r, err)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "private, no-store")
		json.NewEncoder(w).Encode(map[string]any{
			"deleted": deleted.ID.String(),
		})
	})
	mux.HandleFunc("GET /api/v1/knowledge/headings", func(w http.ResponseWriter, r *http.Request) {
		u, _, ws := me(r.Context())
		includeAgent := r.URL.Query().Get("include_agent") == "true" || r.URL.Query().Get("include_agent") == "1"
		rows, err := s.Q.ListKnowledgeHeadings(r.Context(), store.ListKnowledgeHeadingsParams{
			WorkspaceID:  ws,
			Viewer:       &u.ID,
			IncludeAgent: includeAgent,
			Query:        strings.TrimSpace(r.URL.Query().Get("q")),
		})
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		type headingDTO struct {
			PageID    string `json:"page_id"`
			PageTitle string `json:"page_title"`
			PagePath  string `json:"page_path"`
			Audience  string `json:"audience"`
			Level     int32  `json:"level"`
			Anchor    string `json:"anchor"`
			Heading   string `json:"heading"`
			Position  int32  `json:"position"`
		}
		out := make([]headingDTO, 0, len(rows))
		for _, row := range rows {
			path := ""
			if row.PagePath != nil {
				path = *row.PagePath
			}
			out = append(out, headingDTO{
				PageID:    row.PageID.String(),
				PageTitle: row.PageTitle,
				PagePath:  path,
				Audience:  row.Audience,
				Level:     row.Level,
				Anchor:    row.Anchor,
				Heading:   row.Heading,
				Position:  row.Position,
			})
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "private, no-store")
		json.NewEncoder(w).Encode(map[string]any{
			"headings": out,
		})
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
			"path":         wiki.AttachmentFolderPath(asset.Filename),
			"content_type": asset.ContentType,
			"size_bytes":   asset.SizeBytes,
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
