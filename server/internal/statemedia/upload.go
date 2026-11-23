package statemedia

import (
	"bytes"
	"context"
	"errors"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	// MaxClipBytes bounds an uploaded clip. A 10s 1080p generation is about
	// 15 MB; the headroom is for higher-bitrate exports.
	MaxClipBytes = 64 << 20
	// maxClipMS is the longest clip a loop is made from: looppack keeps every
	// frame, so length is what bounds the matting work. The slack covers
	// container rounding on a 10s export.
	maxClipMS = 10_500
	minClipMS = 1_000
	// UploadProvider is the provider_id of a loop made from an uploaded clip.
	UploadProvider = "upload"
)

// clipCodecs are the codecs both matters decode: AVFoundation (Vision on
// macOS) and ffmpeg.
var clipCodecs = map[string]bool{"H.264": true, "H.265": true}

// UploadInput is a clip the person made elsewhere (e.g. AI Studio) for one
// state, to be matted into its loop in place of a generation.
type UploadInput struct {
	Owner     personas.Owner
	PersonaID uuid.UUID
	State     State
	Clip      []byte
}

// Upload checks the clip and queues it to be matted and packed like a
// generated one. It needs no video provider. The loop it makes can't be
// tweaked: there is no provider conversation to continue.
func (r *Runner) Upload(ctx context.Context, in UploadInput) ([]store.PersonaStateMedia, error) {
	if r == nil || r.Pool == nil {
		return nil, errors.New("statemedia: runner is not configured")
	}
	if r.Blobs == nil || r.Bucket == "" {
		return nil, apperr.Conflict("Vesper has no storage configured for persona loops.")
	}
	if !Valid(in.State) {
		return nil, apperr.Invalid("state", "unknown state %q", in.State)
	}
	info, err := CheckClip(in.Clip)
	if err != nil {
		return nil, err
	}
	// The packed size is budgeted by length, as for a generated loop.
	seconds := min(10, max(1, (info.DurationMS+999)/1000))
	return r.queue(ctx, queueSpec{
		owner: in.Owner, persona: in.PersonaID, states: []State{in.State},
		provider: UploadProvider, note: "Queued: cutting out your clip…",
		prepare: func(a *attempt, _ store.Persona, _ *store.PersonaStateMedia) error {
			a.seconds, a.upload = seconds, in.Clip
			return nil
		},
	}, nil, nil)
}

// CheckClip refuses a clip Vesper can't make a loop from: not an MP4 or
// QuickTime file, a codec a matter can't decode, or too short or long. It
// reads only the container's boxes, so a hostile file never reaches a
// decoder here.
func CheckClip(b []byte) (runs.VideoInfo, error) {
	if len(b) == 0 {
		return runs.VideoInfo{}, apperr.Invalid("file", "required")
	}
	if len(b) > MaxClipBytes {
		return runs.VideoInfo{}, apperr.Invalid("file", "clips are limited to %d MB", MaxClipBytes>>20)
	}
	info, err := runs.ReadVideoInfo(bytes.NewReader(b), int64(len(b)))
	if err != nil {
		return info, apperr.Invalid("file", "upload an MP4 or MOV video")
	}
	if !clipCodecs[info.Codec] {
		return info, apperr.Invalid("file", "the clip must be H.264 or H.265 video (got %q)", firstNonEmpty(info.Codec, "no video track"))
	}
	if info.DurationMS < minClipMS || info.DurationMS > maxClipMS {
		return info, apperr.Invalid("file", "the clip must be 1 to 10 seconds long (got %.1fs)", float64(info.DurationMS)/1000)
	}
	return info, nil
}
