package customapps

import (
	"encoding/json"
	"path"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
	"unicode/utf8"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

const (
	MaxFiles                 = 20
	MaxTotalFileBytes        = 10 << 20
	MaxSQLiteBytes           = 25 << 20
	MaxNameRunes             = 80
	MaxDescriptionRunes      = 500
	MaxInstructions          = 4000
	MaxNavItems              = 32
	MaxMounts                = 16
	MaxMountPathBytes        = 1024
	MaxMountDescriptionRunes = 200

	ToolScopeChats   = "chats"
	ToolScopeAppOnly = "app_only"
)

// MaxStoredVersions is how many versions of an app are kept. Each version holds
// the full sources plus compiled bundles, so older ones are pruned on every save.
const MaxStoredVersions = 10

// MaxEditsPerUpdate bounds the find/replace edits one update may carry.
const MaxEditsPerUpdate = 100

var (
	slugRE       = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,47}$`)
	iconRE       = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)
	mcpCap       = regexp.MustCompile(`^mcp:([a-z0-9][a-z0-9-]{0,63}):(\*|[A-Za-z0-9_.:-]{1,128})$`)
	secretCap    = regexp.MustCompile(`^secret:(\*|[a-z0-9][a-z0-9-]{0,35})$`)
	nixPkgNameRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$`)
	nixCap       = regexp.MustCompile(`^nix:([A-Za-z0-9][A-Za-z0-9._+-]{0,63})$`)
	mountNameRE  = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,47}$`)
	toolRe       = regexp.MustCompile(`^[A-Za-z0-9_.:-]{1,128}$`)
)

// reservedSlugs protects built-in workbench routes; "finance" is explicitly allowed.
var reservedSlugs = []string{"docs", "slides", "designs", "new"}

var allowedExts = []string{".tsx", ".ts", ".jsx", ".js", ".css", ".sql", ".json"}

type NavItem struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Icon  string `json:"icon,omitempty"`
}

type MCPToolSpec struct {
	Name        string         `json:"name"`
	Description string         `json:"description"`
	InputSchema map[string]any `json:"input_schema"`
}

type Capabilities map[string]agentdef.Mode

type MountRequest struct {
	Name        string `json:"name"`
	Description string `json:"description,omitempty"`
}

type Mounts map[string]string

type Manifest struct {
	Entry                 string         `json:"entry"`
	MCPEntry              string         `json:"mcp_entry,omitempty"`
	ToolScope             string         `json:"tool_scope"`
	Instructions          string         `json:"instructions,omitempty"`
	Nav                   []NavItem      `json:"nav,omitempty"`
	RequestedCapabilities Capabilities   `json:"requested_capabilities,omitempty"`
	RequestedMounts       []MountRequest `json:"requested_mounts,omitempty"`
}

func ValidSlug(slug string) (string, error) {
	s := strings.TrimSpace(slug)
	if !slugRE.MatchString(s) {
		return "", apperr.Invalid("slug", "must be 1–48 lowercase letters, digits, or hyphens starting with a letter or digit")
	}
	if slices.Contains(reservedSlugs, s) {
		return "", apperr.Invalid("slug", "%q is a reserved built-in app route", s)
	}
	return s, nil
}

func ValidateName(name string) (string, error) {
	s := strings.TrimSpace(name)
	n := utf8.RuneCountInString(s)
	if n < 1 || n > MaxNameRunes {
		return "", apperr.Invalid("name", "must be 1–80 characters")
	}
	return s, nil
}

func ValidateDescription(desc string) (string, error) {
	s := strings.TrimSpace(desc)
	if utf8.RuneCountInString(s) > MaxDescriptionRunes {
		return "", apperr.Invalid("description", "must be at most 500 characters")
	}
	return s, nil
}

func ValidateIcon(icon string) (string, error) {
	s := strings.TrimSpace(icon)
	if s == "" {
		return "dashboard", nil
	}
	if !iconRE.MatchString(s) {
		return "", apperr.Invalid("icon", "invalid icon name")
	}
	return s, nil
}

func ValidNixPackage(name string) (string, error) {
	s := strings.TrimSpace(name)
	if s == "." || s == ".." || !nixPkgNameRE.MatchString(s) {
		return "", apperr.Invalid("packages", "invalid nix package name %q", name)
	}
	return s, nil
}

func ValidMountName(name string) (string, error) {
	s := strings.TrimSpace(name)
	if !mountNameRE.MatchString(s) {
		return "", apperr.Invalid("mounts", "mount name %q must be 1–48 lowercase letters, digits, hyphens, or underscores starting with a letter or digit", name)
	}
	return s, nil
}

func ValidCapabilityKey(key string) error {
	switch key {
	case "app.sql:read", "app.sql:write", "app.http:outbound", "app.media:download", "app.media:relay", "vesper.api:read", "vesper.api:write":
		return nil
	default:
		if mcpCap.MatchString(key) || secretCap.MatchString(key) {
			return nil
		}
		if m := nixCap.FindStringSubmatch(key); len(m) == 2 && m[1] != "." && m[1] != ".." {
			return nil
		}
		return apperr.Invalid("capabilities", "unknown capability %q", key)
	}
}

func NormalizeMounts(mounts Mounts) (Mounts, error) {
	if len(mounts) > MaxMounts {
		return nil, apperr.Invalid("mounts", "at most %d mounts allowed", MaxMounts)
	}
	out := make(Mounts, len(mounts))
	for rawName, rawPath := range mounts {
		name, err := ValidMountName(rawName)
		if err != nil {
			return nil, err
		}
		p := strings.TrimSpace(rawPath)
		if p == "" {
			continue
		}
		if len(p) > MaxMountPathBytes || !utf8.ValidString(p) || strings.ContainsAny(p, "\x00\r\n") {
			return nil, apperr.Invalid("mounts", "mount %q has an invalid path", name)
		}
		if !filepath.IsAbs(p) && !(strings.HasPrefix(p, "~/") && len(p) > 2) {
			return nil, apperr.Invalid("mounts", "mount %q path must be an absolute path or ~/...", name)
		}
		if _, dup := out[name]; dup {
			return nil, apperr.Invalid("mounts", "duplicate mount name %q", name)
		}
		out[name] = p
	}
	return out, nil
}

func ValidMode(mode agentdef.Mode) error {
	switch mode {
	case agentdef.Allowed, agentdef.RequiresApproval, agentdef.Denied:
		return nil
	default:
		return apperr.Invalid("capabilities", "mode must be allowed, requires_approval, or denied")
	}
}

func NormalizeCapabilities(caps Capabilities) (Capabilities, error) {
	out := Capabilities{
		"app.sql:read":  agentdef.Allowed,
		"app.sql:write": agentdef.Allowed,
	}
	for k, v := range caps {
		if err := ValidCapabilityKey(k); err != nil {
			return nil, err
		}
		if err := ValidMode(v); err != nil {
			return nil, err
		}
		out[k] = v
	}
	return out, nil
}

// ModeFor returns the effective permission mode for key.
// app.sql:read and app.sql:write default to allowed; all external capabilities
// (vesper.api:*, app.http:outbound, mcp:*, secret:*) default to denied.
// mcp:<slug>:* and secret:* wildcards combine with exact matches via agentdef.Stricter.
func ModeFor(caps Capabilities, key string) agentdef.Mode {
	exact, hasExact := caps[key]
	if m := mcpCap.FindStringSubmatch(key); len(m) == 3 && m[2] != "*" {
		wildKey := "mcp:" + m[1] + ":*"
		wild, hasWild := caps[wildKey]
		switch {
		case hasWild && hasExact:
			return agentdef.Stricter(wild, exact)
		case hasWild:
			return wild
		case hasExact:
			return exact
		default:
			return agentdef.Denied
		}
	}
	if m := secretCap.FindStringSubmatch(key); len(m) == 2 && m[1] != "*" {
		wild, hasWild := caps["secret:*"]
		switch {
		case hasWild && hasExact:
			return agentdef.Stricter(wild, exact)
		case hasWild:
			return wild
		case hasExact:
			return exact
		default:
			return agentdef.Denied
		}
	}
	if hasExact {
		return exact
	}
	if key == "app.sql:read" || key == "app.sql:write" {
		return agentdef.Allowed
	}
	return agentdef.Denied
}

func DefaultCapabilities(requested Capabilities) Capabilities {
	out := Capabilities{
		"app.sql:read":  agentdef.Allowed,
		"app.sql:write": agentdef.Allowed,
	}
	for k, v := range requested {
		if ValidCapabilityKey(k) != nil || ValidMode(v) != nil {
			continue
		}
		// Never auto-grant external capabilities from a manifest; cap at requires_approval.
		if !strings.HasPrefix(k, "app.sql:") && v == agentdef.Allowed {
			v = agentdef.RequiresApproval
		}
		out[k] = v
	}
	return out
}

func NormalizeFiles(files map[string]string) (map[string]string, error) {
	if len(files) == 0 {
		return nil, apperr.Invalid("files", "at least one source file is required")
	}
	if len(files) > MaxFiles {
		return nil, apperr.Invalid("files", "at most %d files allowed", MaxFiles)
	}
	out := make(map[string]string, len(files))
	total := 0
	for rawName, content := range files {
		if strings.ContainsRune(rawName, 0) || strings.ContainsRune(rawName, '\\') {
			return nil, apperr.Invalid("files", "invalid filename %q", rawName)
		}
		name := path.Clean(strings.TrimPrefix(strings.TrimSpace(rawName), "/"))
		if name == "" || name == "." || strings.HasPrefix(name, "..") || strings.Contains(name, "/../") {
			return nil, apperr.Invalid("files", "invalid relative path %q", rawName)
		}
		ext := strings.ToLower(path.Ext(name))
		if !slices.Contains(allowedExts, ext) {
			return nil, apperr.Invalid("files", "unsupported file extension on %q", name)
		}
		if _, dup := out[name]; dup {
			return nil, apperr.Invalid("files", "duplicate file %q", name)
		}
		total += len(content)
		if total > MaxTotalFileBytes {
			return nil, apperr.Invalid("files", "total source size exceeds %d MB", MaxTotalFileBytes>>20)
		}
		out[name] = content
	}
	return out, nil
}

// FileEdit replaces Find with Replace in one existing source file. Find must
// match exactly once unless ReplaceAll is set, so an edit can't silently land
// in the wrong place.
type FileEdit struct {
	Path       string `json:"path" jsonschema:"Existing source file to edit, e.g. app.tsx"`
	Find       string `json:"find" jsonschema:"Exact text to find; must match once unless replace_all is true"`
	Replace    string `json:"replace" jsonschema:"Text to put in its place"`
	ReplaceAll bool   `json:"replace_all,omitempty" jsonschema:"Replace every match instead of requiring exactly one"`
}

// ApplyEdits returns a copy of files with edits applied in order; each edit
// sees the result of the ones before it. The input map is not modified.
func ApplyEdits(files map[string]string, edits []FileEdit) (map[string]string, error) {
	if len(edits) > MaxEditsPerUpdate {
		return nil, apperr.Invalid("edits", "at most %d edits per update", MaxEditsPerUpdate)
	}
	out := make(map[string]string, len(files))
	for k, v := range files {
		out[k] = v
	}
	for i, e := range edits {
		name := path.Clean(strings.TrimPrefix(strings.TrimSpace(e.Path), "/"))
		content, ok := out[name]
		if !ok {
			return nil, apperr.Invalid("edits", "edit %d: %q is not a file in this app", i+1, e.Path)
		}
		if e.Find == "" {
			return nil, apperr.Invalid("edits", "edit %d: find text is required", i+1)
		}
		switch n := strings.Count(content, e.Find); {
		case n == 0:
			return nil, apperr.Invalid("edits", "edit %d: find text not found in %s", i+1, name)
		case n > 1 && !e.ReplaceAll:
			return nil, apperr.Invalid("edits", "edit %d: find text matches %d times in %s; include more surrounding text or set replace_all", i+1, n, name)
		}
		out[name] = strings.ReplaceAll(content, e.Find, e.Replace)
	}
	return out, nil
}

func NormalizeManifest(m Manifest, files map[string]string) (Manifest, error) {
	m.Entry = strings.TrimSpace(m.Entry)
	if m.Entry == "" {
		m.Entry = "app.tsx"
	}
	m.Entry = path.Clean(strings.TrimPrefix(m.Entry, "/"))
	if _, ok := files[m.Entry]; !ok {
		return Manifest{}, apperr.Invalid("manifest", "entry file %q not found in files", m.Entry)
	}
	m.MCPEntry = strings.TrimSpace(m.MCPEntry)
	if m.MCPEntry != "" {
		m.MCPEntry = path.Clean(strings.TrimPrefix(m.MCPEntry, "/"))
		if _, ok := files[m.MCPEntry]; !ok {
			return Manifest{}, apperr.Invalid("manifest", "mcp_entry file %q not found in files", m.MCPEntry)
		}
	} else if _, ok := files["server.ts"]; ok {
		m.MCPEntry = "server.ts"
	} else if _, ok := files["server.js"]; ok {
		m.MCPEntry = "server.js"
	}
	m.ToolScope = strings.TrimSpace(m.ToolScope)
	if m.ToolScope == "" {
		m.ToolScope = ToolScopeChats
	}
	if m.ToolScope != ToolScopeChats && m.ToolScope != ToolScopeAppOnly {
		return Manifest{}, apperr.Invalid("manifest", "tool_scope must be chats or app_only")
	}
	m.Instructions = strings.TrimSpace(m.Instructions)
	if utf8.RuneCountInString(m.Instructions) > MaxInstructions {
		return Manifest{}, apperr.Invalid("manifest", "instructions exceed %d characters", MaxInstructions)
	}
	if len(m.Nav) > MaxNavItems {
		return Manifest{}, apperr.Invalid("manifest", "at most %d nav items allowed", MaxNavItems)
	}
	seenNav := make(map[string]struct{}, len(m.Nav))
	for i := range m.Nav {
		m.Nav[i].ID = strings.TrimSpace(m.Nav[i].ID)
		m.Nav[i].Label = strings.TrimSpace(m.Nav[i].Label)
		m.Nav[i].Icon = strings.TrimSpace(m.Nav[i].Icon)
		if m.Nav[i].ID == "" || len(m.Nav[i].ID) > 48 {
			return Manifest{}, apperr.Invalid("manifest", "nav[%d].id must be 1–48 chars", i)
		}
		if m.Nav[i].Label == "" || len(m.Nav[i].Label) > 48 {
			return Manifest{}, apperr.Invalid("manifest", "nav[%d].label must be 1–48 chars", i)
		}
		if m.Nav[i].Icon != "" && !iconRE.MatchString(m.Nav[i].Icon) {
			return Manifest{}, apperr.Invalid("manifest", "nav[%d].icon invalid", i)
		}
		if _, dup := seenNav[m.Nav[i].ID]; dup {
			return Manifest{}, apperr.Invalid("manifest", "duplicate nav id %q", m.Nav[i].ID)
		}
		seenNav[m.Nav[i].ID] = struct{}{}
	}
	if m.RequestedCapabilities != nil {
		for k, v := range m.RequestedCapabilities {
			if err := ValidCapabilityKey(k); err != nil {
				return Manifest{}, err
			}
			if err := ValidMode(v); err != nil {
				return Manifest{}, err
			}
		}
	}
	if len(m.RequestedMounts) > MaxMounts {
		return Manifest{}, apperr.Invalid("manifest", "at most %d requested mounts allowed", MaxMounts)
	}
	seenMounts := make(map[string]struct{}, len(m.RequestedMounts))
	for i := range m.RequestedMounts {
		name, err := ValidMountName(m.RequestedMounts[i].Name)
		if err != nil {
			return Manifest{}, apperr.Invalid("manifest", "requested_mounts[%d].name invalid", i)
		}
		if _, dup := seenMounts[name]; dup {
			return Manifest{}, apperr.Invalid("manifest", "duplicate requested mount %q", name)
		}
		seenMounts[name] = struct{}{}
		m.RequestedMounts[i].Name = name
		m.RequestedMounts[i].Description = strings.TrimSpace(m.RequestedMounts[i].Description)
		if utf8.RuneCountInString(m.RequestedMounts[i].Description) > MaxMountDescriptionRunes {
			return Manifest{}, apperr.Invalid("manifest", "requested_mounts[%d].description exceeds %d characters", i, MaxMountDescriptionRunes)
		}
	}
	return m, nil
}

func decodeMounts(raw json.RawMessage) Mounts {
	out := Mounts{}
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &out)
	}
	return out
}

func decodeManifest(raw json.RawMessage) Manifest {
	var m Manifest
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &m)
	}
	if m.Entry == "" {
		m.Entry = "app.tsx"
	}
	if m.ToolScope == "" {
		m.ToolScope = ToolScopeChats
	}
	return m
}

func decodeCapabilities(raw json.RawMessage) Capabilities {
	caps := Capabilities{
		"app.sql:read":  agentdef.Allowed,
		"app.sql:write": agentdef.Allowed,
	}
	if len(raw) > 0 {
		var parsed Capabilities
		if json.Unmarshal(raw, &parsed) == nil {
			for k, v := range parsed {
				caps[k] = v
			}
		}
	}
	return caps
}
