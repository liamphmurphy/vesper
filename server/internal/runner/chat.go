package runner

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/designs"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/repositories"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Every chat mutation takes the session lock before its run lock. The session
// serializes posts, cancellation, completion, message seq and state notifications.
func lockRunChat(ctx context.Context, q *store.Queries, run store.Run) (store.ChatSession, error) {
	chat, err := q.ChatSessionForRun(ctx, &run.ID)
	if err != nil {
		return chat, err
	}
	return q.LockChatSession(ctx, store.LockChatSessionParams{ID: chat.ID, WorkspaceID: run.WorkspaceID})
}

// chatSetupScript is a chat segment's workspace setup: the coding persona's
// repository when the frozen spec grants repo:write and the chat has one, otherwise just the context directory (and the outbox
// image-generating chats copy their pictures to).
func chatSetupScript(ctx context.Context, q *store.Queries, c runCtx) (string, error) {
	script := "mkdir -p .lazyagents/context"
	if c.spec.HarnessOptions[agentdef.OptionImageGeneration] == "true" {
		script += " .lazyagents/outbox"
	}
	if !allowedScope(c.spec, "repo:write") {
		return script, nil
	}
	chat, err := q.ChatSessionForRun(ctx, &c.run.ID)
	if err != nil {
		return "", err
	}
	repos, err := q.ChatRepositories(ctx, chat.ID)
	if err != nil {
		return "", err
	}
	name, email, err := chatCommitAuthor(ctx, q, chat)
	if err != nil {
		return "", err
	}
	script += "\n" + sshSetup
	for _, repo := range repos {
		script += repositories.SetupScript(repo.RepoUrl, repo.Directory, repo.WorkBranches, repo.CheckpointBranch, name, email)
		if repo.Directory == "." {
			script += "if [ ! -f .lazyagents/chat-checkout-ready ]; then\n" + keepOurFilesOutOfGit + "touch .lazyagents/chat-checkout-ready\nfi\n"
		}
	}
	return script, nil
}

// chatCommitAuthor is who a coding chat's commits are authored as. Commits are
// the person's work, made in their chat: authoring them as the chat's creator,
// with the address they picked for it, lets the forge attribute them to that
// person's account.
func chatCommitAuthor(ctx context.Context, q *store.Queries, chat store.ChatSession) (name, email string, err error) {
	author, err := q.GetUser(ctx, store.GetUserParams{ID: chat.CreatedBy, WorkspaceID: chat.WorkspaceID})
	if err != nil {
		return "", "", fmt.Errorf("chat commit author: %w", err)
	}
	return author.Name, auth.CommitEmail(author, chat.CommitEmail), nil
}

// chatCommitEnv sets the commit author for one coding chat turn. git prefers
// these over the user.email the segment's setup configured, so an address
// picked mid-segment applies from the next turn rather than the next segment.
func chatCommitEnv(ctx context.Context, q *store.Queries, c runCtx) (map[string]string, error) {
	chat, err := q.ChatSessionForRun(ctx, &c.run.ID)
	if err != nil {
		return nil, err
	}
	name, email, err := chatCommitAuthor(ctx, q, chat)
	if err != nil {
		return nil, err
	}
	return map[string]string{
		"GIT_AUTHOR_NAME": name, "GIT_AUTHOR_EMAIL": email,
		"GIT_COMMITTER_NAME": name, "GIT_COMMITTER_EMAIL": email,
	}, nil
}

// chatSpeaker is the persona answering the chat's turn: its speaker, else its
// host; nil is the built-in Assistant.
func chatSpeaker(chat store.ChatSession) *uuid.UUID {
	if chat.SpeakerPersonaID != nil {
		return chat.SpeakerPersonaID
	}
	return chat.PersonaID
}

