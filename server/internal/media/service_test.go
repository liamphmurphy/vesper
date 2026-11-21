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
