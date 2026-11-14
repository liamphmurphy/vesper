package runs

import (
	"context"
	"errors"
	"fmt"
	"maps"
	"regexp"
	"slices"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Several personas in one chat. The chat's persona is its host; anyone (the
// person or a persona's reply) brings another of the person's personas in by
// mentioning it as @Name. One persona answers each turn: its voice and
// capabilities apply to that turn only (chatCaps), and a reply that mentions
// others hands the conversation on, at most MaxRelayTurns times per message
// from the person, unless that message asks for more or fewer (RelayLimitIn).

const (
	// MaxRelayTurns bounds the replies personas hand to each other after one
	// message from the person, so two personas can't mention each other forever.
	MaxRelayTurns = 4
	// MaxRelayLimit bounds what a message from the person may raise that to.
	MaxRelayLimit = 50
	// MaxPendingPersonaProposals bounds proposals waiting in one chat.
	MaxPendingPersonaProposals = 3
	// MaxProposalReasonRunes bounds why a persona proposes another.
	MaxProposalReasonRunes = 500
)

// ChatSpeakerID is the persona answering the chat: its speaker, else its host.
// nil is the built-in Assistant.
func ChatSpeakerID(chat store.ChatSession) *uuid.UUID {
	if chat.SpeakerPersonaID != nil {
		return chat.SpeakerPersonaID
	}
	return chat.PersonaID
}

// PersonaMentions returns the personas body mentions as @Name, in order of first
// mention, without repeats. Names match case-insensitively and may contain
// spaces; the longest name wins ("@Ada Lovelace" over "@Ada"). The @ must
// start the text or follow a character that isn't a letter or digit (so an
// email address isn't a mention), and the name must end at one too.
func PersonaMentions(body string, ps []store.Persona) []uuid.UUID {
	body = chatRequestText(body)
	byLen := slices.Clone(ps)
	slices.SortStableFunc(byLen, func(a, b store.Persona) int {
		return utf8.RuneCountInString(b.Name) - utf8.RuneCountInString(a.Name)
	})
	out := []uuid.UUID{}
	prev := ' '
	for i, r := range body {
		if r != '@' || isWordRune(prev) {
			prev = r
			continue
		}
		prev = r
		rest := body[i+1:]
		for _, p := range byLen {
			name := strings.TrimSpace(p.Name)
			if len(rest) < len(name) || !strings.EqualFold(rest[:len(name)], name) {
				continue
			}
			if next, _ := utf8.DecodeRuneInString(rest[len(name):]); len(rest) > len(name) && isWordRune(next) {
				continue
			}
			if !slices.Contains(out, p.ID) {
				out = append(out, p.ID)
			}
			break
		}
	}
	return out
}

func isWordRune(r rune) bool { return unicode.IsLetter(r) || unicode.IsDigit(r) || r == '_' }

// contextMarkers start the context a dock appends to a message: Knowledge's
// page context (knowledge-dock.tsx) and the run or ticket beside the work chat
// (web/lib/work-context.ts). It is source material, so mentions and hand-off
// instructions there must not change chat controls.
var contextMarkers = []string{
	"\n\n<!-- vesper:knowledge-context -->\n",
	"\n\n<!-- vesper:work-context -->\n",
	"\n\n<!-- vesper:custom-app-context -->\n",
}

func chatRequestText(body string) string {
	for _, marker := range contextMarkers {
		body, _, _ = strings.Cut(body, marker)
	}
	return body
}

var (
	relayNumber = `(\d{1,4}|` + strings.Join(slices.Sorted(maps.Keys(numberWords)), "|") + `)`
	// "talk up to 25 messages", "go for another ten rounds", "no more than 3 replies".
	relayCount = regexp.MustCompile(`(?i)\b(?:up to|for|another|at most|max(?:imum)?(?: of)?|limit(?:ed)?(?: it)? (?:of|to|at)|no more than|keep (?:it )?(?:to|under)|until|talk|chat|go|continue)\s+` +
		relayNumber + `\s+(?:more\s+)?(?:messages?|replies|reply|responses?|turns?|rounds?|exchanges?|times|hand-?offs?)\b`)
	// "talk with no limit", "unlimited replies".
	relayUnlimited = regexp.MustCompile(`(?i)\b(?:no (?:message |reply |turn )?limit|unlimited (?:messages|replies|turns|rounds))\b`)
)

var numberWords = map[string]int{
	"one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
	"eleven": 11, "twelve": 12, "fifteen": 15, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
}

// RelayLimitIn reads how many replies the person's message lets personas hand
// to each other ("talk up to 25 messages"), capped at MaxRelayLimit. It
// returns 0 when the message doesn't say, so MaxRelayTurns applies.
func RelayLimitIn(body string) int {
	body = chatRequestText(body)
	if relayUnlimited.MatchString(body) {
		return MaxRelayLimit
	}
	m := relayCount.FindStringSubmatch(body)
	if m == nil {
		return 0
	}
	n, ok := numberWords[strings.ToLower(m[1])]
	if !ok {
		n, _ = strconv.Atoi(m[1])
	}
	return min(n, MaxRelayLimit)
}

// relayLimit is how many replies personas may hand on since the person last wrote.
func relayLimit(chat store.ChatSession) int {
	if chat.RelayLimit > 0 {
		return int(chat.RelayLimit)
	}
	return MaxRelayTurns
}

func ownerPersonas(ctx context.Context, q *store.Queries, chat store.ChatSession) ([]store.Persona, error) {
	return q.ListPersonas(ctx, store.ListPersonasParams{WorkspaceID: chat.WorkspaceID, UserID: chat.CreatedBy})
}

// joinChat adds a persona to the chat's participants (its host already is one).
func joinChat(ctx context.Context, q *store.Queries, chat store.ChatSession, id uuid.UUID) error {
	if chat.PersonaID != nil && *chat.PersonaID == id {
		return nil
	}
	return q.AddChatParticipant(ctx, store.AddChatParticipantParams{ChatID: chat.ID, PersonaID: id})
}

// routeHumanMessage picks who answers the person's message: the first persona
// it mentions (the others queue up after), or whoever answered last. Every
// mentioned persona joins the chat.
func routeHumanMessage(ctx context.Context, q *store.Queries, chat store.ChatSession, body string) (*uuid.UUID, []uuid.UUID, error) {
	if !strings.Contains(body, "@") {
		return ChatSpeakerID(chat), []uuid.UUID{}, nil
	}
	ps, err := ownerPersonas(ctx, q, chat)
	if err != nil {
		return nil, nil, err
	}
	ids := PersonaMentions(body, ps)
	if len(ids) == 0 {
		return ChatSpeakerID(chat), []uuid.UUID{}, nil
	}
	for _, id := range ids {
		if err := joinChat(ctx, q, chat, id); err != nil {
			return nil, nil, err
		}
	}
	return &ids[0], ids[1:], nil
}

// personaName is a persona's display name; nil or unknown is the built-in Assistant.
func personaName(ps []store.Persona, id *uuid.UUID) string {
	if id != nil {
		if i := slices.IndexFunc(ps, func(p store.Persona) bool { return p.ID == *id }); i >= 0 {
			return strings.TrimSpace(ps[i].Name)
		}
	}
	return "Assistant"
}

// chatPersonaIDs is the chat's host (when it has one) and its participants, in
// the order they joined.
func chatPersonaIDs(ctx context.Context, q *store.Queries, chat store.ChatSession) ([]uuid.UUID, error) {
	rows, err := q.ChatParticipants(ctx, []uuid.UUID{chat.ID})
	if err != nil {
		return nil, err
	}
	var out []uuid.UUID
	if chat.PersonaID != nil {
		out = append(out, *chat.PersonaID)
	}
	for _, r := range rows {
		if !slices.Contains(out, r.PersonaID) {
			out = append(out, r.PersonaID)
		}
	}
	return out, nil
}

// GroupNote is the "Other personas" section of a chat turn's instructions,
// rendered fresh every turn: who is answering, who else is in the
// conversation, and how to bring someone in. It is empty when the person has
// a single persona that can't create others, so such chats read as before.
func GroupNote(ctx context.Context, q *store.Queries, chat store.ChatSession) (string, error) {
	ps, err := ownerPersonas(ctx, q, chat)
	if err != nil {
		return "", err
	}
	speaker := ChatSpeakerID(chat)
	canCreate, canPicture := false, false
	if speaker != nil {
		if i := slices.IndexFunc(ps, func(p store.Persona) bool { return p.ID == *speaker }); i >= 0 {
			canCreate = ps[i].CanCreatePersonas
			// avatar_prompt queues a generate_image job, which a Codex chat can't.
			canPicture = ps[i].CanGenerateImages && chat.Harness != agentdef.HarnessCodex
		}
	}
	if len(ps) < 2 && !canCreate {
		return "", nil
	}
	ids, err := chatPersonaIDs(ctx, q, chat)
	if err != nil {
		return "", err
	}
	var in, others []string
	for _, id := range ids {
		if speaker == nil || id != *speaker {
			in = append(in, personaName(ps, &id))
		}
	}
	for _, p := range ps {
		if (speaker == nil || p.ID != *speaker) && !slices.Contains(ids, p.ID) {
			others = append(others, strings.TrimSpace(p.Name))
		}
	}
	var b strings.Builder
	b.WriteString("- You are answering this turn as " + personaName(ps, speaker) + ".\n")
	if len(in) > 0 {
		b.WriteString("- Also in this conversation: " + strings.Join(in, ", ") + ". Earlier replies may be theirs, not yours: don't take credit for them or treat them as your own words.\n")
	}
	if len(others) > 0 {
		b.WriteString("- The person's other personas: " + strings.Join(others, ", ") + ".\n")
	}
	if len(in) > 0 || len(others) > 0 {
		b.WriteString("- To bring a persona in, write @ and their name in your reply, only when the person asks for them or their view would clearly help; they answer after you. Don't write @ before a name just to talk about them.\n")
	}
	if canCreate {
		b.WriteString("- You may propose a new persona with propose_persona when the person asks for one. Nothing is created until they approve it in the chat, and a new persona starts without coding or image permissions.\n")
		if canPicture {
			b.WriteString("- Give it a face: pass avatar_prompt, describing a portrait of it, and the image becomes its profile picture and reference likeness once the person approves.\n")
		}
	}
	return b.String(), nil
}

// RelayChat runs in the runner's transaction right after a turn's reply is
// stored and the chat went idle (the chat lock is held). Personas the reply
// mentions join the queue; the next queued persona then gets its own turn.
// ok is false when the turn failed or was stopped: the queue is dropped.
func RelayChat(ctx context.Context, q *store.Queries, chatID uuid.UUID, reply string, ok bool) error {
	chat, err := q.LockChatSessionByID(ctx, chatID)
	if err != nil {
		return err
	}
	clear := func() error {
		if len(chat.QueuedPersonaIds) == 0 {
			return nil
		}
		_, err := q.SetChatSpeaker(ctx, store.SetChatSpeakerParams{ID: chat.ID, SpeakerPersonaID: chat.SpeakerPersonaID, QueuedPersonaIds: []uuid.UUID{}, RelayTurns: chat.RelayTurns, RelayLimit: chat.RelayLimit})
		return err
	}
	if !ok || chat.Archived || chat.State == "running" {
		return clear()
	}
	ps, err := ownerPersonas(ctx, q, chat)
	if err != nil {
		return err
	}
	from := ChatSpeakerID(chat)
	queue := slices.Clone(chat.QueuedPersonaIds)
	if strings.Contains(reply, "@") {
		for _, id := range PersonaMentions(reply, ps) {
			if (from != nil && id == *from) || slices.Contains(queue, id) {
				continue
			}
			if err := joinChat(ctx, q, chat, id); err != nil {
				return err
			}
			queue = append(queue, id)
		}
	}
	var next *store.Persona
	for next == nil && len(queue) > 0 {
		id := queue[0]
		queue = queue[1:]
		if i := slices.IndexFunc(ps, func(p store.Persona) bool { return p.ID == id }); i >= 0 {
			next = &ps[i]
		}
	}
	if next == nil {
		return clear()
	}
	if limit := relayLimit(chat); int(chat.RelayTurns) >= limit {
		if err := clear(); err != nil {
			return err
		}
		body := fmt.Sprintf("Paused the hand-off to %s after %d replies in a row. Mention @%s to continue, or say how many more replies they may take (\"talk up to 25 messages\").", next.Name, limit, next.Name)
		_, err := q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chat.ID, Role: "system", BodyMd: body, ContextRefs: []byte("[]"), Citations: []byte("[]")})
		return err
	}
	p, err := chatProject(ctx, q, chat)
	if err != nil {
		return err
	}
	if p.Archived {
		return clear()
	}
	fromName := personaName(ps, from)
	if chat, err = q.SetChatSpeaker(ctx, store.SetChatSpeakerParams{ID: chat.ID, SpeakerPersonaID: &next.ID, QueuedPersonaIds: queue, RelayTurns: chat.RelayTurns + 1, RelayLimit: chat.RelayLimit}); err != nil {
		return err
	}
	body := fmt.Sprintf("(Vesper: %s brought you into the conversation in their last reply. Answer as %s: pick up from there and add what you can, without repeating what has been said.)", fromName, strings.TrimSpace(next.Name))
	_, _, _, err = startChatTurn(ctx, q, chat, p.Key, body, "medium", true, 0)
	return err
}

