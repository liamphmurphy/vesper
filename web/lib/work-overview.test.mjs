import test from "node:test";
import assert from "node:assert/strict";
import {
  compactRunTime,
  computeActivityStats,
  computeActivityViewCounts,
  computeEpicPortfolioStats,
  computeEpicViewCounts,
  computeEpicWaves,
  computeSidebarEpics,
  computeTaskQueueCounts,
  filterActivityRuns,
  groupActivitySidebarRuns,
  matchesTaskQueue,
  parseActivityFilter,
} from "./work-overview.ts";

const now = new Date(2026, 10, 15, 14, 0, 0);
const isoAt = (dayOffset, hour = 10) => new Date(2026, 10, 15 - dayOffset, hour, 0, 0).toISOString();

const mkRun = (id, over = {}) => ({
  id,
  ticket_key: "WEB-1",
  work_title: `Run ${id}`,
  purpose: "ticket",
  project_key: "WEB",
  agent: { id: "a1", handle: "builder", name: "Builder", color_index: 0 },
  mode: "managed",
  state: "running",
  harness: "claude-code",
  model: "opus",
  started_at: isoAt(0, 12),
  tool_calls: 1,
  input_tokens: 100,
  output_tokens: 50,
  cost_usd: 0.25,
  plan: [],
  scopes: [],
  approval_scopes: [],
  ...over,
});

const mkTicket = (key, over = {}) => ({
  id: key,
  key,
  project_key: "WEB",
  title: `Ticket ${key}`,
  status: "todo",
  priority: "medium",
  labels: [],
  unmet_dependencies: 0,
  criteria_total: 2,
  criteria_done: 1,
  updated_at: isoAt(0, 11),
  ...over,
});

test("parseActivityFilter maps URL values and legacy done=hide", () => {
  assert.equal(parseActivityFilter("needs_you"), "needs_you");
  assert.equal(parseActivityFilter("active"), "active");
  assert.equal(parseActivityFilter("failed"), "failed");
  assert.equal(parseActivityFilter(null, "hide"), "active");
  assert.equal(parseActivityFilter(null, null), "all");
  assert.equal(parseActivityFilter("unknown"), "all");
});

test("computeActivityViewCounts and filterActivityRuns keep counts consistent", () => {
  const runs = [
    mkRun("r-wait", { state: "waiting", wait_reason: "approval" }),
    mkRun("r-live", { state: "running" }),
    mkRun("r-queue", { state: "queued" }),
    mkRun("r-fail-today", { state: "failed", ended_at: isoAt(0, 9) }),
    mkRun("r-fail-old", { state: "failed", started_at: isoAt(2, 9), ended_at: isoAt(2, 10) }),
    mkRun("r-done", { state: "completed", ended_at: isoAt(0, 11), pr_number: 412 }),
    mkRun("r-live"), // duplicate deduplicated in counts
  ];
  const needsIds = new Set(["r-wait"]);
  assert.deepEqual(computeActivityViewCounts(runs, needsIds, now), {
    all: 6,
    needs_you: 1,
    active: 3,
    failed: 1,
  });
  assert.deepEqual(
    filterActivityRuns(runs.slice(0, 6), "needs_you", needsIds, now).map((r) => r.id),
    ["r-wait"],
  );
  assert.deepEqual(
    filterActivityRuns(runs.slice(0, 6), "active", needsIds, now).map((r) => r.id),
    ["r-wait", "r-live", "r-queue"],
  );
  assert.deepEqual(
    filterActivityRuns(runs.slice(0, 6), "failed", needsIds, now).map((r) => r.id),
    ["r-fail-today"],
  );
});

test("groupActivitySidebarRuns groups Active first then day buckets, and compactRunTime formats short badges", () => {
  const runs = [
    mkRun("r-wait", { state: "waiting", wait_reason: "human_reply" }),
    mkRun("r-live", { state: "running" }),
    mkRun("r-today", { state: "completed", ended_at: isoAt(0, 12) }),
    mkRun("r-yest", { state: "completed", ended_at: isoAt(1, 15) }),
  ];
  const groups = groupActivitySidebarRuns(runs, now);
  assert.deepEqual(
    groups.map((g) => [g.label, g.kind, g.runs.map((r) => r.id)]),
    [
      ["Active", "active", ["r-wait", "r-live"]],
      ["Earlier today", "history", ["r-today"]],
      ["Yesterday", "history", ["r-yest"]],
    ],
  );
  assert.equal(compactRunTime(runs[0], "human", now), "wait");
  assert.equal(compactRunTime(runs[1], "running", now), "live");
  assert.equal(compactRunTime(mkRun("q", { state: "queued" }), "queued", now), "queue");
  assert.equal(compactRunTime(runs[2], "done", now), "2h");
});

