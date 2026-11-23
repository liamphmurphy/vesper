package customapps

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

func TestHLSRelayMasterAndVariantRewriting(t *testing.T) {
	relay := &HLSRelay{
		ListenAddr:     "127.0.0.1:0",
		MasterCacheTTL: 5 * time.Second,
		MediaCacheTTL:  50 * time.Millisecond,
	}
	t.Cleanup(relay.Close)

	appID := uuid.New()
	var masterCalls atomic.Int32
	var mediaCalls atomic.Int32

	st, err := relay.Start(context.Background(), appID, HLSRelaySpec{
		Tool: "twitch_player",
		Args: map[string]any{"channel": "demo"},
	}, func(_ context.Context, tool string, args map[string]any) (any, error) {
		if tool != "twitch_player" {
			t.Errorf("tool = %q, want twitch_player", tool)
		}
		if args["channel"] != "demo" {
			t.Errorf("channel = %v, want demo", args["channel"])
		}
		switch args["relay_kind"] {
		case "master":
			masterCalls.Add(1)
			return map[string]any{
				"playlist": "#EXTM3U\n" +
					"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",NAME=\"main\",URI=\"https://cdn.example.com/audio.m3u8\"\n" +
					"#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080\n" +
					"https://video-weaver.example.com/v1/playlist/source.m3u8\n",
			}, nil
		case "media":
			n := mediaCalls.Add(1)
			prev := 0
			if m, ok := args["relay_state"].(map[string]any); ok {
				if c, ok := m["polls"].(int); ok {
					prev = c
				}
			}
			// Verify opaque relay_state persists across polls without hitting SQLite.
			if n == 2 && prev != 1 {
				t.Errorf("second poll saw relay_state.polls = %d, want 1", prev)
			}
			return map[string]any{
				"playlist": "#EXTM3U\n" +
					"#EXT-X-TARGETDURATION:2\n" +
					"#EXT-X-MEDIA-SEQUENCE:10\n" +
					"#EXT-X-MAP:URI=\"init.mp4\"\n" +
					"#EXTINF:2.000,live\n" +
					"seg10.m4s\n",
				"state":       map[string]any{"polls": prev + 1},
				"in_ad_break": n == 2,
				"ads_skipped": float64(n),
			}, nil
		default:
			t.Fatalf("unexpected relay_kind: %v", args["relay_kind"])
			return nil, nil
		}
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}
	if st.PlayURL != "vesper-hls:"+st.ID.String() {
		t.Fatalf("PlayURL = %q", st.PlayURL)
	}

	// Fetch master twice inside cache window -> single tool call, both variants rewritten.
	res, body := mustGET(t, st.LANURL)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("master status = %d: %s", res.StatusCode, body)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/vnd.apple.mpegurl") {
		t.Fatalf("Content-Type = %q", ct)
	}
	if !strings.Contains(body, `URI="variant/0.m3u8"`) || !strings.Contains(body, "\nvariant/1.m3u8\n") {
		t.Fatalf("rewritten master missing relative variants:\n%s", body)
	}
	res2, body2 := mustGET(t, st.LoopbackURL)
	if res2.StatusCode != http.StatusOK || body2 != body {
		t.Fatalf("cached master mismatch: %d", res2.StatusCode)
	}
	if masterCalls.Load() != 1 {
		t.Fatalf("masterCalls = %d, want 1 (cached)", masterCalls.Load())
	}

	// Fetch variant 1 (video): relative segment/map URIs resolve against upstream variant URL.
	variantURL := strings.TrimSuffix(st.LANURL, "master.m3u8") + "variant/1.m3u8"
	res, vbody := mustGET(t, variantURL)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("variant status = %d: %s", res.StatusCode, vbody)
	}
	if !strings.Contains(vbody, `URI="https://video-weaver.example.com/v1/playlist/init.mp4"`) {
		t.Fatalf("variant missing resolved MAP URI:\n%s", vbody)
	}
	if !strings.Contains(vbody, "https://video-weaver.example.com/v1/playlist/seg10.m4s\n") {
		t.Fatalf("variant missing resolved segment URI:\n%s", vbody)
	}

	// Wait past media cache TTL and poll again -> state persists and ad status updates.
	time.Sleep(70 * time.Millisecond)
	res, _ = mustGET(t, variantURL)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("second variant poll status = %d", res.StatusCode)
	}
	if mediaCalls.Load() != 2 {
		t.Fatalf("mediaCalls = %d, want 2", mediaCalls.Load())
	}
	got, err := relay.Get(appID, st.ID)
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !got.InAdBreak || got.AdsSkipped != 3 {
		t.Fatalf("ad status = (inAd=%v, skipped=%d), want (true, 3)", got.InAdBreak, got.AdsSkipped)
	}

	// Cross-app access and bad tokens are rejected.
	if _, err := relay.Get(uuid.New(), st.ID); err != apperr.ErrNotFound {
		t.Fatalf("cross-app Get err = %v, want ErrNotFound", err)
	}
	if err := relay.Stop(uuid.New(), st.ID); err != apperr.ErrNotFound {
		t.Fatalf("cross-app Stop err = %v, want ErrNotFound", err)
	}
	badURL := strings.Replace(st.LANURL, "/hls/", "/hls/0000", 1)
	if res, _ := mustGET(t, badURL); res.StatusCode != http.StatusNotFound {
		t.Fatalf("bad token status = %d, want 404", res.StatusCode)
	}

	// Stopping the last stream shuts down the ephemeral LAN listener cleanly.
	if err := relay.Stop(appID, st.ID); err != nil {
		t.Fatalf("Stop: %v", err)
	}
	if _, err := relay.Get(appID, st.ID); err != apperr.ErrNotFound {
		t.Fatalf("Get after Stop = %v, want ErrNotFound", err)
	}
	relay.mu.Lock()
	srvAfter := relay.srv
	relay.mu.Unlock()
	if srvAfter != nil {
		t.Fatalf("expected idle LAN listener to shut down when 0 streams remain")
	}
}

