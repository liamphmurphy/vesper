package runner

import (
	"bytes"
	"cmp"
	"context"
	"encoding/json"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/harness"
	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// workflowImageDir holds the images a workflow step receives from earlier steps.
const workflowImageDir = ".lazyagents/workflow-images/"

// workflowTurnImages prepares a workflow step's workspace: the images from
// earlier steps, as real image inputs, and the outbox of a step that makes
// them. A non-empty failure ends the step: one asked to judge an image must
// not carry on without seeing it.
func (r *Runner) workflowTurnImages(ctx context.Context, q *store.Queries, c runCtx) (files map[string][]byte, paths []string, inline []harness.InlineImage, failure string) {
	files = map[string][]byte{}
	if c.spec.HarnessOptions[agentdef.OptionImageGeneration] == "true" {
		// The directory the step may write to; dot files are never harvested.
		files[".lazyagents/outbox/.keep"] = []byte{}
	}
	images, err := runs.WorkflowStepInputImages(ctx, q, c.run.ID)
	if err != nil {
		r.Log.Warn("workflow input images", "run", c.run.ID, "err", err)
		return nil, nil, nil, "Couldn't load the images from earlier steps."
	}
	if len(images) > 0 && r.Attachments == nil {
		return nil, nil, nil, "Couldn't load the images from earlier steps: no attachment storage is configured."
	}
	var total int64
	for i, im := range images {
		body, err := r.readAttachment(ctx, im.BlobKey)
		if err != nil || len(body) == 0 {
			r.Log.Warn("read workflow image", "run", c.run.ID, "image", im.ID, "err", err)
			return nil, nil, nil, "Couldn't load the images from earlier steps."
		}
		if total += int64(len(body)); total > maxChatAttachmentTurnBytes {
			return nil, nil, nil, "The images from earlier steps are too large to attach."
		}
		ext := referenceExts[im.ContentType]
		if ext == "" {
			return nil, nil, nil, "An image from an earlier step has an unsupported type."
		}
		p := fmt.Sprintf("%s%d%s", workflowImageDir, i+1, ext)
		files[p] = body
		paths = append(paths, p)
		inline = append(inline, harness.InlineImage{MediaType: im.ContentType, Data: body})
	}
	return files, paths, inline, ""
}

// finishWorkflowImageStep stores what an image step left in its outbox. A
// non-empty result is why the step failed; when the harness itself failed for
// another reason it is empty, and the usual handling reports that.
func (r *Runner) finishWorkflowImageStep(ctx context.Context, c runCtx, res harness.Result, code int, waitErr error, sensitive map[string]string) string {
	q := r.q()
	if run, err := q.GetRun(ctx, store.GetRunParams{ID: c.run.ID, WorkspaceID: c.run.WorkspaceID}); err != nil || run.State != "running" {
		return "" // stopped, or re-run by a reviewer: this attempt's images don't count
	}
	step, err := q.WorkflowStepForAgentRun(ctx, &c.run.ID)
	if err != nil {
		r.Log.Warn("workflow image step", "run", c.run.ID, "err", err)
		return "Couldn't record this step's images."
	}
	// A refusal can arrive as an error, as the reply, or in what it submitted.
	refused := func() string {
		check := res
		if check.Final == "" {
			check.Final = step.Output
		}
		if moderated, detail := classifyImageFailure(check, sensitive); moderated {
			return clipReason("The image was rejected by moderation: " + detail)
		}
		return ""
	}
	if waitErr != nil || code != 0 || res.IsError || res.UsageLimited {
		return refused()
	}
	if r.Blobs == nil || r.Cfg.AttachmentBucket == "" {
		return "Generated images can't be stored: no attachment storage is configured."
	}
	wf, err := q.WorkflowRunForAgentRun(ctx, &c.run.ID)
	if err != nil {
		r.Log.Warn("workflow image step", "run", c.run.ID, "err", err)
		return "Couldn't record this step's images."
	}
	used, err := q.ChatGeneratedImageBytes(ctx, store.ChatGeneratedImageBytesParams{WorkspaceID: wf.WorkspaceID, UserID: wf.UserID})
	if err != nil {
		r.Log.Warn("generated image usage", "run", c.run.ID, "err", err)
		return "Couldn't record this step's images."
	}
	if agentdef.CapsOf(c.spec.Harness).CollectsGeneratedImages && res.SessionID != "" {
		// Antigravity's generator saves into its own folder; copy what it made.
		if err := collectAntigravityImages(ctx, r.Backend, wsID(c.run), res.SessionID, res.Images); err != nil {
			r.Log.Warn("collect generated images", "run", c.run.ID, "err", err)
		}
	}
	files, _, err := r.Backend.ReadOutbox(ctx, wsID(c.run))
	if err != nil {
		r.Log.Warn("read workflow outbox", "run", c.run.ID, "err", err)
		return "Couldn't read the generated image."
	}
	var stored []generatedImage
	var quota bool
	for _, f := range files {
		if len(stored) == runs.MaxWorkflowImagesPerStep {
			r.event(ctx, c.run.ID, "lifecycle", map[string]any{"state": "workflow_images_limited", "kept": len(stored), "found": len(files)})
			break
		}
		ct, ok := runs.GeneratedImageType(f.Data)
		name := runs.ChatAttachmentName(f.Name)
		if !ok || name == "" || len(f.Data) == 0 {
			continue
		}
		if used+int64(len(f.Data)) > runs.MaxGeneratedImageStorageBytes {
			quota = true
			continue
		}
		key := runs.ChatAttachmentKey(wf.WorkspaceID, wf.UserID)
		if err := r.Blobs.Put(ctx, r.Cfg.AttachmentBucket, key, bytes.NewReader(f.Data), int64(len(f.Data)), ct); err != nil {
			r.Log.Warn("store workflow image", "run", c.run.ID, "err", err)
			r.dropImageBlobs(stored)
			return "Couldn't store the generated image."
		}
		used += int64(len(f.Data))
		stored = append(stored, generatedImage{name: name, ct: ct, key: key, size: int64(len(f.Data))})
	}
	if len(stored) == 0 {
		if quota {
			return "Your generated image storage is full: delete some images from the Library, then run this again."
		}
		if reason := refused(); reason != "" {
			return reason
		}
		return "The step finished without producing an image."
	}
	bound := false
	err = pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		tq := store.New(tx)
		cur, err := tq.WorkflowStepForAgentRun(ctx, &c.run.ID)
		if err != nil {
			return err
		}
		if cur.State != "running" {
			return nil
		}
		for _, im := range stored {
			if _, err := tq.CreateWorkflowStepImage(ctx, store.CreateWorkflowStepImageParams{StepID: cur.ID, RunID: cur.RunID, Filename: im.name, ContentType: im.ct, SizeBytes: im.size, BlobKey: im.key}); err != nil {
				return err
			}
		}
		bound = true
		// The image is the result, so a step that forgot to report still counts.
		if cur.Output == "" {
			return tq.SetWorkflowStepOutput(ctx, store.SetWorkflowStepOutputParams{ID: cur.ID, Output: "Generated an image."})
		}
		return nil
	})
	if !bound {
		r.dropImageBlobs(stored)
	}
	if err != nil && !errors.Is(err, context.Canceled) {
		r.Log.Warn("record workflow images", "run", c.run.ID, "err", err)
		return "Couldn't record this step's images."
	}
	return ""
}

