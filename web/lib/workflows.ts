// Workflow graphs in the browser: fences, diffs and labels. Kept free of React
// so `npm run test:unit` covers it.

export type NodeType = "trigger" | "enrich" | "agent" | "gate" | "wiki" | "library" | "ticket" | "chat";
export type GraphNode = {
  id: string;
  type: NodeType;
  title: string;
  x?: number;
  y?: number;
  config: {
    prompt?: string;
    persona_id?: string;
    agent_handle?: string;
    web?: boolean;
    images?: boolean;
    /** auto, codex or antigravity; absent follows the persona's, then the workspace's, engine. */
    image_engine?: string;
    check?: boolean;
    show?: string[];
    retry_from?: string;
    max_attempts?: number;
    requires_check?: string;
    path?: string;
    mode?: string;
    title?: string;
  };
};
export type Graph = { nodes: GraphNode[]; edges: { from: string; to: string }[] };

export const NODE_LABEL: Record<NodeType, string> = {
  trigger: "Trigger",
  enrich: "Enrich",
  agent: "Agent step",
  gate: "Human gate",
  wiki: "Output",
  library: "Output",
  ticket: "Output",
  chat: "Output",
};

export const PALETTE: { group: string; items: { type: NodeType; label: string }[] }[] = [
  { group: "Steps", items: [{ type: "enrich", label: "Enrich prompt" }, { type: "agent", label: "Agent step" }, { type: "gate", label: "Human gate" }] },
  { group: "Outputs", items: [{ type: "wiki", label: "Add to wiki" }, { type: "library", label: "Add to library" }, { type: "ticket", label: "Create ticket" }, { type: "chat", label: "Post to chat" }] },
];

export const isOutput = (t: NodeType) => t === "wiki" || t === "library" || t === "ticket" || t === "chat";

/** A short line under a node's title. */
export function nodeSummary(n: GraphNode): string {
  const c = n.config;
  switch (n.type) {
    case "trigger":
      return "outputs: input";
    case "enrich":
      return "Sharpens the request";
    case "agent":
      if (c.check) return c.retry_from ? `Check · re-runs ${c.retry_from}` : "Check";
      if (c.images) return `Persona · images · ${imageEngineName(c.image_engine)}`;
      return c.agent_handle ? `@${c.agent_handle}` : c.web ? "Persona · web" : "Persona · read-only";
    case "gate":
      if (c.requires_check) return `Needs ${c.requires_check} to pass`;
      return c.retry_from ? `Can re-run ${c.retry_from}` : "Approve or reject";
    case "wiki":
      return c.path || "No path yet";
    case "library":
    case "ticket":
      return c.title || "No title yet";
    case "chat":
      return "Posts a message";
  }
}

/** A node id unused in the graph, for a new node. */
export function newNodeId(g: Graph, type: NodeType): string {
  for (let i = 1; ; i++) {
    const id = `${type}_${i}`;
    if (!g.nodes.some((n) => n.id === id)) return id;
  }
}

/** Every node that runs before this one. */
export function ancestors(g: Graph, id: string): GraphNode[] {
  const seen = new Set<string>();
  const stack = [id];
  while (stack.length) {
    const cur = stack.pop()!;
    for (const e of g.edges) {
      if (e.to === cur && !seen.has(e.from)) {
        seen.add(e.from);
        stack.push(e.from);
      }
    }
  }
  return g.nodes.filter((n) => seen.has(n.id));
}

/** Whether connecting these two is allowed at all; the server's validator has the full rules. */
export function canConnect(g: Graph, from: string, to: string): boolean {
  const a = g.nodes.find((n) => n.id === from);
  const b = g.nodes.find((n) => n.id === to);
  if (!a || !b || from === to || isOutput(a.type) || b.type === "trigger") return false;
  if (g.edges.some((e) => e.from === from && e.to === to)) return false;
  return !ancestors(g, from).some((n) => n.id === to);
}

/** Removes a node, its connections and anything that pointed at it. */
export function removeNode(g: Graph, id: string): Graph {
  return {
    nodes: g.nodes
      .filter((n) => n.id !== id)
      .map((n) => (n.config.retry_from === id || n.config.requires_check === id || n.config.show?.includes(id) ? { ...n, config: { ...n.config, retry_from: n.config.retry_from === id ? undefined : n.config.retry_from, requires_check: n.config.requires_check === id ? undefined : n.config.requires_check, show: n.config.show?.filter((s) => s !== id) } } : n)),
    edges: g.edges.filter((e) => e.from !== id && e.to !== id),
  };
}

