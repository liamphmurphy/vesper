package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"image/png"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/looppack"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/fake"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
)

const loopPrefix = avatarBucket + "/persona-loops/"

type stateMediaEnv struct {
	*chatEnv
	blobs *fakeBlobs
	ctrl  *fake.Controller
	packs atomic.Int32
}

// newStateMediaEnv is a server with the fake video provider configured (or
// not) and looppack stubbed, so no test needs ffmpeg or a real provider.
func newStateMediaEnv(t *testing.T, configure bool) *stateMediaEnv {
	t.Helper()
	reg := media.NewRegistry()
	ctrl := &fake.Controller{}
	fake.RegisterVideo(reg, ctrl)
	k := make([]byte, 32)
	_, _ = rand.Read(k)
	box, err := secrets.NewBox(base64.StdEncoding.EncodeToString(k))
	if err != nil {
		t.Fatal(err)
	}
	env := &stateMediaEnv{blobs: newFakeBlobs(t), ctrl: ctrl}
	var srv *Server
	env.chatEnv = newChatEnvServer(t, nil, func(s *Server) {
		s.Secrets = &secrets.Service{Q: s.Q, Box: box}
		s.MediaRegistry = reg
		s.Blobs = env.blobs.Store
		s.ArtifactBucket = avatarBucket
		s.StateMediaPack = func(ctx context.Context, mp4 []byte, opts looppack.Options) (*looppack.Result, error) {
			n := env.packs.Add(1)
			if !bytes.Equal(mp4, fake.FakeVideoMP4) {
				return nil, errors.New("unexpected clip bytes")
			}
			return &looppack.Result{
				WebP:        fmt.Appendf(nil, "RIFF-webp-%d", n),
				HeadCropPNG: fmt.Appendf(nil, "png-head-%d", n),
				Width:       opts.TargetWidth, Height: opts.TargetHeight, Frames: 96, DurationMS: 4000, Backend: "stub",
			}, nil
		}
		srv = s
	})
	t.Cleanup(func() {
		if srv != nil {
			srv.CloseMedia()
		}
	})
	if configure {
		env.want("PUT", "/media/providers/fake-video", map[string]any{"secrets": map[string]any{"api_key": "k"}}, http.StatusOK)
		env.want("PUT", "/media/defaults/video", map[string]any{"provider_id": "fake-video"}, http.StatusOK)
	}
	return env
}

// personaWithPortrait makes a persona whose avatar is a 96px PNG.
func (e *stateMediaEnv) personaWithPortrait() string {
	e.t.Helper()
	p := e.want("POST", "/personas", map[string]any{"name": fmt.Sprintf("Loop %d", time.Now().UnixNano())}, http.StatusCreated)
	id := p["id"].(string)
	var b bytes.Buffer
	if err := png.Encode(&b, avatarImage(96, 96)); err != nil {
		e.t.Fatal(err)
	}
	if code, out := e.uploadAvatar(id, "me.png", "image/png", b.Bytes()); code != http.StatusOK {
		e.t.Fatalf("upload portrait = %d %v", code, out)
	}
	return id
}

// settle waits until no state is queued or running and returns the rows by state.
func (e *stateMediaEnv) settle(id string) map[string]map[string]any {
	e.t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		rows := e.want("GET", "/personas/"+id+"/state-media", nil, http.StatusOK)["states"].([]any)
		out := map[string]map[string]any{}
		busy := false
		for _, raw := range rows {
			r := raw.(map[string]any)
			out[r["state"].(string)] = r
			if s := r["status"]; s == "queued" || s == "running" {
				busy = true
			}
		}
		if !busy {
			return out
		}
		time.Sleep(15 * time.Millisecond)
	}
	e.t.Fatalf("state loops for %s never settled", id)
	return nil
}

