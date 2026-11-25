package httpapi

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/companion"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
)

func TestCompanionPairingAuthAndRevocation(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	q := store.New(pool)
	if _, err := seed.Run(ctx, pool, seed.Options{UserName: "Liam", UserEmail: "liam@localhost"}); err != nil {
		t.Fatalf("seed: %v", err)
	}

	srv := &Server{
		Pool: pool,
		Q:    q,
		Companion: &CompanionRuntimeInfo{
			Enabled:         true,
			Port:            8443,
			CertFingerprint: strings.Repeat("a", 64),
			DiscoverNetworkFn: func(context.Context) companion.NetworkInfo {
				return companion.NetworkInfo{
					HostName:           "liam-mbp",
					LANAddresses:       []string{"192.168.1.42"},
					TailscaleAddresses: []string{"100.64.0.10"},
					TailscaleDNS:       "liam-mbp.tailnet.ts.net",
				}
			},
		},
	}
	handler := srv.Handler()

	// 1. Mint a browser session cookie (simulating the Mac app).
	sessionToken, err := auth.NewSession(ctx, q)
	if err != nil {
		t.Fatalf("NewSession: %v", err)
	}
	sessionCookie := &http.Cookie{Name: auth.SessionCookie, Value: sessionToken}

	// 2. Request a QR pairing code from the Mac app.
	req := httptest.NewRequest(http.MethodPost, "/api/v1/companion/pairing-code", nil)
	req.AddCookie(sessionCookie)
	rec := httptest.NewRecorder()
	handler.ServeHTTP(rec, req)
	if rec.Code != http.StatusCreated {
		t.Fatalf("pairing-code status = %d, body = %s", rec.Code, rec.Body.String())
	}
	var codeResp companionPairingCodeOut
	if err := json.Unmarshal(rec.Body.Bytes(), &codeResp); err != nil {
		t.Fatalf("decode pairing-code: %v", err)
	}
	if !strings.HasPrefix(codeResp.Code, companion.PairingCodePrefix) {
		t.Fatalf("unexpected code prefix: %q", codeResp.Code)
	}
	if !strings.HasPrefix(codeResp.PayloadURI, "vesper-pair://v1?data=") {
		t.Fatalf("unexpected payload_uri: %q", codeResp.PayloadURI)
	}

	// 3. Unauthenticated iPhone redeems the pairing code.
	pairBody, _ := json.Marshal(companionPairIn{
		Code:       codeResp.Code,
		DeviceName: "Liam's iPhone 18 Pro Max",
		Platform:   "ios",
	})
	pairReq := httptest.NewRequest(http.MethodPost, CompanionPairPath, bytes.NewReader(pairBody))
	pairRec := httptest.NewRecorder()
	handler.ServeHTTP(pairRec, pairReq)
	if pairRec.Code != http.StatusCreated {
		t.Fatalf("pair status = %d, body = %s", pairRec.Code, pairRec.Body.String())
	}
	var pairResp companionPairOut
	if err := json.Unmarshal(pairRec.Body.Bytes(), &pairResp); err != nil {
		t.Fatalf("decode pair response: %v", err)
	}
	if !strings.HasPrefix(pairResp.DeviceToken, companion.DeviceTokenPrefix) {
		t.Fatalf("unexpected device token: %q", pairResp.DeviceToken)
	}

	// 4. iPhone calls a person-facing API route using Authorization: Bearer vcd_...
	statusReq := httptest.NewRequest(http.MethodGet, "/api/v1/companion/status", nil)
	statusReq.Header.Set("Authorization", "Bearer "+pairResp.DeviceToken)
	statusRec := httptest.NewRecorder()
	handler.ServeHTTP(statusRec, statusReq)
	if statusRec.Code != http.StatusOK {
		t.Fatalf("status with bearer token = %d, body = %s", statusRec.Code, statusRec.Body.String())
	}
	var statusResp companionStatusOut
	if err := json.Unmarshal(statusRec.Body.Bytes(), &statusResp); err != nil {
		t.Fatalf("decode status: %v", err)
	}
	if !statusResp.Enabled || statusResp.Port != 8443 || len(statusResp.Devices) != 1 {
		t.Fatalf("unexpected status: %+v", statusResp)
	}

	// 5. Mac revokes the device.
	delReq := httptest.NewRequest(http.MethodDelete, "/api/v1/companion/devices/"+pairResp.DeviceID.String(), nil)
	delReq.AddCookie(sessionCookie)
	delRec := httptest.NewRecorder()
	handler.ServeHTTP(delRec, delReq)
	if delRec.Code != http.StatusNoContent {
		t.Fatalf("revoke status = %d, body = %s", delRec.Code, delRec.Body.String())
	}

	// 6. Revoked token is immediately rejected with 401.
	retryReq := httptest.NewRequest(http.MethodGet, "/api/v1/companion/status", nil)
	retryReq.Header.Set("Authorization", "Bearer "+pairResp.DeviceToken)
	retryRec := httptest.NewRecorder()
	handler.ServeHTTP(retryRec, retryReq)
	if retryRec.Code != http.StatusUnauthorized {
		t.Fatalf("expected 401 after revocation, got %d", retryRec.Code)
	}
}
