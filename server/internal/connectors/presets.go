package connectors

import (
	"slices"
	"strings"
	"unicode"
)

// Preset describes a suggested MCP connector with known defaults and setup guidance.
type Preset struct {
	ID                  string
	Name                string
	URL                 string
	AuthKind            string
	Description         string
	SetupHint           string
	OAuthClientRequired bool
	DefaultScopes       []string
}

var builtInPresets = []Preset{
	{
		ID:                  "google-drive",
		Name:                "Google Drive",
		URL:                 "https://drivemcp.googleapis.com/mcp/v1",
		AuthKind:            AuthOAuth,
		Description:         "Search, read and create files in Google Drive.",
		SetupHint:           "Enable the Google Drive API and Drive MCP API in Google Cloud, then create an OAuth 2.0 Web Client with this callback URL and \"Use this client for an AI-powered agent\" enabled.",
		OAuthClientRequired: true,
		DefaultScopes: []string{
			"https://www.googleapis.com/auth/drive.readonly",
			"https://www.googleapis.com/auth/drive.file",
		},
	},
	{
		ID:                  "github",
		Name:                "GitHub",
		URL:                 "https://api.githubcopilot.com/mcp/",
		AuthKind:            AuthToken,
		Description:         "Repositories, pull requests, issues and code search.",
		SetupHint:           "Create a fine-grained personal access token in GitHub Developer settings.",
		OAuthClientRequired: false,
		DefaultScopes:       []string{},
	},
	{
		ID:                  "notion",
		Name:                "Notion",
		URL:                 "https://mcp.notion.com/mcp",
		AuthKind:            AuthOAuth,
		Description:         "Search and update Notion pages and databases.",
		SetupHint:           "",
		OAuthClientRequired: false,
		DefaultScopes:       []string{},
	},
}

// Presets returns the built-in suggested MCP connectors in display order.
func Presets() []Preset {
	out := make([]Preset, len(builtInPresets))
	for i, p := range builtInPresets {
		p.DefaultScopes = slices.Clone(p.DefaultScopes)
		if p.DefaultScopes == nil {
			p.DefaultScopes = []string{}
		}
		out[i] = p
	}
	return out
}

func normalizePresetURL(raw string) string {
	return strings.TrimRight(strings.ToLower(strings.TrimSpace(raw)), "/")
}

// PresetForURL returns the preset whose server URL matches rawURL, if any.
func PresetForURL(rawURL string) (Preset, bool) {
	want := normalizePresetURL(rawURL)
	if want == "" {
		return Preset{}, false
	}
	for _, p := range builtInPresets {
		if normalizePresetURL(p.URL) == want {
			p.DefaultScopes = slices.Clone(p.DefaultScopes)
			if p.DefaultScopes == nil {
				p.DefaultScopes = []string{}
			}
			return p, true
		}
	}
	return Preset{}, false
}

// NormalizeScopes splits whitespace- or comma-separated scopes and deduplicates them in order.
func NormalizeScopes(in []string) []string {
	out := []string{}
	seen := make(map[string]struct{}, len(in))
	for _, item := range in {
		for _, part := range strings.FieldsFunc(item, func(r rune) bool {
			return r == ',' || unicode.IsSpace(r)
		}) {
			if part == "" {
				continue
			}
			if _, ok := seen[part]; ok {
				continue
			}
			seen[part] = struct{}{}
			out = append(out, part)
		}
	}
	return out
}