// PersonaProposalInput is what propose_persona asks for: a voice, and
// optionally a picture to make for it (AvatarPrompt).
type PersonaProposalInput struct {
	Name, Tone, Color, Instructions, Reason string
	AvatarPrompt                            string
}

// Where a proposed persona's picture stands (PersonaProposalAvatars).
const (
	ProposalAvatarPending = "pending"
	ProposalAvatarReady   = "ready"
	ProposalAvatarFailed  = "failed"
)

// PersonaProposalAvatars reports the picture of each proposal that asked for
// one, by proposal id. Proposals without a picture are absent.
func PersonaProposalAvatars(ctx context.Context, q *store.Queries, ids []uuid.UUID) (map[uuid.UUID]store.PersonaProposalAvatarsRow, error) {
	rows, err := q.PersonaProposalAvatars(ctx, ids)
	if err != nil {
		return nil, err
	}
	out := make(map[uuid.UUID]store.PersonaProposalAvatarsRow, len(rows))
	for _, r := range rows {
		out[r.ProposalID] = r
	}
	return out, nil
}

// ProposePersona records a persona the chat's current speaker wants to
// create. Only a persona with can_create_personas may propose, read fresh so
// turning it off applies at once; the person approves or declines it from
// the chat (DecidePersonaProposal). Nothing is created until then. An
// AvatarPrompt queues an image job with the proposal, under the same checks
// as generate_image; approving makes that image the persona's avatar.
func (s *Service) ProposePersona(ctx context.Context, ws, runID uuid.UUID, in PersonaProposalInput) (store.PersonaProposal, error) {
	var out store.PersonaProposal
	d, err := personas.CheckDraft(personas.Draft{Name: in.Name, Tone: in.Tone, Color: in.Color, Instructions: in.Instructions})
	if err != nil {
		return out, err
	}
	reason := strings.TrimSpace(in.Reason)
	if utf8.RuneCountInString(reason) > MaxProposalReasonRunes {
		return out, apperr.Invalid("reason", "must be at most %d characters", MaxProposalReasonRunes)
	}
	var avatar *chatImageRequest
	if strings.TrimSpace(in.AvatarPrompt) != "" {
		req, err := s.prepareProposalAvatar(ctx, ws, runID, in.AvatarPrompt)
		if err != nil {
			return out, err
		}
		avatar = &req
	}
	err = s.tx(ctx, func(q *store.Queries) error {
		run, err := q.GetRun(ctx, store.GetRunParams{ID: runID, WorkspaceID: ws})
		if err != nil {
			return err
		}
		if run.Purpose != "chat" || run.State != "running" {
			return apperr.Conflict("propose_persona only works while you are answering a message in a chat")
		}
		found, err := q.ChatSessionForRun(ctx, &run.ID)
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.Conflict("this chat run is no longer attached to a chat")
		}
		if err != nil {
			return err
		}
		chat, err := q.LockChatSession(ctx, store.LockChatSessionParams{ID: found.ID, WorkspaceID: ws})
		if err != nil {
			return err
		}
		speaker := ChatSpeakerID(chat)
		if speaker == nil {
			return apperr.Conflict("The built-in Assistant can't create personas; tell the person to enable it for a persona in Manage personas.")
		}
		p, err := q.GetPersona(ctx, store.GetPersonaParams{ID: *speaker, WorkspaceID: ws, UserID: chat.CreatedBy})
		if errors.Is(err, pgx.ErrNoRows) || (err == nil && !p.CanCreatePersonas) {
			return apperr.Conflict("This persona can't create personas; tell the person it isn't enabled in Manage personas.")
		}
		if err != nil {
			return err
		}
		n, err := q.CountPendingPersonaProposals(ctx, chat.ID)
		if err != nil {
			return err
		}
		if n >= MaxPendingPersonaProposals {
			return apperr.Conflict("%d proposals are already waiting for the person; ask them to decide those first.", n)
		}
		taken, err := q.PersonaNameTaken(ctx, store.PersonaNameTakenParams{WorkspaceID: ws, UserID: chat.CreatedBy, Name: d.Name})
		if err != nil {
			return err
		}
		if taken {
			return apperr.Invalid("name", "the person already has a persona with this name; pick another")
		}
		var jobID *uuid.UUID
		if avatar != nil {
			job, err := insertChatImageJob(ctx, q, *avatar)
			if err != nil {
				return err
			}
			jobID = &job.ID
		}
		out, err = q.CreatePersonaProposal(ctx, store.CreatePersonaProposalParams{ChatID: chat.ID, RunID: &run.ID, ProposedBy: &p.ID, Name: d.Name, Tone: d.Tone, Color: d.Color, CustomInstructions: d.Instructions, Reason: reason, AvatarJobID: jobID})
		if err != nil {
			return err
		}
		_, err = q.BumpChatRevision(ctx, chat.ID)
		return err
	})
	return out, err
}

