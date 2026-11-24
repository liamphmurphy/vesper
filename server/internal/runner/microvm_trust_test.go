package runner

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/guestproto"
	"github.com/liamphmurphy/vesper/server/internal/runner/microvm"
)

// fakeGuestFS is a guest that keeps files in memory and records each exec's
// environment, enough to see what a boot and a turn leave in the VM.
type fakeGuestFS struct {
	mu    sync.Mutex
	files map[string][]byte
	envs  []map[string]string
}

func (g *fakeGuestFS) file(p string) []byte {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.files[p]
}

func (g *fakeGuestFS) handle(_ context.Context, conn net.Conn) {
	f, err := guestproto.ReadFrame(conn)
	if err != nil {
		return
	}
	var req guestproto.Request
	_ = json.Unmarshal(f.Data, &req)
	reply := func(resp guestproto.Response) {
		resp.ID = f.ID
		raw, _ := json.Marshal(resp)
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameResp, ID: f.ID, Data: raw})
	}
	switch req.Op {
	case guestproto.OpReadFile:
		var in guestproto.ReadFileReq
		_ = json.Unmarshal(req.V, &in)
		data := g.file(in.Path)
		if data == nil {
			reply(guestproto.Response{Err: "open " + in.Path + ": no such file or directory"})
			return
		}
		reply(guestproto.Response{})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameFileChunk, ID: f.ID, Data: data})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameFileEOF, ID: f.ID})
	case guestproto.OpWriteFiles:
		var in guestproto.WriteFilesReq
		_ = json.Unmarshal(req.V, &in)
		g.mu.Lock()
		for _, fw := range in.Files {
			g.files[fw.Path] = fw.Data
		}
		g.mu.Unlock()
		reply(guestproto.Response{})
	case guestproto.OpExecStart:
		var in guestproto.ExecReq
		_ = json.Unmarshal(req.V, &in)
		g.mu.Lock()
		g.envs = append(g.envs, in.Env)
		g.mu.Unlock()
		reply(guestproto.Response{})
		ex, _ := json.Marshal(guestproto.ExecExit{Code: 0})
		_ = guestproto.WriteFrame(conn, guestproto.Frame{Type: guestproto.FrameExecExit, ID: f.ID, Data: ex})
	default:
		reply(guestproto.Response{})
	}
}

const imageBundle = "-----BEGIN CERTIFICATE-----\nIMAGEROOT\n-----END CERTIFICATE-----" // no trailing newline, on purpose

func newTrustTestVM(t *testing.T, extra []byte) (*MicroVM, *fakeGuestFS, *microvm.MemDriver) {
	t.Helper()
	g := &fakeGuestFS{files: map[string][]byte{guestCABundlePath: []byte(imageBundle)}}
	drv := &microvm.MemDriver{Handler: g.handle}
	b := &MicroVM{Driver: drv, StateDir: t.TempDir(), KernelPath: "/k", RootfsPath: "/r", MemoryMB: 512,
		TestWorkspaceBytes: 2 << 20, TestHomeBytes: 2 << 20, TestDockerBytes: 2 << 20, ExtraCACerts: extra}
	t.Cleanup(func() { _ = b.Close() })
	return b, g, drv
}

func TestMicroVMTrustsExtraCACerts(t *testing.T) {
	extra := testCertPEM(t, "Zscaler Root CA")
	b, g, _ := newTrustTestVM(t, extra)

	runTrue(t, b, "zscaler-run")

	want := imageBundle + "\n" + string(extra)
	if got := string(g.file(guestCABundlePath)); got != want {
		t.Fatalf("system bundle = %q, want the image's roots then the extra ones %q", got, want)
	}
	if got := g.file(guestExtraCAPath); !bytes.Equal(got, extra) {
		t.Fatalf("%s = %q, want the extra roots alone", guestExtraCAPath, got)
	}
	g.mu.Lock()
	env := g.envs[len(g.envs)-1]
	g.mu.Unlock()
	for k, v := range map[string]string{
		"NODE_EXTRA_CA_CERTS":  guestExtraCAPath,
		"CODEX_CA_CERTIFICATE": guestCABundlePath,
		"REQUESTS_CA_BUNDLE":   guestCABundlePath,
	} {
		if env[k] != v {
			t.Errorf("turn env %s = %q, want %q", k, env[k], v)
		}
	}
}

func TestMicroVMExtraCACertsInstallOncePerBundle(t *testing.T) {
	extra := testCertPEM(t, "Zscaler Root CA")
	b, g, drv := newTrustTestVM(t, extra)
	vm, err := drv.Start(context.Background(), microvm.VMConfig{})
	if err != nil {
		t.Fatal(err)
	}
	for range 2 {
		if err := b.installExtraCACerts(context.Background(), vm.Client()); err != nil {
			t.Fatal(err)
		}
	}
	if n := bytes.Count(g.file(guestCABundlePath), extra); n != 1 {
		t.Fatalf("extra roots appear %d times in the bundle, want 1", n)
	}
}

