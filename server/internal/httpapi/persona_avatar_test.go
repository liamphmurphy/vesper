package httpapi

import (
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/gif"
	"image/jpeg"
	"image/png"
	"io"
	"mime/multipart"
	"net/http"
	"net/textproto"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/blob"
	"github.com/liamphmurphy/vesper/server/internal/config"
	"github.com/liamphmurphy/vesper/server/internal/personas"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// fakeBlobs is a local-directory blob store (the one the app uses) with
// helpers to see what a handler stored and to make writes fail, so the
// handlers run against the real blob client.
type fakeBlobs struct {
	*blob.Store
	failPut, failDelete atomic.Bool
}

func newFakeBlobs(t *testing.T) *fakeBlobs {
	t.Helper()
	f := &fakeBlobs{Store: blob.New(config.Blob{Dir: t.TempDir()})}
	f.SetFault(func(op, _, _ string) error {
		if (op == "put" && f.failPut.Load()) || (op == "delete" && f.failDelete.Load()) {
			return errors.New("blob: injected failure")
		}
		return nil
	})
	return f
}

// keys lists the stored "bucket/key" names under prefix.
func (f *fakeBlobs) keys(prefix string) []string {
	ctx := context.Background()
	buckets, err := f.ListBuckets(ctx)
	if err != nil {
		return nil
	}
	var out []string
	for _, b := range buckets {
		_ = f.List(ctx, b, func(i blob.Info) error {
			if k := b + "/" + i.Key; strings.HasPrefix(k, prefix) {
				out = append(out, k)
			}
			return nil
		})
	}
	return out
}

// body is the content stored at "bucket/key".
func (f *fakeBlobs) body(key string) []byte {
	bucket, k, _ := strings.Cut(key, "/")
	o, err := f.Get(context.Background(), bucket, k)
	if err != nil {
		return nil
	}
	defer o.Body.Close()
	b, _ := io.ReadAll(o.Body)
	return b
}

func (f *fakeBlobs) put(key string, body []byte, ct string) {
	bucket, k, _ := strings.Cut(key, "/")
	if err := f.EnsureBucket(context.Background(), bucket); err != nil {
		panic(err)
	}
	if err := f.Put(context.Background(), bucket, k, bytes.NewReader(body), int64(len(body)), ct); err != nil {
		panic(err)
	}
}

const avatarBucket = "test-artifacts"

func newAvatarEnv(t *testing.T) (*chatEnv, *fakeBlobs) {
	t.Helper()
	fake := newFakeBlobs(t)
	e := newChatEnvServer(t, nil, func(s *Server) {
		s.Blobs = fake.Store
		s.ArtifactBucket = avatarBucket
	})
	return e, fake
}

func avatarImage(w, h int) image.Image {
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	for x := range w {
		for y := range h {
			img.Set(x, y, color.RGBA{uint8(x * 9), uint8(y * 5), 140, 255})
		}
	}
	return img
}

func avatarPNG(t *testing.T) []byte {
	var b bytes.Buffer
	if err := png.Encode(&b, avatarImage(12, 12)); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

func avatarJPEG(t *testing.T) []byte {
	var b bytes.Buffer
	if err := jpeg.Encode(&b, avatarImage(12, 12), nil); err != nil {
		t.Fatal(err)
	}
	return b.Bytes()
}

// uploadAvatar PUTs data as the multipart file part with a declared name and type.
func (e *chatEnv) uploadAvatar(id, filename, declared string, data []byte) (int, map[string]any) {
	e.t.Helper()
	return e.uploadAvatarTo("/personas/"+id+"/avatar", filename, declared, data)
}

func (e *chatEnv) uploadAvatarTo(path, filename, declared string, data []byte) (int, map[string]any) {
	e.t.Helper()
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	h := textproto.MIMEHeader{}
	h.Set("Content-Disposition", fmt.Sprintf(`form-data; name="file"; filename=%q`, filename))
	h.Set("Content-Type", declared)
	pw, err := mw.CreatePart(h)
	if err != nil {
		e.t.Fatal(err)
	}
	pw.Write(data)
	mw.Close()
	req, _ := http.NewRequest("PUT", e.srv.URL+"/api/v1"+path, &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	var out map[string]any
	raw, _ := io.ReadAll(res.Body)
	_ = json.Unmarshal(raw, &out)
	return res.StatusCode, out
}

func (e *chatEnv) getAvatar(id string) (*http.Response, []byte) {
	e.t.Helper()
	res, err := http.Get(e.srv.URL + "/api/v1/personas/" + id + "/avatar?v=1")
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res, b
}

func TestPersonaAvatarUploadServeAndReplace(t *testing.T) {
	e, fake := newAvatarEnv(t)
	ctx := context.Background()
	p := e.want("POST", "/personas", map[string]any{"name": "Work"}, http.StatusCreated)
	id := p["id"].(string)
	prefix := fmt.Sprintf("%s/personas/%s/%s/%s/", avatarBucket, e.me.WorkspaceID, e.me.ID, id)
	chat := e.newChat(map[string]any{"persona_id": id})

	// No avatar yet.
	if res, _ := e.getAvatar(id); res.StatusCode != http.StatusNotFound {
		t.Fatalf("avatar before upload: %d", res.StatusCode)
	}

	// A PNG declared as HTML is stored and served as the sniffed PNG.
	pngImg := avatarPNG(t)
	code, got := e.uploadAvatar(id, "evil.html", "text/html", pngImg)
	if code != 200 || got["avatar_url"] != fmt.Sprintf("/api/v1/personas/%s/avatar?v=2", id) || got["revision"].(float64) != 2 {
		t.Fatalf("upload png = %d %v", code, got)
	}
	first := fake.keys(prefix)
	if len(first) != 1 {
		t.Fatalf("stored keys %v", first)
	}
	res, body := e.getAvatar(id)
	if res.StatusCode != 200 || !bytes.Equal(body, pngImg) {
		t.Fatalf("get avatar = %d (%d bytes)", res.StatusCode, len(body))
	}
	for h, want := range map[string]string{
		"Content-Type": "image/png", "X-Content-Type-Options": "nosniff", "Content-Disposition": "inline",
		"Content-Security-Policy": "default-src 'none'; sandbox", "Cache-Control": "private, max-age=86400",
	} {
		if res.Header.Get(h) != want {
			t.Fatalf("%s = %q, want %q", h, res.Header.Get(h), want)
		}
	}
	// The chat's embedded summary carries the new URL.
	if s := e.want("GET", "/chats/"+chat["id"].(string), nil, 200)["persona"].(map[string]any); s["avatar_url"] != got["avatar_url"] {
		t.Fatalf("chat summary %v", s)
	}

	// Replacing it with a JPEG deletes the old blob.
	jpegImg := avatarJPEG(t)
	code, got = e.uploadAvatar(id, "photo.png", "image/png", jpegImg)
	if code != 200 || got["revision"].(float64) != 3 {
		t.Fatalf("replace = %d %v", code, got)
	}
	second := fake.keys(prefix)
	if len(second) != 1 || second[0] == first[0] {
		t.Fatalf("keys after replace %v (before %v)", second, first)
	}
	if res, body := e.getAvatar(id); res.StatusCode != 200 || res.Header.Get("Content-Type") != "image/jpeg" || !bytes.Equal(body, jpegImg) {
		t.Fatalf("get replaced avatar = %d %q", res.StatusCode, res.Header.Get("Content-Type"))
	}

	// WebP is accepted too.
	webp, _ := base64.StdEncoding.DecodeString("UklGRhoAAABXRUJQVlA4TA0AAAAvAAAAEAcQERGIiP4HAA==")
	if code, got := e.uploadAvatar(id, "a.webp", "application/octet-stream", webp); code != 200 {
		t.Fatalf("webp = %d %v", code, got)
	}
	if res, _ := e.getAvatar(id); res.Header.Get("Content-Type") != "image/webp" {
		t.Fatalf("webp served as %q", res.Header.Get("Content-Type"))
	}
	if keys := fake.keys(prefix); len(keys) != 1 {
		t.Fatalf("keys after webp %v", keys)
	}

	// The unsent-attachment sweep only reads chat_attachments: even with a
	// cutoff in the future it never returns or removes an avatar.
	swept, err := e.q.DeleteStaleChatAttachments(ctx, store.DeleteStaleChatAttachmentsParams{Cutoff: time.Now().Add(time.Hour), RowLimit: 1000})
	if err != nil {
		t.Fatal(err)
	}
	for _, k := range swept {
		if strings.HasPrefix(k, "personas/") {
			t.Fatalf("sweep returned avatar key %s", k)
		}
	}
	if res, _ := e.getAvatar(id); res.StatusCode != 200 || len(fake.keys(prefix)) != 1 {
		t.Fatalf("avatar after sweep = %d", res.StatusCode)
	}

	// Removing it deletes the blob; removing again is a no-op.
	rev := e.want("GET", "/personas/"+id, nil, 200)["revision"].(float64)
	del := e.want("DELETE", "/personas/"+id+"/avatar", nil, 200)
	if _, ok := del["avatar_url"]; ok || del["revision"].(float64) != rev+1 {
		t.Fatalf("delete avatar %v", del)
	}
	if keys := fake.keys(prefix); len(keys) != 0 {
		t.Fatalf("keys after delete %v", keys)
	}
	if res, _ := e.getAvatar(id); res.StatusCode != http.StatusNotFound {
		t.Fatalf("avatar after delete: %d", res.StatusCode)
	}
	if again := e.want("DELETE", "/personas/"+id+"/avatar", nil, 200); again["revision"].(float64) != rev+1 {
		t.Fatalf("second delete bumped the revision: %v", again)
	}

	// Deleting the persona deletes its avatar.
	if code, got := e.uploadAvatar(id, "a.png", "image/png", pngImg); code != 200 {
		t.Fatalf("re-upload = %d %v", code, got)
	}
	e.want("DELETE", "/personas/"+id, nil, http.StatusNoContent)
	if keys := fake.keys(prefix); len(keys) != 0 {
		t.Fatalf("keys after persona delete %v", keys)
	}
}

func TestPersonaAvatarRejectsUnsafeUploads(t *testing.T) {
	e, fake := newAvatarEnv(t)
	id := e.want("POST", "/personas", map[string]any{"name": "Work"}, http.StatusCreated)["id"].(string)
	pngImg, jpegImg := avatarPNG(t), avatarJPEG(t)
	var gifBuf bytes.Buffer
	if err := gif.Encode(&gifBuf, avatarImage(4, 4), nil); err != nil {
		t.Fatal(err)
	}
	const html = "<html><body><script>alert(document.cookie)</script></body></html>"
	oversize := append(append([]byte{}, pngImg...), make([]byte, personas.MaxAvatarBytes+1-len(pngImg))...)

	cases := []struct {
		name, filename, declared string
		data                     []byte
		code                     int
	}{
		{"svg", "a.svg", "image/svg+xml", []byte(`<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>`), 415},
		{"svg spoofed as png", "a.png", "image/png", []byte(`<svg xmlns="http://www.w3.org/2000/svg" onload="alert(1)"/>`), 415},
		{"html spoofed as jpeg", "a.jpg", "image/jpeg", []byte(html), 415},
		{"gif", "a.gif", "image/gif", gifBuf.Bytes(), 415},
		{"png+html polyglot", "a.png", "image/png", append(append([]byte{}, pngImg...), html...), 415},
		{"jpeg+html polyglot", "a.jpg", "image/jpeg", append(append([]byte{}, jpegImg...), html...), 415},
		{"over 1 MB", "big.png", "image/png", oversize, 413},
		{"empty", "a.png", "image/png", nil, 422},
	}
	for _, c := range cases {
		code, got := e.uploadAvatar(id, c.filename, c.declared, c.data)
		if code != c.code || got["field"] != "file" {
			t.Fatalf("%s: %d %v, want %d on file", c.name, code, got, c.code)
		}
	}
	// Nothing was stored and the persona is unchanged.
	if keys := fake.keys(avatarBucket + "/"); len(keys) != 0 {
		t.Fatalf("refused uploads stored %v", keys)
	}
	if p := e.want("GET", "/personas/"+id, nil, 200); p["revision"].(float64) != 1 || p["avatar_url"] != nil {
		t.Fatalf("persona after refused uploads %v", p)
	}

	// Only the file field is accepted.
	var body bytes.Buffer
	mw := multipart.NewWriter(&body)
	mw.WriteField("note", "hi")
	mw.Close()
	req, _ := http.NewRequest("PUT", e.srv.URL+"/api/v1/personas/"+id+"/avatar", &body)
	req.Header.Set("Content-Type", mw.FormDataContentType())
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != http.StatusUnprocessableEntity {
		t.Fatalf("form without file = %d", res.StatusCode)
	}
}

func TestPersonaAvatarIsOwnerOnly(t *testing.T) {
	e, fake := newAvatarEnv(t)
	ctx := context.Background()
	stranger := e.strangerPersona()
	// Give the other person's persona a real avatar.
	var ws, user uuid.UUID
	if err := e.pool.QueryRow(ctx, `SELECT workspace_id, user_id FROM personas WHERE id=$1`, stranger).Scan(&ws, &user); err != nil {
		t.Fatal(err)
	}
	key := personas.AvatarKey(personas.Owner{WorkspaceID: ws, UserID: user}, uuid.MustParse(stranger))
	fake.put(avatarBucket+"/"+key, avatarPNG(t), "image/png")
	if _, err := e.pool.Exec(ctx, `UPDATE personas SET avatar_key=$2, avatar_content_type='image/png' WHERE id=$1`, stranger, key); err != nil {
		t.Fatal(err)
	}

	for _, id := range []string{stranger, uuid.NewString()} {
		if res, _ := e.getAvatar(id); res.StatusCode != http.StatusNotFound {
			t.Fatalf("GET avatar of %s = %d", id, res.StatusCode)
		}
		if code, got := e.uploadAvatar(id, "a.png", "image/png", avatarPNG(t)); code != http.StatusNotFound {
			t.Fatalf("PUT avatar of %s = %d %v", id, code, got)
		}
		e.want("DELETE", "/personas/"+id+"/avatar", nil, http.StatusNotFound)
	}
	// The other person's avatar is untouched.
	var still *string
	if err := e.pool.QueryRow(ctx, `SELECT avatar_key FROM personas WHERE id=$1`, stranger).Scan(&still); err != nil || still == nil || *still != key {
		t.Fatalf("stranger avatar key %v, %v", still, err)
	}
	if keys := fake.keys(avatarBucket + "/" + key); len(keys) != 1 {
		t.Fatalf("stranger blob %v", keys)
	}
}
