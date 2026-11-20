package transfer

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"

	"golang.org/x/crypto/argon2"
)

const (
	// EncryptedExtension is the file extension for password-encrypted Vesper backups.
	EncryptedExtension = ".vesper.enc"

	// BackupPasswordScope is the AAD scope used when sealing the backup password with secrets.Box.
	BackupPasswordScope = "backup:password"

	encryptedMagic = "VSPBENC1"
	headerLen      = 38
	saltLen        = 16
	frameHdrLen    = 5

	defaultArgonMemoryKiB = 64 * 1024
	defaultArgonTime      = 3
	defaultArgonThreads   = 1
	defaultChunkSize      = 64 * 1024

	minArgonMemoryKiB = 1024
	maxArgonMemoryKiB = 512 * 1024
	minArgonTime      = 1
	maxArgonTime      = 32
	minArgonThreads   = 1
	maxArgonThreads   = 16
	minChunkSize      = 1024
	maxChunkSize      = 4 * 1024 * 1024

	chunkFlagContinue = 0x00
	chunkFlagFinal    = 0x01
)

var (
	// ErrPasswordRequired indicates an encrypted archive cannot be read without a password.
	ErrPasswordRequired = errors.New("transfer: this backup is encrypted; provide a backup password")
	// ErrWrongPassword indicates the supplied backup password failed authentication on chunk 0.
	ErrWrongPassword = errors.New("transfer: incorrect backup password")
	// ErrCorruptArchive indicates malformed framing, header validation failure, truncation, or tampering.
	ErrCorruptArchive = errors.New("transfer: encrypted backup is corrupt or truncated")
)

type streamHeader struct {
	raw       [headerLen]byte
	memKiB    uint32
	time      uint32
	threads   uint8
	chunkSize uint32
	salt      [saltLen]byte
}

// HasEncryptedMagic reports whether prefix begins with the encrypted Vesper archive magic.
func HasEncryptedMagic(prefix []byte) bool {
	return len(prefix) >= len(encryptedMagic) && string(prefix[:len(encryptedMagic)]) == encryptedMagic
}

// IsEncryptedFile reports whether path is a regular file beginning with the encrypted archive magic.
// Directories and files shorter than the magic prefix return false, nil.
func IsEncryptedFile(path string) (bool, error) {
	info, err := os.Stat(path)
	if err != nil {
		return false, err
	}
	if info.IsDir() {
		return false, nil
	}
	f, err := os.Open(path)
	if err != nil {
		return false, err
	}
	defer f.Close()

	var magic [len(encryptedMagic)]byte
	_, err = io.ReadFull(f, magic[:])
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return HasEncryptedMagic(magic[:]), nil
}

func newHeader() (streamHeader, error) {
	var h streamHeader
	h.memKiB = defaultArgonMemoryKiB
	h.time = defaultArgonTime
	h.threads = defaultArgonThreads
	h.chunkSize = defaultChunkSize
	if _, err := rand.Read(h.salt[:]); err != nil {
		return streamHeader{}, fmt.Errorf("transfer: generate backup salt: %w", err)
	}
	copy(h.raw[0:8], encryptedMagic)
	binary.BigEndian.PutUint32(h.raw[8:12], h.memKiB)
	binary.BigEndian.PutUint32(h.raw[12:16], h.time)
	h.raw[16] = h.threads
	h.raw[17] = 0
	binary.BigEndian.PutUint32(h.raw[18:22], h.chunkSize)
	copy(h.raw[22:38], h.salt[:])
	return h, nil
}

