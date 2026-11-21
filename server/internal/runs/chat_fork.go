package runs

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"time"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const maxForkTitleRunes = 120

// ForkChatInput configures branching an existing conversation at a message.
type ForkChatInput struct {
	MessageID  uuid.UUID
	Title      string
	BranchRepo bool
	BranchName string
}

func defaultForkTitle(source string) string {
	source = strings.TrimSpace(source)
	if source == "" {
		return "Forked chat"
	}
	title := "Fork of " + source
	r := []rune(title)
	if len(r) > maxForkTitleRunes {
		return strings.TrimSpace(string(r[:maxForkTitleRunes]))
	}
	return title
}

// ForkChat creates an independent conversation seeded with the transcript
// prefix through in.MessageID. On coding chats with in.BranchRepo, attached
// repositories start on a new fork branch seeded from the fork point's ref.
func (s *Service) ForkChat(ctx context.Context, ws, user, sourceChatID uuid.UUID, in ForkChatInput) (store.ChatSession, error) {
	in.Title = strings.TrimSpace(in.Title)
	if utf8.RuneCountInString(in.Title) > 200 {
		return store.ChatSession{}, apperr.Invalid("title", "must be at most 200 characters")
	}
	in.BranchName = strings.TrimSpace(in.BranchName)
	if in.BranchName != "" {
		if !in.BranchRepo {
			return store.ChatSession{}, apperr.Invalid("branch_name", "branch_name requires branch_repo=true")
		}
		if !personas.ValidWorkBranch(in.BranchName) {
			return store.ChatSession{}, apperr.Invalid("branch_name", "use TYPE/short-description (e.g. feat/my-fork)")
		}
	}

	var out store.ChatSession
	err := s.tx(ctx, func(q *store.Queries) error {
		source, err := lockChat(ctx, q, ws, user, sourceChatID)
		if err != nil {
			return err
		}
		anchor, err := q.GetChatMessageByID(ctx, store.GetChatMessageByIDParams{ID: in.MessageID, SessionID: source.ID})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		if err != nil {
			return err
		}
		msgs, err := q.ListChatMessagesUpToSeq(ctx, store.ListChatMessagesUpToSeqParams{SessionID: source.ID, Seq: anchor.Seq})
		if err != nil {
			return err
		}
		title := in.Title
		if title == "" {
			title = defaultForkTitle(source.Title)
		}
		var lastMsgAt *time.Time
		if n := len(msgs); n > 0 {
			ts := msgs[n-1].CreatedAt
			lastMsgAt = &ts
		}
		forked, err := q.CreateForkedChatSession(ctx, store.CreateForkedChatSessionParams{
			WorkspaceID:         source.WorkspaceID,
			ProjectID:           source.ProjectID,
			Title:               title,
			CreatedBy:           user,
			AgentID:             source.AgentID,
			Harness:             source.Harness,
			Model:               source.Model,
			Effort:              source.Effort,
			AutoModel:           source.AutoModel,
			PersonaID:           source.PersonaID,
			SpeakerPersonaID:    source.SpeakerPersonaID,
			RepoUrl:             source.RepoUrl,
			CommitEmail:         source.CommitEmail,
			SpaceID:             source.SpaceID,
			ConnectorIds:        source.ConnectorIds,
			SecretIds:           source.SecretIds,
			AutoRolloverTokens:  source.AutoRolloverTokens,
			ForkedFromChatID:    &source.ID,
			ForkedFromMessageID: &anchor.ID,
			LastMessageAt:       lastMsgAt,
		})
		if err != nil {
			return err
		}
		parts, err := q.ChatParticipants(ctx, []uuid.UUID{source.ID})
		if err != nil {
			return err
		}
		for _, p := range parts {
			if err := q.AddChatParticipant(ctx, store.AddChatParticipantParams{ChatID: forked.ID, PersonaID: p.PersonaID}); err != nil {
				return err
			}
		}

		var latestBranch, latestSHA *string
		for i, m := range msgs {
			refs := m.ContextRefs
			if len(refs) == 0 {
				refs = []byte("[]")
			}
			cites := m.Citations
			if len(cites) == 0 {
				cites = []byte("[]")
			}
			changes := m.CodeChanges
			if len(changes) == 0 {
				changes = []byte("[]")
			}
			if _, err := q.CopyChatMessageForFork(ctx, store.CopyChatMessageForForkParams{
				SessionID:    forked.ID,
				Seq:          int64(i + 1),
				Role:         m.Role,
				BodyMd:       m.BodyMd,
				Harness:      m.Harness,
				Model:        m.Model,
				ContextRefs:  refs,
				Citations:    cites,
				CodeChanges:  changes,
				PersonaID:    m.PersonaID,
				GitBranch:    m.GitBranch,
				GitCommitSha: m.GitCommitSha,
			}); err != nil {
				return err
			}
			if m.GitBranch != nil && *m.GitBranch != "" {
				b := *m.GitBranch
				latestBranch = &b
			}
			if m.GitCommitSha != nil && *m.GitCommitSha != "" {
				s := *m.GitCommitSha
				latestSHA = &s
			}
		}
		if len(msgs) > 0 {
			if err := q.MarkChatRead(ctx, store.MarkChatReadParams{ID: forked.ID, Seq: int64(len(msgs))}); err != nil {
				return err
			}
			forked.LastReadSeq = int64(len(msgs))
		}

		repos, err := q.ChatRepositories(ctx, source.ID)
		if err != nil {
			return err
		}
		forkBranch := in.BranchName
		if in.BranchRepo && forkBranch == "" {
			forkBranch = fmt.Sprintf("feat/fork-%s", forked.ID.String()[:8])
		}
		for _, r := range repos {
			if in.BranchRepo {
				var startRef *string
				isPrimary := (source.RepoUrl != nil && r.RepoUrl == *source.RepoUrl) || len(repos) == 1
				if isPrimary {
					if latestSHA != nil {
						startRef = latestSHA
					} else if latestBranch != nil {
						startRef = latestBranch
					}
				}
				if startRef == nil && r.CheckpointBranch != nil && *r.CheckpointBranch != "" {
					startRef = r.CheckpointBranch
				}
				if _, err := q.AttachChatRepositoryWithFork(ctx, store.AttachChatRepositoryWithForkParams{
					ChatID:           forked.ID,
					RepoUrl:          r.RepoUrl,
					Directory:        r.Directory,
					CheckpointBranch: startRef,
					ForkBranch:       &forkBranch,
				}); err != nil {
					return err
				}
			} else {
				if _, err := q.AttachChatRepository(ctx, store.AttachChatRepositoryParams{
					ChatID:    forked.ID,
					RepoUrl:   r.RepoUrl,
					Directory: r.Directory,
				}); err != nil {
					return err
				}
			}
		}
		out = forked
		return nil
	})
	return out, err
}
