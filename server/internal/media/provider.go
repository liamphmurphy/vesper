package media

import "context"

// Capability identifies one generation surface a Provider can implement.
type Capability string

const (
	CapImage  Capability = "image"
	CapMusic  Capability = "music"
	CapVideo  Capability = "video"
	CapTTS    Capability = "tts"
	CapScript Capability = "script"
)

// AllCapabilities lists every supported capability in display order.
var AllCapabilities = []Capability{CapImage, CapMusic, CapVideo, CapTTS, CapScript}

// ValidCapability reports whether c is a recognized capability.
func ValidCapability(c Capability) bool {
	switch c {
	case CapImage, CapMusic, CapVideo, CapTTS, CapScript:
		return true
	}
	return false
}

// Provider is the base contract implemented by every media backend.
type Provider interface {
	ID() string
	Label() string
	// Check verifies configuration and reachability without generating media.
	Check(ctx context.Context) error
}

// MusicLength controls clip vs. full-track generation.
type MusicLength string

const (
	LengthClip MusicLength = "clip"
	LengthFull MusicLength = "full"
)

// MusicRequest describes a music generation request across all adapters.
type MusicRequest struct {
	Title        string
	Prompt       string
	Lyrics       string
	Instrumental bool
	Length       MusicLength
	DurationSec  int
	Model        string
}

// MusicProgress reports generation progress while a blocking call runs.
type MusicProgress struct {
	Percent int
	Note    string
}

// AudioClip is the normalized audio payload returned by an adapter.
type AudioClip struct {
	Data            []byte
	ContentType     string
	FilenameExt     string
	DurationMS      int
	GeneratedLyrics string
	Model           string
}

// MusicGenerator is implemented by providers that generate music tracks.
type MusicGenerator interface {
	Provider
	GenerateMusic(ctx context.Context, req MusicRequest, onProgress func(MusicProgress)) (AudioClip, error)
}

// VideoFrame is an image frame passed as a first/last keyframe or reference image.
type VideoFrame struct {
	Data        []byte
	ContentType string
}

// VideoRequest describes a video generation request across all adapters.
type VideoRequest struct {
	Prompt                string
	FirstFrame            *VideoFrame
	LastFrame             *VideoFrame
	ReferenceImages       []VideoFrame
	AspectRatio           string
	DurationSec           int
	Model                 string
	PreviousInteractionID string
}

// VideoProgress reports generation progress while a blocking call runs.
type VideoProgress struct {
	Percent int
	Note    string
}

// VideoClip is the normalized video payload returned by an adapter.
type VideoClip struct {
	Data          []byte
	ContentType   string
	FilenameExt   string
	DurationMS    int
	Model         string
	InteractionID string
}

// VideoGenerator is implemented by providers that generate video clips.
type VideoGenerator interface {
	Provider
	GenerateVideo(ctx context.Context, req VideoRequest, onProgress func(VideoProgress)) (VideoClip, error)
}

// SpeechRequest describes a text-to-speech request across all adapters.
type SpeechRequest struct {
	// Text is what is spoken: plain prose, already stripped of markdown.
	Text string
	// Voice is the adapter's voice name; empty takes the adapter's default.
	Voice string
	// Style is a short natural-language delivery direction ("warm, unhurried").
	Style string
	Model string
}

// SpeechClip is the normalized speech payload returned by an adapter: a WAV
// file the clients can play as is.
type SpeechClip struct {
	Data        []byte
	ContentType string
	DurationMS  int
	Model       string
}

// Voice is one voice an adapter offers, with a short description of its tone.
type Voice struct {
	Name string
	Tone string
}

// SpeechGenerator is implemented by providers that synthesize speech.
type SpeechGenerator interface {
	Provider
	Voices() []Voice
	// DefaultVoice is spoken when a request names none.
	DefaultVoice() string
	GenerateSpeech(ctx context.Context, req SpeechRequest) (SpeechClip, error)
}

// SpeechChunk is one incremental slice of 16-bit signed little-endian mono PCM.
type SpeechChunk struct {
	PCM        []byte
	SampleRate int
}

// StreamingSpeechGenerator is optionally implemented by speech providers that
// emit PCM chunks as synthesis progresses, while still returning the complete
// WAV SpeechClip at the end for caching.
type StreamingSpeechGenerator interface {
	SpeechGenerator
	StreamSpeech(ctx context.Context, req SpeechRequest, onChunk func(SpeechChunk) error) (SpeechClip, error)
}

// ImageReference is one reference image (such as a persona or person likeness,
// or an upstream workflow image) passed into an image generation request.
type ImageReference struct {
	Role        string // "persona", "person", or ""
	Data        []byte
	ContentType string
}

// ImageRequest describes an image generation request across all adapters.
type ImageRequest struct {
	Prompt      string
	References  []ImageReference
	Model       string // optional override; empty takes the provider's configured image_model
	AspectRatio string // optional e.g. "1:1", "16:9"
	ImageSize   string // optional e.g. "1K", "2K", "4K"; empty takes the provider's configured image_size
}

// GeneratedImage is the normalized image payload returned by an adapter.
type GeneratedImage struct {
	Data        []byte
	ContentType string
	FilenameExt string
	Model       string
}

// ImageGenerator is implemented by providers that generate images directly.
type ImageGenerator interface {
	Provider
	GenerateImage(ctx context.Context, req ImageRequest) (GeneratedImage, error)
}