func TestHLSRelayProxySegmentsAndSecurity(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/seg1.ts":
			w.Header().Set("Content-Type", "video/mp2t")
			_, _ = w.Write([]byte("TS-SEGMENT-BYTES"))
		default:
			http.NotFound(w, r)
		}
	}))
	t.Cleanup(upstream.Close)

	// 1. Production mode rejects non-https / localhost URIs returned by a custom app.
	prodRelay := &HLSRelay{ListenAddr: "127.0.0.1:0"}
	t.Cleanup(prodRelay.Close)
	stProd, err := prodRelay.Start(context.Background(), uuid.New(), HLSRelaySpec{Tool: "p"}, func(_ context.Context, _ string, _ map[string]any) (any, error) {
		return map[string]any{
			"playlist": "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nhttps://127.0.0.1:8080/secret.m3u8\n",
		}, nil
	})
	if err != nil {
		t.Fatalf("Start prod: %v", err)
	}
	if res, _ := mustGET(t, stProd.LANURL); res.StatusCode != http.StatusBadGateway {
		t.Fatalf("loopback upstream URI status = %d, want 502", res.StatusCode)
	}

	// 2. ProxySegments mode rewrites segment URIs to ../seg/<key> and streams them.
	relay := &HLSRelay{
		ListenAddr:            "127.0.0.1:0",
		Transport:             http.DefaultTransport,
		AllowInsecureUpstream: true,
	}
	t.Cleanup(relay.Close)
	st, err := relay.Start(context.Background(), uuid.New(), HLSRelaySpec{
		Tool:          "p",
		ProxySegments: true,
	}, func(_ context.Context, _ string, args map[string]any) (any, error) {
		if args["relay_kind"] == "master" {
			return map[string]any{
				"playlist": "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\n" + upstream.URL + "/live.m3u8\n",
			}, nil
		}
		return map[string]any{
			"playlist": "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2.0,live\n" + upstream.URL + "/seg1.ts\n",
		}, nil
	})
	if err != nil {
		t.Fatalf("Start proxy: %v", err)
	}
	if res, _ := mustGET(t, st.LANURL); res.StatusCode != http.StatusOK {
		t.Fatalf("master = %d", res.StatusCode)
	}
	variantURL := strings.TrimSuffix(st.LANURL, "master.m3u8") + "variant/0.m3u8"
	res, vbody := mustGET(t, variantURL)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("variant = %d: %s", res.StatusCode, vbody)
	}
	if !strings.Contains(vbody, "../seg/1\n") {
		t.Fatalf("expected proxied segment path ../seg/1, got:\n%s", vbody)
	}
	segURL := strings.TrimSuffix(st.LANURL, "master.m3u8") + "seg/1"
	res, sbody := mustGET(t, segURL)
	if res.StatusCode != http.StatusOK || sbody != "TS-SEGMENT-BYTES" || res.Header.Get("Content-Type") != "video/mp2t" {
		t.Fatalf("proxied segment = %d %q %q", res.StatusCode, res.Header.Get("Content-Type"), sbody)
	}
}

func TestHLSRelayIdleTTLSweep(t *testing.T) {
	relay := &HLSRelay{
		ListenAddr: "127.0.0.1:0",
		StreamTTL:  60 * time.Millisecond,
	}
	t.Cleanup(relay.Close)

	appID := uuid.New()
	st, err := relay.Start(context.Background(), appID, HLSRelaySpec{Tool: "p"}, func(_ context.Context, _ string, _ map[string]any) (any, error) {
		return map[string]any{"playlist": "#EXTM3U\n"}, nil
	})
	if err != nil {
		t.Fatalf("Start: %v", err)
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		// Inspect map directly rather than calling Get (which refreshes lastAccess).
		relay.mu.Lock()
		_, exists := relay.streams[st.ID]
		srv := relay.srv
		relay.mu.Unlock()
		if !exists && srv == nil {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	t.Fatal("idle HLS relay stream was not swept after StreamTTL")
}

func TestHLSRelayCapabilityValidation(t *testing.T) {
	if err := ValidCapabilityKey("app.media:relay"); err != nil {
		t.Fatalf("ValidCapabilityKey(app.media:relay) = %v", err)
	}
	caps := DefaultCapabilities(Capabilities{"app.media:relay": agentdef.Allowed})
	if caps["app.media:relay"] != agentdef.RequiresApproval {
		t.Fatalf("DefaultCapabilities(app.media:relay) = %q, want requires_approval", caps["app.media:relay"])
	}
	if m := ModeFor(Capabilities{}, "app.media:relay"); m != agentdef.Denied {
		t.Fatalf("ModeFor empty caps = %q, want denied", m)
	}
}

func mustGET(t *testing.T, rawURL string) (*http.Response, string) {
	t.Helper()
	res, err := http.Get(rawURL)
	if err != nil {
		t.Fatalf("GET %s: %v", rawURL, err)
	}
	defer res.Body.Close()
	b, _ := io.ReadAll(res.Body)
	return res, string(b)
}
