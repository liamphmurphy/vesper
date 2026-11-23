package metrics

import (
	"context"
	"log/slog"
	"time"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/riverqueue/river"
	"github.com/riverqueue/river/riverdriver/riverpgxv5"
)

type RollupArgs struct{}

func (RollupArgs) Kind() string { return "metrics_rollup" }

type RollupWorker struct {
	river.WorkerDefaults[RollupArgs]
	Pool *pgxpool.Pool
}

func (w *RollupWorker) Work(ctx context.Context, _ *river.Job[RollupArgs]) error {
	return Refresh(ctx, w.Pool)
}

const (
	metricsFetchPollInterval = 30 * time.Second
	metricsRollupInterval    = 10 * time.Minute
)

// NewClient registers only statistics work. It never launches agent harnesses.
func NewClient(pool *pgxpool.Pool, log *slog.Logger) (*river.Client[pgx.Tx], error) {
	workers := river.NewWorkers()
	river.AddWorker(workers, &RollupWorker{Pool: pool})
	return river.NewClient(riverpgxv5.New(pool), &river.Config{
		Logger:            log,
		Workers:           workers,
		JobTimeout:        time.Minute,
		FetchPollInterval: metricsFetchPollInterval,
		Queues:            map[string]river.QueueConfig{river.QueueDefault: {MaxWorkers: 1}},
		PeriodicJobs: []*river.PeriodicJob{river.NewPeriodicJob(river.PeriodicInterval(metricsRollupInterval), func() (river.JobArgs, *river.InsertOpts) {
			return RollupArgs{}, &river.InsertOpts{UniqueOpts: river.UniqueOpts{ByPeriod: metricsRollupInterval}}
		}, &river.PeriodicJobOpts{ID: "metrics", RunOnStart: true})},
	})
}
