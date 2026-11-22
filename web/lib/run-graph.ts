// Pure graph model for the run page's Graph view: a DAG of turns, human
// gates, errors, delegated runs and the outcome, derived from the data the
// run page already loads. The renderer only lays it out.
//
// Request bound: the graph needs no requests of its own. It reads the run's
// `GET /runs/{id}` detail and the details of its direct child runs, which the
// page already fetches (useRunLog + useDelegatedRunLogs): 1 + C requests per
// refresh for C direct children. Grandchildren come from each child's
// `child_runs` list at no extra cost and are shown collapsed
// (`expanded: false`). Deeper levels are fetched only when a person expands a
// node: pass that run's detail in `loaded` and its children appear. Nothing
// here fans out per grandchild on refresh.

import { delegateChild, str, turnAt, turnByEvent, turnStarts, type Ev } from "./run-view.ts";

type P = Record<string, unknown>;

export type GraphRun = {
  id: string;
  state: string;
  wait_reason?: string;
  agent: { handle: string; name?: string };
  started_at: string;
  ended_at?: string;
  cost_usd: number;
  outcome?: string;
  child_count?: number;
};

export type GraphTurn = {
  seq: number;
  trigger: string;
  started_at: string;
  ended_at?: string;
  status: string;
  exit_code?: number;
  usage?: Record<string, unknown>;
};

export type GraphSubagentJob = {
  id: string;
  batch_id?: string | null;
  agent_type: "explorer" | "helper";
  role: string;
  reason: string;
  requested_tier: string;
  tier: string;
  model: string;
  effort: string;
  status: "queued" | "running" | "completed" | "failed" | "canceled";
  prompt: string;
  result_text: string;
  error: string;
  input_tokens: number;
  output_tokens: number;
  cached_tokens: number;
  cost_usd?: number | null;
  tool_calls: number;
  created_at: string;
  started_at?: string | null;
  completed_at?: string | null;
};

/** The parts of a RunDetail (`GET /runs/{id}`) the graph reads. */
export type GraphDetail = { run: GraphRun; turns: GraphTurn[]; events: Ev[]; child_runs: GraphRun[]; subagent_jobs?: GraphSubagentJob[] };

export type NodeStatus = "pending" | "running" | "waiting" | "done" | "failed" | "cancelled";
export type GateKind = "approval" | "human_reply" | "mockup_review";
export type SubagentFlag = "capped" | "spinning" | "queue_bound" | "serial" | "failed";

export type TurnNode = {
  id: string; kind: "turn"; turn: number; trigger: string; status: NodeStatus;
  started_at: string; ended_at?: string; duration_ms?: number; cost_usd?: number;
};
export type SubagentNode = {
  id: string; kind: "subagent_run"; run_id: string; agent: string; status: NodeStatus; cost_usd: number;
  depth: number; child_count: number;
  /** The run's own detail is loaded, so its children are in the graph. */
  expanded: boolean;
};
export type SubagentJobNode = {
  id: string;
  kind: "subagent_job";
  job_id: string;
  turn: number;
  batch_id?: string;
  batch_size: number;
  agent_type: "explorer" | "helper";
  role: string;
  reason: string;
  requested_tier: string;
  tier: string;
  model: string;
  effort: string;
  status: NodeStatus;
  tool_calls: number;
  input_tokens: number;
  output_tokens: number;
  cached_tokens: number;
  cost_usd?: number;
  created_at: string;
  started_at?: string;
  completed_at?: string;
  queued_ms?: number;
  duration_ms?: number;
  prompt: string;
  result_text: string;
  error: string;
  flags: SubagentFlag[];
};
export type GateNode = { id: string; kind: "gate"; gate: GateKind; state: "pending" | "resolved"; after_turn: number; detail?: string };
export type ErrorNode = { id: string; kind: "error"; turn: number; seq: number; message: string };
export type OutcomeNode = { id: string; kind: "outcome"; status: NodeStatus; text: string };
export type GraphNode = TurnNode | SubagentNode | SubagentJobNode | GateNode | ErrorNode | OutcomeNode;

export type EdgeKind = "sequence" | "delegation" | "resume";
export type GraphEdge = { id: string; kind: EdgeKind; from: string; to: string };
export type RunGraph = { nodes: GraphNode[]; edges: GraphEdge[] };

