package browserext

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Service runs the share lifecycle. Every method takes the acting person's
// user id and only touches their shares and chats.
type Service struct {
	Pool *pgxpool.Pool
	Q    *store.Queries
}

// Share ends, as stored in browser_shares.stop_reason.
const (
	StopByPerson   = "stopped"
	StopTabClosed  = "tab_closed"
	StopLeftPage   = "left_page"
	StopNeverShare = "never_share"
	StopReplaced   = "replaced"
)

var stopReasons = []string{StopByPerson, StopTabClosed, StopLeftPage, StopNeverShare}

// ErrStopped is a snapshot for a share that has ended.
var ErrStopped = apperr.Conflict("sharing this tab has stopped; share it again from Safari")

// Snapshot is what the extension read from a tab. Screenshot is a JPEG,
// already decoded; nil when the share leaves screenshots out.
type Snapshot struct {
	URL        string
	Title      string
	Text       string
	Screenshot []byte
	Incognito  bool
}

// clean validates a snapshot against the never-share lists and trims it to
// the limits.
func (s Snapshot) clean(mine []string) (Snapshot, error) {
	if s.Incognito {
		return s, ErrNotShareable
	}
	if _, err := CheckURL(s.URL, mine); err != nil {
		return s, err
	}
	s.Title, _ = Clip(strings.Join(strings.Fields(s.Title), " "), MaxTitleRunes)
	if text, cut := Clip(s.Text, MaxTextRunes); cut {
		s.Text = text + "\n\n[Vesper cut the page here: it was longer than " + fmt.Sprint(MaxTextRunes) + " characters.]"
	}
	if s.Screenshot != nil {
		if len(s.Screenshot) > MaxScreenshotBytes {
			return s, apperr.Invalid("screenshot", "at most %d bytes", MaxScreenshotBytes)
		}
		if !bytes.HasPrefix(s.Screenshot, []byte{0xFF, 0xD8, 0xFF}) {
			return s, apperr.Invalid("screenshot", "must be a JPEG")
		}
	}
	return s, nil
}

// NeverShareList is the person's own never-share hosts (the built-in ones
// apply as well).
func (s *Service) NeverShareList(ctx context.Context, userID uuid.UUID) ([]string, error) {
	return s.Q.ListBrowserNeverShare(ctx, userID)
}

// StartInput shares a tab with a chat the person owns.
type StartInput struct {
	ChatID            uuid.UUID
	TabID             string
	Until             string
	IncludeScreenshot bool
	Snapshot          Snapshot
}

// Start shares a tab with a chat, ending whatever that tab or chat shared
// before, and tells the chat in a system message.
func (s *Service) Start(ctx context.Context, ws, userID uuid.UUID, in StartInput) (store.BrowserShare, error) {
	var share store.BrowserShare
	if in.Until != "page" && in.Until != "stop" {
		return share, apperr.Invalid("until", "page or stop")
	}
	if in.TabID = strings.TrimSpace(in.TabID); in.TabID == "" || len(in.TabID) > 64 {
		return share, apperr.Invalid("tab_id", "1 to 64 characters")
	}
	mine, err := s.NeverShareList(ctx, userID)
	if err != nil {
		return share, err
	}
	snap, err := in.Snapshot.clean(mine)
	if err != nil {
		return share, err
	}
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := s.Q.WithTx(tx)
		chat, err := q.GetChatSession(ctx, store.GetChatSessionParams{ID: in.ChatID, WorkspaceID: ws})
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && (chat.CreatedBy != userID || chat.Archived)) {
			return apperr.Invalid("chat_id", "not one of your open chats")
		}
		if err != nil {
			return err
		}
		if err = q.StopBrowserSharesForTab(ctx, store.StopBrowserSharesForTabParams{UserID: userID, TabID: in.TabID}); err != nil {
			return err
		}
		if err = q.StopBrowserSharesForChat(ctx, chat.ID); err != nil {
			return err
		}
		share, err = q.CreateBrowserShare(ctx, store.CreateBrowserShareParams{WorkspaceID: ws, UserID: userID, ChatID: chat.ID, TabID: in.TabID, StartUrl: snap.URL,
			Until: in.Until, IncludeScreenshot: in.IncludeScreenshot, Title: snap.Title, PageText: snap.Text})
		if err != nil {
			return err
		}
		if in.IncludeScreenshot && snap.Screenshot != nil {
			if err = q.SetBrowserShareScreenshot(ctx, store.SetBrowserShareScreenshotParams{ShareID: share.ID, Jpeg: snap.Screenshot}); err != nil {
				return err
			}
		}
		return appendSystem(ctx, q, chat.ID, startedNote(share))
	})
	return share, err
}

func startedNote(sh store.BrowserShare) string {
	title := sh.Title
	if title == "" {
		title = sh.Url
	}
	until := "until you press Stop in Safari or here"
	if sh.Until == "page" {
		until = "until you leave that page"
	}
	return "You shared a Safari tab with this chat: " + mdLink(title, sh.Url) + ". It can be read with browser_snapshot " + until + "."
}

