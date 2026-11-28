package runs

import (
	"context"
	"errors"
	"fmt"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// ChatEditOptions carries optional model/harness/effort overrides when redoing
// or regenerating the last turn.
type ChatEditOptions struct {
	Harness string
	Model   string
	Effort  string
}

// editQuoteRunes bounds how much of the replaced message the new turn quotes.
const editQuoteRunes = 2000

// editNote tells the persona the turn is being redone. The harness session
// still holds the old turn, and whatever it did to files or through tools has
// happened, so it can't simply vanish; the stored message is only what the
// person wrote.
func editNote(previous, body string) string {
	if previous == body {
		return "(Vesper: the person asked you to try your last reply again. It has been removed from the chat, so answer their message afresh; anything it changed in files or through tools is still in place.)\n\n"
	}
	if r := []rune(previous); len(r) > editQuoteRunes {
		previous = string(r[:editQuoteRunes]) + "…"
	}
	return fmt.Sprintf("(Vesper: the person edited their last message and is redoing that turn. Your reply to the earlier version has been removed from the chat, so answer this version instead; anything it changed in files or through tools is still in place. The earlier version was:\n> %s)\n\n", strings.ReplaceAll(previous, "\n", "\n> "))
}

// EditLastChatMessage replaces the person's newest message and everything
// after it with a new turn on the edited text. Sending the same text retries
// the turn. Its attachments and context stay with the message.
func (s *Service) EditLastChatMessage(ctx context.Context, ws, user, id uuid.UUID, body string, opts ...ChatEditOptions) (store.ChatMessage, error) {
	var out store.ChatMessage
	var opt ChatEditOptions
	if len(opts) > 0 {
		opt = opts[0]
	}
	body = strings.TrimSpace(body)
	if body == "" || len([]rune(body)) > 100000 {
		return out, apperr.Invalid("body", "provide 1–100000 characters")
	}
	err := s.tx(ctx, func(q *store.Queries) error {
		chat, err := lockChat(ctx, q, ws, user, id)
		if err != nil {
			return err
		}
		if chat.Archived {
			return apperr.Conflict("the chat is archived")
		}
		if chat.State == "running" || chat.InterruptMessageID != nil {
			return apperr.Conflict("wait for the reply to finish, or stop it first")
		}
		p, err := chatProject(ctx, q, chat)
		if err != nil {
			return err
		}
		if p.Archived {
			return apperr.Conflict("restore the archived project before chatting")
		}
		if opt.Harness != "" || opt.Model != "" || opt.Effort != "" {
			cur := chatmodels.Selection{Harness: chat.Harness, Model: chat.Model, Effort: chat.Effort, AutoModel: chat.AutoModel}
			sel, err := s.ChatCatalog().Resolve(ctx, q, chat.WorkspaceID, cur, chatmodels.Selection{Harness: opt.Harness, Model: opt.Model, Effort: opt.Effort})
			if err != nil {
				return err
			}
			if sel != cur {
				if chat, err = q.SetChatSelection(ctx, store.SetChatSelectionParams{ID: chat.ID, Harness: sel.Harness, Model: sel.Model, Effort: sel.Effort, AutoModel: sel.AutoModel}); err != nil {
					return err
				}
			}
		}
		last, err := q.LastChatUserMessage(ctx, chat.ID)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("there's no message to edit yet")
		} else if err != nil {
			return err
		}
		if err := q.DeleteChatMessagesAfter(ctx, store.DeleteChatMessagesAfterParams{SessionID: chat.ID, Seq: last.Seq}); err != nil {
			return err
		}
		if err := q.SetChatMessageBody(ctx, store.SetChatMessageBodyParams{ID: last.ID, BodyMd: body}); err != nil {
			return err
		}
		speaker, queue, err := routeHumanMessage(ctx, q, chat, body)
		if err != nil {
			return err
		}
		if chat, err = q.SetChatSpeaker(ctx, store.SetChatSpeakerParams{ID: chat.ID, SpeakerPersonaID: speaker, QueuedPersonaIds: queue, RelayTurns: 0, RelayLimit: int32(RelayLimitIn(body))}); err != nil {
			return err
		}
		_, run, turn, err := startClassifiedChatTurn(ctx, q, chat, p.Key, editNote(last.BodyMd, body)+body, body, false, true, s.HandoffChars)
		if err != nil {
			return err
		}
		if err := q.SetChatMessageTurn(ctx, store.SetChatMessageTurnParams{ID: last.ID, RunID: &run.ID, RunTurnID: &turn.ID, Harness: &run.Harness, Model: &run.Model}); err != nil {
			return err
		}
		out, err = q.GetChatMessage(ctx, last.ID)
		return err
	})
	return out, err
}
