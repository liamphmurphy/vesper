package httpapi

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/companion"
	"github.com/liamphmurphy/vesper/server/internal/realtime"
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

func TestCompanionBearerAuthStreamsSSEEvents(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	pool := testdb.New(t)
	q := store.New(pool)
	if _, err := seed.Run(ctx, pool, seed.Options{UserName: "Liam", UserEmail: "liam@localhost"}); err != nil {
		t.Fatalf("seed: %v", err)
	}
	u, err := q.GetLocalUser(ctx)
	if err != nil {
		t.Fatalf("GetLocalUser: %v", err)
	}
	code, _, err := companion.NewPairingCode(ctx, q)
	if err != nil {
		t.Fatalf("NewPairingCode: %v", err)
	}
	_, token, err := companion.RedeemPairingCode(ctx, q, u.ID, code, "Test iPhone", "ios")
	if err != nil {
		t.Fatalf("RedeemPairingCode: %v", err)
	}

	hub := realtime.New()
	defer hub.Close()
	srv := &Server{Pool: pool, Q: q, Events: hub}
	ts := httptest.NewServer(srv.Handler())
	defer ts.Close()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, ts.URL+"/events", nil)
	if err != nil {
		t.Fatalf("NewRequest: %v", err)
	}
	req.Header.Set("Accept", "text/event-stream")
	req.Header.Set("Authorization", "Bearer "+token)

	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatalf("GET /events: %v", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		t.Fatalf("GET /events status = %d, want 200", resp.StatusCode)
	}
	if ct := resp.Header.Get("Content-Type"); !strings.HasPrefix(ct, "text/event-stream") {
		t.Fatalf("Content-Type = %q, want text/event-stream", ct)
	}
	scanner := bufio.NewScanner(resp.Body)
	if !scanner.Scan() {
		t.Fatalf("expected initial SSE frame, err=%v", scanner.Err())
	}
	if line := scanner.Text(); !strings.Contains(line, `"type":"reset"`) {
		t.Fatalf("first SSE line = %q, want reset event", line)
	}
}
