import test from "node:test";
import assert from "node:assert/strict";
import { layoutRunGraph, moveFrom } from "./run-graph-layout.ts";

const turn = (n, status = "done") => ({ id: `turn:${n}`, kind: "turn", turn: n, trigger: n === 1 ? "start" : "resume", status, started_at: "" });
const sub = (id, depth = 1) => ({ id: `run:${id}`, kind: "subagent_run", run_id: id, agent: "implementer", status: "done", cost_usd: 0, depth, child_count: 0, expanded: false });
const jobNode = (id, turnNum = 1) => ({
  id: `job:${id}`,
  kind: "subagent_job",
  job_id: id,
  turn: turnNum,
  batch_size: 1,
  agent_type: "explorer",
  role: "Search",
  reason: "",
  requested_tier: "",
  tier: "fast",
  model: "claude-haiku-4-5",
  effort: "low",
  status: "done",
  tool_calls: 1,
  input_tokens: 10,
  output_tokens: 5,
  cached_tokens: 0,
  created_at: "",
  prompt: "p",
  result_text: "r",
  error: "",
  flags: [],
});
const seq = (from, to) => ({ id: `${from}-${to}`, kind: "sequence", from, to });
const del = (from, to) => ({ id: `${from}-${to}`, kind: "delegation", from, to });
const chain = (n) => Array.from({ length: n }, (_, i) => turn(i + 1, i === n - 1 ? "running" : "done"));
const graph = (nodes, extra = []) => {
  const turns = nodes.filter((x) => x.kind === "turn");
  return { nodes, edges: [...turns.slice(1).map((t, i) => seq(turns[i].id, t.id)), ...extra] };
};
const mains = (l) => l.columns.map((c) => c.main.id);

test("small runs never group", () => {
  const l = layoutRunGraph(graph(chain(5)));
  assert.deepEqual(mains(l), ["turn:1", "turn:2", "turn:3", "turn:4", "turn:5"]);
});

test("large runs group quiet finished turns, keeping branches, gates, the live turn and the selection", () => {
  const nodes = [...chain(60), sub("c1"), { id: "gate:20", kind: "gate", gate: "approval", state: "resolved", after_turn: 20 }];
  const g = graph(nodes, [del("turn:10", "run:c1")]);
  const l = layoutRunGraph(g, new Set(), new Set(["turn:30"]));
  assert.deepEqual(mains(l).slice(0, 6), ["group:1", "turn:10", "group:11", "gate:20", "group:21", "turn:30"]);
  assert.equal(l.columns[0].main.turns.length, 9);
  assert.deepEqual(mains(l).slice(-2), ["group:31", "turn:60"]);
  assert.ok(l.columns.length < 12, "60 turns fit in a handful of columns");
  // Expanding a group shows its turns; the ids of everything else stay put.
  const open = layoutRunGraph(g, new Set(["group:1"]), new Set(["turn:30"]));
  assert.deepEqual(mains(open).slice(0, 10), ["turn:1", "turn:2", "turn:3", "turn:4", "turn:5", "turn:6", "turn:7", "turn:8", "turn:9", "turn:10"]);
});

test("nested runs collapse under their subagent until expanded; errors follow the runs", () => {
  const err = { id: "error:9", kind: "error", turn: 1, seq: 9, message: "boom" };
  const g = graph([turn(1, "running"), sub("a"), sub("b", 2), sub("c", 3), err],
    [del("turn:1", "run:a"), del("run:a", "run:b"), del("run:b", "run:c"), seq("turn:1", "error:9")]);
  assert.deepEqual(layoutRunGraph(g).columns[0].branch.map((b) => [b.id, b.depth, b.count]), [["run:a", 1, undefined], ["more:run:a", 2, 2], ["error:9", 1, undefined]]);
  assert.deepEqual(layoutRunGraph(g, new Set(["run:a"])).columns[0].branch.map((b) => b.id), ["run:a", "run:b", "more:run:b", "error:9"]);
});

test("arrow keys move along the lane and within a column", () => {
  const l = layoutRunGraph(graph([turn(1), turn(2, "running"), sub("a")], [del("turn:1", "run:a")]));
  assert.equal(moveFrom(l, "turn:1", "ArrowRight"), "turn:2");
  assert.equal(moveFrom(l, "turn:1", "ArrowDown"), "run:a");
  assert.equal(moveFrom(l, "run:a", "ArrowUp"), "turn:1");
  assert.equal(moveFrom(l, "run:a", "ArrowRight"), "turn:2");
  assert.equal(moveFrom(l, "turn:2", "ArrowRight"), undefined);
  assert.equal(moveFrom(l, "turn:2", "Home"), "turn:1");
});

test("subagent_job nodes sit at depth 1 ahead of delegated runs and errors, and prevent quiet grouping", () => {
  const err = { id: "error:9", kind: "error", turn: 1, seq: 9, message: "boom" };
  const g1 = graph([turn(1, "running"), sub("a"), jobNode("j1"), err], [del("turn:1", "run:a"), del("turn:1", "job:j1"), seq("turn:1", "error:9")]);
  const l1 = layoutRunGraph(g1);
  assert.deepEqual(
    l1.columns[0].branch.map((b) => [b.id, b.depth]),
    [["job:j1", 1], ["run:a", 1], ["error:9", 1]],
  );
  assert.equal(moveFrom(l1, "turn:1", "ArrowDown"), "job:j1");
  assert.equal(moveFrom(l1, "job:j1", "ArrowDown"), "run:a");
  assert.equal(moveFrom(l1, "job:j1", "ArrowUp"), "turn:1");

  const large = graph([...chain(20), jobNode("j8", 8)], [del("turn:8", "job:j8")]);
  const l2 = layoutRunGraph(large);
  assert.ok(mains(l2).includes("turn:8"), "turn with subagent_job must stay ungrouped");
  assert.deepEqual(mains(l2), ["group:1", "turn:8", "group:9", "turn:20"]);
});
