package twitchplayer

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/google/uuid"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

func TestParseMasterPlaylistAndRenderProxiedMaster(t *testing.T) {
	raw := `#EXTM3U
#EXT-X-TWITCH-INFO:NODE="video-edge-abc"
#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="chunked",NAME="1080p60 (source)",AUTOSELECT=YES,DEFAULT=YES
#EXT-X-STREAM-INF:BANDWIDTH=6500000,RESOLUTION=1920x1080,CODECS="avc1.64002A,mp4a.40.2",VIDEO="chunked",FRAME-RATE=60.000
https://video-weaver.example/playlist/source.m3u8
#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="480p30",NAME="480p",AUTOSELECT=YES,DEFAULT=NO
#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=852x480,CODECS="avc1.4D401F,mp4a.40.2",VIDEO="480p30",FRAME-RATE=30.000
/relative/480p.m3u8
#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID="audio_only",NAME="Audio Only",AUTOSELECT=NO,DEFAULT=NO
#EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS="mp4a.40.2",VIDEO="audio_only"
https://video-weaver.example/playlist/audio.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=640x360,VIDEO="360p"
http://insecure.example/360p.m3u8
`

	variants, err := ParseMasterPlaylist(raw, "https://usher.ttvnw.net/api/channel/hls/test.m3u8", false)
	if err != nil {
		t.Fatalf("ParseMasterPlaylist failed: %v", err)
	}
	if len(variants) != 3 {
		t.Fatalf("got %d variants, want 3 (insecure http should be skipped when allowLocal=false)", len(variants))
	}
	if variants[0].Name != "1080p60 (source)" || variants[0].AudioOnly || variants[0].Resolution != "1920x1080" {
		t.Fatalf("unexpected source variant: %+v", variants[0])
	}
	if variants[1].URL != "https://usher.ttvnw.net/relative/480p.m3u8" || variants[1].Name != "480p" {
		t.Fatalf("unexpected relative variant: %+v", variants[1])
	}
	if !variants[2].AudioOnly || variants[2].GroupID != "audio_only" || variants[2].Name != "Audio Only" {
		t.Fatalf("unexpected audio variant: %+v", variants[2])
	}

	rendered := RenderProxiedMaster(variants)
	for _, want := range []string{
		"#EXTM3U",
		`NAME="1080p60 (source)"`,
		"variant/0.m3u8",
		"variant/1.m3u8",
		"variant/2.m3u8",
	} {
		if !strings.Contains(rendered, want) {
			t.Fatalf("rendered master missing %q:\n%s", want, rendered)
		}
	}
}

func TestInspectMediaPlaylist(t *testing.T) {
	t.Run("clean live stream", func(t *testing.T) {
		raw := `#EXTM3U
#EXT-X-TARGETDURATION:2
#EXT-X-MEDIA-SEQUENCE:100
#EXT-X-TWITCH-PREFETCH:prefetch1.ts
#EXTINF:2.000,live
seg100.ts
#EXTINF:2.000,live
seg101.ts`
		info := InspectMediaPlaylist(raw)
		if info.AdActive || info.AdSegments != 0 || info.TotalSegments != 2 {
			t.Fatalf("expected clean playlist, got %+v", info)
		}
	})

	t.Run("twitch stitched ad daterange and amazon title", func(t *testing.T) {
		raw := `#EXTM3U
#EXT-X-DATERANGE:ID="stitched-ad-123",CLASS="twitch-stitched-ad",DURATION=30.000,X-TV-TWITCH-AD-URL="https://ads.example"
#EXTINF:2.000,Amazon
ad1.ts
#EXTINF:2.000,Amazon
ad2.ts`
		info := InspectMediaPlaylist(raw)
		if !info.AdActive || info.AdSegments != 2 || info.DurationSec != 30 {
			t.Fatalf("expected active ad with duration 30, got %+v", info)
		}
	})

	t.Run("cue-out open vs closed before clean segments", func(t *testing.T) {
		openCue := `#EXTM3U
#EXT-X-CUE-OUT:15.0
#EXTINF:2.000,
seg1.ts`
		infoOpen := InspectMediaPlaylist(openCue)
		if !infoOpen.AdActive || infoOpen.DurationSec != 15 {
			t.Fatalf("expected open cue-out ad active, got %+v", infoOpen)
		}

		closedCue := `#EXTM3U
#EXT-X-CUE-OUT:15.0
#EXTINF:2.000,live
seg1.ts
#EXT-X-CUE-IN
#EXTINF:2.000,live
seg2.ts`
		infoClosed := InspectMediaPlaylist(closedCue)
		if infoClosed.AdActive {
			t.Fatalf("expected closed cue-out followed by clean segments to be clean, got %+v", infoClosed)
		}
	})

	t.Run("vod playlist", func(t *testing.T) {
		vod := `#EXTM3U
#EXT-X-PLAYLIST-TYPE:VOD
#EXTINF:10.000,
vod1.ts
#EXT-X-ENDLIST`
		info := InspectMediaPlaylist(vod)
		if info.AdActive || info.TotalSegments != 1 {
			t.Fatalf("expected clean VOD playlist, got %+v", info)
		}
	})
}

