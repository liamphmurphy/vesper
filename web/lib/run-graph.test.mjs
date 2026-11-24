import test from "node:test";
import assert from "node:assert/strict";
import { buildRunGraph, subagentFlags, subagentJobStatus } from "./run-graph.ts";

const at = (s) => `2026-11-03T12:${String(Math.floor(s / 60)).padStart(2, "0")}:${String(s % 60).padStart(2, "0")}Z`;
const ev = (seq, type, payload, s = seq) => ({ seq, type, payload, at: at(s) });
const marker = (seq, turn) => ev(seq, "lifecycle", { state: "turn_started", turn });
const turn = (seq, trigger, s, e, extra = {}) => ({ seq, trigger, started_at: at(s), ...(e != null ? { ended_at: at(e) } : {}), status: e != null ? "done" : "running", exit_code: e != null ? 0 : undefined, ...extra });
const run = (id, state, extra = {}) => ({ id, state, agent: { handle: "lead" }, started_at: at(0), cost_usd: 0, ...extra });
const child = (id, handle, s, state = "completed", extra = {}) => ({ id, state, agent: { handle }, started_at: at(s), cost_usd: 0.5, ...extra });
const delegate = (seq, agent) => ev(seq, "tool_call", { tool: "mcp__lazyagents__delegate", input: { agent } });
const job = (id, createdSec, extra = {}) => ({
  id,
  batch_id: null,
  agent_type: "explorer",
  role: "Codebase Search",
  reason: "",
  requested_tier: "",
  tier: "fast",
  model: "claude-haiku-4-5",
  effort: "low",
  status: "completed",
  prompt: "check files",
  result_text: "found it",
  error: "",
  input_tokens: 100,
  output_tokens: 50,
  cached_tokens: 0,
  cost_usd: 0.01,
  tool_calls: 2,
  created_at: at(createdSec),
  started_at: at(createdSec + 1),
  completed_at: at(createdSec + 4),
  ...extra,
});
const detail = (r, turns, events, child_runs = [], subagent_jobs) => ({ run: r, turns, events, child_runs, ...(subagent_jobs ? { subagent_jobs } : {}) });

const ids = (g, kind) => g.nodes.filter((n) => !kind || n.kind === kind).map((n) => n.id);
const edges = (g) => g.edges.map((e) => `${e.kind} ${e.from} ${e.to}`);

test("multi-turn ended run: turns in order with duration and cost, then the outcome", () => {
  const g = buildRunGraph(detail(
    run("r", "completed", { outcome: "Shipped" }),
    [turn(2, "resume", 20, 30), turn(1, "start", 1, 10, { usage: { cost_usd: 0.25 } })],
    [marker(1, 1), ev(2, "message", {}), marker(20, 2)],
  ));
  assert.deepEqual(ids(g), ["turn:1", "turn:2", "outcome"]);
  assert.deepEqual(edges(g), ["sequence turn:1 turn:2", "sequence turn:2 outcome"]);
  const t1 = g.nodes[0];
  assert.equal(t1.duration_ms, 9000);
  assert.equal(t1.cost_usd, 0.25);
  assert.equal(t1.status, "done");
  assert.deepEqual(g.nodes[2], { id: "outcome", kind: "outcome", status: "done", text: "Shipped" });
});

test("approval gate: pending while waiting, then resolved with a resume edge and the same id", () => {
  const waiting = detail(
    run("r", "waiting", { wait_reason: "approval" }),
    [turn(1, "start", 1, 10)],
    [marker(1, 1), ev(5, "lifecycle", { state: "waiting", reason: "approval", approval_id: "a1", scope: "db:migrate" })],
  );
  const g1 = buildRunGraph(waiting);
  const gate1 = g1.nodes.find((n) => n.kind === "gate");
  assert.deepEqual(gate1, { id: "gate:1", kind: "gate", gate: "approval", state: "pending", after_turn: 1, detail: "db:migrate" });
  assert.deepEqual(edges(g1), ["sequence turn:1 gate:1"]);
  assert.ok(!ids(g1).includes("outcome"));

  const resumed = detail(
    run("r", "running"),
    [...waiting.turns, turn(2, "approval", 40)],
    [...waiting.events, marker(40, 2)],
  );
  const g2 = buildRunGraph(resumed);
  assert.equal(g2.nodes.find((n) => n.id === "gate:1").state, "resolved");
  assert.deepEqual(edges(g2), ["sequence turn:1 gate:1", "resume gate:1 turn:2"]);
  assert.equal(g2.nodes.find((n) => n.id === "turn:2").status, "running");
  for (const id of ids(g1)) assert.ok(ids(g2).includes(id), `${id} kept`);
});

