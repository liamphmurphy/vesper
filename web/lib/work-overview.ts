import type { components } from "./api/schema";
import { needsYouByTicket, type NeedsYou } from "./work-rows.ts";

type S = components["schemas"];
export type InboxItem = S["InboxItem"];
export type TicketSummary = S["TicketSummary"];
export type EpicOverview = S["EpicOverview"];

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
