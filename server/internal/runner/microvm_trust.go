package runner

import (
	"bytes"
	"context"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"fmt"
	"io"
	"os"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
)

// A TLS-inspecting proxy (Zscaler, Netskope and the like) re-signs every
// HTTPS connection with the company's own root. The host trusts that root
// through its keychain, but the VM's connections leave through the host with
// the guest's trust store, which is the image's, so they fail verification.
// MicroVM.ExtraCACerts adds those roots to every VM it boots.
const (
	// guestCABundlePath is the Debian system bundle: OpenSSL (curl, git,
	// Python's ssl), Go, Nix and dockerd read it.
	guestCABundlePath = "/etc/ssl/certs/ca-certificates.crt"
	// guestExtraCAPath holds the extra roots alone, for NODE_EXTRA_CA_CERTS,
	// which adds to Node's built-in roots rather than replacing them.
	guestExtraCAPath = "/etc/ssl/certs/vesper-extra-ca.pem"
	// maxExtraCAFileBytes bounds one file a person points us at; a corporate
	// bundle is a few KB.
	maxExtraCAFileBytes = 1 << 20
	// maxExtraCABundleBytes bounds the combined re-encoded PEM across all files.
	maxExtraCABundleBytes = 4 << 20
	// maxGuestCABundleBytes bounds what the host reads back from a guest; the
	// image's bundle is about 200 KB.
	maxGuestCABundleBytes = 8 << 20
)

// LoadExtraCACerts reads PEM or binary DER certificates from one or more files
// for MicroVM.ExtraCACerts. It refuses any file with no certificate, or with
// any non-certificate PEM block (such as a private key exported by mistake),
// deduplicates identical certificates in order, and returns them re-encoded as
// PEM so nothing else in the files reaches a VM.
func LoadExtraCACerts(paths ...string) ([]byte, error) {
	if len(paths) == 0 {
		return nil, nil
	}
	var out bytes.Buffer
	seen := make(map[string]struct{})
	for _, path := range paths {
		ders, err := loadExtraCACertFile(path)
		if err != nil {
			return nil, err
		}
		for _, der := range ders {
			key := string(der)
			if _, dup := seen[key]; dup {
				continue
			}
			seen[key] = struct{}{}
			_ = pem.Encode(&out, &pem.Block{Type: "CERTIFICATE", Bytes: der})
			if out.Len() > maxExtraCABundleBytes {
				return nil, fmt.Errorf("extra CA certificates: combined bundle is larger than %d bytes", maxExtraCABundleBytes)
			}
		}
	}
	return out.Bytes(), nil
}

func loadExtraCACertFile(path string) ([][]byte, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, fmt.Errorf("extra CA certificates: %w", err)
	}
	defer f.Close()
	var raw bytes.Buffer
	if _, err := raw.ReadFrom(io.LimitReader(f, maxExtraCAFileBytes+1)); err != nil {
		return nil, fmt.Errorf("extra CA certificates: read %s: %w", path, err)
	}
	if raw.Len() > maxExtraCAFileBytes {
		return nil, fmt.Errorf("extra CA certificates: %s is larger than %d bytes", path, maxExtraCAFileBytes)
	}
	var ders [][]byte
	rest := raw.Bytes()
	for {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			break
		}
		if block.Type != "CERTIFICATE" {
			return nil, fmt.Errorf("extra CA certificates: %s has a %q block; it may hold only certificates", path, block.Type)
		}
		if _, err := x509.ParseCertificate(block.Bytes); err != nil {
			return nil, fmt.Errorf("extra CA certificates: %s: %w", path, err)
		}
		ders = append(ders, block.Bytes)
	}
	if len(ders) > 0 {
		return ders, nil
	}
	// Fall back to binary DER (.cer/.crt), single or concatenated.
	if certs, err := x509.ParseCertificates(raw.Bytes()); err == nil && len(certs) > 0 {
		for _, c := range certs {
			ders = append(ders, c.Raw)
		}
		return ders, nil
	}
	return nil, fmt.Errorf("extra CA certificates: %s has no PEM or DER certificate", path)
}

// installExtraCACerts appends ExtraCACerts to a freshly booted VM's system
// bundle and writes them alone for Node. The guest's root is a tmpfs overlay
// that starts from the image on every boot, so this runs once per boot; it
// skips the append when the bundle already has them, so a repeat is harmless.
func (b *MicroVM) installExtraCACerts(ctx context.Context, client *guestproto.Client) error {
	if len(b.ExtraCACerts) == 0 {
		return nil
	}
	if client == nil {
		return errors.New("extra CA certificates: no guest client")
	}
	bundle, err := client.ReadFile(ctx, guestCABundlePath, maxGuestCABundleBytes+1)
	if err != nil {
		return fmt.Errorf("extra CA certificates: read guest bundle: %w", err)
	}
	if len(bundle) > maxGuestCABundleBytes {
		return fmt.Errorf("extra CA certificates: guest bundle is larger than %d bytes", maxGuestCABundleBytes)
	}
	writes := []guestproto.FileWrite{{Path: guestExtraCAPath, Data: b.ExtraCACerts, Mode: 0o644}}
	if !bytes.Contains(bundle, b.ExtraCACerts) {
		merged := make([]byte, 0, len(bundle)+1+len(b.ExtraCACerts))
		merged = append(merged, bundle...)
		if len(merged) > 0 && merged[len(merged)-1] != '\n' {
			merged = append(merged, '\n')
		}
		merged = append(merged, b.ExtraCACerts...)
		writes = append(writes, guestproto.FileWrite{Path: guestCABundlePath, Data: merged, Mode: 0o644})
	}
	if err := client.WriteFiles(ctx, writes); err != nil {
		return fmt.Errorf("extra CA certificates: write guest bundle: %w", err)
	}
	return nil
}

// trustNewVM installs ExtraCACerts in a VM that just booted. A failure is
// logged, not returned: the VM still works for every host the proxy doesn't
// inspect, and a turn that hits an inspected one reports the TLS error itself.
func (b *MicroVM) trustNewVM(ctx context.Context, client *guestproto.Client) {
	if err := b.installExtraCACerts(ctx, client); err != nil {
		b.logger().Warn("microvm: extra CA certificates not installed", "err", err)
	}
}

// applyTrustEnv points tools that ignore the system bundle (or ship their own)
// at the extra roots: Node (Claude Code, npm) at the extra roots alone, which
// it adds to its own; Codex, Python requests (certifi), OpenSSL/Go/Rust/agy,
// Nix, curl, and git at the merged system bundle.
func (b *MicroVM) applyTrustEnv(env map[string]string) {
	if len(b.ExtraCACerts) == 0 {
		return
	}
	env["NODE_EXTRA_CA_CERTS"] = guestExtraCAPath
	env["CODEX_CA_CERTIFICATE"] = guestCABundlePath
	env["REQUESTS_CA_BUNDLE"] = guestCABundlePath
	env["SSL_CERT_FILE"] = guestCABundlePath
	env["NIX_SSL_CERT_FILE"] = guestCABundlePath
	env["CURL_CA_BUNDLE"] = guestCABundlePath
	env["GIT_SSL_CAINFO"] = guestCABundlePath
}
