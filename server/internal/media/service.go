package media

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"maps"
	"slices"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const checkTimeout = 15 * time.Second

// Service manages encrypted media provider configs, workspace capability
// defaults, and provider resolution.
type Service struct {
	Pool     *pgxpool.Pool
	Box      *secrets.Box
	Registry *Registry
}

// ProviderView is the non-secret view of a provider returned to Settings.
type ProviderView struct {
	Descriptor        Descriptor
	Enabled           bool
	Settings          map[string]string
	SecretsSet        map[string]bool
	Available         bool
	UnavailableReason string
}

// ProvidersSnapshot summarizes every registered provider and active defaults.
type ProvidersSnapshot struct {
	Providers []ProviderView
	Defaults  map[Capability]string
}

// CheckResult reports whether a provider's Check(ctx) succeeded.
type CheckResult struct {
	OK        bool
	Message   string
	ErrorKind ErrorKind
}

func secretScope(providerID string) string {
	return "media-provider:" + providerID
}

// ListProviders returns all registered providers with masked secret presence,
// effective non-secret settings, availability, and workspace defaults.
func (s *Service) ListProviders(ctx context.Context, ws uuid.UUID) (ProvidersSnapshot, error) {
	out := ProvidersSnapshot{Defaults: map[Capability]string{}}
	if s.Registry == nil {
		return out, nil
	}
	q := store.New(s.Pool)
	rows, err := q.ListMediaProviderConfigs(ctx, ws)
	if err != nil {
		return out, err
	}
	byID := make(map[string]store.MediaProviderConfig, len(rows))
	for _, r := range rows {
		byID[r.ProviderID] = r
	}
	defs, err := q.ListWorkspaceMediaDefaults(ctx, ws)
	if err != nil {
		return out, err
	}
	for _, d := range defs {
		out.Defaults[Capability(d.Capability)] = d.ProviderID
	}

	entries := s.Registry.Entries()
	out.Providers = make([]ProviderView, 0, len(entries))
	for _, e := range entries {
		row, hasRow := byID[e.Descriptor.ID]
		view, _, err := s.buildView(ws, e, row, hasRow, false)
		if err != nil {
			return out, err
		}
		out.Providers = append(out.Providers, view)
	}
	return out, nil
}

