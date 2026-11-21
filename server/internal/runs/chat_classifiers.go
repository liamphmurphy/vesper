package runs

import (
	"context"
	"regexp"
	"slices"
	"strings"

	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Before a person's message starts a turn, a set of cheap rules judge it
// against the recent conversation. A rule can change the turn's effort or add
// a hidden note for the persona; every firing is logged as a "chat_classified" lifecycle
// event, so its hit rate can be read back. Notes carry fixed text only, never
// the person's words.

// classifierHistory bounds how far back the rules look.
const (
	classifierHistory  = 12
	classifierRowChars = 4000
	// substantialReply is the length of a reply worth inheriting effort from.
	substantialReply = 1500
	// confirmationWords is the longest message treated as a bare go-ahead.
	confirmationWords = 8
	// ticketSizedWords keeps a one-line "refactor this" from suggesting a ticket.
	ticketSizedWords = 25
	mentionStreak    = 2
)

var autoLevels = []string{"low", "medium", "high", "xhigh"}

var (
	confirmationRe = regexp.MustCompile(`^(yes|yep|yeah|yup|sure|ok|okay|go ahead|do it|ship it|sounds good|lgtm|please do|proceed|let'?s (do it|go))\b`)
	choicesFenceRe = regexp.MustCompile("(?m)^ {0,3}(`{3,}|~{3,})[ \t]*choices\\b")
	retryRe        = regexp.MustCompile(`\b(try again|redo (it|that)|that'?s (wrong|not right|incorrect)|(doesn'?t|didn'?t) work|still (broken|wrong|failing)|think harder|look again|you missed|not what i)\b`)
	correctionRe   = regexp.MustCompile(`^(no|nope|wait|stop|actually|hold on|not that)\b|\binstead\b`)
	repoAskRe      = regexp.MustCompile(`\b(repo|repository|codebase|branch|pull request|merged|latest changes|the code)\b`)
	imageAskRe     = regexp.MustCompile(`\b(draw|generate|make|create|paint)\b.{0,30}\b(image|picture|photo|illustration|portrait)\b`)
	codeAskRe      = regexp.MustCompile(`\b(fix|implement|refactor|commit|push|open a (pr|pull request))\b`)
	bigWorkRe      = regexp.MustCompile(`\b(epic|multi[- ]?(day|week|sprint)|across the (whole |entire )?(codebase|repo|system))\b`)
	memoryAskRe    = regexp.MustCompile(`\b(remember (that|this|to)|i told you|like i said|as i (said|mentioned)|i (always|never) (want|prefer|like))\b`)
	memoryNotRe    = regexp.MustCompile(`\b(don'?t|do not|do you|can'?t|cannot) remember\b`)
	linkRe         = regexp.MustCompile(`https?://\S+`)
)

// turnSignals is what the rules judge a message by.
type turnSignals struct {
	Body                    string
	Interrupted, Edited     bool
	PrevUser, PrevAssistant string
	Caps                    ChatCaps
	// RepeatMention is another persona the person keeps bringing in, if any.
	RepeatMention string
	// Workflows are the person's published workflows.
	Workflows []store.Workflow
}

// turnDecision is the rules' verdict on one message.
type turnDecision struct {
	Level string
	Notes []string
	Fired []string
}

func (d *turnDecision) fire(name, note string) {
	d.Fired = append(d.Fired, name)
	if note != "" {
		d.Notes = append(d.Notes, note)
	}
}

// levelRules are the rules that raise a turn's effort level.
var levelRules = []string{"confirmation", "effort_mismatch"}

// effortReasons are the fired rules that raised the turn's level.
func (d turnDecision) effortReasons() []string {
	var out []string
	for _, f := range d.Fired {
		if slices.Contains(levelRules, f) {
			out = append(out, f)
		}
	}
	return out
}

// prompt is the turn's prompt with the decision's notes after it, at the end
// so a note never disturbs the cached prefix.
func (d turnDecision) prompt(prompt string) string {
	for _, n := range d.Notes {
		prompt += "\n\n(Vesper: " + n + ")"
	}
	return prompt
}

func higherLevel(a, b string) string {
	if slices.Index(autoLevels, b) > slices.Index(autoLevels, a) {
		return b
	}
	return a
}

func stepLevel(level string) string {
	return autoLevels[min(slices.Index(autoLevels, level)+1, len(autoLevels)-1)]
}

// classifyTurn applies the rules. It is pure; classifyChatTurn gathers s.
func classifyTurn(s turnSignals) turnDecision {
	s.Body = chatRequestText(s.Body)
	s.PrevUser = chatRequestText(s.PrevUser)
	t := strings.ToLower(strings.TrimSpace(s.Body))
	words := len(strings.Fields(t))
	level := chatmodels.AutoLevel(s.Body)
	d := turnDecision{Level: level}
	hadReply := s.PrevAssistant != ""
	code := chatmodels.MentionsCode(t) || repoAskRe.MatchString(t)

	// A go-ahead carries the weight of what it approves.
	if hadReply && words <= confirmationWords && (confirmationRe.MatchString(t) || choicesFenceRe.MatchString(s.PrevAssistant)) {
		inherited := higherLevel(level, chatmodels.AutoLevel(s.PrevUser))
		if len(s.PrevAssistant) >= substantialReply {
			inherited = higherLevel(inherited, "high")
		}
		if inherited != level {
			d.Level = inherited
			d.fire("confirmation", "")
		}
	}
	if hadReply && retryRe.MatchString(t) || s.Edited {
		d.Level = stepLevel(higherLevel(d.Level, chatmodels.AutoLevel(s.PrevUser)))
		d.fire("effort_mismatch", "")
	}
	if s.Interrupted && correctionRe.MatchString(t) {
		d.fire("course_correction", "The person stopped your last reply to correct it. Re-read what they asked before continuing, and don't resume the stopped approach unless it still fits.")
	}
	if s.Caps.RepoCoding() && code {
		d.fire("needs_code", "This message looks like it depends on the repository. Fetch the latest and read the relevant code before answering; don't rely on what you remember of it.")
	}
	if s.RepeatMention != "" {
		d.fire("persona_fit", "In this conversation the person keeps bringing in "+s.RepeatMention+". If this message suits them better, suggest it in a sentence, naming them without the @ sign.")
	}
	if imageAskRe.MatchString(t) && !s.Caps.Images {
		d.fire("capability_mismatch", "This message seems to ask for a generated image, which you aren't allowed to make. Say so, and that image generation can be enabled in the persona's settings, instead of attempting it.")
	} else if !s.Caps.Coding() && codeAskRe.MatchString(t) && code {
		d.fire("capability_mismatch", "This message seems to ask for changes to code, which you can't make in this chat. Say so, and that it needs a persona allowed to write code, instead of attempting it.")
	}
	if !strings.Contains(t, "ticket") && (bigWorkRe.MatchString(t) || (level == "xhigh" && words >= ticketSizedWords)) {
		d.fire("ticket_sized", "This looks bigger than one chat. Offer in one sentence to create a ticket or epic for it; don't create one unless the person asks.")
	}
	for _, w := range s.Workflows {
		if namesWorkflow(t, w.Name) {
			d.fire("workflow_match", "This message names the published workflow "+w.ID.String()+". Offer it with a workflow-run card unless the person is only asking about it.")
			break
		}
	}
	if memoryAskRe.MatchString(t) && !memoryNotRe.MatchString(t) {
		d.fire("memory_worthy", "This message may state something durable or refer to something said before. Check memory if it refers back, and save it if it's a lasting preference or fact, unless it's sensitive.")
	}
	if linkRe.MatchString(s.Body) {
		d.fire("has_link", "The person included a link. Open it, or read its transcript if it's a video, before answering about it.")
	}
	return d
}

// namesWorkflow reports whether lowered text refers to a workflow by name. A
// one-word name must sit beside the word "workflow": a workflow called "test"
// shouldn't match every message about tests.
func namesWorkflow(text, name string) bool {
	name = strings.ToLower(strings.TrimSpace(name))
	if name == "" {
		return false
	}
	q := regexp.QuoteMeta(name)
	pattern := `\b` + q + `\b`
	if !strings.Contains(name, " ") {
		pattern = `\b` + q + ` workflow\b|\bworkflow (called |named )?` + q + `\b`
	}
	return regexp.MustCompile(pattern).MatchString(text)
}

// classifyChatTurn gathers the signals for a person's message and judges it.
// The message itself may already be stored (an edit, or an interruption that
// waited). The caller holds the chat lock and has set the speaker.
func classifyChatTurn(ctx context.Context, q *store.Queries, chat store.ChatSession, body string, interrupted, edited bool) (turnDecision, error) {
	s := turnSignals{Body: body, Interrupted: interrupted, Edited: edited}
	rows, err := q.ListRecentChatMessages(ctx, store.ListRecentChatMessagesParams{SessionID: chat.ID, RowLimit: classifierHistory, MaxChars: classifierRowChars})
	if err != nil {
		return turnDecision{}, err
	}
	if len(rows) > 0 && rows[0].Role == "user" && strings.HasPrefix(body, rows[0].BodyMd) {
		rows = rows[1:]
	}
	var earlier []string
	for _, r := range rows {
		switch {
		case r.Role == "user":
			if s.PrevUser == "" {
				s.PrevUser = r.BodyMd
			}
			earlier = append(earlier, r.BodyMd)
		case s.PrevAssistant == "" && s.PrevUser == "":
			s.PrevAssistant = r.BodyMd
		}
	}
	if s.Caps, err = chatCaps(ctx, q, chat); err != nil {
		return turnDecision{}, err
	}
	if s.Workflows, err = q.ListPublishedWorkflows(ctx, store.ListPublishedWorkflowsParams{WorkspaceID: chat.WorkspaceID, UserID: chat.CreatedBy}); err != nil {
		return turnDecision{}, err
	}
	if !strings.Contains(body, "@") && slices.ContainsFunc(earlier, func(b string) bool { return strings.Contains(b, "@") }) {
		ps, err := ownerPersonas(ctx, q, chat)
		if err != nil {
			return turnDecision{}, err
		}
		speaker := ChatSpeakerID(chat)
		counts := map[string]int{}
		for _, b := range earlier {
			for _, id := range PersonaMentions(b, ps) {
				if speaker == nil || id != *speaker {
					counts[personaName(ps, &id)]++
				}
			}
		}
		for _, p := range ps {
			if name := strings.TrimSpace(p.Name); counts[name] >= mentionStreak {
				s.RepeatMention = name
				break
			}
		}
	}
	return classifyTurn(s), nil
}

// startClassifiedChatTurn starts the turn for a person's message under the
// rules' verdict and logs what fired.
func startClassifiedChatTurn(ctx context.Context, q *store.Queries, chat store.ChatSession, project, prompt, body string, interrupted, edited bool, handoffChars int) (store.ChatSession, store.Run, store.RunTurn, error) {
	return startClassifiedChatTurnWithRollover(ctx, q, chat, project, prompt, body, interrupted, edited, handoffChars, 0)
}

func startClassifiedChatTurnWithRollover(ctx context.Context, q *store.Queries, chat store.ChatSession, project, prompt, body string, interrupted, edited bool, handoffChars int, autoRolloverDefault int64) (store.ChatSession, store.Run, store.RunTurn, error) {
	d, err := classifyChatTurn(ctx, q, chat, body, interrupted, edited)
	if err != nil {
		return chat, store.Run{}, store.RunTurn{}, err
	}
	chat, run, turn, err := startChatTurnWithRollover(ctx, q, chat, project, d.prompt(prompt), d.Level, false, handoffChars, autoRolloverDefault)
	if err != nil || len(d.Fired) == 0 {
		return chat, run, turn, err
	}
	// A chosen effort ignores the level, so only an automatic turn has reasons to show.
	if reasons := d.effortReasons(); chat.Effort == "" && len(reasons) > 0 {
		if err = q.SetTurnEffortReasons(ctx, store.SetTurnEffortReasonsParams{ID: turn.ID, Reasons: reasons}); err != nil {
			return chat, run, turn, err
		}
		turn.EffortReasons = reasons
	}
	return chat, run, turn, event(ctx, q, run.ID, "lifecycle", map[string]any{"state": "chat_classified", "fired": d.Fired, "level": d.Level, "chat_effort": chat.Effort})
}
