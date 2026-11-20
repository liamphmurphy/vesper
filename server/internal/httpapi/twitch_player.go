package httpapi

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strconv"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/twitchplayer"
)

func (s *Server) twitchPlayer() *twitchplayer.Service {
	s.twitchPlayerOnce.Do(func() {
		if s.TwitchPlayer != nil {
			s.twitchPlayerSvc = s.TwitchPlayer
		} else {
			s.twitchPlayerSvc = &twitchplayer.Service{}
		}
	})
	return s.twitchPlayerSvc
}

func (s *Server) twitchPlayerRoutes(mux *http.ServeMux) {
	jsonHandle := func(pattern string, fn func(*http.Request) (any, int, error)) {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			result, status, err := fn(r)
			if err != nil {
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

	jsonHandle("POST /api/v1/twitch/sessions", func(r *http.Request) (any, int, error) {
		u, _, _ := me(r.Context())
		var in twitchplayer.CreateSessionInput
		if err := httpClientJSON(r, &in, 64<<10); err != nil {
			return nil, 0, err
		}
		info, err := s.twitchPlayer().CreateSession(r.Context(), u.ID, in)
		return info, http.StatusCreated, err
	})

	jsonHandle("GET /api/v1/twitch/sessions/{id}", func(r *http.Request) (any, int, error) {
		u, _, _ := me(r.Context())
		info, err := s.twitchPlayer().GetSession(u.ID, r.PathValue("id"))
		return info, http.StatusOK, err
	})

	jsonHandle("PATCH /api/v1/twitch/sessions/{id}", func(r *http.Request) (any, int, error) {
		u, _, _ := me(r.Context())
		var in twitchplayer.UpdateSessionInput
		if err := httpClientJSON(r, &in, 64<<10); err != nil {
			return nil, 0, err
		}
		info, err := s.twitchPlayer().UpdateSession(u.ID, r.PathValue("id"), in)
		return info, http.StatusOK, err
	})

	jsonHandle("DELETE /api/v1/twitch/sessions/{id}", func(r *http.Request) (any, int, error) {
		u, _, _ := me(r.Context())
		return nil, http.StatusNoContent, s.twitchPlayer().DeleteSession(u.ID, r.PathValue("id"))
	})

	mux.HandleFunc("GET /api/v1/twitch/sessions/{id}/master.m3u8", func(w http.ResponseWriter, r *http.Request) {
		u, _, _ := me(r.Context())
		body, err := s.twitchPlayer().MasterPlaylist(u.ID, r.PathValue("id"))
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(body))
	})

	mux.HandleFunc("GET /api/v1/twitch/sessions/{id}/variant/{idx}", func(w http.ResponseWriter, r *http.Request) {
		u, _, _ := me(r.Context())
		rawIdx := strings.TrimSuffix(r.PathValue("idx"), ".m3u8")
		idx, err := strconv.Atoi(rawIdx)
		if err != nil || idx < 0 {
			s.responseError(w, r, apperr.Invalid("idx", "invalid variant index"))
			return
		}
		res, err := s.twitchPlayer().VariantPlaylist(r.Context(), u.ID, r.PathValue("id"), idx)
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Vesper-Twitch-Ad", res.AdStatus)
		w.Header().Set("X-Vesper-Twitch-Player-Type", res.ActiveType)
		w.Header().Set("X-Vesper-Twitch-Using-Backup", fmt.Sprintf("%t", res.UsingBackup))
		if res.AdDurationSec > 0 {
			w.Header().Set("X-Vesper-Twitch-Ad-Duration", strconv.FormatFloat(res.AdDurationSec, 'f', 1, 64))
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(res.Body))
	})
}