// runWorkflowGeminiImageStep executes a workflow image step directly against
// the workspace's Gemini media provider without spawning a CLI harness.
func (r *Runner) runWorkflowGeminiImageStep(ctx context.Context, c runCtx, turn store.RunTurn) {
	q := r.q()
	finishTurn := func(code int32) {
		usage, _ := json.Marshal(harness.Usage{})
		if err := q.FinishTurn(context.WithoutCancel(ctx), store.FinishTurnParams{ID: turn.ID, ExitCode: &code, Usage: usage}); err != nil {
			r.Log.Warn("finish gemini workflow turn", "run", c.run.ID, "err", err)
		}
		r.event(context.WithoutCancel(ctx), c.run.ID, "lifecycle", map[string]any{"state": "turn_ended", "turn": turn.Seq, "exit_code": code})
	}
	fail := func(msg string) {
		finishTurn(1)
		r.end(ctx, c, "failed", msg, runs.VerbRunFailed)
	}

	_, _, inputImages, failure := r.workflowTurnImages(ctx, q, c)
	if failure != "" {
		fail(failure)
		return
	}
	if r.Media == nil {
		fail("Gemini API isn't configured on this runner.")
		return
	}
	if r.Blobs == nil || r.Cfg.AttachmentBucket == "" {
		fail("Generated images can't be stored: no attachment storage is configured.")
		return
	}
	gen, _, err := r.Media.ResolveImage(ctx, c.run.WorkspaceID, runs.EngineGemini)
	if err != nil {
		_, msg := media.ClassifyError(err)
		fail(clipReason(cmp.Or(msg, "Gemini API isn't configured.")))
		return
	}

	callID := fmt.Sprintf("gemini-workflow-%s-%d", c.run.ID.String()[:8], turn.Seq)
	r.event(ctx, c.run.ID, "tool_call", map[string]any{"id": callID, "tool": "image_generation", "input": map[string]any{}})

	refs := make([]media.ImageReference, 0, len(inputImages))
	for _, im := range inputImages {
		refs = append(refs, media.ImageReference{Data: im.Data, ContentType: im.MediaType})
	}
	timeout := r.Cfg.ChatImageTimeout
	if timeout <= 0 {
		timeout = DefaultChatImageTimeout
	}
	tctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	img, err := gen.GenerateImage(tctx, media.ImageRequest{
		Prompt:     turn.InputMessage,
		References: refs,
		Model:      c.spec.HarnessOptions[agentdef.OptionImageModel],
	})
	if err != nil {
		if ctx.Err() != nil {
			return // shutting down: Recover re-runs this turn
		}
		kind, msg := media.ClassifyError(err)
		payload := map[string]any{"id": callID, "tool": "image_generation", "is_error": true}
		if kind == media.ErrKindFiltered {
			payload["failure_kind"] = imageFailModeration
			r.event(context.WithoutCancel(ctx), c.run.ID, "tool_result", payload)
			fail(clipReason("The image was rejected by moderation: " + cmp.Or(msg, "blocked by safety filter")))
			return
		}
		r.event(context.WithoutCancel(ctx), c.run.ID, "tool_result", payload)
		if errors.Is(tctx.Err(), context.DeadlineExceeded) {
			fail("Gemini API timed out generating the image.")
			return
		}
		fail(clipReason(cmp.Or(msg, "Gemini API couldn't generate the image.")))
		return
	}
	r.event(ctx, c.run.ID, "tool_result", map[string]any{"id": callID, "tool": "image_generation", "is_error": false})

	ct, ok := runs.GeneratedImageType(img.Data)
	if !ok {
		fail("Gemini API returned an unsupported image format.")
		return
	}
	wf, err := q.WorkflowRunForAgentRun(ctx, &c.run.ID)
	if err != nil {
		r.Log.Warn("workflow gemini image step", "run", c.run.ID, "err", err)
		fail("Couldn't record this step's images.")
		return
	}
	used, err := q.ChatGeneratedImageBytes(ctx, store.ChatGeneratedImageBytesParams{WorkspaceID: wf.WorkspaceID, UserID: wf.UserID})
	if err != nil {
		r.Log.Warn("generated image usage", "run", c.run.ID, "err", err)
		fail("Couldn't record this step's images.")
		return
	}
	if used+int64(len(img.Data)) > runs.MaxGeneratedImageStorageBytes {
		fail("Your generated image storage is full: delete some images from the Library, then run this again.")
		return
	}
	ext := img.FilenameExt
	if ext == "" {
		ext = referenceExts[ct]
	}
	if ext == "" {
		ext = ".png"
	}
	name := fmt.Sprintf("gemini-%s%s", c.run.ID.String()[:8], ext)
	key := runs.ChatAttachmentKey(wf.WorkspaceID, wf.UserID)
	if err := r.Blobs.Put(ctx, r.Cfg.AttachmentBucket, key, bytes.NewReader(img.Data), int64(len(img.Data)), ct); err != nil {
		r.Log.Warn("store workflow gemini image", "run", c.run.ID, "err", err)
		fail("Couldn't store the generated image.")
		return
	}
	stored := []generatedImage{{name: name, ct: ct, key: key, size: int64(len(img.Data))}}
	note := "Generated an image with Gemini API."
	if img.Model != "" {
		note = fmt.Sprintf("Generated an image with Gemini API (%s).", img.Model)
	}
	bound := false
	err = pgx.BeginFunc(ctx, r.Pool, func(tx pgx.Tx) error {
		tq := store.New(tx)
		cur, err := tq.WorkflowStepForAgentRun(ctx, &c.run.ID)
		if err != nil {
			return err
		}
		if cur.State != "running" {
			return nil
		}
		if _, err := tq.CreateWorkflowStepImage(ctx, store.CreateWorkflowStepImageParams{
			StepID: cur.ID, RunID: cur.RunID, Filename: name, ContentType: ct, SizeBytes: int64(len(img.Data)), BlobKey: key,
		}); err != nil {
			return err
		}
		bound = true
		return tq.SetWorkflowStepOutput(ctx, store.SetWorkflowStepOutputParams{ID: cur.ID, Output: note})
	})
	if !bound {
		r.dropImageBlobs(stored)
	}
	if err != nil {
		if ctx.Err() != nil {
			return
		}
		r.Log.Warn("record workflow gemini image", "run", c.run.ID, "err", err)
		fail("Couldn't record this step's images.")
		return
	}
	finishTurn(0)
	r.afterTurn(ctx, c.run.ID, harness.Result{Final: note}, "", 0, nil)
}
