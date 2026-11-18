package httpapi

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/browserext"
	"github.com/liamphmurphy/vesper/server/internal/linkpreview"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/transcript"
	"github.com/liamphmurphy/vesper/server/internal/wiki"
)

// The Safari extension's API (docs/dev/safari-extension.md has every route).
// /api/v1/browser-extension/* takes the extension's bearer token instead of a
// browser session, and nothing else takes that token. The Mac app mints it
// through the session-authenticated POST /api/v1/browser-extension-token.
const browserExtensionPrefix = "/api/v1/browser-extension/"

// clippingsFolder is where pages clipped from Safari land in Knowledge.
const clippingsFolder = "Clippings"

func (s *Server) browserExt() *browserext.Service {
	return &browserext.Service{Pool: s.Pool, Q: s.Q}
}

type browserSnapshotIn struct {
	URL        string `json:"url"`
	Title      string `json:"title"`
	Text       string `json:"text"`
	Screenshot string `json:"screenshot"` // base64 JPEG, optional
	Incognito  bool   `json:"incognito"`
}

func (in browserSnapshotIn) decode() (browserext.Snapshot, error) {
	snap := browserext.Snapshot{URL: in.URL, Title: in.Title, Text: in.Text, Incognito: in.Incognito}
	if in.Screenshot != "" {
		if base64.StdEncoding.DecodedLen(len(in.Screenshot)) > browserext.MaxScreenshotBytes+3 {
			return snap, apperr.Invalid("screenshot", "at most %d bytes", browserext.MaxScreenshotBytes)
		}
		b, err := base64.StdEncoding.DecodeString(in.Screenshot)
		if err != nil {
			return snap, apperr.Invalid("screenshot", "must be base64")
		}
		snap.Screenshot = b
	}
	return snap, nil
}

type browserShareOut struct {
	ID                uuid.UUID             `json:"id"`
	ChatID            uuid.UUID             `json:"chat_id"`
	ChatTitle         string                `json:"chat_title"`
	TabID             string                `json:"tab_id"`
	URL               string                `json:"url"`
	Title             string                `json:"title"`
	Until             string                `json:"until"`
	IncludeScreenshot bool                  `json:"include_screenshot"`
	StartedAt         time.Time             `json:"started_at"`
	SnapshotAt        *time.Time            `json:"snapshot_at"`
	StoppedAt         *time.Time            `json:"stopped_at"`
	StopReason        string                `json:"stop_reason"`
	Reads             []browserShareReadOut `json:"reads"`
}

type browserShareReadOut struct {
	Persona string    `json:"persona"`
	URL     string    `json:"url"`
	ReadAt  time.Time `json:"read_at"`
}

func (s *Server) browserShareOut(ctx context.Context, ws uuid.UUID, sh store.BrowserShare) (browserShareOut, error) {
	out := browserShareOut{ID: sh.ID, ChatID: sh.ChatID, TabID: sh.TabID, URL: sh.Url, Title: sh.Title, Until: sh.Until, IncludeScreenshot: sh.IncludeScreenshot,
		StartedAt: sh.StartedAt, SnapshotAt: sh.SnapshotAt, StoppedAt: sh.StoppedAt, StopReason: sh.StopReason, Reads: []browserShareReadOut{}}
	if chat, err := s.Q.GetChatSession(ctx, store.GetChatSessionParams{ID: sh.ChatID, WorkspaceID: ws}); err == nil {
		out.ChatTitle = chat.Title
	} else if !errors.Is(err, pgx.ErrNoRows) {
		return out, err
	}
	reads, err := s.Q.ListBrowserShareReads(ctx, sh.ID)
	if err != nil {
		return out, err
	}
	for _, r := range reads {
		out.Reads = append(out.Reads, browserShareReadOut{Persona: r.PersonaName, URL: r.Url, ReadAt: r.ReadAt})
	}
	return out, nil
}

// browserExtensionAuth checks the extension's token. The local user is
// already on the context (localUser); the token must be theirs.
func (s *Server) browserExtensionAuth(r *http.Request) error {
	id, err := browserext.TokenUser(r.Context(), s.Q, r.Header.Get("Authorization"))
	if errors.Is(err, browserext.ErrBadToken) {
		return errBrowserExtensionToken
	}
	if err != nil {
		return err
	}
	if u, ok := auth.UserFrom(r.Context()); !ok || u.ID != id {
		return errBrowserExtensionToken
	}
	return nil
}