// SaveProvider validates and saves settings and encrypted secret updates for
// providerID. Untouched secret fields are preserved.
func (s *Service) SaveProvider(ctx context.Context, ws uuid.UUID, providerID string, enabled *bool, settings map[string]string, secretUpdates map[string]string) (ProviderView, error) {
	if s.Registry == nil {
		return ProviderView{}, apperr.Invalid("provider_id", "unknown media provider %q", providerID)
	}
	entry, ok := s.Registry.Lookup(providerID)
	if !ok {
		return ProviderView{}, apperr.Invalid("provider_id", "unknown media provider %q", providerID)
	}
	if entry.Descriptor.ComingSoon {
		return ProviderView{}, apperr.Invalid("provider_id", "%s is not installed yet", entry.Descriptor.Label)
	}

	fieldByKey := make(map[string]FieldSpec, len(entry.Descriptor.Fields))
	for _, f := range entry.Descriptor.Fields {
		fieldByKey[f.Key] = f
	}

	q := store.New(s.Pool)
	existingRow, err := q.GetMediaProviderConfig(ctx, store.GetMediaProviderConfigParams{WorkspaceID: ws, ProviderID: providerID})
	hasExisting := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return ProviderView{}, err
	}

	// Start from existing non-secret settings + defaults, then apply updates.
	mergedSettings := defaultSettings(entry.Descriptor)
	if hasExisting {
		var saved map[string]string
		if len(existingRow.SettingsJson) > 0 && json.Unmarshal(existingRow.SettingsJson, &saved) == nil {
			for k, v := range saved {
				if f, ok := fieldByKey[k]; ok && f.Kind != "secret" {
					mergedSettings[k] = v
				}
			}
		}
	}
	for k, v := range settings {
		f, exists := fieldByKey[k]
		if !exists {
			return ProviderView{}, apperr.Invalid("settings", "unknown field %q for %s", k, providerID)
		}
		if f.Kind == "secret" {
			return ProviderView{}, apperr.Invalid("settings", "field %q is a secret and must be passed in secrets", k)
		}
		val := strings.TrimSpace(v)
		if (f.Kind == "select" || f.Kind == "segmented") && val != "" && !validOption(f.Options, val) {
			return ProviderView{}, apperr.Invalid("settings", "invalid option %q for %s", val, k)
		}
		if val == "" {
			if f.Default != "" {
				mergedSettings[k] = f.Default
			} else {
				delete(mergedSettings, k)
			}
		} else {
			mergedSettings[k] = val
		}
	}

	// Decrypt existing secrets if needed, or require Box when saving new secrets.
	mergedSecrets := map[string]string{}
	needDecrypt := hasExisting && len(existingRow.SecretCiphertext) > 0
	hasNewSecret := false
	for k, v := range secretUpdates {
		f, exists := fieldByKey[k]
		if !exists {
			return ProviderView{}, apperr.Invalid("secrets", "unknown field %q for %s", k, providerID)
		}
		if f.Kind != "secret" {
			return ProviderView{}, apperr.Invalid("secrets", "field %q is not a secret field", k)
		}
		if strings.TrimSpace(v) != "" {
			hasNewSecret = true
		}
	}
	if (needDecrypt || hasNewSecret) && s.Box == nil {
		return ProviderView{}, secrets.ErrNoKey
	}
	if needDecrypt {
		opened, err := s.openSecrets(ws, providerID, existingRow.SecretNonce, existingRow.SecretCiphertext)
		if err != nil {
			return ProviderView{}, err
		}
		maps.Copy(mergedSecrets, opened)
	}
	for k, v := range secretUpdates {
		val := strings.TrimSpace(v)
		if val != "" {
			mergedSecrets[k] = val
		}
	}

	isEnabled := true
	if hasExisting {
		isEnabled = existingRow.Enabled
	}
	if enabled != nil {
		isEnabled = *enabled
	}

	settingsRaw, err := json.Marshal(mergedSettings)
	if err != nil {
		return ProviderView{}, err
	}
	var nonce, ciphertext []byte
	if len(mergedSecrets) > 0 {
		nonce, ciphertext, err = s.sealSecrets(ws, providerID, mergedSecrets)
		if err != nil {
			return ProviderView{}, err
		}
	}

	savedRow, err := q.UpsertMediaProviderConfig(ctx, store.UpsertMediaProviderConfigParams{
		WorkspaceID:      ws,
		ProviderID:       providerID,
		Enabled:          isEnabled,
		SettingsJson:     settingsRaw,
		SecretNonce:      nonce,
		SecretCiphertext: ciphertext,
	})
	if err != nil {
		return ProviderView{}, err
	}

	view, _, err := s.buildView(ws, entry, savedRow, true, false)
	if err != nil {
		return ProviderView{}, err
	}

	// Auto-select as default for any capability it provides when none is set yet.
	if view.Enabled && view.Available {
		for _, cap := range entry.Descriptor.Capabilities {
			_, err := q.GetWorkspaceMediaDefault(ctx, store.GetWorkspaceMediaDefaultParams{WorkspaceID: ws, Capability: string(cap)})
			if errors.Is(err, pgx.ErrNoRows) {
				_, _ = q.UpsertWorkspaceMediaDefault(ctx, store.UpsertWorkspaceMediaDefaultParams{
					WorkspaceID: ws,
					Capability:  string(cap),
					ProviderID:  providerID,
				})
			}
		}
	}
	return view, nil
}

