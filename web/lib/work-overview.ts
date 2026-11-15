import type { components } from "./api/schema";
import { dayLabel, isEnded, type Dot } from "./run-list.ts";
import { needsYouByTicket, type NeedsYou } from "./work-rows.ts";

type S = components["schemas"];
export type Run = S["Run"];
export type InboxItem = S["InboxItem"];
export type RunnerStatus = S["RunnerStatus"];
export type CostReport = S["CostReport"];
export type TicketSummary = S["TicketSummary"];
export type EpicOverview = S["EpicOverview"];

export type ActivityFilter = "all" | "needs_you" | "active" | "failed";

/** Parse Activity sidebar filter from query params (`filter`, falling back from legacy `done=hide`). */
export function parseActivityFilter(filterParam: string | null | undefined, legacyDone?: string | null): ActivityFilter {
  if (filterParam === "needs_you" || filterParam === "active" || filterParam === "failed" || filterParam === "all") {
    return filterParam;
  }
  if (legacyDone === "hide") return "active";
  return "all";
}

/** True when a run has an active human wait (or matching unresolved inbox item). */
export function isRunNeedsYou(run: Pick<Run, "id" | "state" | "wait_reason">, needsRunIds: ReadonlySet<string>): boolean {
  if (needsRunIds.has(run.id)) return true;
  return run.state === "waiting" && run.wait_reason !== "delegation";
}

/** True when a run has failed or blocked in a terminal/error state. */
export function isRunFailed(run: Pick<Run, "state">): boolean {
  return run.state === "failed" || run.state === "blocked";
}

/** Local-calendar same-day comparison against `now`. */
export function isSameLocalDay(iso: string | undefined, now = new Date()): boolean {
  if (!iso) return false;
  const d = new Date(iso);
  return (
    d.getFullYear() === now.getFullYear() &&
    d.getMonth() === now.getMonth() &&
    d.getDate() === now.getDate()
  );
}

/** Sidebar `VIEW` counters for Activity runs. */
export function computeActivityViewCounts(
  runs: readonly Run[],
  needsRunIds: ReadonlySet<string>,
  now = new Date(),
): Record<ActivityFilter, number> {
  const seen = new Set<string>();
  let all = 0;
  let needs_you = 0;
  let active = 0;
  let failed = 0;
  for (const r of runs) {
    if (seen.has(r.id)) continue;
    seen.add(r.id);
    all += 1;
    if (isRunNeedsYou(r, needsRunIds)) needs_you += 1;
    if (!isEnded(r.state)) active += 1;
    if (isRunFailed(r) && isSameLocalDay(r.ended_at ?? r.started_at, now)) failed += 1;
  }
  return { all, needs_you, active, failed };
}

/** Filter Activity runs according to the selected sidebar `VIEW`. */
export function filterActivityRuns(
  runs: readonly Run[],
  filter: ActivityFilter,
  needsRunIds: ReadonlySet<string>,
  now = new Date(),
): Run[] {
  if (filter === "all") return [...runs];
  if (filter === "needs_you") return runs.filter((r) => isRunNeedsYou(r, needsRunIds));
  if (filter === "active") return runs.filter((r) => !isEnded(r.state) || isRunNeedsYou(r, needsRunIds));
  return runs.filter((r) => isRunFailed(r) && isSameLocalDay(r.ended_at ?? r.started_at, now));
}

export type ActivitySidebarGroup = { label: string; kind: "active" | "history"; runs: Run[] };

/** Compact Activity sidebar grouping: single `Active` group followed by day buckets (`Earlier today`, `Yesterday`, ...). */
export function groupActivitySidebarRuns(runs: readonly Run[], now = new Date()): ActivitySidebarGroup[] {
  const active: Run[] = [];
  const days = new Map<string, Run[]>();
  const seen = new Set<string>();

  for (const r of runs) {
    if (seen.has(r.id)) continue;
    seen.add(r.id);
    if (!isEnded(r.state)) {
      active.push(r);
      continue;
    }
    const label = dayLabel(r.ended_at ?? r.started_at, now);
    const list = days.get(label) ?? [];
    list.push(r);
    days.set(label, list);
  }

  const out: ActivitySidebarGroup[] = [];
  if (active.length > 0) out.push({ label: "Active", kind: "active", runs: active });
  for (const [label, bucket] of days) out.push({ label, kind: "history", runs: bucket });
  return out;
}

/** Single-word / short right-column badge for 1-line Activity sidebar rows. */
export function compactRunTime(
  run: Pick<Run, "state" | "wait_reason" | "started_at" | "ended_at">,
  dot: Dot,
  now = new Date(),
): string {
  if (dot === "human") return "wait";
  if (dot === "running") return "live";
  if (run.state === "queued") return "queue";
  const ts = new Date(run.ended_at ?? run.started_at).getTime();
  const sec = Math.max(0, Math.round((now.getTime() - ts) / 1000));
  if (sec < 60) return "now";
  const min = Math.round(sec / 60);
  if (min < 60) return `${min}m`;
  const hrs = Math.round(min / 60);
  if (hrs < 24) return `${hrs}h`;
  return `${Math.round(hrs / 24)}d`;
}