var errBrowserExtensionToken = errors.New("browser extension token refused")

// browserPageError explains a page the extension may not send.
func browserPageError(err error) error {
	if errors.Is(err, browserext.ErrNotShareable) {
		return apperr.ConflictField("url", "this page can't be shared: it's on the never-share list, in a private window, or not a web page")
	}
	return err
}

func (s *Server) browserExtensionRoutes(mux *http.ServeMux) {
	reply := func(w http.ResponseWriter, r *http.Request, result any, status int, err error) {
		if errors.Is(err, errBrowserExtensionToken) {
			writeError(w, http.StatusUnauthorized, api.Unauthenticated, "the Safari extension's token was refused: reopen Vesper to renew it", "")
			return
		}
		if err != nil {
			if errors.Is(err, pgx.ErrNoRows) {
				err = apperr.ErrNotFound
			}
			s.responseError(w, r, err)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(status)
		_ = json.NewEncoder(w).Encode(result)
	}
	// ext serves an extension route: token first, then the handler.
	ext := func(pattern string, fn func(*http.Request) (any, int, error)) {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			if err := s.browserExtensionAuth(r); err != nil {
				reply(w, r, nil, 0, err)
				return
			}
			result, status, err := fn(r)
			reply(w, r, result, status, err)
		})
	}
	// person serves a route for a signed-in browser (the Mac app, the chat page).
	person := func(pattern string, fn func(*http.Request) (any, int, error)) {
		mux.HandleFunc(pattern, func(w http.ResponseWriter, r *http.Request) {
			result, status, err := fn(r)
			reply(w, r, result, status, err)
		})
	}

	person("POST /api/v1/browser-extension-token", func(r *http.Request) (any, int, error) {
		u, _, _ := me(r.Context())
		token, err := browserext.MintToken(r.Context(), s.Q, u.ID)
		return map[string]string{"token": token}, http.StatusCreated, err
	})

	person("GET /api/v1/chats/{id}/browser-share", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		chat, err := s.browserShareChat(r)
		if err != nil {
			return nil, 0, err
		}
		sh, err := s.Q.LatestBrowserShareForChat(r.Context(), store.LatestBrowserShareForChatParams{ChatID: chat.ID, UserID: u.ID})
		if errors.Is(err, pgx.ErrNoRows) {
			return map[string]any{"share": nil}, http.StatusOK, nil
		}
		if err != nil {
			return nil, 0, err
		}
		out, err := s.browserShareOut(r.Context(), ws, sh)
		return map[string]any{"share": out}, http.StatusOK, err
	})

	person("POST /api/v1/chats/{id}/browser-share/stop", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		chat, err := s.browserShareChat(r)
		if err != nil {
			return nil, 0, err
		}
		active, err := s.Q.ActiveBrowserShareForChat(r.Context(), store.ActiveBrowserShareForChatParams{ChatID: chat.ID, UserID: u.ID})
		if errors.Is(err, pgx.ErrNoRows) {
			return map[string]any{"share": nil}, http.StatusOK, nil
		}
		if err != nil {
			return nil, 0, err
		}
		sh, err := s.browserExt().Stop(r.Context(), u.ID, active.ID, browserext.StopByPerson)
		if err != nil {
			return nil, 0, err
		}
		out, err := s.browserShareOut(r.Context(), ws, sh)
		return map[string]any{"share": out}, http.StatusOK, err
	})

	ext("GET "+browserExtensionPrefix+"config", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		return s.browserExtensionConfig(r.Context(), ws, u.ID)
	})

	ext("POST "+browserExtensionPrefix+"shares", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		var in struct {
			browserSnapshotIn
			ChatID            *uuid.UUID `json:"chat_id"`
			PersonaID         *uuid.UUID `json:"persona_id"`
			TabID             string     `json:"tab_id"`
			Until             string     `json:"until"`
			IncludeScreenshot bool       `json:"include_screenshot"`
		}
		if err := httpClientJSON(r, &in, 3<<20); err != nil {
			return nil, 0, err
		}
		snap, err := in.decode()
		if err != nil {
			return nil, 0, err
		}
		// Refuse a never-share page before a new chat is made for it.
		mine, err := s.browserExt().NeverShareList(r.Context(), u.ID)
		if err != nil {
			return nil, 0, err
		}
		if _, err := browserext.CheckURL(snap.URL, mine); err != nil || snap.Incognito {
			return nil, 0, browserPageError(browserext.ErrNotShareable)
		}
		chatID := uuid.Nil
		if in.ChatID != nil {
			chatID = *in.ChatID
		} else {
			title, _ := browserext.Clip("Safari: "+strings.Join(strings.Fields(snap.Title), " "), 200)
			chat, err := s.Runs.StartChat(r.Context(), ws, u.ID, runs.ChatInput{PersonaID: in.PersonaID, Title: title})
			if err != nil {
				return nil, 0, err
			}
			chatID = chat.ID
		}
		sh, err := s.browserExt().Start(r.Context(), ws, u.ID, browserext.StartInput{ChatID: chatID, TabID: in.TabID, Until: in.Until, IncludeScreenshot: in.IncludeScreenshot, Snapshot: snap})
		if err != nil {
			return nil, 0, browserPageError(err)
		}
		out, err := s.browserShareOut(r.Context(), ws, sh)
		return out, http.StatusCreated, err
	})

	ext("GET "+browserExtensionPrefix+"shares/{share}", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		id, err := httpClientID(r, "share")
		if err != nil {
			return nil, 0, err
		}
		sh, err := s.Q.GetBrowserShare(r.Context(), store.GetBrowserShareParams{ID: id, UserID: u.ID})
		if err != nil {
			return nil, 0, err
		}
		out, err := s.browserShareOut(r.Context(), ws, sh)
		return out, http.StatusOK, err
	})

	ext("POST "+browserExtensionPrefix+"shares/{share}/snapshot", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		id, err := httpClientID(r, "share")
		if err != nil {
			return nil, 0, err
		}
		var in browserSnapshotIn
		if err := httpClientJSON(r, &in, 3<<20); err != nil {
			return nil, 0, err
		}
		snap, err := in.decode()
		if err != nil {
			return nil, 0, err
		}
		sh, err := s.browserExt().Update(r.Context(), u.ID, id, snap)
		if err != nil {
			return nil, 0, browserPageError(err)
		}
		out, err := s.browserShareOut(r.Context(), ws, sh)
		return out, http.StatusOK, err
	})

	ext("POST "+browserExtensionPrefix+"shares/{share}/stop", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		id, err := httpClientID(r, "share")
		if err != nil {
			return nil, 0, err
		}
		var in struct {
			Reason string `json:"reason"`
		}
		if r.ContentLength != 0 {
			if err := httpClientJSON(r, &in, 1<<10); err != nil {
				return nil, 0, err
			}
		}
		sh, err := s.browserExt().Stop(r.Context(), u.ID, id, in.Reason)
		if err != nil {
			return nil, 0, err
		}
		out, err := s.browserShareOut(r.Context(), ws, sh)
		return out, http.StatusOK, err
	})

	ext("POST "+browserExtensionPrefix+"ask", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		var in struct {
			PersonaID *uuid.UUID `json:"persona_id"`
			Prompt    string     `json:"prompt"`
			URL       string     `json:"url"`
			Title     string     `json:"title"`
			Selection string     `json:"selection"`
			Incognito bool       `json:"incognito"`
		}
		if err := httpClientJSON(r, &in, 256<<10); err != nil {
			return nil, 0, err
		}
		prompt := strings.TrimSpace(in.Prompt)
		if prompt == "" {
			prompt = "Explain this."
		}
		if p, cut := browserext.Clip(prompt, browserext.MaxPromptRunes); cut {
			return nil, 0, apperr.Invalid("prompt", "at most %d characters", browserext.MaxPromptRunes)
		} else {
			prompt = p
		}
		sel, cut := browserext.Clip(in.Selection, browserext.MaxSelectionRunes)
		if cut {
			sel += "\n[cut: the selection was longer]"
		}
		if err := s.browserPageAllowed(r.Context(), u.ID, in.URL, in.Incognito); err != nil {
			return nil, 0, err
		}
		title := strings.Join(strings.Fields(in.Title), " ")
		chatTitle, _ := browserext.Clip(title, 200)
		msg := runs.ChatMessageInput{Body: browserext.AskMessage(prompt, title, in.URL, sel)}
		chat, err := s.Runs.StartChat(r.Context(), ws, u.ID, runs.ChatInput{PersonaID: in.PersonaID, Title: chatTitle, Message: &msg})
		if err != nil {
			return nil, 0, err
		}
		return map[string]any{"chat_id": chat.ID, "href": "/chat/" + chat.ID.String()}, http.StatusCreated, nil
	})

	ext("POST "+browserExtensionPrefix+"clip", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		var in struct {
			As        string `json:"as"`
			URL       string `json:"url"`
			Title     string `json:"title"`
			Selection string `json:"selection"`
			Incognito bool   `json:"incognito"`
		}
		if err := httpClientJSON(r, &in, 256<<10); err != nil {
			return nil, 0, err
		}
		if err := s.browserPageAllowed(r.Context(), u.ID, in.URL, in.Incognito); err != nil {
			return nil, 0, err
		}
		pu, _ := url.Parse(in.URL) // browserPageAllowed parsed it already.
		site := strings.TrimPrefix(pu.Hostname(), "www.")
		title, _ := browserext.Clip(strings.Join(strings.Fields(in.Title), " "), browserext.MaxTitleRunes)
		if title == "" {
			title = site + strings.TrimRight(pu.Path, "/")
		}
		sel, _ := browserext.Clip(in.Selection, browserext.MaxSelectionRunes)
		switch in.As {
		case "link":
			if !linkpreview.Valid(in.URL) {
				return nil, 0, apperr.Invalid("url", "use an http(s) address with a host, at most 2048 characters")
			}
			if l, err := s.Q.GetLibraryLink(r.Context(), store.GetLibraryLinkParams{WorkspaceID: ws, UserID: u.ID, Url: in.URL}); err == nil {
				return map[string]any{"kind": "link", "id": l.ID, "href": "/library", "state": "already_saved"}, http.StatusOK, nil
			} else if !errors.Is(err, pgx.ErrNoRows) {
				return nil, 0, err
			}
			note, _ := browserext.Clip(strings.TrimSpace(sel), 300)
			video, _ := transcript.VideoID(in.URL)
			l, err := s.Q.CreateLibraryLink(r.Context(), store.CreateLibraryLinkParams{WorkspaceID: ws, UserID: u.ID, Title: title, ContentType: "link", Url: in.URL, Note: note, Site: site, VideoID: video})
			if err != nil {
				return nil, 0, err
			}
			return map[string]any{"kind": "link", "id": l.ID, "href": "/library", "state": "saved"}, http.StatusCreated, nil
		case "note":
			props := artifacts.Properties{"type": "literature", "source": in.URL, "source_title": title, "source_site": site, "clipped_from": "safari"}
			save := wiki.Save{AutoPath: true, Folder: clippingsFolder, Title: &title, Body: browserext.ClipBody(title, in.URL, sel), Properties: props, Mode: wiki.ModeCreate}
			res, err := s.Wiki.SaveAsUser(r.Context(), ws, u.ID, save)
			if err != nil {
				return nil, 0, err
			}
			return map[string]any{"kind": "note", "id": res.Note.ID, "href": "/knowledge/" + res.Note.ID.String(), "state": "saved"}, http.StatusCreated, nil
		}
		return nil, 0, apperr.Invalid("as", "note or link")
	})

	ext("POST "+browserExtensionPrefix+"never-share", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		var in struct {
			Host string `json:"host"`
		}
		if err := httpClientJSON(r, &in, 4<<10); err != nil {
			return nil, 0, err
		}
		host, ok := browserext.NormalizeHost(in.Host)
		if !ok {
			return nil, 0, apperr.Invalid("host", "a site like bank.example.com")
		}
		if err := s.Q.AddBrowserNeverShare(r.Context(), store.AddBrowserNeverShareParams{UserID: u.ID, Host: host}); err != nil {
			return nil, 0, err
		}
		// A share already showing that site ends now, not at its next snapshot.
		active, err := s.Q.ActiveBrowserShares(r.Context(), u.ID)
		if err != nil {
			return nil, 0, err
		}
		for _, sh := range active {
			if _, err := browserext.CheckURL(sh.Url, []string{host}); err != nil {
				if _, err := s.browserExt().Stop(r.Context(), u.ID, sh.ID, browserext.StopNeverShare); err != nil {
					return nil, 0, err
				}
			}
		}
		return s.browserExtensionConfig(r.Context(), ws, u.ID)
	})

	ext("DELETE "+browserExtensionPrefix+"never-share/{host}", func(r *http.Request) (any, int, error) {
		u, _, ws := me(r.Context())
		host, ok := browserext.NormalizeHost(r.PathValue("host"))
		if !ok {
			return nil, 0, apperr.Invalid("host", "a site like bank.example.com")
		}
		if _, err := s.Q.RemoveBrowserNeverShare(r.Context(), store.RemoveBrowserNeverShareParams{UserID: u.ID, Host: host}); err != nil {
			return nil, 0, err
		}
		return s.browserExtensionConfig(r.Context(), ws, u.ID)
	})
}

