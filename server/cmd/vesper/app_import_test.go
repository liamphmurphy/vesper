package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/cookiejar"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/auth"
	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/db"
	"github.com/liamphmurphy/vesper/server/internal/httpapi"
	"github.com/liamphmurphy/vesper/server/internal/pgembed"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
)

func testBundledPostgresDir(t *testing.T) string {
	t.Helper()
	repoRoot, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	pgBin := filepath.Join(repoRoot, "desktop", "resources", "postgres", "bin")
	if _, err := os.Stat(filepath.Join(pgBin, "postgres")); err != nil {
		t.Skipf("bundled postgres missing at %s", pgBin)
	}
	return pgBin
}

func randomKeyBase64(t *testing.T) string {
	t.Helper()
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		t.Fatal(err)
	}
	return base64.StdEncoding.EncodeToString(b)
}

func TestAppImportInspectSecretPreserveAndDropSecrets(t *testing.T) {
	pgBin := testBundledPostgresDir(t)
	log := slog.New(slog.NewTextHandler(io.Discard, nil))
	ctx := context.Background()

	srcKey := randomKeyBase64(t)
	otherKey := randomKeyBase64(t)

	// 1. Build a realistic source archive (with secret + blob + seeded workspace).
	srcDir := t.TempDir()
	srcPG, err := pgembed.Start(ctx, pgembed.Config{
		BinDir:   pgBin,
		DataDir:  filepath.Join(srcDir, "postgres"),
		Database: "vesper",
		User:     "vesper",
		Log:      log,
	})
	if err != nil {
		t.Fatalf("pgembed.Start source: %v", err)
	}
	srcPool, err := db.Open(ctx, srcPG.DSN())
	if err != nil {
		_ = srcPG.Stop(ctx)
		t.Fatalf("db.Open source: %v", err)
	}
	if err := db.Migrate(ctx, srcPool); err != nil {
		srcPool.Close()
		_ = srcPG.Stop(ctx)
		t.Fatalf("db.Migrate source: %v", err)
	}
	srcS3 := config.S3{Dir: filepath.Join(srcDir, "blobs"), ArtifactBucket: "artifacts", Buckets: []string{"artifacts", "run-logs"}}
	srcBlobs := blob.New(srcS3)
	if err := srcBlobs.EnsureBuckets(ctx); err != nil {
		srcPool.Close()
		_ = srcPG.Stop(ctx)
		t.Fatal(err)
	}
	if _, err := seed.Run(ctx, srcPool, seed.Options{Demo: false, UserName: "Alice Imported", UserEmail: "alice@example.com"}); err != nil {
		srcPool.Close()
		_ = srcPG.Stop(ctx)
		t.Fatal(err)
	}
	var wsID, userID uuid.UUID
	if err := srcPool.QueryRow(ctx, `SELECT id FROM workspaces LIMIT 1`).Scan(&wsID); err != nil {
		t.Fatal(err)
	}
	if err := srcPool.QueryRow(ctx, `SELECT id FROM users LIMIT 1`).Scan(&userID); err != nil {
		t.Fatal(err)
	}
	box, err := secrets.NewBox(srcKey)
	if err != nil {
		t.Fatal(err)
	}
	secSvc := &secrets.Service{Q: store.New(srcPool), Box: box}
	if _, err := secSvc.Set(ctx, wsID, userID, secrets.SetInput{Name: "git:pat", Value: "ghp_imported_token_123"}); err != nil {
		t.Fatalf("seed secret: %v", err)
	}
	const blobPayload = "imported-artifact-body"
	if err := srcBlobs.Put(ctx, "artifacts", "imported/hello.txt", strings.NewReader(blobPayload), int64(len(blobPayload)), "text/plain"); err != nil {
		t.Fatalf("seed blob: %v", err)
	}

	archivePath := filepath.Join(t.TempDir(), "vesper-export.zip")
	af, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := (&transfer.Exporter{
		Pool:         srcPool,
		Blobs:        srcBlobs,
		AppVersion:   "test-1.0",
		SecretsKey:   srcKey,
		KnownBuckets: srcS3.Buckets,
		Log:          log,
	}).Export(ctx, af); err != nil {
		_ = af.Close()
		t.Fatalf("Export: %v", err)
	}
	_ = af.Close()
	srcPool.Close()
	_ = srcPG.Stop(ctx)

	t.Setenv("VESPER_POSTGRES_BIN_DIR", pgBin)

	// 2. Test -inspect with both mismatched and matching SECRETS_KEY.
	inspectWithKey := func(k string) appImportInspection {
		t.Setenv("SECRETS_KEY", k)
		oldOut := os.Stdout
		r, w, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		os.Stdout = w
		runErr := runAppImport(ctx, log, []string{"-inspect", archivePath})
		_ = w.Close()
		os.Stdout = oldOut
		var buf bytes.Buffer
		_, _ = io.Copy(&buf, r)
		_ = r.Close()
		if runErr != nil {
			t.Fatalf("runAppImport -inspect: %v", runErr)
		}
		var out appImportInspection
		if err := json.Unmarshal(buf.Bytes(), &out); err != nil {
			t.Fatalf("decode inspect JSON (%q): %v", buf.String(), err)
		}
		return out
	}

	inspWrong := inspectWithKey(otherKey)
	if inspWrong.MatchesCurrentKey || inspWrong.EncryptedSecretRows != 1 || inspWrong.ObjectCount < 1 || inspWrong.TableCount == 0 {
		t.Fatalf("unexpected wrong-key inspection: %+v", inspWrong)
	}
	inspRight := inspectWithKey(srcKey)
	if !inspRight.MatchesCurrentKey {
		t.Fatalf("expected MatchesCurrentKey=true, got %+v", inspRight)
	}

	// 3. Prepare an existing migrated target dataDir so swap & wrong-key preservation are tested.
	targetDir := t.TempDir()
	existingBlobSentinel := filepath.Join(targetDir, "blobs", "artifacts", "sentinel.txt")
	if err := os.MkdirAll(filepath.Dir(existingBlobSentinel), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(existingBlobSentinel, []byte("keep-me"), 0o644); err != nil {
		t.Fatal(err)
	}
	existingPG, err := pgembed.Start(ctx, pgembed.Config{
		BinDir:   pgBin,
		DataDir:  filepath.Join(targetDir, "postgres"),
		Database: "vesper",
		User:     "vesper",
		Log:      log,
	})
	if err != nil {
		t.Fatal(err)
	}
	existingPool, err := db.Open(ctx, existingPG.DSN())
	if err != nil {
		_ = existingPG.Stop(ctx)
		t.Fatal(err)
	}
	if err := db.Migrate(ctx, existingPool); err != nil {
		existingPool.Close()
		_ = existingPG.Stop(ctx)
		t.Fatal(err)
	}
	existingPool.Close()
	_ = existingPG.Stop(ctx)

	// 4. Wrong key fails fast without modifying targetDir.
	t.Setenv("SECRETS_KEY", otherKey)
	if err := runAppImport(ctx, log, []string{"-data-dir", targetDir, archivePath}); err == nil || !strings.Contains(err.Error(), "does not match") {
		t.Fatalf("expected wrong-key rejection, got %v", err)
	}
	if raw, rerr := os.ReadFile(existingBlobSentinel); rerr != nil || string(raw) != "keep-me" {
		t.Fatalf("expected sentinel preserved on rejected import, got %q err=%v", raw, rerr)
	}

	// 5. Matching SECRETS_KEY succeeds against pre-existing dataDir, then boots runApp + redeems sign-in code.
	t.Setenv("SECRETS_KEY", srcKey)
	if err := runAppImport(ctx, log, []string{"-data-dir", targetDir, archivePath}); err != nil {
		t.Fatalf("runAppImport secret-preserving: %v", err)
	}
	if _, serr := os.Stat(existingBlobSentinel); !os.IsNotExist(serr) {
		t.Fatalf("expected old sentinel dir replaced, got err=%v", serr)
	}
	importedObj, err := blob.NewDir(filepath.Join(targetDir, "blobs"), nil).Get(ctx, "artifacts", "imported/hello.txt")
	if err != nil {
		t.Fatalf("expected imported blob readable via blob.Store: %v", err)
	}
	importedBlob, err := io.ReadAll(importedObj.Body)
	_ = importedObj.Body.Close()
	if err != nil || string(importedBlob) != blobPayload {
		t.Fatalf("expected imported blob %q, got %q err=%v", blobPayload, importedBlob, err)
	}

	t.Setenv("VESPER_NO_SIGNIN", "")
	t.Setenv("VESPER_APP_DISABLE_RUNNER", "1")
	t.Setenv("VESPER_WEB_DIST_DIR", "")
	appCtx, appCancel := context.WithCancel(context.Background())
	defer appCancel()
	appDone := make(chan error, 1)
	go func() {
		appDone <- runApp(appCtx, log, []string{"-data-dir", targetDir, "-addr", "127.0.0.1:0"})
	}()

	runtimePath := filepath.Join(targetDir, "runtime.json")
	var rt appRuntimeMetadata
	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		if raw, rerr := os.ReadFile(runtimePath); rerr == nil && json.Unmarshal(raw, &rt) == nil && rt.URL != "" {
			break
		}
		select {
		case err := <-appDone:
			t.Fatalf("runApp after import exited early: %v", err)
		case <-time.After(50 * time.Millisecond):
		}
	}
	if rt.URL == "" {
		t.Fatal("timed out waiting for runtime.json after import")
	}

	jar, _ := cookiejar.New(nil)
	hc := &http.Client{Jar: jar, Timeout: 5 * time.Second}
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
		t.Fatal("/api/v1/health never became 200 after import")
	}

	pool, err := db.Open(ctx, rt.DatabaseURL)
	if err != nil {
		t.Fatal(err)
	}
	revealed, err := (&secrets.Service{Q: store.New(pool), Box: box}).Reveal(ctx, wsID, nil, "git:pat")
	if err != nil || revealed != "ghp_imported_token_123" {
		pool.Close()
		t.Fatalf("expected decrypted secret after import, got %q err=%v", revealed, err)
	}
	code, err := auth.NewSignInCode(ctx, store.New(pool))
	pool.Close()
	if err != nil {
		t.Fatal(err)
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
			t.Fatalf("expected 200 /api/v1/inbox after import login, got %d", res.StatusCode)
		}
	}
	appCancel()
	if err := <-appDone; err != nil {
		t.Fatalf("runApp shutdown after import: %v", err)
	}

	// 6. Test -drop-secrets succeeds with a different key and clears encrypted secret rows.
	dropDir := t.TempDir()
	t.Setenv("SECRETS_KEY", otherKey)
	if err := runAppImport(ctx, log, []string{"-data-dir", dropDir, "-drop-secrets", archivePath}); err != nil {
		t.Fatalf("runAppImport -drop-secrets: %v", err)
	}
	dropPG, err := pgembed.Start(ctx, pgembed.Config{
		BinDir:   pgBin,
		DataDir:  filepath.Join(dropDir, "postgres"),
		Database: "vesper",
		User:     "vesper",
		Log:      log,
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = dropPG.Stop(context.Background()) }()
	dropPool, err := db.Open(ctx, dropPG.DSN())
	if err != nil {
		t.Fatal(err)
	}
	defer dropPool.Close()
	var secCount int
	if err := dropPool.QueryRow(ctx, `SELECT count(*) FROM secrets`).Scan(&secCount); err != nil {
		t.Fatal(err)
	}
	if secCount != 0 {
		t.Fatalf("expected 0 secrets after -drop-secrets, got %d", secCount)
	}
	var userCount int
	if err := dropPool.QueryRow(ctx, `SELECT count(*) FROM users`).Scan(&userCount); err != nil {
		t.Fatal(err)
	}
	if userCount != 1 {
		t.Fatalf("expected imported user preserved after -drop-secrets, got %d", userCount)
	}
}
