package statemedia

import (
	"bytes"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"strings"
	"testing"
)

func encodePNG(t *testing.T, w, h int, alpha bool) []byte {
	t.Helper()
	img := image.NewNRGBA(image.Rect(0, 0, w, h))
	for y := range h {
		for x := range w {
			a := uint8(255)
			if alpha {
				a = 0
			}
			img.SetNRGBA(x, y, color.NRGBA{R: 200, G: 120, B: 90, A: a})
		}
	}
	var b bytes.Buffer
	if err := png.Encode(&b, img); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func TestNormPortraitBoundsAndFlattens(t *testing.T) {
	out, err := normPortrait(encodePNG(t, 2000, 3000, true))
	if err != nil {
		t.Fatal(err)
	}
	img, err := jpeg.Decode(bytes.NewReader(out))
	if err != nil {
		t.Fatalf("not a JPEG: %v", err)
	}
	if b := img.Bounds(); b.Dx() != 853 || b.Dy() != portraitSide {
		t.Fatalf("size = %v, want 853x%d", b.Size(), portraitSide)
	}
	// Transparent pixels land on the chroma backdrop, not black.
	r, g, b, _ := img.At(10, 10).RGBA()
	want := chromaRGBA()
	if d := int(r>>8) - int(want.R); d < -6 || d > 6 || int(g>>8) < int(want.G)-6 || int(b>>8) < int(want.B)-6 {
		t.Fatalf("flattened pixel = %d,%d,%d, want about %v", r>>8, g>>8, b>>8, want)
	}

	for name, src := range map[string][]byte{
		"empty":        nil,
		"tiny":         encodePNG(t, 20, 20, false),
		"not an image": []byte("<svg/>"),
	} {
		if _, err := normPortrait(src); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestPromptsLockTheLoop(t *testing.T) {
	seen := map[string]bool{}
	for _, s := range States {
		p := Prompt(s)
		if !strings.Contains(p, ChromaHex) || !strings.Contains(p, "first and last frames") || !strings.Contains(p, "static camera") {
			t.Errorf("%s prompt misses a loop constraint: %q", s, p)
		}
		if seen[p] {
			t.Errorf("%s prompt duplicates another state", s)
		}
		seen[p] = true
	}
	if p := TweakPrompt(StateIdle, "  slower  "); !strings.HasPrefix(p, Prompt(StateIdle)) || !strings.HasSuffix(p, " Additional direction: slower") {
		t.Errorf("tweak prompt = %q", p)
	}
	if _, err := normStates([]State{"idle", "idle", "coding"}); err != nil {
		t.Error(err)
	}
	if got, _ := normStates(nil); len(got) != len(States) {
		t.Errorf("empty states = %v, want all", got)
	}
	if _, err := normStates([]State{"dancing"}); err == nil {
		t.Error("unknown state accepted")
	}
}
