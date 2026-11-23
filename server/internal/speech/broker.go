package speech

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"sync"
	"time"
)

// CacheVersion bumps whenever the synthesized audio changes for identical
// inputs (provider, voice, style, text). Version 2 dropped clips made before
// the 3.8 WAV trailer and spoken-style fixes.
const CacheVersion = "2"

// CacheHash identifies a synthesized clip for a given provider, voice, style
// and speakable text, shared between live pre-synthesis and blob storage keys.
func CacheHash(providerID, voiceName, voiceStyle, text string) string {
	sum := sha256.Sum256([]byte(CacheVersion + "\x00" + providerID + "\x00" + voiceName + "\x00" + voiceStyle + "\x00" + text))
	return hex.EncodeToString(sum[:12])
}

// StreamFunc synthesizes speech, emitting 16-bit mono PCM chunks via onChunk
// and returning the complete WAV bytes and model name when finished.
type StreamFunc func(ctx context.Context, onChunk func(pcm []byte, sampleRate int) error) (wav []byte, model string, err error)

const (
	defaultBrokerTTL     = 2 * time.Minute
	defaultBrokerMaxKeys = 64
	defaultPreSynthLimit = 60 * time.Second
)

// Broker coordinates in-flight and recently completed speech pre-synthesis so
// the runner can start voicing sentence 1 while the model is still writing,
// and an HTTP speech stream request immediately subscribes to its live PCM
// chunks without duplicating the provider call.
type Broker struct {
	ttl     time.Duration
	maxKeys int

	mu      sync.Mutex
	entries map[string]*brokerEntry
	closed  bool
}

type pcmSlice struct {
	pcm        []byte
	sampleRate int
}

type brokerEntry struct {
	mu         sync.Mutex
	cond       *sync.Cond
	cancel     context.CancelFunc
	createdAt  time.Time
	finishedAt time.Time
	chunks     []pcmSlice
	wav        []byte
	model      string
	err        error
	done       bool
}

// NewBroker returns a pre-synthesis broker that retains completed clips for ttl.
func NewBroker(ttl time.Duration) *Broker {
	if ttl <= 0 {
		ttl = defaultBrokerTTL
	}
	return &Broker{
		ttl:     ttl,
		maxKeys: defaultBrokerMaxKeys,
		entries: make(map[string]*brokerEntry),
	}
}

// Start kicks off background synthesis for key if not already running or cached.
func (b *Broker) Start(key string, fn StreamFunc) {
	if b == nil || key == "" || fn == nil {
		return
	}
	now := time.Now()
	b.mu.Lock()
	if b.closed {
		b.mu.Unlock()
		return
	}
	b.pruneLocked(now)
	if existing, ok := b.entries[key]; ok {
		existing.mu.Lock()
		valid := !existing.done || (existing.err == nil && now.Sub(existing.finishedAt) < b.ttl)
		existing.mu.Unlock()
		if valid {
			b.mu.Unlock()
			return
		}
		delete(b.entries, key)
	}
	ctx, cancel := context.WithTimeout(context.Background(), defaultPreSynthLimit)
	e := &brokerEntry{
		cancel:    cancel,
		createdAt: now,
	}
	e.cond = sync.NewCond(&e.mu)
	b.entries[key] = e
	b.evictOverflowLocked()
	b.mu.Unlock()

	go func() {
		defer cancel()
		wav, model, err := fn(ctx, func(pcm []byte, sampleRate int) error {
			if len(pcm) == 0 {
				return nil
			}
			cp := append([]byte(nil), pcm...)
			e.mu.Lock()
			e.chunks = append(e.chunks, pcmSlice{pcm: cp, sampleRate: sampleRate})
			e.cond.Broadcast()
			e.mu.Unlock()
			return nil
		})
		e.mu.Lock()
		e.wav = wav
		e.model = model
		e.err = err
		e.done = true
		e.finishedAt = time.Now()
		e.cond.Broadcast()
		e.mu.Unlock()

		if err != nil {
			b.mu.Lock()
			if b.entries[key] == e {
				delete(b.entries, key)
			}
			b.mu.Unlock()
		}
	}()
}

// Subscribe attaches to an in-flight or completed pre-synthesis for key,
// streaming every PCM chunk in order to onChunk (if non-nil) and returning the
// final WAV and model. hit is false when key is not in the broker.
func (b *Broker) Subscribe(ctx context.Context, key string, onChunk func(pcm []byte, sampleRate int) error) (hit bool, wav []byte, model string, err error) {
	if b == nil || key == "" {
		return false, nil, "", nil
	}
	now := time.Now()
	b.mu.Lock()
	e, ok := b.entries[key]
	if ok {
		e.mu.Lock()
		expired := e.done && (e.err != nil || now.Sub(e.finishedAt) >= b.ttl)
		e.mu.Unlock()
		if expired {
			delete(b.entries, key)
			ok = false
		}
	}
	b.mu.Unlock()
	if !ok {
		return false, nil, "", nil
	}

	stopWake := context.AfterFunc(ctx, func() {
		e.mu.Lock()
		e.cond.Broadcast()
		e.mu.Unlock()
	})
	defer stopWake()

	idx := 0
	for {
		e.mu.Lock()
		for idx >= len(e.chunks) && !e.done && ctx.Err() == nil {
			e.cond.Wait()
		}
		if ctx.Err() != nil {
			e.mu.Unlock()
			return true, nil, "", ctx.Err()
		}
		batch := append([]pcmSlice(nil), e.chunks[idx:]...)
		idx += len(batch)
		done := e.done && idx >= len(e.chunks)
		finalWAV, finalModel, finalErr := e.wav, e.model, e.err
		e.mu.Unlock()

		if onChunk != nil {
			for _, ch := range batch {
				if err := onChunk(ch.pcm, ch.sampleRate); err != nil {
					return true, nil, "", err
				}
			}
		}
		if done {
			return true, finalWAV, finalModel, finalErr
		}
	}
}

// Close cancels all in-flight pre-synthesis tasks and clears the broker.
func (b *Broker) Close() {
	if b == nil {
		return
	}
	b.mu.Lock()
	b.closed = true
	entries := b.entries
	b.entries = nil
	b.mu.Unlock()
	for _, e := range entries {
		e.cancel()
		e.mu.Lock()
		e.cond.Broadcast()
		e.mu.Unlock()
	}
}

func (b *Broker) pruneLocked(now time.Time) {
	for k, e := range b.entries {
		e.mu.Lock()
		expired := e.done && now.Sub(e.finishedAt) >= b.ttl
		e.mu.Unlock()
		if expired {
			delete(b.entries, k)
		}
	}
}

func (b *Broker) evictOverflowLocked() {
	for len(b.entries) > b.maxKeys {
		var oldestKey string
		var oldestTime time.Time
		for k, e := range b.entries {
			if oldestKey == "" || e.createdAt.Before(oldestTime) {
				oldestKey = k
				oldestTime = e.createdAt
			}
		}
		if oldestKey == "" {
			return
		}
		if e := b.entries[oldestKey]; e != nil {
			e.cancel()
		}
		delete(b.entries, oldestKey)
	}
}
