// Pure view logic for the Runs page (LAZYAGENTS-163): the grouped run list
// beside the run thread, the Next line, and facts the Context panel reads
// from a run's events. Unit-tested in run-list.test.mjs.

import { PURPOSE_LABEL, str, toolName, type Ev } from "./run-view.ts";

type ListRun = {
  id: string;
  state: string;
  wait_reason?: string | null;
  started_at: string;
  ended_at?: string | null;
  ticket_key: string;
  work_title?: string;
  purpose: string;
  agent: { name: string; handle: string };
  plan: { position: number; text: string; state: string }[];
};

type NeedsItem = { id: string; title: string; href: string; run_id?: string; project: string; ticket_key: string; agent?: { name: string; handle: string } };

const ENDED = ["completed", "failed", "cancelled"];

export const isEnded = (state: string) => ENDED.includes(state);

/** The row's title: what the run works on, else its purpose. */
export function runTitle(run: Pick<ListRun, "work_title" | "ticket_key" | "purpose">): string {
  return run.work_title || run.ticket_key || PURPOSE_LABEL[run.purpose] || "Run";
}

/** The row's muted line: the current plan step while live, else ticket key · agent. */
export function runLine(run: ListRun): string {
  if (!isEnded(run.state)) {
    const steps = [...run.plan].sort((a, b) => a.position - b.position);
    const i = steps.findIndex((s) => s.state === "current");
    if (i >= 0) return `Step ${i + 1} of ${steps.length} · ${steps[i].text}`;
  }
  return [run.ticket_key || PURPOSE_LABEL[run.purpose], run.agent.name].filter(Boolean).join(" · ");
}

export type Dot = "human" | "running" | "queued" | "done" | "failed" | "idle";

/** The row's status dot. */
export function runDot(run: Pick<ListRun, "state" | "wait_reason">, needsYou = false): Dot {
  if (needsYou) return "human";
  if (run.state === "failed" || run.state === "blocked") return "failed";
  if (run.state === "completed") return "done";
  if (run.state === "cancelled") return "idle";
  if (run.state === "queued") return "queued";
  if (run.state === "paused" || (run.state === "waiting" && ["approval", "human_reply", "mockup_review"].includes(run.wait_reason ?? ""))) return "human";
  return "running";
}

/** Case-insensitive match on title, ticket key, agent and purpose. */
export function matchesRun(run: ListRun, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return [run.work_title, run.ticket_key, run.agent.name, run.agent.handle, PURPOSE_LABEL[run.purpose]].some((s) => s?.toLowerCase().includes(q));
}

export function matchesItem(item: NeedsItem, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (!q) return true;
  return [item.title, item.ticket_key, item.agent?.name, item.agent?.handle].some((s) => s?.toLowerCase().includes(q));
}

const startOfDay = (d: Date) => new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();

/** "Earlier today", "Yesterday", a weekday within the week, else a date. */
export function dayLabel(iso: string, now: Date): string {
  const d = new Date(iso);
  const days = Math.round((startOfDay(now) - startOfDay(d)) / 86_400_000);
  if (days <= 0) return "Earlier today";
  if (days === 1) return "Yesterday";
  if (days < 7) return d.toLocaleDateString(undefined, { weekday: "long" });
  return d.toLocaleDateString(undefined, { month: "short", day: "numeric", ...(d.getFullYear() !== now.getFullYear() ? { year: "numeric" } : {}) });
}

export type RunGroup<R> = { key: string; label: string; runs: R[] };

/**
 * Running (live and not queued) and Queued, then finished runs by the day
 * they ended, latest first. Runs in `skip` (shown under Needs you) are left
 * out; duplicates across pages are dropped.
 */
export function groupRuns<R extends ListRun>(runs: readonly R[], skip: ReadonlySet<string>, now: Date): RunGroup<R>[] {
  const seen = new Set<string>();
  const shown = runs.filter((r) => !skip.has(r.id) && !seen.has(r.id) && !!seen.add(r.id));
  const byStart = (a: R, b: R) => Date.parse(b.started_at) - Date.parse(a.started_at);
  const running = shown.filter((r) => !isEnded(r.state) && r.state !== "queued").sort(byStart);
  const queued = shown.filter((r) => r.state === "queued").sort(byStart);
  const endAt = (r: R) => r.ended_at ?? r.started_at;
  const ended = shown.filter((r) => isEnded(r.state)).sort((a, b) => Date.parse(endAt(b)) - Date.parse(endAt(a)));
  const out: RunGroup<R>[] = [];
  if (running.length) out.push({ key: "running", label: "Running", runs: running });
  if (queued.length) out.push({ key: "queued", label: "Queued", runs: queued });
  for (const r of ended) {
    const label = dayLabel(endAt(r), now);
    const last = out.at(-1);
    if (last && last.key === `day:${label}`) last.runs.push(r);
    else out.push({ key: `day:${label}`, label, runs: [r] });
  }
  return out;
}

/** Where a Needs you item opens: its run on this page, else its own page. */
export function itemHref(item: Pick<NeedsItem, "run_id" | "href">, query = ""): string {
  return item.run_id ? `/runs/${item.run_id}${query ? `?${query}` : ""}` : item.href;
}

/** The Needs you item after the one for `runId` (wrapping), else the first one not for it. */
export function nextNeedsItem<I extends Pick<NeedsItem, "id" | "run_id">>(items: readonly I[], runId: string): I | undefined {
  const at = items.findIndex((i) => i.run_id === runId);
  const rest = at < 0 ? items : [...items.slice(at + 1), ...items.slice(0, at)];
  return rest.find((i) => i.run_id !== runId);
}

/** The runner slot a run started on, from its `starting` lifecycle event. */
export function runnerSlot(events: readonly Ev[]): { runner: string; backend: string } | null {
  for (let i = events.length - 1; i >= 0; i--) {
    const e = events[i];
    const p = (e.payload ?? {}) as Record<string, unknown>;
    if (e.type === "lifecycle" && p.state === "starting" && (p.runner || p.backend)) return { runner: str(p.runner), backend: str(p.backend) };
  }
  return null;
}

const WRITE_TOOLS = new Set(["Edit", "Write", "MultiEdit", "NotebookEdit", "apply_patch", "edit", "write", "patch"]);
const READ_TOOLS = new Set(["Read", "read", "view"]);

export type TouchedFile = { path: string; writes: number; reads: number };

/** Files the run's tool calls read or changed, changed ones first, then by path. */
export function touchedFiles(events: readonly Ev[]): TouchedFile[] {
  const files = new Map<string, TouchedFile>();
  for (const e of events) {
    if (e.type !== "tool_call") continue;
    const p = (e.payload ?? {}) as Record<string, unknown>;
    const name = toolName(str(p.tool));
    const write = WRITE_TOOLS.has(name);
    if (!write && !READ_TOOLS.has(name)) continue;
    const input = (p.input ?? {}) as Record<string, unknown>;
    const path = str(input.file_path ?? input.path ?? input.notebook_path).trim();
    if (!path) continue;
    const f = files.get(path) ?? { path, writes: 0, reads: 0 };
    if (write) f.writes += 1;
    else f.reads += 1;
    files.set(path, f);
  }
  return [...files.values()].sort((a, b) => Number(b.writes > 0) - Number(a.writes > 0) || a.path.localeCompare(b.path));
}
