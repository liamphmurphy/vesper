package companion

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"time"
)

// TLSMaterial holds the self-signed certificate used by the companion HTTPS
// listener and its lowercase hex SHA-256 DER fingerprint for client pinning.
type TLSMaterial struct {
	Config            *tls.Config
	FingerprintSHA256 string
}

// LoadOrCreateCert loads a persisted companion TLS certificate from dir or
// generates a new ECDSA P-256 self-signed certificate if none exists or it is
// within 30 days of expiring.
func LoadOrCreateCert(dir, hostName string) (*TLSMaterial, error) {
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return nil, fmt.Errorf("create companion cert dir: %w", err)
	}
	certPath := filepath.Join(dir, "cert.pem")
	keyPath := filepath.Join(dir, "key.pem")

	if mat, ok := tryLoadCert(certPath, keyPath); ok {
		return mat, nil
	}

	priv, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return nil, fmt.Errorf("generate companion key: %w", err)
	}
	serialLimit := new(big.Int).Lsh(big.NewInt(1), 128)
	serial, err := rand.Int(rand.Reader, serialLimit)
	if err != nil {
		return nil, fmt.Errorf("generate companion serial: %w", err)
	}

	if hostName == "" {
		hostName = "vesper-mac"
	}
	now := time.Now().UTC()
	tmpl := &x509.Certificate{
		SerialNumber: serial,
		Subject: pkix.Name{
			CommonName:   hostName,
			Organization: []string{"Vesper Companion"},
		},
		NotBefore:             now.Add(-5 * time.Minute),
		NotAfter:              now.Add(10 * 365 * 24 * time.Hour),
		KeyUsage:              x509.KeyUsageDigitalSignature | x509.KeyUsageKeyEncipherment,
		ExtKeyUsage:           []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
		BasicConstraintsValid: true,
		DNSNames:              []string{"localhost", hostName},
		IPAddresses:           []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")},
	}

	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &priv.PublicKey, priv)
	if err != nil {
		return nil, fmt.Errorf("create companion cert: %w", err)
	}
	keyDER, err := x509.MarshalECPrivateKey(priv)
	if err != nil {
		return nil, fmt.Errorf("marshal companion key: %w", err)
	}

	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER})

	if err := os.WriteFile(certPath, certPEM, 0o644); err != nil {
		return nil, fmt.Errorf("write companion cert: %w", err)
	}
	if err := os.WriteFile(keyPath, keyPEM, 0o600); err != nil {
		return nil, fmt.Errorf("write companion key: %w", err)
	}

	tlsCert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, fmt.Errorf("parse companion key pair: %w", err)
	}
	return buildMaterial(tlsCert), nil
}

func tryLoadCert(certPath, keyPath string) (*TLSMaterial, bool) {
	tlsCert, err := tls.LoadX509KeyPair(certPath, keyPath)
	if err != nil || len(tlsCert.Certificate) == 0 {
		return nil, false
	}
	leaf, err := x509.ParseCertificate(tlsCert.Certificate[0])
	if err != nil {
		return nil, false
	}
	if time.Until(leaf.NotAfter) < 30*24*time.Hour {
		return nil, false
	}
	return buildMaterial(tlsCert), true
}

func buildMaterial(cert tls.Certificate) *TLSMaterial {
	sum := sha256.Sum256(cert.Certificate[0])
	return &TLSMaterial{
		Config: &tls.Config{
			MinVersion:   tls.VersionTLS12,
			Certificates: []tls.Certificate{cert},
		},
		FingerprintSHA256: hex.EncodeToString(sum[:]),
	}
}
