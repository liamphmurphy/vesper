package config

import (
	"testing"
	"time"
)

func TestModelPriceConfiguration(t *testing.T) {
	for _, tt := range []struct {
		name, raw string
		valid     bool
	}{
		{"complete", `{"test":{"input_per_million":2,"cached_input_per_million":0.2,"output_per_million":10}}`, true},
		{"negative", `{"test":{"input_per_million":-2,"cached_input_per_million":0,"output_per_million":10}}`, false},
		{"incomplete", `{"test":{"input_per_million":2}}`, false},
		{"null", `{"test":{"input_per_million":null,"cached_input_per_million":0,"output_per_million":10}}`, false},
	} {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("RUNNER_MODEL_PRICES", tt.raw)
			c, err := Load()
			if tt.valid {
				if err != nil || c.Runner.ModelPrices["test"].Input != 2 {
					t.Fatalf("valid prices rejected: %v", err)
				}
			} else if err == nil {
				t.Fatal("invalid prices accepted")
			}
		})
	}
}

func TestHostWorkspacesMustBeAbsolute(t *testing.T) {
	t.Setenv("RUNNER_HOST_WORKSPACES_DIR", "workspaces")
	if _, err := Load(); err == nil {
		t.Fatal("relative RUNNER_HOST_WORKSPACES_DIR accepted")
	}
	t.Setenv("RUNNER_HOST_WORKSPACES_DIR", "/Users/me/vesper/workspaces")
	if c, err := Load(); err != nil || c.Runner.HostWorkspaces != "/Users/me/vesper/workspaces" {
		t.Fatalf("absolute path: %q %v", c.Runner.HostWorkspaces, err)
	}
}

func TestExtraCAFileMustBeAbsolute(t *testing.T) {
	t.Setenv("RUNNER_EXTRA_CA_FILE", "zscaler-root.pem")
	if _, err := Load(); err == nil {
		t.Fatal("relative RUNNER_EXTRA_CA_FILE accepted")
	}
	t.Setenv("RUNNER_EXTRA_CA_FILE", "/Users/me/zscaler-root.pem:relative.cer")
	if _, err := Load(); err == nil {
		t.Fatal("relative entry in RUNNER_EXTRA_CA_FILE list accepted")
	}
	t.Setenv("RUNNER_EXTRA_CA_FILE", "/Users/me/zscaler-root.pem")
	c, err := Load()
	if err != nil || len(c.Runner.ExtraCAFiles) != 1 || c.Runner.ExtraCAFiles[0] != "/Users/me/zscaler-root.pem" {
		t.Fatalf("single absolute path: %q %v", c.Runner.ExtraCAFiles, err)
	}
	t.Setenv("RUNNER_EXTRA_CA_FILE", "/Users/me/zscaler-root.pem:/Users/me/zscaler-int.cer:/Users/me/zscaler-root.pem:")
	c, err = Load()
	if err != nil || len(c.Runner.ExtraCAFiles) != 2 || c.Runner.ExtraCAFiles[0] != "/Users/me/zscaler-root.pem" || c.Runner.ExtraCAFiles[1] != "/Users/me/zscaler-int.cer" {
		t.Fatalf("multiple absolute paths: %q %v", c.Runner.ExtraCAFiles, err)
	}
}

func TestSpareVMsDefaultAndBounds(t *testing.T) {
	c, err := Load()
	if err != nil || c.Runner.SpareVMs != 1 {
		t.Fatalf("default: %d %v", c.Runner.SpareVMs, err)
	}
	t.Setenv("RUNNER_VM_SPARES", "0")
	if c, err := Load(); err != nil || c.Runner.SpareVMs != 0 {
		t.Fatalf("off: %d %v", c.Runner.SpareVMs, err)
	}
	for _, bad := range []string{"-1", "5", "many"} {
		t.Setenv("RUNNER_VM_SPARES", bad)
		if _, err := Load(); err == nil {
			t.Fatalf("RUNNER_VM_SPARES=%s loaded", bad)
		}
	}
}

func TestMacOSGuestsDefaultsAndBounds(t *testing.T) {
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	m := c.Runner.MacOS
	if m.MaxVMs != 2 || m.IdleTTL != 10*time.Minute || m.CPUs != 4 || m.MemoryMB != 8192 || m.User != "admin" || m.ImageDir != "" {
		t.Fatalf("defaults = %+v", m)
	}
	t.Setenv("RUNNER_MACOS_VMS", "0")
	if c, err := Load(); err != nil || c.Runner.MacOS.MaxVMs != 0 {
		t.Fatalf("off: %d %v", c.Runner.MacOS.MaxVMs, err)
	}
	for key, bad := range map[string]string{
		"RUNNER_MACOS_VMS":        "3",
		"RUNNER_MACOS_IDLE_TTL_S": "5",
		"RUNNER_MACOS_MEMORY_MB":  "1024",
		"RUNNER_MACOS_IMAGE_DIR":  "golden",
	} {
		t.Run(key, func(t *testing.T) {
			t.Setenv(key, bad)
			if _, err := Load(); err == nil {
				t.Fatalf("%s=%s loaded", key, bad)
			}
		})
	}
}
