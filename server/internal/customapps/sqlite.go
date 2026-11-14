package customapps

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"
	"unicode"

	"github.com/google/uuid"
	"github.com/jackc/pgx/v5"
	_ "modernc.org/sqlite"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
	"github.com/liamphmurphy/vesper/server/internal/store"
)

const (
	MaxSQLRows   = 1000
	sqlTimeout   = 3 * time.Second
	sqliteDriver = "sqlite"
)

type SQLResult struct {
	Columns         []string         `json:"columns"`
	Rows            []map[string]any `json:"rows"`
	Changes         int64            `json:"changes"`
	LastInsertRowID int64            `json:"lastInsertRowId"`
	Truncated       bool             `json:"truncated,omitempty"`
	ReadOnly        bool             `json:"readOnly"`
}

type SchemaObject struct {
	Type string `json:"type"`
	Name string `json:"name"`
	SQL  string `json:"sql"`
}

var writeKeywords = map[string]bool{
	"INSERT": true, "UPDATE": true, "DELETE": true, "REPLACE": true,
	"CREATE": true, "ALTER": true, "DROP": true, "REINDEX": true, "VACUUM": true,
}

var blockedKeywords = map[string]bool{
	"ATTACH":         true,
	"DETACH":         true,
	"LOAD_EXTENSION": true,
}

var safePragmas = map[string]bool{
	"TABLE_INFO":       true,
	"TABLE_LIST":       true,
	"INDEX_LIST":       true,
	"INDEX_INFO":       true,
	"FOREIGN_KEY_LIST": true,
	"DATABASE_LIST":    false,
}

// ClassifySQL verifies a query is safe for an isolated per-app SQLite file and
// reports whether it is read-only.
func ClassifySQL(query string) (readOnly bool, err error) {
	tokens, hasAssign := tokenizeSQL(query)
	if len(tokens) == 0 {
		return false, apperr.Invalid("query", "SQL query is empty")
	}
	for _, tok := range tokens {
		if blockedKeywords[tok] {
			return false, apperr.Invalid("query", "%s is not allowed", tok)
		}
	}
	first := tokens[0]
	if first == "VACUUM" {
		for _, tok := range tokens[1:] {
			if tok == "INTO" {
				return false, apperr.Invalid("query", "VACUUM INTO is not allowed")
			}
		}
	}
	if first == "PRAGMA" {
		if hasAssign || len(tokens) < 2 || !safePragmas[tokens[1]] {
			return false, apperr.Invalid("query", "only read-only schema PRAGMA statements (table_info, table_list, index_list, index_info, foreign_key_list) are allowed")
		}
		return true, nil
	}
	for _, tok := range tokens {
		if writeKeywords[tok] {
			return false, nil
		}
	}
	switch first {
	case "SELECT", "EXPLAIN", "VALUES", "WITH":
		return true, nil
	default:
		return false, apperr.Invalid("query", "unsupported SQL statement %q", first)
	}
}

// tokenizeSQL extracts uppercase identifier/keyword tokens outside literals and
// comments so keywords inside string values don't trigger false positives.
func tokenizeSQL(s string) (tokens []string, hasAssign bool) {
	i := 0
	for i < len(s) {
		c := s[i]
		if c == '-' && i+1 < len(s) && s[i+1] == '-' {
			i += 2
			for i < len(s) && s[i] != '\n' {
				i++
			}
			continue
		}
		if c == '/' && i+1 < len(s) && s[i+1] == '*' {
			i += 2
			for i+1 < len(s) && !(s[i] == '*' && s[i+1] == '/') {
				i++
			}
			i += 2
			continue
		}
		if c == '\'' || c == '"' || c == '`' {
			quote := c
			i++
			for i < len(s) {
				if s[i] == quote {
					if i+1 < len(s) && s[i+1] == quote {
						i += 2
						continue
					}
					i++
					break
				}
				i++
			}
			continue
		}
		if c == '=' {
			hasAssign = true
			i++
			continue
		}
		if unicode.IsLetter(rune(c)) || c == '_' {
			start := i
			i++
			for i < len(s) && (unicode.IsLetter(rune(s[i])) || unicode.IsDigit(rune(s[i])) || s[i] == '_') {
				i++
			}
			tokens = append(tokens, strings.ToUpper(s[start:i]))
			continue
		}
		i++
	}
	return tokens, hasAssign
}

