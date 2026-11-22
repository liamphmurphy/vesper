package looppack

import (
	"bytes"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/png"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
)

// generateSyntheticMP4 creates a synthetic H.264 MP4 with a solid chroma
// backdrop (`bgHex`, e.g. "0x00ff00" or "0x3a3d40") and a moving bright orange
// subject rectangle in the center so chroma keying, cross-dissolve, and head
// cropping can be verified deterministically.
func generateSyntheticMP4(t *testing.T, bgHex string, width, height, fps int, durationSec float64, fullHeightSubject bool) []byte {
	t.Helper()
	ffmpegPath, err := exec.LookPath("ffmpeg")
	if err != nil {
		t.Skipf("ffmpeg not available in PATH: %v", err)
	}

	outPath := filepath.Join(t.TempDir(), "synthetic.mp4")
	boxW := width / 2
	boxH := height / 2
	boxY := fmt.Sprintf("%d", height/4)
	if fullHeightSubject {
		boxH = height
		boxY = "0"
	}
	// Overlay a moving bright orange box onto the solid chroma backdrop so each
	// frame is distinct (ffmpeg's drawbox does not re-evaluate `t` per frame,
	// whereas overlay does).
	overlayExpr := fmt.Sprintf(
		"overlay=x='%d+12*sin(2*PI*t)':y=%s:shortest=1",
		(width-boxW)/2, boxY,
	)

	args := []string{
		"-hide_banner",
		"-loglevel", "error",
		"-y",
		"-f", "lavfi",
		"-i", fmt.Sprintf("color=c=%s:s=%dx%d:r=%d:d=%.2f", bgHex, width, height, fps, durationSec),
		"-f", "lavfi",
		"-i", fmt.Sprintf("color=c=0xff5522:s=%dx%d:r=%d:d=%.2f", boxW, boxH, fps, durationSec),
		"-filter_complex", overlayExpr,
		"-c:v", "libx264",
		"-pix_fmt", "yuv420p",
		"-crf", "12",
		outPath,
	}
	cmd := exec.Command(ffmpegPath, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("generate synthetic MP4 failed: %v: %s", err, stderr.String())
	}
	data, err := os.ReadFile(outPath)
	if err != nil {
		t.Fatalf("read synthetic MP4: %v", err)
	}
	return data
}

// parseAnimatedWebPHeader validates RIFF....WEBP structure, verifies the VP8X
// chunk has both Alpha (bit 4) and Animation (bit 1) flags set, and checks for
// at least one ANIM and ANMF chunk.
func parseAnimatedWebPHeader(t *testing.T, data []byte) (canvasW, canvasH, anmfCount int) {
	t.Helper()
	if len(data) < 30 {
		t.Fatalf("WebP too short: %d bytes", len(data))
	}
	if string(data[0:4]) != "RIFF" || string(data[8:12]) != "WEBP" {
		t.Fatalf("invalid WebP magic: %q / %q", string(data[0:4]), string(data[8:12]))
	}

	var sawVP8X, sawANIM bool
	pos := 12
	for pos+8 <= len(data) {
		fourCC := string(data[pos : pos+4])
		chunkSize := int(binary.LittleEndian.Uint32(data[pos+4 : pos+8]))
		payloadStart := pos + 8
		payloadEnd := payloadStart + chunkSize
		if payloadEnd > len(data) {
			t.Fatalf("truncated WebP chunk %q: end %d > len %d", fourCC, payloadEnd, len(data))
		}
		payload := data[payloadStart:payloadEnd]

		switch fourCC {
		case "VP8X":
			if len(payload) < 10 {
				t.Fatalf("VP8X payload too short: %d", len(payload))
			}
			flags := payload[0]
			const (
				flagAlpha = 1 << 4
				flagAnim  = 1 << 1
			)
			if flags&flagAlpha == 0 {
				t.Errorf("VP8X missing alpha flag (flags=0x%02x)", flags)
			}
			if flags&flagAnim == 0 {
				t.Errorf("VP8X missing animation flag (flags=0x%02x)", flags)
			}
			canvasW = 1 + int(payload[4]) | (int(payload[5]) << 8) | (int(payload[6]) << 16)
			canvasH = 1 + int(payload[7]) | (int(payload[8]) << 8) | (int(payload[9]) << 16)
			sawVP8X = true
		case "ANIM":
			sawANIM = true
		case "ANMF":
			anmfCount++
		}

		// RIFF chunks are padded to even byte boundaries.
		pos = payloadEnd + (chunkSize & 1)
	}

	if !sawVP8X {
		t.Errorf("WebP missing VP8X extended header chunk")
	}
	if !sawANIM {
		t.Errorf("WebP missing ANIM global animation chunk")
	}
	if anmfCount == 0 {
		t.Errorf("WebP has 0 ANMF animation frame chunks")
	}
	return canvasW, canvasH, anmfCount
}