func TestRewriteMediaPlaylist(t *testing.T) {
	raw := `#EXTM3U
#EXT-X-MAP:URI="init-0.mp4"
#EXT-X-TWITCH-PREFETCH:https://edge.example/live/pref1.ts
#EXTINF:2.000,live
seg-1.ts
/abs/seg-2.ts
https://cdn.other.example/seg-3.ts`

	cleanOut := RewriteMediaPlaylist(raw, "https://video-edge.example/hls/stream.m3u8", false)
	for _, want := range []string{
		`#EXT-X-MAP:URI="https://video-edge.example/hls/init-0.mp4"`,
		`#EXT-X-TWITCH-PREFETCH:https://edge.example/live/pref1.ts`,
		`https://video-edge.example/hls/seg-1.ts`,
		`https://video-edge.example/abs/seg-2.ts`,
		`https://cdn.other.example/seg-3.ts`,
	} {
		if !strings.Contains(cleanOut, want) {
			t.Fatalf("clean rewrite missing %q:\n%s", want, cleanOut)
		}
	}

	adOut := RewriteMediaPlaylist(raw, "https://video-edge.example/hls/stream.m3u8", true)
	if strings.Contains(adOut, "#EXT-X-TWITCH-PREFETCH:") {
		t.Fatalf("expected prefetch lines stripped during ad:\n%s", adOut)
	}
}

