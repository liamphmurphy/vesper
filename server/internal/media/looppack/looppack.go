package looppack

import (
	"bytes"
	"context"
	"fmt"
	"image"
	"image/png"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"

	xdraw "golang.org/x/image/draw"
)

const minEncodeQuality = 15

// Pack mattes an input MP4 video, applies a seamless multi-frame loop-seam
// cross-dissolve, encodes to Animated WebP with alpha transparency, extracts a
// square head-crop PNG, and enforces MaxOutputBytes.
func Pack(ctx context.Context, mp4Bytes []byte, opts Options) (*Result, error) {
	if len(mp4Bytes) == 0 {
		return nil, fmt.Errorf("%w: empty MP4 input", ErrInvalidInput)
	}
	if err := ctx.Err(); err != nil {
		return nil, err
	}

	normOpts, err := opts.withDefaults()
	if err != nil {
		return nil, err
	}

	// Verify ffmpeg up front so missing dependencies fail fast before matting work.
	ffmpegPath, err := resolveFFmpeg(normOpts.FFmpegBin)
	if err != nil {
		return nil, err
	}

	tmpDir, err := os.MkdirTemp(normOpts.TempDirBase, "vesper-looppack-*")
	if err != nil {
		return nil, fmt.Errorf("looppack: create temp dir: %w", err)
	}
	defer os.RemoveAll(tmpDir)

	inputPath := filepath.Join(tmpDir, "input.mp4")
	if err := os.WriteFile(inputPath, mp4Bytes, 0o600); err != nil {
		return nil, fmt.Errorf("looppack: write input mp4: %w", err)
	}

	framesDir := filepath.Join(tmpDir, "frames")
	if err := os.MkdirAll(framesDir, 0o755); err != nil {
		return nil, fmt.Errorf("looppack: create frames dir: %w", err)
	}

	matter := normOpts.Matter
	if matter == nil {
		matter = DefaultMatter()
	}

	matteRes, err := matter.Matte(ctx, inputPath, framesDir, normOpts)
	if err != nil {
		return nil, err
	}
	if matteRes.FrameCount == 0 {
		return nil, fmt.Errorf("looppack: matter %q produced 0 frames", matter.Name())
	}

	// Extract head crop from unblended frame 1 if the matter did not produce a
	// face-aware head crop (e.g. FFmpegChromaMatter fallback).
	headCropPNG := matteRes.HeadCropPNG
	if len(headCropPNG) == 0 {
		firstFramePath := filepath.Join(framesDir, fmt.Sprintf("frame_%05d.png", 1))
		headCropPNG, err = extractFallbackHeadCrop(firstFramePath, normOpts.HeadCropSize)
		if err != nil {
			return nil, err
		}
	}

	if err := ctx.Err(); err != nil {
		return nil, err
	}

	// Apply seamless loop-seam cross-dissolve across the boundary frames.
	finalFrames, err := applyLoopCrossfade(framesDir, matteRes.FrameCount, normOpts.CrossfadeFrames)
	if err != nil {
		return nil, err
	}

	// Encode Animated WebP with automatic quality step-down to honor MaxOutputBytes.
	webpBytes, err := encodeAnimatedWebPWithBudget(ctx, ffmpegPath, framesDir, tmpDir, normOpts)
	if err != nil {
		return nil, err
	}

	durationMS := (finalFrames * 1000) / normOpts.FPS
	return &Result{
		WebP:        webpBytes,
		HeadCropPNG: headCropPNG,
		Width:       normOpts.TargetWidth,
		Height:      normOpts.TargetHeight,
		Frames:      finalFrames,
		DurationMS:  durationMS,
		Backend:     matteRes.Backend,
	}, nil
}

// applyLoopCrossfade blends the last K frames (`N-K+1 .. N`) over the first K
// frames (`1 .. K`) in premultiplied-alpha space and removes the trailing K
// frames so the loop wraps cleanly from frame `N-K` back to frame `1`.
func applyLoopCrossfade(framesDir string, totalFrames int, crossfadeFrames int) (int, error) {
	if crossfadeFrames <= 0 || totalFrames < 3 {
		return totalFrames, nil
	}
	k := crossfadeFrames
	if maxK := (totalFrames - 1) / 2; k > maxK {
		k = maxK
	}
	if k <= 0 {
		return totalFrames, nil
	}

	for i := 0; i < k; i++ {
		headPath := filepath.Join(framesDir, fmt.Sprintf("frame_%05d.png", i+1))
		tailPath := filepath.Join(framesDir, fmt.Sprintf("frame_%05d.png", totalFrames-k+i+1))

		headImg, err := readPNGAsNRGBA(headPath)
		if err != nil {
			return 0, fmt.Errorf("looppack: read head frame %d: %w", i+1, err)
		}
		tailImg, err := readPNGAsNRGBA(tailPath)
		if err != nil {
			return 0, fmt.Errorf("looppack: read tail frame %d: %w", totalFrames-k+i+1, err)
		}

		// At i=0, weight leans toward tail[0] (continuing smoothly from frame N-K).
		// At i=k-1, weight leans toward head[k-1] (leading smoothly into frame K+1).
		wHead := float64(i+1) / float64(k+1)
		blended := blendNRGBA(headImg, tailImg, wHead)
		if err := writeNRGBAPNG(headPath, blended); err != nil {
			return 0, fmt.Errorf("looppack: write blended frame %d: %w", i+1, err)
		}
	}

	// Remove the consumed tail frames so ffmpeg encodes exactly `totalFrames - k` frames.
	for i := totalFrames - k + 1; i <= totalFrames; i++ {
		tailPath := filepath.Join(framesDir, fmt.Sprintf("frame_%05d.png", i))
		if err := os.Remove(tailPath); err != nil && !os.IsNotExist(err) {
			return 0, fmt.Errorf("looppack: remove tail frame %d: %w", i, err)
		}
	}
	return totalFrames - k, nil
}

