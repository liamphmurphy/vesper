package main

import (
	"encoding/json"
	"fmt"
	"path"
	"strings"
)

func isContainerCreatePath(p string) bool {
	if p == "/containers/create" {
		return true
	}
	return strings.HasPrefix(p, "/v") && strings.HasSuffix(p, "/containers/create") && strings.Count(p, "/") == 3
}

// validateDockerContainerCreate rejects host escapes and bind mounts outside
// /workspace and /tmp so in-guest dockerd cannot alter host or rootfs state.
func validateDockerContainerCreate(body []byte) string {
	var spec struct {
		HostConfig struct {
			Privileged  bool     `json:"Privileged"`
			NetworkMode string   `json:"NetworkMode"`
			PidMode     string   `json:"PidMode"`
			IpcMode     string   `json:"IpcMode"`
			UTSMode     string   `json:"UTSMode"`
			UsernsMode  string   `json:"UsernsMode"`
			CapAdd      []string `json:"CapAdd"`
			Devices     []any    `json:"Devices"`
			Binds       []string `json:"Binds"`
			Mounts      []struct {
				Type   string `json:"Type"`
				Source string `json:"Source"`
			} `json:"Mounts"`
		} `json:"HostConfig"`
	}
	if err := json.Unmarshal(body, &spec); err != nil {
		return ""
	}
	hc := spec.HostConfig
	if hc.Privileged {
		return "vesper guard: privileged containers are disabled"
	}
	for name, mode := range map[string]string{
		"NetworkMode": hc.NetworkMode,
		"PidMode":     hc.PidMode,
		"IpcMode":     hc.IpcMode,
		"UTSMode":     hc.UTSMode,
		"UsernsMode":  hc.UsernsMode,
	} {
		if strings.EqualFold(strings.TrimSpace(mode), "host") {
			return fmt.Sprintf("vesper guard: %s=host is disabled", name)
		}
	}
	if len(hc.CapAdd) > 0 {
		return "vesper guard: adding Linux capabilities is disabled"
	}
	if len(hc.Devices) > 0 {
		return "vesper guard: device passthrough is disabled"
	}
	for _, b := range hc.Binds {
		src, _, hasColon := strings.Cut(b, ":")
		if !hasColon {
			continue
		}
		if strings.HasPrefix(src, "/") && !allowedBindSource(src) {
			return fmt.Sprintf("vesper guard: bind mount %q outside /workspace and /tmp is denied", src)
		}
	}
	for _, m := range hc.Mounts {
		if (strings.EqualFold(m.Type, "bind") || strings.HasPrefix(m.Source, "/")) && !allowedBindSource(m.Source) {
			return fmt.Sprintf("vesper guard: bind mount %q outside /workspace and /tmp is denied", m.Source)
		}
	}
	return ""
}

func allowedBindSource(src string) bool {
	if !strings.HasPrefix(src, "/") {
		return false
	}
	clean := path.Clean(src)
	return clean == "/workspace" || strings.HasPrefix(clean, "/workspace/") ||
		clean == "/tmp" || strings.HasPrefix(clean, "/tmp/") ||
		clean == "/var/run/docker.sock"
}
