package guestproto

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"path"
	"strings"
)

// The mac API is how `mac` in a run's Linux VM reaches the host's macOS guest
// broker, over HTTP at mac.vesper.internal. A call is:
//
//  1. POST MacPathStart: boot the run's macOS VM if it isn't running. The
//     response is NDJSON MacStatus lines, ending in "ready" or "error".
//  2. POST MacPathPlan with a MacPlanReq: the files that changed since the
//     last sync. Read-only.
//  3. POST MacPathUpload: the MacManifest framed by WriteMacManifest, then a
//     tar of the files the plan asked for. Files in the last manifest but not
//     this one are deleted.
//  4. POST MacPathExec with a MacExecReq: the response streams the command's
//     output as FrameStdout, FrameStderr and a final FrameExecExit.
//  5. POST MacPathPull with a MacPullReq (optional): a tar of those paths,
//     streamed as FrameStdout chunks, then FrameExecExit.
//
// POST MacPathAgentLog, on its own, returns the end of the macOS guest
// agent's log as text, for when the guest itself misbehaves.
const (
	MacPathStart    = "/v1/start"
	MacPathPlan     = "/v1/sync/plan"
	MacPathUpload   = "/v1/sync/upload"
	MacPathExec     = "/v1/exec"
	MacPathPull     = "/v1/pull"
	MacPathAgentLog = "/v1/agent-log"
)

// MacAgentLogPath is where launchd writes the macOS guest agent's stderr
// (StandardErrorPath in deploy/microvm/macos-golden.sh).
const MacAgentLogPath = "/var/log/vesper-guest-agent.log"

// MacMaxManifestBytes bounds a manifest: about 200k files of typical path length.
const MacMaxManifestBytes = 32 << 20

// MacFile is one synced file, keyed by its slash-separated path relative to
// the synced tree's root.
type MacFile struct {
	Path    string `json:"p"`
	Size    int64  `json:"s"`
	Mode    uint32 `json:"m"`
	MtimeNS int64  `json:"t"`
}

// MacManifest is every file under Root, a directory relative to the synced
// tree's root ("" for all of it). A run with several checkouts syncs each
// on its own, so an upload only deletes files under its Root.
type MacManifest struct {
	Root  string    `json:"root,omitempty"`
	Files []MacFile `json:"files"`
}

// MacPlanReq asks which of these files the macOS copy lacks or has stale.
type MacPlanReq = MacManifest

type MacPlanResp struct {
	Need []string `json:"need"`
}

// MacStatus is one NDJSON line of the start response.
type MacStatus struct {
	// Status is "waiting" (no macOS VM slot free), "booting", "ready" or "error".
	Status  string `json:"status"`
	Message string `json:"message,omitempty"`
}

type MacExecReq struct {
	Argv []string `json:"argv"`
	// Dir is relative to the synced tree's root; "" is the root.
	Dir string            `json:"dir,omitempty"`
	Env map[string]string `json:"env,omitempty"`
}

type MacPullReq struct {
	// Paths are relative to the synced tree's root.
	Paths []string `json:"paths"`
}

// CleanMacPath returns p as a clean relative path inside the synced tree, or
// an error for an absolute path, one that leaves the tree, or the root itself
// unless allowRoot.
func CleanMacPath(p string, allowRoot bool) (string, error) {
	if strings.ContainsRune(p, 0) || strings.Contains(p, `\`) {
		return "", fmt.Errorf("mac: invalid path %q", p)
	}
	if path.IsAbs(p) {
		return "", fmt.Errorf("mac: path %q must be relative to the workspace", p)
	}
	c := path.Clean(p)
	if c == ".." || strings.HasPrefix(c, "../") {
		return "", fmt.Errorf("mac: path %q leaves the workspace", p)
	}
	if c == "." {
		if allowRoot {
			return "", nil
		}
		return "", errors.New("mac: path is the workspace root")
	}
	return c, nil
}

// WriteMacManifest writes m length-prefixed, ahead of the upload's tar.
func WriteMacManifest(w io.Writer, m MacManifest) error {
	b, err := json.Marshal(m)
	if err != nil {
		return err
	}
	if len(b) > MacMaxManifestBytes {
		return fmt.Errorf("mac: manifest too large (%d files)", len(m.Files))
	}
	var hdr [4]byte
	binary.BigEndian.PutUint32(hdr[:], uint32(len(b)))
	if err := writeFull(w, hdr[:]); err != nil {
		return err
	}
	return writeFull(w, b)
}

// ReadMacManifest reads a manifest written by WriteMacManifest, leaving r at
// the start of the tar.
func ReadMacManifest(r io.Reader) (MacManifest, error) {
	var hdr [4]byte
	if _, err := io.ReadFull(r, hdr[:]); err != nil {
		return MacManifest{}, fmt.Errorf("mac: read manifest length: %w", err)
	}
	n := binary.BigEndian.Uint32(hdr[:])
	if n > MacMaxManifestBytes {
		return MacManifest{}, fmt.Errorf("mac: manifest too large (%d bytes)", n)
	}
	b := make([]byte, n)
	if _, err := io.ReadFull(r, b); err != nil {
		return MacManifest{}, fmt.Errorf("mac: read manifest: %w", err)
	}
	var m MacManifest
	if err := json.Unmarshal(b, &m); err != nil {
		return MacManifest{}, fmt.Errorf("mac: decode manifest: %w", err)
	}
	return m, nil
}