func TestMicroVMWithoutExtraCACertsLeavesTrustAlone(t *testing.T) {
	b, g, _ := newTrustTestVM(t, nil)

	runTrue(t, b, "plain-run")

	if got := string(g.file(guestCABundlePath)); got != imageBundle {
		t.Fatalf("system bundle changed without extra roots: %q", got)
	}
	if g.file(guestExtraCAPath) != nil {
		t.Fatalf("%s written without extra roots", guestExtraCAPath)
	}
	g.mu.Lock()
	env := g.envs[len(g.envs)-1]
	g.mu.Unlock()
	for _, k := range []string{"NODE_EXTRA_CA_CERTS", "CODEX_CA_CERTIFICATE", "REQUESTS_CA_BUNDLE"} {
		if _, set := env[k]; set {
			t.Errorf("turn env sets %s without extra roots", k)
		}
	}
}

func TestLoadExtraCACerts(t *testing.T) {
	rootDER := testCertDER(t, "Zscaler Root CA")
	intermediateDER := testCertDER(t, "Zscaler Intermediate")
	root := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: rootDER})
	intermediate := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: intermediateDER})
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: []byte("not really a key")})
	badCert := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: []byte("garbage")})
	privKey, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(privKey)
	if err != nil {
		t.Fatal(err)
	}

	for _, tc := range []struct {
		name    string
		ext     string
		file    []byte
		want    []byte
		wantErr string
	}{
		// `security find-certificate -p` and hand-made bundles carry text
		// between blocks; only the certificates are kept.
		{name: "bundle with comments", ext: ".pem", file: append(append([]byte("# exported from Keychain\n"), root...), append([]byte("\nsubject= Zscaler Intermediate\n"), intermediate...)...),
			want: append(append([]byte(nil), root...), intermediate...)},
		{name: "PEM with CRLF", ext: ".crt", file: bytes.ReplaceAll(root, []byte("\n"), []byte("\r\n")), want: root},
		{name: "single DER certificate", ext: ".cer", file: rootDER, want: root},
		{name: "concatenated DER certificates", ext: ".crt", file: append(append([]byte(nil), rootDER...), intermediateDER...),
			want: append(append([]byte(nil), root...), intermediate...)},
		{name: "private key PEM refused", ext: ".pem", file: append(append([]byte(nil), root...), keyPEM...), wantErr: `"PRIVATE KEY" block`},
		{name: "private key DER refused", ext: ".cer", file: keyDER, wantErr: "no PEM or DER certificate"},
		{name: "no certificate", ext: ".pem", file: []byte("not a pem file\n"), wantErr: "no PEM or DER certificate"},
		{name: "unparsable certificate", ext: ".pem", file: badCert, wantErr: "x509"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			p := filepath.Join(t.TempDir(), "ca"+tc.ext)
			if err := os.WriteFile(p, tc.file, 0o600); err != nil {
				t.Fatal(err)
			}
			got, err := LoadExtraCACerts(p)
			if tc.wantErr != "" {
				if err == nil || !strings.Contains(err.Error(), tc.wantErr) {
					t.Fatalf("err = %v, want one mentioning %q", err, tc.wantErr)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Equal(got, tc.want) {
				t.Fatalf("got %q, want %q", got, tc.want)
			}
		})
	}

	if _, err := LoadExtraCACerts(filepath.Join(t.TempDir(), "missing.pem")); err == nil {
		t.Fatal("missing file accepted")
	}
	if got, err := LoadExtraCACerts(); err != nil || got != nil {
		t.Fatalf("empty paths = (%q, %v), want (nil, nil)", got, err)
	}
}

func TestLoadExtraCACertsMultipleFiles(t *testing.T) {
	dir := t.TempDir()
	rootDER := testCertDER(t, "Zscaler Root CA")
	intDER := testCertDER(t, "Zscaler Intermediate")
	corpDER := testCertDER(t, "Corp Root CA")
	rootPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: rootDER})
	intPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: intDER})
	corpPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: corpDER})

	pemPath := filepath.Join(dir, "zscaler.pem")
	cerPath := filepath.Join(dir, "intermediate.cer")
	crtPath := filepath.Join(dir, "corp.crt")
	if err := os.WriteFile(pemPath, rootPEM, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(cerPath, intDER, 0o600); err != nil {
		t.Fatal(err)
	}
	// Duplicate root in the third file alongside a new DER cert; root should appear once.
	if err := os.WriteFile(crtPath, append(append([]byte(nil), rootDER...), corpDER...), 0o600); err != nil {
		t.Fatal(err)
	}

	got, err := LoadExtraCACerts(pemPath, cerPath, crtPath)
	if err != nil {
		t.Fatal(err)
	}
	want := append(append(append([]byte(nil), rootPEM...), intPEM...), corpPEM...)
	if !bytes.Equal(got, want) {
		t.Fatalf("combined certs mismatch:\ngot:\n%s\nwant:\n%s", got, want)
	}

	badPath := filepath.Join(dir, "bad.cer")
	if err := os.WriteFile(badPath, []byte("not a cert"), 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := LoadExtraCACerts(pemPath, badPath); err == nil {
		t.Fatal("invalid second file accepted")
	}
}

func testCertPEM(t *testing.T, cn string) []byte {
	t.Helper()
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: testCertDER(t, cn)})
}

func testCertDER(t *testing.T, cn string) []byte {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber:          big.NewInt(1),
		Subject:               pkix.Name{CommonName: cn},
		NotBefore:             time.Now().Add(-time.Hour),
		NotAfter:              time.Now().Add(time.Hour),
		IsCA:                  true,
		BasicConstraintsValid: true,
		KeyUsage:              x509.KeyUsageCertSign,
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	return der
}
