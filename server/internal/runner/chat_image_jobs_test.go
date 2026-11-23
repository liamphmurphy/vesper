package runner_test

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/fake"
	"github.com/liamphmurphy/vesper/server/internal/runner"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// imageChat is a Claude chat whose persona has images on, with Codex
// available in the catalog; the fake Claude turn asks for an image.
func (e env) imageChat(t *testing.T, step string, prompt string) (store.ChatSession, string) {
	t.Helper()
	t.Setenv("FAKE_HARNESS_MODE", "chat-image")
	t.Setenv("FAKE_IMAGE_STEP", step)
	logPath := filepath.Join(t.TempDir(), "harness.log")
	t.Setenv("FAKE_HARNESS_LOG", logPath)
	if err := e.setOverride(agentdef.Override{Harness: agentdef.HarnessClaudeCode, Model: "opus-5.5"}); err != nil {
		t.Fatal(err)
	}
	blobs := &putBlobs{m: map[string][]byte{}}
	e.runner.Blobs, e.runner.Attachments, e.runner.Cfg.AttachmentBucket = blobs, blobs, "artifacts"
	e.runs.ModelDiscovery = func(_ context.Context, h, _ string) ([]chatmodels.Model, error) {
		return []chatmodels.Model{{ID: h + "-small"}, {ID: h + "-main", Default: true}}, nil
	}
	p := e.persona("Artist", false, true)
	chat, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{Project: "PAY", Title: "Art", PersonaID: &p.ID, Message: &runs.ChatMessageInput{Body: prompt}})
	if err != nil {
		t.Fatal(err)
	}
	e.until("reply", func() bool { s := e.chat(chat.ID).State; return s == "idle" || s == "failed" })
	return chat, logPath
}

func (e env) chatMsgs(id uuid.UUID) []store.ChatMessage {
	e.t.Helper()
	rows, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: id, Limit: 100})
	if err != nil {
		e.t.Fatal(err)
	}
	out := make([]store.ChatMessage, len(rows))
	for i, r := range rows {
		out[i] = store.ChatMessage(r)
	}
	return out
}

func (e env) imageJob(runID uuid.UUID) store.ChatImageJob {
	e.t.Helper()
	var j store.ChatImageJob
	if err := e.pool.QueryRow(e.ctx, "SELECT id, state, model, failure_kind, outbox_files, attachment_id, followup_turn_id FROM chat_image_jobs WHERE run_id=$1", runID).
		Scan(&j.ID, &j.State, &j.Model, &j.FailureKind, &j.OutboxFiles, &j.AttachmentID, &j.FollowupTurnID); err != nil {
		e.t.Fatal(err)
	}
	var sess, msg string
	if err := e.pool.QueryRow(e.ctx, "SELECT coalesce(codex_session_id,''), coalesce(error,'') FROM chat_image_jobs WHERE id=$1", j.ID).Scan(&sess, &msg); err != nil {
		e.t.Fatal(err)
	}
	if sess != "" {
		j.CodexSessionID = &sess
	}
	if msg != "" {
		j.Error = &msg
	}
	return j
}

// turns lists a run's turns, oldest first.
func (e env) turns(runID uuid.UUID) []store.RunTurn {
	e.t.Helper()
	ts, err := e.q.ListTurns(e.ctx, runID)
	if err != nil {
		e.t.Fatal(err)
	}
	return ts
}

