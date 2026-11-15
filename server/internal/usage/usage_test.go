package usage

import (
	"bufio"
	"context"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

var now = time.Date(2026, 11, 9, 18, 0, 0, 0, time.UTC)

func TestParseClaudeUsage(t *testing.T) {
	resp := `{"session":{},"subscription_type":"max","rate_limits_available":true,"rate_limits":{
		"five_hour":{"utilization":38.4,"resets_at":"2026-11-09T21:20:00Z"},
		"seven_day":{"utilization":61,"resets_at":"2026-11-12T08:00:00Z"},
		"seven_day_oauth_apps":null,
		"seven_day_opus":{"utilization":54,"resets_at":null},
		"seven_day_sonnet":null}}`
	s := ParseClaudeUsage(json.RawMessage(resp), now)
	if !s.Available || s.Plan != "max" || s.Harness != "claude-code" {
		t.Fatalf("snapshot = %+v", s)
	}
	if len(s.Windows) != 3 {
		t.Fatalf("windows = %+v", s.Windows)
	}
	w := s.Windows[0]
	if w.ID != "five_hour" || w.Kind != Session || w.Label != "Session" || w.UsedPercent != 38.4 || w.ResetsAt == nil || !w.ResetsAt.Equal(time.Date(2026, 11, 9, 21, 20, 0, 0, time.UTC)) {
		t.Fatalf("session window = %+v", w)
	}
	if s.Windows[2].Label != "Weekly · Opus" || s.Windows[2].ResetsAt != nil {
		t.Fatalf("opus window = %+v", s.Windows[2])
	}
}

func TestParseClaudeUsageSignedOut(t *testing.T) {
	// What claude 2.1.316 answered in a container with no plan login.
	resp := `{"session":{"total_cost_usd":0,"total_api_duration_ms":0,"total_duration_ms":121,"total_lines_added":0,"total_lines_removed":0,"model_usage":{}},"subscription_type":null,"rate_limits_available":false,"rate_limits":null,"behaviors":null}`
	s := ParseClaudeUsage(json.RawMessage(resp), now)
	if s.Available || s.Plan != "" || len(s.Windows) != 0 {
		t.Fatalf("snapshot = %+v", s)
	}
}

func TestFromClaudeEvent(t *testing.T) {
	cases := []struct {
		name    string
		info    string
		ok      bool
		used    float64
		limited bool
	}{
		{"fraction", `{"status":"allowed_warning","resetsAt":1794266400,"rateLimitType":"five_hour","utilization":0.82}`, true, 82, false},
		{"percent", `{"status":"allowed","rateLimitType":"seven_day","utilization":45}`, true, 45, false},
		{"rejected", `{"status":"rejected","resetsAt":1794266400,"rateLimitType":"five_hour"}`, true, 100, true},
		{"no figure", `{"status":"allowed","rateLimitType":"five_hour"}`, false, 0, false},
		{"unknown window", `{"status":"allowed","rateLimitType":"overage","utilization":0.1}`, false, 0, false},
		{"garbage", `[`, false, 0, false},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			ev, ok := FromClaudeEvent(json.RawMessage(c.info))
			if ok != c.ok {
				t.Fatalf("ok = %v", ok)
			}
			if !ok {
				return
			}
			if ev.Window.UsedPercent != c.used || ev.Limited != c.limited {
				t.Fatalf("event = %+v", ev)
			}
		})
	}
	ev, _ := FromClaudeEvent(json.RawMessage(`{"status":"allowed","resetsAt":1794266400,"rateLimitType":"five_hour","utilization":0.5}`))
	if ev.Window.ResetsAt == nil || ev.Window.ResetsAt.Unix() != 1794266400 {
		t.Fatalf("resets_at = %v", ev.Window.ResetsAt)
	}
}

func TestParseCodexRateLimits(t *testing.T) {
	result := `{"rateLimits":{"limitId":"codex","planType":"plus","primary":{"usedPercent":46,"windowDurationMins":300,"resetsAt":1794266400},"secondary":{"usedPercent":72,"windowDurationMins":10080,"resetsAt":1794405600}},
		"rateLimitsByLimitId":{"codex":{"limitId":"codex","planType":"plus","primary":{"usedPercent":46,"windowDurationMins":300,"resetsAt":1794266400},"secondary":{"usedPercent":72,"windowDurationMins":10080,"resetsAt":1794405600}},
		"codex_other":{"limitId":"codex_other","primary":{"usedPercent":3,"windowDurationMins":300}}}}`
	s := ParseCodexRateLimits(json.RawMessage(result), now)
	if !s.Available || s.Plan != "plus" || len(s.Windows) != 2 {
		t.Fatalf("snapshot = %+v", s)
	}
	if s.Windows[0].ID != "codex_300" || s.Windows[0].Kind != Session || s.Windows[0].UsedPercent != 46 {
		t.Fatalf("session = %+v", s.Windows[0])
	}
	if s.Windows[1].ID != "codex_10080" || s.Windows[1].Kind != Weekly || s.Windows[1].UsedPercent != 72 {
		t.Fatalf("weekly = %+v", s.Windows[1])
	}
	// An older Codex sends only rateLimits.
	s = ParseCodexRateLimits(json.RawMessage(`{"rateLimits":{"primary":{"usedPercent":120,"windowDurationMins":300}}}`), now)
	if !s.Available || len(s.Windows) != 1 || s.Windows[0].UsedPercent != 100 {
		t.Fatalf("legacy = %+v", s)
	}
	// Another allowance's bucket alone is not the main one.
	s = ParseCodexRateLimits(json.RawMessage(`{"rateLimits":{"limitId":"codex_other","primary":{"usedPercent":1,"windowDurationMins":300}}}`), now)
	if s.Available {
		t.Fatalf("other bucket = %+v", s)
	}
}

