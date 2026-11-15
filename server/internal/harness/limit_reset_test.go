package harness

import (
	"testing"
	"time"
)

func TestLimitReset(t *testing.T) {
	la, err := time.LoadLocation("America/Los_Angeles")
	if err != nil {
		t.Skip("no tzdata")
	}
	now := time.Date(2026, 11, 6, 15, 0, 0, 0, la) // 3pm Pacific
	at := func(loc *time.Location, d, h, m int) time.Time { return time.Date(2026, 11, d, h, m, 0, 0, loc) }
	tests := []struct {
		name, msg string
		want      time.Time
		ok        bool
	}{
		{"claude zone and minutes", "You've hit your session limit · resets 9:20pm (America/Los_Angeles)", at(la, 6, 21, 20), true},
		{"claude no minutes", "You've hit your session limit · resets 9pm (America/Los_Angeles)", at(la, 6, 21, 0), true},
		{"claude no zone", "limit · resets 9:20pm", at(la, 6, 21, 20), true},
		{"claude unknown zone", "limit · resets 9:20pm (Mars/Olympus)", at(la, 6, 21, 20), true},
		{"other zone", "resets 11:30pm (UTC)", at(time.UTC, 6, 23, 30), true},
		{"codex", "You've hit your usage limit. Upgrade or try again at 11:32 PM.", at(la, 6, 23, 32), true},
		{"earlier than now is tomorrow", "resets 9am (America/Los_Angeles)", at(la, 7, 9, 0), true},
		{"exactly now is tomorrow", "resets 3pm", at(la, 7, 15, 0), true},
		{"midnight", "resets 12am", at(la, 7, 0, 0), true},
		{"noon", "resets 12pm", at(la, 7, 12, 0), true},
		{"gemini retry delay (agy)", "Error 429, Message: You exceeded your current quota, please check your plan and billing details., Status: RESOURCE_EXHAUSTED, Details: [map[@type:type.googleapis.com/google.rpc.RetryInfo retryDelay:41s]]", now.Add(41 * time.Second), true},
		{"gemini retry delay as JSON", `{"@type":"type.googleapis.com/google.rpc.RetryInfo","retryDelay":"2.5s"}`, now.Add(2500 * time.Millisecond), true},
		{"agy quota reset after duration", "Your quota will reset after 3h12m05s.", now.Add(3*time.Hour + 12*time.Minute + 5*time.Second), true},
		{"retry in minutes", "Rate limit exceeded, retry after 2 minutes 30 seconds", now.Add(150 * time.Second), true},
		{"iso reset timestamp", "Quota exhausted, reset_time: 2026-11-06T23:30:00Z", time.Date(2026, 11, 6, 23, 30, 0, 0, time.UTC), true},
		{"unparsable", "You've hit your usage limit.", time.Time{}, false},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, ok := LimitReset(tt.msg, now)
			if ok != tt.ok || (ok && !got.Equal(tt.want)) {
				t.Fatalf("got %v %v, want %v %v", got, ok, tt.want, tt.ok)
			}
		})
	}
}

func TestUsageLimitSessionMarker(t *testing.T) {
	if !UsageLimit("You've hit your session limit · resets 9:20pm") {
		t.Fatal("session limit not detected")
	}
}
