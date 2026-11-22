package looppack

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
)

// MatteResult describes the matted RGBA PNG frame sequence produced by a Matter.
type MatteResult struct {
	FramesDir   string
	FrameCount  int
	HeadCropPNG []byte
	Backend     string
}

// Matter extracts foreground frames with an alpha channel from an input MP4 into
// a sequence of 1-indexed RGBA PNGs (`frame_%05d.png`) in outDir.
type Matter interface {
	Name() string
	Available() bool
	Matte(ctx context.Context, inputMP4 string, outDir string, opts Options) (*MatteResult, error)
}

// DefaultMatter returns VisionMatter on macOS when the native `vesper-matte`
// helper is available, falling back to FFmpegChromaMatter otherwise.
func DefaultMatter() Matter {
	vm := &VisionMatter{}
	if vm.Available() {
		return vm
	}
	return &FFmpegChromaMatter{}
}

// VisionMatter invokes the native Apple Silicon `vesper-matte` Swift CLI helper
// (Vision framework + CoreImage + AVFoundation) for high-fidelity soft alpha
// matting and face-aware head-crop extraction.
type VisionMatter struct {
	// BinPath optionally pins the path to the vesper-matte binary.
	BinPath string
}

func (v *VisionMatter) Name() string { return "vision" }

// ResolveBin searches for the `vesper-matte` executable via:
// 1) Explicit BinPath,
// 2) VESPER_MATTE_BIN environment variable,
// 3) Adjacent to the current executable,
// 4) Staged macOS resources (`macos/staged/bin/vesper-matte`),
// 5) System PATH.
func (v *VisionMatter) ResolveBin() string {
	if v != nil && strings.TrimSpace(v.BinPath) != "" {
		if isExecutableFile(v.BinPath) {
			return v.BinPath
		}
		return ""
	}
	if envBin := strings.TrimSpace(os.Getenv("VESPER_MATTE_BIN")); envBin != "" {
		if isExecutableFile(envBin) {
			return envBin
		}
	}
	if exe, err := os.Executable(); err == nil {
		adj := filepath.Join(filepath.Dir(exe), "vesper-matte")
		if isExecutableFile(adj) {
			return adj
		}
	}
	for _, rel := range []string{
		filepath.Join("macos", "staged", "bin", "vesper-matte"),
		filepath.Join("..", "macos", "staged", "bin", "vesper-matte"),
	} {
		if isExecutableFile(rel) {
			return rel
		}
	}
	if found, err := exec.LookPath("vesper-matte"); err == nil && isExecutableFile(found) {
		return found
	}
	return ""
}

func (v *VisionMatter) Available() bool {
	if v != nil && strings.TrimSpace(v.BinPath) != "" {
		return isExecutableFile(v.BinPath)
	}
	if runtime.GOOS != "darwin" {
		return false
	}
	return v.ResolveBin() != ""
}

func (v *VisionMatter) Matte(ctx context.Context, inputMP4 string, outDir string, opts Options) (*MatteResult, error) {
	bin := v.ResolveBin()
	if bin == "" {
		return nil, fmt.Errorf("looppack: vesper-matte binary not found")
	}

	headCropPath := filepath.Join(filepath.Dir(outDir), "head_crop.png")
	args := []string{
		"--input", inputMP4,
		"--out-dir", outDir,
		"--fps", strconv.Itoa(opts.FPS),
		"--width", strconv.Itoa(opts.TargetWidth),
		"--height", strconv.Itoa(opts.TargetHeight),
		"--head-crop", headCropPath,
		"--head-crop-size", strconv.Itoa(opts.HeadCropSize),
	}
	if opts.FeatherBottom > 0 {
		args = append(args, "--feather-bottom", fmt.Sprintf("%.4f", opts.FeatherBottom))
	}
	if opts.ChromaColor != "" {
		args = append(args, "--chroma-despill", opts.ChromaColor)
	}

	cmd := exec.CommandContext(ctx, bin, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, fmt.Errorf("looppack: vesper-matte failed: %w: %s", err, strings.TrimSpace(stderr.String()))
	}

	count, err := countFramePNGs(outDir)
	if err != nil {
		return nil, err
	}
	if count == 0 {
		return nil, fmt.Errorf("looppack: vesper-matte produced 0 frames")
	}

	var headCropPNG []byte
	if data, err := os.ReadFile(headCropPath); err == nil && len(data) > 0 {
		headCropPNG = data
	}

	return &MatteResult{
		FramesDir:   outDir,
		FrameCount:  count,
		HeadCropPNG: headCropPNG,
		Backend:     v.Name(),
	}, nil
}