export type ActivityStats = {
  slotsBusy: number;
  slotsMax: number;
  queued: number;
  online: boolean;
  needsYouCount: number;
  needsApprovals: number;
  needsQuestions: number;
  needsReviews: number;
  completedToday: number;
  prsToday: number;
  passRatePct: number | null;
  passed24h: number;
  totalTerminal24h: number;
  spend7dUsd: number | null;
  unpriced7d: number;
};

/** Compute top KPI telemetry strip for the Activity overview without inventing unavailable fields. */
export function computeActivityStats(
  runs: readonly Run[],
  inbox: readonly InboxItem[],
  runner: RunnerStatus | undefined,
  costs7d: CostReport | undefined,
  now = new Date(),
): ActivityStats {
  const openNeeds = inbox.filter((i) => i.needs_you && !i.resolved && !i.read);
  let needsApprovals = 0;
  let needsQuestions = 0;
  let needsReviews = 0;
  for (const item of openNeeds) {
    if (item.kind === "approval") needsApprovals += 1;
    else if (item.kind === "question") needsQuestions += 1;
    else needsReviews += 1;
  }

  let completedToday = 0;
  const prSet = new Set<number>();
  const cutoff24h = now.getTime() - 24 * 60 * 60 * 1000;
  let passed24h = 0;
  let totalTerminal24h = 0;

  for (const r of runs) {
    const endIso = r.ended_at ?? r.started_at;
    const endMs = new Date(endIso).getTime();
    if (isEnded(r.state) && endMs >= cutoff24h) {
      if (r.state === "completed") {
        passed24h += 1;
        totalTerminal24h += 1;
      } else if (isRunFailed(r)) {
        totalTerminal24h += 1;
      }
    }
    if (r.state === "completed" && isSameLocalDay(endIso, now)) {
      completedToday += 1;
      if (r.pr_number) prSet.add(r.pr_number);
    }
  }

  return {
    slotsBusy: runner?.busy ?? 0,
    slotsMax: runner?.slots ?? 0,
    queued: runner?.queued ?? 0,
    online: runner?.online ?? false,
    needsYouCount: openNeeds.length,
    needsApprovals,
    needsQuestions,
    needsReviews,
    completedToday,
    prsToday: prSet.size,
    passRatePct: totalTerminal24h > 0 ? Math.round((passed24h / totalTerminal24h) * 100) : null,
    passed24h,
    totalTerminal24h,
    spend7dUsd: costs7d ? costs7d.total.cost_micros / 1_000_000 : null,
    unpriced7d: costs7d?.unpriced_runs ?? 0,
  };
}

export type TaskQueueKey = "needs_you" | "in_progress" | "ready" | "blocked" | "all";

/** Match a ticket against one of the Work Tasks sidebar queue filters. */
export function matchesTaskQueue(
  t: TicketSummary,
  queue: TaskQueueKey,
  needsMap: ReadonlyMap<string, NeedsYou>,
): boolean {
  if (queue === "all") return true;
  if (queue === "needs_you") return needsMap.has(t.key);
  if (queue === "in_progress") return t.status === "in_progress" || t.status === "in_review";
  if (queue === "ready") return t.status === "todo" && t.unmet_dependencies === 0 && !!t.assignee;
  return t.unmet_dependencies > 0;
}

/** Count tickets per Tasks sidebar queue without double-scanning. */
export function computeTaskQueueCounts(
  tickets: readonly TicketSummary[],
  inbox: readonly InboxItem[] = [],
): Record<TaskQueueKey, number> {
  const needsMap = needsYouByTicket(inbox);
  let needs_you = 0;
  let in_progress = 0;
  let ready = 0;
  let blocked = 0;
  for (const t of tickets) {
    if (needsMap.has(t.key)) needs_you += 1;
    if (t.status === "in_progress" || t.status === "in_review") in_progress += 1;
    if (t.status === "todo" && t.unmet_dependencies === 0 && !!t.assignee) ready += 1;
    if (t.unmet_dependencies > 0) blocked += 1;
  }
  return { needs_you, in_progress, ready, blocked, all: tickets.length };
}

export type SidebarEpicSummary = {
  id: string;
  name: string;
  done: number;
  total: number;
  pct: number;
  inProgress: number;
};

/** Summarize epics for the Tasks left sidebar `BY EPIC` progress list. */
export function computeSidebarEpics(
  epics: readonly EpicOverview[],
  projectKey?: string,
): SidebarEpicSummary[] {
  return epics
    .filter((e) => !projectKey || e.project.key === projectKey)
    .filter((e) => e.epic.status === "open")
    .map((e) => {
      const done = e.counts.done;
      const total = e.counts.total;
      const pct = total > 0 ? Math.round((done / total) * 100) : 0;
      const inProgress = e.counts.in_progress + e.counts.in_review;
      return { id: e.epic.id, name: e.epic.name, done, total, pct, inProgress };
    });
}

