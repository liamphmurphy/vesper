package usage

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"sync"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"

	"github.com/liamphmurphy/vesper/server/internal/agentdef"
	"github.com/liamphmurphy/vesper/server/internal/chatmodels"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

// Harnesses are the ones with plan allowances, in display order.
var Harnesses = []string{agentdef.HarnessClaudeCode, agentdef.HarnessCodex, agentdef.HarnessAntigravity}

const (
	// Fresh is how long a reading stands before a check asks again.
	Fresh = 2 * time.Minute
	// QueuedFresh is Fresh for checks a runner answers: each one starts a
	// container, so they ask less often.
	QueuedFresh = 5 * time.Minute
	// failedRetry waits out a check that didn't answer.
	failedRetry = 10 * time.Minute
	// settledRetry waits out what only the person can fix: a CLI that's
	// missing, signed out or too old.
	settledRetry = 30 * time.Minute
)

// Service saves readings and keeps them fresh.
type Service struct {
	Q *store.Queries
	// Probe checks a harness through its CLI, as on the fake backend.
	Probe func(ctx context.Context, harness string) (Snapshot, error)
	// Queued asks a runner instead (harness_usage_checks), as on the Docker
	// backend, where the CLIs and their logins live in run containers. With
	// neither, readings come only from runs (Record).
	Queued bool
	Log    *slog.Logger
	// Now is for tests.
	Now func() time.Time

	mu   sync.Mutex
	next map[string]time.Time // workspace/harness → earliest next check
	busy map[string]bool
}

func (s *Service) now() time.Time {
	if s.Now != nil {
		return s.Now()
	}
	return time.Now()
}

func (s *Service) log() *slog.Logger {
	if s.Log != nil {
		return s.Log
	}
	return slog.Default()
}

// Save replaces a harness's reading.
func (s *Service) Save(ctx context.Context, ws uuid.UUID, snap Snapshot) error {
	windows, err := json.Marshal(Current(snap.Windows, s.now()))
	if err != nil {
		return err
	}
	return s.Q.SaveProviderUsage(ctx, store.SaveProviderUsageParams{WorkspaceID: ws, Harness: snap.Harness, Plan: snap.Plan,
		Available: snap.Available, Windows: windows, ObservedAt: snap.ObservedAt})
}

// Record lays windows a run reported over the saved reading, keeping the
// plan and the windows the run didn't mention.
func (s *Service) Record(ctx context.Context, ws uuid.UUID, harness string, windows []Window) error {
	if len(windows) == 0 {
		return nil
	}
	snap := Snapshot{Harness: harness, Available: true, ObservedAt: s.now()}
	row, err := s.Q.ProviderUsageFor(ctx, store.ProviderUsageForParams{WorkspaceID: ws, Harness: harness})
	switch {
	case err == nil:
		snap.Plan = row.Plan
		var old []Window
		_ = json.Unmarshal(row.Windows, &old)
		snap.Windows = Merge(old, windows, snap.ObservedAt)
	case errors.Is(err, pgx.ErrNoRows):
		snap.Windows = Merge(nil, windows, snap.ObservedAt)
	default:
		return err
	}
	return s.Save(ctx, ws, snap)
}

// Readings returns the saved readings by harness, with renewed windows dropped.
func (s *Service) Readings(ctx context.Context, ws uuid.UUID) (map[string]Snapshot, error) {
	rows, err := s.Q.ProviderUsage(ctx, ws)
	if err != nil {
		return nil, err
	}
	out := map[string]Snapshot{}
	now := s.now()
	for _, r := range rows {
		var ws []Window
		_ = json.Unmarshal(r.Windows, &ws)
		out[r.Harness] = Snapshot{Harness: r.Harness, Plan: r.Plan, Available: r.Available, Windows: Current(ws, now), ObservedAt: r.ObservedAt}
	}
	return out, nil
}

// Refresh starts a check of each harness whose reading is due and returns
// at once; results show on a later poll. Local checks run in the background,
// never overlap for a harness, and wait after a failure; queued checks are
// left to a runner, which keeps the same back-off in the queue.
func (s *Service) Refresh(ctx context.Context, ws uuid.UUID, readings map[string]Snapshot) {
	switch {
	case s.Probe != nil:
		s.refreshLocal(ws, readings)
	case s.Queued:
		s.refreshQueued(ctx, ws, readings)
	}
}

