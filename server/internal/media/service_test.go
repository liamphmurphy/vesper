package media_test

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/fake"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/gemini"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func testBox(t *testing.T) *secrets.Box {
	t.Helper()
	k := make([]byte, 32)
	if _, err := rand.Read(k); err != nil {
		t.Fatal(err)
	}
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	if err != nil {
		t.Fatal(err)
	}
	return box
}

func newTestService(t *testing.T, withBox bool) (*media.Service, *fake.Controller, store.User) {
	t.Helper()
	pool := testdb.New(t)
	ctx := context.Background()
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true}); err != nil {
		t.Fatal(err)
	}
	me, err := store.New(pool).GetLocalUser(ctx)
	if err != nil {
		t.Fatal(err)
	}
	reg := media.NewRegistry()
	ctrl := &fake.Controller{}
	fake.Register(reg, ctrl)
	media.RegisterLocalMLXPlaceholder(reg)

	var box *secrets.Box
	if withBox {
		box = testBox(t)
	}
	return &media.Service{Pool: pool, Box: box, Registry: reg}, ctrl, me
}

func TestServiceProviderLifecycleAndEncryption(t *testing.T) {
	ctx := context.Background()
	svc, ctrl, me := newTestService(t, true)

	snap, err := svc.ListProviders(ctx, me.WorkspaceID)
	if err != nil {
		t.Fatal(err)
	}
	if len(snap.Providers) != 2 {
		t.Fatalf("got %d providers, want 2", len(snap.Providers))
	}
	if snap.Providers[0].Available {
		t.Fatal("expected unconfigured fake provider to be unavailable")
	}

	// Reject unknown, coming-soon, unknown field, secret-in-settings, and bad option.
	for _, tc := range []struct {
		name string
		id   string
		set  map[string]string
		sec  map[string]string
	}{
		{"unknown provider", "nope", nil, nil},
		{"coming soon", "local-mlx", nil, nil},
		{"unknown field", "fake", map[string]string{"bogus": "1"}, nil},
		{"secret in settings", "fake", map[string]string{"api_key": "x"}, nil},
		{"non-secret in secrets", "fake", nil, map[string]string{"mode": "fast"}},
		{"invalid option", "fake", map[string]string{"mode": "ludicrous"}, nil},
	} {
		if _, err := svc.SaveProvider(ctx, me.WorkspaceID, tc.id, nil, tc.set, tc.sec); err == nil {
			t.Fatalf("%s: expected validation error", tc.name)
		} else {
			var ve *apperr.ValidationError
			if !errors.As(err, &ve) {
				t.Fatalf("%s: got %T (%v), want *apperr.ValidationError", tc.name, err, err)
			}
		}
	}

	const rawKey = "super-secret-fake-key-1234"
	view, err := svc.SaveProvider(ctx, me.WorkspaceID, "fake", nil, map[string]string{"mode": "slow"}, map[string]string{"api_key": rawKey})
	if err != nil {
		t.Fatal(err)
	}
	if !view.Available || !view.SecretsSet["api_key"] || view.Settings["mode"] != "slow" {
		t.Fatalf("unexpected saved view: %+v", view)
	}

	// Ciphertext stored in Postgres must not contain plaintext secret.
	row, err := store.New(svc.Pool).GetMediaProviderConfig(ctx, store.GetMediaProviderConfigParams{WorkspaceID: me.WorkspaceID, ProviderID: "fake"})
	if err != nil {
		t.Fatal(err)
	}
	if len(row.SecretCiphertext) == 0 || bytes.Contains(row.SecretCiphertext, []byte(rawKey)) {
		t.Fatalf("ciphertext missing or leaks plaintext")
	}

	// Auto-default should now point to fake for music.
	snap, err = svc.ListProviders(ctx, me.WorkspaceID)
	if err != nil {
		t.Fatal(err)
	}
	if snap.Defaults[media.CapMusic] != "fake" {
		t.Fatalf("default music provider = %q, want fake", snap.Defaults[media.CapMusic])
	}

	// Updating non-secret settings preserves existing encrypted secret.
	view, err = svc.SaveProvider(ctx, me.WorkspaceID, "fake", nil, map[string]string{"mode": "fast"}, nil)
	if err != nil {
		t.Fatal(err)
	}
	if !view.Available || !view.SecretsSet["api_key"] || view.Settings["mode"] != "fast" {
		t.Fatalf("secret was lost on settings-only update: %+v", view)
	}

	// Check succeeds, then fails with classified error.
	res, err := svc.CheckProvider(ctx, me.WorkspaceID, "fake")
	if err != nil || !res.OK {
		t.Fatalf("check = %+v, err = %v", res, err)
	}
	ctrl.CheckErr = &media.ProviderError{Provider: "fake", Kind: media.ErrKindAuth, Message: "invalid api key"}
	res, err = svc.CheckProvider(ctx, me.WorkspaceID, "fake")
	if err != nil || res.OK || res.ErrorKind != media.ErrKindAuth {
		t.Fatalf("failed check = %+v, err = %v", res, err)
	}

	// ResolveMusic succeeds while enabled & configured.
	gen, desc, err := svc.ResolveMusic(ctx, me.WorkspaceID, "")
	if err != nil || gen.ID() != "fake" || desc.Label != "Fake Music" {
		t.Fatalf("resolve = %v, %+v, err = %v", gen, desc, err)
	}

	// Clear secret -> unavailable -> ResolveMusic returns ErrKindUnavailable.
	if err := svc.ClearProviderSecret(ctx, me.WorkspaceID, "fake", "api_key"); err != nil {
		t.Fatal(err)
	}
	_, _, err = svc.ResolveMusic(ctx, me.WorkspaceID, "")
	var pe *media.ProviderError
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindUnavailable {
		t.Fatalf("resolve after clear = %v, want ErrKindUnavailable", err)
	}

	// SetDefault validation + clear.
	if err := svc.SetDefault(ctx, me.WorkspaceID, media.CapMusic, "local-mlx"); err == nil {
		t.Fatal("expected coming-soon default to be rejected")
	}
	if err := svc.SetDefault(ctx, me.WorkspaceID, media.CapMusic, ""); err != nil {
		t.Fatal(err)
	}
}