// ClearProviderSecret clears either one secret field or all stored secrets for
// providerID.
func (s *Service) ClearProviderSecret(ctx context.Context, ws uuid.UUID, providerID, fieldKey string) error {
	if s.Registry == nil {
		return apperr.Invalid("provider_id", "unknown media provider %q", providerID)
	}
	entry, ok := s.Registry.Lookup(providerID)
	if !ok {
		return apperr.Invalid("provider_id", "unknown media provider %q", providerID)
	}
	fieldKey = strings.TrimSpace(fieldKey)
	if fieldKey != "" {
		found := false
		for _, f := range entry.Descriptor.Fields {
			if f.Key == fieldKey && f.Kind == "secret" {
				found = true
				break
			}
		}
		if !found {
			return apperr.Invalid("field", "unknown secret field %q for %s", fieldKey, providerID)
		}
	}

	q := store.New(s.Pool)
	if fieldKey == "" {
		return q.ClearMediaProviderSecret(ctx, store.ClearMediaProviderSecretParams{WorkspaceID: ws, ProviderID: providerID})
	}
	row, err := q.GetMediaProviderConfig(ctx, store.GetMediaProviderConfigParams{WorkspaceID: ws, ProviderID: providerID})
	if errors.Is(err, pgx.ErrNoRows) || len(row.SecretCiphertext) == 0 {
		return nil
	}
	if err != nil {
		return err
	}
	if s.Box == nil {
		return secrets.ErrNoKey
	}
	secs, err := s.openSecrets(ws, providerID, row.SecretNonce, row.SecretCiphertext)
	if err != nil {
		return err
	}
	delete(secs, fieldKey)
	if len(secs) == 0 {
		return q.ClearMediaProviderSecret(ctx, store.ClearMediaProviderSecretParams{WorkspaceID: ws, ProviderID: providerID})
	}
	nonce, ct, err := s.sealSecrets(ws, providerID, secs)
	if err != nil {
		return err
	}
	_, err = q.UpsertMediaProviderConfig(ctx, store.UpsertMediaProviderConfigParams{
		WorkspaceID:      ws,
		ProviderID:       providerID,
		Enabled:          row.Enabled,
		SettingsJson:     row.SettingsJson,
		SecretNonce:      nonce,
		SecretCiphertext: ct,
	})
	return err
}

// CheckProvider validates credentials and connectivity for providerID.
func (s *Service) CheckProvider(ctx context.Context, ws uuid.UUID, providerID string) (CheckResult, error) {
	if s.Registry == nil {
		return CheckResult{}, apperr.Invalid("provider_id", "unknown media provider %q", providerID)
	}
	entry, ok := s.Registry.Lookup(providerID)
	if !ok {
		return CheckResult{}, apperr.Invalid("provider_id", "unknown media provider %q", providerID)
	}
	if entry.Descriptor.ComingSoon {
		return CheckResult{OK: false, ErrorKind: ErrKindUnavailable, Message: entry.Descriptor.Label + " is not installed yet."}, nil
	}

	q := store.New(s.Pool)
	row, err := q.GetMediaProviderConfig(ctx, store.GetMediaProviderConfigParams{WorkspaceID: ws, ProviderID: providerID})
	hasRow := err == nil
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return CheckResult{}, err
	}
	view, cfg, err := s.buildView(ws, entry, row, hasRow, true)
	if err != nil {
		return CheckResult{}, err
	}
	if !view.Available {
		msg := view.UnavailableReason
		if msg == "" {
			msg = entry.Descriptor.Label + " is not configured."
		}
		return CheckResult{OK: false, ErrorKind: ErrKindUnavailable, Message: msg}, nil
	}
	if entry.New == nil {
		return CheckResult{OK: false, ErrorKind: ErrKindUnavailable, Message: entry.Descriptor.Label + " is unavailable."}, nil
	}
	prov, err := entry.New(cfg)
	if err != nil {
		kind, msg := ClassifyError(err)
		return CheckResult{OK: false, ErrorKind: kind, Message: msg}, nil
	}
	tctx, cancel := context.WithTimeout(ctx, checkTimeout)
	defer cancel()
	if err := prov.Check(tctx); err != nil {
		kind, msg := ClassifyError(err)
		return CheckResult{OK: false, ErrorKind: kind, Message: msg}, nil
	}
	return CheckResult{OK: true, Message: entry.Descriptor.Label + " reachable."}, nil
}

