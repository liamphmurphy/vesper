package media

import "slices"

// FieldOption is one selectable choice for a select or segmented field.
type FieldOption struct {
	Value string `json:"value"`
	Label string `json:"label"`
}

// FieldSpec describes one configuration input so Settings can render providers
// dynamically without hardcoding vendor forms.
type FieldSpec struct {
	Key         string            `json:"key"`
	Label       string            `json:"label"`
	Kind        string            `json:"kind"` // "text" | "secret" | "select" | "segmented"
	Required    bool              `json:"required,omitempty"`
	Default     string            `json:"default,omitempty"`
	Placeholder string            `json:"placeholder,omitempty"`
	Help        string            `json:"help,omitempty"`
	Options     []FieldOption     `json:"options,omitempty"`
	ShowWhen    map[string]string `json:"show_when,omitempty"`
}

// Descriptor advertises a registered media provider's identity, capabilities,
// and configuration schema.
type Descriptor struct {
	ID           string       `json:"id"`
	Label        string       `json:"label"`
	Description  string       `json:"description,omitempty"`
	Capabilities []Capability `json:"capabilities"`
	ComingSoon   bool         `json:"coming_soon,omitempty"`
	Fields       []FieldSpec  `json:"fields,omitempty"`
}

// Supports reports whether the provider advertises cap.
func (d Descriptor) Supports(cap Capability) bool {
	return slices.Contains(d.Capabilities, cap)
}

// ResolvedConfig carries decrypted configuration into a provider factory.
type ResolvedConfig struct {
	Settings map[string]string
	Secrets  map[string]string
}

// Setting returns the configured value for key, or the field's default.
func (c ResolvedConfig) Setting(desc Descriptor, key string) string {
	if v := c.Settings[key]; v != "" {
		return v
	}
	for _, f := range desc.Fields {
		if f.Key == key {
			return f.Default
		}
	}
	return ""
}