func execSQLiteBytes(ctx context.Context, dbBytes []byte, query string, params []any, allowMulti bool) (SQLResult, []byte, error) {
	readOnly, err := ClassifySQL(query)
	if err != nil {
		return SQLResult{}, nil, err
	}

	tmpDir, err := os.MkdirTemp("", "vesper-app-sql-*")
	if err != nil {
		return SQLResult{}, nil, err
	}
	defer os.RemoveAll(tmpDir)

	dbPath := filepath.Join(tmpDir, "app.db")
	if len(dbBytes) > 0 {
		if err := os.WriteFile(dbPath, dbBytes, 0o600); err != nil {
			return SQLResult{}, nil, err
		}
	}

	db, err := sql.Open(sqliteDriver, dbPath)
	if err != nil {
		return SQLResult{}, nil, err
	}
	closed := false
	closeDB := func() error {
		if closed {
			return nil
		}
		closed = true
		return db.Close()
	}
	defer closeDB()

	qctx, cancel := context.WithTimeout(ctx, sqlTimeout)
	defer cancel()

	if _, err := db.ExecContext(qctx, "PRAGMA journal_mode = DELETE; PRAGMA foreign_keys = ON; PRAGMA busy_timeout = 2000;"); err != nil {
		return SQLResult{}, nil, apperr.Invalid("query", "sqlite init: %v", err)
	}

	var out SQLResult
	out.ReadOnly = readOnly
	out.Columns = []string{}
	out.Rows = []map[string]any{}

	if allowMulti && !readOnly && len(params) == 0 {
		res, err := db.ExecContext(qctx, query)
		if err != nil {
			return SQLResult{}, nil, apperr.Invalid("query", "sqlite: %v", err)
		}
		out.Changes, _ = res.RowsAffected()
		out.LastInsertRowID, _ = res.LastInsertId()
	} else if readOnly || queryReturnsRows(query) {
		rows, err := db.QueryContext(qctx, query, params...)
		if err != nil {
			return SQLResult{}, nil, apperr.Invalid("query", "sqlite: %v", err)
		}
		defer rows.Close()
		cols, err := rows.Columns()
		if err != nil {
			return SQLResult{}, nil, err
		}
		out.Columns = cols
		for rows.Next() {
			if len(out.Rows) >= MaxSQLRows {
				out.Truncated = true
				break
			}
			dest := make([]any, len(cols))
			ptrs := make([]any, len(cols))
			for i := range dest {
				ptrs[i] = &dest[i]
			}
			if err := rows.Scan(ptrs...); err != nil {
				return SQLResult{}, nil, err
			}
			rowMap := make(map[string]any, len(cols))
			for i, col := range cols {
				if b, ok := dest[i].([]byte); ok {
					rowMap[col] = string(b)
				} else {
					rowMap[col] = dest[i]
				}
			}
			out.Rows = append(out.Rows, rowMap)
		}
		if err := rows.Err(); err != nil {
			return SQLResult{}, nil, apperr.Invalid("query", "sqlite: %v", err)
		}
	} else {
		res, err := db.ExecContext(qctx, query, params...)
		if err != nil {
			return SQLResult{}, nil, apperr.Invalid("query", "sqlite: %v", err)
		}
		out.Changes, _ = res.RowsAffected()
		out.LastInsertRowID, _ = res.LastInsertId()
	}

	if err := closeDB(); err != nil {
		return SQLResult{}, nil, err
	}
	if readOnly {
		return out, nil, nil
	}
	updated, err := os.ReadFile(dbPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return SQLResult{}, nil, err
	}
	if len(updated) > MaxSQLiteBytes {
		return SQLResult{}, nil, apperr.Invalid("query", "app database exceeds %d MB limit", MaxSQLiteBytes>>20)
	}
	return out, updated, nil
}

func queryReturnsRows(query string) bool {
	tokens, _ := tokenizeSQL(query)
	if len(tokens) == 0 {
		return false
	}
	if tokens[0] == "SELECT" || tokens[0] == "EXPLAIN" || tokens[0] == "PRAGMA" || tokens[0] == "VALUES" {
		return true
	}
	for _, tok := range tokens {
		if tok == "RETURNING" {
			return true
		}
	}
	return false
}

func (s *Service) runSQLTx(ctx context.Context, q *store.Queries, appID uuid.UUID, query string, params []any, allowMulti bool) (SQLResult, error) {
	if err := q.EnsureCustomAppDatabase(ctx, appID); err != nil {
		return SQLResult{}, err
	}
	row, err := q.GetCustomAppDatabaseForUpdate(ctx, appID)
	if err != nil {
		return SQLResult{}, err
	}
	res, updated, err := execSQLiteBytes(ctx, row.SqliteBytes, query, params, allowMulti)
	if err != nil {
		return SQLResult{}, err
	}
	if updated != nil {
		if err := q.UpdateCustomAppDatabase(ctx, store.UpdateCustomAppDatabaseParams{
			AppID:       appID,
			SqliteBytes: updated,
			SizeBytes:   int32(len(updated)),
		}); err != nil {
			return SQLResult{}, err
		}
	}
	return res, nil
}

func schemaSummaryTx(ctx context.Context, dbBytes []byte) ([]SchemaObject, error) {
	if len(dbBytes) == 0 {
		return []SchemaObject{}, nil
	}
	res, _, err := execSQLiteBytes(ctx, dbBytes, `SELECT type, name, coalesce(sql, '') AS sql FROM sqlite_master WHERE type IN ('table', 'index', 'view') AND name NOT LIKE 'sqlite_%' ORDER BY type DESC, name`, nil, false)
	if err != nil {
		return nil, err
	}
	objs := make([]SchemaObject, 0, len(res.Rows))
	for _, r := range res.Rows {
		objs = append(objs, SchemaObject{
			Type: fmt.Sprint(r["type"]),
			Name: fmt.Sprint(r["name"]),
			SQL:  fmt.Sprint(r["sql"]),
		})
	}
	return objs, nil
}

func (s *Service) QuerySQL(ctx context.Context, ws, userID uuid.UUID, slug, query string, params []any) (SQLResult, error) {
	if _, err := ClassifySQL(query); err != nil {
		return SQLResult{}, err
	}
	var out SQLResult
	err := pgx.BeginTxFunc(ctx, s.Pool, pgx.TxOptions{}, func(tx pgx.Tx) error {
		q := store.New(tx)
		app, err := q.GetCustomAppBySlug(ctx, store.GetCustomAppBySlugParams{WorkspaceID: ws, UserID: userID, Slug: slug})
		if errors.Is(err, pgx.ErrNoRows) {
			return apperr.ErrNotFound
		}
		if err != nil {
			return err
		}
		res, err := s.runSQLTx(ctx, q, app.ID, query, params, false)
		if err != nil {
			return err
		}
		out = res
		return nil
	})
	return out, err
}