// FFmpegChromaMatter is a cross-platform fallback that uses ffmpeg's RGB
// `colorkey`, optional `despill` (for green/blue screens), and optional
// bottom-edge alpha feather via `geq` to produce matted RGBA PNG frames.
type FFmpegChromaMatter struct {
	FFmpegBin string
}

func (f *FFmpegChromaMatter) Name() string { return "ffmpeg-chroma" }

func (f *FFmpegChromaMatter) Available() bool {
	bin := "ffmpeg"
	if f != nil && strings.TrimSpace(f.FFmpegBin) != "" {
		bin = f.FFmpegBin
	}
	_, err := exec.LookPath(bin)
	return err == nil
}

func (f *FFmpegChromaMatter) Matte(ctx context.Context, inputMP4 string, outDir string, opts Options) (*MatteResult, error) {
	binName := opts.FFmpegBin
	if binName == "" && f != nil {
		binName = f.FFmpegBin
	}
	ffmpegPath, err := resolveFFmpeg(binName)
	if err != nil {
		return nil, err
	}

	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return nil, fmt.Errorf("looppack: create frames dir: %w", err)
	}

	vf := buildChromaFilterGraph(opts)
	outPattern := filepath.Join(outDir, "frame_%05d.png")

	args := []string{
		"-hide_banner",
		"-loglevel", "error",
		"-y",
		"-i", inputMP4,
		"-vf", vf,
		"-pix_fmt", "rgba",
		outPattern,
	}

	cmd := exec.CommandContext(ctx, ffmpegPath, args...)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}
		return nil, fmt.Errorf("looppack: ffmpeg chroma matting failed: %w: %s", err, strings.TrimSpace(stderr.String()))
	}

	count, err := countFramePNGs(outDir)
	if err != nil {
		return nil, err
	}
	if count == 0 {
		return nil, fmt.Errorf("looppack: ffmpeg chroma matting produced 0 frames")
	}

	return &MatteResult{
		FramesDir:  outDir,
		FrameCount: count,
		Backend:    f.Name(),
	}, nil
}

func buildChromaFilterGraph(opts Options) string {
	filters := []string{
		fmt.Sprintf("fps=%d", opts.FPS),
		fmt.Sprintf("scale=%d:%d:force_original_aspect_ratio=increase:flags=lanczos", opts.TargetWidth, opts.TargetHeight),
		fmt.Sprintf("crop=%d:%d", opts.TargetWidth, opts.TargetHeight),
		"format=rgba",
		fmt.Sprintf("colorkey=%s:%.4f:%.4f", opts.ChromaColor, opts.ChromaSimilarity, opts.ChromaBlend),
	}

	r, g, b := parseRGB(opts.ChromaColor)
	if int(g) > int(r)+40 && int(g) > int(b)+40 {
		filters = append(filters, "despill=type=green")
	} else if int(b) > int(r)+40 && int(b) > int(g)+40 {
		filters = append(filters, "despill=type=blue")
	}

	if opts.FeatherBottom > 0 {
		// Linearly fade alpha from 1.0 at Y = H*(1-F) to 0.0 at Y = H.
		filters = append(filters, fmt.Sprintf(
			"geq=r='r(X,Y)':g='g(X,Y)':b='b(X,Y)':a='if(gt(Y,H*(1-%.4f)),alpha(X,Y)*max(0,(H-Y)/(H*%.4f)),alpha(X,Y))'",
			opts.FeatherBottom, opts.FeatherBottom,
		))
	}

	return strings.Join(filters, ",")
}

func resolveFFmpeg(override string) (string, error) {
	bin := strings.TrimSpace(override)
	if bin == "" {
		bin = "ffmpeg"
	}
	path, err := exec.LookPath(bin)
	if err != nil {
		return "", fmt.Errorf("%w: %q not found in PATH (install ffmpeg with libwebp support): %v", ErrFFmpegNotFound, bin, err)
	}
	return path, nil
}

func isExecutableFile(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode()&0o111 != 0
}

func countFramePNGs(dir string) (int, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, fmt.Errorf("looppack: read frames dir: %w", err)
	}
	var names []string
	for _, e := range entries {
		if !e.IsDir() && strings.HasPrefix(e.Name(), "frame_") && strings.HasSuffix(e.Name(), ".png") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)
	return len(names), nil
}
