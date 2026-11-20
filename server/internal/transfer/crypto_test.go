package transfer_test

import (
	"archive/zip"
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"os"
	"path/filepath"
	"slices"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/transfer"
)

func encryptBytes(t *testing.T, plain []byte, password string) []byte {
	t.Helper()
	var buf bytes.Buffer
	ew, err := transfer.NewEncryptWriter(&buf, password)
	if err != nil {
		t.Fatalf("NewEncryptWriter: %v", err)
	}
	if len(plain) > 0 {
		if _, err := ew.Write(plain); err != nil {
			t.Fatalf("Write: %v", err)
		}
	}
	if err := ew.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	return buf.Bytes()
}

func TestStreamEncryptDecryptBoundaries(t *testing.T) {
	const password = "correct horse battery staple"
	large := make([]byte, 3*64*1024+137)
	if _, err := rand.Read(large); err != nil {
		t.Fatal(err)
	}

	cases := []struct {
		name  string
		plain []byte
	}{
		{"empty", []byte{}},
		{"small", []byte("hello encrypted world")},
		{"exact_chunk", bytes.Repeat([]byte("A"), 64*1024)},
		{"multi_chunk", large},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			enc := encryptBytes(t, tc.plain, password)
			if !transfer.HasEncryptedMagic(enc) {
				t.Fatalf("missing magic in header")
			}

			var out bytes.Buffer
			if err := transfer.DecryptStream(bytes.NewReader(enc), &out, password); err != nil {
				t.Fatalf("DecryptStream: %v", err)
			}
			if !bytes.Equal(out.Bytes(), tc.plain) {
				t.Fatalf("decrypted len = %d, want %d", out.Len(), len(tc.plain))
			}

			var wrongOut bytes.Buffer
			if err := transfer.DecryptStream(bytes.NewReader(enc), &wrongOut, "wrong-password"); !errors.Is(err, transfer.ErrWrongPassword) {
				t.Fatalf("wrong password err = %v, want ErrWrongPassword", err)
			}

			var emptyPwOut bytes.Buffer
			if err := transfer.DecryptStream(bytes.NewReader(enc), &emptyPwOut, ""); !errors.Is(err, transfer.ErrPasswordRequired) {
				t.Fatalf("empty password err = %v, want ErrPasswordRequired", err)
			}
		})
	}
}

func TestEncryptWriterRejectsEmptyPassword(t *testing.T) {
	var buf bytes.Buffer
	if _, err := transfer.NewEncryptWriter(&buf, ""); !errors.Is(err, transfer.ErrPasswordRequired) {
		t.Fatalf("err = %v, want ErrPasswordRequired", err)
	}
}

func TestDecryptStreamRejectsTamperingAndTruncation(t *testing.T) {
	const password = "backup-secret-password"
	plain := bytes.Repeat([]byte("0123456789abcdef"), 6000) // > 64 KiB -> at least 2 chunks
	enc := encryptBytes(t, plain, password)

	t.Run("truncated_before_final_chunk", func(t *testing.T) {
		// Strip the final chunk frame completely (16 tag + 5 frame header + remainder).
		firstCTLen := binary.BigEndian.Uint32(enc[38+1 : 38+5])
		truncated := enc[:38+5+int(firstCTLen)]
		var out bytes.Buffer
		if err := transfer.DecryptStream(bytes.NewReader(truncated), &out, password); !errors.Is(err, transfer.ErrCorruptArchive) {
			t.Fatalf("err = %v, want ErrCorruptArchive", err)
		}
	})

	t.Run("unclosed_encrypt_writer", func(t *testing.T) {
		var partial bytes.Buffer
		ew, err := transfer.NewEncryptWriter(&partial, password)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := ew.Write([]byte("half-written")); err != nil {
			t.Fatal(err)
		}
		// Never call ew.Close().
		var out bytes.Buffer
		if err := transfer.DecryptStream(bytes.NewReader(partial.Bytes()), &out, password); !errors.Is(err, transfer.ErrCorruptArchive) {
			t.Fatalf("err = %v, want ErrCorruptArchive", err)
		}
	})

	t.Run("trailing_bytes_after_final_chunk", func(t *testing.T) {
		withTrail := append(slices.Clone(enc), 0x42)
		var out bytes.Buffer
		if err := transfer.DecryptStream(bytes.NewReader(withTrail), &out, password); !errors.Is(err, transfer.ErrCorruptArchive) {
			t.Fatalf("err = %v, want ErrCorruptArchive", err)
		}
	})

	t.Run("flipped_header_aad_byte", func(t *testing.T) {
		badHdr := slices.Clone(enc)
		badHdr[25] ^= 0xff // salt byte in header (AAD)
		var out bytes.Buffer
		if err := transfer.DecryptStream(bytes.NewReader(badHdr), &out, password); err == nil {
			t.Fatal("expected error for flipped header byte")
		}
	})

	t.Run("flipped_reserved_header_byte", func(t *testing.T) {
		badRes := slices.Clone(enc)
		badRes[17] = 1
		var out bytes.Buffer
		if err := transfer.DecryptStream(bytes.NewReader(badRes), &out, password); !errors.Is(err, transfer.ErrCorruptArchive) {
			t.Fatalf("err = %v, want ErrCorruptArchive", err)
		}
	})

	t.Run("flipped_chunk0_flag_byte", func(t *testing.T) {
		badFlag := slices.Clone(enc)
		badFlag[38] = 0x01 // lie that chunk 0 is final
		var out bytes.Buffer
		if err := transfer.DecryptStream(bytes.NewReader(badFlag), &out, password); err == nil {
			t.Fatal("expected error for flipped chunk flag")
		}
	})

	t.Run("flipped_chunk1_ciphertext_byte", func(t *testing.T) {
		firstCTLen := binary.BigEndian.Uint32(enc[38+1 : 38+5])
		chunk1Offset := 38 + 5 + int(firstCTLen)
		badCT := slices.Clone(enc)
		badCT[chunk1Offset+6] ^= 0xff
		var out bytes.Buffer
		if err := transfer.DecryptStream(bytes.NewReader(badCT), &out, password); !errors.Is(err, transfer.ErrCorruptArchive) {
			t.Fatalf("err = %v, want ErrCorruptArchive", err)
		}
	})
}

