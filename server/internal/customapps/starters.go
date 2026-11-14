package customapps

import (
	"fmt"

	"github.com/liamphmurphy/vesper/server/internal/apperr"
)

type Starter struct {
	ID          string
	Name        string
	Description string
	Icon        string
	Manifest    Manifest
	Files       map[string]string
}

func StarterFor(id, name string) (Starter, error) {
	if name == "" {
		name = "Custom App"
	}
	switch id {
	case "", "blank":
		return Starter{
			ID:          "blank",
			Name:        name,
			Description: "Minimal custom app with private SQLite storage.",
			Icon:        "dashboard",
			Manifest: Manifest{
				Entry:        "app.tsx",
				ToolScope:    ToolScopeChats,
				Instructions: fmt.Sprintf("You are helping build and operate the %q custom app. Inspect its files and schema with get_custom_app, update UI/code with update_custom_app, and query or update its data with custom_app_sql.", name),
			},
			Files: map[string]string{
				"schema.sql": `CREATE TABLE IF NOT EXISTS notes (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);`,
				"styles.css": baseAppCSS,
				"app.tsx": fmt.Sprintf(`import { useState } from "react";
import { sql, useBridgeQuery, askDock } from "@vesper/bridge";

type Note = { id: number; title: string; created_at: string };

export default function App() {
  const [title, setTitle] = useState("");
  const notes = useBridgeQuery(() => sql("SELECT id, title, created_at FROM notes ORDER BY id DESC"), []);

  async function addNote(e: Event) {
    e.preventDefault();
    const clean = title.trim();
    if (!clean) return;
    await sql("INSERT INTO notes (title) VALUES (?)", [clean]);
    setTitle("");
    notes.refetch();
  }

  return (
    <main className="app-shell">
      <header className="app-header">
        <div>
          <h1>%s</h1>
          <p className="muted">Private SQLite storage + Vesper persona co-building</p>
        </div>
        <button type="button" className="btn-secondary" onClick={() => askDock("Suggest tables and views to build out this app.")}>
          Ask persona
        </button>
      </header>
      <form className="row" onSubmit={addNote}>
        <input
          className="input"
          value={title}
          onChange={(e: any) => setTitle(e.target.value)}
          placeholder="Add a note..."
        />
        <button className="btn-primary" type="submit">Add</button>
      </form>
      {notes.error && <p className="error">{notes.error}</p>}
      <section className="card list">
        {(notes.data?.rows ?? []).length === 0 && <p className="muted">No items yet.</p>}
        {(notes.data?.rows ?? []).map((n: Note) => (
          <div key={n.id} className="list-row">
            <span>{n.title}</span>
            <span className="muted small">{n.created_at}</span>
          </div>
        ))}
      </section>
    </main>
  );
}
`, name),
			},
		}, nil
	case "tracker":
		return Starter{
			ID:          "tracker",
			Name:        name,
			Description: "Checklist and progress tracker with sidebar filters.",
			Icon:        "check",
			Manifest: Manifest{
				Entry:     "app.tsx",
				ToolScope: ToolScopeChats,
				Nav: []NavItem{
					{ID: "all", Label: "All items", Icon: "dashboard"},
					{ID: "open", Label: "Open", Icon: "clock"},
					{ID: "done", Label: "Done", Icon: "check"},
				},
				Instructions: fmt.Sprintf("You help maintain the %q tracker app. Use get_custom_app to inspect items schema and custom_app_sql to query or update tracked items.", name),
			},
			Files: map[string]string{
				"schema.sql": `CREATE TABLE IF NOT EXISTS items (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'done')),
  priority TEXT NOT NULL DEFAULT 'medium',
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);`,
				"styles.css": baseAppCSS,
				"app.tsx": fmt.Sprintf(`import { useEffect, useState } from "react";
import { sql, useBridgeQuery, onNavSelect } from "@vesper/bridge";

export default function App() {
  const [filter, setFilter] = useState("all");
  const [title, setTitle] = useState("");
  useEffect(() => onNavSelect((id: string) => setFilter(id || "all")), []);

  const items = useBridgeQuery(
    () => filter === "all"
      ? sql("SELECT id, title, status, priority, created_at FROM items ORDER BY id DESC")
      : sql("SELECT id, title, status, priority, created_at FROM items WHERE status = ? ORDER BY id DESC", [filter]),
    [filter],
  );

  async function addItem(e: Event) {
    e.preventDefault();
    const clean = title.trim();
    if (!clean) return;
    await sql("INSERT INTO items (title) VALUES (?)", [clean]);
    setTitle("");
    items.refetch();
  }

  async function toggle(item: any) {
    const next = item.status === "done" ? "open" : "done";
    await sql("UPDATE items SET status = ? WHERE id = ?", [next, item.id]);
    items.refetch();
  }

  return (
    <main className="app-shell">
      <header className="app-header">
        <div>
          <h1>%s</h1>
          <p className="muted">Filter: {filter}</p>
        </div>
      </header>
      <form className="row" onSubmit={addItem}>
        <input className="input" value={title} onChange={(e: any) => setTitle(e.target.value)} placeholder="New item..." />
        <button className="btn-primary" type="submit">Add</button>
      </form>
      <section className="card list">
        {(items.data?.rows ?? []).length === 0 && <p className="muted">Nothing in this view.</p>}
        {(items.data?.rows ?? []).map((item: any) => (
          <div key={item.id} className="list-row">
            <label className="row">
              <input type="checkbox" checked={item.status === "done"} onChange={() => toggle(item)} />
              <span>{item.title}</span>
            </label>
            <span className="pill">{item.status}</span>
          </div>
        ))}
      </section>
    </main>
  );
}
`, name),
			},
		}, nil
	case "ledger":
		return Starter{
			ID:          "ledger",
			Name:        name,
			Description: "Structured multi-table log and summary starter backed by SQLite.",
			Icon:        "chart",
			Manifest: Manifest{
				Entry:     "app.tsx",
				ToolScope: ToolScopeChats,
				Nav: []NavItem{
					{ID: "entries", Label: "Entries", Icon: "dashboard"},
					{ID: "summary", Label: "Summary", Icon: "chart"},
				},
				Instructions: fmt.Sprintf("You help maintain the %q ledger app. Use get_custom_app and custom_app_sql to inspect or query entries.", name),
			},
			Files: map[string]string{
				"schema.sql": `CREATE TABLE IF NOT EXISTS entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  occurred_on TEXT NOT NULL DEFAULT (date('now')),
  label TEXT NOT NULL,
  category TEXT NOT NULL DEFAULT 'general',
  amount REAL NOT NULL,
  created_at TEXT NOT NULL DEFAULT (datetime('now'))
);`,
				"styles.css": baseAppCSS,
				"app.tsx": fmt.Sprintf(`import { useEffect, useState } from "react";
import { sql, useBridgeQuery, onNavSelect } from "@vesper/bridge";

export default function App() {
  const [view, setView] = useState("entries");
  const [label, setLabel] = useState("");
  const [category, setCategory] = useState("general");
  const [amount, setAmount] = useState("");
  useEffect(() => onNavSelect((id: string) => setView(id || "entries")), []);

  const entries = useBridgeQuery(() => sql("SELECT id, occurred_on, label, category, amount FROM entries ORDER BY occurred_on DESC, id DESC"), []);
  const summary = useBridgeQuery(() => sql("SELECT category, COUNT(*) AS count, ROUND(SUM(amount), 2) AS total FROM entries GROUP BY category ORDER BY total DESC"), []);

  async function addEntry(e: Event) {
    e.preventDefault();
    const num = Number(amount);
    if (!label.trim() || !Number.isFinite(num)) return;
    await sql("INSERT INTO entries (label, category, amount) VALUES (?, ?, ?)", [label.trim(), category.trim() || "general", num]);
    setLabel("");
    setAmount("");
    entries.refetch();
    summary.refetch();
  }

  return (
    <main className="app-shell">
      <header className="app-header">
        <div>
          <h1>%s</h1>
          <p className="muted">SQLite ledger template — customize tables and views freely</p>
        </div>
      </header>
      {view === "entries" ? (
        <>
          <form className="row" onSubmit={addEntry}>
            <input className="input" value={label} onChange={(e: any) => setLabel(e.target.value)} placeholder="Description" />
            <input className="input" value={category} onChange={(e: any) => setCategory(e.target.value)} placeholder="Category" />
            <input className="input" value={amount} onChange={(e: any) => setAmount(e.target.value)} placeholder="Amount" type="number" step="0.01" />
            <button className="btn-primary" type="submit">Add</button>
          </form>
          <section className="card list">
            {(entries.data?.rows ?? []).length === 0 && <p className="muted">No entries yet.</p>}
            {(entries.data?.rows ?? []).map((row: any) => (
              <div key={row.id} className="list-row">
                <div>
                  <strong>{row.label}</strong>
                  <span className="muted small"> · {row.category} · {row.occurred_on}</span>
                </div>
                <span className="mono">{Number(row.amount).toFixed(2)}</span>
              </div>
            ))}
          </section>
        </>
      ) : (
        <section className="card list">
          {(summary.data?.rows ?? []).length === 0 && <p className="muted">No categories yet.</p>}
          {(summary.data?.rows ?? []).map((row: any) => (
            <div key={row.category} className="list-row">
              <span>{row.category} ({row.count})</span>
              <span className="mono">{Number(row.total).toFixed(2)}</span>
            </div>
          ))}
        </section>
      )}
    </main>
  );
}
`, name),
			},
		}, nil
	default:
		return Starter{}, apperr.Invalid("template", "unknown template %q (use blank, tracker, or ledger)", id)
	}
}

