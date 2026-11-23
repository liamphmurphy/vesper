package runs

import (
	"context"
	"errors"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// MaxChatImageJobsPerTurn caps generate_image requests in one chat turn.
const MaxChatImageJobsPerTurn = 2

// TriggerImageFollowup is the run_turns trigger of the one automatic turn that
// follows a chat turn whose generate_image jobs ran: it shows the assistant
// what they made (or why they failed) so it can react. It has no user message.
const TriggerImageFollowup = "image_followup"

// MaxChatImagePromptRunes bounds an image prompt (and chat_image_jobs.prompt).
const MaxChatImagePromptRunes = 4000

// Reference roles a generate_image request may ask for: the likeness of the
// chat's persona, or of the person (their Library 'self' reference).
const (
	ReferencePersona = "persona"
	ReferencePerson  = "person"
)

// ChatReferences are the reference images that apply in chat, by role
// (ReferencePersona, ReferencePerson): the person's own and the speaking
// persona's, read fresh so a change in the Library applies at once.
func ChatReferences(ctx context.Context, q *store.Queries, chat store.ChatSession) (map[string]store.LibraryItem, error) {
	items, err := q.LibraryReferences(ctx, store.LibraryReferencesParams{WorkspaceID: chat.WorkspaceID, UserID: chat.CreatedBy, PersonaID: ChatSpeakerID(chat)})
	if err != nil {
		return nil, err
	}
	out := map[string]store.LibraryItem{}
	for _, it := range items {
		switch {
		case it.Reference == nil:
		case *it.Reference == "self":
			out[ReferencePerson] = it
		case *it.Reference == "persona":
			out[ReferencePersona] = it
		}
	}
	return out, nil
}

// QueueChatImage records a generate_image request from a chat turn on a
// harness that can't make images itself. The runner creates the image with a
// one-shot step on the image engine (Codex or Antigravity) once the turn's reply
// is done. The capability is read
// fresh from the chat's persona, so turning images off applies at once.
// references asks for the persona's and/or the person's likeness; each must
// have a reference image in the person's Library.
func (s *Service) QueueChatImage(ctx context.Context, ws, runID uuid.UUID, prompt string, references []string) (store.ChatImageJob, error) {
	var job store.ChatImageJob
	req, err := s.prepareChatImage(ctx, ws, runID, prompt, references)
	if err != nil {
		return job, err
	}
	err = pgx.BeginFunc(ctx, s.Pool, func(tx pgx.Tx) error {
		tq := store.New(tx)
		if _, err := tq.LockChatSession(ctx, store.LockChatSessionParams{ID: req.chatID, WorkspaceID: ws}); err != nil {
			return err
		}
		job, err = insertChatImageJob(ctx, tq, req)
		return err
	})
	return job, err
}

// chatImageRequest is a checked generate_image request, ready for
// insertChatImageJob.
type chatImageRequest struct {
	ws, runID, turnID, chatID uuid.UUID
	prompt, harness, model    string
	roles                     []string
}

// prepareChatImage checks a request to make an image in a chat turn: the
// prompt, the references, that the run is answering a message on a harness
// that can't make images itself, the persona's capability and that an image
// engine is available. It reads without locking; insertChatImageJob enforces the per-turn
// cap under the chat's lock.
func (s *Service) prepareChatImage(ctx context.Context, ws, runID uuid.UUID, prompt string, references []string) (chatImageRequest, error) {
	var none chatImageRequest
	prompt = strings.TrimSpace(prompt)
	if n := utf8.RuneCountInString(prompt); n < 1 || n > MaxChatImagePromptRunes {
		return none, apperr.Invalid("prompt", "provide 1–4000 characters")
	}
	roles := []string{}
	for _, r := range references {
		if r != ReferencePersona && r != ReferencePerson {
			return none, apperr.Invalid("references", "use %q (your own likeness) or %q (the person's)", ReferencePersona, ReferencePerson)
		}
		if !slices.Contains(roles, r) {
			roles = append(roles, r)
		}
	}
	q := store.New(s.Pool)
	run, err := q.GetRun(ctx, store.GetRunParams{ID: runID, WorkspaceID: ws})
	if err != nil {
		return none, err
	}
	if run.Purpose != "chat" {
		return none, apperr.Conflict("generate_image only works in a chat")
	}
	if run.State != "running" {
		return none, apperr.Conflict("generate_image only works while you are answering a message")
	}
	if agentdef.CapsOf(run.Harness).ChatInlineImageGen {
		return none, apperr.Conflict("This chat runs on Codex: use your own image generation tool, then copy the image into .lazyagents/outbox/. generate_image is for other models.")
	}
	chat, err := q.ChatSessionForRun(ctx, &run.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		return none, apperr.Conflict("this chat run is no longer attached to a chat")
	}
	if err != nil {
		return none, err
	}
	// The Codex step shares the run's token and sees its tools; it must not
	// queue more images for itself.
	if running, err := q.RunningChatImageJobs(ctx, run.ID); err != nil {
		return none, err
	} else if len(running) > 0 {
		return none, apperr.Conflict("An image is being made right now; generate_image isn't available to that step")
	}
	caps, err := chatCaps(ctx, q, chat)
	if err != nil {
		return none, err
	}
	if !caps.Images {
		return none, apperr.Conflict("This persona can't generate images; tell the person it isn't enabled.")
	}
	if len(roles) > 0 {
		refs, err := ChatReferences(ctx, q, chat)
		if err != nil {
			return none, err
		}
		for _, r := range roles {
			if _, ok := refs[r]; ok {
				continue
			}
			if r == ReferencePersona {
				return none, apperr.Conflict("There is no reference image of you (this persona). Call generate_image again without \"persona\" in references, describing your look in the prompt; the person can pick one in their Library with \"Use as reference\".")
			}
			return none, apperr.Conflict("The person hasn't set a reference image of themselves. Call generate_image again without \"person\" in references, describing them in the prompt; they can upload a photo in their Library and choose \"Use as my reference\".")
		}
	}
	catalog, err := s.ChatCatalog().List(ctx, q, ws)
	if err != nil {
		return none, err
	}
	personaEngine, err := chatPersonaImageEngine(ctx, q, chat)
	if err != nil {
		return none, err
	}
	preference, err := ImageEnginePreference(ctx, q, ws, personaEngine)
	if err != nil {
		return none, err
	}
	engine, model, reason := PickImageEngineWith(catalog, s.geminiImageInfo(ctx, ws), preference)
	if reason != "" {
		return none, apperr.Conflict("Image generation isn't available: %s. The person can configure one in Settings → Workspace → Media providers.", reason)
	}
	turn, err := q.RunningChatTurn(ctx, run.ID)
	if errors.Is(err, pgx.ErrNoRows) {
		return none, apperr.Conflict("generate_image only works while you are answering a message")
	}
	if err != nil {
		return none, err
	}
	// The follow-up only reports what earlier requests made; a request from it
	// would queue another follow-up, and so on.
	if turn.Trigger == TriggerImageFollowup {
		return none, apperr.Conflict("generate_image isn't available while you react to the images you already asked for. Tell the person what came of them; make another only when they ask in a new message.")
	}
	return chatImageRequest{ws: ws, runID: run.ID, turnID: turn.ID, chatID: chat.ID, prompt: prompt, harness: engine, model: model, roles: roles}, nil
}

// insertChatImageJob queues a prepared request. The caller holds the chat's
// lock, so two requests can't both pass the per-turn cap.
func insertChatImageJob(ctx context.Context, tq *store.Queries, req chatImageRequest) (store.ChatImageJob, error) {
	n, err := tq.CountChatImageJobsForTurn(ctx, store.CountChatImageJobsForTurnParams{RunID: req.runID, TurnID: req.turnID})
	if err != nil {
		return store.ChatImageJob{}, err
	}
	if n >= MaxChatImageJobsPerTurn {
		return store.ChatImageJob{}, apperr.Conflict("You can request at most %d images in one reply; tell the person to ask again for more.", MaxChatImageJobsPerTurn)
	}
	return tq.CreateChatImageJob(ctx, store.CreateChatImageJobParams{WorkspaceID: req.ws, RunID: req.runID, TurnID: req.turnID, ChatID: req.chatID, Prompt: req.prompt, Model: req.model, Harness: req.harness, ReferenceRoles: req.roles})
}

// ChatImagesOn reports whether the chat's persona may make images right now.
func ChatImagesOn(ctx context.Context, q *store.Queries, chat store.ChatSession) (bool, error) {
	caps, err := chatCaps(ctx, q, chat)
	return caps.Images, err
}
