package transfer

import (
	"context"
	"fmt"
	"slices"
	"strings"

	"github.com/jackc/pgx/v5"
)

// excluded names the tables an export leaves out, each with the reason. A new
// table is exported unless it is listed here, so a migration needs no change to
// this package. TestEveryTableIsExportedOrExcluded keeps the list honest.
var excluded = map[string]string{
	"goose_db_version":          "migration history: the target's own migrations rebuild it",
	"browser_sessions":          "sign-in sessions: people sign in again on the new machine",
	"browser_sign_in_codes":     "one-time sign-in codes",
	"sign_ins":                  "pending harness sign-in flows, tied to a runner on the old machine",
	"runners":                   "runner registrations: a runner on the new machine registers itself",
	"playgrounds":               "live playground stacks, tied to a runner and ports on the old machine",
	"harness_usage_checks":      "runner-claimed jobs that refresh provider usage",
	"harness_model_listings":    "cache of the models each harness login offers; the runner refills it",
	"provider_usage":            "observed provider usage, refreshed by the runner",
	"provider_limits":           "observed provider rate limits, refreshed by the runner",
	"metric_snapshots":          "cached dashboard metrics, recomputed on demand",
	"browser_extension_tokens":  "the Safari extension's credential: the Mac app mints a new one at launch",
	"browser_share_screenshots": "the latest screenshot of a shared Safari tab, replaced at every snapshot",
	"backup_encryption":         "backup encryption password: never exported inside the archive it protects",
	"custom_app_media":          "custom-app downloaded media: large video files that apps can re-download",
	"subagent_jobs":             "ephemeral in-turn subagent execution jobs, scoped to a live run turn",
	"custom_app_nix_jobs":       "custom-app Nix job state and scratch paths: ephemeral per-machine runs",
	"chat_steers":               "ephemeral mid-turn steering messages scoped to a live chat turn",
	"pr_feedback":               "cached GitHub PR check runs, review threads and ETags, refreshed by prsync",
	"companion_pairing_codes":   "one-time companion pairing codes",
	"companion_devices":         "paired mobile companion credentials: devices re-pair with the new machine",
	"mail_contacts":             "cached Apple Contacts emails synced from iCloud CardDAV; the mail poller refills it",
	"mail_triage_queue":         "ephemeral pending mail classification jobs claimed by the runner",
}

// excludedPrefixes are table-name prefixes owned by a library with its own
// migrations.
var excludedPrefixes = map[string]string{
	"river_": "River's job queue: its own migrations create it, and queued jobs are runtime state",
}

// excludeReason returns why a table isn't exported, or "" when it is.
func excludeReason(table string) string {
	if r, ok := excluded[table]; ok {
		return r
	}
	for p, r := range excludedPrefixes {
		if strings.HasPrefix(table, p) {
			return r
		}
	}
	return ""
}

// excludedBlobPrefixes are blob key prefixes an export leaves out, each with
// the reason. Keep prefixes ending in "/" so they match only that namespace.
var excludedBlobPrefixes = map[string]string{
	"custom-app-media/": "custom-app downloaded media: large video files that apps can re-download",
}

// excludeBlobReason returns why a blob isn't exported, or "" when it is.
func excludeBlobReason(key string) string {
	for p, r := range excludedBlobPrefixes {
		if strings.HasPrefix(key, p) {
			return r
		}
	}
	return ""
}

// Column is one exported column. Generated columns are left out: Postgres
// recomputes them.
type Column struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

// Table is one table in the public schema.
type Table struct {
	Name    string
	Columns []Column
}

// foreignKey is a constraint from Child to Parent, by table name.
type foreignKey struct {
	Name, Child, Parent string
}

// Schema is what discovery found in a database.
type Schema struct {
	Tables   []Table // exported tables, in load order (parents first)
	Excluded map[string]string
	// Deferred are foreign keys inside a cycle: no table order satisfies them,
	// so import checks them at commit instead.
	Deferred []DeferredKey
	// Sequences are serial or identity columns whose counters need resetting
	// after a load.
	Sequences []Sequence
}

// DeferredKey is a foreign key import defers to the end of its transaction.
type DeferredKey struct{ Table, Constraint string }

// Sequence is a column backed by a sequence.
type Sequence struct{ Table, Column, Name string }

// Discover reads the public schema. Which tables exist, their columns and
// their foreign keys all come from the catalog, so none of it is written down.
func Discover(ctx context.Context, q pgx.Tx) (*Schema, error) {
	cols, err := discoverColumns(ctx, q)
	if err != nil {
		return nil, err
	}
	fks, err := discoverForeignKeys(ctx, q)
	if err != nil {
		return nil, err
	}
	s := &Schema{Excluded: map[string]string{}}
	byName := map[string]Table{}
	for name, c := range cols {
		if r := excludeReason(name); r != "" {
			s.Excluded[name] = r
			continue
		}
		byName[name] = Table{Name: name, Columns: c}
	}
	order, deferred := loadOrder(byName, fks)
	for _, n := range order {
		s.Tables = append(s.Tables, byName[n])
	}
	s.Deferred = deferred
	s.Sequences, err = discoverSequences(ctx, q, byName)
	if err != nil {
		return nil, err
	}
	return s, nil
}

