package runs

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/repositories"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
)

// PRCheckFailure mirrors prsync.FailedCheck for decoding stored JSONB feedback.
type PRCheckFailure struct {
	Name       string `json:"name"`
	Conclusion string `json:"conclusion"`
	DetailsURL string `json:"details_url,omitempty"`
	Title      string `json:"title,omitempty"`
	Summary    string `json:"summary,omitempty"`
}

// PRReviewComment mirrors prsync.ReviewComment.
type PRReviewComment struct {
	Author    string    `json:"author"`
	Body      string    `json:"body"`
	URL       string    `json:"url,omitempty"`
	CreatedAt time.Time `json:"created_at"`
}

// PRReviewThread mirrors prsync.ReviewThread.
type PRReviewThread struct {
	ID        string            `json:"id"`
	Path      string            `json:"path"`
	Line      int               `json:"line,omitempty"`
	URL       string            `json:"url,omitempty"`
	DiffHunk  string            `json:"diff_hunk,omitempty"`
	Outdated  bool              `json:"outdated,omitempty"`
	UpdatedAt time.Time         `json:"updated_at"`
	Comments  []PRReviewComment `json:"comments"`
}

// PRFeedbackData holds the decoded CI check failures and unresolved review threads for a PR.
type PRFeedbackData struct {
	CIState           string
	FailedChecksCount int
	FailedChecks      []PRCheckFailure
	UnresolvedThreads int
	ReviewThreads     []PRReviewThread
}

// DecodePRFeedback parses the JSONB payloads of a store.PrFeedback row.
func DecodePRFeedback(row store.PrFeedback) PRFeedbackData {
	out := PRFeedbackData{
		CIState:           row.CiState,
		FailedChecksCount: int(row.FailedChecksCount),
		UnresolvedThreads: int(row.UnresolvedThreads),
	}
	_ = json.Unmarshal(row.FailedChecks, &out.FailedChecks)
	_ = json.Unmarshal(row.ReviewThreads, &out.ReviewThreads)
	return out
}

// FormatPRFeedbackPrompt builds a focused follow-up prompt instructing a coding
// persona or ticket agent to fix failing CI checks and/or address unresolved
// inline review comments on the existing branch.
func FormatPRFeedbackPrompt(mode, prURL, branch string, fb PRFeedbackData, isChat bool) (string, error) {
	switch mode {
	case "ci", "review", "all":
	default:
		return "", apperr.Invalid("mode", "must be ci, review, or all")
	}
	includeCI := (mode == "ci" || mode == "all") && len(fb.FailedChecks) > 0
	includeReview := (mode == "review" || mode == "all") && len(fb.ReviewThreads) > 0
	if mode == "ci" && !includeCI {
		return "", apperr.Conflict("no failing CI checks are recorded for this pull request")
	}
	if mode == "review" && !includeReview {
		return "", apperr.Conflict("no unresolved review comments are recorded for this pull request")
	}
	if mode == "all" && !includeCI && !includeReview {
		return "", apperr.Conflict("no failing CI checks or unresolved review comments are recorded for this pull request")
	}

	var b strings.Builder
	switch {
	case includeCI && includeReview:
		b.WriteString("Fix the failing CI checks and address the unresolved review comments on pull request ")
	case includeCI:
		b.WriteString("Fix the failing CI checks on pull request ")
	default:
		b.WriteString("Address the unresolved review comments on pull request ")
	}
	b.WriteString(prURL)
	if branch != "" {
		b.WriteString(" (existing branch `")
		b.WriteString(branch)
		b.WriteString("`)")
	}
	b.WriteString(".\n\n")
	if branch != "" {
		b.WriteString("Check out and build on the existing branch `")
		b.WriteString(branch)
		b.WriteString("` (`git fetch origin` first if needed so you include the latest remote commits).\n\n")
	}

	if includeCI {
		fmt.Fprintf(&b, "## Failing CI Checks (%d)\n\n", len(fb.FailedChecks))
		for i, c := range fb.FailedChecks {
			fmt.Fprintf(&b, "%d. **%s** (%s)", i+1, c.Name, c.Conclusion)
			if c.Title != "" {
				b.WriteString(" — " + c.Title)
			}
			b.WriteByte('\n')
			if c.DetailsURL != "" {
				b.WriteString("   Details: " + c.DetailsURL + "\n")
			}
			if c.Summary != "" {
				b.WriteString("   " + strings.ReplaceAll(c.Summary, "\n", "\n   ") + "\n")
			}
		}
		b.WriteByte('\n')
	}

	if includeReview {
		fmt.Fprintf(&b, "## Unresolved Review Threads (%d)\n\n", len(fb.ReviewThreads))
		for i, th := range fb.ReviewThreads {
			loc := th.Path
			if th.Line > 0 {
				loc = fmt.Sprintf("%s:%d", th.Path, th.Line)
			}
			if loc == "" {
				loc = "Pull request comment"
			}
			fmt.Fprintf(&b, "### %d. `%s`", i+1, loc)
			if th.Outdated {
				b.WriteString(" (outdated)")
			}
			b.WriteByte('\n')
			if th.URL != "" {
				b.WriteString("Link: " + th.URL + "\n")
			}
			if th.DiffHunk != "" {
				b.WriteString("```diff\n" + th.DiffHunk + "\n```\n")
			}
			for _, c := range th.Comments {
				fmt.Fprintf(&b, "- **@%s**: %s\n", c.Author, c.Body)
			}
			b.WriteByte('\n')
		}
	}

	b.WriteString("Run the relevant tests after your changes, commit on `")
	if branch != "" {
		b.WriteString(branch)
	} else {
		b.WriteString("the PR branch")
	}
	if isChat {
		b.WriteString("`, and call `request_push` targeting that branch so the pull request updates.\n")
	} else {
		b.WriteString("`, and push your updates to the pull request branch before finishing.\n")
	}
	return b.String(), nil
}

