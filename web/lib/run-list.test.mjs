import test from "node:test";
import assert from "node:assert/strict";
import { dayLabel, groupRuns, itemHref, matchesRun, nextNeedsItem, runDot, runLine, runTitle, runnerSlot, touchedFiles } from "./run-list.ts";
import { condenseFeed } from "./run-view.ts";

const now = new Date(2026, 10, 12, 15, 0);
const at = (days, h = 10) => new Date(2026, 10, 12 - days, h).toISOString();
const run = (id, over = {}) => ({
  id, state: "running", started_at: at(0, 9), ticket_key: "WEB-1", work_title: "Payout retries", purpose: "ticket",
  agent: { name: "Quill", handle: "quill" }, plan: [], ...over,
});

test("groupRuns: Running, Queued, then finished runs by day; Needs you runs left out", () => {
  const runs = [
    run("a"),
    run("q", { state: "queued" }),
    run("w", { state: "waiting", wait_reason: "approval" }),
    run("t", { state: "completed", ended_at: at(0, 11) }),
    run("y", { state: "failed", ended_at: at(1) }),
    run("y2", { state: "cancelled", ended_at: at(1, 8) }),
    run("old", { state: "completed", ended_at: at(30) }),
    run("a"),
  ];
  const groups = groupRuns(runs, new Set(["w"]), now);
  assert.deepEqual(groups.map((g) => [g.label, g.runs.map((r) => r.id)]), [
    ["Running", ["a"]],
    ["Queued", ["q"]],
    ["Earlier today", ["t"]],
    ["Yesterday", ["y", "y2"]],
    [dayLabel(at(30), now), ["old"]],
  ]);
});

test("dayLabel", () => {
  assert.equal(dayLabel(at(0, 1), now), "Earlier today");
  assert.equal(dayLabel(at(1), now), "Yesterday");
  assert.equal(dayLabel(at(3), now), new Date(at(3)).toLocaleDateString(undefined, { weekday: "long" }));
});

test("row title, line and dot", () => {
  assert.equal(runTitle(run("a")), "Payout retries");
  assert.equal(runTitle(run("a", { work_title: "", ticket_key: "" , purpose: "planning" })), "Planning run");
  assert.equal(runLine(run("a")), "WEB-1 · Quill");
  const plan = [{ position: 1, state: "done", text: "Read" }, { position: 2, state: "current", text: "Ask" }];
  assert.equal(runLine(run("a", { plan })), "Step 2 of 2 · Ask");
  assert.equal(runLine(run("a", { plan, state: "completed" })), "WEB-1 · Quill");
  assert.equal(runDot(run("a")), "running");
  assert.equal(runDot(run("a", { state: "waiting", wait_reason: "human_reply" })), "human");
  assert.equal(runDot(run("a", { state: "waiting", wait_reason: "delegation" })), "running");
  assert.equal(runDot(run("a", { state: "failed" })), "failed");
  assert.equal(runDot(run("a"), true), "human");
});

test("matchesRun searches title, key and agent", () => {
  assert.ok(matchesRun(run("a"), "payout"));
  assert.ok(matchesRun(run("a"), "web-1"));
  assert.ok(matchesRun(run("a"), "QUILL"));
  assert.ok(!matchesRun(run("a"), "ledger"));
  assert.ok(matchesRun(run("a"), "  "));
});

test("nextNeedsItem skips the current run and wraps", () => {
  const items = [{ id: "1", run_id: "r1" }, { id: "2", run_id: "r2" }, { id: "3" }];
  assert.equal(nextNeedsItem(items, "r1")?.id, "2");
  assert.equal(nextNeedsItem(items, "r2")?.id, "3");
  assert.equal(nextNeedsItem([{ id: "1", run_id: "r1" }, { id: "2", run_id: "r1" }], "r1"), undefined);
  assert.equal(nextNeedsItem(items, "elsewhere")?.id, "1");
  assert.equal(itemHref(items[0], "project=WEB"), "/runs/r1?project=WEB");
  assert.equal(itemHref({ href: "/plans/x" }), "/plans/x");
});

const ev = (seq, type, payload) => ({ seq, type, payload, at: `2026-11-03T12:00:${String(seq).padStart(2, "0")}Z` });

test("runnerSlot and touchedFiles read the events", () => {
  const events = [
    ev(1, "lifecycle", { state: "starting", runner: "runner-2", backend: "microvm" }),
    ev(2, "tool_call", { id: "a", tool: "Read", input: { file_path: "b.go" } }),
    ev(3, "tool_call", { id: "b", tool: "Edit", input: { file_path: "a.go" } }),
    ev(4, "tool_call", { id: "c", tool: "Bash", input: { command: "ls" } }),
    ev(5, "tool_call", { id: "d", tool: "Read", input: { file_path: "a.go" } }),
  ];
  assert.deepEqual(runnerSlot(events), { runner: "runner-2", backend: "microvm" });
  assert.equal(runnerSlot([]), null);
  assert.deepEqual(touchedFiles(events), [{ path: "a.go", writes: 1, reads: 1 }, { path: "b.go", writes: 0, reads: 1 }]);
});

test("condenseFeed with messages keeps every agent message in full", () => {
  const events = [
    ev(1, "lifecycle", { state: "turn_started", turn: 1 }),
    ev(2, "message", { text: "First\nsecond line" }),
    ev(3, "message", { text: "Again" }),
    ev(4, "message", { kind: "thinking", text: "hmm" }),
  ];
  const feed = condenseFeed(events, undefined, { messages: true });
  assert.deepEqual(feed.map((f) => f.kind), ["turn", "message", "message"]);
  assert.equal(feed[1].text, "First\nsecond line");
  assert.equal(feed[0].text, "First");
  assert.deepEqual(condenseFeed(events).map((f) => f.kind), ["turn"]);
});
