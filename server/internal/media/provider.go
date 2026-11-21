package media

import "context"

// Capability identifies one generation surface a Provider can implement.
type Capability string

const (
	CapMusic  Capability = "music"
	CapTTS    Capability = "tts"
	CapScript Capability = "script"
)

// AllCapabilities lists every supported capability in display order.
var AllCapabilities = []Capability{CapMusic, CapTTS, CapScript}

// ValidCapability reports whether c is a recognized capability.
func ValidCapability(c Capability) bool {
	switch c {
	case CapMusic, CapTTS, CapScript:
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