// prepareProposalAvatar checks an avatar_prompt like a generate_image call,
// with errors that name the field the persona should drop.
func (s *Service) prepareProposalAvatar(ctx context.Context, ws, runID uuid.UUID, prompt string) (chatImageRequest, error) {
	run, err := store.New(s.Pool).GetRun(ctx, store.GetRunParams{ID: runID, WorkspaceID: ws})
	if err != nil {
		return chatImageRequest{}, err
	}
	// A Codex chat makes images itself, into its outbox, with no job to tie
	// to the proposal.
	if run.Harness == agentdef.HarnessCodex {
		return chatImageRequest{}, apperr.Conflict("avatar_prompt isn't available in a Codex chat. Propose the persona without it; the person can give it a picture in Manage personas.")
	}
	req, err := s.prepareChatImage(ctx, ws, runID, prompt, nil)
	var conflict *apperr.ConflictError
	if errors.As(err, &conflict) {
		return req, apperr.Conflict("avatar_prompt can't be used: %s Propose the persona without avatar_prompt instead.", conflict.Error())
	}
	return req, err
}

// ListPersonaProposals returns a chat's proposals, oldest first.
func (s *Service) ListPersonaProposals(ctx context.Context, ws, user, chatID uuid.UUID) ([]store.PersonaProposal, error) {
	q := store.New(s.Pool)
	chat, err := q.GetChatSession(ctx, store.GetChatSessionParams{ID: chatID, WorkspaceID: ws})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && chat.CreatedBy != user) {
		return nil, apperr.ErrNotFound
	}
	if err != nil {
		return nil, err
	}
	return q.ListPersonaProposals(ctx, chat.ID)
}