// SetDefault persists the workspace's active provider for capability (or clears
// it when providerID is empty).
func (s *Service) SetDefault(ctx context.Context, ws uuid.UUID, capability Capability, providerID string) error {
	if !ValidCapability(capability) {
		return apperr.Invalid("capability", "unsupported capability %q", capability)
	}
	providerID = strings.TrimSpace(providerID)
	q := store.New(s.Pool)
	if providerID == "" {
		return q.DeleteWorkspaceMediaDefault(ctx, store.DeleteWorkspaceMediaDefaultParams{WorkspaceID: ws, Capability: string(capability)})
	}
	if s.Registry == nil {
		return apperr.Invalid("provider_id", "unknown media provider %q", providerID)
	}
	entry, ok := s.Registry.Lookup(providerID)
	if !ok {
		return apperr.Invalid("provider_id", "unknown media provider %q", providerID)
	}
	if entry.Descriptor.ComingSoon {
		return apperr.Invalid("provider_id", "%s is not installed yet", entry.Descriptor.Label)
	}
	if !entry.Descriptor.Supports(capability) {
		return apperr.Invalid("provider_id", "%s does not support %s", entry.Descriptor.Label, capability)
	}
	_, err := q.UpsertWorkspaceMediaDefault(ctx, store.UpsertWorkspaceMediaDefaultParams{
		WorkspaceID: ws,
		Capability:  string(capability),
		ProviderID:  providerID,
	})
	return err
}

// ResolveMusic picks and constructs the active MusicGenerator for ws (explicit
// override first, then workspace default, then first enabled available provider).
func (s *Service) ResolveMusic(ctx context.Context, ws uuid.UUID, providerIDOverride string) (MusicGenerator, Descriptor, error) {
	if s.Registry == nil {
		return nil, Descriptor{}, &ProviderError{
			Kind:    ErrKindUnavailable,
			Message: "No Music provider is configured. Add a Gemini API key in Settings → Workspace → Media providers.",
		}
	}
	q := store.New(s.Pool)
	rows, err := q.ListMediaProviderConfigs(ctx, ws)
	if err != nil {
		return nil, Descriptor{}, err
	}
	byID := make(map[string]store.MediaProviderConfig, len(rows))
	for _, r := range rows {
		byID[r.ProviderID] = r
	}

	var candidates []string
	if override := strings.TrimSpace(providerIDOverride); override != "" {
		entry, ok := s.Registry.Lookup(override)
		if !ok {
			return nil, Descriptor{}, apperr.Invalid("provider_id", "unknown media provider %q", override)
		}
		if entry.Descriptor.ComingSoon || !entry.Descriptor.Supports(CapMusic) {
			return nil, Descriptor{}, apperr.Invalid("provider_id", "%s does not support music generation", entry.Descriptor.Label)
		}
		candidates = []string{override}
	} else {
		def, err := q.GetWorkspaceMediaDefault(ctx, store.GetWorkspaceMediaDefaultParams{WorkspaceID: ws, Capability: string(CapMusic)})
		if err == nil && def.ProviderID != "" {
			candidates = append(candidates, def.ProviderID)
		} else if err != nil && !errors.Is(err, pgx.ErrNoRows) {
			return nil, Descriptor{}, err
		}
		for _, e := range s.Registry.Entries() {
			if e.Descriptor.ComingSoon || !e.Descriptor.Supports(CapMusic) {
				continue
			}
			if !slices.Contains(candidates, e.Descriptor.ID) {
				candidates = append(candidates, e.Descriptor.ID)
			}
		}
	}

	var lastUnavailableReason string
	for _, id := range candidates {
		entry, ok := s.Registry.Lookup(id)
		if !ok || entry.Descriptor.ComingSoon || !entry.Descriptor.Supports(CapMusic) || entry.New == nil {
			continue
		}
		row, hasRow := byID[id]
		view, cfg, err := s.buildView(ws, entry, row, hasRow, true)
		if err != nil {
			return nil, Descriptor{}, err
		}
		if !view.Enabled {
			lastUnavailableReason = entry.Descriptor.Label + " is disabled in Settings → Workspace → Media providers."
			continue
		}
		if !view.Available {
			lastUnavailableReason = view.UnavailableReason
			continue
		}
		prov, err := entry.New(cfg)
		if err != nil {
			return nil, Descriptor{}, err
		}
		gen, ok := prov.(MusicGenerator)
		if !ok {
			continue
		}
		return gen, entry.Descriptor, nil
	}

	msg := "No Music provider is configured. Add a Gemini API key in Settings → Workspace → Media providers."
	if providerIDOverride != "" && lastUnavailableReason != "" {
		msg = lastUnavailableReason
	}
	return nil, Descriptor{}, &ProviderError{
		Kind:    ErrKindUnavailable,
		Message: msg,
	}
}

