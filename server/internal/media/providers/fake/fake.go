// Package fake provides a deterministic, offline media.MusicGenerator for tests.
package fake

import (
	"bytes"
	"context"
	"encoding/binary"
	"math"
	"sync"

	"github.com/liamphmurphy/vesper/server/internal/media"
)

const ProviderID = "fake"

// Controller lets tests inject delays, blocking, errors, or custom audio clips.
type Controller struct {
	mu          sync.Mutex
	CheckErr    error
	GenerateErr error
	BlockCh     chan struct{}
	Calls       []media.MusicRequest
	ClipData    []byte
}

// Register registers the fake music provider on reg.
func Register(reg *media.Registry, ctrl *Controller) {
	if ctrl == nil {
		ctrl = &Controller{}
	}
	reg.Register(media.Entry{
		Descriptor: media.Descriptor{
			ID:           ProviderID,
			Label:        "Fake Music",
			Description:  "Deterministic test music provider.",
			Capabilities: []media.Capability{media.CapMusic},
			Fields: []media.FieldSpec{
				{
					Key:     "mode",
					Label:   "Mode",
					Kind:    "segmented",
					Default: "fast",
					Options: []media.FieldOption{
						{Value: "fast", Label: "Fast"},
						{Value: "slow", Label: "Slow"},
					},
				},
				{
					Key:         "api_key",
					Label:       "API Key",
					Kind:        "secret",
					Required:    true,
					Placeholder: "fake-key",
				},
			},
		},
		CheckAvailability: func(cfg media.ResolvedConfig) (bool, string) {
			if cfg.Secrets["api_key"] == "" {
				return false, "Fake Music API key is not configured."
			}
			return true, ""
		},
		New: func(media.ResolvedConfig) (media.Provider, error) {
			return &Provider{ctrl: ctrl}, nil
		},
	})
}

// Provider is an in-memory MusicGenerator.
type Provider struct {
	ctrl *Controller
}

func (p *Provider) ID() string    { return ProviderID }
func (p *Provider) Label() string { return "Fake Music" }

func (p *Provider) Check(ctx context.Context) error {
	p.ctrl.mu.Lock()
	err := p.ctrl.CheckErr
	p.ctrl.mu.Unlock()
	return err
}

func (p *Provider) GenerateMusic(ctx context.Context, req media.MusicRequest, onProgress func(media.MusicProgress)) (media.AudioClip, error) {
	p.ctrl.mu.Lock()
	p.ctrl.Calls = append(p.ctrl.Calls, req)
	block := p.ctrl.BlockCh
	err := p.ctrl.GenerateErr
	custom := p.ctrl.ClipData
	p.ctrl.mu.Unlock()

	if onProgress != nil {
		onProgress(media.MusicProgress{Percent: 25, Note: "Synthesizing track…"})
	}
	if block != nil {
		select {
		case <-ctx.Done():
			return media.AudioClip{}, ctx.Err()
		case <-block:
		}
	}
	if ctx.Err() != nil {
		return media.AudioClip{}, ctx.Err()
	}
	if err != nil {
		return media.AudioClip{}, err
	}
	if onProgress != nil {
		onProgress(media.MusicProgress{Percent: 80, Note: "Finalizing audio…"})
	}
	data := custom
	if len(data) == 0 {
		data = SineWAV(8000, 2)
	}
	return media.AudioClip{
		Data:        data,
		ContentType: "audio/wav",
		FilenameExt: ".wav",
		DurationMS:  2000,
		Model:       "fake-lyria",
	}, nil
}

// SineWAV builds a valid mono 16-bit PCM WAV file that rises from quiet to loud
// so waveform peak extraction yields non-zero dynamic buckets.
func SineWAV(rate, seconds int) []byte {
	n := rate * seconds
	data := make([]byte, n*2)
	for i := range n {
		amp := 0.1
		if i >= n/2 {
			amp = 0.85
		}
		v := int16(amp * math.Sin(2*math.Pi*440*float64(i)/float64(rate)) * 32767)
		binary.LittleEndian.PutUint16(data[i*2:], uint16(v))
	}
	var b bytes.Buffer
	b.WriteString("RIFF")
	_ = binary.Write(&b, binary.LittleEndian, uint32(36+len(data)))
	b.WriteString("WAVEfmt ")
	for _, v := range []any{uint32(16), uint16(1), uint16(1), uint32(rate), uint32(rate * 2), uint16(2), uint16(16)} {
		_ = binary.Write(&b, binary.LittleEndian, v)
	}
	b.WriteString("data")
	_ = binary.Write(&b, binary.LittleEndian, uint32(len(data)))
	b.Write(data)
	return b.Bytes()
}
