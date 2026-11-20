package main

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/db"
	"github.com/liamphmurphy/vesper/server/internal/pgembed"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
)

type appImportInspection struct {
	ExportedAt            string `json:"exportedAt"`
	AppVersion            string `json:"appVersion"`
	SchemaVersion         int64  `json:"schemaVersion"`
	TableCount            int    `json:"tableCount"`
	TotalRows             int64  `json:"totalRows"`
	ObjectCount           int    `json:"objectCount"`
	SecretsKeyFingerprint string `json:"secretsKeyFingerprint,omitempty"`
	EncryptedSecretRows   int64  `json:"encryptedSecretRows"`
	MatchesCurrentKey     bool   `json:"matchesCurrentKey"`
	Encrypted             bool   `json:"encrypted,omitempty"`
	NeedsPassword         bool   `json:"needsPassword,omitempty"`
}

func runAppImport(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("app-import", flag.ContinueOnError)
	inspectOnly := fs.Bool("inspect", false, "inspect backup archive manifest as JSON and exit")
	dataDirFlag := fs.String("data-dir", envOr("VESPER_APP_DATA_DIR", defaultAppDataDir()), "persistent Vesper desktop data directory")
	dropSecrets := fs.Bool("drop-secrets", false, "import archive without SECRETS_KEY and clear stored secret ciphertexts")
	passwordFile := fs.String("password-file", "", "read backup encryption password from FILE (defaults to VESPER_BACKUP_PASSWORD)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: vesper app-import [-inspect] [-data-dir DIR] [-drop-secrets] [-password-file FILE] ARCHIVE.zip|ARCHIVE.vesper.enc|EXPORT_DIR")
	}
	archivePath := fs.Arg(0)
	password, err := readBackupPassword(*passwordFile)
	if err != nil {
		return err
	}

	encrypted, err := transfer.IsEncryptedFile(archivePath)
	if err != nil {
		return fmt.Errorf("transfer: inspect %s: %w", archivePath, err)
	}
	effectiveArchive := archivePath
	if encrypted {
		if password == "" {
			if *inspectOnly {
				enc := json.NewEncoder(os.Stdout)
				enc.SetIndent("", "  ")
				return enc.Encode(appImportInspection{Encrypted: true, NeedsPassword: true})
			}
			return transfer.ErrPasswordRequired
		}
		decPath, decCleanup, err := transfer.DecryptArchiveToTemp(archivePath, password)
		if err != nil {
			return err
		}
		defer decCleanup()
		effectiveArchive = decPath
	}

	manifest, err := transfer.InspectArchivePath(effectiveArchive)
	if err != nil {
		return err
	}
	latest, err := db.LatestVersion()
	if err != nil {
		return err
	}
	if manifest.SchemaVersion > latest {
		return fmt.Errorf("app-import: backup schema version %d is newer than this Vesper build (%d); upgrade Vesper first", manifest.SchemaVersion, latest)
	}

	srcKey := strings.TrimSpace(os.Getenv("SECRETS_KEY"))
	if *inspectOnly {
		insp := inspectArchiveManifest(manifest, srcKey)
		insp.Encrypted = encrypted
		enc := json.NewEncoder(os.Stdout)
		enc.SetIndent("", "  ")
		return enc.Encode(insp)
	}

	dataDir := *dataDirFlag
	if dataDir == "" {
		return errors.New("vesper app-import: data-dir is required")
	}
	if err := ensureAppStopped(dataDir); err != nil {
		return err
	}

	if !*dropSecrets {
		if srcKey != "" {
			if _, err := secrets.NewBox(srcKey); err != nil {
				return fmt.Errorf("app-import invalid SECRETS_KEY: %w", err)
			}
			if manifest.SecretsKeyFingerprint != "" && transfer.KeyFingerprint(srcKey) != manifest.SecretsKeyFingerprint {
				return errors.New("the provided SECRETS_KEY does not match this backup archive")
			}
		} else if manifest.SecretsKeyFingerprint != "" {
			return errors.New("this backup holds encrypted secrets; provide SECRETS_KEY or use -drop-secrets")
		}
	}

	if err := os.MkdirAll(dataDir, 0o755); err != nil {
		return err
	}

	stagePG, err := os.MkdirTemp(dataDir, ".postgres-import-*")
	if err != nil {
		return fmt.Errorf("app-import staging postgres dir: %w", err)
	}
	defer func() {
		if stagePG != "" {
			_ = os.RemoveAll(stagePG)
		}
	}()

	stageBlobs, err := os.MkdirTemp(dataDir, ".blobs-import-*")
	if err != nil {
		return fmt.Errorf("app-import staging blobs dir: %w", err)
	}
	defer func() {
		if stageBlobs != "" {
			_ = os.RemoveAll(stageBlobs)
		}
	}()

	exeDir := ""
	if exe, eerr := os.Executable(); eerr == nil {
		exeDir = filepath.Dir(exe)
	}
	pgBinDir := resolvePostgresBinDir(exeDir)

	if err := populateStagedImport(ctx, log, pgBinDir, stagePG, stageBlobs, filepath.Join(dataDir, "logs", "postgres-import.log"), srcKey, *dropSecrets, effectiveArchive); err != nil {
		return err
	}

	if err := swapImportDirectories(dataDir, stagePG, stageBlobs); err != nil {
		return err
	}
	stagePG = ""
	stageBlobs = ""
	return nil
}

