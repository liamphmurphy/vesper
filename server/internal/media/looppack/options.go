// Package looppack implements local video matting and seamless Animated WebP
// loop-packing with a native Apple Silicon Vision backend on macOS and an
// ffmpeg colorkey/despill fallback on Linux and CI.
package looppack

import (
	"errors"
	"fmt"
	"strings"
)

const (
	DefaultTargetWidth      = 320
	DefaultTargetHeight     = 480
	DefaultFPS              = 20
	DefaultCrossfadeFrames  = 5
	DefaultChromaColor      = "0x3a3d40"
	DefaultChromaSimilarity = 0.18
	DefaultChromaBlend      = 0.08
	DefaultQuality          = 82
	DefaultMaxOutputBytes   = 8 << 20 // 8 MiB
	DefaultHeadCropSize     = 256
	MaxFeatherBottom        = 0.35
)

var (
	// ErrFFmpegNotFound is returned when the ffmpeg binary cannot be located.
	ErrFFmpegNotFound = errors.New("looppack: ffmpeg binary not found")
	// ErrOutputTooLarge is returned when the encoded Animated WebP exceeds MaxOutputBytes
	// even after stepping down encoding quality.
	ErrOutputTooLarge = errors.New("looppack: encoded WebP exceeds MaxOutputBytes")
	// ErrInvalidInput is returned when input video bytes or options are invalid.
	ErrInvalidInput = errors.New("looppack: invalid input")
)

// Options configures video matting, loop cross-dissolve, head-crop extraction,
// and Animated WebP encoding. Zero values receive sensible defaults.
type Options struct {
	TargetWidth      int
	TargetHeight     int
	FPS              int
	CrossfadeFrames  int
	DisableCrossfade bool // set true to explicitly disable crossfade (CrossfadeFrames == 0 uses default)
	FeatherBottom    float64
	ChromaColor      string
	ChromaSimilarity float64
	ChromaBlend      float64
	Quality          int
	MaxOutputBytes   int
	HeadCropSize     int

	// Matter overrides the matting backend. When nil, DefaultMatter() is used.
	Matter Matter
	// FFmpegBin overrides the ffmpeg executable path or name. Defaults to "ffmpeg".
	FFmpegBin string
	// TempDirBase overrides the parent directory for temporary working files.
	TempDirBase string
}

// Result contains the packed Animated WebP, square head-crop PNG, and metadata.
type Result struct {
	WebP        []byte
	HeadCropPNG []byte
	Width       int
	Height      int
	Frames      int
	DurationMS  int
	Backend     string
}

func (o Options) withDefaults() (Options, error) {
	out := o
	if out.TargetWidth <= 0 {
		out.TargetWidth = DefaultTargetWidth
	}
	if out.TargetHeight <= 0 {
		out.TargetHeight = DefaultTargetHeight
	}
	if out.FPS <= 0 {
		out.FPS = DefaultFPS
	}
	if out.DisableCrossfade {
		out.CrossfadeFrames = 0
	} else if out.CrossfadeFrames < 0 {
		out.CrossfadeFrames = 0
	} else if out.CrossfadeFrames == 0 {
		out.CrossfadeFrames = DefaultCrossfadeFrames
	}
	if out.FeatherBottom < 0 {
		return out, fmt.Errorf("%w: FeatherBottom must be >= 0 (got %v)", ErrInvalidInput, out.FeatherBottom)
	}
	if out.FeatherBottom > MaxFeatherBottom {
		return out, fmt.Errorf("%w: FeatherBottom must be <= %.2f (got %v)", ErrInvalidInput, MaxFeatherBottom, out.FeatherBottom)
	}
	if strings.TrimSpace(out.ChromaColor) == "" {
		out.ChromaColor = DefaultChromaColor
	} else {
		norm, err := normalizeHexColor(out.ChromaColor)
		if err != nil {
			return out, fmt.Errorf("%w: %v", ErrInvalidInput, err)
		}
		out.ChromaColor = norm
	}
	if out.ChromaSimilarity <= 0 {
		out.ChromaSimilarity = DefaultChromaSimilarity
	}
	if out.ChromaBlend < 0 {
		out.ChromaBlend = 0
	} else if out.ChromaBlend == 0 {
		out.ChromaBlend = DefaultChromaBlend
	}
	if out.Quality <= 0 {
		out.Quality = DefaultQuality
	}
	if out.Quality > 100 {
		out.Quality = 100
	}
	if out.MaxOutputBytes <= 0 {
		out.MaxOutputBytes = DefaultMaxOutputBytes
	}
	if out.HeadCropSize <= 0 {
		out.HeadCropSize = DefaultHeadCropSize
	}
	return out, nil
}

// normalizeHexColor validates and normalizes #RRGGBB, 0xRRGGBB, or RRGGBB to 0xRRGGBB.
func normalizeHexColor(raw string) (string, error) {
	s := strings.TrimSpace(raw)
	switch {
	case strings.HasPrefix(s, "0x"), strings.HasPrefix(s, "0X"):
		s = s[2:]
	case strings.HasPrefix(s, "#"):
		s = s[1:]
	}
	if len(s) != 6 {
		return "", fmt.Errorf("invalid hex color %q: expected 6 hex digits", raw)
	}
	for i := 0; i < 6; i++ {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')) {
			return "", fmt.Errorf("invalid hex color %q: non-hex character %q", raw, c)
		}
	}
	return "0x" + strings.ToLower(s), nil
}

func parseRGB(hexColor string) (r, g, b uint8) {
	norm, err := normalizeHexColor(hexColor)
	if err != nil {
		return 0, 0, 0
	}
	var val uint32
	_, _ = fmt.Sscanf(norm[2:], "%06x", &val)
	return uint8((val >> 16) & 0xff), uint8((val >> 8) & 0xff), uint8(val & 0xff)
}
