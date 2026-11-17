package main

import (
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/db"
	"github.com/liamphmurphy/vesper/server/internal/httpapi"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

func TestAppSecurityRequirements(t *testing.T) {
	t.Setenv("SECRETS_KEY", base64.StdEncoding.EncodeToString(make([]byte, 32)))
	t.Setenv("VESPER_NO_SIGNIN", "1")
	if err := runApp(context.Background(), slog.New(slog.NewTextHandler(io.Discard, nil)), nil); err == nil || !strings.Contains(err.Error(), "VESPER_NO_SIGNIN") {
		t.Fatalf("expected VESPER_NO_SIGNIN refusal, got %v", err)
	}

	t.Setenv("VESPER_NO_SIGNIN", "")
	t.Setenv("SECRETS_KEY", "")
	if err := runApp(context.Background(), slog.New(slog.NewTextHandler(io.Discard, nil)), nil); err == nil || !strings.Contains(err.Error(), "SECRETS_KEY") {
		t.Fatalf("expected SECRETS_KEY error, got %v", err)
	}
}

func TestImageManagerResumeDownloadAndSHA256(t *testing.T) {
	payload := []byte("0123456789abcdef-vesper-erofs-image-payload")
	sum := sha256.Sum256(payload)
	wantSHA := hex.EncodeToString(sum[:])

	var sawRange bool
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		rng := r.Header.Get("Range")
		if strings.HasPrefix(rng, "bytes=") {
			sawRange = true
			startStr := strings.TrimSuffix(strings.TrimPrefix(rng, "bytes="), "-")
			start, _ := strconv.Atoi(startStr)
			w.Header().Set("Content-Range", "bytes "+strconv.Itoa(start)+"-"+strconv.Itoa(len(payload)-1)+"/"+strconv.Itoa(len(payload)))
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write(payload[start:])
			return
		}
		_, _ = w.Write(payload)
	}))
	defer srv.Close()

	dataDir := t.TempDir()
	partPath := filepath.Join(dataDir, "images", "agent-base.erofs.part")
	if err := os.MkdirAll(filepath.Dir(partPath), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(partPath, payload[:10], 0o644); err != nil {
		t.Fatal(err)
	}

	t.Setenv("VESPER_ROOTFS_SHA256", wantSHA)
	mgr := NewImageManager()
	mgr.DownloadURL = srv.URL + "/agent-base.erofs"

	got, err := mgr.EnsureRootfs(context.Background(), "", dataDir, "", "")
	if err != nil {
		t.Fatalf("EnsureRootfs: %v", err)
	}
	if !sawRange {
		t.Fatal("expected HTTP Range resume request")
	}
	raw, err := os.ReadFile(got)
	if err != nil || string(raw) != string(payload) {
		t.Fatalf("downloaded bytes mismatch: %q err=%v", raw, err)
	}
	if mgr.Status().State != "ready" {
		t.Fatalf("status = %+v", mgr.Status())
	}
}