test("gate kinds: a comment resumes a human reply, an approval after a mockup wait is a mockup review", () => {
  const g = buildRunGraph(detail(
    run("r", "waiting", { wait_reason: "human_reply" }),
    [turn(1, "start", 1, 5), turn(2, "approval", 10, 15), turn(3, "comment", 20, 25)],
    [marker(1, 1), ev(3, "lifecycle", { state: "waiting", reason: "mockup_review", artifact_id: "m1" }), marker(10, 2), marker(20, 3)],
  ));
  const gates = g.nodes.filter((n) => n.kind === "gate").map((n) => [n.id, n.gate, n.state, n.detail]);
  assert.deepEqual(gates, [["gate:1", "mockup_review", "resolved", "m1"], ["gate:2", "human_reply", "resolved", undefined], ["gate:3", "human_reply", "pending", undefined]]);
});

test("nested and parallel delegation: distinct nodes per call, grandchildren collapsed until loaded", () => {
  // Turn 1 delegates to impl twice in parallel; turn 2 delegates to rev.
  const parent = detail(
    run("r", "running"),
    [turn(1, "start", 1, 10), turn(2, "delegation", 20)],
    [marker(1, 1), delegate(2, "impl"), delegate(3, "@impl"), marker(20, 2), delegate(21, "rev")],
    [child("rev1", "rev", 22, "running"), child("impl-b", "impl", 4), child("impl-a", "impl", 3, "completed", { child_count: 1 })],
  );
  const implA = detail(child("impl-a", "impl", 3), [], [], [child("gc1", "qa", 5, "completed", { child_count: 2 })]);
  const g = buildRunGraph(parent, [implA, undefined]);
  assert.deepEqual(ids(g, "subagent_run"), ["run:impl-a", "run:gc1", "run:impl-b", "run:rev1"]);
  assert.deepEqual(edges(g).filter((e) => e.startsWith("delegation")), [
    "delegation turn:1 run:impl-a", "delegation run:impl-a run:gc1", "delegation turn:1 run:impl-b", "delegation turn:2 run:rev1",
  ]);
  const node = (id) => g.nodes.find((n) => n.id === id);
  assert.deepEqual([node("run:impl-a").depth, node("run:impl-a").expanded, node("run:impl-a").child_count], [1, true, 1]);
  assert.deepEqual([node("run:gc1").depth, node("run:gc1").expanded, node("run:gc1").child_count], [2, false, 2]);
  assert.equal(node("run:impl-b").expanded, false);
  assert.equal(node("run:rev1").status, "running");
  assert.equal(node("run:impl-a").cost_usd, 0.5);
  assert.equal(new Set(g.edges.map((e) => e.id)).size, g.edges.length);

  // Expanding the grandchild adds its children without renaming anything.
  const gc = detail(child("gc1", "qa", 5), [], [], [child("ggc", "docs", 6)]);
  const g2 = buildRunGraph(parent, [implA, gc]);
  assert.deepEqual(ids(g2).filter((id) => !ids(g).includes(id)), ["run:ggc"]);
  assert.equal(g2.nodes.find((n) => n.id === "run:ggc").depth, 3);
});

test("live update: a new child and turn only add nodes", () => {
  const base = detail(run("r", "running"), [turn(1, "start", 1)], [marker(1, 1), delegate(2, "impl")], [child("c1", "impl", 3, "running")]);
  const g1 = buildRunGraph(base);
  const next = detail(
    run("r", "running"),
    [turn(1, "start", 1, 10), turn(2, "delegation", 20)],
    [...base.events, delegate(4, "impl"), marker(20, 2)],
    [child("c1", "impl", 3), child("c2", "impl", 5, "running")],
  );
  const g2 = buildRunGraph(next);
  for (const id of ids(g1)) assert.ok(ids(g2).includes(id), `${id} kept`);
  for (const e of g1.edges) assert.ok(g2.edges.some((x) => x.id === e.id), `${e.id} kept`);
  assert.deepEqual(ids(g2).filter((id) => !ids(g1).includes(id)), ["turn:2", "run:c2"]);
  assert.ok(edges(g2).includes("delegation turn:1 run:c2"));
});

test("failed run: errors hang off their turn, the last turn and outcome are failed", () => {
  const g = buildRunGraph(detail(
    run("r", "failed", { outcome: "harness exited 1" }),
    [turn(1, "start", 1, 5), turn(2, "resume", 10, 15, { exit_code: 1 })],
    [ev(0, "error", { message: "setup warning" }), marker(1, 1), marker(10, 2), ev(12, "error", { message: "boom" })],
  ));
  assert.deepEqual(g.nodes.filter((n) => n.kind === "error").map((n) => [n.id, n.turn, n.message]), [["error:0", 1, "setup warning"], ["error:12", 2, "boom"]]);
  assert.ok(edges(g).includes("sequence turn:2 error:12"));
  assert.equal(g.nodes.find((n) => n.id === "turn:2").status, "failed");
  assert.equal(g.nodes.find((n) => n.id === "outcome").status, "failed");
});

