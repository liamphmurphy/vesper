package pushreq

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

const compareFilesLimit = 300

// CheckpointTarget identifies a pull request whose head commit is checked
// against open checkpoint branches before those branches may be deleted.
type CheckpointTarget struct {
	Owner              string
	Name               string
	RepoURL            string
	PRURL              string
	PRBranch           string
	PRHeadSHA          string
	RunID              *uuid.UUID
	CleanHead          bool
	IsTicket           bool
	SkipAlreadyChecked bool
}

// CheckpointContained reports whether every change in ckpt (whose live remote
// tip is ckptSHA) is provably contained in target.PRHeadSHA. A transient error
// returns a non-nil error so callers avoid recording a negative check.
func CheckpointContained(ctx context.Context, gh *GitHub, target CheckpointTarget, ckpt store.RunCheckpoint, ckptSHA string, recoveredByTarget bool) (bool, error) {
	if gh == nil || target.PRHeadSHA == "" || ckptSHA == "" {
		return false, nil
	}
	// Level 1: exact commit match.
	if ckptSHA == target.PRHeadSHA {
		return true, nil
	}

	// Level 2: strict ancestor (ckptSHA is reachable from target.PRHeadSHA).
	cmp, err := gh.Compare(ctx, target.Owner, target.Name, target.PRHeadSHA, ckptSHA)
	if errors.Is(err, ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if cmp.Status == "identical" || (cmp.Status == "behind" && cmp.AheadBy == 0) {
		return true, nil
	}

	// Level 3: identical tree snapshot (exact amend/squash or empty net diff vs merge-base).
	prTree := cmp.BaseCommit.Commit.Tree.SHA
	if prTree == "" {
		prTree, err = gh.CommitTreeSHA(ctx, target.Owner, target.Name, target.PRHeadSHA)
		if errors.Is(err, ErrNotFound) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
	}
	ckptTree := ""
	if ckpt.TreeSha != nil && *ckpt.TreeSha != "" && ckpt.CommitSha != nil && *ckpt.CommitSha == ckptSHA {
		ckptTree = *ckpt.TreeSha
	} else if n := len(cmp.Commits); n > 0 && cmp.Commits[n-1].SHA == ckptSHA && cmp.Commits[n-1].Commit.Tree.SHA != "" {
		ckptTree = cmp.Commits[n-1].Commit.Tree.SHA
	} else {
		ckptTree, err = gh.CommitTreeSHA(ctx, target.Owner, target.Name, ckptSHA)
		if errors.Is(err, ErrNotFound) {
			return false, nil
		}
		if err != nil {
			return false, err
		}
	}
	mergeBaseTree := cmp.MergeBaseCommit.Commit.Tree.SHA
	if ckptTree != "" && prTree != "" && ckptTree == prTree {
		return true, nil
	}
	if ckptTree != "" && mergeBaseTree != "" && ckptTree == mergeBaseTree {
		return true, nil
	}

	// Level 4: diverged (rebased, or recovered checkpoint amended and continued).
	if cmp.Status != "diverged" || cmp.MergeBaseCommit.SHA == "" || len(cmp.Files) == 0 || len(cmp.Files) >= compareFilesLimit {
		return false, nil
	}
	rev, err := gh.Compare(ctx, target.Owner, target.Name, ckptSHA, target.PRHeadSHA)
	if errors.Is(err, ErrNotFound) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if len(rev.Files) >= compareFilesLimit || rev.MergeBaseCommit.SHA != cmp.MergeBaseCommit.SHA {
		return false, nil
	}

	revByPath := make(map[string]CompareFile, len(rev.Files))
	revRemoved := make(map[string]bool, len(rev.Files))
	for _, rf := range rev.Files {
		revByPath[rf.Filename] = rf
		if rf.Status == "removed" {
			revRemoved[rf.Filename] = true
		} else if rf.Status == "renamed" && rf.PreviousFilename != "" {
			revRemoved[rf.PreviousFilename] = true
		}
	}

	// Sub-case 4a: exact blob/deletion match for rebased checkpoints.
	if filesExactMatch(cmp.Files, revByPath, revRemoved) {
		return true, nil
	}

	// Sub-case 4b: recovered synthetic/uncommitted checkpoint amended & edited
	// further on the same workstream with a clean workspace matching PRHeadSHA.
	sameWorkstream := target.IsTicket || ckpt.HasUncommitted || (ckpt.SourceBranch != "" && ckpt.SourceBranch == target.PRBranch)
	if target.CleanHead && recoveredByTarget && sameWorkstream && filesAccountedFor(cmp.Files, revByPath, revRemoved) {
		return true, nil
	}

	return false, nil
}

func filesExactMatch(ckptFiles []CompareFile, revByPath map[string]CompareFile, revRemoved map[string]bool) bool {
	for _, f := range ckptFiles {
		switch f.Status {
		case "removed":
			rf, exists := revByPath[f.Filename]
			if !revRemoved[f.Filename] || (exists && rf.Status != "removed") {
				return false
			}
		case "renamed":
			rf, ok := revByPath[f.Filename]
			if !ok || rf.Status == "removed" || f.SHA == "" || rf.SHA != f.SHA {
				return false
			}
			if f.PreviousFilename == "" || !revRemoved[f.PreviousFilename] {
				return false
			}
		default:
			rf, ok := revByPath[f.Filename]
			if !ok || rf.Status == "removed" || f.SHA == "" || rf.SHA != f.SHA {
				return false
			}
		}
	}
	return true
}

func filesAccountedFor(ckptFiles []CompareFile, revByPath map[string]CompareFile, revRemoved map[string]bool) bool {
	for _, f := range ckptFiles {
		switch f.Status {
		case "removed":
			rf, exists := revByPath[f.Filename]
			if !revRemoved[f.Filename] || (exists && rf.Status != "removed") {
				return false
			}
		case "renamed":
			rf, ok := revByPath[f.Filename]
			if !ok || rf.Status == "removed" {
				return false
			}
			if f.PreviousFilename == "" || !revRemoved[f.PreviousFilename] {
				return false
			}
		default:
			rf, ok := revByPath[f.Filename]
			if !ok || rf.Status == "removed" {
				return false
			}
		}
	}
	return true
}

// recoveryChain returns the set of checkpoint IDs that were recovered along a
// chain of runs ending at targetRunID.
func recoveryChain(targetRunID *uuid.UUID, ckpts []store.RunCheckpoint) map[uuid.UUID]bool {
	out := map[uuid.UUID]bool{}
	if targetRunID == nil {
		return out
	}
	runs := map[uuid.UUID]bool{*targetRunID: true}
	for range len(ckpts) {
		added := false
		for _, ckpt := range ckpts {
			if out[ckpt.ID] {
				continue
			}
			if ckpt.RecoveredByRunID != nil && runs[*ckpt.RecoveredByRunID] {
				out[ckpt.ID] = true
				if ckpt.RunID != nil && !runs[*ckpt.RunID] {
					runs[*ckpt.RunID] = true
					added = true
				}
			}
		}
		if !added {
			break
		}
	}
	return out
}

// CleanupCheckpoints checks each checkpoint against target, deletes verified
// remote checkpoint branches, marks them deleted in Postgres, and emits a
// checkpoint_deleted lifecycle event.
func CleanupCheckpoints(ctx context.Context, gh *GitHub, q *store.Queries, target CheckpointTarget, ckpts []store.RunCheckpoint) ([]string, error) {
	if gh == nil || len(ckpts) == 0 || target.PRHeadSHA == "" {
		return nil, nil
	}
	recovered := recoveryChain(target.RunID, ckpts)
	var deleted []string
	var errs []error
	for _, ckpt := range ckpts {
		co, cn, ok := ParseRepo(ckpt.RepoUrl)
		if !ok || !strings.EqualFold(co, target.Owner) || !strings.EqualFold(cn, target.Name) {
			continue
		}
		if target.SkipAlreadyChecked && ckpt.LastCheckedPrSha != nil && *ckpt.LastCheckedPrSha == target.PRHeadSHA {
			continue
		}
		ckptSHA, berr := gh.BranchSHA(ctx, target.Owner, target.Name, ckpt.Branch)
		if berr != nil {
			errs = append(errs, berr)
			continue
		}
		if ckptSHA == "" {
			if err := markCheckpointCleaned(ctx, q, ckpt); err != nil {
				errs = append(errs, err)
			}
			continue
		}
		contained, cerr := CheckpointContained(ctx, gh, target, ckpt, ckptSHA, recovered[ckpt.ID])
		if cerr != nil {
			errs = append(errs, cerr)
			continue
		}
		if !contained {
			_ = q.MarkCheckpointCheckedPR(ctx, store.MarkCheckpointCheckedPRParams{
				ID:               ckpt.ID,
				LastCheckedPrSha: &target.PRHeadSHA,
			})
			continue
		}
		if derr := gh.DeleteBranch(ctx, target.Owner, target.Name, ckpt.Branch); derr != nil {
			errs = append(errs, derr)
			continue
		}
		if err := markCheckpointCleaned(ctx, q, ckpt); err != nil {
			errs = append(errs, err)
			continue
		}
		eventRunID := target.RunID
		if eventRunID == nil {
			eventRunID = ckpt.RunID
		}
		if eventRunID != nil {
			payload, _ := json.Marshal(map[string]any{
				"state":  "checkpoint_deleted",
				"branch": ckpt.Branch,
				"repo":   ckpt.RepoUrl,
				"pr_url": target.PRURL,
			})
			_ = q.AddRunEvent(ctx, store.AddRunEventParams{RunID: *eventRunID, Type: "lifecycle", Payload: payload})
		}
		deleted = append(deleted, ckpt.Branch)
	}
	return deleted, errors.Join(errs...)
}

func markCheckpointCleaned(ctx context.Context, q *store.Queries, ckpt store.RunCheckpoint) error {
	if err := q.MarkCheckpointDeleted(ctx, ckpt.ID); err != nil {
		return err
	}
	if ckpt.ChatID != nil {
		_ = q.ClearRepositoryCheckpointIfMatches(ctx, store.ClearRepositoryCheckpointIfMatchesParams{
			ChatID:           *ckpt.ChatID,
			RepoUrl:          ckpt.RepoUrl,
			CheckpointBranch: &ckpt.Branch,
		})
	}
	if ckpt.RunID != nil {
		_ = q.ClearRunCheckpointIfMatches(ctx, store.ClearRunCheckpointIfMatchesParams{
			ID:               *ckpt.RunID,
			CheckpointBranch: &ckpt.Branch,
		})
	}
	return nil
}

// CleanupChatCheckpoints cleans up open checkpoints for req's chat repository
// once req has shipped a PR.
func CleanupChatCheckpoints(ctx context.Context, gh *GitHub, q *store.Queries, req store.PushRequest) ([]string, error) {
	if req.State != "pushed" || req.PrUrl == nil || *req.PrUrl == "" || req.HeadSha == nil || *req.HeadSha == "" {
		return nil, nil
	}
	return CleanupChatCheckpointsAtPR(ctx, gh, q, req.ChatID, req.RepoUrl, *req.PrUrl, req.Branch, *req.HeadSha, req.RunID, false)
}

// CleanupChatCheckpointsAtPR cleans up open checkpoints for a chat repository
// against a known PR URL, branch, and head SHA.
func CleanupChatCheckpointsAtPR(ctx context.Context, gh *GitHub, q *store.Queries, chatID uuid.UUID, repoURL, prURL, prBranch, prHeadSHA string, runID *uuid.UUID, skipChecked bool) ([]string, error) {
	if prURL == "" || prHeadSHA == "" {
		return nil, nil
	}
	ckpts, err := q.OpenChatCheckpoints(ctx, store.OpenChatCheckpointsParams{ChatID: chatID, RepoUrl: repoURL})
	if err != nil || len(ckpts) == 0 {
		return nil, err
	}
	owner, name, ok := ParseRepo(repoURL)
	if !ok {
		return nil, nil
	}
	cleanHead := false
	if cr, err := q.GetChatCodeReview(ctx, store.GetChatCodeReviewParams{ChatID: chatID, RepoUrl: repoURL}); err == nil {
		cleanHead = !cr.Dirty && cr.HeadSha != nil && *cr.HeadSha == prHeadSHA
	}
	return CleanupCheckpoints(ctx, gh, q, CheckpointTarget{
		Owner:              owner,
		Name:               name,
		RepoURL:            repoURL,
		PRURL:              prURL,
		PRBranch:           prBranch,
		PRHeadSHA:          prHeadSHA,
		RunID:              runID,
		CleanHead:          cleanHead,
		SkipAlreadyChecked: skipChecked,
	}, ckpts)
}

// CleanupTicketCheckpoints cleans up open checkpoints for a ticket against a
// known PR URL, branch, and head SHA.
func CleanupTicketCheckpoints(ctx context.Context, gh *GitHub, q *store.Queries, ticketID uuid.UUID, prURL, prBranch, prHeadSHA string, runID *uuid.UUID, cleanHead, skipChecked bool) ([]string, error) {
	if prURL == "" || prHeadSHA == "" {
		return nil, nil
	}
	ckpts, err := q.OpenTicketCheckpoints(ctx, ticketID)
	if err != nil || len(ckpts) == 0 {
		return nil, err
	}
	owner, name, _, ok := ParsePRURL(prURL)
	if !ok {
		return nil, nil
	}
	return CleanupCheckpoints(ctx, gh, q, CheckpointTarget{
		Owner:              owner,
		Name:               name,
		PRURL:              prURL,
		PRBranch:           prBranch,
		PRHeadSHA:          prHeadSHA,
		RunID:              runID,
		CleanHead:          cleanHead,
		IsTicket:           true,
		SkipAlreadyChecked: skipChecked,
	}, ckpts)
}

// CommitContainedInPR reports whether commitSHA (with optional treeSHA) is
// already contained in prHeadSHA.
func CommitContainedInPR(ctx context.Context, gh *GitHub, owner, name, prHeadSHA, commitSHA, treeSHA string) (bool, error) {
	var shaPtr, treePtr *string
	if commitSHA != "" {
		shaPtr = &commitSHA
	}
	if treeSHA != "" {
		treePtr = &treeSHA
	}
	return CheckpointContained(ctx, gh, CheckpointTarget{
		Owner:     owner,
		Name:      name,
		PRHeadSHA: prHeadSHA,
	}, store.RunCheckpoint{
		CommitSha: shaPtr,
		TreeSha:   treePtr,
	}, commitSHA, false)
}