test("computeActivityStats derives pass rate, PR velocity, needs breakdown, and 7d spend", () => {
  const runs = [
    mkRun("c1", { state: "completed", started_at: isoAt(0, 8), ended_at: isoAt(0, 9), pr_number: 410 }),
    mkRun("c2", { state: "completed", started_at: isoAt(0, 10), ended_at: isoAt(0, 11), pr_number: 410 }), // same PR counted once
    mkRun("c3", { state: "completed", started_at: isoAt(0, 11), ended_at: isoAt(0, 12), pr_number: 411 }),
    mkRun("f1", { state: "failed", started_at: isoAt(0, 7), ended_at: isoAt(0, 8) }),
    mkRun("old", { state: "failed", started_at: isoAt(3, 7), ended_at: isoAt(3, 8) }),
  ];
  const inbox = [
    { id: "a1", kind: "approval", title: "x", summary: "", href: "/", project: "WEB", ticket_key: "WEB-1", created_at: isoAt(0, 12), resolved: false, read: false, needs_you: true },
    { id: "q1", kind: "question", title: "y", summary: "", href: "/", project: "WEB", ticket_key: "WEB-2", created_at: isoAt(0, 12), resolved: false, read: false, needs_you: true },
    { id: "r1", kind: "review", title: "z", summary: "", href: "/", project: "WEB", ticket_key: "WEB-3", created_at: isoAt(0, 12), resolved: false, read: false, needs_you: true },
    { id: "ignored", kind: "review", title: "read", summary: "", href: "/", project: "WEB", ticket_key: "WEB-4", created_at: isoAt(0, 12), resolved: false, read: true, needs_you: true },
  ];
  const runner = { online: true, busy: 2, queued: 1, slots: 6, max_concurrent: 6 };
  const costs7d = {
    total: { key: "total", label: "Total", runs: 5, tokens: 1000, cost_micros: 18_420_000, unpriced_runs: 1 },
    unpriced_runs: 1,
    estimated: { tickets: 0, points: 0, cost_micros: 0 },
    days: [],
    agents: [],
    projects: [],
    models: [],
    purposes: [],
    top_tickets: [],
  };
  const stats = computeActivityStats(runs, inbox, runner, costs7d, now);
  assert.equal(stats.slotsBusy, 2);
  assert.equal(stats.slotsMax, 6);
  assert.equal(stats.queued, 1);
  assert.equal(stats.needsYouCount, 3);
  assert.equal(stats.needsApprovals, 1);
  assert.equal(stats.needsQuestions, 1);
  assert.equal(stats.needsReviews, 1);
  assert.equal(stats.completedToday, 3);
  assert.equal(stats.prsToday, 2);
  assert.equal(stats.passRatePct, 75);
  assert.equal(stats.spend7dUsd, 18.42);
  assert.equal(stats.unpriced7d, 1);
  assert.equal(stats.online, true);
  assert.equal(stats.starting, false);

  const startingStats = computeActivityStats(runs, inbox, { ...runner, online: false, starting: true }, costs7d, now);
  assert.equal(startingStats.online, false);
  assert.equal(startingStats.starting, true);
});