// A Claude chat asks for an image: after its reply the runner makes it with a
// one-shot Codex step in the same workspace, attaches it under the reply, and
// leaves the chat's own harness session alone. One automatic follow-up turn
// then shows the assistant the image with its prompt to react to.
func TestChatImageJobMakesImageWithCodex(t *testing.T) {
	e := setup(t)
	chat, logPath := e.imageChat(t, "ok", "image: a red fox")
	msgs := e.chatMsgs(chat.ID)
	run := e.chatRun(chat.ID)
	if len(msgs) != 3 || msgs[1].Role != "assistant" || !strings.Contains(msgs[1].BodyMd, "making it") || msgs[2].Role != "assistant" {
		t.Fatalf("messages %+v", msgs)
	}
	atts, err := e.q.ListChatAttachmentsForMessages(e.ctx, []uuid.UUID{msgs[1].ID})
	if err != nil || len(atts) != 1 || atts[0].Source != "generated" || atts[0].ContentType != "image/png" || !strings.HasPrefix(atts[0].Filename, "exec-") {
		t.Fatalf("attachments %+v %v", atts, err)
	}
	// The run keeps the chat harness's own session, and the chat its harness.
	claudeSession := strings.TrimSuffix(strings.TrimPrefix(msgs[1].BodyMd[strings.Index(msgs[1].BodyMd, "session="):], "session="), "): making it (true)")
	if run.HarnessSessionID == nil || *run.HarnessSessionID != claudeSession || run.Harness != agentdef.HarnessClaudeCode || run.State != "waiting" {
		t.Fatalf("run %+v want session %q", run, claudeSession)
	}
	job := e.imageJob(run.ID)
	if job.State != "done" || job.CodexSessionID == nil || *job.CodexSessionID == claudeSession || job.Model != "codex-main" || job.FailureKind != nil {
		t.Fatalf("job %+v", job)
	}
	// The job knows its outbox file and the attachment it became.
	if len(job.OutboxFiles) != 1 || job.OutboxFiles[0] != atts[0].Filename || job.AttachmentID == nil || *job.AttachmentID != atts[0].ID {
		t.Fatalf("job files %v attachment %v, want %s", job.OutboxFiles, job.AttachmentID, atts[0].ID)
	}
	// The follow-up turn has no user message; it got the image as a file with
	// its prompt, couldn't ask for another, and its reply is a normal one.
	turns := e.turns(run.ID)
	if len(turns) != 2 || turns[1].Trigger != runs.TriggerImageFollowup || job.FollowupTurnID == nil || *job.FollowupTurnID != turns[1].ID {
		t.Fatalf("turns %+v job %+v", turns, job)
	}
	if msgs[2].RunTurnID == nil || *msgs[2].RunTurnID != turns[1].ID {
		t.Fatalf("follow-up reply %+v", msgs[2])
	}
	follow := msgs[2].BodyMd
	for _, want := range []string{"seen=1", "isn't available while you react", `Prompt: "a red fox"`, "`.lazyagents/attachments/generated/turn-1/1-" + atts[0].Filename + "`", "Open each image file"} {
		if !strings.Contains(follow, want) {
			t.Fatalf("follow-up lacks %q:\n%s", want, follow)
		}
	}
	// The Claude turns and the Codex step all ran; the step has no session to
	// resume, and the follow-up resumed the chat's own.
	var step, followLog map[string]string
	for _, l := range readLog(t, logPath) {
		if l["harness"] == "codex" {
			step = l
		} else if strings.HasPrefix(l["prompt"], "(Vesper: this is an automatic follow-up") {
			followLog = l
		}
	}
	if step == nil || step["resume"] != "" || step["model"] != "codex-main" || !strings.HasPrefix(step["prompt"], "Generate exactly one image") || step["request"] != "a red fox" {
		t.Fatalf("codex step %+v", step)
	}
	if followLog == nil || followLog["resume"] != claudeSession {
		t.Fatalf("follow-up turn %+v", followLog)
	}
	// Synthetic events carry no prompt; usage from all three processes is on the run.
	evs, _ := e.q.ListRunEvents(e.ctx, store.ListRunEventsParams{RunID: run.ID, Seq: 0})
	var calls, results int
	for _, ev := range evs {
		var p map[string]any
		_ = json.Unmarshal(ev.Payload, &p)
		if p["tool"] != "image_generation" {
			continue
		}
		if strings.Contains(string(ev.Payload), "red fox") || p["id"] != job.ID.String() {
			t.Fatalf("synthetic event %s", ev.Payload)
		}
		switch ev.Type {
		case "tool_call":
			calls++
		case "tool_result":
			results++
			if p["is_error"] != false {
				t.Fatalf("result %s", ev.Payload)
			}
		}
	}
	if calls != 1 || results != 1 {
		t.Fatalf("synthetic events: %d calls %d results", calls, results)
	}
	if run.InputTokens != 4000 || run.OutputTokens != 600 {
		t.Fatalf("usage %d/%d", run.InputTokens, run.OutputTokens)
	}
	// The next turn resumes the chat's own session, untouched by the step.
	if reply := e.say(chat.ID, "thanks"); !strings.Contains(reply.BodyMd, "thanks") || e.chatRun(chat.ID).ID != run.ID || *e.chatRun(chat.ID).HarnessSessionID != claudeSession {
		t.Fatalf("second turn %+v", reply)
	}
}

