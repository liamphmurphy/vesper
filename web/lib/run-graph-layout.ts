// Layout for the run page's Graph view: turns, gates and the outcome run left
// to right in one lane; delegated runs and errors hang below the turn they
// belong to. Pure, so live updates (which only add nodes) keep every existing
// item's key and column.

import type { GraphNode, NodeStatus, RunGraph, SubagentJobNode, SubagentNode, TurnNode, ErrorNode } from "./run-graph.ts";

/** Past this many turns, runs of quiet finished turns collapse into groups. */
export const GROUP_THRESHOLD = 12;
const MIN_GROUP = 3;

export type GroupItem = { kind: "group"; id: string; turns: TurnNode[]; status: NodeStatus };
export type MainItem = { kind: "node"; id: string; node: GraphNode } | GroupItem;
export type BranchNode = SubagentNode | SubagentJobNode | ErrorNode;
export type BranchItem =
  | { kind: "node"; id: string; node: BranchNode; depth: number }
  /** Collapsed nested runs under a subagent (depth ≥ 2). */
  | { kind: "more"; id: string; parent: string; count: number; depth: number };
export type Column = { main: MainItem; branch: BranchItem[] };
export type GraphLayout = { columns: Column[]; turnCount: number };

export const groupId = (firstTurn: number) => `group:${firstTurn}`;
export const moreId = (runNode: string) => `more:${runNode}`;

const ACTIVE: NodeStatus[] = ["running", "waiting", "pending"];

export function groupStatus(turns: TurnNode[]): NodeStatus {
  for (const s of ["failed", "running", "waiting", "pending", "cancelled"] as NodeStatus[]) if (turns.some((t) => t.status === s)) return s;
  return "done";
}

/**
 * `expanded` holds group ids and subagent node ids a person opened; `keep`
 * holds node ids that must stay visible (the selection), so grouping never
 * hides them.
 */
export function layoutRunGraph(graph: RunGraph, expanded: ReadonlySet<string> = new Set(), keep: ReadonlySet<string> = new Set(), threshold = GROUP_THRESHOLD): GraphLayout {
  const byId = new Map(graph.nodes.map((n) => [n.id, n]));
  const out = new Map<string, string[]>();
  for (const e of graph.edges) out.set(e.from, [...(out.get(e.from) ?? []), e.to]);

  // Branch nodes under each turn: delegated runs depth-first, then errors.
  const branchOf = (turnId: string): BranchItem[] => {
    const items: BranchItem[] = [];
    const walk = (runId: string, depth: number) => {
      const n = byId.get(runId) as SubagentNode;
      items.push({ kind: "node", id: n.id, node: n, depth });
      const kids = (out.get(runId) ?? []).filter((k) => byId.get(k)?.kind === "subagent_run");
      if (!kids.length) return;
      if (depth >= 1 && !expanded.has(runId)) {
        items.push({ kind: "more", id: moreId(runId), parent: runId, count: countRuns(kids), depth: depth + 1 });
        return;
      }
      for (const k of kids) walk(k, depth + 1);
    };
    const countRuns = (ids: string[]): number => ids.reduce((s, k) => s + 1 + countRuns((out.get(k) ?? []).filter((x) => byId.get(x)?.kind === "subagent_run")), 0);
    const targets = out.get(turnId) ?? [];
    for (const k of targets) {
      const n = byId.get(k);
      if (n?.kind === "subagent_job") items.push({ kind: "node", id: n.id, node: n, depth: 1 });
    }
    for (const k of targets) if (byId.get(k)?.kind === "subagent_run") walk(k, 1);
    for (const k of targets) {
      const n = byId.get(k);
      if (n?.kind === "error") items.push({ kind: "node", id: n.id, node: n, depth: 1 });
    }
    return items;
  };

  const turns = graph.nodes.filter((n): n is TurnNode => n.kind === "turn").sort((a, b) => a.turn - b.turn);
  const gateAfter = new Map<number, GraphNode>();
  for (const n of graph.nodes) if (n.kind === "gate") gateAfter.set(n.after_turn, n);
  const grouping = turns.length > threshold;

  const columns: Column[] = [];
  let run: TurnNode[] = [];
  const flush = () => {
    if (run.length >= MIN_GROUP && !expanded.has(groupId(run[0].turn))) {
      columns.push({ main: { kind: "group", id: groupId(run[0].turn), turns: run, status: groupStatus(run) }, branch: [] });
    } else {
      for (const t of run) columns.push({ main: { kind: "node", id: t.id, node: t }, branch: [] });
    }
    run = [];
  };
  turns.forEach((t, i) => {
    const branch = branchOf(t.id);
    const quiet = grouping && i < turns.length - 1 && !branch.length && !ACTIVE.includes(t.status) && !keep.has(t.id);
    const gate = gateAfter.get(t.turn);
    if (quiet) {
      run.push(t);
    } else {
      flush();
      columns.push({ main: { kind: "node", id: t.id, node: t }, branch });
    }
    if (gate) {
      flush();
      columns.push({ main: { kind: "node", id: gate.id, node: gate }, branch: [] });
    }
  });
  flush();
  const outcome = graph.nodes.find((n) => n.kind === "outcome");
  if (outcome) columns.push({ main: { kind: "node", id: outcome.id, node: outcome }, branch: [] });
  // Errors with no turn to hang on (no turns recorded) go under the first column.
  const placed = new Set(columns.flatMap((c) => [c.main.id, ...c.branch.map((b) => b.id)]));
  const stray = graph.nodes.filter((n): n is ErrorNode => n.kind === "error" && !placed.has(n.id));
  if (stray.length) {
    if (!columns.length) columns.push({ main: { kind: "node", id: stray[0].id, node: stray.shift()! }, branch: [] });
    columns[0].branch.push(...stray.map((n) => ({ kind: "node" as const, id: n.id, node: n, depth: 1 })));
  }
  return { columns, turnCount: turns.length };
}

/** Where an arrow key moves from item `id`: ←/→ along the lane, ↑/↓ within a column. */
export function moveFrom(layout: GraphLayout, id: string, key: string): string | undefined {
  const { columns } = layout;
  const col = columns.findIndex((c) => c.main.id === id || c.branch.some((b) => b.id === id));
  if (col < 0) return undefined;
  const c = columns[col];
  const row = c.main.id === id ? -1 : c.branch.findIndex((b) => b.id === id);
  switch (key) {
    case "ArrowRight": return columns[col + 1]?.main.id;
    case "ArrowLeft": return columns[col - 1]?.main.id;
    case "ArrowDown": return c.branch[row + 1]?.id;
    case "ArrowUp": return row === -1 ? undefined : row === 0 ? c.main.id : c.branch[row - 1].id;
    case "Home": return columns[0]?.main.id;
    case "End": return columns.at(-1)?.main.id;
  }
  return undefined;
}