func validatePRFeedbackMode(mode string) error {
	switch mode {
	case "ci", "review", "all":
		return nil
	default:
		return apperr.Invalid("mode", "must be ci, review, or all")
	}
}

// AddressPushRequestPRFeedback posts a focused prompt to the originating chat
// so the persona fixes CI failures or addresses review comments on the PR's branch.
func (s *Service) AddressPushRequestPRFeedback(ctx context.Context, ws, userID, pushReqID uuid.UUID, mode string) (store.ChatMessage, error) {
	var msg store.ChatMessage
	if err := validatePRFeedbackMode(mode); err != nil {
		return msg, err
	}
	err := s.tx(ctx, func(q *store.Queries) error {
		pr, err := q.GetPushRequest(ctx, store.GetPushRequestParams{ID: pushReqID, WorkspaceID: ws, UserID: userID})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		if err != nil {
			return err
		}
		if pr.State != "pushed" || pr.PrUrl == nil || *pr.PrUrl == "" {
			return apperr.Conflict("this push request has no open pull request")
		}
		if pr.PrState != nil && *pr.PrState != "open" && *pr.PrState != "draft" {
			return apperr.Conflict("pull request is already %s", *pr.PrState)
		}
		fbRow, err := q.GetPRFeedback(ctx, store.GetPRFeedbackParams{WorkspaceID: ws, PrUrl: *pr.PrUrl})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("no PR feedback has been synced yet")
		}
		if err != nil {
			return err
		}
		prompt, err := FormatPRFeedbackPrompt(mode, *pr.PrUrl, pr.Branch, DecodePRFeedback(fbRow), true)
		if err != nil {
			return err
		}

		chat, err := lockChat(ctx, q, ws, userID, pr.ChatID)
		if err != nil {
			return err
		}
		if chat.Archived {
			return apperr.Conflict("restore the chat before sending")
		}
		if chat.State == "running" || chat.InterruptMessageID != nil {
			return apperr.Conflict("wait for the current reply to finish before starting a PR fix")
		}
		caps, err := chatCaps(ctx, q, chat)
		if err != nil {
			return err
		}
		if !caps.Code {
			return apperr.Conflict("this persona cannot write code")
		}
		if _, err := q.AttachChatRepository(ctx, store.AttachChatRepositoryParams{
			ChatID: chat.ID, RepoUrl: pr.RepoUrl, Directory: repositories.Directory(pr.RepoUrl),
		}); err != nil {
			return err
		}
		if chat.RepoUrl == nil || *chat.RepoUrl != pr.RepoUrl || chat.PendingRepoUrl != nil {
			if err := q.ClearPendingChatRepository(ctx, chat.ID); err != nil {
				return err
			}
			if chat, err = q.ActivateChatRepository(ctx, store.ActivateChatRepositoryParams{ID: chat.ID, RepoUrl: pr.RepoUrl}); err != nil {
				return err
			}
		}
		if err := q.AddChatWorkBranch(ctx, store.AddChatWorkBranchParams{ChatID: chat.ID, RepoUrl: pr.RepoUrl, Branch: pr.Branch}); err != nil {
			return err
		}
		if err := q.AddChatWorkBranches(ctx, store.AddChatWorkBranchesParams{ID: chat.ID, Branches: []string{pr.Branch}, MaxBranches: personas.MaxWorkBranches}); err != nil {
			return err
		}
		if chat, err = q.GetChatSession(ctx, store.GetChatSessionParams{ID: chat.ID, WorkspaceID: ws}); err != nil {
			return err
		}

		_, msg, err = postChatMessage(ctx, q, s.ChatCatalog(), chat, ChatMessageInput{Body: prompt}, s.HandoffChars)
		if err != nil {
			return err
		}
		if mode == "ci" || mode == "all" {
			if err := q.ReadInboxItem(ctx, store.ReadInboxItemParams{UserID: userID, ItemID: "pr_ci_failed:push:" + pr.ID.String()}); err != nil {
				return err
			}
		}
		if mode == "review" || mode == "all" {
			if err := q.ReadInboxItem(ctx, store.ReadInboxItemParams{UserID: userID, ItemID: "pr_review_comments:push:" + pr.ID.String()}); err != nil {
				return err
			}
		}
		return nil
	})
	return msg, err
}

