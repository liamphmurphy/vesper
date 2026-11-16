package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/httpclient"
)

func (s *Server) httpClient() *httpclient.Service {
	return &httpclient.Service{Q: s.Q, Secrets: s.userSecrets()}
}

func httpClientID(r *http.Request, name string) (uuid.UUID, error) {
	id, err := uuid.Parse(r.PathValue(name))
	if err != nil {
		return uuid.Nil, apperr.Invalid(name, "must be a UUID")
	}
	return id, nil
}

func httpClientJSON(r *http.Request, dst any, maxBytes int64) error {
	defer r.Body.Close()
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBytes+1))
	if err != nil {
		return apperr.Invalid("body", "unreadable request body")
	}
	if int64(len(body)) > maxBytes {
		return apperr.Invalid("body", "request body too large")
	}
	if len(body) == 0 {
		return apperr.Invalid("body", "required")
	}
	if err := json.Unmarshal(body, dst); err != nil {
		return apperr.Invalid("body", "invalid JSON")
	}
	return nil
}

func (s *Server) httpClientRoutes(mux *http.ServeMux) {
	handle := func(pattern string, fn func(*http.Request) (any, int, error)) {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			result, status, err := fn(r)
			if err != nil {
				if errors.Is(err, pgx.ErrNoRows) {
					err = apperr.ErrNotFound
				}
				s.responseError(w, r, err)
				return
			}
			if status == http.StatusNoContent {
				w.WriteHeader(http.StatusNoContent)
				return
			}
			w.Header().Set("Content-Type", "application/json")
			w.Header().Set("Cache-Control", "no-store")
			w.WriteHeader(status)
			_ = json.NewEncoder(w).Encode(result)
		})
	}

	handle("GET /api/v1/http/workspaces", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		list, err := s.httpClient().ListWorkspaces(r.Context(), ws)
		return map[string]any{"workspaces": list}, http.StatusOK, err
	})

	handle("POST /api/v1/http/workspaces", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		var in httpclient.WorkspaceInput
		if err := httpClientJSON(r, &in, 1<<20); err != nil {
			return nil, 0, err
		}
		bundle, err := s.httpClient().CreateWorkspace(r.Context(), ws, u.ID, in)
		return bundle, http.StatusCreated, err
	})

	handle("GET /api/v1/http/workspaces/{id}", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		bundle, err := s.httpClient().GetWorkspaceBundle(r.Context(), ws, id)
		return bundle, http.StatusOK, err
	})

	handle("PUT /api/v1/http/workspaces/{id}", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		var in httpclient.WorkspaceInput
		if err := httpClientJSON(r, &in, 1<<20); err != nil {
			return nil, 0, err
		}
		out, err := s.httpClient().UpdateWorkspace(r.Context(), ws, id, in)
		return out, http.StatusOK, err
	})

	handle("PATCH /api/v1/http/workspaces/{id}/active-environment", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		var in struct {
			EnvironmentID *uuid.UUID `json:"environment_id"`
		}
		if err := httpClientJSON(r, &in, 64<<10); err != nil {
			return nil, 0, err
		}
		out, err := s.httpClient().SetActiveEnvironment(r.Context(), ws, id, in.EnvironmentID)
		return out, http.StatusOK, err
	})

	handle("DELETE /api/v1/http/workspaces/{id}", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		return nil, http.StatusNoContent, s.httpClient().DeleteWorkspace(r.Context(), ws, id)
	})

	handle("POST /api/v1/http/workspaces/{id}/environments", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		var in httpclient.EnvironmentInput
		if err := httpClientJSON(r, &in, 1<<20); err != nil {
			return nil, 0, err
		}
		out, err := s.httpClient().CreateEnvironment(r.Context(), ws, id, in)
		return out, http.StatusCreated, err
	})

	handle("PUT /api/v1/http/environments/{id}", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		var in httpclient.EnvironmentInput
		if err := httpClientJSON(r, &in, 1<<20); err != nil {
			return nil, 0, err
		}
		out, err := s.httpClient().UpdateEnvironment(r.Context(), ws, id, in)
		return out, http.StatusOK, err
	})

	handle("DELETE /api/v1/http/environments/{id}", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		return nil, http.StatusNoContent, s.httpClient().DeleteEnvironment(r.Context(), ws, id)
	})

	handle("POST /api/v1/http/workspaces/{id}/folders", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		var in httpclient.FolderInput
		if err := httpClientJSON(r, &in, 1<<20); err != nil {
			return nil, 0, err
		}
		out, err := s.httpClient().CreateFolder(r.Context(), ws, id, in)
		return out, http.StatusCreated, err
	})

	handle("PUT /api/v1/http/folders/{id}", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		var in httpclient.FolderInput
		if err := httpClientJSON(r, &in, 1<<20); err != nil {
			return nil, 0, err
		}
		out, err := s.httpClient().UpdateFolder(r.Context(), ws, id, in)
		return out, http.StatusOK, err
	})

	handle("DELETE /api/v1/http/folders/{id}", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		return nil, http.StatusNoContent, s.httpClient().DeleteFolder(r.Context(), ws, id)
	})

	handle("POST /api/v1/http/workspaces/{id}/requests", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		var in httpclient.RequestInput
		if err := httpClientJSON(r, &in, 4<<20); err != nil {
			return nil, 0, err
		}
		out, err := s.httpClient().CreateRequest(r.Context(), ws, id, in)
		return out, http.StatusCreated, err
	})

	handle("PUT /api/v1/http/requests/{id}", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		var in httpclient.RequestInput
		if err := httpClientJSON(r, &in, 4<<20); err != nil {
			return nil, 0, err
		}
		out, err := s.httpClient().UpdateRequest(r.Context(), ws, id, in)
		return out, http.StatusOK, err
	})

	handle("DELETE /api/v1/http/requests/{id}", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		return nil, http.StatusNoContent, s.httpClient().DeleteRequest(r.Context(), ws, id)
	})

	handle("GET /api/v1/http/workspaces/{id}/executions", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		list, err := s.httpClient().ListExecutionsByWorkspace(r.Context(), ws, id, limit)
		return map[string]any{"executions": list}, http.StatusOK, err
	})

	handle("GET /api/v1/http/requests/{id}/executions", func(r *http.Request) (any, int, error) {
		_, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
		list, err := s.httpClient().ListExecutionsByRequest(r.Context(), ws, id, limit)
		return map[string]any{"executions": list}, http.StatusOK, err
	})

	handle("POST /api/v1/http/requests/{id}/run", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		var opts httpclient.RunOptions
		if r.ContentLength != 0 {
			if err := httpClientJSON(r, &opts, 4<<20); err != nil {
				return nil, 0, err
			}
		}
		exec, err := s.httpClient().RunSavedRequest(r.Context(), ws, u.ID, id, opts)
		return exec, http.StatusOK, err
	})

	handle("POST /api/v1/http/workspaces/{id}/run", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		id, err := httpClientID(r, "id")
		if err != nil {
			return nil, 0, err
		}
		var in httpclient.AdHocRunInput
		if err := httpClientJSON(r, &in, 4<<20); err != nil {
			return nil, 0, err
		}
		exec, err := s.httpClient().RunAdHocRequest(r.Context(), ws, u.ID, id, in)
		return exec, http.StatusOK, err
	})
}
