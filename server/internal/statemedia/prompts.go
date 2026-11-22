// Package statemedia makes and keeps a persona's photorealistic state loops:
// one short, seamlessly looping clip per character state, generated from the
// persona's portrait by an image-to-video provider (Gemini Omni) and matted to
// a transparent Animated WebP by internal/media/looppack.
package statemedia

import (
	"fmt"
	"slices"
	"strings"
)

// State is one character state a persona has a loop for. The names match the
// character states the clients already drive (needs_you is spelled with an
// underscore, as in the API).
type State string

const (
	StateIdle     State = "idle"
	StateThinking State = "thinking"
	StateReading  State = "reading"
	StateCoding   State = "coding"
	StateCreating State = "creating"
	StateNeedsYou State = "needs_you"
	StateTalking  State = "talking"
)

// States lists every state in display order.
var States = []State{StateIdle, StateThinking, StateReading, StateCoding, StateCreating, StateNeedsYou, StateTalking}

// Valid reports whether s is a known state.
func Valid(s State) bool { return slices.Contains(States, s) }

// ChromaHex is the flat backdrop every clip is asked for. It matches the
// looppack chroma default, so the ffmpeg fallback keys the same colour Vision
// would segment away on macOS.
const ChromaHex = "#3a3d40"

// motions describe each state as restrained micro-motion: big gestures and
// camera moves are what make a short loop look uncanny or show its seam.
var motions = map[State]string{
	StateIdle:     "The person rests calmly and naturally: slow, gentle breathing visible in the chest and shoulders, one soft natural blink, a faint warm smile that barely shifts.",
	StateThinking: "The person is thinking: their gaze drifts slightly up and to the side, their brow furrows faintly, one finger taps slowly near their chin, then settles back.",
	StateReading:  "The person is reading something just below the camera: their eyes scan left to right line by line, with a small, understanding nod.",
	StateCoding:   "The person is typing on a laptop just out of frame below: small, real finger and forearm movement, eyes flicking across a screen, a slight focused lean in.",
	StateCreating: "The person is sketching or shaping an idea: small, fluid hand gestures in front of their chest, an engaged and pleased expression.",
	StateTalking:  "The person is speaking warmly and directly to the viewer: natural lip and jaw movement as if mid-sentence, eye contact, small expressive nods and one gentle hand gesture, then settles back.",
	StateNeedsYou: "The person turns their attention directly to the viewer with an expectant, friendly look and a brief, small wave of one hand, then lowers it.",
}

// Prompt is the full generation prompt for a state. The fixed framing keeps
// every state's clip interchangeable: same subject, camera, light and
// backdrop, starting and ending on the portrait so the loop closes.
func Prompt(s State) string {
	return fmt.Sprintf(
		"Photorealistic 4 second seamless loop of the exact person in the reference portrait. %s "+
			"The first and last frames match the reference portrait exactly, so the clip loops without a visible seam. "+
			"Locked-off static camera: no zoom, pan, tilt or cut. Keep their face, hair, outfit, framing, lighting and camera distance identical to the portrait. "+
			"Plain, perfectly uniform flat matte %s studio backdrop with soft, even, spill-free lighting and no shadows on the backdrop, so they can be cut out cleanly. "+
			"Natural skin texture, sharp focus, no text, captions, logos or watermarks.",
		motions[s], ChromaHex)
}

// TweakPrompt is the follow-up instruction for a conversational edit of an
// earlier clip: the provider keeps the earlier context, so only the change and
// the loop constraints are restated.
func TweakPrompt(tweak string) string {
	return strings.TrimSpace(tweak) + " Keep everything else the same: the same person, framing, static camera, " +
		"the same uniform flat " + ChromaHex + " backdrop, and first and last frames matching the reference portrait so it still loops seamlessly."
}