func TestEncryptedExportInspectAndImportRoundTrip(t *testing.T) {
	src := testdb.New(t)
	seed(t, src)
	srcBlobs := newMemBlobs()
	srcBlobs.put("artifacts", "doc.txt", "text/plain", []byte("encrypted-blob-contents"))

	const backupPassword = "  preserve leading/trailing spaces!  "
	archivePath := filepath.Join(t.TempDir(), "vesper-export"+transfer.EncryptedExtension)
	f, err := os.Create(archivePath)
	if err != nil {
		t.Fatal(err)
	}
	m, err := (&transfer.Exporter{Pool: src, Blobs: srcBlobs, AppVersion: "enc-test"}).ExportWithPassword(t.Context(), f, backupPassword)
	if err != nil {
		_ = f.Close()
		t.Fatalf("ExportWithPassword: %v", err)
	}
	if err := f.Close(); err != nil {
		t.Fatal(err)
	}

	isEnc, err := transfer.IsEncryptedFile(archivePath)
	if err != nil || !isEnc {
		t.Fatalf("IsEncryptedFile = (%v, %v), want (true, nil)", isEnc, err)
	}

	// Inspect requires the password.
	if _, err := transfer.InspectArchivePath(archivePath); !errors.Is(err, transfer.ErrPasswordRequired) {
		t.Fatalf("InspectArchivePath without password err = %v, want ErrPasswordRequired", err)
	}
	if _, err := transfer.InspectArchivePathWithPassword(archivePath, "wrong"); !errors.Is(err, transfer.ErrWrongPassword) {
		t.Fatalf("InspectArchivePathWithPassword wrong password err = %v, want ErrWrongPassword", err)
	}
	gotManifest, err := transfer.InspectArchivePathWithPassword(archivePath, backupPassword)
	if err != nil {
		t.Fatalf("InspectArchivePathWithPassword: %v", err)
	}
	if gotManifest.AppVersion != m.AppVersion || len(gotManifest.Tables) != len(m.Tables) {
		t.Fatalf("manifest mismatch: got %+v, want %+v", gotManifest, m)
	}

	// Decrypt to temp and import into an unmigrated database.
	tmpZip, cleanup, err := transfer.DecryptArchiveToTemp(archivePath, backupPassword)
	if err != nil {
		t.Fatalf("DecryptArchiveToTemp: %v", err)
	}
	defer cleanup()

	info, err := os.Stat(tmpZip)
	if err != nil {
		t.Fatal(err)
	}
	if mode := info.Mode().Perm(); mode != 0o600 {
		t.Fatalf("temp zip mode = %o, want 0600", mode)
	}

	zr, err := zip.OpenReader(tmpZip)
	if err != nil {
		t.Fatalf("open decrypted zip: %v", err)
	}
	defer zr.Close()

	dst := testdb.NewUnmigrated(t)
	dstBlobs := newMemBlobs()
	if err := (&transfer.Importer{Pool: dst, Blobs: dstBlobs}).Import(t.Context(), &zr.Reader); err != nil {
		t.Fatalf("Importer.Import: %v", err)
	}

	want, got := dump(t, src), dump(t, dst)
	for table, rows := range want {
		if !slices.Equal(rows, got[table]) {
			t.Errorf("table %s differs after encrypted round-trip", table)
		}
	}
}