func idleChat(ctx context.Context, q *store.Queries, chat store.ChatSession, run store.Run, state string) error {
	reason := "human_reply"
	if _, err := q.SetRunState(ctx, store.SetRunStateParams{ID: run.ID, State: "waiting", WaitReason: &reason}); err != nil {
		return err
	}
	if _, err := q.SetChatRunState(ctx, store.SetChatRunStateParams{ID: chat.ID, CurrentRunID: &run.ID, State: state}); err != nil {
		return err
	}
	return runs.RecomputeAgentStatus(ctx, q, run.AgentID)
}

// A stopped setup has no harness result to finalize, but must still release
// the chat and deliver any message that interrupted it.
func (r *Runner) finishStoppedChatSetup(ctx context.Context, c runCtx) bool {
	stopped := false
	err := pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		chat, err := lockRunChat(ctx, q, c.run)
		if err != nil {
			return err
		}
		run, err := q.LockRun(ctx, c.run.ID)
		if err != nil || run.State != "paused" {
			return err
		}
		if err := verifyExecution(ctx, q, run.ID); err != nil {
			return err
		}
		stopped = true
		// Setup may have been killed halfway through a clone or install. A new
		// turn must run setup again rather than trusting the partial workspace.
		if err := q.FinishUnfinishedChatTurns(ctx, run.ID); err != nil {
			return err
		}
		if err := idleChat(ctx, q, chat, run, "idle"); err != nil {
			return err
		}
		return runs.ResumeInterruptedChat(ctx, q, chat.ID, run.ID, nil, 0)
	})
	if err != nil {
		r.Log.Error("finish stopped chat setup", "run", c.run.ID, "err", err)
	}
	return stopped
}

// generatedImage is an outbox file already stored as a blob, waiting to be
// bound to the turn's assistant message.
type generatedImage struct {
	outbox   string // the file's name in the outbox
	name, ct string
	key      string
	size     int64
}

// harvestChatImages stores the images an image-generating chat copied into
// its outbox. It runs before the turn's transaction so no blob I/O happens
// under row locks; a failure is logged as a run event and never fails the turn.
func (r *Runner) harvestChatImages(ctx context.Context, c runCtx) (out []generatedImage) {
	warn := func(state string, detail any) {
		r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": state, "detail": detail})
	}
	if r.Blobs == nil || r.Cfg.AttachmentBucket == "" {
		warn("chat_images_skipped", "no attachment storage is configured")
		return nil
	}
	chat, err := r.q().ChatSessionForRun(ctx, &c.run.ID)
	if err != nil {
		r.Log.Warn("harvest chat images", "run", c.run.ID, "err", err)
		return nil
	}
	stored, err := r.q().ChatGeneratedImageBytes(ctx, store.ChatGeneratedImageBytesParams{WorkspaceID: chat.WorkspaceID, UserID: chat.CreatedBy})
	if err != nil {
		r.Log.Warn("generated image usage", "run", c.run.ID, "err", err)
		return nil
	}
	if stored >= runs.MaxGeneratedImageStorageBytes {
		warn("chat_images_skipped", "quota")
		return nil
	}
	files, skipped, err := r.Backend.ReadOutbox(ctx, c.run.ID.String())
	if err != nil {
		r.Log.Warn("read chat outbox", "run", c.run.ID, "err", err)
		warn("chat_images_failed", err.Error())
		return nil
	}
	for _, f := range files {
		ct, ok := runs.GeneratedImageType(f.Data)
		name := runs.ChatAttachmentName(f.Name)
		if !ok || name == "" || len(f.Data) == 0 {
			skipped = append(skipped, f.Name+": not a png, jpeg, webp or gif image")
			continue
		}
		if stored+int64(len(f.Data)) > runs.MaxGeneratedImageStorageBytes {
			skipped = append(skipped, f.Name+": quota")
			continue
		}
		stored += int64(len(f.Data))
		key := runs.ChatAttachmentKey(chat.WorkspaceID, chat.CreatedBy)
		if err := r.Blobs.Put(ctx, r.Cfg.AttachmentBucket, key, bytes.NewReader(f.Data), int64(len(f.Data)), ct); err != nil {
			r.Log.Warn("store generated image", "run", c.run.ID, "err", err)
			skipped = append(skipped, f.Name+": couldn't be stored")
			continue
		}
		out = append(out, generatedImage{outbox: f.Name, name: name, ct: ct, key: key, size: int64(len(f.Data))})
	}
	if len(skipped) > 0 {
		warn("chat_images_skipped", skipped)
	}
	return out
}