func (s *Service) buildView(ws uuid.UUID, entry Entry, row store.MediaProviderConfig, hasRow bool, decrypt bool) (ProviderView, ResolvedConfig, error) {
	settings := defaultSettings(entry.Descriptor)
	secretKeys := map[string]bool{}
	secretMap := map[string]string{}

	if hasRow {
		if len(row.SettingsJson) > 0 {
			var saved map[string]string
			if json.Unmarshal(row.SettingsJson, &saved) == nil {
				for k, v := range saved {
					if v != "" {
						settings[k] = v
					}
				}
			}
		}
		if len(row.SecretCiphertext) > 0 {
			if s.Box != nil {
				opened, err := s.openSecrets(ws, entry.Descriptor.ID, row.SecretNonce, row.SecretCiphertext)
				if err != nil {
					return ProviderView{}, ResolvedConfig{}, err
				}
				for k, v := range opened {
					if v != "" {
						secretKeys[k] = true
						if decrypt {
							secretMap[k] = v
						}
					}
				}
			} else if decrypt {
				return ProviderView{}, ResolvedConfig{}, secrets.ErrNoKey
			} else {
				// Without SECRETS_KEY we still report whether ciphertext exists on the
				// required secret field without decrypting.
				for _, f := range entry.Descriptor.Fields {
					if f.Kind == "secret" {
						secretKeys[f.Key] = true
					}
				}
			}
		}
	}

	// CheckAvailability uses non-secret settings plus presence markers when
	// decrypt is false, or real secret values when decrypt is true.
	availCfg := ResolvedConfig{
		Settings: settings,
		Secrets:  map[string]string{},
	}
	if decrypt {
		availCfg.Secrets = secretMap
	} else {
		for k, set := range secretKeys {
			if set {
				availCfg.Secrets[k] = "set"
			}
		}
	}

	available := !entry.Descriptor.ComingSoon
	reason := ""
	if entry.CheckAvailability != nil {
		available, reason = entry.CheckAvailability(availCfg)
	}
	if s.Box == nil && hasRow && len(row.SecretCiphertext) > 0 && !entry.Descriptor.ComingSoon {
		available = false
		reason = "SECRETS_KEY is not configured on the API server."
	}

	enabled := true
	if hasRow {
		enabled = row.Enabled
	}
	if entry.Descriptor.ComingSoon {
		enabled = false
	}

	return ProviderView{
		Descriptor:        entry.Descriptor,
		Enabled:           enabled,
		Settings:          settings,
		SecretsSet:        secretKeys,
		Available:         available,
		UnavailableReason: reason,
	}, ResolvedConfig{Settings: settings, Secrets: secretMap}, nil
}

func (s *Service) sealSecrets(ws uuid.UUID, providerID string, values map[string]string) ([]byte, []byte, error) {
	if s.Box == nil {
		return nil, nil, secrets.ErrNoKey
	}
	raw, err := json.Marshal(values)
	if err != nil {
		return nil, nil, err
	}
	return s.Box.Seal(ws, secretScope(providerID), raw)
}

func (s *Service) openSecrets(ws uuid.UUID, providerID string, nonce, ct []byte) (map[string]string, error) {
	if s.Box == nil {
		return nil, secrets.ErrNoKey
	}
	raw, err := s.Box.Open(ws, secretScope(providerID), nonce, ct)
	if err != nil {
		return nil, err
	}
	var out map[string]string
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("media: corrupted secret payload for %s: %w", providerID, err)
	}
	if out == nil {
		out = map[string]string{}
	}
	return out, nil
}

func defaultSettings(desc Descriptor) map[string]string {
	out := map[string]string{}
	for _, f := range desc.Fields {
		if f.Kind != "secret" && f.Default != "" {
			out[f.Key] = f.Default
		}
	}
	return out
}

func validOption(opts []FieldOption, val string) bool {
	for _, o := range opts {
		if o.Value == val {
			return true
		}
	}
	return false
}