test("Task queue counts and matchesTaskQueue classify needs_you, in_progress, ready, and blocked", () => {
  const assignee = { id: "a1", name: "Builder", handle: "builder", color_index: 0 };
  const tickets = [
    mkTicket("WEB-1", { status: "in_progress", assignee }),
    mkTicket("WEB-2", { status: "todo", assignee, unmet_dependencies: 0 }),
    mkTicket("WEB-3", { status: "todo", assignee, unmet_dependencies: 2 }),
    mkTicket("WEB-4", { status: "todo", unmet_dependencies: 0 }), // unassigned not ready
    mkTicket("WEB-5", { status: "in_review", assignee }),
  ];
  const inbox = [
    { id: "q:r1", kind: "question", title: "q", summary: "", href: "/", project: "WEB", ticket_key: "WEB-1", created_at: isoAt(0, 12), resolved: false, read: false, needs_you: true },
  ];
  assert.deepEqual(computeTaskQueueCounts(tickets, inbox), {
    needs_you: 1,
    in_progress: 2,
    ready: 1,
    blocked: 1,
    all: 5,
  });
  const needsMap = new Map([["WEB-1", inbox[0]]]);
  assert.equal(matchesTaskQueue(tickets[1], "ready", needsMap), true);
  assert.equal(matchesTaskQueue(tickets[3], "ready", needsMap), false);
  assert.equal(matchesTaskQueue(tickets[2], "blocked", needsMap), true);
});

test("Epics views, sidebar summaries, and topological computeEpicWaves handle multi-wave deps and cycles", () => {
  const mkEpic = (id, name, over = {}) => ({
    epic: { id, name, status: "open", health: "on_track", points_done: 5, points_total: 10, ...over.epic },
    project: { id: "p1", key: over.projectKey ?? "WEB", name: "Web", default_branch: "main", ...over.project },
    objective: "Ship",
    counts: { total: 4, done: 2, backlog: 0, todo: 1, in_progress: 1, in_review: 0, ...over.counts },
    agents: [],
    agent_seconds: 120,
    tickets: [],
  });
  const overviews = [
    mkEpic("e1", "Work Rethink"),
    mkEpic("e2", "Billing", { epic: { health: "at_risk" } }),
    mkEpic("e3", "Old Epic", { epic: { status: "done" } }),
  ];
  assert.deepEqual(computeEpicViewCounts(overviews), { active: 2, at_risk: 1, completed: 1 });
  assert.deepEqual(computeSidebarEpics(overviews, "WEB"), [
    { id: "e1", name: "Work Rethink", done: 2, total: 4, pct: 50, inProgress: 1 },
    { id: "e2", name: "Billing", done: 2, total: 4, pct: 50, inProgress: 1 },
  ]);

  const assignee = { id: "a1", name: "Builder", handle: "builder", color_index: 0 };
  const waveTickets = [
    { id: "1", key: "WEB-1", title: "Base", status: "done", priority: "high", blocked_by: [] },
    { id: "2", key: "WEB-2", title: "Wave2 A", status: "in_progress", priority: "high", assignee, unmet_dependencies: 0, blocked_by: ["WEB-1"] },
    { id: "3", key: "WEB-3", title: "Wave2 B", status: "todo", priority: "medium", assignee, unmet_dependencies: 0, blocked_by: ["WEB-1"] },
    { id: "4", key: "WEB-4", title: "Wave3 Final", status: "todo", priority: "low", assignee, unmet_dependencies: 1, blocked_by: ["WEB-2", "WEB-3"] },
  ];
  const waves = computeEpicWaves(waveTickets);
  assert.deepEqual(
    waves.map((w) => [w.wave, w.status, w.tickets.map((t) => t.key), w.readyTickets.map((t) => t.key)]),
    [
      [1, "done", ["WEB-1"], []],
      [2, "current", ["WEB-2", "WEB-3"], ["WEB-3"]],
      [3, "queued", ["WEB-4"], []],
    ],
  );

  // Cycle protection: never infinite loops
  const cyclic = [
    { id: "a", key: "C-1", title: "A", status: "todo", priority: "low", blocked_by: ["C-2"] },
    { id: "b", key: "C-2", title: "B", status: "todo", priority: "low", blocked_by: ["C-1"] },
  ];
  assert.equal(computeEpicWaves(cyclic).length > 0, true);

  const portfolio = computeEpicPortfolioStats(overviews, new Map([["e1", waves]]));
  assert.equal(portfolio.openCount, 2);
  assert.equal(portfolio.pointsDone, 10);
  assert.equal(portfolio.pointsTotal, 20);
  assert.equal(portfolio.progressPct, 50);
  assert.equal(portfolio.readyAcrossEpics, 1);
});