// PersonaDecision is a decided proposal and, when an approval came with a
// picture, the generated image to make the new persona's avatar from.
type PersonaDecision struct {
	Proposal store.PersonaProposal
	Avatar   *store.ChatAttachment
}

// DecidePersonaProposal approves or declines a pending proposal. Approving
// creates the persona (voice only: every capability off), adds it to the
// chat and, when the chat is idle, lets it introduce itself. A proposal whose
// picture is still being made can't be approved yet; a ready picture becomes
// the persona's reference likeness in the Library, and is returned for the
// caller to store as its avatar, which needs blob I/O outside this transaction.
func (s *Service) DecidePersonaProposal(ctx context.Context, ws, user, chatID, id uuid.UUID, approve bool) (PersonaDecision, error) {
	var out PersonaDecision
	o := personas.Owner{WorkspaceID: ws, UserID: user}
	err := s.tx(ctx, func(q *store.Queries) error {
		// The owner's persona lock before the chat lock, the order a persona
		// delete takes them in.
		if err := personas.LockOwner(ctx, q, o); err != nil {
			return err
		}
		chat, err := lockChat(ctx, q, ws, user, chatID)
		if err != nil {
			return err
		}
		prop, err := q.LockPersonaProposal(ctx, store.LockPersonaProposalParams{ID: id, ChatID: chat.ID})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		if err != nil {
			return err
		}
		if prop.State != "pending" {
			return apperr.Conflict("this proposal was already %s", prop.State)
		}
		ps, err := ownerPersonas(ctx, q, chat)
		if err != nil {
			return err
		}
		by := "A persona"
		if prop.ProposedBy != nil {
			by = personaName(ps, prop.ProposedBy)
		}
		if !approve {
			if out.Proposal, err = q.DecidePersonaProposal(ctx, store.DecidePersonaProposalParams{ID: prop.ID, State: "declined"}); err != nil {
				return err
			}
			if _, err = q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chat.ID, Role: "system", BodyMd: fmt.Sprintf("You declined %s's proposed persona %s.", by, prop.Name), ContextRefs: []byte("[]"), Citations: []byte("[]")}); err != nil {
				return err
			}
			_, err = q.BumpChatRevision(ctx, chat.ID)
			return err
		}
		avatars, err := PersonaProposalAvatars(ctx, q, []uuid.UUID{prop.ID})
		if err != nil {
			return err
		}
		avatar, hasAvatar := avatars[prop.ID]
		if hasAvatar && avatar.AvatarState == ProposalAvatarPending {
			return apperr.Conflict("%s's picture is still being made; approve again in a moment, or decline.", prop.Name)
		}
		created, err := personas.CreateLocked(ctx, q, o, personas.NewInput{Name: prop.Name, Tone: &prop.Tone, Color: &prop.Color, Instructions: &prop.CustomInstructions})
		if err != nil {
			return err
		}
		if hasAvatar && avatar.AttachmentID != nil {
			if out.Avatar, err = useAsPersonaReference(ctx, q, o, *avatar.AttachmentID, created.ID); err != nil {
				return err
			}
		}
		if err = joinChat(ctx, q, chat, created.ID); err != nil {
			return err
		}
		if out.Proposal, err = q.DecidePersonaProposal(ctx, store.DecidePersonaProposalParams{ID: prop.ID, State: "approved", PersonaID: &created.ID}); err != nil {
			return err
		}
		if _, err = q.AppendChatMessage(ctx, store.AppendChatMessageParams{SessionID: chat.ID, Role: "system", BodyMd: fmt.Sprintf("You approved %s, proposed by %s. They joined the conversation.", created.Name, by), ContextRefs: []byte("[]"), Citations: []byte("[]")}); err != nil {
			return err
		}
		if chat, err = q.BumpChatRevision(ctx, chat.ID); err != nil {
			return err
		}
		return introduce(ctx, q, chat, created, by)
	})
	return out, err
}