func TestServiceRequiresSecretsKeyForSecrets(t *testing.T) {
	ctx := context.Background()
	svc, _, me := newTestService(t, false)
	_, err := svc.SaveProvider(ctx, me.WorkspaceID, "fake", nil, nil, map[string]string{"api_key": "secret-val"})
	if !errors.Is(err, secrets.ErrNoKey) {
		t.Fatalf("got %v, want secrets.ErrNoKey", err)
	}
}

func TestCapVideoRegistryAndServiceResolution(t *testing.T) {
	if !media.ValidCapability(media.CapVideo) {
		t.Fatal("expected CapVideo to be a valid capability")
	}

	ctx := context.Background()
	svc, _, me := newTestService(t, true)
	gemini.Register(svc.Registry)

	videoEntries := svc.Registry.EntriesForCapability(media.CapVideo)
	if len(videoEntries) != 1 || videoEntries[0].Descriptor.ID != gemini.ProviderID {
		t.Fatalf("EntriesForCapability(CapVideo) = %+v, want [gemini]", videoEntries)
	}
	if _, err := svc.Registry.BuildVideo(gemini.ProviderID, media.ResolvedConfig{
		Secrets: map[string]string{"api_key": "AIzaTest"},
	}); err != nil {
		t.Fatalf("BuildVideo(gemini) failed: %v", err)
	}
	if _, err := svc.Registry.BuildVideo("fake", media.ResolvedConfig{}); err == nil {
		t.Fatal("expected BuildVideo(fake) to fail since fake does not implement VideoGenerator")
	}

	// Before configuring Gemini, ResolveVideo returns ErrKindUnavailable.
	_, _, err := svc.ResolveVideo(ctx, me.WorkspaceID, "")
	var pe *media.ProviderError
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindUnavailable {
		t.Fatalf("ResolveVideo unconfigured = %v, want ErrKindUnavailable", err)
	}

	// Explicit override to a music-only provider returns ValidationError.
	_, _, err = svc.ResolveVideo(ctx, me.WorkspaceID, "fake")
	var ve *apperr.ValidationError
	if !errors.As(err, &ve) {
		t.Fatalf("ResolveVideo(fake) = %T (%v), want *apperr.ValidationError", err, err)
	}

	// Save Gemini with legacy Lyria-only settings (no video_model specified);
	// video_model must default cleanly and CapVideo auto-default must be set.
	view, err := svc.SaveProvider(ctx, me.WorkspaceID, gemini.ProviderID, nil,
		map[string]string{"backend": "gemini_api", "model": "auto"},
		map[string]string{"api_key": "AIzaVideoServiceTest"},
	)
	if err != nil {
		t.Fatalf("SaveProvider(gemini) failed: %v", err)
	}
	if view.Settings["model"] != "auto" {
		t.Fatalf("model setting = %q, want auto", view.Settings["model"])
	}
	if view.Settings["video_model"] == "" {
		t.Fatal("expected video_model default to be populated")
	}

	// ResolveVideo resolves the configured Gemini provider even before a
	// workspace_media_defaults row exists for CapVideo.
	gen, desc, err := svc.ResolveVideo(ctx, me.WorkspaceID, "")
	if err != nil {
		t.Fatalf("ResolveVideo failed: %v", err)
	}
	if gen.ID() != gemini.ProviderID || !desc.Supports(media.CapVideo) || !desc.Supports(media.CapMusic) {
		t.Fatalf("unexpected resolved video provider: id=%q caps=%v", gen.ID(), desc.Capabilities)
	}

	// Explicit override to gemini also resolves.
	gen, _, err = svc.ResolveVideo(ctx, me.WorkspaceID, gemini.ProviderID)
	if err != nil || gen.ID() != gemini.ProviderID {
		t.Fatalf("ResolveVideo(gemini) = %v, %v", gen, err)
	}

	// Clearing API key makes ResolveVideo unavailable again.
	if err := svc.ClearProviderSecret(ctx, me.WorkspaceID, gemini.ProviderID, "api_key"); err != nil {
		t.Fatal(err)
	}
	_, _, err = svc.ResolveVideo(ctx, me.WorkspaceID, "")
	if !errors.As(err, &pe) || pe.Kind != media.ErrKindUnavailable {
		t.Fatalf("ResolveVideo after clear = %v, want ErrKindUnavailable", err)
	}
}