func TestPack_ChromaGreenAndStudioGray(t *testing.T) {
	cases := []struct {
		name        string
		chromaColor string
	}{
		{name: "green_screen", chromaColor: "0x00ff00"},
		{name: "studio_gray_default", chromaColor: DefaultChromaColor},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			mp4 := generateSyntheticMP4(t, tc.chromaColor, 320, 480, 20, 1.5, false)
			tempBase := t.TempDir()

			res, err := Pack(context.Background(), mp4, Options{
				TargetWidth:     320,
				TargetHeight:    480,
				FPS:             20,
				CrossfadeFrames: 5,
				ChromaColor:     tc.chromaColor,
				HeadCropSize:    256,
				Matter:          &FFmpegChromaMatter{},
				TempDirBase:     tempBase,
			})
			if err != nil {
				t.Fatalf("Pack failed: %v", err)
			}

			if res.Width != 320 || res.Height != 480 {
				t.Errorf("unexpected dimensions: %dx%d", res.Width, res.Height)
			}
			if res.Frames < 20 || res.Frames > 26 {
				t.Errorf("unexpected loop frame count after 5-frame crossfade on 1.5s@20fps: %d", res.Frames)
			}
			if res.DurationMS <= 0 {
				t.Errorf("expected positive DurationMS, got %d", res.DurationMS)
			}
			if res.Backend != "ffmpeg-chroma" {
				t.Errorf("expected backend ffmpeg-chroma, got %q", res.Backend)
			}

			// Verify valid Animated WebP with Alpha + Anim flags and matching canvas dimensions.
			w, h, anmfCount := parseAnimatedWebPHeader(t, res.WebP)
			if w != 320 || h != 480 {
				t.Errorf("WebP canvas mismatch: got %dx%d, want 320x480", w, h)
			}
			// libwebp_anim deduplicates consecutive identical frames (e.g. at sine peaks)
			// by extending frame duration, so ANMF chunks may be slightly fewer than Frames.
			if anmfCount == 0 || anmfCount > res.Frames {
				t.Errorf("WebP ANMF count %d out of range (1..%d)", anmfCount, res.Frames)
			}

			// Verify HeadCropPNG decodes cleanly as 256x256 RGBA with transparent corners
			// and opaque subject pixels.
			headImg, err := png.Decode(bytes.NewReader(res.HeadCropPNG))
			if err != nil {
				t.Fatalf("decode HeadCropPNG: %v", err)
			}
			hb := headImg.Bounds()
			if hb.Dx() != 256 || hb.Dy() != 256 {
				t.Errorf("HeadCropPNG size = %dx%d, want 256x256", hb.Dx(), hb.Dy())
			}

			_, _, _, cornerA := headImg.At(2, 2).RGBA()
			if cornerA>>8 != 0 {
				t.Errorf("expected transparent corner pixel (alpha==0), got alpha=%d", cornerA>>8)
			}
			// Subject starts at y=120 in 320x480; in upper-center 320x320 crop scaled to 256x256,
			// the center-bottom area (x=128, y=180) is solidly inside the orange subject box.
			_, _, _, subjectA := headImg.At(128, 180).RGBA()
			if subjectA>>8 <= 200 {
				t.Errorf("expected opaque subject pixel (alpha>200), got alpha=%d", subjectA>>8)
			}

			// Verify zero leaked temp dirs.
			entries, err := os.ReadDir(tempBase)
			if err != nil {
				t.Fatalf("ReadDir tempBase: %v", err)
			}
			if len(entries) != 0 {
				t.Errorf("expected 0 leaked temp dirs, found %d", len(entries))
			}
		})
	}
}

func TestPack_BottomFeather(t *testing.T) {
	mp4 := generateSyntheticMP4(t, "0x00ff00", 160, 240, 10, 1.0, true)
	outDir := t.TempDir()
	inPath := filepath.Join(t.TempDir(), "in.mp4")
	if err := os.WriteFile(inPath, mp4, 0o600); err != nil {
		t.Fatalf("write mp4: %v", err)
	}

	opts, err := (Options{
		TargetWidth:   160,
		TargetHeight:  240,
		FPS:           10,
		ChromaColor:   "0x00ff00",
		FeatherBottom: 0.25,
	}).withDefaults()
	if err != nil {
		t.Fatalf("withDefaults: %v", err)
	}

	matter := &FFmpegChromaMatter{}
	if _, err := matter.Matte(context.Background(), inPath, outDir, opts); err != nil {
		t.Fatalf("Matte with FeatherBottom failed: %v", err)
	}

	frame1, err := readPNGAsNRGBA(filepath.Join(outDir, "frame_00001.png"))
	if err != nil {
		t.Fatalf("read frame 1: %v", err)
	}
	topSubjectA := frame1.NRGBAAt(80, 40).A
	bottomSubjectA := frame1.NRGBAAt(80, 238).A
	if topSubjectA < 220 {
		t.Errorf("expected opaque upper subject (alpha>=220), got %d", topSubjectA)
	}
	if bottomSubjectA > 30 {
		t.Errorf("expected feathered bottom edge (alpha<=30), got %d", bottomSubjectA)
	}
}

