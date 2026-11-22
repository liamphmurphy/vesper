"use client";

import { useRouter } from "next/navigation";
import { useMemo, useRef, useState, type CSSProperties, type KeyboardEvent, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { cx } from "@/lib/cx";
import { duration } from "@/lib/format";
import { buildRunGraph, finalMessage, turnByEvent, type GraphDetail, type GraphNode, type NodeStatus } from "@/lib/run-graph";
import { layoutRunGraph, moveFrom, type BranchItem, type Column, type GroupItem, type MainItem } from "@/lib/run-graph-layout";
import { isNativeShell, post } from "@/lib/native-shell/bridge";
import { PROTOCOL_VERSION } from "@/lib/native-shell/protocol";
import { Button } from "@/components/ui/button";
import { usePulseList } from "@/components/ui/motion";
import { WORK_COLUMN } from "@/components/domain/work-detail-header";

const ACTION_BOX_ID = "run-action-box";

type RunDetail = Schemas["RunDetail"];


const COL = 168;
const W = 132;
const H = 52;
const MAIN_Y = 20;
const BRANCH_Y = MAIN_Y + H + 36;
const ROW = 64;
const INDENT = 14;

const TONE: Record<NodeStatus, string> = {
  done: "border-state-done bg-pill-done-bg text-pill-done-fg",
  running: "border-2 border-accent bg-accent-soft text-fg",
  waiting: "border-2 border-state-human bg-pill-human-bg text-pill-human-fg",
  failed: "border-state-blocked bg-pill-blocked-bg text-pill-blocked-fg",
  pending: "border-border-strong bg-pill-neutral-bg text-pill-neutral-fg",
  cancelled: "border-dashed border-border-strong bg-pill-neutral-bg text-pill-neutral-fg",
};
const STATUS_LABEL: Record<NodeStatus, string> = { done: "done", running: "running", waiting: "waiting", failed: "failed", pending: "pending", cancelled: "cancelled" };
const GATE_LABEL = { approval: "Approval", human_reply: "Reply", mockup_review: "Mockup review" } as const;

type Item = MainItem | BranchItem;
type Labels = { title: string; sub: string; status: NodeStatus };

function labels(item: Item): Labels {
  if (item.kind === "group") {
    const first = item.turns[0].turn, last = item.turns.at(-1)!.turn;
    return { title: `Turns ${first}–${last}`, sub: `${item.turns.length} ${STATUS_LABEL[item.status]} · expand ▸`, status: item.status };
  }
  if (item.kind === "more") return { title: `+${item.count} nested run${item.count === 1 ? "" : "s"}`, sub: "expand ▸", status: "pending" };
  const n = item.node;
  switch (n.kind) {
    case "turn":
      return { title: `Turn ${n.turn}`, sub: `${n.trigger} · ${n.status === "running" ? "live" : n.duration_ms != null ? duration(n.started_at, n.ended_at) : STATUS_LABEL[n.status]}`, status: n.status };
    case "subagent_run":
      return { title: `↳ ${n.agent}`, sub: `${STATUS_LABEL[n.status]} · $${n.cost_usd.toFixed(2)} · open ↗`, status: n.status };
    case "gate":
      return { title: `${GATE_LABEL[n.gate]}${n.state === "pending" ? "?" : " ✓"}`, sub: n.state === "pending" ? "waiting on you" : "resolved", status: n.state === "pending" ? "waiting" : "pending" };
    case "error":
      return { title: "⚠ Error", sub: n.message || "error", status: "failed" };
    case "outcome":
      return { title: "Outcome", sub: STATUS_LABEL[n.status], status: n.status };
  }
}

/** An item's accessible name, e.g. "Turn 4, approval, done". */
const ariaName = (item: Item) => {
  const l = labels(item);
  return `${l.title.replace(/[↳⚠✓?▸↗]/g, "").trim()}, ${l.sub.replace(/ · (open ↗|expand ▸)$/, "")}`;
};

export function RunGraphView({ d, childDetails, onOpenTurn, onOpenEvent }: {
  d: RunDetail;
  childDetails: (RunDetail | undefined)[];
  onOpenTurn: (n: number) => void;
  onOpenEvent: (seq: number) => void;
}) {
  const router = useRouter();
  const [selected, setSelected] = useState<string>();
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(() => new Set());
  const [list, setList] = useState(false);
  const [zoom, setZoom] = useState(1);
  const viewport = useRef<HTMLDivElement>(null);
  const refs = useRef(new Map<string, HTMLButtonElement>());

  // Node ids are stable across refetches, so live events only add nodes; the
  // selection, expansion and the scroll position of the viewport survive.
  const graph = useMemo(() => buildRunGraph(d as unknown as GraphDetail, childDetails as unknown as (GraphDetail | undefined)[]), [d, childDetails]);
  const keep = useMemo(() => new Set(selected ? [selected] : []), [selected]);
  const layout = useMemo(() => layoutRunGraph(graph, expanded, keep), [graph, expanded, keep]);
  const turnOfEvent = useMemo(() => turnByEvent(d.events), [d.events]);

  const toggle = (id: string) => setExpanded((s) => {
    const next = new Set(s);
    if (!next.delete(id)) next.add(id);
    return next;
  });
  const focusActionBox = () => {
    const box = document.getElementById(ACTION_BOX_ID);
    if (box) {
      box.scrollIntoView({ block: "nearest" });
      box.focus();
    } else if (isNativeShell()) {
      post({ v: PROTOCOL_VERSION, type: "openInMain", path: `/runs/${encodeURIComponent(d.run.id)}?view=simple` });
    }
  };
  /** Opens what a node stands for. */
  const activate = (item: Item) => {
    if (item.kind === "group") return toggle(item.id);
    if (item.kind === "more") return toggle(item.parent);
    const n = item.node;
    if (n.kind === "turn") onOpenTurn(n.turn);
    else if (n.kind === "subagent_run") router.push(`/runs/${n.run_id}`);
    else if (n.kind === "gate") { if (n.state === "pending") focusActionBox(); else onOpenTurn(n.after_turn); }
    else if (n.kind === "error") onOpenEvent(n.seq);
  };
  // A click selects (showing the summary); clicking the selected node, Enter
  // or a double click opens it. A pending gate acts at once.
  const click = (item: Item) => {
    const urgent = item.kind === "node" && item.node.kind === "gate" && item.node.state === "pending";
    if (urgent || selected === item.id || item.kind !== "node") activate(item);
    if (item.kind === "node") setSelected(item.id);
  };
  const keyDown = (e: KeyboardEvent, item: Item) => {
    if (e.key === "Enter") {
      e.preventDefault();
      if (item.kind === "node") setSelected(item.id);
      activate(item);
      return;
    }
    const target = moveFrom(layout, item.id, e.key);
    if (target) {
      e.preventDefault();
      refs.current.get(target)?.focus();
    }
  };
  const nodes = useRef<HTMLElement>(null);
  usePulseList(nodes);
  const nodeButton = (item: Item, className: string, style?: CSSProperties, inList = false): ReactNode => {
    const l = labels(item);
    const isSel = selected === item.id;
    const gate = item.kind === "node" && item.node.kind === "gate";
    const live = l.status === "running";
    return (
      <button
        key={item.id}
        type="button"
        data-node-id={item.id}
        data-pulse-id={item.id}
        data-pulse={l.status}
        ref={inList ? undefined : (el) => { if (el) refs.current.set(item.id, el); else refs.current.delete(item.id); }}
        aria-label={ariaName(item)}
        aria-pressed={item.kind === "node" ? isSel : undefined}
        aria-expanded={item.kind === "node" ? undefined : false}
        aria-current={live ? "step" : undefined}
        onClick={() => click(item)}
        onDoubleClick={() => activate(item)}
        onKeyDown={(e) => keyDown(e, item)}
        className={cx(
          "text-left text-12 transition-colors duration-(--motion-base) focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent",
          className,
          !gate && "rounded-lg border px-2.5 py-1.5",
          !gate && TONE[l.status],
          item.kind === "group" && "border-dashed",
          item.kind === "more" && "border-dashed bg-surface",
          item.kind === "node" && item.node.kind === "error" && "bg-surface",
          item.kind === "node" && item.node.kind === "outcome" && "rounded-full",
          isSel && "ring-2 ring-fg ring-offset-1",
        )}
        style={style}
      >
        {gate ? (
          <span className="relative flex h-full items-center justify-center">
            <svg aria-hidden="true" className="absolute inset-0 size-full" viewBox="0 0 100 100" preserveAspectRatio="none">
              <polygon points="50,2 98,50 50,98 2,50" className={cx(l.status === "waiting" ? "fill-pill-human-bg stroke-state-human" : "fill-pill-neutral-bg stroke-border-strong")} strokeWidth={l.status === "waiting" ? 3 : 1.5} vectorEffect="non-scaling-stroke" />
            </svg>
            <span className={cx("relative font-medium", l.status === "waiting" ? "text-pill-human-fg" : "text-fg-2")}>{l.title}</span>
          </span>
        ) : (
          <>
            <span className="flex items-center justify-between gap-2">
              <span className="truncate font-semibold">{l.title}</span>
              {live && (
                <span aria-hidden="true" className="relative flex size-2.5 flex-none">
                  <span className="absolute inline-flex size-full animate-ping rounded-full bg-accent opacity-60" />
                  <span className="relative inline-flex size-2.5 rounded-full bg-accent" />
                </span>
              )}
            </span>
            <span className="block truncate text-11 opacity-90">{l.sub}</span>
          </>
        )}
      </button>
    );
  };

  const width = Math.max(1, layout.columns.length) * COL + 20;
  const rows = Math.max(0, ...layout.columns.map((c) => c.branch.length));
  const height = BRANCH_Y + rows * ROW + 12;
  const x = (col: number) => 16 + col * COL;
  const by = (row: number) => BRANCH_Y + row * ROW;
  const bx = (col: number, b: BranchItem) => x(col) + 16 + (b.depth - 1) * INDENT;
  const fit = () => {
    const w = viewport.current?.clientWidth ?? width;
    setZoom(Math.max(0.4, Math.min(1, w / width)));
  };
  const sel = selected ? findItem(layout.columns, selected) : undefined;

  return (
    <section ref={nodes} aria-label="Run graph" className="min-h-0 flex-1 overflow-y-auto py-4">
      <div className={`${WORK_COLUMN} flex flex-col gap-3 lg:flex-row`}>
      <div className="flex min-w-0 flex-1 flex-col gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <p className="mr-auto text-12 text-fg-secondary">Turns left to right · subagent runs below the turn that delegated them</p>
          {!list && (
            <>
              <Button variant="outline" onClick={fit}>Fit view</Button>
              <span className="inline-flex items-center gap-1 rounded-md border border-border-strong px-1 text-13">
                <button type="button" aria-label="Zoom out" className="px-1.5" onClick={() => setZoom((z) => Math.max(0.4, +(z - 0.1).toFixed(1)))}>−</button>
                <span aria-live="polite" className="w-10 text-center tabular-nums">{Math.round(zoom * 100)}%</span>
                <button type="button" aria-label="Zoom in" className="px-1.5" onClick={() => setZoom((z) => Math.min(1.5, +(z + 0.1).toFixed(1)))}>+</button>
              </span>
            </>
          )}
          <Button variant="outline" aria-pressed={list} onClick={() => setList(!list)}>{list ? "Graph" : "☰ List"}</Button>
        </div>
        {!layout.columns.length && <p className="text-13 text-fg-secondary">Nothing to draw yet. Turns appear here as the run works.</p>}
        {/* The canvas: hidden on narrow screens and when the list is chosen. */}
        <div ref={viewport} aria-label="Run graph canvas" className={cx("min-h-[240px] overflow-auto rounded-lg border border-border bg-surface", list ? "hidden" : "max-md:hidden")}>
          <div style={{ width: width * zoom, height: height * zoom }}>
            <div className="relative origin-top-left" style={{ width, height, transform: `scale(${zoom})` }}>
              <svg width={width} height={height} className="absolute inset-0" aria-hidden="true">
                {layout.columns.slice(1).map((c, i) => (
                  <path key={`seq-${c.main.id}`} d={`M${x(i) + W},${MAIN_Y + H / 2} H${x(i + 1)}`} stroke="#9aa1ad" strokeWidth={1.5} fill="none" />
                ))}
                {layout.columns.flatMap((c, col) => c.branch.map((b, row) => {
                  const err = b.kind === "node" && b.node.kind === "error";
                  const midY = by(row) + (b.kind === "more" ? 17 : H / 2);
                  return <path key={`br-${b.id}`} d={`M${x(col) + 8},${MAIN_Y + H} V${midY} H${bx(col, b)}`} stroke={err ? "var(--state-blocked)" : "#9aa1ad"} strokeWidth={1.5} strokeDasharray={err ? undefined : "4 3"} fill="none" />;
                }))}
              </svg>
              {layout.columns.map((c, col) => nodeButton(c.main, "absolute", { left: x(col), top: MAIN_Y, width: W, height: H }))}
              {layout.columns.flatMap((c, col) => c.branch.map((b, row) =>
                nodeButton(b, "absolute", { left: bx(col, b), top: by(row), width: W, height: b.kind === "more" ? 34 : H }),
              ))}
            </div>
          </div>
        </div>
        {!list && <Legend />}
        {/* List fallback: the same nodes, nested. Shown on narrow screens and on request; always read by screen readers. */}
        <div className={cx(list ? "" : "md:sr-only md:focus-within:not-sr-only")}>
          <ul aria-label="Run graph as a list" className="flex flex-col gap-1.5 text-13">
            {layout.columns.map((c) => (
              <li key={`li-${c.main.id}`}>
                {nodeButton(c.main, "inline-block min-w-48", undefined, true)}
                {c.main.kind === "group" && <TurnList group={c.main} render={(t) => nodeButton({ kind: "node", id: t.id, node: t }, "inline-block min-w-48", undefined, true)} />}
                {!!c.branch.length && <BranchList items={c.branch} render={(b) => nodeButton(b, "inline-block min-w-48", undefined, true)} />}
              </li>
            ))}
          </ul>
        </div>
      </div>
      {sel && sel.kind === "node" && (
        <Summary node={sel.node} d={d} turnOfEvent={turnOfEvent} onOpen={() => activate(sel)} onClose={() => setSelected(undefined)} />
      )}
      </div>
    </section>
  );
}

function findItem(columns: Column[], id: string): Item | undefined {
  for (const c of columns) {
    if (c.main.id === id) return c.main;
    const b = c.branch.find((x) => x.id === id);
    if (b) return b;
  }
  return undefined;
}

function TurnList({ group, render }: { group: GroupItem; render: (t: GroupItem["turns"][number]) => ReactNode }) {
  return (
    <ul className="ml-5 mt-1 flex flex-col gap-1">
      {group.turns.map((t) => <li key={`li-${t.id}`}>{render(t)}</li>)}
    </ul>
  );
}

/** Nests branch items by depth: each run's nested runs form a sub-list. */
function BranchList({ items, render, depth = 1 }: { items: BranchItem[]; render: (b: BranchItem) => ReactNode; depth?: number }) {
  const out: ReactNode[] = [];
  for (let i = 0; i < items.length; i++) {
    const b = items[i];
    if (b.depth !== depth) continue;
    let j = i + 1;
    while (j < items.length && items[j].depth > depth) j++;
    const nested = items.slice(i + 1, j);
    out.push(
      <li key={`li-${b.id}`}>
        {render(b)}
        {!!nested.length && <BranchList items={nested} render={render} depth={depth + 1} />}
      </li>,
    );
    i = j - 1;
  }
  return <ul className="ml-5 mt-1 flex flex-col gap-1">{out}</ul>;
}

function Legend() {
  const swatch = (cls: string, label: string) => (
    <span className="inline-flex items-center gap-1"><span aria-hidden="true" className={cx("inline-block size-2.5 rounded-sm", cls)} />{label}</span>
  );
  return (
    <p className="flex flex-wrap items-center gap-3 text-11 text-fg-secondary">
      {swatch("bg-state-done", "done")}
      {swatch("bg-accent", "running")}
      {swatch("bg-state-human", "waiting")}
      {swatch("bg-state-blocked", "failed")}
      {swatch("bg-border-strong", "pending / cancelled")}
      <span>←/→ move along turns · ↑/↓ to subagents · Enter opens · Tab cycles nodes</span>
    </p>
  );
}

function Summary({ node, d, turnOfEvent, onOpen, onClose }: {
  node: GraphNode; d: RunDetail; turnOfEvent: Map<number, number>; onOpen: () => void; onClose: () => void;
}) {
  const rows: [string, ReactNode][] = [];
  let title = "";
  let action: string | undefined;
  let message: string | null = null;
  switch (node.kind) {
    case "turn": {
      title = `Turn ${node.turn} · ${node.trigger}`;
      rows.push(["Status", STATUS_LABEL[node.status]], ["Duration", duration(node.started_at, node.ended_at)], ["Cost", node.cost_usd != null ? `$${node.cost_usd.toFixed(2)}` : "–"]);
      message = finalMessage(d.events.filter((e) => turnOfEvent.get(e.seq) === node.turn));
      action = "Open in Details";
      break;
    }
    case "subagent_run": {
      const r = d.child_runs.find((c) => c.id === node.run_id);
      title = `↳ ${node.agent}`;
      rows.push(["Status", STATUS_LABEL[node.status]], ["Duration", r ? duration(r.started_at, r.ended_at) : "–"], ["Cost", `$${node.cost_usd.toFixed(2)}`]);
      if (node.child_count) rows.push(["Nested runs", node.child_count]);
      message = r?.outcome ?? null;
      action = "Open run ↗";
      break;
    }
    case "gate":
      title = `${GATE_LABEL[node.gate]} after turn ${node.after_turn}`;
      rows.push(["State", node.state]);
      if (node.detail) rows.push(["Detail", <code key="d" className="text-12">{node.detail}</code>]);
      action = node.state === "pending" ? "Go to the action" : `Open turn ${node.after_turn}`;
      break;
    case "error":
      title = `Error in turn ${node.turn}`;
      message = node.message;
      action = "Open in Details";
      break;
    case "outcome":
      title = "Outcome";
      rows.push(["Status", STATUS_LABEL[node.status]]);
      message = node.text || null;
      break;
  }
  return (
    <aside aria-label="Selected node" className="flex w-full flex-none flex-col gap-2 self-start rounded-lg border border-border bg-surface p-4 lg:w-80">
      <div className="flex items-start justify-between gap-2">
        <h2 className="text-14 font-semibold">{title}</h2>
        <button type="button" aria-label="Close summary" className="text-fg-tertiary hover:text-fg" onClick={onClose}>×</button>
      </div>
      {!!rows.length && (
        <dl className="grid grid-cols-[6.5rem_1fr] gap-y-1 text-13">
          {rows.map(([k, v]) => (
            <div key={k} className="contents"><dt className="text-fg-secondary">{k}</dt><dd>{v}</dd></div>
          ))}
        </dl>
      )}
      {message && (
        <>
          <p className="text-13 text-fg-secondary">{node.kind === "turn" ? "Last message" : node.kind === "error" ? "Message" : "Outcome"}</p>
          <p className="line-clamp-6 whitespace-pre-line rounded-md bg-pill-neutral-bg p-2.5 text-13 text-fg-2">{message}</p>
        </>
      )}
      {action && <Button variant="primary" className="self-start" onClick={onOpen}>{action}</Button>}
    </aside>
  );
}