// dropImageBlobs removes stored images that never got a row, through the
// store they were written to. A runner crash between the Put and the turn's
// commit can still orphan blobs; a sweep for those is a follow-up.
func (r *Runner) dropImageBlobs(imgs []generatedImage) {
	if r.Blobs == nil {
		return
	}
	for _, im := range imgs {
		if err := r.Blobs.Delete(context.WithoutCancel(context.Background()), r.Cfg.AttachmentBucket, im.key); err != nil {
			r.Log.Warn("remove unbound generated image", "key", im.key, "err", err)
		}
	}
}

// chatTurnCode is what a coding chat's turn did in its repository: the
// changes JSON for its reply, and the branches it has pushed.
type chatTurnCode struct {
	changes            []byte
	branches           []string
	repositoryBranches map[string][]string
}

func (r *Runner) finishChatTurn(ctx context.Context, c runCtx, turn store.RunTurn, res harness.Result, code int, waitErr error, logKey *string, work chatTurnCode, jobs chatImages) {
	codeChanges := work.changes
	var imgs []generatedImage
	// A Codex chat copies its pictures to the outbox itself; any other chat's
	// come from the Codex steps its generate_image requests ran.
	if (c.spec.HarnessOptions[agentdef.OptionImageGeneration] == "true" || jobs.ran) && waitErr == nil && code == 0 && !res.IsError && !res.UsageLimited {
		imgs = r.harvestChatImages(ctx, c)
	}
	bound := false
	err := r.retryChatTransaction(ctx, func(ctx context.Context, q *store.Queries) error {
		bound = false
		chat, err := lockRunChat(ctx, q, c.run)
		if err != nil {
			return err
		}
		run, err := q.LockRun(ctx, c.run.ID)
		if err != nil {
			return err
		}
		current, err := q.LockTurn(ctx, turn.ID)
		if err != nil {
			return err
		}
		if current.Status == "done" {
			// A commit whose acknowledgement was lost must not duplicate the
			// reply, its usage, or its automatic follow-up turn.
			bound = len(imgs) > 0
			return nil
		}
		if token := executionToken(ctx); token != nil && (current.ExecutionToken == nil || *current.ExecutionToken != *token || current.ExecutionExpiresAt == nil || !current.ExecutionExpiresAt.After(time.Now())) {
			return errors.New("chat execution lease was lost")
		}
		// Kept whatever came of the turn: a branch it pushed is on the remote.
		if len(work.branches) > 0 {
			if err := q.AddChatWorkBranches(ctx, store.AddChatWorkBranchesParams{ID: chat.ID, Branches: work.branches, MaxBranches: personas.MaxWorkBranches}); err != nil {
				return err
			}
		}
		for url, branches := range work.repositoryBranches {
			if err := q.SaveRepositoryBranches(ctx, store.SaveRepositoryBranchesParams{ChatID: chat.ID, RepoUrl: url, Branches: branches}); err != nil {
				return err
			}
		}
		if len(work.repositoryBranches) > 0 {
			if err := q.RefreshChatRepositoryBranches(ctx, chat.ID); err != nil {
				return err
			}
		}
		usage, err := json.Marshal(res.Usage)
		if err != nil {
			return err
		}
		exit := int32(code)
		if err = q.FinishTurn(ctx, store.FinishTurnParams{ID: turn.ID, ExitCode: &exit, LogKey: logKey, Usage: usage}); err != nil {
			return err
		}
		var source *string
		if res.Usage.CostSource != "" {
			source = &res.Usage.CostSource
		}
		if _, err = q.AddRunUsage(ctx, store.AddRunUsageParams{ID: run.ID, ToolCalls: int32(res.Usage.ToolCalls), InputTokens: res.Usage.InputTokens, OutputTokens: res.Usage.OutputTokens, CostUsdMicros: int64(res.Usage.CostUSD * 1e6), CostSource: source}); err != nil {
			return err
		}
		// generate_image requests the turn never got to (its reply failed, or
		// the run was stopped) end as failed rather than staying queued with
		// nothing to show for them.
		turnFailed := waitErr != nil || code != 0 || res.IsError || res.UsageLimited
		dropReason := "the image step never ran"
		switch {
		case run.State != "running":
			dropReason = "stopped"
		case turnFailed:
			dropReason = "the reply failed before the image could be made"
		}
		dropped, err := q.FailQueuedChatImageJobs(ctx, store.FailQueuedChatImageJobsParams{RunID: run.ID, TurnID: turn.ID, Error: dropReason})
		if err != nil {
			return err
		}
		if run.State != "running" && run.State != "paused" {
			return nil
		}
		state, followup := "idle", false
		replied, reply := false, ""
		speaker := chatSpeaker(chat)
		if run.State == "running" {
			role, body := "assistant", res.Final
			if turnFailed {
				state, role = "failed", "system"
				body = res.Error
				if body == "" {
					body = fmt.Sprintf("The chat turn stopped (exit %d). Send another message to retry.", code)
				}
			}
			citations := []byte("[]")
			if role == "assistant" {
				if citations, err = runs.ChatCitations(ctx, q, run.ID, turn.StartedAt); err != nil {
					return err
				}
				if body, err = runs.GateSVGFences(ctx, q, chat, body); err != nil {
					return err
				}
			}
			// The opening line the chat showed while the turn worked stays in
			// the conversation, as its own reply ahead of the answer.
			if opening := strings.TrimSpace(res.Opening); role == "assistant" && opening != "" && opening != strings.TrimSpace(body) {
				if opening, err = runs.GateSVGFences(ctx, q, chat, opening); err != nil {
					return err
				}
				if _, err := q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chat.ID, Role: role, BodyMd: opening, Harness: &run.Harness, Model: &run.Model, RunID: &run.ID, RunTurnID: &turn.ID, ContextRefs: []byte("[]"), Citations: []byte("[]"), PersonaID: speaker}); err != nil {
					return err
				}
			}
			msg, err := q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chat.ID, Role: role, BodyMd: body, Harness: &run.Harness, Model: &run.Model, RunID: &run.ID, RunTurnID: &turn.ID, ContextRefs: []byte("[]"), Citations: citations, Usage: usage, PersonaID: personaFor(role, speaker)})
			if err != nil {
				return err
			}
			// The turn's videos (finished or not) show on the reply it stored.
			if err := q.LinkChatVideoJobsToMessage(ctx, store.LinkChatVideoJobsToMessageParams{MessageID: &msg.ID, RunID: &run.ID, TurnID: &turn.ID}); err != nil {
				return err
			}
			if err := q.LinkChatAudioJobsToMessage(ctx, store.LinkChatAudioJobsToMessageParams{MessageID: &msg.ID, RunID: &run.ID, TurnID: &turn.ID}); err != nil {
				return err
			}
			// A failed reply gets no follow-up turn, so the person hears of its
			// image requests here. (A reply's own jobs are reported below.)
			if role == "system" {
				for _, j := range dropped {
					if _, err := q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chat.ID, Role: "system", BodyMd: imageFailureMessage(imageFailError, *j.Error), RunID: &run.ID, RunTurnID: &turn.ID, ContextRefs: []byte("[]"), Citations: []byte("[]")}); err != nil {
						return err
					}
				}
			}
			if role == "assistant" {
				replied, reply = true, body
				if len(codeChanges) > 2 { // more than "[]"
					if err := q.SetChatMessageCodeChanges(ctx, store.SetChatMessageCodeChangesParams{ID: msg.ID, CodeChanges: codeChanges}); err != nil {
						return err
					}
				}
				// The image jobs this turn ran, by the outbox files they made, so
				// each job is linked to the attachment its image became.
				jobRows, err := q.ChatImageJobsForTurn(ctx, store.ChatImageJobsForTurnParams{RunID: run.ID, TurnID: turn.ID})
				if err != nil {
					return err
				}
				jobByFile, linked := map[string]uuid.UUID{}, map[uuid.UUID]bool{}
				for _, j := range jobRows {
					for _, f := range j.OutboxFiles {
						jobByFile[f] = j.ID
					}
				}
				for _, im := range imgs {
					att, err := q.CreateGeneratedChatAttachment(ctx, store.CreateGeneratedChatAttachmentParams{WorkspaceID: chat.WorkspaceID, UserID: chat.CreatedBy, MessageID: &msg.ID, Filename: im.name, ContentType: im.ct, SizeBytes: im.size, BlobKey: im.key})
					if err != nil {
						return err
					}
					// A step asked for one image; if it left more, the first is its image.
					if id, ok := jobByFile[im.outbox]; ok && !linked[id] {
						if err := q.LinkChatImageJobAttachment(ctx, store.LinkChatImageJobAttachmentParams{ID: id, AttachmentID: &att.ID}); err != nil {
							return err
						}
						linked[id] = true
					}
					// Every generated image is kept in the person's Library too,
					// sharing the attachment's object.
					if _, err := q.CreateLibraryItem(ctx, store.CreateLibraryItemParams{WorkspaceID: chat.WorkspaceID, UserID: chat.CreatedBy, Kind: "image", Title: runs.LibraryImageTitle(chat.Title),
						Filename: im.name, ContentType: im.ct, SizeBytes: im.size, BlobKey: im.key, ChatID: &chat.ID, MessageID: &msg.ID, PersonaID: speaker}); err != nil {
						return err
					}
				}
				bound = len(imgs) > 0
				finished := false
				for _, j := range jobRows {
					finished = finished || j.State == "done" || j.State == "failed"
					if j.State != "failed" || j.FailureKind == nil || j.Error == nil {
						continue
					}
					body := imageFailureMessage(*j.FailureKind, *j.Error)
					if _, err := q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chat.ID, Role: "system", BodyMd: body, RunID: &run.ID, RunTurnID: &turn.ID, ContextRefs: []byte("[]"), Citations: []byte("[]")}); err != nil {
						return err
					}
				}
				// The assistant hasn't seen what came of its generate_image
				// calls: one automatic turn shows it the images and failures to
				// react to, and the chat keeps working until it ends. A Codex
				// chat made its images itself, and a follow-up never gets one.
				if finished && run.Harness != agentdef.HarnessCodex && turn.Trigger != runs.TriggerImageFollowup {
					next, err := q.StartTurn(ctx, store.StartTurnParams{RunID: run.ID, Trigger: runs.TriggerImageFollowup, InputMessage: imageFollowupPrompt})
					if err != nil {
						return err
					}
					if err := q.SetChatImageJobsFollowup(ctx, store.SetChatImageJobsFollowupParams{FollowupTurnID: &next.ID, RunID: run.ID, TurnID: turn.ID}); err != nil {
						return err
					}
					followup = true
				}
			}
		}
		if !followup {
			if err = idleChat(ctx, q, chat, run, state); err != nil {
				return err
			}
		}
		ended := map[string]any{"state": "turn_ended", "turn": turn.Seq, "exit_code": code}
		if followup {
			ended["image_followup"] = true
		}
		payload, _ := json.Marshal(ended)
		if err = q.AddRunEvent(ctx, store.AddRunEventParams{RunID: run.ID, Type: "lifecycle", Payload: payload}); err != nil {
			return err
		}
		if followup {
			// The same persona reacts to its images first; that turn's reply
			// is what hands the conversation on.
			return nil
		}
		if chat.ParentChatID != nil {
			// A thread waits for the person's next reply, like a chat, but hands
			// nothing on to other personas.
			if chat.AnchorMessageID != nil {
				return nil
			}
			// An aside answers one question: it hands nothing on and keeps no
			// workspace once it has answered (or was stopped).
			return runs.EndAside(ctx, q, chat.ID)
		}
		// A reply that mentions other personas hands the conversation on.
		if err := runs.RelayChat(ctx, q, chat.ID, reply, replied); err != nil {
			return err
		}
		// A stopped reply may have been interrupted by a new message.
		if err := runs.ResumeInterruptedChat(ctx, q, chat.ID, run.ID, &turn.StartedAt, 0); err != nil {
			return err
		}
		// Only a turn that ended with a reply sends the next queued follow-up;
		// after a stop or a failure the queue waits for the person.
		if !replied {
			return nil
		}
		return runs.SendNextFollowup(ctx, q, chat.ID, 0)
	})
	if err != nil {
		r.Log.Error("finish chat turn", "run", c.run.ID, "err", err)
	}
	if err != nil && ctx.Err() == nil {
		r.failChat(ctx, c, "The reply could not be saved. Send another message to retry.")
	}
	// What the turn drafted on designs becomes the person's to see now. Best
	// effort: opening the design publishes whatever this misses.
	if err := (&designs.Service{Pool: r.Pool}).PublishSettled(context.WithoutCancel(ctx), nil, &turn.ID); err != nil {
		r.Log.Error("publish design drafts", "run", c.run.ID, "turn", turn.ID, "err", err)
	}
	switch {
	case len(imgs) == 0:
	case err != nil || !bound:
		r.dropImageBlobs(imgs)
	default:
		// Committed: the files must not be attached to a later message too.
		names := make([]string, len(imgs))
		for i, im := range imgs {
			names[i] = im.outbox
		}
		if err := r.Backend.RemoveOutbox(context.WithoutCancel(ctx), c.run.ID.String(), names); err != nil {
			r.Log.Warn("clear chat outbox", "run", c.run.ID, "err", err)
		}
	}
}

