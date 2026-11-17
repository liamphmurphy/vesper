import assert from "node:assert/strict";
import test from "node:test";
import { detectFinishedRuns, isActive, pausableRuns, RunMonitor } from "../dist/runs.js";
import { buildTrayMenu, clipLabel, lastWindowClosedAction, newestNeedsYou, trayTitle, trayTooltip } from "../dist/tray-model.js";

const run = (id, over = {}) => ({ id, state: "running", purpose: "ticket", work_title: `Work ${id}`, ticket_key: "PAY-1", agent: { name: "Pike" }, ...over });
const item = (id, over = {}) => ({
  id,
  kind: "approval",
  title: `Item ${id}`,
  href: `/runs/${id}`,
  created_at: "2026-11-17T10:00:00Z",
  resolved: false,
  read: false,
  needs_you: true,
  ...over,
});
const running = { phase: "running", title: "Vesper is running", message: "", nextStep: "", actions: ["logs"] };

test("detectFinishedRuns alerts once per run that left the live list in a terminal state", () => {
  const notified = new Set();
  const prev = new Map([
    ["a", run("a")],
    ["b", run("b")],
    ["c", run("c", { purpose: "chat" })],
    ["d", run("d")],
    ["e", run("e")],
  ]);
  const live = [run("e")];
  const recent = [
    run("a", { state: "completed", outcome: "Opened PR #1" }),
    run("b", { state: "failed" }),
    run("c", { purpose: "chat", state: "completed" }),
    run("d", { state: "cancelled" }),
  ];
  const alerts = detectFinishedRuns(prev, live, recent, notified);
  assert.deepEqual(alerts.map((a) => a.title), ["Run finished: Work a", "Run failed: Work b"]);
  assert.equal(alerts[0].href, "/runs/a");
  assert.equal(alerts[0].kind, "run_finished");
  assert.match(alerts[0].body, /Opened PR #1/);
  assert.ok(notified.has("c") && notified.has("d"), "chat and cancelled runs are marked so they never alert later");
  assert.deepEqual(detectFinishedRuns(prev, live, recent, notified), [], "never twice");
});

test("detectFinishedRuns waits when a vanished run's end state isn't known yet", () => {
  const notified = new Set();
  const alerts = detectFinishedRuns(new Map([["a", run("a")]]), [], [], notified);
  assert.deepEqual(alerts, []);
  assert.equal(notified.has("a"), false);
});

test("RunMonitor alerts on a later poll when a vanished run's end shows up late", async () => {
  let liveRuns = [run("a")];
  let allRuns = [];
  const finished = [];
  const monitor = new RunMonitor({
    pollIntervalMs: 60_000,
    fetch: async (url) => new Response(JSON.stringify({ runs: url.endsWith("state=all") ? allRuns : liveRuns }), { status: 200 }),
    onSnapshot: () => {},
    onFinished: (a) => finished.push(a.title),
  });
  monitor.start("http://localhost:8080");
  await new Promise((r) => setTimeout(r, 20));
  liveRuns = [];
  await monitor.refreshNow();
  assert.deepEqual(finished, []);
  allRuns = [run("a", { state: "failed" })];
  await monitor.refreshNow();
  monitor.stop();
  assert.deepEqual(finished, ["Run failed: Work a"]);
});

test("isActive and pausableRuns pick the right runs", () => {
  assert.equal(isActive(run("a")), true);
  assert.equal(isActive(run("a", { state: "waiting", wait_reason: "approval" })), false);
  assert.equal(isActive(run("a", { state: "waiting", wait_reason: "checks" })), true);
  assert.equal(isActive(run("a", { state: "paused" })), false);
  const p = pausableRuns([
    run("a"),
    run("b", { purpose: "chat" }),
    run("c", { state: "waiting", wait_reason: "checks" }),
    run("d", { state: "waiting", wait_reason: "human_reply" }),
    run("e", { state: "queued" }),
  ]);
  assert.deepEqual(p.map((r) => r.id), ["a", "d"]);
});

test("RunMonitor polls live runs, then all runs only when one vanished", async () => {
  const calls = [];
  let liveRuns = [run("a")];
  const finished = [];
  const snapshots = [];
  const monitor = new RunMonitor({
    pollIntervalMs: 60_000,
    fetch: async (url) => {
      calls.push(url);
      const all = url.endsWith("state=all");
      const runs = all ? [run("a", { state: "completed" })] : liveRuns;
      return new Response(JSON.stringify({ runs, has_more: false }), { status: 200 });
    },
    onSnapshot: (live) => snapshots.push(live.map((r) => r.id)),
    onFinished: (a) => finished.push(a.title),
  });
  monitor.start("http://localhost:8080/");
  await new Promise((r) => setTimeout(r, 20));
  liveRuns = [];
  await monitor.refreshNow();
  monitor.stop();
  assert.deepEqual(calls, [
    "http://localhost:8080/api/v1/runs?state=live",
    "http://localhost:8080/api/v1/runs?state=live",
    "http://localhost:8080/api/v1/runs?state=all",
  ]);
  assert.deepEqual(snapshots, [["a"], []]);
  assert.deepEqual(finished, ["Run finished: Work a"]);
});

test("newestNeedsYou keeps open needs-you items, newest first", () => {
  const list = newestNeedsYou([
    item("old", { created_at: "2026-11-16T10:00:00Z" }),
    item("new", { created_at: "2026-11-17T12:00:00Z" }),
    item("read", { read: true }),
    item("news", { needs_you: false }),
    item("done", { resolved: true }),
  ]);
  assert.deepEqual(list.map((i) => i.id), ["new", "old"]);
});

test("buildTrayMenu lists status, needs-you, running runs and actions in order", () => {
  const menu = buildTrayMenu({
    health: running,
    localStack: true,
    items: [item("1", { ticket_key: "PAY-2" }), item("2")],
    runs: [run("r1"), run("r2", { purpose: "chat" }), run("r3", { state: "paused" })],
    pausedByVesper: 0,
    quickCapture: { enabled: true, shortcut: "Alt+Shift+Space" },
  });
  const labels = menu.map((m) => (m.type === "separator" ? "---" : m.label));
  assert.deepEqual(labels, [
    "● Vesper is running",
    "---",
    "Needs you (2)",
    "PAY-2 · Item 1",
    "Item 2",
    "---",
    "Running (2)",
    "Pike: Work r1",
    "Pike: Work r3 (paused)",
    "---",
    "Open Vesper",
    "Quick Capture…",
    "Pause Runs (1)",
    "---",
    "Restart Stack",
    "Show Logs…",
    "---",
    "Settings…",
    "Quit Vesper",
  ]);
  const first = menu.find((m) => m.type === "item" && m.label === "PAY-2 · Item 1");
  assert.deepEqual(first.action, { kind: "open-href", href: "/runs/1" });
  const runItem = menu.find((m) => m.type === "item" && m.label === "Pike: Work r1");
  assert.deepEqual(runItem.action, { kind: "open-href", href: "/runs/r1" });
});

test("buildTrayMenu caps sections, offers Resume, shows errors and hides local-only items", () => {
  const items = Array.from({ length: 8 }, (_, i) => item(String(i)));
  const menu = buildTrayMenu({
    health: { phase: "error", title: "Disk full", message: "m", nextStep: "Free up disk space, then restart the stack.", actions: [] },
    localStack: false,
    items,
    runs: [],
    pausedByVesper: 2,
    maxPerSection: 3,
  });
  const labels = menu.map((m) => (m.type === "separator" ? "---" : m.label));
  assert.equal(labels[0], "⚠ Disk full");
  assert.equal(labels[1], "Free up disk space, then restart the stack.");
  assert.ok(labels.includes("Show all 8 in Inbox…"));
  assert.equal(labels.filter((l) => l.startsWith("Item ")).length, 3);
  assert.ok(labels.includes("Resume Runs (2)"));
  assert.ok(!labels.includes("Restart Stack"));
  assert.ok(!labels.includes("Quick Capture…"));
  const pause = buildTrayMenu({ health: running, localStack: true, items: [], runs: [], pausedByVesper: 0 }).find(
    (m) => m.type === "item" && m.label === "Pause Runs",
  );
  assert.equal(pause.enabled, false);
});

test("tray title, tooltip, label clipping and last-window policy", () => {
  assert.equal(trayTitle(0, true), "");
  assert.equal(trayTitle(3, true), "3");
  assert.equal(trayTitle(3, false), "");
  assert.equal(trayTitle(250, true), "99+");
  assert.equal(trayTooltip(running, 1), "Vesper: Vesper is running · 1 needs you");
  assert.equal(trayTooltip(running, 0), "Vesper: Vesper is running");
  assert.equal(clipLabel("a  b\n c"), "a b c");
  assert.equal(clipLabel("x".repeat(60)).length, 48);
  assert.equal(lastWindowClosedAction({ enabled: true, onLastWindowClose: "dock" }), "stay");
  assert.equal(lastWindowClosedAction({ enabled: true, onLastWindowClose: "menuBar" }), "hide-dock");
  assert.equal(lastWindowClosedAction({ enabled: false, onLastWindowClose: "menuBar" }), "stay", "never invisible without a tray");
  assert.equal(lastWindowClosedAction({ enabled: false, onLastWindowClose: "quit" }), "quit");
});
