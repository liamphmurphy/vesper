package main

import (
	"archive/zip"
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"log/slog"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"

	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/db"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
)

func readBackupPassword(passwordFile string) (string, error) {
	if passwordFile != "" {
		raw, err := os.ReadFile(passwordFile)
		if err != nil {
			return "", fmt.Errorf("read backup password file: %w", err)
		}
		pw := string(raw)
		if strings.HasSuffix(pw, "\r\n") {
			pw = strings.TrimSuffix(pw, "\r\n")
		} else {
			pw = strings.TrimSuffix(pw, "\n")
		}
		if pw == "" {
			return "", errors.New("backup password file is empty")
		}
		return pw, nil
	}
	return os.Getenv("VESPER_BACKUP_PASSWORD"), nil
}

// exportData writes the whole instance (every table, every stored object) to
// one archive. It reads the database and object store directly, like
// sign-in-link: whoever can run it already holds their credentials.
func exportData(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("export", flag.ContinueOnError)
	out := fs.String("o", "", `archive file to write, or "-" for stdout (required)`)
	passwordFile := fs.String("password-file", "", "read backup encryption password from FILE (defaults to VESPER_BACKUP_PASSWORD)")
	plaintext := fs.Bool("plaintext", false, "write an unencrypted archive even if backup encryption is enabled")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *out == "" || fs.NArg() != 0 {
		return errors.New("usage: vesper export [-password-file FILE | -plaintext] -o FILE|-")
	}
	password, err := readBackupPassword(*passwordFile)
	if err != nil {
		return err
	}
	if *plaintext && password != "" {
		return errors.New("export: -plaintext cannot be combined with a backup password")
	}
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	pool, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	if *out == "-" {
		// The archive owns stdout, so progress goes to stderr.
		log = slog.New(slog.NewJSONHandler(os.Stderr, nil))
		_, err := exporter(cfg, pool, log).ExportWithPassword(ctx, os.Stdout, password)
		return err
	}

	// Write beside the destination and rename, so a failed export never
	// leaves a half-written archive under the real name.
	tmp, err := os.CreateTemp(filepath.Dir(*out), ".vesper-export-*")
	if err != nil {
		return fmt.Errorf("export: %w", err)
	}
	defer os.Remove(tmp.Name())
	defer tmp.Close()

	m, err := exporter(cfg, pool, log).ExportWithPassword(ctx, tmp, password)
	if err != nil {
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	if err := os.Chmod(tmp.Name(), 0o600); err != nil { // it holds every secret, sealed or not
		return err
	}
	if err := os.Rename(tmp.Name(), *out); err != nil {
		return err
	}
	objects := 0
	for _, b := range m.Buckets {
		objects += len(b.Objects)
	}
	log.Info("export written", "file", *out, "tables", len(m.Tables), "buckets", len(m.Buckets), "objects", objects, "schema_version", m.SchemaVersion, "encrypted", password != "")
	return nil
}

func exporter(cfg config.Config, pool *pgxpool.Pool, log *slog.Logger) *transfer.Exporter {
	return &transfer.Exporter{
		Pool: pool, Blobs: blob.New(cfg.Blob), AppVersion: cfg.Version,
		SecretsKey: cfg.SecretsKey, KnownBuckets: cfg.Blob.Buckets, Log: log,
	}
}

// openArchive opens an archive file, decrypting it if password-protected, or
// spools stdin when path is "-": a zip is read from its end, so a pipe has to
// land in a file first.
func openArchive(path, password string) (*zip.ReadCloser, func(), error) {
	var cleanups []func()
	runCleanups := func() {
		for i := len(cleanups) - 1; i >= 0; i-- {
			cleanups[i]()
		}
	}

	actualPath := path
	if path == "-" {
		tmp, err := os.CreateTemp("", "vesper-import-*")
		if err != nil {
			return nil, nil, fmt.Errorf("import: %w", err)
		}
		tmpName := tmp.Name()
		cleanups = append(cleanups, func() { _ = os.Remove(tmpName) })
		if err := os.Chmod(tmpName, 0o600); err != nil {
			_ = tmp.Close()
			runCleanups()
			return nil, nil, err
		}
		if _, err := io.Copy(tmp, os.Stdin); err != nil {
			_ = tmp.Close()
			runCleanups()
			return nil, nil, fmt.Errorf("import: read stdin: %w", err)
		}
		if err := tmp.Close(); err != nil {
			runCleanups()
			return nil, nil, err
		}
		actualPath = tmpName
	}

	encrypted, err := transfer.IsEncryptedFile(actualPath)
	if err != nil {
		runCleanups()
		return nil, nil, fmt.Errorf("import: open archive: %w", err)
	}
	if encrypted {
		decPath, decCleanup, err := transfer.DecryptArchiveToTemp(actualPath, password)
		if err != nil {
			runCleanups()
			return nil, nil, err
		}
		cleanups = append(cleanups, decCleanup)
		actualPath = decPath
	}

	zr, err := zip.OpenReader(actualPath)
	if err != nil {
		runCleanups()
		return nil, nil, fmt.Errorf("import: open archive: %w", err)
	}
	return zr, func() {
		_ = zr.Close()
		runCleanups()
	}, nil
}

// importData loads an archive into this instance. Stop the server first, and
// set SECRETS_KEY to the source instance's value.
func importData(ctx context.Context, log *slog.Logger, args []string) error {
	fs := flag.NewFlagSet("import", flag.ContinueOnError)
	replace := fs.Bool("replace", false, "discard rows the target already has instead of refusing")
	passwordFile := fs.String("password-file", "", "read backup encryption password from FILE (defaults to VESPER_BACKUP_PASSWORD)")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if fs.NArg() != 1 {
		return errors.New("usage: vesper import [--replace] [-password-file FILE] FILE|-")
	}
	password, err := readBackupPassword(*passwordFile)
	if err != nil {
		return err
	}
	cfg, err := config.Load()
	if err != nil {
		return err
	}
	zr, closeArchive, err := openArchive(fs.Arg(0), password)
	if err != nil {
		return err
	}
	defer closeArchive()

	// No migrate here: the importer brings the schema to the archive's
	// version first, then upgrades it after the rows are in.
	pool, err := db.Open(ctx, cfg.DatabaseURL)
	if err != nil {
		return err
	}
	defer pool.Close()

	start := time.Now()
	if err := (&transfer.Importer{
		Pool: pool, Blobs: blob.New(cfg.Blob), SecretsKey: cfg.SecretsKey, Replace: *replace, Log: log,
	}).Import(ctx, &zr.Reader); err != nil {
		return err
	}
	log.Info("import finished", "took", time.Since(start).Round(time.Millisecond).String())
	return nil
}