// personaFor is the persona an appended message is from: the speaker for an
// assistant reply, none for a system notice.
func personaFor(role string, speaker *uuid.UUID) *uuid.UUID {
	if role == "assistant" {
		return speaker
	}
	return nil
}

// failChat handles setup/invocation failures before a harness result exists.
// The segment stays usable; pending/running records cannot block its next turn.
// restartChatSegment answers a turn whose segment can't continue here (its
// session or workspace is gone, or on the other backend) from a new segment
// that gets the conversation so far. It reports false when the turn isn't
// answering a message, so the caller's normal failure handling applies.
func (r *Runner) restartChatSegment(ctx context.Context, c runCtx, turn store.RunTurn, code int, logKey *string) bool {
	restarted := false
	err := pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		chat, err := lockRunChat(ctx, q, c.run)
		if err != nil {
			return err
		}
		run, err := q.LockRun(ctx, c.run.ID)
		if err != nil || run.State != "running" {
			return err
		}
		if err := verifyExecution(ctx, q, run.ID); err != nil {
			return err
		}
		if restarted, err = runs.RestartChatSegment(ctx, q, chat, run, turn); err != nil || !restarted {
			return err
		}
		exit := int32(code)
		return q.FinishTurn(ctx, store.FinishTurnParams{ID: turn.ID, ExitCode: &exit, LogKey: logKey, Usage: []byte("{}")})
	})
	if err != nil {
		r.Log.Error("restart chat segment", "run", c.run.ID, "err", err)
		return false
	}
	return restarted
}