func TestMergeAndCurrent(t *testing.T) {
	past, future := now.Add(-time.Minute), now.Add(time.Hour)
	old := []Window{
		{ID: "seven_day", Kind: Weekly, Label: "Weekly", UsedPercent: 60, ResetsAt: &future},
		{ID: "five_hour", Kind: Session, Label: "Session", UsedPercent: 90, ResetsAt: &past},
		{ID: "seven_day_opus", Kind: Weekly, Label: "Weekly · Opus", UsedPercent: 10},
	}
	got := Merge(old, []Window{{ID: "seven_day", Kind: Weekly, Label: "Weekly", UsedPercent: 64, ResetsAt: &future}}, now)
	if len(got) != 2 || got[0].ID != "seven_day" || got[0].UsedPercent != 64 || got[1].ID != "seven_day_opus" {
		t.Fatalf("merge = %+v", got)
	}
	got = Merge(got, []Window{{ID: "five_hour", Kind: Session, Label: "Session", UsedPercent: 5, ResetsAt: &future}}, now)
	if got[0].ID != "five_hour" {
		t.Fatalf("session first: %+v", got)
	}
}

// fakeCLI answers each line written to it with canned output. Answers are
// queued, so a caller that writes several requests before reading can't
// deadlock the synchronous pipes.
func fakeCLI(t *testing.T, answer func(line string) []string) (io.Writer, io.Reader) {
	inR, inW := io.Pipe()
	outR, outW := io.Pipe()
	queue := make(chan string, 64)
	go func() {
		defer close(queue)
		s := bufio.NewScanner(inR)
		for s.Scan() {
			for _, o := range answer(s.Text()) {
				queue <- o
			}
		}
	}()
	go func() {
		defer outW.Close()
		for o := range queue {
			if _, err := outW.Write([]byte(o + "\n")); err != nil {
				return
			}
		}
	}()
	t.Cleanup(func() { inW.Close(); outR.Close() })
	return inW, outR
}

func TestConverseClaude(t *testing.T) {
	in, out := fakeCLI(t, func(line string) []string {
		switch {
		case strings.Contains(line, `"initialize"`):
			return []string{`{"type":"control_response","response":{"subtype":"success","request_id":"initialize","response":{}}}`}
		case strings.Contains(line, `"get_usage"`):
			return []string{`{"type":"system","subtype":"status"}`,
				`{"type":"control_response","response":{"subtype":"success","request_id":"usage","response":{"subscription_type":"pro","rate_limits_available":true,"rate_limits":{"five_hour":{"utilization":12,"resets_at":"2026-11-09T21:20:00Z"}}}}}`}
		}
		return nil
	})
	s, err := converseClaude(in, out, func() time.Time { return now })
	if err != nil || s.Plan != "pro" || len(s.Windows) != 1 || s.Windows[0].UsedPercent != 12 {
		t.Fatalf("snapshot = %+v, err = %v", s, err)
	}
}

func TestConverseClaudeOutdated(t *testing.T) {
	in, out := fakeCLI(t, func(line string) []string {
		if strings.Contains(line, `"get_usage"`) {
			return []string{`{"type":"control_response","response":{"subtype":"error","request_id":"usage","error":"Unsupported control request subtype: get_usage"}}`}
		}
		return nil
	})
	if _, err := converseClaude(in, out, func() time.Time { return now }); err != ErrOutdated {
		t.Fatalf("err = %v", err)
	}
}

