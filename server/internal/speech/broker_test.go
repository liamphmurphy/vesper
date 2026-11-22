package speech

import (
	"bytes"
	"context"
	"errors"
	"testing"
	"time"
)

func TestLeadWatcherMatchesFinalSplitLead(t *testing.T) {
	chunks := []string{
		"Sure. I checked ",
		"the **runner** and it ",
		"looks fine.\n\nWant ",
		"the logs for it?",
	}
	var w LeadWatcher
	var firedLead string
	fireIdx := -1
	for i, ch := range chunks {
		if lead, ok := w.Feed(ch); ok {
			firedLead = lead
			fireIdx = i
		}
	}
	if fireIdx != 3 {
		t.Fatalf("fired at chunk %d (lead=%q), want chunk 3 once rest has >=2 words", fireIdx, firedLead)
	}
	full, _ := Speakable(chunks[0]+chunks[1]+chunks[2]+chunks[3], MaxWords)
	wantLead, _ := SplitLead(full)
	if firedLead != wantLead {
		t.Fatalf("fired lead = %q, want %q", firedLead, wantLead)
	}
}

func TestLeadWatcherResetsAfterToolCall(t *testing.T) {
	var w LeadWatcher
	w.Feed("Let me check the server logs right now. Holding on.")
	w.Reset()
	if lead, ok := w.Feed("All good, the migration applied cleanly across every node. Ready to deploy?"); !ok || lead != "All good, the migration applied cleanly across every node." {
		t.Fatalf("after reset: ok=%v lead=%q", ok, lead)
	}
}

func TestBrokerStreamsInFlightAndCaches(t *testing.T) {
	b := NewBroker(time.Minute)
	defer b.Close()

	ch1 := []byte{0x01, 0x02, 0x03, 0x04}
	ch2 := []byte{0x05, 0x06, 0x07, 0x08}
	release := make(chan struct{})
	started := make(chan struct{})
	calls := 0

	b.Start("k1", func(ctx context.Context, onChunk func([]byte, int) error) ([]byte, string, error) {
		calls++
		_ = onChunk(ch1, 24000)
		close(started)
		<-release
		_ = onChunk(ch2, 24000)
		return WAVFromPCM(append(append([]byte(nil), ch1...), ch2...), 24000), "gemini-3.8-flash-tts", nil
	})
	<-started
	// Duplicate Start is singleflighted.
	b.Start("k1", func(ctx context.Context, onChunk func([]byte, int) error) ([]byte, string, error) {
		calls++
		return nil, "", errors.New("must not run")
	})

	var got [][]byte
	subDone := make(chan error, 1)
	go func() {
		hit, wav, model, err := b.Subscribe(context.Background(), "k1", func(pcm []byte, rate int) error {
			got = append(got, append([]byte(nil), pcm...))
			if len(got) == 1 {
				close(release)
			}
			return nil
		})
		if err != nil || !hit || model != "gemini-3.8-flash-tts" || len(wav) != 44+len(ch1)+len(ch2) {
			subDone <- errors.New("unexpected subscribe result")
			return
		}
		subDone <- nil
	}()

	if err := <-subDone; err != nil {
		t.Fatal(err)
	}
	if calls != 1 || len(got) != 2 || !bytes.Equal(got[0], ch1) || !bytes.Equal(got[1], ch2) {
		t.Fatalf("calls=%d got=%v", calls, got)
	}
}
