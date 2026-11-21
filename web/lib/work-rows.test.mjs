import test from "node:test";
import assert from "node:assert/strict";
import {
  approvalId,
  epicProgress,
  filterText,
  needsYouByTicket,
  parseFilterText,
  resolveFilter,
  startReady,
  stateText,
  ticketNeedsYou,
  weekStart,
  withoutProjectToken,
  workGroups,
} from "./work-rows.ts";

const t = (key, over = {}) => ({
  id: key, key, project_key: "LA", title: key, status: "todo", priority: "none", labels: [],
  criteria_total: 0, criteria_done: 0, unmet_dependencies: 0, updated_at: "2026-11-12T12:00:00Z", ...over,
});
const item = (id, kind, ticket_key, over = {}) => ({ id, kind, ticket_key, resolved: false, read: false, needs_you: true, summary: "", href: "/x", created_at: "2026-11-12T10:00:00Z", ...over });

test("needsYouByTicket keeps open items the server marks needs_you, most urgent per ticket", () => {
  const m = needsYouByTicket([
    item("question:r1", "question", "LA-1", { summary: "Which DB?" }),
    item("approval:a1", "approval", "LA-1", { summary: "Run migration" }),
    item("approval:a2", "approval", "LA-2", { resolved: true }),
    item("blocked:r4", "blocked", "LA-4"),
    item("planning:p", "planning", ""),
    // Actionable kinds beyond approvals, questions and blocked runs.
    item("review:t3", "review", "LA-3", { summary: "PR #12" }),
    item("dispatch:t5", "dispatch", "LA-5"),
    // A mention the server promotes to needs you (it asks a question), and one it doesn't.
    item("mention:c6", "mention", "LA-6", { summary: "Can you check the copy?" }),
    item("mention:c7", "mention", "LA-7", { needs_you: false }),
    // Marked done in the tray, so not waiting any more.
    item("review:t8", "review", "LA-8", { read: true }),
  ]);
  assert.deepEqual([...m.keys()].sort(), ["LA-1", "LA-3", "LA-4", "LA-5", "LA-6"]);
  assert.equal(m.get("LA-1").kind, "approval");
  assert.equal(m.get("LA-3").kind, "review");
  assert.equal(m.get("LA-5").kind, "dispatch");
  assert.equal(m.get("LA-6").kind, "mention");
  assert.equal(approvalId(m.get("LA-1")), "a1");
  assert.equal(approvalId(m.get("LA-4")), undefined);
});

test("needsYouByTicket ranks by the Inbox's urgency order, then the longest wait", () => {
  const m = needsYouByTicket([
    item("mention:c1", "mention", "LA-1", { created_at: "2026-11-12T08:00:00Z" }),
    item("review:t1", "review", "LA-1", { created_at: "2026-11-12T11:00:00Z" }),
    item("question:r2", "question", "LA-2", { created_at: "2026-11-12T11:00:00Z" }),
    item("question:r3", "question", "LA-2", { created_at: "2026-11-12T09:00:00Z" }),
  ]);
  assert.equal(m.get("LA-1").id, "review:t1");
  assert.equal(m.get("LA-2").id, "question:r3");
});

test("stateText gives every needs-you kind a state text", () => {
  for (const kind of ["approval", "question", "blocked", "stalled", "pr_ci_failed", "pr_review_comments", "mockup", "planning", "review", "dispatch", "mention", "suggestion", "workflow_gate", "scheduled", "connector_approval", "secret_approval", "secret_expiring", "merged"]) {
    const s = stateText(t("A"), { kind, summary: "" });
    assert.equal(s.tone, "human");
    assert.ok(s.text && s.text !== "Needs you", kind);
  }
  assert.equal(stateText(t("A"), { kind: "review", summary: "PR #12" }).text, "Review requested: PR #12");
});

test("stateText: needs you is amber, then blocked, then status", () => {
  assert.deepEqual(stateText(t("A"), { kind: "approval", summary: "Push" }), { text: "Wants approval: Push", tone: "human" });
  assert.deepEqual(stateText(t("A", { unmet_dependencies: 2 })), { text: "Blocked by 2", tone: "blocked" });
  assert.equal(stateText(t("A", { status: "done", unmet_dependencies: 2, pr: { number: 9, state: "merged" } })).text, "Done · PR #9 merged");
  assert.equal(
    stateText(t("A", { status: "in_review", pr: { number: 14, state: "open", feedback: { ci_state: "failing", failed_checks_count: 1, failed_checks: [], unresolved_threads: 2, review_threads: [], updated_at: "2026-11-12T10:00:00Z" } } })).text,
    "In review · PR #14 · CI failed · 2 comments",
  );
  assert.equal(stateText(t("A", { status: "in_review" })).text, "In review");
});