// AddressTicketPRFeedback resumes a waiting ticket run or dispatches a fresh
// managed run on the ticket's branch to fix CI failures or address review comments.
func (s *Service) AddressTicketPRFeedback(ctx context.Context, ws, userID uuid.UUID, key, mode string) (store.Run, error) {
	var run store.Run
	if err := validatePRFeedbackMode(mode); err != nil {
		return run, err
	}
	err := s.tx(ctx, func(q *store.Queries) error {
		if err := tracker.LockTicketProjects(ctx, q, ws, []string{key}); err != nil {
			if errors.Is(err, tracker.ErrNotFound) {
				return apperr.ErrNotFound
			}
			return err
		}
		t, err := q.LockTicketByKey(ctx, store.LockTicketByKeyParams{WorkspaceID: ws, Key: strings.ToUpper(strings.TrimSpace(key))})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		if err != nil {
			return err
		}
		if t.PrUrl == nil || *t.PrUrl == "" {
			return apperr.Conflict("%s has no pull request", t.Key)
		}
		if t.PrState != nil && *t.PrState != "open" && *t.PrState != "draft" {
			return apperr.Conflict("pull request is already %s", *t.PrState)
		}
		if t.Status == "done" || t.Status == "canceled" {
			return apperr.Conflict("%s is %s", t.Key, t.Status)
		}
		fbRow, err := q.GetPRFeedback(ctx, store.GetPRFeedbackParams{WorkspaceID: ws, PrUrl: *t.PrUrl})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("no PR feedback has been synced yet")
		}
		if err != nil {
			return err
		}
		prompt, err := FormatPRFeedbackPrompt(mode, *t.PrUrl, deref(t.Branch), DecodePRFeedback(fbRow), false)
		if err != nil {
			return err
		}

		live, err := q.ActiveRunForTicket(ctx, &t.ID)
		switch {
		case err == nil:
			if live.State != "waiting" || deref(live.WaitReason) != "human_reply" {
				return apperr.Conflict("%s already has a %s run", t.Key, live.State)
			}
			live, err = q.LockRun(ctx, live.ID)
			if err != nil {
				return err
			}
			if _, err := q.CreateComment(ctx, store.CreateCommentParams{
				WorkspaceID: ws, TicketID: t.ID, AuthorType: "user", AuthorID: userID, BodyMd: prompt,
			}); err != nil {
				return err
			}
			if err := resume(ctx, q, live, "comment", prompt); err != nil {
				return err
			}
			live, err = q.GetRun(ctx, store.GetRunParams{ID: live.ID, WorkspaceID: ws})
			if err != nil {
				return err
			}
			run = live
		case errors.Is(err, pgx.ErrNoRows):
			if _, err := q.CreateComment(ctx, store.CreateCommentParams{
				WorkspaceID: ws, TicketID: t.ID, AuthorType: "user", AuthorID: userID, BodyMd: prompt,
			}); err != nil {
				return err
			}
			run, err = dispatchTicketWithPrompt(ctx, q, ws, userID, t.Key, "key", prompt)
			if err != nil {
				return err
			}
		default:
			return err
		}

		if mode == "ci" || mode == "all" {
			if err := q.ReadInboxItem(ctx, store.ReadInboxItemParams{UserID: userID, ItemID: "pr_ci_failed:ticket:" + t.ID.String()}); err != nil {
				return err
			}
		}
		if mode == "review" || mode == "all" {
			if err := q.ReadInboxItem(ctx, store.ReadInboxItemParams{UserID: userID, ItemID: "pr_review_comments:ticket:" + t.ID.String()}); err != nil {
				return err
			}
		}
		return nil
	})
	return run, err
}