func discoverColumns(ctx context.Context, q pgx.Tx) (map[string][]Column, error) {
	rows, err := q.Query(ctx, `
		SELECT c.relname, a.attname, format_type(a.atttypid, a.atttypmod)
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = c.oid
		WHERE n.nspname = 'public'
		  AND c.relkind IN ('r', 'p')
		  AND NOT c.relispartition
		  AND a.attnum > 0
		  AND NOT a.attisdropped
		  AND a.attgenerated = ''
		ORDER BY c.relname, a.attnum`)
	if err != nil {
		return nil, fmt.Errorf("transfer: discover columns: %w", err)
	}
	defer rows.Close()
	out := map[string][]Column{}
	for rows.Next() {
		var table string
		var c Column
		if err := rows.Scan(&table, &c.Name, &c.Type); err != nil {
			return nil, err
		}
		out[table] = append(out[table], c)
	}
	return out, rows.Err()
}

func discoverForeignKeys(ctx context.Context, q pgx.Tx) ([]foreignKey, error) {
	rows, err := q.Query(ctx, `
		SELECT con.conname, child.relname, parent.relname
		FROM pg_constraint con
		JOIN pg_class child ON child.oid = con.conrelid
		JOIN pg_class parent ON parent.oid = con.confrelid
		JOIN pg_namespace cn ON cn.oid = child.relnamespace
		JOIN pg_namespace pn ON pn.oid = parent.relnamespace
		WHERE con.contype = 'f' AND cn.nspname = 'public' AND pn.nspname = 'public'
		ORDER BY child.relname, con.conname`)
	if err != nil {
		return nil, fmt.Errorf("transfer: discover foreign keys: %w", err)
	}
	defer rows.Close()
	var out []foreignKey
	for rows.Next() {
		var f foreignKey
		if err := rows.Scan(&f.Name, &f.Child, &f.Parent); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}

func discoverSequences(ctx context.Context, q pgx.Tx, tables map[string]Table) ([]Sequence, error) {
	rows, err := q.Query(ctx, `
		SELECT c.relname, a.attname, pg_get_serial_sequence(format('%I.%I', n.nspname, c.relname), a.attname)
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_attribute a ON a.attrelid = c.oid
		WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p') AND a.attnum > 0 AND NOT a.attisdropped
		  AND pg_get_serial_sequence(format('%I.%I', n.nspname, c.relname), a.attname) IS NOT NULL
		ORDER BY c.relname, a.attnum`)
	if err != nil {
		return nil, fmt.Errorf("transfer: discover sequences: %w", err)
	}
	defer rows.Close()
	var out []Sequence
	for rows.Next() {
		var s Sequence
		if err := rows.Scan(&s.Table, &s.Column, &s.Name); err != nil {
			return nil, err
		}
		if _, ok := tables[s.Table]; ok {
			out = append(out, s)
		}
	}
	return out, rows.Err()
}

// loadOrder sorts tables so a table comes after the tables it references. A
// self-reference needs no ordering: Postgres checks it when the statement
// ends. Real cycles (an agent and its current definition version) can't be
// ordered, so each is broken at one table: that table is loaded early and its
// foreign keys to tables not yet loaded are returned as deferred, to be
// checked at commit.
func loadOrder(tables map[string]Table, fks []foreignKey) (order []string, deferred []DeferredKey) {
	parents := map[string]map[string]bool{}
	children := map[string][]string{}
	for n := range tables {
		parents[n] = map[string]bool{}
	}
	for _, f := range fks {
		_, okC := tables[f.Child]
		_, okP := tables[f.Parent]
		if !okC || !okP || f.Child == f.Parent || parents[f.Child][f.Parent] {
			continue
		}
		parents[f.Child][f.Parent] = true
		children[f.Parent] = append(children[f.Parent], f.Child)
	}
	remaining := map[string]int{}
	for n, p := range parents {
		remaining[n] = len(p)
	}
	done := map[string]bool{}
	emit := func(n string) {
		order = append(order, n)
		done[n] = true
		for _, c := range children[n] {
			if !done[c] {
				remaining[c]--
			}
		}
	}
	for len(done) < len(tables) {
		var ready []string
		for n := range tables {
			if !done[n] && remaining[n] == 0 {
				ready = append(ready, n)
			}
		}
		if len(ready) > 0 {
			slices.Sort(ready)
			emit(ready[0])
			continue
		}
		// Stuck in a cycle: break it at the table with the fewest unloaded parents.
		var stuck []string
		for n := range tables {
			if !done[n] {
				stuck = append(stuck, n)
			}
		}
		slices.SortFunc(stuck, func(a, b string) int {
			if remaining[a] != remaining[b] {
				return remaining[a] - remaining[b]
			}
			return strings.Compare(a, b)
		})
		n := stuck[0]
		for _, f := range fks {
			if f.Child == n && f.Parent != n && !done[f.Parent] {
				if _, ok := tables[f.Parent]; ok {
					deferred = append(deferred, DeferredKey{Table: f.Child, Constraint: f.Name})
				}
			}
		}
		emit(n)
	}
	return order, deferred
}
