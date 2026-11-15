// Package usage reads how much of a harness's plan allowance is left: the
// session and weekly windows a Claude or Codex subscription has. Readings come
// from the CLIs themselves, never from their private HTTP endpoints, so the
// CLI keeps owning authentication and token refresh:
//
//   - actively, through each CLI's control protocol (Probe): Claude's
//     get_usage control request and Codex app-server's account/rateLimits/read.
//     Neither sends a prompt or spends tokens.
//   - passively, from the rate_limit_event lines Claude's stream-json output
//     carries during every run (FromClaudeEvent).
package usage

import (
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
)

// Kind groups windows by length.
type Kind string

const (
	Session Kind = "session" // a few hours (Claude's and Codex's 5h windows)
	Weekly  Kind = "weekly"
	Other   Kind = "other"
)

// Window is one allowance window.
type Window struct {
	ID          string     `json:"id"`
	Kind        Kind       `json:"kind"`
	Label       string     `json:"label"`
	UsedPercent float64    `json:"used_percent"`
	ResetsAt    *time.Time `json:"resets_at,omitempty"`
}

// Snapshot is one reading of a harness's allowance.
type Snapshot struct {
	Harness string
	// Plan is the subscription's name ("max", "plus"), empty when unknown.
	Plan string
	// Available is false when plan limits don't apply or can't be read: an
	// API key, a login without the profile scope, or a signed-out CLI.
	Available  bool
	Windows    []Window
	ObservedAt time.Time
}

var claudeWindows = []struct {
	key   string
	kind  Kind
	label string
}{
	{"five_hour", Session, "Session"},
	{"seven_day", Weekly, "Weekly"},
	{"seven_day_opus", Weekly, "Weekly · Opus"},
	{"seven_day_sonnet", Weekly, "Weekly · Sonnet"},
}

func claudeWindow(key string) (Kind, string, bool) {
	for _, w := range claudeWindows {
		if w.key == key {
			return w.kind, w.label, true
		}
	}
	return "", "", false
}

func clampPercent(v float64) float64 {
	if math.IsNaN(v) || math.IsInf(v, 0) {
		return 0
	}
	return math.Min(100, math.Max(0, v))
}

// timeValue reads a reset time given as RFC 3339 text or Unix seconds.
func timeValue(raw json.RawMessage) *time.Time {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		if t, err := time.Parse(time.RFC3339Nano, s); err == nil {
			return &t
		}
		if n, err := strconv.ParseFloat(s, 64); err == nil {
			raw = json.RawMessage(strconv.FormatFloat(n, 'f', -1, 64))
		} else {
			return nil
		}
	}
	var n float64
	if json.Unmarshal(raw, &n) != nil || n <= 0 {
		return nil
	}
	if n > 1e12 { // milliseconds
		n /= 1000
	}
	t := time.Unix(int64(n), 0).UTC()
	return &t
}

// ParseClaudeUsage reads the response of Claude Code's get_usage control
// request. utilization there is a percentage.
func ParseClaudeUsage(resp json.RawMessage, now time.Time) Snapshot {
	var r struct {
		SubscriptionType    *string                    `json:"subscription_type"`
		RateLimitsAvailable bool                       `json:"rate_limits_available"`
		RateLimits          map[string]json.RawMessage `json:"rate_limits"`
	}
	snap := Snapshot{Harness: agentdef.HarnessClaudeCode, ObservedAt: now, Windows: []Window{}}
	if json.Unmarshal(resp, &r) != nil {
		return snap
	}
	if r.SubscriptionType != nil {
		snap.Plan = *r.SubscriptionType
	}
	if !r.RateLimitsAvailable {
		return snap
	}
	for _, cw := range claudeWindows {
		var w struct {
			Utilization *float64        `json:"utilization"`
			ResetsAt    json.RawMessage `json:"resets_at"`
		}
		raw, ok := r.RateLimits[cw.key]
		if !ok || json.Unmarshal(raw, &w) != nil || w.Utilization == nil {
			continue
		}
		snap.Windows = append(snap.Windows, Window{ID: cw.key, Kind: cw.kind, Label: cw.label, UsedPercent: clampPercent(*w.Utilization), ResetsAt: timeValue(w.ResetsAt)})
	}
	snap.Available = true
	return snap
}