func TestAppBootsSealedAndRedeemsSignInCode(t *testing.T) {
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	pgBin := filepath.Join(repoRoot, "desktop", "resources", "postgres", "bin")
	if _, err := os.Stat(filepath.Join(pgBin, "postgres")); err != nil {
		t.Skipf("bundled postgres missing at %s", pgBin)
	}

	key := make([]byte, 32)
	_, _ = rand.Read(key)
	t.Setenv("SECRETS_KEY", base64.StdEncoding.EncodeToString(key))
	t.Setenv("VESPER_NO_SIGNIN", "")
	t.Setenv("VESPER_POSTGRES_BIN_DIR", pgBin)
	t.Setenv("VESPER_APP_DISABLE_RUNNER", "1")
	t.Setenv("VESPER_WEB_DIST_DIR", "")

	dataDir := t.TempDir()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	done := make(chan error, 1)
	go func() {
		done <- runApp(ctx, slog.New(slog.NewTextHandler(io.Discard, nil)), []string{
			"-data-dir", dataDir,
			"-addr", "127.0.0.1:0",
		})
	}()

	runtimePath := filepath.Join(dataDir, "runtime.json")
	var rt appRuntimeMetadata
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if raw, rerr := os.ReadFile(runtimePath); rerr == nil && json.Unmarshal(raw, &rt) == nil && rt.URL != "" {
			break
		}
		select {
		case err := <-done:
			t.Fatalf("runApp exited early: %v", err)
		case <-time.After(50 * time.Millisecond):
		}
	}
	if rt.URL == "" {
		t.Fatal("timed out waiting for runtime.json")
	}

	jar, _ := cookiejar.New(nil)
	hc := &http.Client{Jar: jar, Timeout: 5 * time.Second}

	// Poll /api/v1/health -> 200.
	var healthy bool
	for time.Now().Before(deadline) {
		if res, herr := hc.Get(rt.URL + "/api/v1/health"); herr == nil {
			_ = res.Body.Close()
			if res.StatusCode == http.StatusOK {
				healthy = true
				break
			}
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !healthy {
		t.Fatal("/api/v1/health never became 200")
	}

	// /internal/* must be blocked with 404.
	if res, err := hc.Get(rt.URL + "/internal/designs/render"); err != nil {
		t.Fatal(err)
	} else {
		_ = res.Body.Close()
		if res.StatusCode != http.StatusNotFound {
			t.Fatalf("expected 404 on /internal/designs/render, got %d", res.StatusCode)
		}
	}

	// Unauthenticated API calls must return 401.
	if res, err := hc.Get(rt.URL + "/api/v1/inbox"); err != nil {
		t.Fatal(err)
	} else {
		_ = res.Body.Close()
		if res.StatusCode != http.StatusUnauthorized {
			t.Fatalf("expected 401 unauthenticated /api/v1/inbox, got %d", res.StatusCode)
		}
	}

	// Unauthenticated /api/v1/auth/setup must reject because claimed_at was sealed at boot.
	reqSetup, _ := http.NewRequest(http.MethodPost, rt.URL+httpapi.AuthSetupPath, strings.NewReader(`{"login":"evil","password":"password123"}`))
	reqSetup.Header.Set("Content-Type", "application/json")
	if res, err := hc.Do(reqSetup); err != nil {
		t.Fatal(err)
	} else {
		_ = res.Body.Close()
		if res.StatusCode == http.StatusOK || res.StatusCode == http.StatusNoContent {
			t.Fatalf("expected sealed setup to fail, got %d", res.StatusCode)
		}
	}

	// Mint one-time sign-in code over Unix-socket Postgres and redeem cookie.
	pool, err := db.Open(ctx, rt.DatabaseURL)
	if err != nil {
		t.Fatalf("db.Open(%s): %v", rt.DatabaseURL, err)
	}
	code, err := auth.NewSignInCode(ctx, store.New(pool))
	pool.Close()
	if err != nil {
		t.Fatalf("NewSignInCode: %v", err)
	}

	if res, err := hc.Get(rt.URL + httpapi.SignInPath + "?code=" + code); err != nil {
		t.Fatal(err)
	} else {
		_ = res.Body.Close()
	}

	if res, err := hc.Get(rt.URL + "/api/v1/inbox"); err != nil {
		t.Fatal(err)
	} else {
		_ = res.Body.Close()
		if res.StatusCode != http.StatusOK {
			t.Fatalf("expected 200 after redeeming sign-in code, got %d", res.StatusCode)
		}
	}

	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("runApp shutdown error: %v", err)
		}
	case <-time.After(15 * time.Second):
		t.Fatal("timed out waiting for runApp shutdown")
	}
}

func TestAppPlaygroundDefaults(t *testing.T) {
	if got := appPlaygroundPorts(nil); len(got) != 5 || got[0] != 8090 || got[4] != 8094 {
		t.Fatalf("default ports = %v, want 8090-8094", got)
	}
	if got := appPlaygroundPorts([]int{9000}); len(got) != 1 || got[0] != 9000 {
		t.Fatalf("configured ports = %v, want [9000]", got)
	}
	for in, want := range map[string]string{
		"http://127.0.0.1:8080": "http://localhost:8080",
		"http://[::1]:8080":     "http://localhost:8080",
		"http://10.0.0.5:8080":  "",
		"http://localhost:8080": "",
	} {
		if got := localhostURL(in); got != want {
			t.Fatalf("localhostURL(%q) = %q, want %q", in, got, want)
		}
	}
}