/** Ids are derived from stable keys (turn seq, run id, event seq) so live updates only add nodes. */
export const nodeId = {
  turn: (n: number) => `turn:${n}`,
  gate: (afterTurn: number) => `gate:${afterTurn}`,
  run: (id: string) => `run:${id}`,
  job: (id: string) => `job:${id}`,
  error: (seq: number) => `error:${seq}`,
  outcome: "outcome",
};

const ENDED = ["completed", "failed", "cancelled"];
const GATES: GateKind[] = ["approval", "human_reply", "mockup_review"];

export function subagentJobStatus(status: string): NodeStatus {
  switch (status) {
    case "queued":
      return "pending";
    case "running":
      return "running";
    case "completed":
      return "done";
    case "failed":
      return "failed";
    case "canceled":
      return "cancelled";
    default:
      return "pending";
  }
}

export function subagentFlags(
  job: { requested_tier?: string; tier?: string; status: string; tool_calls: number; queued_ms?: number; duration_ms?: number },
  opts?: { serialInTurn?: boolean },
): SubagentFlag[] {
  const flags: SubagentFlag[] = [];
  if (job.requested_tier && job.tier && job.requested_tier !== job.tier) flags.push("capped");
  if (job.status === "failed") flags.push("failed");
  if (job.tool_calls >= 20) flags.push("spinning");
  if (job.queued_ms != null && job.queued_ms >= 5_000 && (job.duration_ms == null || job.queued_ms > job.duration_ms)) flags.push("queue_bound");
  if (opts?.serialInTurn) flags.push("serial");
  return flags;
}

export function runStatus(state: string): NodeStatus {
  switch (state) {
    case "queued":
    case "starting":
      return "pending";
    case "running":
      return "running";
    case "completed":
      return "done";
    case "failed":
    case "cancelled":
      return state;
    default:
      return "waiting"; // waiting, paused, blocked
  }
}

function turnStatus(t: GraphTurn, run: GraphRun, last: boolean): NodeStatus {
  if (t.status === "done") {
    if (t.exit_code != null && t.exit_code !== 0) return "failed";
    return last && run.state === "failed" ? "failed" : "done";
  }
  if (ENDED.includes(run.state)) return run.state === "completed" ? "done" : runStatus(run.state);
  return t.status === "pending" ? "pending" : "running";
}

const isWaiting = (e: Ev) => e.type === "lifecycle" && (e.payload as P).state === "waiting";
const isDelegate = (e: Ev) => e.type === "tool_call" && /delegate$/.test(str((e.payload as P).tool));

/**
 * Builds the run's DAG. `loaded` holds details of delegated runs already
 * fetched (direct children, plus any a person expanded); runs without a
 * loaded detail appear as collapsed subagent nodes.
 */