// ClaudeEvent is what one rate_limit_event line says about a window.
type ClaudeEvent struct {
	Window  Window
	Limited bool // the request was refused for this window
}

// FromClaudeEvent reads the rate_limit_info of a stream-json rate_limit_event.
// Its utilization mirrors the API's unified rate-limit headers, a fraction
// from 0 to 1; a value above 1 is taken as already a percentage. ok is false
// when the event names no window Vesper knows.
func FromClaudeEvent(info json.RawMessage) (ClaudeEvent, bool) {
	var e struct {
		Status        string          `json:"status"`
		ResetsAt      json.RawMessage `json:"resetsAt"`
		RateLimitType string          `json:"rateLimitType"`
		Utilization   *float64        `json:"utilization"`
	}
	if json.Unmarshal(info, &e) != nil {
		return ClaudeEvent{}, false
	}
	kind, label, ok := claudeWindow(e.RateLimitType)
	if !ok {
		return ClaudeEvent{}, false
	}
	limited := e.Status == "rejected"
	used := 0.0
	switch {
	case e.Utilization != nil && *e.Utilization > 1:
		used = *e.Utilization
	case e.Utilization != nil:
		used = *e.Utilization * 100
	case limited:
		used = 100
	default:
		return ClaudeEvent{}, false // nothing to show without a figure
	}
	if limited {
		used = 100
	}
	return ClaudeEvent{Window: Window{ID: e.RateLimitType, Kind: kind, Label: label, UsedPercent: clampPercent(used), ResetsAt: timeValue(e.ResetsAt)}, Limited: limited}, true
}

func codexKind(minutes int) (Kind, string) {
	switch {
	case minutes > 0 && minutes <= 12*60:
		return Session, "Session"
	case minutes >= 6*1440 && minutes <= 8*1440:
		return Weekly, "Weekly"
	}
	return Other, "Limit"
}

// ParseCodexRateLimits reads the result of Codex app-server's
// account/rateLimits/read: the main "codex" allowance's primary and secondary
// windows. usedPercent there is a percentage.
func ParseCodexRateLimits(result json.RawMessage, now time.Time) Snapshot {
	type window struct {
		UsedPercent        *float64        `json:"usedPercent"`
		WindowDurationMins int             `json:"windowDurationMins"`
		ResetsAt           json.RawMessage `json:"resetsAt"`
	}
	type limits struct {
		LimitID   string  `json:"limitId"`
		PlanType  string  `json:"planType"`
		Primary   *window `json:"primary"`
		Secondary *window `json:"secondary"`
	}
	var r struct {
		RateLimits          *limits           `json:"rateLimits"`
		RateLimitsByLimitID map[string]limits `json:"rateLimitsByLimitId"`
	}
	snap := Snapshot{Harness: agentdef.HarnessCodex, ObservedAt: now, Windows: []Window{}}
	if json.Unmarshal(result, &r) != nil {
		return snap
	}
	var l *limits
	if main, ok := r.RateLimitsByLimitID["codex"]; ok {
		l = &main
	} else if r.RateLimits != nil && (r.RateLimits.LimitID == "" || strings.EqualFold(r.RateLimits.LimitID, "codex")) {
		l = r.RateLimits
	}
	if l == nil {
		return snap
	}
	snap.Plan = l.PlanType
	for i, w := range []*window{l.Primary, l.Secondary} {
		slot := [2]string{"primary", "secondary"}[i]
		if w == nil || w.UsedPercent == nil {
			continue
		}
		kind, label := codexKind(w.WindowDurationMins)
		id := "codex_" + slot
		if w.WindowDurationMins > 0 {
			id = "codex_" + strconv.Itoa(w.WindowDurationMins)
		}
		snap.Windows = append(snap.Windows, Window{ID: id, Kind: kind, Label: label, UsedPercent: clampPercent(*w.UsedPercent), ResetsAt: timeValue(w.ResetsAt)})
	}
	Sort(snap.Windows)
	snap.Available = len(snap.Windows) > 0
	return snap
}