// A step that fails, makes nothing or is refused by moderation still leaves
// the reply, plus a plain system message saying why (a refusal says so), and
// the follow-up turn tells the assistant the image doesn't exist and why.
const fakeRefusal = "I can't create that image: the request was blocked by the safety system under the content policy."

func TestChatImageJobFailures(t *testing.T) {
	for _, tc := range []struct{ step, kind, reason, system, label string }{
		{"fail", "error", "Codex couldn't finish the image", "Couldn't create the image: Codex couldn't finish the image.", "Failed (error)"},
		// A clean exit with nothing made passes on what Codex said, the only
		// clue to why (a denied copy, an image saved elsewhere).
		{"empty", "error", "no image was produced; Codex said: Image step done", "Couldn't create the image: no image was produced; Codex said: Image step done.", "Failed (error)"},
		{"moderation", "moderation", "rejected by moderation: " + fakeRefusal, "The image request was rejected by moderation: " + fakeRefusal, "Failed (refused by moderation)"},
	} {
		t.Run(tc.step, func(t *testing.T) {
			e := setup(t)
			chat, _ := e.imageChat(t, tc.step, "image: a fox")
			msgs := e.chatMsgs(chat.ID)
			if len(msgs) != 4 || msgs[1].Role != "assistant" || msgs[2].Role != "system" || msgs[2].BodyMd != tc.system || msgs[3].Role != "assistant" {
				t.Fatalf("messages %+v", msgs)
			}
			follow := msgs[3].BodyMd
			if !strings.Contains(follow, tc.label+": "+tc.reason+". No image exists") || !strings.Contains(follow, "seen=0") || strings.Contains(follow, "attachments/generated/") {
				t.Fatalf("follow-up:\n%s", follow)
			}
			atts, _ := e.q.ListChatAttachmentsForMessages(e.ctx, []uuid.UUID{msgs[1].ID})
			run := e.chatRun(chat.ID)
			job := e.imageJob(run.ID)
			if len(atts) != 0 || job.State != "failed" || job.Error == nil || *job.Error != tc.reason || job.FailureKind == nil || *job.FailureKind != tc.kind ||
				job.AttachmentID != nil || job.FollowupTurnID == nil || run.HarnessSessionID == nil || e.chat(chat.ID).State != "idle" {
				t.Fatalf("atts %v job %+v run %+v", atts, job, run)
			}
		})
	}
}

// LAZYAGENTS-97: Codex makes the image (into its own generated_images folder
// for the thread) but its copy into the outbox is denied by the policy hook.
// The runner collects the image from that folder itself, so it still shows
// under the reply and the follow-up turn gets the file.
func TestChatImageJobCollectsImageCodexSaved(t *testing.T) {
	codexHome := t.TempDir()
	t.Setenv("CODEX_HOME", codexHome)
	e := setup(t)
	chat, _ := e.imageChat(t, "saved", "image: a photo of you")
	msgs := e.chatMsgs(chat.ID)
	if len(msgs) != 3 || msgs[1].Role != "assistant" || msgs[2].Role != "assistant" {
		t.Fatalf("messages %+v", msgs)
	}
	atts, err := e.q.ListChatAttachmentsForMessages(e.ctx, []uuid.UUID{msgs[1].ID})
	if err != nil || len(atts) != 1 || atts[0].ContentType != "image/png" || !strings.HasPrefix(atts[0].Filename, "exec-") {
		t.Fatalf("attachments %+v %v", atts, err)
	}
	job := e.imageJob(e.chatRun(chat.ID).ID)
	if job.State != "done" || job.FailureKind != nil || job.CodexSessionID == nil || len(job.OutboxFiles) != 1 || job.OutboxFiles[0] != atts[0].Filename ||
		job.AttachmentID == nil || *job.AttachmentID != atts[0].ID {
		t.Fatalf("job %+v", job)
	}
	// It came from the job's own thread folder, which Codex keeps.
	if _, err := os.Stat(filepath.Join(codexHome, "generated_images", *job.CodexSessionID, atts[0].Filename)); err != nil {
		t.Fatalf("source image: %v", err)
	}
	if follow := msgs[2].BodyMd; !strings.Contains(follow, "seen=1") || strings.Contains(follow, "Failed") {
		t.Fatalf("follow-up:\n%s", follow)
	}
}

