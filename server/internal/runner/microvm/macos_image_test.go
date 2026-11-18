package microvm

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func writeMacOSImage(t *testing.T, dir, config string) {
	t.Helper()
	for name, data := range map[string]string{MacOSDiskFile: "disk", MacOSAuxFile: "nvram", MacOSConfigFile: config} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(data), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestLoadMacOSImageReadsTartLayout(t *testing.T) {
	dir := t.TempDir()
	// A Tart config.json: hardwareModel and ecid are base64 data representations.
	writeMacOSImage(t, dir, `{"version":1,"os":"darwin","arch":"arm64","cpuCount":4,"memorySize":8589934592,"hardwareModel":"aHctbW9kZWw=","ecid":"ZWNpZA=="}`)
	img, err := LoadMacOSImage(dir)
	if err != nil {
		t.Fatal(err)
	}
	if string(img.HardwareModel) != "hw-model" {
		t.Errorf("hardware model = %q", img.HardwareModel)
	}
	if img.DiskPath != filepath.Join(dir, "disk.img") || img.AuxPath != filepath.Join(dir, "nvram.bin") {
		t.Errorf("paths = %q, %q", img.DiskPath, img.AuxPath)
	}
}

func TestLoadMacOSImageMissingDirIsNotExist(t *testing.T) {
	_, err := LoadMacOSImage(filepath.Join(t.TempDir(), "none"))
	if !IsMacOSImageMissing(err) {
		t.Fatalf("err = %v, want not-exist", err)
	}
	if _, err := LoadMacOSImage(""); !IsMacOSImageMissing(err) {
		t.Fatalf("empty dir: err = %v, want not-exist", err)
	}
}

func TestLoadMacOSImageRejectsBadImages(t *testing.T) {
	for name, cfg := range map[string]string{
		"linux":       `{"os":"linux","arch":"arm64","hardwareModel":"aHc="}`,
		"intel":       `{"os":"darwin","arch":"amd64","hardwareModel":"aHc="}`,
		"no hardware": `{"os":"darwin","arch":"arm64"}`,
		"not json":    `{`,
	} {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			writeMacOSImage(t, dir, cfg)
			_, err := LoadMacOSImage(dir)
			if err == nil || IsMacOSImageMissing(err) {
				t.Fatalf("err = %v, want a bad-image error", err)
			}
		})
	}
	t.Run("no disk", func(t *testing.T) {
		dir := t.TempDir()
		writeMacOSImage(t, dir, `{"os":"darwin","arch":"arm64","hardwareModel":"aHc="}`)
		_ = os.Remove(filepath.Join(dir, MacOSDiskFile))
		_, err := LoadMacOSImage(dir)
		if err == nil || IsMacOSImageMissing(err) || !strings.Contains(err.Error(), "disk.img") {
			t.Fatalf("err = %v, want missing disk.img", err)
		}
	})
}