test("workGroups puts Needs you first and buckets the rest by status", () => {
  const now = new Date("2026-11-12T15:00:00"); // a Thursday
  const tickets = [
    t("A", { status: "in_progress" }),
    t("B", { status: "in_review" }),
    t("C"),
    t("D", { status: "done", updated_at: new Date("2026-11-10T09:00:00").toISOString() }),
    t("E", { status: "done", updated_at: new Date("2026-11-01T09:00:00").toISOString() }),
    t("F", { status: "backlog" }),
    t("G", { status: "done" }),
  ];
  const needs = new Map([["A", {}], ["G", {}]]);
  const groups = workGroups(tickets, needs, "status", now);
  assert.deepEqual(groups.map((g) => [g.title, g.tickets.map((x) => x.key)]), [
    ["Needs you", ["A"]],
    ["In progress", ["B"]],
    ["Ready", ["C"]],
    ["Backlog", ["F"]],
    ["Done this week", ["D", "G"]],
    ["Done earlier", ["E"]],
  ]);
  assert.ok(groups[0].needs);
  const byEpic = workGroups([t("A", { epic: { id: "e", name: "E" } }), t("B")], new Map([["B", {}]]), "epic", now);
  assert.deepEqual(byEpic.map((g) => g.title), ["Needs you", "E"]);
  assert.equal(weekStart(now), new Date("2026-11-09T00:00:00").getTime());
});

test("parseFilterText and filterText round-trip tokens and free text", () => {
  assert.deepEqual(parseFilterText('fix login epic:"Mobile UI" agent:@atlas status:ready'), {
    tokens: [{ key: "epic", value: "Mobile UI" }, { key: "agent", value: "@atlas" }, { key: "status", value: "ready" }],
    text: "fix login",
  });
  assert.deepEqual(parseFilterText("project: hello"), { tokens: [], text: "hello" });
  const s = filterText({ project: "LA", epic: "Mobile UI", q: "login" });
  assert.equal(s, 'project:LA epic:"Mobile UI" login');
  assert.deepEqual(parseFilterText(s).tokens.map((x) => x.value), ["LA", "Mobile UI"]);
});

test("resolveFilter maps tokens to URL filters and reports unknown ones", () => {
  const look = {
    projects: [{ id: "p1", key: "LA", name: "Lazy Agents" }, { id: "p2", key: "PAY", name: "Payments" }],
    epics: [{ id: "e1", name: "Mobile UI", project_id: "p2" }, { id: "e2", name: "Mobile UI", project_id: "p1" }],
    agents: [{ handle: "atlas", name: "Atlas" }],
  };
  assert.deepEqual(resolveFilter("project:la epic:mobile-ui agent:@Atlas status:review login", look), {
    unknown: [], q: "login", project: "LA", epic: "e2", assignee: "atlas", status: "in_review",
  });
  assert.deepEqual(resolveFilter("epic:nope status:zzz", look), { unknown: ["epic:nope", "status:zzz"] });
  // Same name in two projects with All projects: the URL's epic wins.
  assert.equal(resolveFilter('epic:"Mobile UI"', { ...look, currentEpic: "e2" }).epic, "e2");
  assert.equal(resolveFilter('epic:"Mobile UI"', look).epic, "e1");
  assert.equal(withoutProjectToken('project:OPS epic:"A b" project:"Lazy Agents" bug'), 'epic:"A b" bug');
});

test("epicProgress and startReady", () => {
  const tickets = [t("A", { status: "done" }), t("B", { status: "in_progress" }), t("C", { status: "in_progress" }), t("D"), t("E", { status: "canceled" }), t("F", { unmet_dependencies: 1 })];
  assert.deepEqual(epicProgress(tickets, new Map([["C", {}]])), { done: 1, running: 1, needs: 1, open: 2, total: 5 });
  const r = startReady(tickets, new Set(["B"]));
  assert.deepEqual(r.ready.map((x) => x.key), ["C", "D"]);
  assert.deepEqual(r.blocked.map((x) => x.key), ["F"]);
});

test("ticketNeedsYou filters stale dispatch items while keeping todo dispatches and other urgent kinds", () => {
  const dispatchItem = { kind: "dispatch", id: "dispatch:t1" };
  const approvalItem = { kind: "approval", id: "approval:a1" };
  assert.equal(ticketNeedsYou({ status: "todo" }, dispatchItem), dispatchItem);
  assert.equal(ticketNeedsYou({ status: "todo", run: { state: "completed" } }, dispatchItem), dispatchItem);
  assert.equal(ticketNeedsYou({ status: "todo", run: { state: "running" } }, dispatchItem), undefined);
  assert.equal(ticketNeedsYou({ status: "backlog" }, dispatchItem), undefined);
  assert.equal(ticketNeedsYou({ status: "in_progress" }, dispatchItem), undefined);
  assert.equal(ticketNeedsYou({ status: "in_review" }, dispatchItem), undefined);
  assert.equal(ticketNeedsYou({ status: "done" }, dispatchItem), undefined);
  assert.equal(ticketNeedsYou({ status: "in_progress" }, approvalItem), approvalItem);
  assert.equal(ticketNeedsYou({ status: "in_review" }, { kind: "review", id: "review:t2" }).id, "review:t2");

  const tickets = [t("LA-1", { status: "todo" }), t("LA-2", { status: "in_progress" }), t("LA-3", { status: "in_review" })];
  const needs = new Map([["LA-1", dispatchItem], ["LA-2", dispatchItem], ["LA-3", approvalItem]]);
  const groups = workGroups(tickets, needs, "status");
  assert.deepEqual(groups.find((g) => g.needs)?.tickets.map((x) => x.key), ["LA-1", "LA-3"]);
  assert.deepEqual(epicProgress(tickets, needs), { done: 0, running: 1, needs: 2, open: 0, total: 3 });
});