// A step whose own copy did get through isn't collected again: the image
// shows once, under the name the step gave it.
func TestChatImageJobDoesNotCollectTwice(t *testing.T) {
	t.Setenv("CODEX_HOME", t.TempDir())
	e := setup(t)
	chat, _ := e.imageChat(t, "saved-copied", "image: a photo of you")
	msgs := e.chatMsgs(chat.ID)
	atts, err := e.q.ListChatAttachmentsForMessages(e.ctx, []uuid.UUID{msgs[1].ID})
	if err != nil || len(atts) != 1 || atts[0].Filename != "portrait.png" {
		t.Fatalf("attachments %+v %v", atts, err)
	}
	if job := e.imageJob(e.chatRun(chat.ID).ID); job.State != "done" || len(job.OutboxFiles) != 1 || job.OutboxFiles[0] != "portrait.png" {
		t.Fatalf("job %+v", job)
	}
}

// A reply that fails after asking for an image never runs the image step and
// gets no follow-up turn: the request still ends with a reason the person
// sees, instead of staying queued with nothing to show for it.
func TestChatImageJobFailedTurnReportsQueuedRequest(t *testing.T) {
	t.Setenv("FAKE_HARNESS_FAIL_AFTER_IMAGE", "1")
	e := setup(t)
	chat, logPath := e.imageChat(t, "ok", "image: a fox")
	const reason = "the reply failed before the image could be made"
	run := e.chatRun(chat.ID)
	job := e.imageJob(run.ID)
	if job.State != "failed" || job.Error == nil || *job.Error != reason || job.FailureKind == nil || *job.FailureKind != "error" || job.FollowupTurnID != nil {
		t.Fatalf("job %+v", job)
	}
	msgs := e.chatMsgs(chat.ID)
	last := msgs[len(msgs)-1]
	if last.Role != "system" || last.BodyMd != "Couldn't create the image: "+reason+"." || e.chat(chat.ID).State != "failed" {
		t.Fatalf("messages %+v", msgs)
	}
	if turns := e.turns(run.ID); len(turns) != 1 {
		t.Fatalf("turns %+v", turns)
	}
	for _, l := range readLog(t, logPath) {
		if l["harness"] == "codex" {
			t.Fatalf("an image step ran: %+v", l)
		}
	}
}

// unreadableOutbox is a backend whose outbox can't be listed, like a Docker
// helper container that fails to start.
type unreadableOutbox struct{ runner.Backend }

func (unreadableOutbox) ReadOutbox(context.Context, string) ([]runner.OutboxFile, []string, error) {
	return nil, nil, errors.New("outbox container failed")
}

// An outbox the runner can't read is reported as such, not as a step that
// made nothing: the image may well be sitting there.
func TestChatImageJobUnreadableOutbox(t *testing.T) {
	e := setup(t)
	e.runner.Backend = unreadableOutbox{e.runner.Backend}
	chat, _ := e.imageChat(t, "ok", "image: a fox")
	job := e.imageJob(e.chatRun(chat.ID).ID)
	if job.State != "failed" || job.Error == nil || *job.Error != "couldn't read the workspace outbox" || job.FailureKind == nil || *job.FailureKind != "error" {
		t.Fatalf("job %+v", job)
	}
	msgs := e.chatMsgs(chat.ID)
	if last := msgs[len(msgs)-1]; last.Role != "assistant" || !strings.Contains(last.BodyMd, "Failed (error): couldn't read the workspace outbox. No image exists") {
		t.Fatalf("messages %+v", msgs)
	}
}

// A hung step is killed at the timeout and reported as such.
func TestChatImageJobTimeout(t *testing.T) {
	e := setup(t)
	e.runner.Cfg.ChatImageTimeout = 1500 * time.Millisecond
	chat, _ := e.imageChat(t, "hang", "image: a fox")
	msgs := e.chatMsgs(chat.ID)
	if len(msgs) != 4 || msgs[2].Role != "system" || msgs[2].BodyMd != "Couldn't create the image: timed out." || !strings.Contains(msgs[3].BodyMd, "Failed (error): timed out.") {
		t.Fatalf("messages %+v", msgs)
	}
	if job := e.imageJob(e.chatRun(chat.ID).ID); job.State != "failed" || *job.Error != "timed out" || *job.FailureKind != "error" {
		t.Fatalf("job %+v", job)
	}
}

