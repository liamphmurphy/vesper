package httpapi

import (
	"encoding/json"
	"errors"
	"net/http"
	"regexp"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// dockScope names the place an app dock keeps chats for: a Knowledge page
// (page:<uuid>) or an app's screens that aren't an item (app:<name> or app:custom:<slug>).
var dockScope = regexp.MustCompile(`^(page:[0-9a-f-]{36}|app:[a-z0-9][a-z0-9_:-]{0,63})$`)

func validDockScope(scope string) error {
	if !dockScope.MatchString(scope) {
		return apperr.Invalid("scope", "use page:<id> or app:<name>")
	}
	return nil
}

// dockChatRoutes serve an app dock's chat switcher: the chats it keeps for a
// place, and adding one when the person starts or picks a chat there.
func (s *Server) dockChatRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/dock-chats", func(w http.ResponseWriter, r *http.Request) {
		u, _, ws := me(r.Context())
		scope := r.URL.Query().Get("scope")
		if err := validDockScope(scope); err != nil {
			s.responseError(w, r, err)
			return
		}
		rows, err := s.Q.ListDockChats(r.Context(), store.ListDockChatsParams{WorkspaceID: ws, UserID: u.ID, Scope: scope})
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		items, err := s.toChats(r.Context(), rows)
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		if items == nil {
			items = []api.ChatSession{}
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		json.NewEncoder(w).Encode(map[string]any{"chats": items})
	})
	mux.HandleFunc("POST /api/v1/dock-chats", func(w http.ResponseWriter, r *http.Request) {
		u, _, ws := me(r.Context())
		var in struct {
			Scope  string    `json:"scope"`
			ChatID uuid.UUID `json:"chat_id"`
		}
		if err := knowledgeJSON(r, &in); err != nil {
			s.responseError(w, r, err)
			return
		}
		if err := validDockScope(in.Scope); err != nil {
			s.responseError(w, r, err)
			return
		}
		chat, err := s.Q.GetChatSession(r.Context(), store.GetChatSessionParams{ID: in.ChatID, WorkspaceID: ws})
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && chat.CreatedBy != u.ID) {
			s.responseError(w, r, apperr.ErrNotFound)
			return
		}
		if err != nil {
			s.responseError(w, r, err)
			return
		}
		if err := s.Q.AddDockChat(r.Context(), store.AddDockChatParams{Scope: in.Scope, ChatID: chat.ID, WorkspaceID: ws, UserID: u.ID}); err != nil {
			s.responseError(w, r, err)
			return
		}
		w.WriteHeader(http.StatusNoContent)
	})
}