type agyUsageEntry struct {
	ID                  string          `json:"id"`
	Name                string          `json:"name"`
	Label               string          `json:"label"`
	DisplayName         string          `json:"display_name"`
	DisplayNameCamel    string          `json:"displayName"`
	Window              string          `json:"window"`
	RefreshWindowLabel  string          `json:"refresh_window_label"`
	RefreshWindowCamel  string          `json:"refreshWindowLabel"`
	Description         string          `json:"description"`
	RemainingFraction   *float64        `json:"remaining_fraction"`
	RemainingFracCamel  *float64        `json:"remainingFraction"`
	RemainingPercent    *float64        `json:"remaining_percentage"`
	RemainingPctCamel   *float64        `json:"remainingPercentage"`
	UsedPercent         *float64        `json:"used_percent"`
	UsedPercentCamel    *float64        `json:"usedPercent"`
	UsedPercentage      *float64        `json:"used_percentage"`
	UsedPercentageCamel *float64        `json:"usedPercentage"`
	ResetTime           json.RawMessage `json:"reset_time"`
	ResetTimeCamel      json.RawMessage `json:"resetTime"`
	ResetsAt            json.RawMessage `json:"resets_at"`
	ResetsAtCamel       json.RawMessage `json:"resetsAt"`
	Disabled            bool            `json:"disabled"`
}

func firstText(vals ...string) string {
	for _, v := range vals {
		if s := strings.TrimSpace(v); s != "" {
			return s
		}
	}
	return ""
}

func firstRaw(vals ...json.RawMessage) json.RawMessage {
	for _, v := range vals {
		if len(v) > 0 && string(v) != "null" {
			return v
		}
	}
	return nil
}

func agyUsedPercent(e agyUsageEntry) (float64, bool) {
	for _, p := range []*float64{e.UsedPercent, e.UsedPercentCamel, e.UsedPercentage, e.UsedPercentageCamel} {
		if p != nil {
			return clampPercent(*p), true
		}
	}
	for _, p := range []*float64{e.RemainingPercent, e.RemainingPctCamel} {
		if p != nil {
			return clampPercent(100 - *p), true
		}
	}
	for _, f := range []*float64{e.RemainingFraction, e.RemainingFracCamel} {
		if f != nil {
			frac := math.Min(1, math.Max(0, *f))
			return clampPercent((1 - frac) * 100), true
		}
	}
	return 0, false
}

func agyWindowKind(hint string) Kind {
	s := strings.ToLower(hint)
	switch {
	case strings.Contains(s, "week") || strings.Contains(s, "7d") || strings.Contains(s, "7 day"):
		return Weekly
	case strings.Contains(s, "5h") || strings.Contains(s, "5 hour") || strings.Contains(s, "session") || strings.Contains(s, "daily") || strings.Contains(s, "24h") || strings.Contains(s, "hour"):
		return Session
	}
	return Other
}

func agyWindowID(raw, fallback string) string {
	var b strings.Builder
	prevUnderscore := false
	for _, r := range strings.ToLower(strings.TrimSpace(raw)) {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			b.WriteRune(r)
			prevUnderscore = false
		} else if !prevUnderscore && b.Len() > 0 {
			b.WriteByte('_')
			prevUnderscore = true
		}
	}
	s := strings.Trim(b.String(), "_")
	if s == "" {
		return fallback
	}
	return "agy_" + s
}