export type EpicViewFilter = "active" | "at_risk" | "completed";

/** Count epics across the three Epics sidebar `VIEWS`. */
export function computeEpicViewCounts(overviews: readonly EpicOverview[]): Record<EpicViewFilter, number> {
  let active = 0;
  let at_risk = 0;
  let completed = 0;
  for (const o of overviews) {
    if (o.epic.status === "done") {
      completed += 1;
    } else {
      active += 1;
      if (o.epic.health === "at_risk" || o.epic.health === "off_track") at_risk += 1;
    }
  }
  return { active, at_risk, completed };
}

export type WaveTicketInput = {
  id: string;
  key: string;
  title: string;
  status: S["TicketStatus"];
  priority: S["Priority"];
  unmet_dependencies?: number;
  assignee?: S["AgentRef"];
  estimate_points?: S["EstimatePoints"];
  blocked_by?: readonly string[];
};

export type ExecutionWave = {
  wave: number;
  status: "done" | "current" | "queued";
  tickets: WaveTicketInput[];
  readyTickets: WaveTicketInput[];
};

/**
 * Group an epic's tickets into topological execution waves (`Wave 1`, `Wave 2`, ...).
 * When explicit `blocked_by` edges are present, compute longest-path wave depth with
 * cycle protection; otherwise fall back cleanly to Wave 1 (`unmet_dependencies === 0` or
 * done/active) and Wave 2 (`unmet_dependencies > 0`).
 */
export function computeEpicWaves(tickets: readonly WaveTicketInput[]): ExecutionWave[] {
  if (tickets.length === 0) return [];
  const byKey = new Map<string, WaveTicketInput>();
  for (const t of tickets) byKey.set(t.key, t);

  const hasExplicitEdges = tickets.some((t) => (t.blocked_by?.length ?? 0) > 0);
  const depthMemo = new Map<string, number>();

  const depthOf = (key: string, stack: Set<string>): number => {
    const cached = depthMemo.get(key);
    if (cached !== undefined) return cached;
    if (stack.has(key)) return 1; // break dependency cycle safely
    const t = byKey.get(key);
    if (!t) return 1;
    stack.add(key);
    let maxParent = 0;
    if (hasExplicitEdges && t.blocked_by && t.blocked_by.length > 0) {
      for (const bKey of t.blocked_by) {
        if (!byKey.has(bKey)) continue;
        maxParent = Math.max(maxParent, depthOf(bKey, stack));
      }
    } else if ((t.unmet_dependencies ?? 0) > 0 && t.status !== "done" && t.status !== "canceled") {
      maxParent = 1;
    }
    stack.delete(key);
    const wave = maxParent + 1;
    depthMemo.set(key, wave);
    return wave;
  };

  const buckets = new Map<number, WaveTicketInput[]>();
  for (const t of tickets) {
    const w = depthOf(t.key, new Set());
    const list = buckets.get(w) ?? [];
    list.push(t);
    buckets.set(w, list);
  }

  const sortedNums = [...buckets.keys()].sort((a, b) => a - b);
  let assignedCurrent = false;
  return sortedNums.map((wave) => {
    const list = buckets.get(wave)!;
    const allTerminal = list.every((t) => t.status === "done" || t.status === "canceled");
    const hasLive = list.some((t) => t.status === "in_progress" || t.status === "in_review");
    let status: ExecutionWave["status"];
    if (allTerminal) {
      status = "done";
    } else if (!assignedCurrent || hasLive) {
      status = "current";
      assignedCurrent = true;
    } else {
      status = "queued";
    }
    const readyTickets = list.filter(
      (t) => t.status === "todo" && (t.unmet_dependencies ?? 0) === 0 && !!t.assignee,
    );
    return { wave, status, tickets: list, readyTickets };
  });
}

/** Portfolio-level telemetry summary across open epics in view. */
export function computeEpicPortfolioStats(
  overviews: readonly EpicOverview[],
  wavesByEpic: ReadonlyMap<string, readonly ExecutionWave[]> = new Map(),
): {
  openCount: number;
  pointsDone: number;
  pointsTotal: number;
  progressPct: number;
  readyAcrossEpics: number;
} {
  let openCount = 0;
  let pointsDone = 0;
  let pointsTotal = 0;
  let readyAcrossEpics = 0;
  for (const o of overviews) {
    if (o.epic.status === "open") {
      openCount += 1;
      pointsDone += o.epic.points_done;
      pointsTotal += o.epic.points_total;
      const waves = wavesByEpic.get(o.epic.id);
      if (waves) {
        for (const w of waves) readyAcrossEpics += w.readyTickets.length;
      }
    }
  }
  const progressPct = pointsTotal > 0 ? Math.round((pointsDone / pointsTotal) * 100) : 0;
  return { openCount, pointsDone, pointsTotal, progressPct, readyAcrossEpics };
}
