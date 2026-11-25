package companion

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func TestLoadOrCreateCertPersistsAndKeepsFingerprint(t *testing.T) {
	dir := t.TempDir()
	first, err := LoadOrCreateCert(dir, "liam-mbp")
	if err != nil {
		t.Fatalf("LoadOrCreateCert first: %v", err)
	}
	if len(first.FingerprintSHA256) != 64 {
		t.Fatalf("expected 64-char hex sha256 fingerprint, got %q", first.FingerprintSHA256)
	}

	second, err := LoadOrCreateCert(dir, "liam-mbp")
	if err != nil {
		t.Fatalf("LoadOrCreateCert second: %v", err)
	}
	if second.FingerprintSHA256 != first.FingerprintSHA256 {
		t.Fatalf("fingerprint changed across reloads: %q != %q", second.FingerprintSHA256, first.FingerprintSHA256)
	}
}

func TestEncodePairingURI(t *testing.T) {
	want := PairingPayload{
		Version:        1,
		Name:           "MacBook Pro",
		Port:           8443,
		CertSHA256:     "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		Code:           "vcp_testcode",
		LANHosts:       []string{"192.168.1.42"},
		TailscaleHosts: []string{"macbook.tailnet.ts.net", "100.64.0.10"},
		BonjourService: BonjourServiceType,
	}
	uri, err := EncodePairingURI(want)
	if err != nil {
		t.Fatalf("EncodePairingURI: %v", err)
	}
	parsed, err := url.Parse(uri)
	if err != nil {
		t.Fatalf("parse uri: %v", err)
	}
	if parsed.Scheme != "vesper-pair" || parsed.Host != "v1" {
		t.Fatalf("unexpected uri scheme/host: %s", uri)
	}
	raw, err := base64.RawURLEncoding.DecodeString(parsed.Query().Get("data"))
	if err != nil {
		t.Fatalf("decode data: %v", err)
	}
	var got PairingPayload
	if err := json.Unmarshal(raw, &got); err != nil {
		t.Fatalf("unmarshal payload: %v", err)
	}
	if got.Port != want.Port || got.Code != want.Code || got.CertSHA256 != want.CertSHA256 {
		t.Fatalf("roundtrip mismatch: got %+v want %+v", got, want)
	}
}

func TestPairingLifecycleAndRevocation(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	q := store.New(pool)
	if _, err := seed.Run(ctx, pool, seed.Options{UserName: "Liam", UserEmail: "liam@localhost"}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	u, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatalf("GetLocalUser: %v", err)
	}

	code, _, err := NewPairingCode(ctx, q)
	if err != nil {
		t.Fatalf("NewPairingCode: %v", err)
	}

	dev, token, err := RedeemPairingCode(ctx, q, u.ID, code, "Liam's iPhone", "ios")
	if err != nil {
		t.Fatalf("RedeemPairingCode: %v", err)
	}
	if dev.Name != "Liam's iPhone" {
		t.Fatalf("device name = %q", dev.Name)
	}

	// Reusing the same code must fail.
	if _, _, err := RedeemPairingCode(ctx, q, u.ID, code, "Replay", "ios"); !errors.Is(err, ErrBadPairingCode) {
		t.Fatalf("expected ErrBadPairingCode on replay, got %v", err)
	}

	ok, err := ValidDeviceToken(ctx, q, token)
	if err != nil || !ok {
		t.Fatalf("expected valid device token, ok=%v err=%v", ok, err)
	}

	if _, err := q.RevokeCompanionDevice(ctx, store.RevokeCompanionDeviceParams{ID: dev.ID, UserID: u.ID}); err != nil {
		t.Fatalf("RevokeCompanionDevice: %v", err)
	}

	ok, err = ValidDeviceToken(ctx, q, token)
	if err != nil || ok {
		t.Fatalf("expected revoked token to be invalid, ok=%v err=%v", ok, err)
	}
}
