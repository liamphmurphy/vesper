package runner_test

import (
	"crypto/rand"
	"encoding/base64"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/fake"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/speech"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// A voiced persona's reply is pre-synthesized only when the person spoke, and
// then as one request for the whole reply under the key the speech endpoint
// uses, so the client joins it instead of paying for a second request.
func TestOnlySpokenTurnsPreSynthesizeTheirWholeReply(t *testing.T) {
	e := setup(t)
	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	if err != nil {
		t.Fatal(err)
	}
	reg := media.NewRegistry()
	ctrl := &fake.Controller{}
	fake.RegisterSpeech(reg, ctrl)
	svc := &media.Service{Pool: e.pool, Box: box, Registry: reg}
	if _, err := svc.SaveProvider(e.ctx, e.ws, fake.SpeechProviderID, nil, nil, map[string]string{"api_key": "k"}); err != nil {
		t.Fatal(err)
	}
	broker := speech.NewBroker(time.Minute)
	t.Cleanup(broker.Close)
	e.runner.Media, e.runner.SpeechBroker = svc, broker

	p := e.persona("Iris", false, false)
	if _, err := e.pool.Exec(e.ctx, "UPDATE personas SET voice_mode = 'always', voice_name = 'Kore' WHERE id = $1", p.ID); err != nil {
		t.Fatal(err)
	}
	assistantReplies := func(chatID uuid.UUID) []string {
		msgs, err := e.q.ListChatMessages(e.ctx, store.ListChatMessagesParams{SessionID: chatID, Limit: 20})
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, m := range msgs {
			if m.Role == "assistant" {
				out = append(out, m.BodyMd)
			}
		}
		return out
	}

	c, err := e.runs.StartChat(e.ctx, e.ws, e.me.ID, runs.ChatInput{
		Project: "PAY", Title: "Voice", PersonaID: &p.ID,
		Message: &runs.ChatMessageInput{Body: "a typed question"},
	})
	if err != nil {
		t.Fatal(err)
	}
	e.until("typed reply", func() bool { return e.chat(c.ID).State == "idle" && len(assistantReplies(c.ID)) > 0 })
	if n := len(ctrl.SpeechRequests()); n != 0 {
		t.Fatalf("speech requests after a typed turn = %d, want 0", n)
	}

	if _, err := e.runs.PostChatMessage(e.ctx, e.ws, e.me.ID, c.ID, runs.ChatMessageInput{Body: "a spoken question", Voice: true}); err != nil {
		t.Fatal(err)
	}
	typed := len(assistantReplies(c.ID))
	// The turn may store an opening line ahead of its answer; the answer is last.
	e.until("spoken reply", func() bool { return e.chat(c.ID).State == "idle" && len(assistantReplies(c.ID)) > typed })
	replies := assistantReplies(c.ID)
	reply := replies[len(replies)-1]
	text, words := speech.Speakable(reply, speech.MaxWords)
	if words == 0 {
		t.Fatalf("the fake reply %q has nothing to speak", reply)
	}
	e.until("pre-synthesis", func() bool { return len(ctrl.SpeechRequests()) > 0 })
	if reqs := ctrl.SpeechRequests(); len(reqs) != 1 || reqs[0].Text != text || reqs[0].Voice != "Kore" {
		t.Fatalf("speech requests = %+v, want one for the whole reply %q", reqs, text)
	}
	hit, wav, _, err := broker.Subscribe(e.ctx, speech.CacheHash(fake.SpeechProviderID, "Kore", "", text), nil)
	if !hit || err != nil || len(wav) == 0 {
		t.Fatalf("broker under the endpoint's key: hit %v, %d bytes, err %v", hit, len(wav), err)
	}
}