// useAsPersonaReference marks the Library copy of a generated chat image as
// persona's reference likeness, so the images it makes later keep its face,
// and returns the attachment. It returns nil when the person has since
// deleted the image. A Library copy deleted on its own, or one the person
// already uses as another reference, is left as it is.
func useAsPersonaReference(ctx context.Context, q *store.Queries, o personas.Owner, attachmentID, persona uuid.UUID) (*store.ChatAttachment, error) {
	att, err := q.GetChatAttachment(ctx, store.GetChatAttachmentParams{ID: attachmentID, WorkspaceID: o.WorkspaceID, UserID: o.UserID})
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if err := q.LockLibraryReferences(ctx, store.LockLibraryReferencesParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID}); err != nil {
		return nil, err
	}
	item, err := q.LibraryItemByBlobKey(ctx, store.LibraryItemByBlobKeyParams{WorkspaceID: o.WorkspaceID, UserID: o.UserID, BlobKey: att.BlobKey})
	if errors.Is(err, pgx.ErrNoRows) {
		return &att, nil
	}
	if err != nil {
		return nil, err
	}
	if item.Reference != nil {
		return &att, nil
	}
	// The persona is new, so it has no reference to unmark first.
	role := "persona"
	if _, err := q.SetLibraryReference(ctx, store.SetLibraryReferenceParams{ID: item.ID, WorkspaceID: o.WorkspaceID, UserID: o.UserID, Role: &role, PersonaID: &persona}); err != nil {
		return nil, err
	}
	return &att, nil
}