const baseAppCSS = `:root {
  color-scheme: light dark;
}
* { box-sizing: border-box; }
body {
  margin: 0;
  padding: 20px;
  font-family: ui-sans-serif, system-ui, -apple-system, sans-serif;
  background: var(--bg, #ffffff);
  color: var(--fg, #18181b);
  font-size: 14px;
  line-height: 1.5;
}
.app-shell {
  max-width: 920px;
  margin: 0 auto;
  display: flex;
  flex-direction: column;
  gap: 16px;
}
.app-header {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
}
h1 { margin: 0; font-size: 18px; font-weight: 600; }
.muted { color: var(--fg-secondary, #71717a); }
.small { font-size: 12px; }
.mono { font-family: ui-monospace, SFMono-Regular, monospace; }
.error { color: #dc2626; font-size: 13px; margin: 0; }
.row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
.input {
  flex: 1 1 140px;
  padding: 7px 10px;
  border-radius: 6px;
  border: 1px solid var(--border, #d4d4d8);
  background: var(--surface, transparent);
  color: inherit;
  font: inherit;
}
.btn-primary, .btn-secondary {
  padding: 7px 12px;
  border-radius: 6px;
  font: inherit;
  font-weight: 500;
  cursor: pointer;
  border: 1px solid var(--border, #d4d4d8);
}
.btn-primary {
  background: var(--accent, #2563eb);
  color: #ffffff;
  border-color: transparent;
}
.btn-secondary {
  background: var(--surface, transparent);
  color: inherit;
}
.card {
  border: 1px solid var(--border, #e4e4e7);
  border-radius: 8px;
  background: var(--surface, rgba(128, 128, 128, 0.04));
  padding: 12px;
}
.list { display: flex; flex-direction: column; gap: 8px; }
.list-row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  padding: 6px 4px;
  border-bottom: 1px solid var(--border, rgba(128, 128, 128, 0.12));
}
.list-row:last-child { border-bottom: 0; }
.pill {
  font-size: 11px;
  padding: 2px 8px;
  border-radius: 999px;
  border: 1px solid var(--border, #d4d4d8);
}
`
