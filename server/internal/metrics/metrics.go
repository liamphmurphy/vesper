// Package metrics computes recorded performance, separately from live workflow
// state. Missing observations stay unknown rather than being inferred from edits.
package metrics

import (
	"context"
	"encoding/json"
	"errors"
	"sort"
	"time"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

type Performance struct {
	UnpricedRuns       int      `json:"unpriced_runs"`
	Completed          int      `json:"completed"`
	MedianCycleSeconds *float64 `json:"median_cycle_seconds"`
	MergedPRs          int      `json:"merged_prs"`
	ClosedPRs          int      `json:"closed_prs"`
	SpendUSD           float64  `json:"spend_usd"`
}
type Day struct {
	Date  string `json:"date"`
	Count int    `json:"count"`
}
type Snapshot struct {
	Range       string                    `json:"range"`
	GeneratedAt time.Time                 `json:"generated_at"`
	Performance Performance               `json:"performance"`
	Daily       []Day                     `json:"daily"`
	Agents      map[uuid.UUID]Performance `json:"agents"`
}

var Windows = map[string]time.Duration{"24h": 24 * time.Hour, "7d": 7 * 24 * time.Hour, "30d": 30 * 24 * time.Hour}

func median(values []float64) *float64 {
	if len(values) == 0 {
		return nil
	}
	sort.Float64s(values)
	n := len(values)
	v := values[n/2]
	if n%2 == 0 {
		v = (values[n/2-1] + v) / 2
	}
	return &v
}

// Calculate uses one repeatable-read snapshot so related totals agree.
func Calculate(ctx context.Context, pool *pgxpool.Pool, ws uuid.UUID, window string, asOf time.Time) (Snapshot, error) {
	tx, err := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead, AccessMode: pgx.ReadOnly})
	if err != nil {
		return Snapshot{}, err
	}
	defer tx.Rollback(ctx)
	out, err := calculate(ctx, store.New(tx), ws, window, asOf)
	if err != nil {
		return out, err
	}
	return out, tx.Commit(ctx)
}
func calculate(ctx context.Context, q *store.Queries, ws uuid.UUID, window string, asOf time.Time) (Snapshot, error) {
	out := Snapshot{Range: window, GeneratedAt: asOf, Daily: []Day{}, Agents: map[uuid.UUID]Performance{}}
	span, ok := Windows[window]
	if !ok {
		return out, errors.New("unknown metrics window")
	}
	since := asOf.Add(-span)
	completed, err := q.CompletedTicketMetrics(ctx, store.CompletedTicketMetricsParams{WorkspaceID: ws, AsOf: asOf})
	if err != nil {
		return out, err
	}
	costs, err := q.RunCostMetrics(ctx, store.RunCostMetricsParams{WorkspaceID: ws, AsOf: asOf})
	if err != nil {
		return out, err
	}
	prs, err := q.PRMetrics(ctx, store.PRMetricsParams{WorkspaceID: ws, AsOf: asOf})
	if err != nil {
		return out, err
	}
	var cycles []float64
	agentCycles := map[uuid.UUID][]float64{}
	days := map[string]int{}
	for _, c := range completed {
		if c.CompletedAt.Before(since) {
			continue
		}
		out.Performance.Completed++
		cycles = append(cycles, c.CycleSeconds)
		days[c.CompletedAt.UTC().Format("2006-01-02")]++
		if c.AssigneeAgentID != nil {
			id := *c.AssigneeAgentID
			a := out.Agents[id]
			a.Completed++
			out.Agents[id] = a
			agentCycles[id] = append(agentCycles[id], c.CycleSeconds)
		}
	}
	out.Performance.MedianCycleSeconds = median(cycles)
	for id, values := range agentCycles {
		a := out.Agents[id]
		a.MedianCycleSeconds = median(values)
		out.Agents[id] = a
	}
	for _, c := range costs {
		if c.StartedAt.Before(since) {
			continue
		}
		out.Performance.SpendUSD += c.CostUsd
		a := out.Agents[c.AgentID]
		a.SpendUSD += c.CostUsd
		if c.CostSource == nil || *c.CostSource == "unknown" || *c.CostSource == "partial" {
			a.UnpricedRuns++
			out.Performance.UnpricedRuns++
		}
		out.Agents[c.AgentID] = a
	}
	for _, p := range prs {
		if p.ClosedAt.Before(since) {
			continue
		}
		out.Performance.ClosedPRs++
		if p.PrState != nil && *p.PrState == "merged" {
			out.Performance.MergedPRs++
		}
		if p.AssigneeAgentID != nil {
			id := *p.AssigneeAgentID
			a := out.Agents[id]
			a.ClosedPRs++
			if p.PrState != nil && *p.PrState == "merged" {
				a.MergedPRs++
			}
			out.Agents[id] = a
		}
	}
	// Rolling windows have partial first/last UTC days. Keep all observations.
	start := time.Date(since.UTC().Year(), since.UTC().Month(), since.UTC().Day(), 0, 0, 0, 0, time.UTC)
	for d := start; !d.After(asOf); d = d.AddDate(0, 0, 1) {
		key := d.Format("2006-01-02")
		out.Daily = append(out.Daily, Day{Date: key, Count: days[key]})
	}
	return out, nil
}
func Get(ctx context.Context, pool *pgxpool.Pool, ws uuid.UUID, window string) (Snapshot, error) {
	row, err := store.New(pool).GetMetricSnapshot(ctx, store.GetMetricSnapshotParams{WorkspaceID: ws, Range: window})
	if err == nil && time.Since(row.GeneratedAt) < 90*time.Second {
		var out Snapshot
		if err = json.Unmarshal(row.Payload, &out); err == nil {
			return out, nil
		}
	}
	if err != nil && !errors.Is(err, pgx.ErrNoRows) {
		return Snapshot{}, err
	}
	return Calculate(ctx, pool, ws, window, time.Now().UTC())
}

