package media

import (
	"context"
	"errors"
	"testing"
	"time"
)

type countingSpeech struct {
	calls int
	err   error
}

func (c *countingSpeech) ID() string                  { return "counting" }
func (c *countingSpeech) Label() string               { return "Counting" }
func (c *countingSpeech) Check(context.Context) error { return nil }
func (c *countingSpeech) Voices() []Voice             { return nil }
func (c *countingSpeech) DefaultVoice() string        { return "" }
func (c *countingSpeech) GenerateSpeech(context.Context, SpeechRequest) (SpeechClip, error) {
	c.calls++
	return SpeechClip{}, c.err
}
func (c *countingSpeech) StreamSpeech(context.Context, SpeechRequest, func(SpeechChunk) error) (SpeechClip, error) {
	c.calls++
	return SpeechClip{}, c.err
}

func TestSpeechQuotaHoldsRequestsUntilTheLimitLifts(t *testing.T) {
	now := time.Date(2026, 11, 22, 20, 0, 0, 0, time.UTC)
	q := &SpeechQuota{now: func() time.Time { return now }}
	capped := &countingSpeech{err: &ProviderError{Kind: ErrKindQuota, RetryAfter: time.Hour, Message: "daily limit used up"}}
	gen := q.Wrap("ws/gemini", capped).(StreamingSpeechGenerator)

	if _, err := gen.StreamSpeech(context.Background(), SpeechRequest{Text: "hi"}, nil); err == nil {
		t.Fatal("first call: want the provider's refusal")
	}
	// Later calls, streaming or not, fail with the same error without
	// reaching the provider, and say how much longer the limit holds.
	now = now.Add(20 * time.Minute)
	for _, call := range []func() error{
		func() error {
			_, err := gen.GenerateSpeech(context.Background(), SpeechRequest{Text: "hi"})
			return err
		},
		func() error {
			_, err := gen.StreamSpeech(context.Background(), SpeechRequest{Text: "hi"}, nil)
			return err
		},
	} {
		var pe *ProviderError
		if err := call(); !errors.As(err, &pe) || pe.Kind != ErrKindQuota || pe.Message != "daily limit used up" || pe.RetryAfter != 40*time.Minute {
			t.Fatalf("held call: err = %+v", err)
		}
	}
	if capped.calls != 1 {
		t.Fatalf("provider calls = %d while the limit holds, want 1", capped.calls)
	}

	// Another workspace's key is unaffected.
	other := &countingSpeech{}
	if _, err := q.Wrap("other/gemini", other).GenerateSpeech(context.Background(), SpeechRequest{Text: "hi"}); err != nil || other.calls != 1 {
		t.Fatalf("other key: err %v, calls %d", err, other.calls)
	}

	// Once it lifts, the provider is asked again.
	now = now.Add(40 * time.Minute)
	capped.err = nil
	if _, err := gen.GenerateSpeech(context.Background(), SpeechRequest{Text: "hi"}); err != nil || capped.calls != 2 {
		t.Fatalf("after reset: err %v, calls %d", err, capped.calls)
	}
}

func TestSpeechQuotaIgnoresOtherFailures(t *testing.T) {
	q := &SpeechQuota{}
	down := &countingSpeech{err: &ProviderError{Kind: ErrKindUnavailable, Message: "HTTP 503"}}
	gen := q.Wrap("ws/gemini", down)
	_, _ = gen.GenerateSpeech(context.Background(), SpeechRequest{Text: "hi"})
	_, _ = gen.GenerateSpeech(context.Background(), SpeechRequest{Text: "hi"})
	if down.calls != 2 {
		t.Fatalf("calls = %d, want every non-quota failure retried", down.calls)
	}
	if _, ok := gen.(StreamingSpeechGenerator); !ok {
		t.Fatal("wrapping dropped StreamSpeech")
	}
	var nilQuota *SpeechQuota
	if nilQuota.Wrap("k", down) != SpeechGenerator(down) {
		t.Fatal("a nil SpeechQuota must leave the generator as is")
	}
}