// A turn that asked for no image gets no follow-up: the chat idles after its reply.
func TestChatWithoutImageJobsHasNoFollowup(t *testing.T) {
	e := setup(t)
	chat, _ := e.imageChat(t, "ok", "hello there")
	msgs := e.chatMsgs(chat.ID)
	turns := e.turns(e.chatRun(chat.ID).ID)
	if len(msgs) != 2 || msgs[1].Role != "assistant" || len(turns) != 1 || turns[0].Trigger != "comment" {
		t.Fatalf("messages %+v turns %+v", msgs, turns)
	}
}

// A follow-up whose harness fails ends the chat in the normal failed state.
func TestChatImageFollowupFailureFailsChat(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_FAIL_FOLLOWUP", "1")
	chat, _ := e.imageChat(t, "ok", "image: a fox")
	e.until("failed", func() bool { return e.chat(chat.ID).State == "failed" })
	msgs := e.chatMsgs(chat.ID)
	last := msgs[len(msgs)-1]
	if len(msgs) != 3 || msgs[1].Role != "assistant" || last.Role != "system" || e.chatRun(chat.ID).State != "waiting" {
		t.Fatalf("messages %+v", msgs)
	}
	// The person can carry on.
	if reply := e.say(chat.ID, "again?"); !strings.Contains(reply.BodyMd, "again?") {
		t.Fatalf("next turn %+v", reply)
	}
}

// With the workspace's image engine set to Antigravity, the same Claude chat's
// image comes from a one-shot agy step. agy saves into its own folder, so the
// runner collects the file (named in the generator's tool output) into the
// outbox; the job records the harness that made it.
func TestChatImageJobMakesImageWithAntigravity(t *testing.T) {
	e := setup(t)
	home := t.TempDir()
	t.Setenv("HOME", home)
	if _, err := e.pool.Exec(e.ctx, "UPDATE workspaces SET image_engine = 'antigravity' WHERE id = $1", e.ws); err != nil {
		t.Fatal(err)
	}
	chat, logPath := e.imageChat(t, "ok", "image: a red fox")
	run := e.chatRun(chat.ID)
	job := e.imageJob(run.ID)
	var harness string
	if err := e.pool.QueryRow(e.ctx, "SELECT harness FROM chat_image_jobs WHERE id = $1", job.ID).Scan(&harness); err != nil {
		t.Fatal(err)
	}
	if job.State != "done" || harness != agentdef.HarnessAntigravity || job.Model != "antigravity-main" || job.FailureKind != nil {
		t.Fatalf("job %+v harness %q", job, harness)
	}
	msgs := e.chatMsgs(chat.ID)
	atts, err := e.q.ListChatAttachmentsForMessages(e.ctx, []uuid.UUID{msgs[1].ID})
	if err != nil || len(atts) != 1 || atts[0].Source != "generated" || atts[0].ContentType != "image/png" || !strings.HasPrefix(atts[0].Filename, "agy-") {
		t.Fatalf("attachments %+v %v", atts, err)
	}
	var step map[string]string
	for _, l := range readLog(t, logPath) {
		if l["harness"] == "antigravity" {
			step = l
		}
	}
	if step == nil || step["resume"] != "" || step["model"] != "antigravity-main" || !strings.HasPrefix(step["prompt"], "Generate exactly one image") || step["request"] != "a red fox" {
		t.Fatalf("agy step %+v", step)
	}
	// The collector reads only from under the harness's home.
	if _, err := os.Stat(filepath.Join(home, ".gemini", "antigravity-cli", "artifacts")); err != nil {
		t.Fatalf("the step saved nothing under its home: %v", err)
	}
}

// An Antigravity step that makes nothing, or a persona that prefers an engine
// that isn't connected, fails with that engine's name.
func TestChatImageJobFailureNamesTheEngine(t *testing.T) {
	e := setup(t)
	t.Setenv("HOME", t.TempDir())
	if _, err := e.pool.Exec(e.ctx, "UPDATE workspaces SET image_engine = 'antigravity' WHERE id = $1", e.ws); err != nil {
		t.Fatal(err)
	}
	chat, _ := e.imageChat(t, "fail", "image: a fox")
	job := e.imageJob(e.chatRun(chat.ID).ID)
	if job.State != "failed" || job.Error == nil || *job.Error != "Antigravity couldn't finish the image" {
		t.Fatalf("job %+v", job)
	}
	found := false
	for _, m := range e.chatMsgs(chat.ID) {
		found = found || (m.Role == "system" && m.BodyMd == "Couldn't create the image: Antigravity couldn't finish the image.")
	}
	if !found {
		t.Fatalf("the person was not told which engine failed: %+v", e.chatMsgs(chat.ID))
	}
}