func (e *stateMediaEnv) get(path string) (*http.Response, []byte) {
	e.t.Helper()
	res, err := http.Get(e.srv.URL + path)
	if err != nil {
		e.t.Fatal(err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res, b
}

var allStates = []string{"idle", "thinking", "reading", "coding", "creating", "needs_you"}

func TestPersonaStateMediaFullSet(t *testing.T) {
	e := newStateMediaEnv(t, true)
	id := e.personaWithPortrait()

	queued := e.want("POST", "/personas/"+id+"/state-media", map[string]any{}, http.StatusAccepted)["states"].([]any)
	if len(queued) != len(allStates) {
		t.Fatalf("queued %d states, want %d", len(queued), len(allStates))
	}
	rows := e.settle(id)
	for _, s := range allStates {
		r := rows[s]
		if r == nil || r["status"] != "ready" || r["loop_url"] == nil || r["head_url"] == nil || r["can_tweak"] != true {
			t.Fatalf("state %s = %v", s, r)
		}
		if r["width"].(float64) != 360 || r["height"].(float64) != 640 || r["backend"] != "stub" {
			t.Fatalf("state %s metadata = %v", s, r)
		}
	}

	// Every clip is bookended on the normalized portrait, in 9:16, fresh.
	calls := e.ctrl.VideoRequests()
	if len(calls) != len(allStates) {
		t.Fatalf("provider calls = %d", len(calls))
	}
	for _, c := range calls {
		if c.FirstFrame == nil || c.LastFrame == nil || !bytes.Equal(c.FirstFrame.Data, c.LastFrame.Data) || c.FirstFrame.ContentType != "image/jpeg" {
			t.Fatalf("bookends = %+v / %+v", c.FirstFrame, c.LastFrame)
		}
		if c.AspectRatio != "9:16" || c.PreviousInteractionID != "" || !strings.Contains(c.Prompt, "#3a3d40") {
			t.Fatalf("request = %+v", c)
		}
	}

	// The loop is served as WebP with the avatar safety headers.
	res, body := e.get(rows["thinking"]["loop_url"].(string))
	if res.StatusCode != 200 || res.Header.Get("Content-Type") != "image/webp" || res.Header.Get("X-Content-Type-Options") != "nosniff" ||
		!strings.Contains(res.Header.Get("Content-Security-Policy"), "sandbox") || !bytes.HasPrefix(body, []byte("RIFF-webp-")) {
		t.Fatalf("loop = %d %v %q", res.StatusCode, res.Header, body)
	}
	if res, _ := e.get(rows["idle"]["head_url"].(string)); res.StatusCode != 200 || res.Header.Get("Content-Type") != "image/png" {
		t.Fatalf("head = %d %v", res.StatusCode, res.Header)
	}

	// The persona carries the playback summary.
	p := e.want("GET", "/personas", nil, http.StatusOK)
	var sm map[string]any
	for _, raw := range p["personas"].([]any) {
		if pp := raw.(map[string]any); pp["id"] == id {
			sm, _ = pp["state_media"].(map[string]any)
		}
	}
	if sm == nil || sm["generating"] != false || len(sm["loops"].(map[string]any)) != len(allStates) || sm["head_url"] != rows["idle"]["head_url"] {
		t.Fatalf("state_media summary = %v", sm)
	}
	if n := len(e.blobs.keys(loopPrefix)); n != 2*len(allStates) {
		t.Fatalf("stored %d loop blobs, want %d", n, 2*len(allStates))
	}
}

func TestPersonaStateMediaTweakReplacesOneState(t *testing.T) {
	e := newStateMediaEnv(t, true)
	id := e.personaWithPortrait()
	e.want("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"idle", "thinking"}}, http.StatusAccepted)
	before := e.settle(id)
	oldThinking := before["thinking"]["loop_url"].(string)
	_, oldBytes := e.get(oldThinking)
	blobsBefore := e.blobs.keys(loopPrefix)

	e.want("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"thinking"}, "tweak": "Tap the chin more slowly."}, http.StatusAccepted)
	after := e.settle(id)
	if after["thinking"]["status"] != "ready" || after["thinking"]["loop_url"] == oldThinking || after["thinking"]["tweak"] != "Tap the chin more slowly." {
		t.Fatalf("thinking after tweak = %v", after["thinking"])
	}
	if after["idle"]["loop_url"] != before["idle"]["loop_url"] {
		t.Fatalf("idle changed: %v -> %v", before["idle"]["loop_url"], after["idle"]["loop_url"])
	}
	calls := e.ctrl.VideoRequests()
	last := calls[len(calls)-1]
	if !strings.HasPrefix(last.PreviousInteractionID, "fake-interaction-") || !strings.HasPrefix(last.Prompt, "Tap the chin more slowly.") || last.FirstFrame == nil {
		t.Fatalf("tweak request = %+v", last)
	}
	// The replaced loop and head blobs are gone; the count is unchanged.
	blobsAfter := e.blobs.keys(loopPrefix)
	if len(blobsAfter) != len(blobsBefore) {
		t.Fatalf("blobs %d -> %d", len(blobsBefore), len(blobsAfter))
	}
	// The state's path now serves the new loop.
	if _, b := e.get(after["thinking"]["loop_url"].(string)); bytes.Equal(b, oldBytes) {
		t.Fatalf("thinking still serves the replaced loop %q", b)
	}

	// A tweak needs an earlier clip.
	e.invalid("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"coding"}, "tweak": "faster"}, "tweak", "no earlier clip")
}

func TestPersonaStateMediaFailureIsolation(t *testing.T) {
	e := newStateMediaEnv(t, true)
	id := e.personaWithPortrait()
	failReading := func(r media.VideoRequest) error {
		if strings.Contains(r.Prompt, "is reading") {
			return &media.ProviderError{Provider: "fake", Kind: media.ErrKindFiltered, Message: "The clip was blocked by the safety filter."}
		}
		return nil
	}
	e.ctrl.SetVideo(failReading, nil)

	e.want("POST", "/personas/"+id+"/state-media", map[string]any{}, http.StatusAccepted)
	rows := e.settle(id)
	if r := rows["reading"]; r["status"] != "failed" || r["error_kind"] != "filtered" || r["loop_url"] != nil {
		t.Fatalf("reading = %v", r)
	}
	for _, s := range allStates {
		if s != "reading" && rows[s]["status"] != "ready" {
			t.Fatalf("%s = %v, want ready despite reading failing", s, rows[s])
		}
	}

	// A failed regeneration keeps the state's earlier loop.
	good := rows["idle"]["loop_url"].(string)
	e.ctrl.SetVideo(func(media.VideoRequest) error { return errors.New("upstream 500") }, nil)
	e.want("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"idle"}}, http.StatusAccepted)
	rows = e.settle(id)
	if r := rows["idle"]; r["status"] != "failed" || r["loop_url"] != good || r["error"] != "upstream 500" {
		t.Fatalf("idle after failed regeneration = %v", r)
	}
	if res, _ := e.get(good); res.StatusCode != 200 {
		t.Fatalf("earlier loop not served after failed retry: %d", res.StatusCode)
	}
}

func TestPersonaStateMediaClearAndDelete(t *testing.T) {
	e := newStateMediaEnv(t, true)
	id := e.personaWithPortrait()
	e.want("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"idle", "coding"}}, http.StatusAccepted)
	rows := e.settle(id)
	if n := len(e.blobs.keys(loopPrefix + id)); n != 4 {
		t.Fatalf("blobs = %d", n)
	}

	left := e.want("DELETE", "/personas/"+id+"/state-media?state=coding", nil, http.StatusOK)["states"].([]any)
	if len(left) != 1 || left[0].(map[string]any)["state"] != "idle" {
		t.Fatalf("after clearing coding: %v", left)
	}
	if res, _ := e.get(rows["coding"]["loop_url"].(string)); res.StatusCode != http.StatusNotFound {
		t.Fatalf("cleared loop served: %d", res.StatusCode)
	}
	if n := len(e.blobs.keys(loopPrefix + id)); n != 2 {
		t.Fatalf("blobs after clear = %d", n)
	}

	// Clearing a generating state cancels it and leaves no blob behind.
	block := make(chan struct{})
	e.ctrl.SetVideo(nil, block)
	e.want("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"creating"}}, http.StatusAccepted)
	e.want("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"creating"}}, http.StatusConflict)
	e.want("DELETE", "/personas/"+id+"/state-media?state=creating", nil, http.StatusOK)
	close(block)
	e.ctrl.SetVideo(nil, nil)
	time.Sleep(50 * time.Millisecond)
	if got := e.settle(id); got["creating"] != nil || len(got) != 1 {
		t.Fatalf("after clearing a generating state: %v", got)
	}

	// Deleting the persona removes every loop blob.
	e.want("DELETE", "/personas/"+id, nil, http.StatusNoContent)
	deadline := time.Now().Add(2 * time.Second)
	for len(e.blobs.keys(loopPrefix+id)) > 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if left := e.blobs.keys(loopPrefix + id); len(left) != 0 {
		t.Fatalf("blobs left after persona delete: %v", left)
	}
}

func TestPersonaStateMediaRefusals(t *testing.T) {
	e := newStateMediaEnv(t, false)
	id := e.personaWithPortrait()
	// No video provider configured.
	out := e.want("POST", "/personas/"+id+"/state-media", map[string]any{}, http.StatusConflict)
	if !strings.Contains(out["message"].(string), "Video provider") {
		t.Fatalf("no provider: %v", out)
	}
	e.want("PUT", "/media/providers/fake-video", map[string]any{"secrets": map[string]any{"api_key": "k"}}, http.StatusOK)

	// No portrait.
	bare := e.want("POST", "/personas", map[string]any{"name": "Bare"}, http.StatusCreated)["id"].(string)
	out = e.want("POST", "/personas/"+bare+"/state-media", map[string]any{}, http.StatusConflict)
	if !strings.Contains(out["message"].(string), "portrait") {
		t.Fatalf("no portrait: %v", out)
	}
	e.want("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"dancing"}}, http.StatusUnprocessableEntity)
	e.want("GET", "/personas/"+id+"/state-media/idle/loop", nil, http.StatusNotFound)
	if got := e.want("GET", "/personas/"+id+"/state-media", nil, http.StatusOK)["states"].([]any); len(got) != 0 {
		t.Fatalf("rows after refusals: %v", got)
	}
	if len(e.ctrl.VideoRequests()) != 0 {
		t.Fatal("a refused request reached the provider")
	}
}
