package media

import "context"

// Capability identifies one generation surface a Provider can implement.
type Capability string

const (
	CapMusic  Capability = "music"
	CapVideo  Capability = "video"
	CapTTS    Capability = "tts"
	CapScript Capability = "script"
)

// AllCapabilities lists every supported capability in display order.
var AllCapabilities = []Capability{CapMusic, CapVideo, CapTTS, CapScript}

// ValidCapability reports whether c is a recognized capability.
func ValidCapability(c Capability) bool {
	switch c {
	case CapMusic, CapVideo, CapTTS, CapScript:
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
