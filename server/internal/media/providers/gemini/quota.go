package gemini

import (
	"fmt"
	"math"
	"strings"
	"time"
)

// googleQuota is what a Google API 429 says about the quota that ran out: a
// google.rpc.QuotaFailure names it, and a google.rpc.RetryInfo suggests a wait.
type googleQuota struct {
	daily      bool
	perMinute  bool
	limit      string // the quota's value, e.g. "100"
	model      string
	retryDelay time.Duration
}

func parseQuotaDetails(details []map[string]any) googleQuota {
	var q googleQuota
	for _, d := range details {
		switch t, _ := d["@type"].(string); {
		case strings.HasSuffix(t, "google.rpc.QuotaFailure"):
			violations, _ := d["violations"].([]any)
			for _, raw := range violations {
				v, _ := raw.(map[string]any)
				id, _ := v["quotaId"].(string)
				switch {
				case strings.Contains(id, "PerDay"):
					q.daily = true
				case strings.Contains(id, "PerMinute"):
					q.perMinute = true
				default:
					continue
				}
				q.limit, _ = v["quotaValue"].(string)
				dims, _ := v["quotaDimensions"].(map[string]any)
				q.model, _ = dims["model"].(string)
			}
		case strings.HasSuffix(t, "google.rpc.RetryInfo"):
			s, _ := d["retryDelay"].(string)
			if delay, err := time.ParseDuration(s); err == nil && delay > 0 {
				q.retryDelay = time.Duration(math.Ceil(delay.Seconds())) * time.Second
			}
		}
	}
	return q
}

// pacific is where Gemini's per-day quotas reset, at midnight. Without the
// zone database, standard time is at most an hour early.
var pacific = func() *time.Location {
	if loc, err := time.LoadLocation("America/Los_Angeles"); err == nil {
		return loc
	}
	return time.FixedZone("PST", -8*60*60)
}()

// untilDailyReset is how long until Gemini's per-day quotas reset.
func untilDailyReset(now time.Time) time.Duration {
	n := now.In(pacific)
	return time.Date(n.Year(), n.Month(), n.Day()+1, 0, 0, 0, 0, pacific).Sub(now)
}

// message says which limit ran out and when it lifts, in place of the generic
// quota text, for the person to read in the app.
func (q googleQuota) message() string {
	what := "Gemini's daily request limit"
	if q.limit != "" {
		what = "Gemini's daily limit of " + q.limit + " requests"
	}
	if q.model != "" {
		what += " for " + q.model
	}
	if q.daily {
		return what + " is used up. It resets at midnight Pacific time."
	}
	if q.retryDelay > 0 {
		return fmt.Sprintf("Gemini's per-minute request limit was reached; try again in %s.", q.retryDelay)
	}
	return "Gemini's per-minute request limit was reached; try again shortly."
}