func readStreamHeader(r io.Reader) (streamHeader, error) {
	var h streamHeader
	if _, err := io.ReadFull(r, h.raw[:]); err != nil {
		return streamHeader{}, fmt.Errorf("%w: %w", ErrCorruptArchive, err)
	}
	if !HasEncryptedMagic(h.raw[:]) {
		return streamHeader{}, ErrCorruptArchive
	}
	h.memKiB = binary.BigEndian.Uint32(h.raw[8:12])
	h.time = binary.BigEndian.Uint32(h.raw[12:16])
	h.threads = h.raw[16]
	reserved := h.raw[17]
	h.chunkSize = binary.BigEndian.Uint32(h.raw[18:22])
	copy(h.salt[:], h.raw[22:38])

	if reserved != 0 ||
		h.memKiB < minArgonMemoryKiB || h.memKiB > maxArgonMemoryKiB ||
		h.time < minArgonTime || h.time > maxArgonTime ||
		h.threads < minArgonThreads || h.threads > maxArgonThreads ||
		h.chunkSize < minChunkSize || h.chunkSize > maxChunkSize {
		return streamHeader{}, ErrCorruptArchive
	}
	return h, nil
}

func deriveStreamAEAD(password string, h streamHeader) (cipher.AEAD, error) {
	key := argon2.IDKey([]byte(password), h.salt[:], h.time, h.memKiB, h.threads, 32)
	defer clear(key)
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

func makeChunkNonce(nonce *[12]byte, chunkIdx uint64, flags byte) {
	binary.BigEndian.PutUint64(nonce[0:8], chunkIdx)
	nonce[8] = 0
	nonce[9] = 0
	nonce[10] = 0
	nonce[11] = flags
}

// EncryptWriter streams plaintext into a chunked Argon2id + AES-256-GCM envelope.
// Callers must call Close() to emit the authenticated final chunk; an unclosed
// stream is rejected by DecryptStream as truncated.
type EncryptWriter struct {
	w        io.Writer
	aead     cipher.AEAD
	hdr      [headerLen]byte
	chunkSz  int
	buf      []byte
	frameBuf []byte
	chunkIdx uint64
	closed   bool
	err      error
}

// NewEncryptWriter writes the encryption header to w and returns a streaming writer.
func NewEncryptWriter(w io.Writer, password string) (*EncryptWriter, error) {
	if password == "" {
		return nil, ErrPasswordRequired
	}
	h, err := newHeader()
	if err != nil {
		return nil, err
	}
	aead, err := deriveStreamAEAD(password, h)
	if err != nil {
		return nil, err
	}
	if _, err := w.Write(h.raw[:]); err != nil {
		return nil, err
	}
	chunkSz := int(h.chunkSize)
	return &EncryptWriter{
		w:        w,
		aead:     aead,
		hdr:      h.raw,
		chunkSz:  chunkSz,
		buf:      make([]byte, 0, chunkSz),
		frameBuf: make([]byte, frameHdrLen, frameHdrLen+chunkSz+aead.Overhead()),
	}, nil
}

// Write buffers plaintext and flushes full non-final chunks as needed.
func (ew *EncryptWriter) Write(p []byte) (int, error) {
	if ew.closed {
		return 0, errors.New("transfer: write on closed encrypt writer")
	}
	if ew.err != nil {
		return 0, ew.err
	}
	written := 0
	for len(p) > 0 {
		take := min(len(p), ew.chunkSz-len(ew.buf))
		ew.buf = append(ew.buf, p[:take]...)
		p = p[take:]
		written += take
		if len(ew.buf) == ew.chunkSz {
			if err := ew.flushChunk(chunkFlagContinue); err != nil {
				ew.err = err
				return written, err
			}
		}
	}
	return written, nil
}

// Close flushes any remaining plaintext (including an empty final chunk) with
// the final flag so truncation can be detected.
func (ew *EncryptWriter) Close() error {
	if ew.closed {
		return ew.err
	}
	ew.closed = true
	if ew.err != nil {
		return ew.err
	}
	if err := ew.flushChunk(chunkFlagFinal); err != nil {
		ew.err = err
		return err
	}
	clear(ew.buf)
	return nil
}

func (ew *EncryptWriter) flushChunk(flags byte) error {
	var nonce [12]byte
	makeChunkNonce(&nonce, ew.chunkIdx, flags)
	framed := ew.aead.Seal(ew.frameBuf[:frameHdrLen], nonce[:], ew.buf, ew.hdr[:])
	ctLen := len(framed) - frameHdrLen
	framed[0] = flags
	binary.BigEndian.PutUint32(framed[1:frameHdrLen], uint32(ctLen))
	if _, err := ew.w.Write(framed); err != nil {
		return err
	}
	ew.buf = ew.buf[:0]
	ew.chunkIdx++
	return nil
}

// DecryptStream reads an encrypted backup stream from r and writes plaintext to w.
func DecryptStream(r io.Reader, w io.Writer, password string) error {
	h, err := readStreamHeader(r)
	if err != nil {
		return err
	}
	if password == "" {
		return ErrPasswordRequired
	}
	return decryptStreamWithHeader(r, w, password, h)
}

func decryptStreamWithHeader(r io.Reader, w io.Writer, password string, h streamHeader) error {
	aead, err := deriveStreamAEAD(password, h)
	if err != nil {
		return err
	}
	overhead := uint32(aead.Overhead())
	maxCT := h.chunkSize + overhead
	ctBuf := make([]byte, maxCT)
	ptBuf := make([]byte, 0, h.chunkSize)

	var frameHdr [frameHdrLen]byte
	var nonce [12]byte
	var chunkIdx uint64

	for {
		_, err := io.ReadFull(r, frameHdr[:])
		if err != nil {
			// EOF before seeing chunkFlagFinal means the stream was truncated.
			return fmt.Errorf("%w: %w", ErrCorruptArchive, err)
		}
		flags := frameHdr[0]
		if flags != chunkFlagContinue && flags != chunkFlagFinal {
			return ErrCorruptArchive
		}
		ctLen := binary.BigEndian.Uint32(frameHdr[1:frameHdrLen])
		if ctLen < overhead || ctLen > maxCT {
			return ErrCorruptArchive
		}
		ct := ctBuf[:ctLen]
		if _, err := io.ReadFull(r, ct); err != nil {
			return fmt.Errorf("%w: %w", ErrCorruptArchive, err)
		}
		makeChunkNonce(&nonce, chunkIdx, flags)
		pt, err := aead.Open(ptBuf[:0], nonce[:], ct, h.raw[:])
		if err != nil {
			if chunkIdx == 0 {
				return ErrWrongPassword
			}
			return ErrCorruptArchive
		}
		if len(pt) > 0 {
			if _, err := w.Write(pt); err != nil {
				return err
			}
		}
		if flags == chunkFlagFinal {
			var trailing [1]byte
			n, err := r.Read(trailing[:])
			if n > 0 || err != io.EOF {
				return ErrCorruptArchive
			}
			return nil
		}
		chunkIdx++
	}
}

// DecryptArchiveToTemp decrypts archivePath to a 0600 temporary .zip file and
// returns its path and cleanup callback.
func DecryptArchiveToTemp(archivePath, password string) (string, func(), error) {
	f, err := os.Open(archivePath)
	if err != nil {
		return "", nil, fmt.Errorf("transfer: open encrypted archive: %w", err)
	}
	defer f.Close()

	h, err := readStreamHeader(f)
	if err != nil {
		return "", nil, err
	}
	if password == "" {
		return "", nil, ErrPasswordRequired
	}

	tmp, err := os.CreateTemp("", "vesper-decrypt-*.zip")
	if err != nil {
		return "", nil, fmt.Errorf("transfer: create temp archive: %w", err)
	}
	tmpPath := tmp.Name()
	cleanup := func() { _ = os.Remove(tmpPath) }
	if err := os.Chmod(tmpPath, 0o600); err != nil {
		_ = tmp.Close()
		cleanup()
		return "", nil, err
	}
	if err := decryptStreamWithHeader(f, tmp, password, h); err != nil {
		_ = tmp.Close()
		cleanup()
		return "", nil, err
	}
	if err := tmp.Close(); err != nil {
		cleanup()
		return "", nil, err
	}
	return tmpPath, cleanup, nil
}