func appendSystem(ctx context.Context, q *store.Queries, chatID uuid.UUID, body string) error {
	_, err := q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chatID, Role: "system", BodyMd: body, ContextRefs: []byte("[]"), Citations: []byte("[]")})
	return err
}

// Update stores a fresh snapshot of a shared tab. A snapshot of a page the
// share may not cover ends the share instead: a never-share site, a private
// window, or (for a share until the page changes) another page.
func (s *Service) Update(ctx context.Context, userID, shareID uuid.UUID, in Snapshot) (store.BrowserShare, error) {
	share, err := s.Q.GetBrowserShare(ctx, store.GetBrowserShareParams{ID: shareID, UserID: userID})
	if err != nil {
		return share, err
	}
	if share.StoppedAt != nil {
		return share, ErrStopped
	}
	mine, err := s.NeverShareList(ctx, userID)
	if err != nil {
		return share, err
	}
	snap, err := in.clean(mine)
	if errors.Is(err, ErrNotShareable) {
		if _, stopErr := s.Stop(ctx, userID, shareID, StopNeverShare); stopErr != nil {
			return share, stopErr
		}
		return share, ErrStopped
	}
	if err != nil {
		return share, err
	}
	if share.Until == "page" && !SamePage(share.StartUrl, snap.URL) {
		if _, err := s.Stop(ctx, userID, shareID, StopLeftPage); err != nil {
			return share, err
		}
		return share, ErrStopped
	}
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := s.Q.WithTx(tx)
		share, err = q.UpdateBrowserShareSnapshot(ctx, store.UpdateBrowserShareSnapshotParams{ID: shareID, UserID: userID, Url: snap.URL, Title: snap.Title, PageText: snap.Text})
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrStopped // stopped since we read it
		}
		if err != nil {
			return err
		}
		if share.IncludeScreenshot && snap.Screenshot != nil {
			return q.SetBrowserShareScreenshot(ctx, store.SetBrowserShareScreenshotParams{ShareID: share.ID, Jpeg: snap.Screenshot})
		}
		return q.ClearBrowserShareScreenshot(ctx, share.ID)
	})
	return share, err
}

// Stop ends a share and tells its chat. Stopping one that already ended
// returns it unchanged.
func (s *Service) Stop(ctx context.Context, userID, shareID uuid.UUID, reason string) (store.BrowserShare, error) {
	if reason == "" {
		reason = StopByPerson
	}
	var share store.BrowserShare
	if !contains(stopReasons, reason) {
		return share, apperr.Invalid("reason", "one of %s", strings.Join(stopReasons, ", "))
	}
	err := pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		q := s.Q.WithTx(tx)
		var err error
		share, err = q.StopBrowserShare(ctx, store.StopBrowserShareParams{ID: shareID, UserID: userID, StopReason: reason})
		if errors.Is(err, pgx.ErrNoRows) {
			share, err = q.GetBrowserShare(ctx, store.GetBrowserShareParams{ID: shareID, UserID: userID})
			return err // already stopped, or not theirs (ErrNoRows → 404)
		}
		if err != nil {
			return err
		}
		if err = q.ClearBrowserShareScreenshot(ctx, share.ID); err != nil {
			return err
		}
		return appendSystem(ctx, q, share.ChatID, stoppedNote(reason))
	})
	return share, err
}

func stoppedNote(reason string) string {
	switch reason {
	case StopTabClosed:
		return "Stopped sharing the Safari tab: it was closed."
	case StopLeftPage:
		return "Stopped sharing the Safari tab: it left the shared page."
	case StopNeverShare:
		return "Stopped sharing the Safari tab: it went to a site that is never shared, or a private window."
	}
	return "Stopped sharing the Safari tab."
}

func contains(xs []string, x string) bool {
	for _, v := range xs {
		if v == x {
			return true
		}
	}
	return false
}

// Read is browser_snapshot: the chat's shared tab as last sent, recorded in
// the share's read log. The screenshot is nil unless the share includes one.
func (s *Service) Read(ctx context.Context, userID, chatID uuid.UUID, personaID *uuid.UUID) (store.BrowserShare, []byte, error) {
	share, err := s.Q.ActiveBrowserShareForChat(ctx, store.ActiveBrowserShareForChatParams{ChatID: chatID, UserID: userID})
	if errors.Is(err, pgx.ErrNoRows) {
		return share, nil, apperr.Conflict("no Safari tab is shared with this chat right now; the person shares one from the Vesper button in Safari's toolbar")
	}
	if err != nil {
		return share, nil, err
	}
	var shot []byte
	if share.IncludeScreenshot {
		shot, err = s.Q.GetBrowserShareScreenshot(ctx, share.ID)
		if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return share, nil, err
		}
	}
	if _, err = s.Q.RecordBrowserShareRead(ctx, store.RecordBrowserShareReadParams{ShareID: share.ID, ChatID: chatID, PersonaID: personaID, Url: share.Url}); err != nil {
		return share, nil, err
	}
	return share, shot, nil
}