// ParseAntigravityUsage reads the JSON payload from `agy -p /usage --output-format stream-json`,
// accepting a `command_result` line, a `result` line, or the inner `command.data` object.
func ParseAntigravityUsage(raw json.RawMessage, now time.Time) Snapshot {
	snap := Snapshot{Harness: agentdef.HarnessAntigravity, ObservedAt: now, Windows: []Window{}}
	type commandPayload struct {
		Name string          `json:"name"`
		Data json.RawMessage `json:"data"`
	}
	var env struct {
		Event   string          `json:"event"`
		Command *commandPayload `json:"command"`
		Result  *struct {
			PlanName string          `json:"plan_name"`
			Command  *commandPayload `json:"command"`
		} `json:"result"`
	}
	data := raw
	if json.Unmarshal(raw, &env) == nil {
		switch {
		case env.Command != nil && len(env.Command.Data) > 0:
			data = env.Command.Data
		case env.Result != nil:
			if env.Result.PlanName != "" {
				snap.Plan = env.Result.PlanName
			}
			if env.Result.Command != nil && len(env.Result.Command.Data) > 0 {
				data = env.Result.Command.Data
			}
		}
	}
	type agyGroup struct {
		agyUsageEntry
		Buckets []agyUsageEntry `json:"buckets"`
		Models  []agyUsageEntry `json:"models"`
	}
	var quota struct {
		PlanName        string     `json:"plan_name"`
		Plan            string     `json:"plan"`
		TierDisplayName string     `json:"tier_display_name"`
		Groups          []agyGroup `json:"groups"`
	}
	if json.Unmarshal(data, &quota) != nil {
		return snap
	}
	if snap.Plan == "" {
		snap.Plan = firstText(quota.PlanName, quota.Plan, quota.TierDisplayName)
	}
	seenID := map[string]int{}
	addEntry := func(e agyUsageEntry, groupLabel, fallbackID string) {
		if e.Disabled {
			return
		}
		used, ok := agyUsedPercent(e)
		if !ok {
			return
		}
		label := firstText(e.DisplayName, e.DisplayNameCamel, e.Label, e.Name, e.RefreshWindowLabel, e.RefreshWindowCamel, e.Window, groupLabel)
		if groupLabel != "" && label != "" && !strings.EqualFold(groupLabel, label) && !strings.Contains(strings.ToLower(label), strings.ToLower(groupLabel)) {
			label = groupLabel + " · " + label
		}
		if label == "" {
			label = "Quota"
		}
		hint := firstText(e.RefreshWindowLabel, e.RefreshWindowCamel, e.Window, e.Description, label)
		id := agyWindowID(firstText(e.ID, label), fallbackID)
		if n := seenID[id]; n > 0 {
			id = id + "_" + strconv.Itoa(n+1)
		}
		seenID[id]++
		resets := timeValue(firstRaw(e.ResetTime, e.ResetTimeCamel, e.ResetsAt, e.ResetsAtCamel))
		snap.Windows = append(snap.Windows, Window{
			ID:          id,
			Kind:        agyWindowKind(hint),
			Label:       label,
			UsedPercent: used,
			ResetsAt:    resets,
		})
	}
	for gi, g := range quota.Groups {
		if g.Disabled {
			continue
		}
		groupLabel := firstText(g.DisplayName, g.DisplayNameCamel, g.Label, g.Name, g.RefreshWindowLabel, g.RefreshWindowCamel, g.Window)
		if len(g.Buckets) > 0 {
			for bi, b := range g.Buckets {
				addEntry(b, groupLabel, fmt.Sprintf("agy_%d_%d", gi, bi))
			}
			continue
		}
		if len(g.Models) > 0 {
			for mi, m := range g.Models {
				addEntry(m, groupLabel, fmt.Sprintf("agy_%d_%d", gi, mi))
			}
			continue
		}
		addEntry(g.agyUsageEntry, "", fmt.Sprintf("agy_%d", gi))
	}
	Sort(snap.Windows)
	snap.Available = len(snap.Windows) > 0
	return snap
}

var kindOrder = map[Kind]int{Session: 0, Weekly: 1, Other: 2}

// Sort orders windows session first, then weekly, keeping the account-wide
// weekly window ahead of per-model ones.
func Sort(ws []Window) {
	sort.SliceStable(ws, func(i, j int) bool {
		if kindOrder[ws[i].Kind] != kindOrder[ws[j].Kind] {
			return kindOrder[ws[i].Kind] < kindOrder[ws[j].Kind]
		}
		return len(ws[i].Label) < len(ws[j].Label)
	})
}

// Current drops windows that renewed since they were read: their figure says
// nothing about the window now, and inventing zero would hide work already
// spent in the new one.
func Current(ws []Window, now time.Time) []Window {
	out := []Window{}
	for _, w := range ws {
		if w.ResetsAt == nil || w.ResetsAt.After(now) {
			out = append(out, w)
		}
	}
	return out
}

// Merge lays newer windows over older ones by ID, keeping the older windows
// a passive reading didn't mention.
func Merge(old, newer []Window, now time.Time) []Window {
	byID := map[string]Window{}
	order := []string{}
	for _, list := range [][]Window{old, newer} {
		for _, w := range list {
			if _, seen := byID[w.ID]; !seen {
				order = append(order, w.ID)
			}
			byID[w.ID] = w
		}
	}
	out := make([]Window, 0, len(order))
	for _, id := range order {
		out = append(out, byID[id])
	}
	out = Current(out, now)
	Sort(out)
	return out
}