export type NodeDiff = "added" | "changed" | "removed" | undefined;

const content = (n: GraphNode) => JSON.stringify({ t: n.type, n: n.title, c: n.config });

/** How a proposal differs from the draft, node by node and edge by edge. */
export function diffGraphs(base: Graph, next: Graph) {
  const nodes = new Map<string, NodeDiff>();
  for (const n of next.nodes) {
    const old = base.nodes.find((o) => o.id === n.id);
    nodes.set(n.id, !old ? "added" : content(old) !== content(n) ? "changed" : undefined);
  }
  const removedNodes = base.nodes.filter((o) => !next.nodes.some((n) => n.id === o.id));
  for (const n of removedNodes) nodes.set(n.id, "removed");
  const has = (g: Graph, e: { from: string; to: string }) => g.edges.some((x) => x.from === e.from && x.to === e.to);
  return { nodes, removedNodes, addedEdges: next.edges.filter((e) => !has(base, e)), removedEdges: base.edges.filter((e) => !has(next, e)) };
}

export const isWorkflowRunFence = (info: string | undefined) => (info ?? "").trim().split(/\s+/)[0]?.toLowerCase() === "workflow-run";

/** A ```workflow-run fence: the workflow's id, then the request. Null while it's incomplete. */
export function parseWorkflowRun(code: string): { workflowId: string; input: string } | null {
  const [first, ...rest] = code.trim().split("\n");
  const workflowId = first?.trim() ?? "";
  if (!/^[0-9a-f-]{36}$/i.test(workflowId)) return null;
  return { workflowId, input: rest.join("\n").trim() };
}

export const runActive = (state: string) => state === "running" || state === "waiting";

export const RUN_STATE_LABEL: Record<string, string> = { running: "Running", waiting: "Needs you", done: "Done", failed: "Failed", stopped: "Stopped" };

/** Run steps in graph order; nodes not started yet have no step. */
export function stepRows<S extends { node_id: string }>(g: Graph, steps: S[]): { node: GraphNode; step?: S }[] {
  return g.nodes.map((node) => ({ node, step: steps.find((s) => s.node_id === node.id) }));
}

/** What a reviewer reads at a gate: the configured nodes, else its direct parents. */
export function gateSources(g: Graph, gate: GraphNode): string[] {
  return gate.config.show?.length ? gate.config.show : g.edges.filter((e) => e.to === gate.id).map((e) => e.from);
}

/** A run's images grouped by the attempt that made them, newest attempt first. */
export function imagesByAttempt<I extends { attempt: number }>(images: I[]): { attempt: number; images: I[] }[] {
  const out = new Map<number, I[]>();
  for (const im of images) out.set(im.attempt, [...(out.get(im.attempt) ?? []), im]);
  return [...out.entries()].sort((a, b) => b[0] - a[0]).map(([attempt, list]) => ({ attempt, images: list }));
}

/** Checks connected directly into this gate: the ones it can be tied to. */
export function parentChecks(g: Graph, id: string): GraphNode[] {
  return g.nodes.filter((n) => n.type === "agent" && n.config.check && g.edges.some((e) => e.from === n.id && e.to === id));
}

/** The check keeping Approve shut, if any. The server enforces this too. */
export function failedGateCheck<S extends { node_id: string; state: string; check_result: string }>(g: Graph, gate: GraphNode, steps: S[]): GraphNode | undefined {
  const id = gate.config.requires_check;
  if (!id) return undefined;
  const step = steps.find((s) => s.node_id === id);
  if (step?.state === "done" && step.check_result === "passed") return undefined;
  return g.nodes.find((n) => n.id === id) ?? { id, type: "agent", title: id, config: {} };
}

/** Reviews left before Request changes stops being offered. */
export function canRequestChanges(gate: GraphNode, attempt: number): boolean {
  return !!gate.config.retry_from && attempt < (gate.config.max_attempts || 3);
}

/** The engine an images step names, as a node's summary line reads it. */
export function imageEngineName(engine: string | undefined): string {
  switch (engine) {
    case "codex":
      return "Codex";
    case "antigravity":
      return "Antigravity";
    case "gemini":
      return "Gemini API";
    case "auto":
      return "Auto engine";
    default:
      return "default engine";
  }
}