test("still-running and unmanaged runs", () => {
  const g = buildRunGraph(detail(run("r", "running"), [turn(1, "start", 1)], [marker(1, 1)]));
  assert.equal(g.nodes[0].status, "running");
  assert.equal(g.nodes[0].duration_ms, undefined);
  assert.ok(!ids(g).includes("outcome"));

  const unmanaged = buildRunGraph(detail(run("u", "running"), [], [ev(1, "message", {})]));
  assert.deepEqual(ids(unmanaged), ["turn:0"]);
  assert.deepEqual(buildRunGraph(detail(run("q", "queued"), [], [])).nodes, []);

  const unmanagedJobOnly = buildRunGraph(detail(run("uj", "completed"), [], [], [], [job("j0", 2)]));
  assert.deepEqual(ids(unmanagedJobOnly), ["turn:0", "job:j0", "outcome"]);
  assert.ok(edges(unmanagedJobOnly).includes("delegation turn:0 job:j0"));
});

test("subagent_jobs: lifecycle turn attachment, timestamp fallback, batching, timing, and anomaly flags", () => {
  const jBatch1 = job("j1", 5, { batch_id: "b-1", tier: "standard", requested_tier: "deep", model: "claude-sonnet-4-6", effort: "medium", reason: "Check callers", started_at: at(6), completed_at: at(10) });
  const jBatch2 = job("j2", 5, { batch_id: "b-1", tier: "fast", tool_calls: 22, status: "failed", error: "boom", created_at: at(5), started_at: at(15), completed_at: at(18) });
  const jFallback = job("j3", 25, { status: "canceled", requested_tier: "", tier: "standard", started_at: null, completed_at: null });
  const jSerialA = job("j4", 41, { requested_tier: "fast", tier: "fast" });
  const jSerialB = job("j5", 45, { requested_tier: "", tier: "fast" });
  const jSerialC = job("j6", 49);

  const g = buildRunGraph(
    detail(
      run("r", "completed"),
      [turn(1, "start", 1, 20), turn(2, "resume", 22, 38), turn(3, "resume", 40, 60)],
      [
        marker(1, 1),
        ev(4, "lifecycle", { state: "subagent_queued", subagent_id: "j1" }, 5),
        ev(5, "lifecycle", { state: "subagent_started", subagent_id: "j2" }, 15),
        marker(20, 2),
        marker(35, 3),
      ],
      [],
      [jSerialC, jBatch2, jFallback, jBatch1, jSerialA, jSerialB],
    ),
  );

  assert.deepEqual(ids(g, "subagent_job"), ["job:j1", "job:j2", "job:j3", "job:j4", "job:j5", "job:j6"]);
  assert.ok(edges(g).includes("delegation turn:1 job:j1"));
  assert.ok(edges(g).includes("delegation turn:1 job:j2"));
  assert.ok(edges(g).includes("delegation turn:2 job:j3"));
  assert.ok(edges(g).includes("delegation turn:3 job:j4"));

  const byId = new Map(g.nodes.map((n) => [n.id, n]));
  const n1 = byId.get("job:j1");
  assert.equal(n1.turn, 1);
  assert.equal(n1.batch_id, "b-1");
  assert.equal(n1.batch_size, 2);
  assert.equal(n1.queued_ms, 1000);
  assert.equal(n1.duration_ms, 4000);
  assert.equal(n1.reason, "Check callers");
  assert.deepEqual(n1.flags, ["capped"]);

  const n2 = byId.get("job:j2");
  assert.equal(n2.queued_ms, 10000);
  assert.equal(n2.duration_ms, 3000);
  assert.equal(n2.status, "failed");
  assert.deepEqual(n2.flags, ["failed", "spinning", "queue_bound"]);

  const n3 = byId.get("job:j3");
  assert.equal(n3.status, "cancelled");
  assert.equal(n3.turn, 2);
  assert.equal(n3.batch_size, 1);
  assert.deepEqual(n3.flags, [], "omitted requested_tier must not mark capped");

  assert.deepEqual(byId.get("job:j4").flags, ["serial"]);
  assert.deepEqual(byId.get("job:j5").flags, ["serial"]);
  assert.deepEqual(byId.get("job:j6").flags, ["serial"]);

  assert.equal(subagentJobStatus("queued"), "pending");
  assert.equal(subagentJobStatus("running"), "running");
  assert.equal(subagentJobStatus("completed"), "done");
  assert.equal(subagentJobStatus("failed"), "failed");
  assert.equal(subagentJobStatus("canceled"), "cancelled");
  assert.deepEqual(subagentFlags({ requested_tier: "", tier: "standard", status: "completed", tool_calls: 0 }), []);
});
