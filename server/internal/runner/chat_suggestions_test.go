package runner_test

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/memory"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func (e env) suggestions() []api.ChatSuggestion {
	e.t.Helper()
	raw, err := e.q.GetChatSuggestions(e.ctx, store.GetChatSuggestionsParams{WorkspaceID: e.ws, UserID: e.me.ID})
	if err != nil {
		return nil
	}
	var out []api.ChatSuggestion
	if err := json.Unmarshal(raw, &out); err != nil {
		e.t.Fatal(err)
	}
	return out
}

func (e env) remember(typ, title, summary string) {
	e.t.Helper()
	o := memory.Owner{WorkspaceID: e.ws, UserID: e.me.ID}
	if _, err := memory.New(e.q).Save(e.ctx, o, memory.Input{Title: title, Summary: summary, Body: summary, Type: typ}, memory.Source{Label: "manual"}); err != nil {
		e.t.Fatal(err)
	}
}

func (e env) backdateChats() {
	e.t.Helper()
	if _, err := e.pool.Exec(e.ctx, "UPDATE chat_sessions SET last_message_at = now() - interval '1 hour'"); err != nil {
		e.t.Fatal(err)
	}
}

func harnessCalls(t *testing.T, path string) []map[string]any {
	t.Helper()
	b, err := os.ReadFile(path)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	var out []map[string]any
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if line == "" {
			continue
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(line), &m); err != nil {
			t.Fatal(err)
		}
		out = append(out, m)
	}
	return out
}

// A quiet chat earns a batch from the person's memory and own words, once;
// sensitive memory types and assistant replies never reach the prompt.
func TestChatSuggestionsGeneratedOnceFromSafeContext(t *testing.T) {
	e := setup(t)
	log := filepath.Join(e.dir, "harness.log")
	t.Setenv("FAKE_HARNESS_LOG", log)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	chat := e.startChat("Planning a dungeon crawl")
	e.until("reply", func() bool { return e.chat(chat.ID).State == "idle" })
	e.remember("project", "Writing a novel", "A sci-fi book about traded emotions")
	e.remember("life", "Private diagnosis", "Something the grid must not show")

	// A conversation that only just happened is left to settle.
	t.Setenv("FAKE_HARNESS_MODE", "suggestions")
	before := len(harnessCalls(t, log))
	e.runner.Sweep(e.ctx)
	e.runner.Wait()
	if got := len(harnessCalls(t, log)); got != before || e.suggestions() != nil {
		t.Fatalf("generated during a live conversation: %d calls", got-before)
	}

	e.backdateChats()
	e.runner.Sweep(e.ctx)
	e.runner.Wait()
	got := e.suggestions()
	if len(got) != 4 || got[0].Icon != api.ChatSuggestionIconDice || got[1].Icon != api.ChatSuggestionIconMsg {
		t.Fatalf("suggestions %+v", got)
	}
	calls := harnessCalls(t, log)
	if len(calls) != before+1 {
		t.Fatalf("%d harness calls, want %d", len(calls), before+1)
	}
	call := calls[len(calls)-1]
	prompt := call["full_prompt"].(string)
	for _, want := range []string{"Writing a novel", "Planning a dungeon crawl"} {
		if !strings.Contains(prompt, want) {
			t.Errorf("prompt missing %q", want)
		}
	}
	for _, not := range []string{"Private diagnosis", "Chat reply"} {
		if strings.Contains(prompt, not) {
			t.Errorf("prompt leaked %q", not)
		}
	}
	if call["model"] != "claude-haiku-5-5" {
		t.Errorf("model %v", call["model"])
	}
	if strings.Contains(call["cwd"].(string), chat.ID.String()) {
		t.Errorf("ran in the chat's workspace: %v", call["cwd"])
	}

	// New activity doesn't regenerate inside the retry window, but does after it.
	if _, err := e.pool.Exec(e.ctx, "UPDATE chat_suggestions SET generated_at = now() - interval '1 hour'"); err != nil {
		t.Fatal(err)
	}
	if _, err := e.pool.Exec(e.ctx, "UPDATE chat_sessions SET last_message_at = now() - interval '6 minutes'"); err != nil {
		t.Fatal(err)
	}
	e.runner.Sweep(e.ctx)
	e.runner.Wait()
	if n := len(harnessCalls(t, log)); n != before+1 {
		t.Fatalf("regenerated inside the retry window: %d calls", n)
	}
	if _, err := e.pool.Exec(e.ctx, "UPDATE chat_suggestions SET attempted_at = now() - interval '7 hours'"); err != nil {
		t.Fatal(err)
	}
	e.runner.Sweep(e.ctx)
	e.runner.Wait()
	if n := len(harnessCalls(t, log)); n != before+2 {
		t.Fatalf("didn't regenerate after the retry window: %d calls", n)
	}
}