// blendNRGBA blends `a` (weight wa) and `b` (weight 1-wa) in premultiplied alpha
// space so transparent regions do not bleed dark fringes into edges.
func blendNRGBA(a, b *image.NRGBA, wa float64) *image.NRGBA {
	bounds := a.Bounds()
	out := image.NewNRGBA(image.Rect(0, 0, bounds.Dx(), bounds.Dy()))
	wb := 1.0 - wa
	w := bounds.Dx()
	h := bounds.Dy()

	for y := 0; y < h; y++ {
		aRow := a.Pix[y*a.Stride:]
		bRow := b.Pix[y*b.Stride:]
		oRow := out.Pix[y*out.Stride:]
		for x := 0; x < w; x++ {
			off := x * 4
			aA := float64(aRow[off+3]) / 255.0
			bA := float64(bRow[off+3]) / 255.0

			outA := wa*aA + wb*bA
			if outA <= 1e-6 {
				oRow[off] = 0
				oRow[off+1] = 0
				oRow[off+2] = 0
				oRow[off+3] = 0
				continue
			}

			rPre := wa*float64(aRow[off])*aA + wb*float64(bRow[off])*bA
			gPre := wa*float64(aRow[off+1])*aA + wb*float64(bRow[off+1])*bA
			bPre := wa*float64(aRow[off+2])*aA + wb*float64(bRow[off+2])*bA

			oRow[off] = clampU8(rPre / outA)
			oRow[off+1] = clampU8(gPre / outA)
			oRow[off+2] = clampU8(bPre / outA)
			oRow[off+3] = clampU8(outA * 255.0)
		}
	}
	return out
}

func clampU8(v float64) uint8 {
	if v <= 0 {
		return 0
	}
	if v >= 255 {
		return 255
	}
	return uint8(math.Round(v))
}

func extractFallbackHeadCrop(framePath string, size int) ([]byte, error) {
	src, err := readPNGAsNRGBA(framePath)
	if err != nil {
		return nil, fmt.Errorf("looppack: read frame 1 for head crop: %w", err)
	}
	b := src.Bounds()
	side := b.Dx()
	if b.Dy() < side {
		side = b.Dy()
	}
	// Upper-center square crop.
	x0 := b.Min.X + (b.Dx()-side)/2
	y0 := b.Min.Y
	cropRect := image.Rect(x0, y0, x0+side, y0+side)

	dst := image.NewNRGBA(image.Rect(0, 0, size, size))
	xdraw.CatmullRom.Scale(dst, dst.Bounds(), src, cropRect, xdraw.Src, nil)

	var buf bytes.Buffer
	if err := png.Encode(&buf, dst); err != nil {
		return nil, fmt.Errorf("looppack: encode head crop PNG: %w", err)
	}
	return buf.Bytes(), nil
}

func encodeAnimatedWebPWithBudget(
	ctx context.Context,
	ffmpegPath string,
	framesDir string,
	tmpDir string,
	opts Options,
) ([]byte, error) {
	quality := opts.Quality
	outPath := filepath.Join(tmpDir, "loop.webp")

	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if err := runFFmpegWebPEncode(ctx, ffmpegPath, framesDir, outPath, opts.FPS, quality); err != nil {
			return nil, err
		}
		data, err := os.ReadFile(outPath)
		if err != nil {
			return nil, fmt.Errorf("looppack: read encoded WebP: %w", err)
		}
		if len(data) <= opts.MaxOutputBytes {
			return data, nil
		}
		if quality <= minEncodeQuality {
			return nil, fmt.Errorf(
				"%w: %d bytes at minimum quality %d exceeds limit of %d bytes",
				ErrOutputTooLarge, len(data), quality, opts.MaxOutputBytes,
			)
		}
		quality -= 15
		if quality < minEncodeQuality {
			quality = minEncodeQuality
		}
	}
}

func runFFmpegWebPEncode(
	ctx context.Context,
	ffmpegPath string,
	framesDir string,
	outPath string,
	fps int,
	quality int,
) error {
	inPattern := filepath.Join(framesDir, "frame_%05d.png")
	args := []string{
		"-hide_banner",
		"-loglevel", "error",
		"-y",
		"-framerate", strconv.Itoa(fps),
		"-i", inPattern,
		"-c:v", "libwebp_anim",
		"-lossless", "0",
		"-quality", strconv.Itoa(quality),
		"-loop", "0",
		"-pix_fmt", "yuva420p",
		outPath,
	}
	cmd := exec.CommandContext(ctx, ffmpegPath, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return ctx.Err()
		}
		return fmt.Errorf("looppack: ffmpeg libwebp_anim encode failed: %w: %s", err, strings.TrimSpace(stderr.String()))
	}
	return nil
}

func readPNGAsNRGBA(path string) (*image.NRGBA, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	img, err := png.Decode(f)
	if err != nil {
		return nil, err
	}
	if nrgba, ok := img.(*image.NRGBA); ok {
		return nrgba, nil
	}
	b := img.Bounds()
	dst := image.NewNRGBA(image.Rect(0, 0, b.Dx(), b.Dy()))
	xdraw.Copy(dst, image.Point{}, img, b, xdraw.Src, nil)
	return dst, nil
}

func writeNRGBAPNG(path string, img *image.NRGBA) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	if err := png.Encode(f, img); err != nil {
		_ = f.Close()
		return err
	}
	return f.Close()
}