func TestConverseCodex(t *testing.T) {
	in, out := fakeCLI(t, func(line string) []string {
		switch {
		case strings.Contains(line, `"initialize"`):
			return []string{`{"id":1,"result":{"userAgent":"vesper/0.167.0"}}`, `{"method":"configWarning","params":{}}`}
		case strings.Contains(line, `"account/rateLimits/read"`):
			return []string{`{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":46,"windowDurationMins":300}}}}`}
		}
		return nil
	})
	s, err := converseCodex(in, out, func() time.Time { return now })
	if err != nil || len(s.Windows) != 1 || s.Windows[0].UsedPercent != 46 {
		t.Fatalf("snapshot = %+v, err = %v", s, err)
	}
}

func TestConverseCodexSignedOut(t *testing.T) {
	in, out := fakeCLI(t, func(line string) []string {
		switch {
		case strings.Contains(line, `"initialize"`):
			return []string{`{"id":1,"result":{}}`}
		case strings.Contains(line, `"account/rateLimits/read"`):
			// What codex 0.167.0 answered with no login.
			return []string{`{"error":{"code":-32600,"message":"codex account authentication required to read rate limits"},"id":2}`}
		}
		return nil
	})
	s, err := converseCodex(in, out, func() time.Time { return now })
	if err != ErrSignedOut || s.Harness != "codex" {
		t.Fatalf("snapshot = %+v, err = %v", s, err)
	}
}

func TestProbeEnv(t *testing.T) {
	env := probeEnv([]string{"PATH=/bin", "CLAUDECODE=1", "CLAUDE_CODE_ENTRYPOINT=cli", "HOME=/h"})
	if strings.Join(env, " ") != "PATH=/bin HOME=/h DISABLE_AUTOUPDATER=1" {
		t.Fatalf("env = %v", env)
	}
}

// The API only ever checks a stand-in harness on the host; with no
// RUNNER_*_BIN it must not fall through to a real, logged-in CLI on PATH.
func TestProbeRefusesWithoutFakeBinary(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"claude", "codex"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n: >\"$0.ran\"\n"), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PATH", dir)
	t.Setenv("RUNNER_CLAUDE_BIN", "")
	t.Setenv("RUNNER_CODEX_BIN", "")
	for _, h := range []string{agentdef.HarnessClaudeCode, agentdef.HarnessCodex, agentdef.HarnessAntigravity} {
		if _, err := Probe(context.Background(), h); err == nil {
			t.Errorf("%s: probed without a fake binary", h)
		}
	}
	for _, name := range []string{"claude", "codex"} {
		if _, err := os.Stat(filepath.Join(dir, name+".ran")); err == nil {
			t.Errorf("%s on PATH ran", name)
		}
	}
}

func TestParseAntigravityUsage(t *testing.T) {
	line := `{"event":"command_result","command":{"name":"usage","data":{"plan_name":"Pro","groups":[` +
		`{"display_name":"Gemini","refresh_window_label":"5h","remaining_fraction":0.62,"reset_time":"2026-11-09T21:20:00Z"},` +
		`{"display_name":"Claude / GPT","buckets":[{"label":"Weekly","remaining_percentage":25,"reset_time":"2026-11-12T08:00:00Z"}]}` +
		`]}}}`
	s := ParseAntigravityUsage(json.RawMessage(line), now)
	if !s.Available || s.Harness != agentdef.HarnessAntigravity || s.Plan != "Pro" || len(s.Windows) != 2 {
		t.Fatalf("snapshot = %+v", s)
	}
	if s.Windows[0].Kind != Session || s.Windows[0].Label != "Gemini" || int(s.Windows[0].UsedPercent+0.5) != 38 {
		t.Fatalf("session window = %+v", s.Windows[0])
	}
	if s.Windows[1].Kind != Weekly || s.Windows[1].Label != "Claude / GPT · Weekly" || s.Windows[1].UsedPercent != 75 {
		t.Fatalf("weekly window = %+v", s.Windows[1])
	}
	empty := ParseAntigravityUsage(json.RawMessage(`{"event":"command_result","command":{"name":"usage","data":{"groups":[]}}}`), now)
	if empty.Available || len(empty.Windows) != 0 {
		t.Fatalf("empty groups must not be available: %+v", empty)
	}
}

func TestConverseAntigravity(t *testing.T) {
	out := strings.NewReader(`{"event":"command_result","command":{"name":"usage","data":{"groups":[{"display_name":"Gemini","window":"5h","used_percentage":28,"reset_time":"2026-11-09T21:20:00Z"}]}}}` + "\n")
	s, err := converseAntigravity(out, func() time.Time { return now })
	if err != nil || !s.Available || len(s.Windows) != 1 || s.Windows[0].UsedPercent != 28 {
		t.Fatalf("snapshot = %+v, err = %v", s, err)
	}
	errOut := strings.NewReader(`{"event":"result","result":{"status":"ERROR","error":"authentication failed or timed out"}}` + "\n")
	if _, err := converseAntigravity(errOut, func() time.Time { return now }); err != ErrSignedOut {
		t.Fatalf("err = %v, want ErrSignedOut", err)
	}
}
