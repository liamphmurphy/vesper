package runs

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	maxCompactFocusChars = 500
	maxGitBriefFiles     = 30
)

type briefCommit struct {
	SHA     string `json:"sha"`
	Subject string `json:"subject"`
}

type briefFile struct {
	Path    string `json:"path"`
	OldPath string `json:"old_path"`
	Status  string `json:"status"`
}

// buildChatGitBrief summarizes persisted branch, commit, and changed-file state
// for a coding chat so a compacted or forked prompt starts grounded in the
// repository state without a runner round-trip.
func buildChatGitBrief(ctx context.Context, q *store.Queries, chatID uuid.UUID) (string, error) {
	reviews, err := q.ChatCodeReviews(ctx, chatID)
	if err != nil {
		return "", err
	}
	if len(reviews) == 0 {
		return "", nil
	}
	var b strings.Builder
	remainingFiles := maxGitBriefFiles
	for _, r := range reviews {
		if r.Branch == nil && r.HeadSha == nil && !r.Dirty && len(r.Files) <= 2 && len(r.Commits) <= 2 {
			continue
		}
		fmt.Fprintf(&b, "- Repository: %s", r.RepoUrl)
		if r.Branch != nil && *r.Branch != "" {
			fmt.Fprintf(&b, " (branch: %s)", *r.Branch)
		}
		if r.HeadSha != nil && *r.HeadSha != "" {
			fmt.Fprintf(&b, " [HEAD %s]", shortSHA(*r.HeadSha))
		}
		if r.Dirty {
			b.WriteString(" [uncommitted working tree changes]")
		}
		b.WriteByte('\n')

		var commits []briefCommit
		if len(r.Commits) > 0 {
			_ = json.Unmarshal(r.Commits, &commits)
		}
		if len(commits) > 0 {
			latest := commits[len(commits)-1]
			fmt.Fprintf(&b, "  commits ahead (%d): latest %s %s\n", len(commits), shortSHA(latest.SHA), strings.TrimSpace(latest.Subject))
		}

		var files []briefFile
		if len(r.Files) > 0 {
			_ = json.Unmarshal(r.Files, &files)
		}
		if len(files) > 0 {
			shown := 0
			for _, f := range files {
				if remainingFiles <= 0 {
					break
				}
				label := f.Path
				if f.OldPath != "" && f.OldPath != f.Path {
					label = f.OldPath + " -> " + f.Path
				}
				fmt.Fprintf(&b, "  - %s: %s\n", f.Status, label)
				remainingFiles--
				shown++
			}
			if extra := len(files) - shown; extra > 0 {
				fmt.Fprintf(&b, "  - (+%d more files)\n", extra)
			}
		}
	}
	return strings.TrimSpace(b.String()), nil
}

func effectiveAutoRollover(chat store.ChatSession, serverDefault int64) int64 {
	if chat.AutoRolloverTokens != nil {
		return *chat.AutoRolloverTokens
	}
	return serverDefault
}

// CompactChat resets the active harness CLI session while keeping the existing
// run and workspace volume intact, arming a fresh compacted context window
// (plus optional focus note and git state brief) on the next turn.
func (s *Service) CompactChat(ctx context.Context, ws, user, id uuid.UUID, focus string) (store.ChatSession, error) {
	focus = strings.TrimSpace(focus)
	if utf8.RuneCountInString(focus) > maxCompactFocusChars {
		return store.ChatSession{}, apperr.Invalid("focus", "must be at most %d characters", maxCompactFocusChars)
	}
	var out store.ChatSession
	err := s.tx(ctx, func(q *store.Queries) error {
		chat, err := lockChat(ctx, q, ws, user, id)
		if err != nil {
			return err
		}
		if chat.Archived {
			return apperr.Conflict("the chat is archived")
		}
		if chat.State == "running" {
			return apperr.Conflict("wait for the current reply to finish before compacting")
		}
		total, err := q.CountChatHistory(ctx, chat.ID)
		if err != nil {
			return err
		}
		if total == 0 && chat.CurrentRunID == nil {
			return apperr.Invalid("chat", "nothing to compact yet")
		}
		if chat.CurrentRunID != nil {
			run, err := q.LockRun(ctx, *chat.CurrentRunID)
			if err != nil {
				return err
			}
			prevTokens := run.ContextTokens
			if err := q.SetRunSession(ctx, store.SetRunSessionParams{ID: run.ID, HarnessSessionID: nil}); err != nil {
				return err
			}
			if err := q.SetRunContextTokens(ctx, store.SetRunContextTokensParams{ID: run.ID, ContextTokens: 0}); err != nil {
				return err
			}
			if err := event(ctx, q, run.ID, "lifecycle", map[string]any{
				"state":                   "chat_compacted",
				"reason":                  "manual",
				"focus":                   focus,
				"previous_context_tokens": prevTokens,
			}); err != nil {
				return err
			}
		}
		chat, err = q.SetChatCompactPending(ctx, store.SetChatCompactPendingParams{
			ID:             chat.ID,
			CompactPending: true,
			CompactFocus:   focus,
		})
		if err != nil {
			return err
		}
		note := "Context compacted — next turn starts a fresh context window keeping your workspace."
		if focus != "" {
			note += " Focus: " + focus
		}
		appended, err := q.AppendChatMessage(ctx, store.AppendChatMessageParams{
			SessionID:   chat.ID,
			Role:        "system",
			BodyMd:      note,
			RunID:       chat.CurrentRunID,
			ContextRefs: []byte("[]"),
			Citations:   []byte("[]"),
		})
		if err != nil {
			return err
		}
		chat.LastMessageAt = &appended.CreatedAt
		chat.UpdatedAt = appended.CreatedAt
		out = chat
		return nil
	})
	return out, err
}

func buildCompactOrForkPrompt(ctx context.Context, q *store.Queries, chat store.ChatSession, total int64, budget int, lead, focus, footer, body string) (string, error) {
	rows, err := q.ListRecentChatMessages(ctx, store.ListRecentChatMessagesParams{
		SessionID: chat.ID,
		RowLimit:  handoffRows,
		MaxChars:  handoffFetchChars,
	})
	if err != nil {
		return "", err
	}
	hist := make([]HandoffMessage, len(rows))
	for i, r := range rows {
		body := r.BodyMd
		if r.Role == "assistant" {
			body = ApplyChecklistState(body, ParseChecklistState(r.ChecklistState))
		}
		hist[i] = HandoffMessage{
			Seq:     r.Seq,
			Role:    r.Role,
			Harness: deref(r.Harness),
			Model:   deref(r.Model),
			Persona: r.PersonaName,
			Body:    body,
		}
	}
	hc, err := loadHandoffContext(ctx, q, chat.ID)
	if err != nil {
		return "", err
	}
	gitBrief, err := buildChatGitBrief(ctx, q, chat.ID)
	if err != nil {
		return "", err
	}
	return renderHandoffWith(hist, int(total), budget, hc, HandoffOptions{
		Lead:     lead,
		Focus:    focus,
		GitBrief: gitBrief,
		Footer:   footer,
	}, body), nil
}
