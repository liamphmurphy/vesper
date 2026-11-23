package media

import (
	"context"
	"errors"
	"sync"
	"time"
)

// defaultQuotaBackoff is how long a quota refusal that names no wait holds.
const defaultQuotaBackoff = time.Minute

// SpeechQuota remembers when a speech provider refused for quota or rate
// limits, so later requests fail at once with the same error until it lifts
// instead of spending a call (and a Live Voice pause) on another refusal. The
// zero value is ready to use; a nil SpeechQuota remembers nothing.
type SpeechQuota struct {
	mu      sync.Mutex
	blocked map[string]speechBlock
	now     func() time.Time // for tests
}

type speechBlock struct {
	until time.Time
	err   ProviderError
}

// Wrap returns gen with its calls gated on key, which names whose quota it
// spends (a workspace's provider). A streaming gen stays streaming.
func (q *SpeechQuota) Wrap(key string, gen SpeechGenerator) SpeechGenerator {
	if q == nil || gen == nil {
		return gen
	}
	g := quotaGatedSpeech{SpeechGenerator: gen, quota: q, key: key}
	if sg, ok := gen.(StreamingSpeechGenerator); ok {
		return quotaGatedStreamingSpeech{quotaGatedSpeech: g, stream: sg}
	}
	return g
}

func (q *SpeechQuota) clock() time.Time {
	if q.now != nil {
		return q.now()
	}
	return time.Now()
}

// refusal is the remembered error while key's quota is spent, nil otherwise.
func (q *SpeechQuota) refusal(key string) error {
	q.mu.Lock()
	defer q.mu.Unlock()
	b, ok := q.blocked[key]
	if !ok {
		return nil
	}
	now := q.clock()
	if !now.Before(b.until) {
		delete(q.blocked, key)
		return nil
	}
	err := b.err
	err.RetryAfter = b.until.Sub(now)
	return &err
}

// observe remembers a quota or rate-limit refusal for as long as it holds.
func (q *SpeechQuota) observe(key string, err error) {
	var pe *ProviderError
	if !errors.As(err, &pe) || (pe.Kind != ErrKindQuota && pe.Kind != ErrKindRateLimit) {
		return
	}
	wait := pe.RetryAfter
	if wait <= 0 {
		wait = defaultQuotaBackoff
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.blocked == nil {
		q.blocked = make(map[string]speechBlock)
	}
	q.blocked[key] = speechBlock{until: q.clock().Add(wait), err: *pe}
}

type quotaGatedSpeech struct {
	SpeechGenerator
	quota *SpeechQuota
	key   string
}

func (g quotaGatedSpeech) GenerateSpeech(ctx context.Context, req SpeechRequest) (SpeechClip, error) {
	if err := g.quota.refusal(g.key); err != nil {
		return SpeechClip{}, err
	}
	clip, err := g.SpeechGenerator.GenerateSpeech(ctx, req)
	g.quota.observe(g.key, err)
	return clip, err
}

type quotaGatedStreamingSpeech struct {
	quotaGatedSpeech
	stream StreamingSpeechGenerator
}

func (g quotaGatedStreamingSpeech) StreamSpeech(ctx context.Context, req SpeechRequest, onChunk func(SpeechChunk) error) (SpeechClip, error) {
	if err := g.quota.refusal(g.key); err != nil {
		return SpeechClip{}, err
	}
	clip, err := g.stream.StreamSpeech(ctx, req, onChunk)
	g.quota.observe(g.key, err)
	return clip, err
}