func TestPack_MaxOutputBytesEnforcement(t *testing.T) {
	mp4 := generateSyntheticMP4(t, "0x00ff00", 160, 240, 10, 1.0, false)
	tempBase := t.TempDir()

	_, err := Pack(context.Background(), mp4, Options{
		TargetWidth:    160,
		TargetHeight:   240,
		FPS:            10,
		ChromaColor:    "0x00ff00",
		MaxOutputBytes: 64, // impossibly small
		Matter:         &FFmpegChromaMatter{},
		TempDirBase:    tempBase,
	})
	if !errors.Is(err, ErrOutputTooLarge) {
		t.Fatalf("expected ErrOutputTooLarge, got %v", err)
	}

	// Verify cleanup on error too.
	entries, err := os.ReadDir(tempBase)
	if err != nil {
		t.Fatalf("ReadDir tempBase: %v", err)
	}
	if len(entries) != 0 {
		t.Errorf("expected 0 leaked temp dirs after error, found %d", len(entries))
	}
}

func TestPack_MissingFFmpeg(t *testing.T) {
	_, err := Pack(context.Background(), []byte("fake-mp4-bytes"), Options{
		FFmpegBin: "nonexistent-ffmpeg-binary-for-test-xyz",
	})
	if !errors.Is(err, ErrFFmpegNotFound) {
		t.Fatalf("expected ErrFFmpegNotFound, got %v", err)
	}
}

func TestPack_ContextCancellation(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()

	tempBase := t.TempDir()
	_, err := Pack(ctx, []byte("fake-mp4-bytes"), Options{
		TempDirBase: tempBase,
	})
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected context.Canceled, got %v", err)
	}
	entries, _ := os.ReadDir(tempBase)
	if len(entries) != 0 {
		t.Errorf("expected 0 leaked temp dirs on cancel, found %d", len(entries))
	}
}

func TestVisionMatter_StubBinary(t *testing.T) {
	if _, err := exec.LookPath("ffmpeg"); err != nil {
		t.Skip("ffmpeg not available")
	}

	// Create a sequence of distinct RGBA PNG fixtures (moving circle/box) that
	// our stub vesper-matte script copies into out-dir and head-crop.
	fixtureDir := t.TempDir()
	for i := 1; i <= 12; i++ {
		frameImg := image.NewNRGBA(image.Rect(0, 0, 64, 64))
		x0 := 10 + (i % 12)
		for y := 16; y < 48; y++ {
			for x := x0; x < x0+28; x++ {
				frameImg.SetNRGBA(x, y, color.NRGBA{R: 220, G: 80, B: 40, A: 255})
			}
		}
		if err := writeNRGBAPNG(filepath.Join(fixtureDir, fmt.Sprintf("sample_%02d.png", i)), frameImg); err != nil {
			t.Fatalf("write sample PNG %d: %v", i, err)
		}
	}

	stubBin := filepath.Join(fixtureDir, "vesper-matte-stub")
	script := fmt.Sprintf(`#!/usr/bin/env bash
set -euo pipefail
out_dir=""
head_crop=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --out-dir) out_dir="$2"; shift 2 ;;
    --head-crop) head_crop="$2"; shift 2 ;;
    *) shift ;;
  esac
done
mkdir -p "$out_dir"
for i in $(seq -w 1 12); do
  cp %q/sample_${i}.png "$out_dir/frame_000${i}.png"
done
if [[ -n "$head_crop" ]]; then
  cp %q/sample_01.png "$head_crop"
fi
`, fixtureDir, fixtureDir)
	if err := os.WriteFile(stubBin, []byte(script), 0o755); err != nil {
		t.Fatalf("write stub binary: %v", err)
	}

	vm := &VisionMatter{BinPath: stubBin}
	if !vm.Available() {
		t.Fatalf("expected VisionMatter with explicit BinPath to be Available")
	}

	res, err := Pack(context.Background(), []byte("ignored-by-stub"), Options{
		TargetWidth:     64,
		TargetHeight:    64,
		FPS:             10,
		CrossfadeFrames: 3,
		HeadCropSize:    64,
		Matter:          vm,
	})
	if err != nil {
		t.Fatalf("Pack with VisionMatter stub failed: %v", err)
	}
	if res.Backend != "vision" {
		t.Errorf("expected backend vision, got %q", res.Backend)
	}
	if res.Frames != 9 {
		t.Errorf("expected 9 frames (12 - 3 crossfade), got %d", res.Frames)
	}
	parseAnimatedWebPHeader(t, res.WebP)
	if len(res.HeadCropPNG) == 0 {
		t.Errorf("expected HeadCropPNG from VisionMatter stub")
	}
}