func (s *Service) refreshLocal(ws uuid.UUID, readings map[string]Snapshot) {
	now := s.now()
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.next == nil {
		s.next, s.busy = map[string]time.Time{}, map[string]bool{}
	}
	for _, h := range Harnesses {
		key := ws.String() + "/" + h
		if s.busy[key] || now.Before(s.next[key]) {
			continue
		}
		if r, ok := readings[h]; ok && now.Sub(r.ObservedAt) < Fresh {
			continue
		}
		s.busy[key] = true
		go s.check(ws, h, key)
	}
}

// refreshQueued asks a runner to check each harness whose reading is stale.
// Best effort: the orb still shows the last reading if this fails.
func (s *Service) refreshQueued(ctx context.Context, ws uuid.UUID, readings map[string]Snapshot) {
	now := s.now()
	for _, h := range Harnesses {
		if r, ok := readings[h]; ok && now.Sub(r.ObservedAt) < QueuedFresh {
			continue
		}
		version, err := s.Q.SecretVersion(ctx, store.SecretVersionParams{WorkspaceID: ws, Name: chatmodels.KeySecret[h]})
		if errors.Is(err, pgx.ErrNoRows) {
			// No login, so no limits: say so rather than "not read yet".
			snap := Snapshot{Harness: h, ObservedAt: now, Windows: []Window{}}
			if err := s.Save(ctx, ws, snap); err != nil {
				s.log().Warn("save harness usage", "harness", h, "err", err)
			}
			continue
		}
		if err == nil {
			err = s.Q.RequestUsageCheck(ctx, store.RequestUsageCheckParams{WorkspaceID: ws, Harness: h, LoginVersion: version})
		}
		if err != nil && ctx.Err() == nil {
			s.log().Warn("queue harness usage check", "harness", h, "err", err)
		}
	}
}

// Checking reports the harnesses with a check in flight, for the orb.
func (s *Service) Checking(ctx context.Context, ws uuid.UUID) (map[string]bool, error) {
	out := map[string]bool{}
	if s.Queued {
		hs, err := s.Q.UsageChecksInFlight(ctx, ws)
		if err != nil {
			return nil, err
		}
		for _, h := range hs {
			out[h] = true
		}
		return out, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	for _, h := range Harnesses {
		out[h] = s.busy[ws.String()+"/"+h]
	}
	return out, nil
}

func (s *Service) check(ws uuid.UUID, harness, key string) {
	ctx, cancel := context.WithTimeout(context.Background(), ProbeTimeout+5*time.Second)
	defer cancel()
	snap, err := s.Probe(ctx, harness)
	wait := s.Settle(ctx, ws, harness, snap, err)
	s.mu.Lock()
	s.busy[key] = false
	s.next[key] = s.now().Add(wait)
	s.mu.Unlock()
}

// Settle saves what a check found and returns how long to wait before the
// next one. A signed-out CLI is saved too, so the orb can say limits don't
// apply rather than nothing; a failed or outdated check keeps the last reading.
func (s *Service) Settle(ctx context.Context, ws uuid.UUID, harness string, snap Snapshot, err error) time.Duration {
	wait := Fresh
	switch {
	case errors.Is(err, ErrSignedOut):
		wait = settledRetry
		snap.Harness, snap.Available, snap.ObservedAt = harness, false, s.now()
		if snap.Windows == nil {
			snap.Windows = []Window{}
		}
		if serr := s.Save(ctx, ws, snap); serr != nil {
			s.log().Warn("save harness usage", "harness", harness, "err", serr)
		}
	case errors.Is(err, ErrOutdated):
		wait = settledRetry
	case err != nil:
		wait = failedRetry
		s.log().Debug("harness usage check", "harness", harness, "err", err)
	default:
		if serr := s.Save(ctx, ws, snap); serr != nil {
			s.log().Warn("save harness usage", "harness", harness, "err", serr)
		}
	}
	return wait
}