// browserShareChat is the {id} chat of a chat route, when it's the caller's.
func (s *Server) browserShareChat(r *http.Request) (store.ChatSession, error) {
	id, err := httpClientID(r, "id")
	if err != nil {
		return store.ChatSession{}, err
	}
	return s.ownChat(r.Context(), id)
}

// browserPageAllowed refuses a page the extension may not send anywhere.
func (s *Server) browserPageAllowed(ctx context.Context, userID uuid.UUID, pageURL string, incognito bool) error {
	if incognito {
		return browserPageError(browserext.ErrNotShareable)
	}
	mine, err := s.browserExt().NeverShareList(ctx, userID)
	if err != nil {
		return err
	}
	_, err = browserext.CheckURL(pageURL, mine)
	return browserPageError(err)
}

type browserPersonaOut struct {
	ID        uuid.UUID `json:"id"`
	Name      string    `json:"name"`
	IsDefault bool      `json:"is_default"`
}

type browserChatOut struct {
	ID        uuid.UUID  `json:"id"`
	Title     string     `json:"title"`
	PersonaID *uuid.UUID `json:"persona_id"`
}

// browserExtensionConfig is everything the popover shows: who to share with
// or ask, the never-share lists, and the tabs being shared.
func (s *Server) browserExtensionConfig(ctx context.Context, ws, userID uuid.UUID) (any, int, error) {
	personas, err := s.Q.ListPersonas(ctx, store.ListPersonasParams{WorkspaceID: ws, UserID: userID})
	if err != nil {
		return nil, 0, err
	}
	chats, err := s.Q.RecentBrowserShareChats(ctx, store.RecentBrowserShareChatsParams{WorkspaceID: ws, CreatedBy: userID})
	if err != nil {
		return nil, 0, err
	}
	mine, err := s.browserExt().NeverShareList(ctx, userID)
	if err != nil {
		return nil, 0, err
	}
	active, err := s.Q.ActiveBrowserShares(ctx, userID)
	if err != nil {
		return nil, 0, err
	}
	out := struct {
		Personas   []browserPersonaOut `json:"personas"`
		Chats      []browserChatOut    `json:"chats"`
		NeverShare struct {
			Builtin []string `json:"builtin"`
			Mine    []string `json:"mine"`
		} `json:"never_share"`
		Shares []browserShareOut `json:"shares"`
	}{Personas: []browserPersonaOut{}, Chats: []browserChatOut{}, Shares: []browserShareOut{}}
	for _, p := range personas {
		out.Personas = append(out.Personas, browserPersonaOut{ID: p.ID, Name: p.Name, IsDefault: p.IsDefault})
	}
	for _, c := range chats {
		out.Chats = append(out.Chats, browserChatOut{ID: c.ID, Title: c.Title, PersonaID: c.PersonaID})
	}
	out.NeverShare.Builtin, out.NeverShare.Mine = browserext.BuiltinNeverShare, mine
	for _, sh := range active {
		o, err := s.browserShareOut(ctx, ws, sh)
		if err != nil {
			return nil, 0, err
		}
		out.Shares = append(out.Shares, o)
	}
	return out, http.StatusOK, nil
}
