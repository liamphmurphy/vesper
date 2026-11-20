package runner

import (
	"context"
	"fmt"
	"slices"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Reference images (the persona's and the person's likeness, chosen in the
// Library) are delivered into a chat's workspace for the model that makes
// images: the Codex chat itself, or the one-shot Codex step of a
// generate_image request. They are the person's own photos and pictures, so
// their bytes and names never go into run events or logs.

// referenceDir holds a chat workspace's reference images, one per role.
const referenceDir = ".lazyagents/references/"

// referenceRoles are the roles in the order they are delivered.
var referenceRoles = []string{runs.ReferencePersona, runs.ReferencePerson}

// referenceExts names a reference file by its stored type.
var referenceExts = map[string]string{"image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp", "image/gif": ".gif"}

// chatReferences are the reference images delivered for one process: the
// files to write and the delivered path of each role.
type chatReferences struct {
	files map[string][]byte
	paths map[string]string
}

// images lists the delivered files in role order, for Codex image inputs.
func (r chatReferences) images() []string {
	var out []string
	for _, role := range referenceRoles {
		if p, ok := r.paths[role]; ok {
			out = append(out, p)
		}
	}
	return out
}

// loadChatReferences reads the chat's reference images for roles (nil: every
// role that has one). Every other name a role's file could have is written
// empty, so a cleared or replaced picture doesn't stay in the workspace. An
// image that can't be read is left out; that never fails the turn.
func (r *Runner) loadChatReferences(ctx context.Context, q *store.Queries, run store.Run, roles []string) chatReferences {
	out := chatReferences{files: map[string][]byte{}, paths: map[string]string{}}
	for _, role := range referenceRoles {
		for _, ext := range referenceExts {
			out.files[referenceDir+role+ext] = []byte{}
		}
	}
	if r.Attachments == nil {
		return out
	}
	chat, err := q.ChatSessionForRun(ctx, &run.ID)
	if err != nil {
		r.Log.Warn("chat references", "run", run.ID, "err", err)
		return out
	}
	refs, err := runs.ChatReferences(ctx, q, chat)
	if err != nil {
		r.Log.Warn("chat references", "run", run.ID, "err", err)
		return out
	}
	for _, role := range referenceRoles {
		it, ok := refs[role]
		ext, known := referenceExts[it.ContentType]
		if !ok || !known || (roles != nil && !slices.Contains(roles, role)) {
			continue
		}
		body, err := r.readAttachment(ctx, it.BlobKey)
		if err != nil || len(body) == 0 || len(body) > runs.MaxChatAttachmentBytes {
			r.Log.Warn("read reference image", "run", run.ID, "role", role, "err", err)
			continue
		}
		p := referenceDir + role + ext
		out.files[p], out.paths[role] = body, p
	}
	return out
}

// codexChatReferencePrompt tells a Codex chat which reference images this
// turn delivered; "" when there are none.
func codexChatReferencePrompt(refs chatReferences) string {
	if len(refs.paths) == 0 {
		return ""
	}
	return "\n\n(Vesper: reference images for pictures you make: " + describeReferences(refs.paths, "you", "the person") +
		". Whenever an image you make shows you or the person, view the matching file first and keep that likeness.)"
}

// viaEngineReferencePrompt tells a chat that asks an image engine for images with
// generate_image which references it may request; "" when there are none.
func viaEngineReferencePrompt(refs map[string]store.LibraryItem) string {
	var have []string
	for _, role := range referenceRoles {
		if _, ok := refs[role]; ok {
			have = append(have, fmt.Sprintf("%q", role))
		}
	}
	if len(have) == 0 {
		return ""
	}
	return "\n\n(Vesper: reference images are set for generate_image references " + strings.Join(have, " and ") +
		". Pass \"persona\" whenever an image shows you and \"person\" whenever it shows the person, so their likeness is kept.)"
}

// imageStepReferencePrompt tells the image step which attached image
// shows whom; "" when none were delivered.
func imageStepReferencePrompt(refs chatReferences) string {
	if len(refs.paths) == 0 {
		return ""
	}
	return "The attached reference images show the people in it: " + describeReferences(refs.paths, "the chat's persona", "the person the chat is with") +
		". Keep each one's likeness (face, hair, build, distinguishing features) wherever the image shows them. "
}

// describeReferences says which file shows whom, naming the persona and the
// person as the reader knows them.
func describeReferences(paths map[string]string, persona, person string) string {
	var parts []string
	for _, role := range referenceRoles {
		p, ok := paths[role]
		if !ok {
			continue
		}
		who := persona
		if role == runs.ReferencePerson {
			who = person
		}
		parts = append(parts, fmt.Sprintf("%s shows %s", p, who))
	}
	return strings.Join(parts, "; ")
}

// chatTurnReferences is what a chat turn gets of the reference images when
// its persona can make images: a Codex chat has them delivered, with a note
// naming the files; any other chat is told which references generate_image
// can use. Failures only leave the references out.
func (r *Runner) chatTurnReferences(ctx context.Context, q *store.Queries, c runCtx) (files map[string][]byte, prompt string) {
	if agentdef.CapsOf(c.spec.Harness).ChatInlineImageGen {
		if c.spec.HarnessOptions[agentdef.OptionImageGeneration] != "true" {
			return nil, ""
		}
		refs := r.loadChatReferences(ctx, q, c.run, nil)
		return refs.files, codexChatReferencePrompt(refs)
	}
	chat, err := q.ChatSessionForRun(ctx, &c.run.ID)
	if err != nil {
		r.Log.Warn("chat references", "run", c.run.ID, "err", err)
		return nil, ""
	}
	if on, err := runs.ChatImagesOn(ctx, q, chat); err != nil || !on {
		return nil, ""
	}
	refs, err := runs.ChatReferences(ctx, q, chat)
	if err != nil {
		r.Log.Warn("chat references", "run", c.run.ID, "err", err)
		return nil, ""
	}
	return nil, viaEngineReferencePrompt(refs)
}
