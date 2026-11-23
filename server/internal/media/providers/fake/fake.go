// Package fake provides a deterministic, offline media.MusicGenerator and
// media.VideoGenerator for tests.
package fake

import (
	"bytes"
	"context"
	"encoding/binary"
	"fmt"
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

	// VideoCalls records every GenerateVideo request.
	VideoCalls []media.VideoRequest
	// VideoErr, when set, decides per request whether GenerateVideo fails.
	VideoErr func(media.VideoRequest) error
	// VideoBlockCh, when set, holds GenerateVideo until it is closed.
	VideoBlockCh chan struct{}
	// SpeechCalls records every GenerateSpeech request.
	SpeechCalls []media.SpeechRequest
	// SpeechErr, when set, fails every GenerateSpeech after recording it.
	SpeechErr error
	// ImageCalls records every GenerateImage request.
	ImageCalls []media.ImageRequest
	// ImageErr, when set, decides per request whether GenerateImage fails.
	ImageErr func(media.ImageRequest) error
	// ImageData overrides the default 1x1 PNG payload returned by GenerateImage.
	ImageData []byte
}

// SetVideo sets VideoErr and VideoBlockCh under the controller's lock, so a
// test can change them while generation goroutines read them.
func (c *Controller) SetVideo(errFor func(media.VideoRequest) error, block chan struct{}) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.VideoErr, c.VideoBlockCh = errFor, block
}

// VideoRequests returns a copy of the video requests made so far.
func (c *Controller) VideoRequests() []media.VideoRequest {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]media.VideoRequest(nil), c.VideoCalls...)
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

// VideoProviderID is the fake video provider RegisterVideo adds.
const VideoProviderID = "fake-video"

// RegisterVideo registers a fake video provider on reg, sharing ctrl. It is
// separate from the music fake so tests of music-only resolution see no video
// provider.
func RegisterVideo(reg *media.Registry, ctrl *Controller) {
	if ctrl == nil {
		ctrl = &Controller{}
	}
	reg.Register(media.Entry{
		Descriptor: media.Descriptor{
			ID:           VideoProviderID,
			Label:        "Fake Video",
			Description:  "Deterministic test video provider.",
			Capabilities: []media.Capability{media.CapVideo},
			Fields:       []media.FieldSpec{{Key: "api_key", Label: "API Key", Kind: "secret", Required: true}},
		},
		CheckAvailability: func(cfg media.ResolvedConfig) (bool, string) {
			if cfg.Secrets["api_key"] == "" {
				return false, "Fake Video API key is not configured."
			}
			return true, ""
		},
		New: func(media.ResolvedConfig) (media.Provider, error) {
			return &VideoProvider{ctrl: ctrl}, nil
		},
	})
}

// VideoProvider is an in-memory VideoGenerator.
type VideoProvider struct {
	ctrl *Controller
}

func (p *VideoProvider) ID() string    { return VideoProviderID }
func (p *VideoProvider) Label() string { return "Fake Video" }

func (p *VideoProvider) Check(ctx context.Context) error {
	p.ctrl.mu.Lock()
	err := p.ctrl.CheckErr
	p.ctrl.mu.Unlock()
	return err
}

// SpeechProviderID is the fake speech provider RegisterSpeech adds.
const SpeechProviderID = "fake-speech"

// RegisterSpeech registers a fake speech provider on reg, sharing ctrl.
func RegisterSpeech(reg *media.Registry, ctrl *Controller) {
	if ctrl == nil {
		ctrl = &Controller{}
	}
	reg.Register(media.Entry{
		Descriptor: media.Descriptor{
			ID:           SpeechProviderID,
			Label:        "Fake Speech",
			Description:  "Deterministic test speech provider.",
			Capabilities: []media.Capability{media.CapTTS},
			Fields:       []media.FieldSpec{{Key: "api_key", Label: "API Key", Kind: "secret", Required: true}},
		},
		CheckAvailability: func(cfg media.ResolvedConfig) (bool, string) {
			if cfg.Secrets["api_key"] == "" {
				return false, "Fake Speech API key is not configured."
			}
			return true, ""
		},
		New: func(media.ResolvedConfig) (media.Provider, error) {
			return &SpeechProvider{ctrl: ctrl}, nil
		},
	})
}

// SpeechProvider is an in-memory SpeechGenerator that returns a short WAV.
type SpeechProvider struct {
	ctrl *Controller
}

func (p *SpeechProvider) ID() string                      { return SpeechProviderID }
func (p *SpeechProvider) Label() string                   { return "Fake Speech" }
func (p *SpeechProvider) Check(ctx context.Context) error { return nil }
func (p *SpeechProvider) DefaultVoice() string            { return "Kore" }
func (p *SpeechProvider) Voices() []media.Voice {
	return []media.Voice{{Name: "Kore", Tone: "Firm"}, {Name: "Sulafat", Tone: "Warm"}}
}

// GenerateSpeech records the request and returns a one-second WAV.
func (p *SpeechProvider) GenerateSpeech(ctx context.Context, req media.SpeechRequest) (media.SpeechClip, error) {
	p.ctrl.mu.Lock()
	p.ctrl.SpeechCalls = append(p.ctrl.SpeechCalls, req)
	failure := p.ctrl.SpeechErr
	p.ctrl.mu.Unlock()
	if err := ctx.Err(); err != nil {
		return media.SpeechClip{}, err
	}
	if failure != nil {
		return media.SpeechClip{}, failure
	}
	return media.SpeechClip{Data: SineWAV(8000, 1), ContentType: "audio/wav", DurationMS: 1000, Model: "fake-tts"}, nil
}