// A bad answer keeps the batch the person already has, and waits out the
// retry window rather than running again on every sweep.
func TestChatSuggestionsBadAnswerKeepsNothingAndBacksOff(t *testing.T) {
	e := setup(t)
	log := filepath.Join(e.dir, "harness.log")
	t.Setenv("FAKE_HARNESS_LOG", log)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	chat := e.startChat("Hello there")
	e.until("reply", func() bool { return e.chat(chat.ID).State == "idle" })
	before := len(harnessCalls(t, log))
	e.backdateChats() // "chat" mode answers with prose, not suggestions
	e.runner.Sweep(e.ctx)
	e.runner.Wait()
	e.runner.Sweep(e.ctx)
	e.runner.Wait()
	if n := len(harnessCalls(t, log)); n != before+1 {
		t.Fatalf("%d attempts, want 1", n-before)
	}
	if got := e.suggestions(); got != nil {
		t.Fatalf("saved a bad answer: %+v", got)
	}
}

// Forgetting clears what's on screen, and a generation already running can't
// write back a batch that drew on the forgotten entry.
func TestForgetClearsSuggestionsAndDiscardsInFlightBatch(t *testing.T) {
	e := setup(t)
	o := memory.Owner{WorkspaceID: e.ws, UserID: e.me.ID}
	saved, err := memory.New(e.q).Save(e.ctx, o, memory.Input{Title: "Forget me", Summary: "s", Body: "b", Type: "project"}, memory.Source{Label: "manual"})
	if err != nil {
		t.Fatal(err)
	}
	claimed, err := e.q.ClaimChatSuggestions(e.ctx, store.ClaimChatSuggestionsParams{WorkspaceID: e.ws, UserID: e.me.ID, RetryBefore: time.Now()})
	if err != nil {
		t.Fatal(err)
	}
	items := json.RawMessage(`[{"title":"t","prompt":"p","icon":"msg"}]`)
	if n, err := e.q.SaveChatSuggestions(e.ctx, store.SaveChatSuggestionsParams{Items: items, WorkspaceID: e.ws, UserID: e.me.ID, AttemptedAt: claimed}); err != nil || n != 1 {
		t.Fatalf("save %d %v", n, err)
	}
	if err := memory.New(e.q).Forget(e.ctx, o, saved.Memory.ID); err != nil {
		t.Fatal(err)
	}
	if got := e.suggestions(); got != nil {
		t.Fatalf("still showing %+v", got)
	}
	if n, err := e.q.SaveChatSuggestions(e.ctx, store.SaveChatSuggestionsParams{Items: items, WorkspaceID: e.ws, UserID: e.me.ID, AttemptedAt: claimed}); err != nil || n != 0 {
		t.Fatalf("in-flight batch saved: %d %v", n, err)
	}
}

// Deleting a chat or forgetting a memory clears the current batch, and the
// next sweep regenerates fresh starters without waiting out the 6h retry window.
func TestClearingSuggestionsRegeneratesOnNextSweep(t *testing.T) {
	e := setup(t)
	t.Setenv("FAKE_HARNESS_MODE", "chat")
	keep := e.startChat("Keep working on the renderer")
	gone := e.startChat("Throwaway question")
	e.until("replies", func() bool {
		return e.chat(keep.ID).State == "idle" && e.chat(gone.ID).State == "idle"
	})

	t.Setenv("FAKE_HARNESS_MODE", "suggestions")
	e.backdateChats()
	e.runner.Sweep(e.ctx)
	e.runner.Wait()
	if got := e.suggestions(); len(got) != 4 {
		t.Fatalf("initial suggestions %+v", got)
	}

	// Deleting a regular chat clears the batch immediately, and the next sweep
	// replaces it instead of backing off for 6 hours.
	if err := e.runs.DeleteChat(e.ctx, e.ws, e.me.ID, gone.ID); err != nil {
		t.Fatal(err)
	}
	if got := e.suggestions(); got != nil {
		t.Fatalf("still showing after delete: %+v", got)
	}
	e.runner.Sweep(e.ctx)
	e.runner.Wait()
	if got := e.suggestions(); len(got) != 4 {
		t.Fatalf("did not regenerate after chat delete: %+v", got)
	}

	// Same after forgetting a memory.
	o := memory.Owner{WorkspaceID: e.ws, UserID: e.me.ID}
	saved, err := memory.New(e.q).Save(e.ctx, o, memory.Input{Title: "Old project", Summary: "s", Body: "b", Type: "project"}, memory.Source{Label: "manual"})
	if err != nil {
		t.Fatal(err)
	}
	if err := memory.New(e.q).Forget(e.ctx, o, saved.Memory.ID); err != nil {
		t.Fatal(err)
	}
	if got := e.suggestions(); got != nil {
		t.Fatalf("still showing after forget: %+v", got)
	}
	e.runner.Sweep(e.ctx)
	e.runner.Wait()
	if got := e.suggestions(); len(got) != 4 {
		t.Fatalf("did not regenerate after forget: %+v", got)
	}
}