func inspectArchiveManifest(m *transfer.Manifest, currentKey string) appImportInspection {
	var totalRows int64
	var secretRows int64
	for _, t := range m.Tables {
		totalRows += t.Rows
		if t.Name == "secrets" || t.Name == "user_secrets" {
			secretRows += t.Rows
		}
	}
	var objectCount int
	for _, b := range m.Buckets {
		objectCount += len(b.Objects)
	}
	matches := false
	if m.SecretsKeyFingerprint != "" && currentKey != "" {
		matches = transfer.KeyFingerprint(currentKey) == m.SecretsKeyFingerprint
	}
	return appImportInspection{
		ExportedAt:            m.ExportedAt.UTC().Format(time.RFC3339),
		AppVersion:            m.AppVersion,
		SchemaVersion:         m.SchemaVersion,
		TableCount:            len(m.Tables),
		TotalRows:             totalRows,
		ObjectCount:           objectCount,
		SecretsKeyFingerprint: m.SecretsKeyFingerprint,
		EncryptedSecretRows:   secretRows,
		MatchesCurrentKey:     matches,
	}
}

func ensureAppStopped(dataDir string) error {
	raw, err := os.ReadFile(filepath.Join(dataDir, "runtime.json"))
	if err != nil {
		return nil
	}
	var rt appRuntimeMetadata
	if json.Unmarshal(raw, &rt) != nil || rt.PID <= 0 || rt.PID == os.Getpid() {
		return nil
	}
	if syscall.Kill(rt.PID, 0) == nil {
		return errors.New("vesper app is still running; stop Vesper before importing")
	}
	return nil
}

func resolvePostgresBinDir(exeDir string) string {
	pgBinDir := strings.TrimSpace(os.Getenv("VESPER_POSTGRES_BIN_DIR"))
	if pgBinDir == "" && exeDir != "" {
		cand := filepath.Join(exeDir, "..", "postgres", "bin")
		if st, serr := os.Stat(filepath.Join(cand, "postgres")); serr == nil && !st.IsDir() {
			pgBinDir = cand
		}
	}
	return pgBinDir
}

func populateStagedImport(ctx context.Context, log *slog.Logger, pgBinDir, stagePG, stageBlobs, logPath, secretsKey string, dropSecrets bool, archivePath string) error {
	pgCluster, err := pgembed.Start(ctx, pgembed.Config{
		BinDir:   pgBinDir,
		DataDir:  stagePG,
		Database: "vesper",
		User:     "vesper",
		LogPath:  logPath,
		Log:      log,
	})
	if err != nil {
		return fmt.Errorf("app-import embedded postgres: %w", err)
	}
	defer func() {
		sctx, scancel := context.WithTimeout(context.Background(), 10*time.Second)
		_ = pgCluster.Stop(sctx)
		scancel()
	}()

	poolCtx, poolCancel := context.WithTimeout(ctx, 60*time.Second)
	pool, err := db.Open(poolCtx, pgCluster.DSN())
	poolCancel()
	if err != nil {
		return err
	}
	defer pool.Close()

	blobCfg := config.Blob{
		Dir:            stageBlobs,
		ArtifactBucket: envOr("BLOB_ARTIFACT_BUCKET", "artifacts"),
	}
	stageBlobsStore := blob.New(blobCfg)
	if err := stageBlobsStore.EnsureBuckets(ctx); err != nil {
		return err
	}

	imp := &transfer.Importer{
		Pool:        pool,
		Blobs:       stageBlobsStore,
		SecretsKey:  secretsKey,
		DropSecrets: dropSecrets,
		Log:         log,
	}
	st, err := os.Stat(archivePath)
	if err != nil {
		return fmt.Errorf("app-import stat %s: %w", archivePath, err)
	}
	if st.IsDir() {
		if err := imp.ImportDir(ctx, archivePath); err != nil {
			return err
		}
	} else {
		zr, err := zip.OpenReader(archivePath)
		if err != nil {
			return fmt.Errorf("app-import open archive: %w", err)
		}
		defer zr.Close()
		if err := imp.Import(ctx, &zr.Reader); err != nil {
			return err
		}
	}

	// Keep desktop onboarding sealed after restoring users from Docker/server exports.
	if _, err := pool.Exec(ctx, `UPDATE users SET claimed_at = COALESCE(claimed_at, now())`); err != nil {
		return fmt.Errorf("app-import seal local user claim: %w", err)
	}
	pool.Close()

	sctx, scancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer scancel()
	if err := pgCluster.Stop(sctx); err != nil {
		return fmt.Errorf("app-import stop staged postgres: %w", err)
	}
	return nil
}

func swapImportDirectories(dataDir, stagePG, stageBlobs string) error {
	targetPG := filepath.Join(dataDir, "postgres")
	targetBlobs := filepath.Join(dataDir, "blobs")
	bakSuffix := ".import-bak-" + randomHex16()

	pgBak, err := swapSingleDir(stagePG, targetPG, bakSuffix)
	if err != nil {
		return err
	}
	blobsBak, err := swapSingleDir(stageBlobs, targetBlobs, bakSuffix)
	if err != nil {
		rollbackSwapDir(targetPG, stagePG, pgBak)
		return err
	}
	if pgBak != "" {
		_ = os.RemoveAll(pgBak)
	}
	if blobsBak != "" {
		_ = os.RemoveAll(blobsBak)
	}
	return nil
}

func swapSingleDir(staged, target, bakSuffix string) (string, error) {
	var backup string
	if _, err := os.Stat(target); err == nil {
		backup = target + bakSuffix
		if err := os.Rename(target, backup); err != nil {
			return "", fmt.Errorf("app-import backup %s: %w", filepath.Base(target), err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}
	if err := os.Rename(staged, target); err != nil {
		if backup != "" {
			_ = os.Rename(backup, target)
		}
		return "", fmt.Errorf("app-import activate %s: %w", filepath.Base(target), err)
	}
	return backup, nil
}

func rollbackSwapDir(target, staged, backup string) {
	if err := os.Rename(target, staged); err == nil && backup != "" {
		_ = os.Rename(backup, target)
	}
}