func (r *Runner) failChat(ctx context.Context, c runCtx, outcome string) {
	err := r.retryChatTransaction(ctx, func(ctx context.Context, q *store.Queries) error {
		chat, err := lockRunChat(ctx, q, c.run)
		if err != nil {
			return err
		}
		run, err := q.LockRun(ctx, c.run.ID)
		if err != nil {
			return err
		}
		if run.State != "running" && run.State != "paused" && run.State != "starting" {
			return nil
		}
		if err := verifyExecution(ctx, q, run.ID); err != nil {
			return err
		}
		if err = q.FinishUnfinishedChatTurns(ctx, run.ID); err != nil {
			return err
		}
		if _, err = q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chat.ID, Role: "system", BodyMd: outcome, RunID: &run.ID, ContextRefs: []byte("[]"), Citations: []byte("[]")}); err != nil {
			return err
		}
		if err := idleChat(ctx, q, chat, run, "failed"); err != nil {
			return err
		}
		return runs.ResumeInterruptedChat(ctx, q, chat.ID, run.ID, nil, 0)
	})
	if err != nil {
		r.Log.Error("fail chat turn", "run", c.run.ID, "err", err)
	}
}

// expireIdleChats completes chat segments that have waited on the person
// longer than ChatIdleTTL, so a runner doesn't keep their workspace forever.
// The chat itself stays usable: its next message starts a new segment that
// gets the conversation so far as a handoff.
func (r *Runner) expireIdleChats(ctx context.Context) {
	ttl := r.Cfg.ChatIdleTTL
	if ttl <= 0 {
		ttl = DefaultChatIdleTTL
	}
	ids, err := r.q().IdleChatRuns(ctx, time.Now().Add(-ttl))
	if err != nil {
		r.Log.Warn("idle chat runs", "err", err)
		return
	}
	for _, row := range ids {
		if err := r.expireIdleChat(ctx, store.Run{ID: row.ID, WorkspaceID: row.WorkspaceID}); err != nil {
			r.Log.Warn("end idle chat", "run", row.ID, "err", err)
		}
	}
}

