package httpapi

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"image/png"
	"io"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/media"
	"github.com/liamphmurphy/vesper/server/internal/media/looppack"
	"github.com/liamphmurphy/vesper/server/internal/media/providers/fake"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/statemedia"
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
			// The provider's placeholder, or a clip a test uploaded (stateClip).
			if !bytes.Equal(mp4, fake.FakeVideoMP4) && (len(mp4) < 8 || string(mp4[4:8]) != "ftyp") {
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

var allStates = []string{"idle", "thinking", "reading", "coding", "creating", "needs_you", "talking", "complete"}

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
	// A tweak is a fresh, bookended generation with the tweak as extra direction,
	// never a continuation: continuing the conversation made Omni return the old
	// take followed by the new one, which looped as both.
	if last.PreviousInteractionID != "" || !strings.Contains(last.Prompt, "is thinking") || !strings.HasSuffix(last.Prompt, "Additional direction: Tap the chin more slowly.") || last.FirstFrame == nil || last.LastFrame == nil {
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

func TestPersonaRevealPace(t *testing.T) {
	e := newStateMediaEnv(t, true)
	id := e.personaWithPortrait()
	p := e.want("GET", "/personas", nil, http.StatusOK)
	var rev float64
	for _, raw := range p["personas"].([]any) {
		if pp := raw.(map[string]any); pp["id"] == id {
			if pp["reveal_pace"] != "auto" {
				t.Fatalf("default reveal_pace = %v, want auto", pp["reveal_pace"])
			}
			rev = pp["revision"].(float64)
		}
	}
	got := e.want("PATCH", "/personas/"+id, map[string]any{"revision": rev, "reveal_pace": "deliberate"}, http.StatusOK)
	if got["reveal_pace"] != "deliberate" {
		t.Fatalf("reveal_pace after patch = %v", got["reveal_pace"])
	}
	// Leaving it out of a later patch keeps it.
	got = e.want("PATCH", "/personas/"+id, map[string]any{"revision": got["revision"], "name": "Renamed"}, http.StatusOK)
	if got["reveal_pace"] != "deliberate" {
		t.Fatalf("reveal_pace after unrelated patch = %v", got["reveal_pace"])
	}
	e.want("PATCH", "/personas/"+id, map[string]any{"revision": got["revision"], "reveal_pace": "warp"}, http.StatusUnprocessableEntity)
}

func TestPersonaStateMediaLoopLength(t *testing.T) {
	e := newStateMediaEnv(t, true)
	id := e.personaWithPortrait()
	var rev float64
	for _, raw := range e.want("GET", "/personas", nil, http.StatusOK)["personas"].([]any) {
		if p := raw.(map[string]any); p["id"] == id {
			if p["loop_seconds"] != float64(8) {
				t.Fatalf("default loop_seconds = %v, want 8", p["loop_seconds"])
			}
			rev = p["revision"].(float64)
		}
	}
	e.want("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"idle"}}, http.StatusAccepted)
	e.settle(id)
	if c := e.ctrl.VideoRequests(); len(c) != 1 || c[0].DurationSec != 8 || !strings.Contains(c[0].Prompt, "8 second seamless loop") {
		t.Fatalf("default request = %+v", c)
	}

	// Longer loops get more from each generation when the daily quota is the limit.
	got := e.want("PATCH", "/personas/"+id, map[string]any{"revision": rev, "loop_seconds": 10}, http.StatusOK)
	if got["loop_seconds"] != float64(10) {
		t.Fatalf("loop_seconds after patch = %v", got["loop_seconds"])
	}
	e.want("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"thinking"}, "tweak": ""}, http.StatusAccepted)
	e.settle(id)
	if c := e.ctrl.VideoRequests(); len(c) != 2 || c[1].DurationSec != 10 || !strings.Contains(c[1].Prompt, "10 second seamless loop") {
		t.Fatalf("10s request = %+v", c[len(c)-1])
	}

	// Omni only pins first and last frames (which makes a loop) up to 10s.
	e.invalid("PATCH", "/personas/"+id, map[string]any{"revision": got["revision"], "loop_seconds": 11}, "loop_seconds", "4 to 10")
	e.invalid("PATCH", "/personas/"+id, map[string]any{"revision": got["revision"], "loop_seconds": 3}, "loop_seconds", "4 to 10")
}

func TestPersonaStateMediaEnabledToggle(t *testing.T) {
	e := newStateMediaEnv(t, true)
	id := e.personaWithPortrait()

	// Enabled by default.
	p := e.want("GET", "/personas/"+id, nil, http.StatusOK)
	if p["state_media_enabled"] != true {
		t.Fatalf("default state_media_enabled = %v, want true", p["state_media_enabled"])
	}

	// Generate one state loop and verify Persona carries its summary.
	e.want("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"idle"}}, http.StatusAccepted)
	e.settle(id)

	p = e.want("GET", "/personas/"+id, nil, http.StatusOK)
	sm, ok := p["state_media"].(map[string]any)
	if !ok {
		t.Fatalf("expected state_media when enabled, got %v", p["state_media"])
	}
	idleURL, _ := sm["loops"].(map[string]any)["idle"].(string)
	if idleURL == "" {
		t.Fatalf("expected idle loop URL when enabled, got %v", sm)
	}

	// Disabling hides state_media from Persona payloads while keeping the stored rows and blobs.
	disabled := e.want("PATCH", "/personas/"+id, map[string]any{"revision": p["revision"], "state_media_enabled": false}, http.StatusOK)
	if disabled["state_media_enabled"] != false {
		t.Fatalf("state_media_enabled after disable = %v, want false", disabled["state_media_enabled"])
	}
	if disabled["state_media"] != nil {
		t.Fatalf("PATCH returned state_media while disabled: %v", disabled["state_media"])
	}
	for _, raw := range e.want("GET", "/personas", nil, http.StatusOK)["personas"].([]any) {
		if pp := raw.(map[string]any); pp["id"] == id {
			if pp["state_media_enabled"] != false || pp["state_media"] != nil {
				t.Fatalf("GET /personas while disabled: enabled=%v state_media=%v", pp["state_media_enabled"], pp["state_media"])
			}
		}
	}
	// Settings list still shows the generated loop so nothing was deleted.
	states := e.want("GET", "/personas/"+id+"/state-media", nil, http.StatusOK)["states"].([]any)
	if len(states) != 1 || states[0].(map[string]any)["status"] != "ready" || states[0].(map[string]any)["loop_url"] != idleURL {
		t.Fatalf("stored state media after disable = %v", states)
	}

	// Unrelated patch keeps state_media_enabled=false.
	renamed := e.want("PATCH", "/personas/"+id, map[string]any{"revision": disabled["revision"], "name": "Renamed"}, http.StatusOK)
	if renamed["state_media_enabled"] != false || renamed["state_media"] != nil {
		t.Fatalf("unrelated patch changed state_media_enabled: enabled=%v state_media=%v", renamed["state_media_enabled"], renamed["state_media"])
	}

	// Re-enabling brings the exact same generated loop back with no new video request.
	reenabled := e.want("PATCH", "/personas/"+id, map[string]any{"revision": renamed["revision"], "state_media_enabled": true}, http.StatusOK)
	if reenabled["state_media_enabled"] != true {
		t.Fatalf("state_media_enabled after re-enable = %v, want true", reenabled["state_media_enabled"])
	}
	sm2, ok := reenabled["state_media"].(map[string]any)
	if !ok || sm2["loops"].(map[string]any)["idle"] != idleURL {
		t.Fatalf("expected original idle loop %q back after re-enable, got %v", idleURL, reenabled["state_media"])
	}
	if len(e.ctrl.VideoRequests()) != 1 {
		t.Fatalf("expected 1 video request total, got %d", len(e.ctrl.VideoRequests()))
	}
}

// stateClip is an MP4's box skeleton, enough for the container checks: an
// ftyp, and a moov with the length and one portrait video track of codec.
func stateClip(codec string, durMS int) []byte {
	box := func(typ string, payload ...[]byte) []byte {
		b := binary.BigEndian.AppendUint32(nil, uint32(8+len(bytes.Join(payload, nil))))
		return append(append(b, typ...), bytes.Join(payload, nil)...)
	}
	u32 := func(v int) []byte { return binary.BigEndian.AppendUint32(nil, uint32(v)) }
	mvhd := append(append(append(make([]byte, 12), u32(1000)...), u32(durMS)...), make([]byte, 80)...)
	tkhd := append(append(make([]byte, 76), u32(720<<16)...), u32(1280<<16)...)
	hdlr := append(append(make([]byte, 8), "vide"...), make([]byte, 13)...)
	stsd := append(append(make([]byte, 4), u32(1)...), box(codec, make([]byte, 78))...)
	trak := box("trak", box("tkhd", tkhd), box("mdia", box("hdlr", hdlr), box("minf", box("stbl", box("stsd", stsd)))))
	return append(append(box("ftyp", []byte("isom"), u32(512), []byte("isomavc1")), box("moov", box("mvhd", mvhd), trak)...), box("mdat", make([]byte, 64))...)
}

func (e *stateMediaEnv) uploadClip(id, state string, clip []byte) (int, map[string]any) {
	e.t.Helper()
	return e.uploadAvatarTo("/personas/"+id+"/state-media/"+state+"/clip", "take.mp4", "video/mp4", clip)
}

func TestPersonaStateMediaUploadClip(t *testing.T) {
	// No video provider and no portrait: an uploaded clip needs neither.
	e := newStateMediaEnv(t, false)
	id := e.want("POST", "/personas", map[string]any{"name": "Uploader"}, http.StatusCreated)["id"].(string)

	code, out := e.uploadClip(id, "idle", stateClip("avc1", 8000))
	if code != http.StatusAccepted {
		t.Fatalf("upload = %d %v", code, out)
	}
	rows := e.settle(id)
	idle := rows["idle"]
	if idle["status"] != "ready" || idle["provider_id"] != statemedia.UploadProvider || idle["can_tweak"] != false || idle["loop_url"] == nil || idle["head_url"] == nil {
		t.Fatalf("idle after upload = %v", idle)
	}
	if len(rows) != 1 || e.packs.Load() != 1 || len(e.ctrl.VideoRequests()) != 0 {
		t.Fatalf("rows %d, packs %d, provider calls %d; want only idle, packed once, no generation", len(rows), e.packs.Load(), len(e.ctrl.VideoRequests()))
	}
	if res, b := e.get(idle["loop_url"].(string)); res.StatusCode != http.StatusOK || !bytes.HasPrefix(b, []byte("RIFF-webp")) {
		t.Fatalf("loop = %d %q", res.StatusCode, b)
	}
	// The persona's playback summary picks it up like a generated loop.
	p := e.want("GET", "/personas/"+id, nil, http.StatusOK)
	if loops, _ := p["state_media"].(map[string]any)["loops"].(map[string]any); loops["idle"] != idle["loop_url"] {
		t.Fatalf("persona state_media = %v", p["state_media"])
	}

	// A second upload replaces the loop and its blobs.
	if code, out := e.uploadClip(id, "idle", stateClip("hvc1", 10_400)); code != http.StatusAccepted {
		t.Fatalf("H.265 re-upload = %d %v", code, out)
	}
	if again := e.settle(id)["idle"]; again["loop_url"] == idle["loop_url"] || len(e.blobs.keys(loopPrefix+id)) != 2 {
		t.Fatalf("after re-upload: %v, blobs %v", again, e.blobs.keys(loopPrefix+id))
	}
}

func TestPersonaStateMediaUploadRefusals(t *testing.T) {
	e := newStateMediaEnv(t, true)
	id := e.personaWithPortrait()
	oversized := append(stateClip("avc1", 8000), make([]byte, statemedia.MaxClipBytes)...)
	for name, tc := range map[string]struct {
		state string
		clip  []byte
		want  string
	}{
		"empty":         {"idle", nil, "required"},
		"not a video":   {"idle", []byte("GIF89a not a movie"), "MP4 or MOV"},
		"vp9":           {"idle", stateClip("vp09", 8000), "H.264 or H.265"},
		"too long":      {"idle", stateClip("avc1", 15_000), "1 to 10 seconds"},
		"too short":     {"idle", stateClip("avc1", 400), "1 to 10 seconds"},
		"too large":     {"idle", oversized, "64 MB"},
		"unknown state": {"dancing", stateClip("avc1", 8000), "unknown state"},
	} {
		code, out := e.uploadClip(id, tc.state, tc.clip)
		if code != http.StatusUnprocessableEntity || !strings.Contains(fmt.Sprint(out["message"]), tc.want) {
			t.Errorf("%s: %d %v, want 422 mentioning %q", name, code, out, tc.want)
		}
	}
	if got := e.want("GET", "/personas/"+id+"/state-media", nil, http.StatusOK)["states"].([]any); len(got) != 0 || e.packs.Load() != 0 {
		t.Fatalf("a refused clip was queued: rows %v, packs %d", got, e.packs.Load())
	}

	// An upload can't race a generation of the same state.
	block := make(chan struct{})
	e.ctrl.SetVideo(nil, block)
	e.want("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"coding"}}, http.StatusAccepted)
	if code, out := e.uploadClip(id, "coding", stateClip("avc1", 8000)); code != http.StatusConflict {
		t.Fatalf("upload while generating = %d %v", code, out)
	}
	close(block)
	e.ctrl.SetVideo(nil, nil)
	e.settle(id)

	// An uploaded loop has no provider conversation to tweak.
	if code, out := e.uploadClip(id, "idle", stateClip("avc1", 8000)); code != http.StatusAccepted {
		t.Fatalf("upload = %d %v", code, out)
	}
	e.settle(id)
	e.invalid("POST", "/personas/"+id+"/state-media", map[string]any{"states": []string{"idle"}, "tweak": "slower"}, "tweak", "no earlier clip")

	// Someone else's persona, or none, is a 404.
	for _, other := range []string{e.strangerPersona(), uuid.NewString()} {
		if code, out := e.uploadClip(other, "idle", stateClip("avc1", 8000)); code != http.StatusNotFound {
			t.Fatalf("upload to %s = %d %v", other, code, out)
		}
	}
}

func TestPersonaStateMediaPrompts(t *testing.T) {
	e := newStateMediaEnv(t, false)
	id := e.want("POST", "/personas", map[string]any{"name": "Prompted"}, http.StatusCreated)["id"].(string)
	e.want("PATCH", "/personas/"+id, map[string]any{"loop_seconds": 6, "revision": 1}, http.StatusOK)
	prompts := e.want("GET", "/personas/"+id+"/state-media", nil, http.StatusOK)["prompts"].(map[string]any)
	if len(prompts) != len(allStates) {
		t.Fatalf("prompts for %d states, want %d", len(prompts), len(allStates))
	}
	// The prompt to paste elsewhere is the one Vesper itself would send.
	if prompts["talking"] != statemedia.Prompt(statemedia.StateTalking, 6) {
		t.Fatalf("talking prompt = %q", prompts["talking"])
	}
}
