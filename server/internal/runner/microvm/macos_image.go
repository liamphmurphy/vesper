package microvm

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
)

// Files of a macOS golden image directory. The layout is a Tart VM's
// (https://tart.run): one installed disk, its auxiliary storage (NVRAM), and
// a config.json naming the hardware model it was installed for.
const (
	MacOSDiskFile   = "disk.img"
	MacOSAuxFile    = "nvram.bin"
	MacOSConfigFile = "config.json"
)

// MacOSImage is a prepared macOS golden image that macOS guest VMs clone.
type MacOSImage struct {
	Dir      string
	DiskPath string
	AuxPath  string
	// HardwareModel is VZMacHardwareModel's data representation.
	HardwareModel []byte
}

type macOSImageConfig struct {
	OS            string `json:"os"`
	Arch          string `json:"arch"`
	HardwareModel []byte `json:"hardwareModel"` // base64 in the JSON
}

// LoadMacOSImage reads the golden image in dir. It returns an error wrapping
// os.ErrNotExist when dir has no image, so callers can treat "not set up" as
// macOS guests being off.
func LoadMacOSImage(dir string) (*MacOSImage, error) {
	if dir == "" {
		return nil, fmt.Errorf("microvm: no macOS image directory: %w", os.ErrNotExist)
	}
	raw, err := os.ReadFile(filepath.Join(dir, MacOSConfigFile))
	if err != nil {
		return nil, fmt.Errorf("microvm: macOS image %s: %w", dir, err)
	}
	var cfg macOSImageConfig
	if err := json.Unmarshal(raw, &cfg); err != nil {
		return nil, fmt.Errorf("microvm: macOS image %s: %s: %w", dir, MacOSConfigFile, err)
	}
	if cfg.OS != "" && cfg.OS != "darwin" {
		return nil, fmt.Errorf("microvm: macOS image %s is a %q VM, not darwin", dir, cfg.OS)
	}
	if cfg.Arch != "" && cfg.Arch != "arm64" {
		return nil, fmt.Errorf("microvm: macOS image %s is for %q; Apple silicon needs arm64", dir, cfg.Arch)
	}
	if len(cfg.HardwareModel) == 0 {
		return nil, fmt.Errorf("microvm: macOS image %s: %s has no hardwareModel", dir, MacOSConfigFile)
	}
	img := &MacOSImage{
		Dir:           dir,
		DiskPath:      filepath.Join(dir, MacOSDiskFile),
		AuxPath:       filepath.Join(dir, MacOSAuxFile),
		HardwareModel: cfg.HardwareModel,
	}
	for _, p := range []string{img.DiskPath, img.AuxPath} {
		st, err := os.Stat(p)
		if err != nil {
			// %v, not %w: a half-copied image is broken, not absent.
			return nil, fmt.Errorf("microvm: macOS image %s: %v", dir, err)
		}
		if !st.Mode().IsRegular() {
			return nil, fmt.Errorf("microvm: macOS image %s: %s isn't a file", dir, filepath.Base(p))
		}
	}
	return img, nil
}

// IsMacOSImageMissing reports whether err means there's no image to load.
func IsMacOSImageMissing(err error) bool { return errors.Is(err, os.ErrNotExist) }