const metricsUnchangedMaxAge = time.Hour

func workspaceNeedsRefresh(ctx context.Context, pool *pgxpool.Pool, ws uuid.UUID, now time.Time) (bool, error) {
	var count int
	var oldest *time.Time
	err := pool.QueryRow(ctx, `SELECT count(*), min(generated_at) FROM metric_snapshots WHERE workspace_id = $1`, ws).Scan(&count, &oldest)
	if err != nil {
		return true, err
	}
	if count < len(Windows) || oldest == nil || now.Sub(*oldest) >= metricsUnchangedMaxAge {
		return true, nil
	}
	var dirty bool
	err = pool.QueryRow(ctx, `
		SELECT EXISTS (SELECT 1 FROM runs WHERE workspace_id = $1 AND updated_at > $2)
		    OR EXISTS (SELECT 1 FROM tickets WHERE workspace_id = $1 AND updated_at > $2)
		    OR EXISTS (SELECT 1 FROM activity_events WHERE workspace_id = $1 AND created_at > $2)
	`, ws, *oldest).Scan(&dirty)
	if err != nil {
		return true, err
	}
	return dirty, nil
}

func Refresh(ctx context.Context, pool *pgxpool.Pool) error {
	q := store.New(pool)
	workspaces, err := q.MetricWorkspaces(ctx)
	if err != nil {
		return err
	}
	for _, ws := range workspaces {
		asOf := time.Now().UTC()
		need, err := workspaceNeedsRefresh(ctx, pool, ws, asOf)
		if err != nil {
			return err
		}
		if !need {
			continue
		}
		// Publish all ranges atomically. Readers never see half a refresh.
		tx, err := pool.BeginTx(ctx, pgx.TxOptions{IsoLevel: pgx.RepeatableRead})
		if err != nil {
			return err
		}
		err = func() error {
			defer tx.Rollback(ctx)
			tq := store.New(tx)
			for _, window := range []string{"24h", "7d", "30d"} {
				snap, err := calculate(ctx, tq, ws, window, asOf)
				if err != nil {
					return err
				}
				raw, err := json.Marshal(snap)
				if err != nil {
					return err
				}
				if err = tq.SaveMetricSnapshot(ctx, store.SaveMetricSnapshotParams{WorkspaceID: ws, Range: window, Payload: raw, GeneratedAt: asOf}); err != nil {
					return err
				}
			}
			return tx.Commit(ctx)
		}()
		if err != nil {
			return err
		}
	}
	return nil
}
