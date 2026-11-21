import test from "node:test";
import assert from "node:assert/strict";
import {
  computeEpicPortfolioStats,
  computeEpicViewCounts,
  computeEpicWaves,
  computeSidebarEpics,
  computeTaskQueueCounts,
  matchesTaskQueue,
} from "./work-overview.ts";

const isoAt = (dayOffset, hour = 10) => new Date(2026, 10, 15 - dayOffset, hour, 0, 0).toISOString();

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
