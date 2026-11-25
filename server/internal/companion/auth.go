package companion

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/url"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	// PairingCodePrefix marks one-time companion pairing codes.
	PairingCodePrefix = "vcp_"
	// DeviceTokenPrefix marks long-lived companion device bearer tokens.
	DeviceTokenPrefix = "vcd_"
	// PairingCodeTTL is how long a QR pairing code stays valid.
	PairingCodeTTL = 5 * time.Minute
	// BonjourServiceType is the mDNS service type advertised by Vesper on LAN.
	BonjourServiceType = "_vesper._tcp"
)

// ErrBadPairingCode covers unknown, used, and expired pairing codes.
var ErrBadPairingCode = errors.New("companion: invalid or expired pairing code")

// PairingPayload is the JSON encoded inside the QR pairing URI.
type PairingPayload struct {
	Version        int      `json:"v"`
	Name           string   `json:"name"`
	Port           int      `json:"port"`
	CertSHA256     string   `json:"cert_sha256"`
	Code           string   `json:"code"`
	LANHosts       []string `json:"lan_hosts"`
	TailscaleHosts []string `json:"tailscale_hosts"`
	BonjourService string   `json:"bonjour_service"`
}

// EncodePairingURI builds a compact vesper-pair:// URI suitable for a QR code.
func EncodePairingURI(p PairingPayload) (string, error) {
	if p.Version == 0 {
		p.Version = 1
	}
	raw, err := json.Marshal(p)
	if err != nil {
		return "", err
	}
	encoded := base64.RawURLEncoding.EncodeToString(raw)
	u := url.URL{
		Scheme:   "vesper-pair",
		Host:     "v1",
		RawQuery: "data=" + encoded,
	}
	return u.String(), nil
}

func hashSecret(s string) []byte {
	h := sha256.Sum256([]byte(s))
	return h[:]
}

func randomPrefixed(prefix string) (string, error) {
	buf := make([]byte, 32)
	if _, err := rand.Read(buf); err != nil {
		return "", err
	}
	return prefix + base64.RawURLEncoding.EncodeToString(buf), nil
}

// NewPairingCode mints a single-use pairing code and returns the plaintext code
// along with its expiration timestamp.
func NewPairingCode(ctx context.Context, q *store.Queries) (string, time.Time, error) {
	if err := q.DeleteExpiredCompanionPairingCodes(ctx); err != nil {
		return "", time.Time{}, err
	}
	code, err := randomPrefixed(PairingCodePrefix)
	if err != nil {
		return "", time.Time{}, err
	}
	expiresAt := time.Now().UTC().Add(PairingCodeTTL)
	if err := q.CreateCompanionPairingCode(ctx, store.CreateCompanionPairingCodeParams{
		CodeHash:  hashSecret(code),
		ExpiresAt: expiresAt,
	}); err != nil {
		return "", time.Time{}, err
	}
	return code, expiresAt, nil
}

// RedeemPairingCode consumes a pairing code and issues a revocable device token.
func RedeemPairingCode(
	ctx context.Context,
	q *store.Queries,
	userID uuid.UUID,
	code, deviceName, platform string,
) (store.CompanionDevice, string, error) {
	code = strings.TrimSpace(code)
	if !strings.HasPrefix(code, PairingCodePrefix) {
		return store.CompanionDevice{}, "", ErrBadPairingCode
	}
	if _, err := q.RedeemCompanionPairingCode(ctx, hashSecret(code)); errors.Is(err, pgx.ErrNoRows) {
		return store.CompanionDevice{}, "", ErrBadPairingCode
	} else if err != nil {
		return store.CompanionDevice{}, "", err
	}

	deviceName = strings.TrimSpace(deviceName)
	if deviceName == "" {
		deviceName = "iPhone"
	}
	if len(deviceName) > 80 {
		deviceName = deviceName[:80]
	}
	platform = strings.ToLower(strings.TrimSpace(platform))
	if platform == "" {
		platform = "ios"
	}

	token, err := randomPrefixed(DeviceTokenPrefix)
	if err != nil {
		return store.CompanionDevice{}, "", err
	}
	dev, err := q.CreateCompanionDevice(ctx, store.CreateCompanionDeviceParams{
		UserID:    userID,
		Name:      deviceName,
		Platform:  platform,
		TokenHash: hashSecret(token),
	})
	if err != nil {
		return store.CompanionDevice{}, "", err
	}
	return dev, token, nil
}

// ValidDeviceToken reports whether token belongs to an active (non-revoked)
// companion device and throttles last_used_at updates to once per minute.
func ValidDeviceToken(ctx context.Context, q *store.Queries, token string) (bool, error) {
	if !strings.HasPrefix(token, DeviceTokenPrefix) {
		return false, nil
	}
	dev, err := q.GetActiveCompanionDeviceByTokenHash(ctx, hashSecret(token))
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	if time.Since(dev.LastUsedAt) > time.Minute {
		_ = q.TouchCompanionDevice(ctx, dev.ID)
	}
	return true, nil
}