// SpeechRequests returns a copy of the speech requests made so far.
func (c *Controller) SpeechRequests() []media.SpeechRequest {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]media.SpeechRequest(nil), c.SpeechCalls...)
}

// ImageRequests returns a copy of the image requests made so far.
func (c *Controller) ImageRequests() []media.ImageRequest {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]media.ImageRequest(nil), c.ImageCalls...)
}

// ImageProviderID is the fake image provider RegisterImage adds.
const ImageProviderID = "fake-image"

// FakeImagePNG is a valid 1x1 PNG returned by FakeImage when Controller.ImageData is empty.
var FakeImagePNG = []byte{
	0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
	0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
	0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
	0x08, 0x02, 0x00, 0x00, 0x00, 0x90, 0x77, 0x53,
	0xde, 0x00, 0x00, 0x00, 0x0c, 0x49, 0x44, 0x41,
	0x54, 0x08, 0xd7, 0x63, 0xf8, 0xcf, 0xc0, 0x00,
	0x00, 0x03, 0x01, 0x01, 0x00, 0x18, 0xdd, 0x8d,
	0xb0, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e,
	0x44, 0xae, 0x42, 0x60, 0x82,
}

// RegisterImage registers a fake image provider under id (defaulting to
// ImageProviderID) on reg, sharing ctrl. Tests of the "gemini" engine can pass
// id = "gemini".
func RegisterImage(reg *media.Registry, id string, ctrl *Controller) {
	if ctrl == nil {
		ctrl = &Controller{}
	}
	if id == "" {
		id = ImageProviderID
	}
	reg.Register(media.Entry{
		Descriptor: media.Descriptor{
			ID:           id,
			Label:        "Fake Image",
			Description:  "Deterministic test image provider.",
			Capabilities: []media.Capability{media.CapImage},
			Fields: []media.FieldSpec{
				{Key: "api_key", Label: "API Key", Kind: "secret", Required: true},
				{
					Key:     "image_model",
					Label:   "Image Model",
					Kind:    "select",
					Default: "fake-nano-banana",
					Options: []media.FieldOption{
						{Value: "fake-nano-banana", Label: "Fake Nano Banana"},
						{Value: "fake-nano-banana-fast", Label: "Fake Nano Banana Fast"},
					},
				},
			},
		},
		CheckAvailability: func(cfg media.ResolvedConfig) (bool, string) {
			if cfg.Secrets["api_key"] == "" {
				return false, "Add a Gemini API key in Settings → Workspace → Media providers."
			}
			return true, ""
		},
		New: func(cfg media.ResolvedConfig) (media.Provider, error) {
			model := cfg.Settings["image_model"]
			if model == "" {
				model = "fake-nano-banana"
			}
			return &ImageProvider{id: id, model: model, ctrl: ctrl}, nil
		},
	})
}

// ImageProvider is an in-memory ImageGenerator.
type ImageProvider struct {
	id    string
	model string
	ctrl  *Controller
}

func (p *ImageProvider) ID() string                      { return p.id }
func (p *ImageProvider) Label() string                   { return "Fake Image" }
func (p *ImageProvider) Check(ctx context.Context) error { return nil }

func (p *ImageProvider) GenerateImage(ctx context.Context, req media.ImageRequest) (media.GeneratedImage, error) {
	p.ctrl.mu.Lock()
	p.ctrl.ImageCalls = append(p.ctrl.ImageCalls, req)
	errFor := p.ctrl.ImageErr
	custom := p.ctrl.ImageData
	p.ctrl.mu.Unlock()

	if err := ctx.Err(); err != nil {
		return media.GeneratedImage{}, err
	}
	if errFor != nil {
		if err := errFor(req); err != nil {
			return media.GeneratedImage{}, err
		}
	}
	data := custom
	if len(data) == 0 {
		data = FakeImagePNG
	}
	model := req.Model
	if model == "" {
		model = p.model
	}
	return media.GeneratedImage{
		Data:        data,
		ContentType: "image/png",
		FilenameExt: ".png",
		Model:       model,
	}, nil
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

// FakeVideoMP4 is the placeholder payload GenerateVideo returns; tests pack it
// with a stub, never ffmpeg.
var FakeVideoMP4 = []byte("fake-mp4")

func (p *VideoProvider) GenerateVideo(ctx context.Context, req media.VideoRequest, onProgress func(media.VideoProgress)) (media.VideoClip, error) {
	p.ctrl.mu.Lock()
	p.ctrl.VideoCalls = append(p.ctrl.VideoCalls, req)
	n := len(p.ctrl.VideoCalls)
	block := p.ctrl.VideoBlockCh
	errFor := p.ctrl.VideoErr
	p.ctrl.mu.Unlock()

	if onProgress != nil {
		onProgress(media.VideoProgress{Percent: 30, Note: "Rendering clip…"})
	}
	if block != nil {
		select {
		case <-ctx.Done():
			return media.VideoClip{}, ctx.Err()
		case <-block:
		}
	}
	if ctx.Err() != nil {
		return media.VideoClip{}, ctx.Err()
	}
	if errFor != nil {
		if err := errFor(req); err != nil {
			return media.VideoClip{}, err
		}
	}
	return media.VideoClip{
		Data:          FakeVideoMP4,
		ContentType:   "video/mp4",
		FilenameExt:   ".mp4",
		DurationMS:    req.DurationSec * 1000,
		Model:         "fake-omni",
		InteractionID: fmt.Sprintf("fake-interaction-%d", n),
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
