package agentapi

import (
	"context"
	"encoding/base64"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agents"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// FileKeeper stores a file in a person's Library. The HTTP server implements
// it, since it holds the object store the Library's files live in.
type FileKeeper interface {
	KeepChatFile(ctx context.Context, userID, ws uuid.UUID, chatID, personaID *uuid.UUID, title, filename string, data []byte) (store.LibraryItem, error)
	KeepChatFileWithDetail(ctx context.Context, userID, ws uuid.UUID, chatID, personaID *uuid.UUID, title, filename, detail string, data []byte) (store.LibraryItem, error)
}

type SaveFileIn struct {
	Filename string `json:"filename" jsonschema:"The file's name with its extension, e.g. render_riff.py or payouts-q3.csv"`
	Title    string `json:"title,omitempty" jsonschema:"What to call it in the Library; the file name when omitted"`
	Text     string `json:"text,omitempty" jsonschema:"The file's contents, when it is text (code, CSV, JSON, Markdown)"`
	Data     string `json:"data,omitempty" jsonschema:"Or the file's bytes, base64-encoded, for a binary such as a zip or spreadsheet; at most 25 MB"`
}

// saveFile keeps a file the persona made in the person's Library, from the chat
// it's answering. It is only ever kept, never run or opened: the Library lists a
// zip, previews text and offers a download, and refuses executables.
func saveFile(ctx context.Context, d Deps, c agents.Caller, in SaveFileIn) (any, error) {
	scope, err := personChatScope(ctx, d, c, "save_file")
	if err != nil {
		return nil, err
	}
	if d.Files == nil {
		return nil, apperr.Conflict("saving files isn't available here")
	}
	name := runs.ChatAttachmentName(in.Filename)
	if strings.TrimSpace(in.Filename) == "" || name == "" {
		return nil, apperr.Invalid("filename", "is required")
	}
	if (in.Text == "") == (in.Data == "") {
		return nil, apperr.Invalid("text", "give either text or data")
	}
	var raw []byte
	if in.Text != "" {
		raw = []byte(in.Text)
	} else {
		if base64.StdEncoding.DecodedLen(len(in.Data)) > runs.MaxChatAttachmentBytes+3 {
			return nil, apperr.Invalid("data", "is over the 25 MB limit")
		}
		raw, err = base64.StdEncoding.DecodeString(strings.TrimSpace(in.Data))
		if err != nil {
			return nil, apperr.Invalid("data", "isn't valid base64: %v", err)
		}
	}
	l, err := d.Files.KeepChatFile(ctx, scope.UserID, c.Agent.WorkspaceID, &scope.ChatID, scope.PersonaID, in.Title, name, raw)
	if err != nil {
		return nil, err
	}
	return map[string]any{"library_item_id": l.ID, "title": l.Title, "filename": l.Filename, "size_bytes": l.SizeBytes, "detail": l.Detail,
		"tell_the_person": "Saved to the person's Library under Files. Say what you saved and why; don't paste its contents again."}, nil
}