func TestServiceLiveAdSwapFallbackAndVod(t *testing.T) {
	var primaryAd atomic.Bool
	var backupAd atomic.Bool
	var offlineChannel atomic.Bool
	var lastTokenQuery string

	var srvURL string
	mux := http.NewServeMux()
	mux.HandleFunc("POST /gql", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Variables struct {
				IsLive     bool   `json:"isLive"`
				Login      string `json:"login"`
				IsVod      bool   `json:"isVod"`
				VodID      string `json:"vodID"`
				PlayerType string `json:"playerType"`
			} `json:"variables"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			t.Fatalf("decode gql: %v", err)
		}
		w.Header().Set("Content-Type", "application/json")
		if req.Variables.IsVod {
			lastTokenQuery = "vod:" + req.Variables.VodID
			_ = json.NewEncoder(w).Encode(map[string]any{
				"data": map[string]any{
					"videoPlaybackAccessToken": map[string]any{
						"value":     `{"vod":` + req.Variables.VodID + `}`,
						"signature": "vodsig",
					},
				},
			})
			return
		}
		lastTokenQuery = "live:" + req.Variables.PlayerType
		tokVal, _ := json.Marshal(map[string]string{"player_type": req.Variables.PlayerType})
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": map[string]any{
				"streamPlaybackAccessToken": map[string]any{
					"value":     string(tokVal),
					"signature": "sig_" + req.Variables.PlayerType,
				},
			},
		})
	})

	mux.HandleFunc("GET /api/channel/hls/{chan}", func(w http.ResponseWriter, r *http.Request) {
		if offlineChannel.Load() {
			http.NotFound(w, r)
			return
		}
		tok := r.URL.Query().Get("token")
		var parsed struct {
			PlayerType string `json:"player_type"`
		}
		_ = json.Unmarshal([]byte(tok), &parsed)
		pt := parsed.PlayerType
		if pt == "" {
			pt = "site"
		}
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = w.Write([]byte("#EXTM3U\n" +
			"#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"chunked\",NAME=\"1080p60 (source)\",AUTOSELECT=YES,DEFAULT=YES\n" +
			"#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,FRAME-RATE=60.000,VIDEO=\"chunked\"\n" +
			srvURL + "/edge/" + pt + "/1080p.m3u8\n" +
			"#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"480p30\",NAME=\"480p\",AUTOSELECT=YES,DEFAULT=NO\n" +
			"#EXT-X-STREAM-INF:BANDWIDTH=1200000,RESOLUTION=852x480,FRAME-RATE=30.000,VIDEO=\"480p30\"\n" +
			srvURL + "/edge/" + pt + "/480p.m3u8\n"))
	})

	mux.HandleFunc("GET /vod/{id}", func(w http.ResponseWriter, r *http.Request) {
		q := r.URL.Query()
		if q.Get("nauth") == "" || q.Get("nauthsig") == "" {
			http.Error(w, "missing nauth", http.StatusBadRequest)
			return
		}
		_, _ = w.Write([]byte("#EXTM3U\n" +
			"#EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x1080,VIDEO=\"chunked\"\n" +
			srvURL + "/edge/vod/chunked.m3u8\n"))
	})

	mux.HandleFunc("GET /edge/{pt}/{file}", func(w http.ResponseWriter, r *http.Request) {
		pt := r.PathValue("pt")
		if pt == "site" && primaryAd.Load() {
			_, _ = w.Write([]byte("#EXTM3U\n#EXT-X-DATERANGE:ID=\"stitched-ad-1\",CLASS=\"twitch-stitched-ad\",DURATION=30\n#EXTINF:2.0,Amazon\nad-seg.ts\n"))
			return
		}
		if pt == "embed" && backupAd.Load() {
			_, _ = w.Write([]byte("#EXTM3U\n#EXT-X-DATERANGE:ID=\"stitched-ad-2\",CLASS=\"twitch-stitched-ad\",DURATION=30\n#EXTINF:2.0,Amazon\nad-backup.ts\n"))
			return
		}
		if pt == "popout" {
			http.Error(w, "unavailable", http.StatusServiceUnavailable)
			return
		}
		if pt == "autoplay" && backupAd.Load() {
			_, _ = w.Write([]byte("#EXTM3U\n#EXT-X-DATERANGE:ID=\"stitched-ad-3\",CLASS=\"twitch-stitched-ad\",DURATION=30\n#EXTINF:2.0,Amazon\nad-autoplay.ts\n"))
			return
		}
		_, _ = w.Write([]byte("#EXTM3U\n#EXT-X-TWITCH-PREFETCH:prefetch.ts\n#EXTINF:2.0,live\n" + pt + "-seg.ts\n"))
	})

	srv := httptest.NewServer(mux)
	defer srv.Close()
	srvURL = srv.URL

	svc := &Service{
		GQLURL:       srv.URL + "/gql",
		UsherBaseURL: srv.URL,
		AllowLocal:   true,
	}
	user1 := uuid.New()
	user2 := uuid.New()
	ctx := context.Background()

	// 1. Live session & clean delivery.
	sess, err := svc.CreateSession(ctx, user1, CreateSessionInput{
		Kind:        "live",
		Channel:     "CohhCarnage",
		BackupTypes: []string{"embed", "popout", "autoplay"},
	})
	if err != nil {
		t.Fatalf("CreateSession live failed: %v", err)
	}
	if sess.Channel != "cohhcarnage" || len(sess.Variants) != 2 {
		t.Fatalf("unexpected session info: %+v", sess)
	}
	vClean, err := svc.VariantPlaylist(ctx, user1, sess.ID, 0)
	if err != nil || vClean.AdStatus != "none" || vClean.UsingBackup || !strings.Contains(vClean.Body, srvURL+"/edge/site/site-seg.ts") {
		t.Fatalf("expected clean primary playlist, got err=%v res=%+v", err, vClean)
	}

	// Cross-user isolation.
	if _, err := svc.GetSession(user2, sess.ID); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for another user, got %v", err)
	}

	// 2. Stitched ad on primary triggers backup embed swap.
	primaryAd.Store(true)
	vSwapped, err := svc.VariantPlaylist(ctx, user1, sess.ID, 0)
	if err != nil {
		t.Fatalf("VariantPlaylist swapped failed: %v", err)
	}
	if !vSwapped.UsingBackup || vSwapped.AdStatus != "swapped" || vSwapped.ActiveType != "embed" || vSwapped.AdActive {
		t.Fatalf("expected swapped embed backup, got %+v", vSwapped)
	}
	if !strings.Contains(vSwapped.Body, srvURL+"/edge/embed/embed-seg.ts") {
		t.Fatalf("expected rewritten backup URL in body:\n%s", vSwapped.Body)
	}
	infoAfterSwap, _ := svc.GetSession(user1, sess.ID)
	if infoAfterSwap.AdSwapsCount != 1 {
		t.Fatalf("expected AdSwapsCount=1, got %d", infoAfterSwap.AdSwapsCount)
	}

	// 3. When all backup types also have ads, returns active ad and increments AdBreaksHidden.
	backupAd.Store(true)
	vActive, err := svc.VariantPlaylist(ctx, user1, sess.ID, 0)
	if err != nil {
		t.Fatalf("VariantPlaylist active ad failed: %v", err)
	}
	if !vActive.AdActive || vActive.UsingBackup || vActive.AdStatus != "active" || vActive.AdDurationSec != 30 {
		t.Fatalf("expected active ad fallback, got %+v", vActive)
	}
	infoActive, _ := svc.GetSession(user1, sess.ID)
	if infoActive.AdBreaksHidden != 1 {
		t.Fatalf("expected AdBreaksHidden=1, got %d", infoActive.AdBreaksHidden)
	}

	// Clearing ad restores clean state.
	primaryAd.Store(false)
	backupAd.Store(false)
	vRecovered, err := svc.VariantPlaylist(ctx, user1, sess.ID, 0)
	if err != nil || vRecovered.AdActive || vRecovered.AdStatus != "none" {
		t.Fatalf("expected recovery to none, got err=%v res=%+v", err, vRecovered)
	}

	// 4. VOD session uses videoPlaybackAccessToken & nauth/nauthsig.
	vodSess, err := svc.CreateSession(ctx, user1, CreateSessionInput{Kind: "vod", VodID: "23456789"})
	if err != nil {
		t.Fatalf("CreateSession vod failed: %v", err)
	}
	if !strings.HasPrefix(lastTokenQuery, "vod:") || len(vodSess.Variants) != 1 {
		t.Fatalf("expected VOD session, got query=%q info=%+v", lastTokenQuery, vodSess)
	}

	// 5. Offline channel returns ErrNotFound.
	offlineChannel.Store(true)
	if _, err := svc.CreateSession(ctx, user1, CreateSessionInput{Kind: "live", Channel: "offlinetest"}); !errors.Is(err, apperr.ErrNotFound) {
		t.Fatalf("expected ErrNotFound for offline channel, got %v", err)
	}
}
