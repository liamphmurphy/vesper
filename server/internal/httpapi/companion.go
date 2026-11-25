package httpapi

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/api"
	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/companion"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// CompanionPairPath is the unauthenticated one-time pairing redemption endpoint.
const CompanionPairPath = "/api/v1/companion/pair"

// CompanionRuntimeInfo describes the active companion TLS listener (if enabled).
type CompanionRuntimeInfo struct {
	Enabled           bool
	Port              int
	CertFingerprint   string
	DiscoverNetworkFn func(context.Context) companion.NetworkInfo
}

type companionDeviceOut struct {
	ID         uuid.UUID `json:"id"`
	Name       string    `json:"name"`
	Platform   string    `json:"platform"`
	CreatedAt  time.Time `json:"created_at"`
	LastUsedAt time.Time `json:"last_used_at"`
}

type companionStatusOut struct {
	Enabled            bool                 `json:"enabled"`
	Port               int                  `json:"port"`
	HostName           string               `json:"host_name"`
	BonjourService     string               `json:"bonjour_service"`
	CertFingerprint    string               `json:"cert_fingerprint"`
	LANAddresses       []string             `json:"lan_addresses"`
	TailscaleAddresses []string             `json:"tailscale_addresses"`
	TailscaleDNS       string               `json:"tailscale_dns,omitempty"`
	Devices            []companionDeviceOut `json:"devices"`
}

type companionPairingCodeOut struct {
	Code       string                   `json:"code"`
	ExpiresAt  time.Time                `json:"expires_at"`
	PayloadURI string                   `json:"payload_uri"`
	Payload    companion.PairingPayload `json:"payload"`
}

type companionPairIn struct {
	Code       string `json:"code"`
	DeviceName string `json:"device_name"`
	Platform   string `json:"platform"`
}

type companionPairOut struct {
	DeviceID    uuid.UUID `json:"device_id"`
	DeviceName  string    `json:"device_name"`
	DeviceToken string    `json:"device_token"`
	HostName    string    `json:"host_name"`
}

func (s *Server) companionRoutes(mux *http.ServeMux) {
	mux.HandleFunc("GET /api/v1/companion/status", s.handleCompanionStatus)
	mux.HandleFunc("POST /api/v1/companion/pairing-code", s.handleCompanionPairingCode)
	mux.HandleFunc("GET /api/v1/companion/devices", s.handleCompanionListDevices)
	mux.HandleFunc("DELETE /api/v1/companion/devices/{id}", s.handleCompanionRevokeDevice)
	mux.HandleFunc("POST "+CompanionPairPath, s.handleCompanionPair)
}

func (s *Server) companionNetworkInfo(ctx context.Context) companion.NetworkInfo {
	if s.Companion != nil && s.Companion.DiscoverNetworkFn != nil {
		return s.Companion.DiscoverNetworkFn(ctx)
	}
	return companion.DiscoverNetwork(ctx)
}

func mapCompanionDevices(rows []store.CompanionDevice) []companionDeviceOut {
	out := make([]companionDeviceOut, 0, len(rows))
	for _, r := range rows {
		out = append(out, companionDeviceOut{
			ID:         r.ID,
			Name:       r.Name,
			Platform:   r.Platform,
			CreatedAt:  r.CreatedAt,
			LastUsedAt: r.LastUsedAt,
		})
	}
	return out
}

func (s *Server) handleCompanionStatus(w http.ResponseWriter, r *http.Request) {
	u, ok := auth.UserFrom(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, api.Unauthenticated, signInMessage, "")
		return
	}
	rows, err := s.Q.ListActiveCompanionDevices(r.Context(), u.ID)
	if err != nil {
		s.Log.Error("list companion devices", "err", err)
		writeError(w, http.StatusInternalServerError, api.Internal, "internal error", "")
		return
	}
	netInfo := s.companionNetworkInfo(r.Context())
	out := companionStatusOut{
		HostName:           netInfo.HostName,
		BonjourService:     companion.BonjourServiceType,
		LANAddresses:       netInfo.LANAddresses,
		TailscaleAddresses: netInfo.TailscaleAddresses,
		TailscaleDNS:       netInfo.TailscaleDNS,
		Devices:            mapCompanionDevices(rows),
	}
	if s.Companion != nil && s.Companion.Enabled {
		out.Enabled = true
		out.Port = s.Companion.Port
		out.CertFingerprint = s.Companion.CertFingerprint
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(out)
}

