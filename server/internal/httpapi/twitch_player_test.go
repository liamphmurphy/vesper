package httpapi

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/liamphmurphy/vesper/server/internal/artifacts"
	"github.com/liamphmurphy/vesper/server/internal/runs"
	"github.com/liamphmurphy/vesper/server/internal/secrets"
	"github.com/liamphmurphy/vesper/server/internal/seed"
	"github.com/liamphmurphy/vesper/server/internal/store"
	"github.com/liamphmurphy/vesper/server/internal/testdb"
	"github.com/liamphmurphy/vesper/server/internal/tracker"
	"github.com/liamphmurphy/vesper/server/internal/twitchplayer"
)

func TestTwitchPlayerSessionsAPI(t *testing.T) {
	ctx := context.Background()
	pool := testdb.New(t)
	arts := &artifacts.Service{Pool: pool}
	if _, err := seed.Run(ctx, pool, seed.Options{Demo: true, Artifacts: arts}); err != nil {
		t.Fatal(err)
	}
	q := store.New(pool)
	tr := &tracker.Service{Pool: pool}
	rs := &runs.Service{Pool: pool, Tracker: tr, Artifacts: arts}

	var primaryHasAd atomic.Bool
	primaryHasAd.Store(true)

	var fakeURL string
	mux := http.NewServeMux()
	mux.HandleFunc("POST /gql", func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Variables struct {
				PlayerType string `json:"playerType"`
			} `json:"variables"`
		}
		_ = json.NewDecoder(r.Body).Decode(&req)
		tok, _ := json.Marshal(map[string]string{"pt": req.Variables.PlayerType})
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"data": map[string]any{
				"streamPlaybackAccessToken": map[string]any{
					"value":     string(tok),
					"signature": "sig",
				},
			},
		})
	})
	mux.HandleFunc("GET /api/channel/hls/{ch}", func(w http.ResponseWriter, r *http.Request) {
		var p struct {
			PT string `json:"pt"`
		}
		_ = json.Unmarshal([]byte(r.URL.Query().Get("token")), &p)
		if p.PT == "" {
			p.PT = "site"
		}
		_, _ = w.Write([]byte("#EXTM3U\n" +
			"#EXT-X-MEDIA:TYPE=VIDEO,GROUP-ID=\"chunked\",NAME=\"1080p60 (source)\",AUTOSELECT=YES,DEFAULT=YES\n" +
			"#EXT-X-STREAM-INF:BANDWIDTH=6000000,RESOLUTION=1920x1080,FRAME-RATE=60.000,VIDEO=\"chunked\"\n" +
			fakeURL + "/edge/" + p.PT + "/source.m3u8\n"))
	})
	mux.HandleFunc("GET /edge/{pt}/source.m3u8", func(w http.ResponseWriter, r *http.Request) {
		pt := r.PathValue("pt")
		if pt == "site" && primaryHasAd.Load() {
			_, _ = w.Write([]byte("#EXTM3U\n#EXT-X-DATERANGE:ID=\"stitched-ad-1\",CLASS=\"twitch-stitched-ad\",DURATION=20\n#EXTINF:2.0,Amazon\nad.ts\n"))
			return
		}
		_, _ = w.Write([]byte("#EXTM3U\n#EXTINF:2.0,live\n" + pt + "-seg.ts\n"))
	})

	fakeSrv := httptest.NewServer(mux)
	defer fakeSrv.Close()
	fakeURL = fakeSrv.URL

	h := (&Server{
		AnonymousAPI: true,
		Pool:         pool,
		Q:            q,
		Runs:         rs,
		Tracker:      tr,
		Artifacts:    arts,
		Secrets:      &secrets.Service{Q: q, Box: testBox(t)},
		TwitchPlayer: &twitchplayer.Service{
			GQLURL:       fakeSrv.URL + "/gql",
			UsherBaseURL: fakeSrv.URL,
			AllowLocal:   true,
		},
	}).Handler()

	doReq := func(method, path, body string) *httptest.ResponseRecorder {
		rec := httptest.NewRecorder()
		req := httptest.NewRequest(method, "/api/v1"+path, strings.NewReader(body))
		if body != "" {
			req.Header.Set("Content-Type", "application/json")
		}
		h.ServeHTTP(rec, req)
		return rec
	}

	// Invalid channel returns 422.
	if rec := doReq(http.MethodPost, "/twitch/sessions", `{"kind":"live","channel":"bad channel!"}`); rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("invalid channel = %d (%s), want 422", rec.Code, rec.Body.String())
	}

	// Custom app bridge blocks /api/v1/twitch/sessions.
	if _, _, err := validateCustomAppAPIRequest(http.MethodPost, "/api/v1/twitch/sessions"); err == nil {
		t.Fatal("expected validateCustomAppAPIRequest to block /api/v1/twitch/sessions")
	}

	// Create session -> 201.
	createRec := doReq(http.MethodPost, "/twitch/sessions", `{"kind":"live","channel":"shroud"}`)
	if createRec.Code != http.StatusCreated {
		t.Fatalf("create = %d (%s), want 201", createRec.Code, createRec.Body.String())
	}
	var sess twitchplayer.SessionInfo
	if err := json.Unmarshal(createRec.Body.Bytes(), &sess); err != nil {
		t.Fatal(err)
	}

	// Fetch master playlist.
	masterRec := doReq(http.MethodGet, "/twitch/sessions/"+sess.ID+"/master.m3u8", "")
	if masterRec.Code != http.StatusOK || !strings.Contains(masterRec.Body.String(), "variant/0.m3u8") {
		t.Fatalf("master = %d (%s)", masterRec.Code, masterRec.Body.String())
	}

	// Fetch variant -> ad on site swaps to embed backup with custom response headers.
	varRec := doReq(http.MethodGet, "/twitch/sessions/"+sess.ID+"/variant/0.m3u8", "")
	if varRec.Code != http.StatusOK {
		t.Fatalf("variant swapped = %d (%s)", varRec.Code, varRec.Body.String())
	}
	if got := varRec.Header().Get("X-Vesper-Twitch-Ad"); got != "swapped" {
		t.Fatalf("X-Vesper-Twitch-Ad = %q, want swapped", got)
	}
	if got := varRec.Header().Get("X-Vesper-Twitch-Player-Type"); got != "embed" {
		t.Fatalf("X-Vesper-Twitch-Player-Type = %q, want embed", got)
	}
	if got := varRec.Header().Get("X-Vesper-Twitch-Using-Backup"); got != "true" {
		t.Fatalf("X-Vesper-Twitch-Using-Backup = %q, want true", got)
	}

	// Disable ad swap via PATCH and verify active ad headers.
	patchRec := doReq(http.MethodPatch, "/twitch/sessions/"+sess.ID, `{"ad_swap_enabled":false}`)
	if patchRec.Code != http.StatusOK {
		t.Fatalf("patch = %d (%s)", patchRec.Code, patchRec.Body.String())
	}
	varActiveRec := doReq(http.MethodGet, "/twitch/sessions/"+sess.ID+"/variant/0.m3u8", "")
	if varActiveRec.Code != http.StatusOK {
		t.Fatalf("variant active = %d (%s)", varActiveRec.Code, varActiveRec.Body.String())
	}
	if got := varActiveRec.Header().Get("X-Vesper-Twitch-Ad"); got != "active" {
		t.Fatalf("X-Vesper-Twitch-Ad = %q, want active", got)
	}
	if got := varActiveRec.Header().Get("X-Vesper-Twitch-Ad-Duration"); got != "20.0" {
		t.Fatalf("X-Vesper-Twitch-Ad-Duration = %q, want 20.0", got)
	}

	// Delete session -> 204, subsequent GET -> 404.
	if delRec := doReq(http.MethodDelete, "/twitch/sessions/"+sess.ID, ""); delRec.Code != http.StatusNoContent {
		t.Fatalf("delete = %d, want 204", delRec.Code)
	}
	if getRec := doReq(http.MethodGet, "/twitch/sessions/"+sess.ID, ""); getRec.Code != http.StatusNotFound {
		t.Fatalf("get after delete = %d, want 404", getRec.Code)
	}
}