func (e env) withFakeGeminiImage(t *testing.T) *fake.Controller {
	t.Helper()
	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	if err != nil {
		t.Fatal(err)
	}
	reg := media.NewRegistry()
	ctrl := &fake.Controller{}
	fake.RegisterImage(reg, runs.EngineGemini, ctrl)
	svc := &media.Service{Pool: e.pool, Box: box, Registry: reg}
	if _, err := svc.SaveProvider(e.ctx, e.ws, runs.EngineGemini, nil,
		map[string]string{"image_model": "fake-nano-banana"},
		map[string]string{"api_key": "AIza-test"},
	); err != nil {
		t.Fatal(err)
	}
	e.runner.Media = svc
	e.runs.GeminiImageStatus = func(ctx context.Context, ws uuid.UUID) (string, bool, string) {
		return svc.ImageProviderStatus(ctx, ws, runs.EngineGemini)
	}
	if _, err := e.pool.Exec(e.ctx, "UPDATE workspaces SET image_engine = 'gemini' WHERE id = $1", e.ws); err != nil {
		t.Fatal(err)
	}
	return ctrl
}

// With the workspace's image engine set to Gemini API, a Claude chat's
// generate_image request is fulfilled directly via internal/media without
// launching Codex or Antigravity, passes Library reference images inline, and
// feeds the generated image into the automatic follow-up turn.
func TestChatImageJobMakesImageWithGeminiAPI(t *testing.T) {
	e := setup(t)
	ctrl := e.withFakeGeminiImage(t)
	chat, logPath := e.imageChat(t, "ok", "image: a neon fox")
	run := e.chatRun(chat.ID)
	job := e.imageJob(run.ID)
	var h string
	if err := e.pool.QueryRow(e.ctx, "SELECT harness FROM chat_image_jobs WHERE id = $1", job.ID).Scan(&h); err != nil {
		t.Fatal(err)
	}
	if job.State != "done" || h != runs.EngineGemini || job.Model != "fake-nano-banana" || job.FailureKind != nil {
		t.Fatalf("job %+v harness %q", job, h)
	}
	reqs := ctrl.ImageRequests()
	if len(reqs) != 1 || reqs[0].Prompt != "a neon fox" || reqs[0].Model != "fake-nano-banana" {
		t.Fatalf("gemini requests = %+v", reqs)
	}
	// Neither Codex nor Antigravity should have been launched.
	for _, l := range readLog(t, logPath) {
		if l["harness"] == "codex" || l["harness"] == "antigravity" {
			t.Fatalf("unexpected image harness launch: %+v", l)
		}
	}
	msgs := e.chatMsgs(chat.ID)
	if len(msgs) != 3 || msgs[1].Role != "assistant" || msgs[2].Role != "assistant" {
		t.Fatalf("messages = %+v", msgs)
	}
	atts, err := e.q.ListChatAttachmentsForMessages(e.ctx, []uuid.UUID{msgs[1].ID})
	if err != nil || len(atts) != 1 || atts[0].Source != "generated" || atts[0].ContentType != "image/png" || !strings.HasPrefix(atts[0].Filename, "gemini-") {
		t.Fatalf("attachments = %+v, err = %v", atts, err)
	}
	if job.AttachmentID == nil || *job.AttachmentID != atts[0].ID {
		t.Fatalf("job attachment = %v, want %s", job.AttachmentID, atts[0].ID)
	}
}

func TestChatImageJobGeminiModerationRefusal(t *testing.T) {
	e := setup(t)
	ctrl := e.withFakeGeminiImage(t)
	ctrl.ImageErr = func(media.ImageRequest) error {
		return &media.ProviderError{Provider: runs.EngineGemini, Kind: media.ErrKindFiltered, Message: "safety policy"}
	}
	chat, _ := e.imageChat(t, "ok", "image: blocked scene")
	job := e.imageJob(e.chatRun(chat.ID).ID)
	if job.State != "failed" || job.FailureKind == nil || *job.FailureKind != "moderation" || job.Error == nil || !strings.Contains(*job.Error, "safety policy") {
		t.Fatalf("job = %+v", job)
	}
}
