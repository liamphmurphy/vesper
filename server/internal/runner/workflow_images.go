package runner

import (
	"bytes"
	"context"
	"errors"
	"fmt"

	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/harness"
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