func (r *Runner) expireIdleChat(ctx context.Context, run store.Run) error {
	id := run.ID
	return pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		q := store.New(tx)
		// Session lock before run lock, like every chat mutation.
		chat, err := lockRunChat(ctx, q, run)
		if errors.Is(err, pgx.ErrNoRows) {
			chat = store.ChatSession{} // no chat holds this segment any more; still end it
		} else if err != nil {
			return err
		}
		if run, err = q.LockRun(ctx, id); err != nil {
			return err
		}
		// A message may have arrived since the scan.
		if run.State != "waiting" || chat.State == "running" {
			return nil
		}
		busy, err := q.HasRunningChatTurn(ctx, id)
		if err != nil || busy {
			return err
		}
		outcome := "The chat went idle."
		if _, err = q.SetRunState(ctx, store.SetRunStateParams{ID: id, State: "completed", Outcome: &outcome}); err != nil {
			return err
		}
		if err = q.DropPendingTurns(ctx, id); err != nil {
			return err
		}
		if err = q.ExpireRunApprovals(ctx, id); err != nil {
			return err
		}
		payload, _ := json.Marshal(map[string]any{"state": "chat_segment_ended", "reason": "idle"})
		if err = q.AddRunEvent(ctx, store.AddRunEventParams{RunID: id, Type: "lifecycle", Payload: payload}); err != nil {
			return err
		}
		if chat.CurrentRunID != nil && *chat.CurrentRunID == id && slices.Contains([]string{"idle", "failed"}, chat.State) {
			if _, err = q.SetChatRunState(ctx, store.SetChatRunStateParams{ID: chat.ID, State: chat.State}); err != nil {
				return err
			}
		}
		return runs.RecomputeAgentStatus(ctx, q, run.AgentID)
	})
}