export function buildRunGraph(detail: GraphDetail, loaded: Iterable<GraphDetail | undefined> = []): RunGraph {
  const details = new Map<string, GraphDetail>();
  for (const d of loaded) if (d) details.set(d.run.id, d);
  const nodes: GraphNode[] = [];
  const edges: GraphEdge[] = [];
  const edge = (kind: EdgeKind, from: string, to: string) => edges.push({ id: `${kind}:${from}->${to}`, kind, from, to });
  const { run } = detail;
  const events = [...detail.events].sort((a, b) => a.seq - b.seq);
  const byEvent = turnByEvent(events);

  // Turns; an unmanaged run without turn records shows as one session turn.
  const turns: GraphTurn[] = [...detail.turns].sort((a, b) => a.seq - b.seq);
  if (turns.length === 0 && (events.length > 0 || (detail.subagent_jobs?.length ?? 0) > 0)) {
    turns.push({ seq: 0, trigger: "start", started_at: run.started_at, ended_at: run.ended_at, status: ENDED.includes(run.state) ? "done" : "running" });
  }
  const turnIds = new Set(turns.map((t) => t.seq));
  // Setup events (turn 0) and stray turn numbers attach to the nearest earlier turn, else the first.
  const turnOf = (n: number) => {
    let best = turns[0]?.seq;
    for (const t of turns) if (t.seq <= n) best = t.seq;
    return turnIds.has(n) ? n : best;
  };

  // The last waiting event in each turn names the gate that followed it.
  const waits = new Map<number, P>();
  for (const e of events) if (isWaiting(e)) waits.set(byEvent.get(e.seq) ?? 0, e.payload as P);
  const gateAfter = (prev: number, kind: GateKind, state: GateNode["state"]) => {
    const w = waits.get(prev);
    const detail = w && w.reason === kind ? str(w.scope || w.artifact_id) || undefined : undefined;
    const g: GateNode = { id: nodeId.gate(prev), kind: "gate", gate: kind, state, after_turn: prev, ...(detail ? { detail } : {}) };
    nodes.push(g);
    return g.id;
  };

  let prevId: string | undefined;
  turns.forEach((t, i) => {
    const id = nodeId.turn(t.seq);
    const u = (t.usage ?? {}) as P;
    nodes.push({
      id, kind: "turn", turn: t.seq, trigger: t.trigger, status: turnStatus(t, run, i === turns.length - 1),
      started_at: t.started_at,
      ...(t.ended_at ? { ended_at: t.ended_at, duration_ms: Date.parse(t.ended_at) - Date.parse(t.started_at) } : {}),
      ...(u.cost_usd != null ? { cost_usd: Number(u.cost_usd) } : {}),
    });
    if (prevId) {
      const prev = turns[i - 1].seq;
      const kind: GateKind | undefined =
        t.trigger === "comment" ? "human_reply" : t.trigger === "approval" ? (waits.get(prev)?.reason === "mockup_review" ? "mockup_review" : "approval") : undefined;
      if (kind) {
        const g = gateAfter(prev, kind, "resolved");
        edge("sequence", prevId, g);
        edge("resume", g, id);
      } else {
        edge("sequence", prevId, id);
      }
    }
    prevId = id;
  });

  // A gate the run is waiting on now; it keeps its id once resolved.
  const last = turns.at(-1);
  if (last && run.state === "waiting" && GATES.includes(run.wait_reason as GateKind)) {
    edge("sequence", nodeId.turn(last.seq), gateAfter(last.seq, run.wait_reason as GateKind, "pending"));
  }

  for (const e of events) {
    if (e.type !== "error") continue;
    const p = (e.payload ?? {}) as P;
    const turn = turnOf(byEvent.get(e.seq) ?? 0) ?? 0;
    const id = nodeId.error(e.seq);
    nodes.push({ id, kind: "error", turn, seq: e.seq, message: str(p.message || p.error || e.payload) });
    if (turnIds.has(turn)) edge("sequence", nodeId.turn(turn), id);
  }

  // Delegated runs: children go to the turn that delegated them, assigned in
  // call order with used children skipped, so parallel delegations to the
  // same agent land on distinct nodes.
  const starts = turnStarts(events);
  const remaining = [...detail.child_runs];
  const parentOf = new Map<string, number>();
  for (const call of events.filter(isDelegate)) {
    const child = delegateChild(call, remaining);
    if (!child) continue;
    remaining.splice(remaining.indexOf(child), 1);
    parentOf.set(child.id, byEvent.get(call.seq) ?? 0);
  }
  const seen = new Set<string>([run.id]);
  const addRun = (r: GraphRun, from: string, depth: number) => {
    if (seen.has(r.id)) return;
    seen.add(r.id);
    const id = nodeId.run(r.id);
    const d = details.get(r.id);
    nodes.push({
      id, kind: "subagent_run", run_id: r.id, agent: r.agent.handle, status: runStatus(r.state), cost_usd: r.cost_usd || 0,
      depth, child_count: d ? d.child_runs.length : r.child_count ?? 0, expanded: !!d,
    });
    edge("delegation", from, id);
    for (const k of byStart(d?.child_runs ?? [])) addRun(k, id, depth + 1);
  };
  for (const c of byStart(detail.child_runs)) {
    const turn = turnOf(parentOf.get(c.id) ?? turnAt(starts, c.started_at));
    if (turn == null) continue; // no turn to hang it on yet; it appears on the next refresh
    addRun(c, nodeId.turn(turn), 1);
  }

  // In-turn explorer/helper subagent jobs: attach via their first lifecycle event
  // (or timestamp fallback), preserve creation order, and compute batching/anomaly flags.
  const jobTurn = new Map<string, number>();
  for (const e of events) {
    if (e.type !== "lifecycle") continue;
    const p = (e.payload ?? {}) as P;
    if (p.state !== "subagent_queued" && p.state !== "subagent_started") continue;
    const sid = typeof p.subagent_id === "string" ? p.subagent_id : "";
    if (sid && !jobTurn.has(sid)) jobTurn.set(sid, byEvent.get(e.seq) ?? 0);
  }
  const jobs = [...(detail.subagent_jobs ?? [])].sort((a, b) => Date.parse(a.created_at) - Date.parse(b.created_at) || a.id.localeCompare(b.id));
  const batchCount = new Map<string, number>();
  for (const j of jobs) {
    if (j.batch_id) batchCount.set(j.batch_id, (batchCount.get(j.batch_id) ?? 0) + 1);
  }
  const resolvedJobs = jobs
    .map((j) => ({ j, turn: turnOf(jobTurn.get(j.id) ?? turnAt(starts, j.created_at)) }))
    .filter((x): x is { j: GraphSubagentJob; turn: number } => x.turn != null);
  const unbatchedPerTurn = new Map<number, number>();
  for (const { j, turn } of resolvedJobs) {
    if (!j.batch_id) unbatchedPerTurn.set(turn, (unbatchedPerTurn.get(turn) ?? 0) + 1);
  }
  for (const { j, turn } of resolvedJobs) {
    const id = nodeId.job(j.id);
    const createdMs = Date.parse(j.created_at);
    const startedMs = j.started_at ? Date.parse(j.started_at) : Number.NaN;
    const completedMs = j.completed_at ? Date.parse(j.completed_at) : Number.NaN;
    const queued_ms = Number.isFinite(createdMs) && Number.isFinite(startedMs) ? Math.max(0, startedMs - createdMs) : undefined;
    const duration_ms = Number.isFinite(startedMs) && Number.isFinite(completedMs) ? Math.max(0, completedMs - startedMs) : undefined;
    const batchId = j.batch_id || undefined;
    const batch_size = batchId ? (batchCount.get(batchId) ?? 1) : 1;
    const status = subagentJobStatus(j.status);
    const flags = subagentFlags(
      { requested_tier: j.requested_tier, tier: j.tier, status: j.status, tool_calls: j.tool_calls, queued_ms, duration_ms },
      { serialInTurn: !batchId && (unbatchedPerTurn.get(turn) ?? 0) >= 3 },
    );
    nodes.push({
      id,
      kind: "subagent_job",
      job_id: j.id,
      turn,
      ...(batchId ? { batch_id: batchId } : {}),
      batch_size,
      agent_type: j.agent_type,
      role: j.role,
      reason: j.reason,
      requested_tier: j.requested_tier,
      tier: j.tier,
      model: j.model,
      effort: j.effort,
      status,
      tool_calls: j.tool_calls,
      input_tokens: j.input_tokens,
      output_tokens: j.output_tokens,
      cached_tokens: j.cached_tokens,
      ...(j.cost_usd != null ? { cost_usd: j.cost_usd } : {}),
      created_at: j.created_at,
      ...(j.started_at ? { started_at: j.started_at } : {}),
      ...(j.completed_at ? { completed_at: j.completed_at } : {}),
      ...(queued_ms != null ? { queued_ms } : {}),
      ...(duration_ms != null ? { duration_ms } : {}),
      prompt: j.prompt,
      result_text: j.result_text,
      error: j.error,
      flags,
    });
    edge("delegation", nodeId.turn(turn), id);
  }

  if (ENDED.includes(run.state)) {
    nodes.push({ id: nodeId.outcome, kind: "outcome", status: runStatus(run.state), text: run.outcome ?? "" });
    if (last) edge("sequence", nodeId.turn(last.seq), nodeId.outcome);
  }
  return { nodes, edges };
}

function byStart<R extends GraphRun>(runs: R[]): R[] {
  return [...runs].sort((a, b) => Date.parse(a.started_at) - Date.parse(b.started_at) || a.id.localeCompare(b.id));
}