// introduce gives a newly approved persona a first turn to say hello, when
// the chat can take one now; otherwise it waits to be mentioned.
func introduce(ctx context.Context, q *store.Queries, chat store.ChatSession, p store.Persona, by string) error {
	if chat.Archived || chat.State == "running" {
		return nil
	}
	if chat.CurrentRunID != nil {
		run, err := q.LockRun(ctx, *chat.CurrentRunID)
		if err != nil {
			return err
		}
		if run.State != "waiting" && !slices.Contains(Terminal, run.State) {
			return nil
		}
		if slices.Contains(Terminal, run.State) {
			// The segment ended (idle cleanup); the turn starts a fresh one.
			if chat, err = q.SetChatRunState(ctx, store.SetChatRunStateParams{ID: chat.ID, State: chat.State}); err != nil {
				return err
			}
		}
	}
	proj, err := chatProject(ctx, q, chat)
	if err != nil || proj.Archived {
		return err
	}
	if chat, err = q.SetChatSpeaker(ctx, store.SetChatSpeakerParams{ID: chat.ID, SpeakerPersonaID: &p.ID, QueuedPersonaIds: []uuid.UUID{}, RelayTurns: 0, RelayLimit: 0}); err != nil {
		return err
	}
	body := fmt.Sprintf("(Vesper: the person just approved you, %s, a new persona %s proposed. Introduce yourself in a sentence or two, in your own voice, and say how you can help with the conversation so far.)", strings.TrimSpace(p.Name), by)
	_, _, _, err = startChatTurn(ctx, q, chat, proj.Key, body, "low", true, 0)
	return err
}
