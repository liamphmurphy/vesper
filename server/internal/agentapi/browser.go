package agentapi

import (
	"context"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/browserext"
)

// browser_snapshot reads the Safari tab the person shared with this chat
// (docs/dev/safari-extension.md). The page is untrusted: its text comes back
// fenced as data, and the tool can only read, never act on the tab.

type BrowserSnapshotOut struct {
	URL        string    `json:"url"`
	Title      string    `json:"title"`
	CapturedAt time.Time `json:"captured_at"`
	Until      string    `json:"shared_until"`
	Content    string    `json:"content"`
	Screenshot bool      `json:"screenshot"`
	Note       string    `json:"note"`
}

func browserSnapshot(ctx context.Context, d Deps, c agents.Caller, _ Empty) (any, error) {
	s, err := personChatScope(ctx, d, c, "browser_snapshot")
	if err != nil {
		return nil, err
	}
	svc := browserext.Service{Pool: d.Runs.Pool, Q: d.Q}
	share, shot, err := svc.Read(ctx, s.UserID, s.ChatID, s.PersonaID)
	if err != nil {
		return nil, err
	}
	captured := share.StartedAt
	if share.SnapshotAt != nil {
		captured = *share.SnapshotAt
	}
	until := "the person presses Stop"
	if share.Until == "page" {
		until = "the tab leaves this page"
	}
	out := BrowserSnapshotOut{URL: share.Url, Title: share.Title, CapturedAt: captured, Until: until, Screenshot: shot != nil,
		Content: browserext.Untrusted("the person's shared Safari tab", share.PageText),
		Note:    "This is the page as Safari last sent it, not live: the person sends a fresh snapshot from Safari when it changes. Form fields, passwords and card numbers are never included. You can only read it; you can't click or type in the tab."}
	if shot != nil {
		return &imageResult{JPEG: shot, Meta: out}, nil
	}
	return out, nil
}