func (s *Server) handleCompanionPairingCode(w http.ResponseWriter, r *http.Request) {
	if s.Companion == nil || !s.Companion.Enabled {
		writeError(w, http.StatusConflict, api.Conflict, "companion access is disabled; enable it in Settings -> iPhone Companion first", "")
		return
	}
	code, expiresAt, err := companion.NewPairingCode(r.Context(), s.Q)
	if err != nil {
		s.Log.Error("mint companion pairing code", "err", err)
		writeError(w, http.StatusInternalServerError, api.Internal, "internal error", "")
		return
	}
	netInfo := s.companionNetworkInfo(r.Context())
	tsHosts := make([]string, 0, len(netInfo.TailscaleAddresses)+1)
	if netInfo.TailscaleDNS != "" {
		tsHosts = append(tsHosts, netInfo.TailscaleDNS)
	}
	tsHosts = append(tsHosts, netInfo.TailscaleAddresses...)

	payload := companion.PairingPayload{
		Version:        1,
		Name:           netInfo.HostName,
		Port:           s.Companion.Port,
		CertSHA256:     s.Companion.CertFingerprint,
		Code:           code,
		LANHosts:       netInfo.LANAddresses,
		TailscaleHosts: tsHosts,
		BonjourService: companion.BonjourServiceType,
	}
	uri, err := companion.EncodePairingURI(payload)
	if err != nil {
		s.Log.Error("encode companion pairing uri", "err", err)
		writeError(w, http.StatusInternalServerError, api.Internal, "internal error", "")
		return
	}

	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(companionPairingCodeOut{
		Code:       code,
		ExpiresAt:  expiresAt,
		PayloadURI: uri,
		Payload:    payload,
	})
}

func (s *Server) handleCompanionListDevices(w http.ResponseWriter, r *http.Request) {
	u, ok := auth.UserFrom(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, api.Unauthenticated, signInMessage, "")
		return
	}
	rows, err := s.Q.ListActiveCompanionDevices(r.Context(), u.ID)
	if err != nil {
		s.Log.Error("list companion devices", "err", err)
		writeError(w, http.StatusInternalServerError, api.Internal, "internal error", "")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"devices": mapCompanionDevices(rows)})
}

func (s *Server) handleCompanionRevokeDevice(w http.ResponseWriter, r *http.Request) {
	u, ok := auth.UserFrom(r.Context())
	if !ok {
		writeError(w, http.StatusUnauthorized, api.Unauthenticated, signInMessage, "")
		return
	}
	id, err := uuid.Parse(r.PathValue("id"))
	if err != nil {
		writeError(w, http.StatusBadRequest, api.Invalid, "invalid device id", "id")
		return
	}
	if _, err := s.Q.RevokeCompanionDevice(r.Context(), store.RevokeCompanionDeviceParams{
		ID:     id,
		UserID: u.ID,
	}); errors.Is(err, pgx.ErrNoRows) {
		writeError(w, http.StatusNotFound, api.NotFound, "device not found", "")
		return
	} else if err != nil {
		s.Log.Error("revoke companion device", "err", err)
		writeError(w, http.StatusInternalServerError, api.Internal, "internal error", "")
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

func (s *Server) handleCompanionPair(w http.ResponseWriter, r *http.Request) {
	if crossOriginWrite(r) {
		writeError(w, http.StatusForbidden, api.Forbidden, "cross-origin writes are refused", "")
		return
	}
	u, ok := auth.UserFrom(r.Context())
	if !ok {
		writeError(w, http.StatusServiceUnavailable, api.NoUser, "no workspace user yet", "")
		return
	}
	var in companionPairIn
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16*1024)).Decode(&in); err != nil {
		writeError(w, http.StatusBadRequest, api.Invalid, "invalid JSON body", "")
		return
	}
	dev, token, err := companion.RedeemPairingCode(r.Context(), s.Q, u.ID, in.Code, in.DeviceName, in.Platform)
	if errors.Is(err, companion.ErrBadPairingCode) {
		writeError(w, http.StatusUnauthorized, api.Unauthenticated, "invalid or expired pairing code", "")
		return
	}
	if err != nil {
		s.Log.Error("redeem companion pairing code", "err", err)
		writeError(w, http.StatusInternalServerError, api.Internal, "internal error", "")
		return
	}
	netInfo := s.companionNetworkInfo(r.Context())
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(companionPairOut{
		DeviceID:    dev.ID,
		DeviceName:  dev.Name,
		DeviceToken: token,
		HostName:    netInfo.HostName,
	})
}

func companionBearerToken(r *http.Request) string {
	h := strings.TrimSpace(r.Header.Get("Authorization"))
	if len(h) > 7 && strings.EqualFold(h[:7], "Bearer ") {
		tok := strings.TrimSpace(h[7:])
		if strings.HasPrefix(tok, companion.DeviceTokenPrefix) {
			return tok
		}
	}
	return ""
}
