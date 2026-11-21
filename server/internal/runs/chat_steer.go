package runs

import (
	"context"
	"errors"
	"strings"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const maxChatSteerRunes = 20000

// SteerChat queues a mid-turn steering message for an active chat turn. It
// records the user message once in chat_messages and writes a pending
// chat_steers row that the runner injects into the live session (or falls back
// to an interrupt/next turn if the harness cannot steer mid-turn).
func (s *Service) SteerChat(ctx context.Context, ws, user, id uuid.UUID, body string) (store.ChatSteer, store.ChatMessage, error) {
	var steer store.ChatSteer
	var msg store.ChatMessage
	body = strings.TrimSpace(body)
	if body == "" || len([]rune(body)) > maxChatSteerRunes {
		return steer, msg, apperr.Invalid("body", "provide 1–20000 characters")
	}
	err := s.tx(ctx, func(q *store.Queries) error {
		chat, err := lockChat(ctx, q, ws, user, id)
		if err != nil {
			return err
		}
		if chat.Archived {
			return apperr.Conflict("the chat is archived")
		}
		if chat.ParentChatID != nil {
			return apperr.Conflict("an aside answers one question; ask another aside instead")
		}
		if chat.State != "running" || chat.CurrentRunID == nil {
			return apperr.Conflict("no reply is running to steer; send it as a normal message")
		}
		if chat.InterruptMessageID != nil {
			return apperr.Conflict("still stopping the reply for your last message; send this again in a moment")
		}
		appended, err := q.AppendChatMessage(ctx, store.AppendChatMessageParams{
			SessionID:   chat.ID,
			Role:        "user",
			BodyMd:      body,
			ContextRefs: []byte("[]"),
			Citations:   []byte("[]"),
		})
		if err != nil {
			return err
		}
		msg = store.ChatMessage(appended)
		steer, err = q.CreateChatSteer(ctx, store.CreateChatSteerParams{
			SessionID: chat.ID,
			RunID:     *chat.CurrentRunID,
			MessageID: msg.ID,
			Body:      body,
		})
		if err != nil {
			return err
		}
		_, err = q.BumpChatRevision(ctx, chat.ID)
		return err
	})
	return steer, msg, err
}

// ListPendingChatApprovals returns open live tool approval requests owned by
// the caller's chat.
func (s *Service) ListPendingChatApprovals(ctx context.Context, ws, user, id uuid.UUID) ([]store.ApprovalRequest, error) {
	q := store.New(s.Pool)
	chat, err := readOwnChat(ctx, q, ws, user, id)
	if err != nil {
		return nil, err
	}
	return q.ListPendingApprovalsForChat(ctx, chat.ID)
}

// FallbackChatSteerToInterrupt converts a steer that the active harness session
// could not accept mid-turn into a clean turn interruption while preserving the
// single user message already written by SteerChat. It reports whether a live
// turn was paused so the runner can stop the process immediately. The caller
// must NOT hold chat or run locks; this function acquires chat before run.
func FallbackChatSteerToInterrupt(ctx context.Context, q *store.Queries, chatID, runID, steerID, messageID uuid.UUID, handoffChars int) (bool, error) {
	chat, err := q.LockChatSessionByID(ctx, chatID)
	if err != nil {
		return false, err
	}
	if err := q.MarkChatSteerState(ctx, store.MarkChatSteerStateParams{ID: steerID, State: "fallback"}); err != nil {
		return false, err
	}
	if chat.Archived || chat.CurrentRunID == nil || *chat.CurrentRunID != runID {
		return false, nil
	}
	if chat.State != "running" {
		// The turn already settled while we were failing over; answer the
		// already-saved message on the next turn without duplicating it.
		return false, startTurnForExistingChatMessage(ctx, q, chat, messageID, false, "", handoffChars)
	}
	if chat.InterruptMessageID != nil {
		return false, nil
	}
	var stopped bool
	var dropped *store.RunTurn
	chat, stopped, dropped, err = stopChatTurn(ctx, q, chat)
	if err != nil {
		return false, err
	}
	if !stopped {
		_, err = q.SetChatInterrupt(ctx, store.SetChatInterruptParams{ID: chat.ID, InterruptMessageID: &messageID})
		return true, err
	}
	note := replacedTurnNote(dropped)
	if note == "" {
		if note, err = interruptNote(ctx, q, chat, lastUserSeq, nil, nil); err != nil {
			return false, err
		}
	}
	return false, startTurnForExistingChatMessage(ctx, q, chat, messageID, true, note, handoffChars)
}

// ResumePendingChatSteer runs in the runner's transaction at turn completion:
// if a steer stayed pending (for example because the turn finished right before
// supervise delivered it), it starts a follow-up turn bound to that steer's
// already-saved user message without duplicating it.
func ResumePendingChatSteer(ctx context.Context, q *store.Queries, chatID, runID uuid.UUID, handoffChars int) error {
	chat, err := q.LockChatSessionByID(ctx, chatID)
	if err != nil {
		return err
	}
	if chat.Archived || chat.State != "idle" || chat.InterruptMessageID != nil {
		return nil
	}
	steer, err := q.TakeNextPendingChatSteer(ctx, runID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	return startTurnForExistingChatMessage(ctx, q, chat, steer.MessageID, false, "", handoffChars)
}

func startTurnForExistingChatMessage(ctx context.Context, q *store.Queries, chat store.ChatSession, messageID uuid.UUID, interrupted bool, prefix string, handoffChars int) error {
	if chat.Archived || chat.State != "idle" {
		return nil
	}
	p, err := chatProject(ctx, q, chat)
	if err != nil || p.Archived {
		return err
	}
	msg, err := q.GetChatMessage(ctx, messageID)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil
	}
	if err != nil {
		return err
	}
	speaker, queue, err := routeHumanMessage(ctx, q, chat, msg.BodyMd)
	if err != nil {
		return err
	}
	if chat, err = q.SetChatSpeaker(ctx, store.SetChatSpeakerParams{
		ID: chat.ID, SpeakerPersonaID: speaker, QueuedPersonaIds: queue,
		RelayTurns: 0, RelayLimit: int32(RelayLimitIn(msg.BodyMd)),
	}); err != nil {
		return err
	}
	_, run, turn, err := startClassifiedChatTurn(ctx, q, chat, p.Key, prefix+msg.BodyMd, msg.BodyMd, interrupted, false, handoffChars)
	if err != nil {
		return err
	}
	return q.SetChatMessageTurn(ctx, store.SetChatMessageTurnParams{
		ID: msg.ID, RunID: &run.ID, RunTurnID: &turn.ID, Harness: &run.Harness, Model: &run.Model,
	})
}
