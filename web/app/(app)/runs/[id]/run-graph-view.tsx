"use client";

import { useRouter } from "next/navigation";
import { useMemo, useRef, useState, type CSSProperties, type KeyboardEvent, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { readableModelId, formatSpan } from "@/lib/chat-ui";
import { cx } from "@/lib/cx";
import { compact, duration } from "@/lib/format";
import { buildRunGraph, type GraphDetail, type GraphNode, type NodeStatus, type SubagentFlag, type SubagentJobNode } from "@/lib/run-graph";
import { layoutRunGraph, moveFrom, type BranchItem, type Column, type GroupItem, type MainItem } from "@/lib/run-graph-layout";
import { argSummary, finalMessage, rowEvent, rowsOf, str, toolName, turnByEvent, type Ev } from "@/lib/run-view";
import { Button } from "@/components/ui/button";
import { usePulseList } from "@/components/ui/motion";
import { WORK_COLUMN } from "@/components/domain/work-detail-header";
import { ACTION_BOX_ID } from "./run-panels";

type RunDetail = Schemas["RunDetail"];
type P = Record<string, unknown>;


const COL = 192;
const W = 156;
const H = 58;
const MAIN_Y = 20;
const BRANCH_Y = MAIN_Y + H + 36;
const ROW = 70;
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
const TIER_TONE: Record<string, string> = {
  fast: "bg-pill-neutral-bg text-pill-neutral-fg",
  standard: "bg-accent-soft text-accent",
  deep: "bg-pill-review-bg text-pill-review-fg",
};
const FLAG_LABEL: Record<SubagentFlag, string> = {
  capped: "capped ↓",
  spinning: "spinning",
  queue_bound: "queue",
  serial: "serial!",
  failed: "failed",
};

function TierPill({ tier }: { tier: string }) {
  if (!tier) return null;
  const tone = TIER_TONE[tier] ?? "bg-pill-neutral-bg text-pill-neutral-fg";
  return <span className={cx("inline-flex flex-none items-center rounded-full px-1.5 py-[1px] font-mono text-10 font-medium", tone)}>{tier}</span>;
}

function FlagBadge({ flag }: { flag: SubagentFlag }) {
  const tone = flag === "failed" ? "bg-pill-blocked-bg text-pill-blocked-fg" : "bg-pill-human-bg text-pill-human-fg";
  return <span className={cx("inline-flex flex-none items-center rounded px-1 py-[1px] font-mono text-10 font-medium", tone)}>{FLAG_LABEL[flag]}</span>;
}

function formatMs(ms?: number): string {
  if (ms == null) return "–";
  return ms < 1000 ? `${ms}ms` : formatSpan(ms);
}

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
    case "subagent_job":
      return {
        title: `↳ ${n.role || n.agent_type}`,
        sub: [n.tier || n.agent_type, n.model ? readableModelId(n.model) : "", n.effort].filter(Boolean).join(" · "),
        status: n.status,
      };
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
  const [mode, setMode] = useState<"graph" | "waterfall" | "list">("graph");
  const [zoom, setZoom] = useState(1);
  const viewport = useRef<HTMLDivElement>(null);
  const refs = useRef(new Map<string, HTMLButtonElement>());

  // Node ids are stable across refetches, so live events only add nodes; the
  // selection, expansion and the scroll position of the viewport survive.
  const graph = useMemo(() => buildRunGraph(d as unknown as GraphDetail, childDetails as unknown as (GraphDetail | undefined)[]), [d, childDetails]);
  const jobNodes = useMemo(() => graph.nodes.filter((n): n is SubagentJobNode => n.kind === "subagent_job"), [graph]);
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
    box?.scrollIntoView({ block: "nearest" });
    box?.focus();
  };
  /** Opens what a node stands for. */
  const activate = (item: Item) => {
    if (item.kind === "group") return toggle(item.id);
    if (item.kind === "more") return toggle(item.parent);
    const n = item.node;
    if (n.kind === "turn" || n.kind === "subagent_job") onOpenTurn(n.turn);
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
    const job = item.kind === "node" && item.node.kind === "subagent_job" ? item.node : undefined;
    const primaryFlag = job?.flags.find((f) => f !== "failed") ?? job?.flags[0];
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
            <span className="flex items-center justify-between gap-1.5">
              <span className="min-w-0 truncate font-semibold">{l.title}</span>
              <span className="flex flex-none items-center gap-1">
                {job && <TierPill tier={job.tier} />}
                {live && (
                  <span aria-hidden="true" className="relative flex size-2.5 flex-none">
                    <span className="absolute inline-flex size-full animate-ping rounded-full bg-accent opacity-60" />
                    <span className="relative inline-flex size-2.5 rounded-full bg-accent" />
                  </span>
                )}
              </span>
            </span>
            {job ? (
              <span className="mt-0.5 flex items-center justify-between gap-1 text-11 opacity-90">
                <span className="min-w-0 truncate">
                  {[job.model ? readableModelId(job.model) : job.agent_type, job.effort].filter(Boolean).join(" · ")}
                </span>
                {primaryFlag && <FlagBadge flag={primaryFlag} />}
              </span>
            ) : (
              <span className="block truncate text-11 opacity-90">{l.sub}</span>
            )}
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
  const selNode = sel && sel.kind === "node" ? sel.node : selected ? graph.nodes.find((n) => n.id === selected) : undefined;
  const batches = batchBoxes(layout.columns);

  return (
    <section ref={nodes} aria-label="Run graph" className="min-h-0 flex-1 overflow-y-auto py-4">
      <div className={`${WORK_COLUMN} flex flex-col gap-3 lg:flex-row`}>
      <div className="flex min-w-0 flex-1 flex-col gap-2">
        <div className="flex flex-wrap items-center gap-2">
          <p className="mr-auto text-12 text-fg-secondary">
            {mode === "waterfall"
              ? "Subagent spawn and execution waterfall grouped by turn"
              : "Turns left to right · subagents below the turn that delegated them"}
          </p>
          {mode === "graph" && (
            <>
              <Button variant="outline" onClick={fit}>Fit view</Button>
              <span className="inline-flex items-center gap-1 rounded-md border border-border-strong px-1 text-13">
                <button type="button" aria-label="Zoom out" className="px-1.5" onClick={() => setZoom((z) => Math.max(0.4, +(z - 0.1).toFixed(1)))}>−</button>
                <span aria-live="polite" className="w-10 text-center tabular-nums">{Math.round(zoom * 100)}%</span>
                <button type="button" aria-label="Zoom in" className="px-1.5" onClick={() => setZoom((z) => Math.min(1.5, +(z + 0.1).toFixed(1)))}>+</button>
              </span>
            </>
          )}
          {jobNodes.length > 0 && (
            <Button variant="outline" aria-pressed={mode === "waterfall"} onClick={() => setMode((m) => (m === "waterfall" ? "graph" : "waterfall"))}>
              Waterfall
            </Button>
          )}
          <Button variant="outline" aria-pressed={mode === "list"} onClick={() => setMode((m) => (m === "list" ? "graph" : "list"))}>
            {mode === "list" ? "Graph" : "☰ List"}
          </Button>
        </div>
        {!layout.columns.length && <p className="text-13 text-fg-secondary">Nothing to draw yet. Turns appear here as the run works.</p>}
        {mode === "waterfall" ? (
          <SubagentWaterfall d={d} jobs={jobNodes} selected={selected} onSelect={(id) => setSelected(id)} />
        ) : (
          <>
            {/* The canvas: hidden on narrow screens and when the list is chosen. */}
            <div ref={viewport} aria-label="Run graph canvas" className={cx("min-h-[240px] overflow-auto rounded-lg border border-border bg-surface", mode === "list" ? "hidden" : "max-md:hidden")}>
              <div style={{ width: width * zoom, height: height * zoom }}>
                <div className="relative origin-top-left" style={{ width, height, transform: `scale(${zoom})` }}>
                  <svg width={width} height={height} className="absolute inset-0" aria-hidden="true">
                    {batches.map((box) => {
                      const left = bx(box.col, box.first) - 6;
                      const top = by(box.start) - 10;
                      const h = (box.end - box.start) * ROW + H + 16;
                      return (
                        <g key={box.key}>
                          <rect x={left} y={top} width={W + 12} height={h} rx={10} strokeWidth={1.25} strokeDasharray="4 3" className="fill-surface-sunken/35 stroke-border-strong" />
                          <text x={left + 8} y={by(box.start) - 2} className="fill-fg-tertiary font-mono text-10">batch · {box.count}</text>
                        </g>
                      );
                    })}
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
            {mode === "graph" && <Legend />}
            {/* List fallback: the same nodes, nested. Shown on narrow screens and on request; always read by screen readers. */}
            <div className={cx(mode === "list" ? "" : "md:sr-only md:focus-within:not-sr-only")}>
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
          </>
        )}
      </div>
      {selNode && (
        <Summary node={selNode} d={d} turnOfEvent={turnOfEvent} onOpen={() => activate({ kind: "node", id: selNode.id, node: selNode })} onClose={() => setSelected(undefined)} />
      )}
      </div>
    </section>
  );
}

function batchBoxes(columns: Column[]) {
  const out: { key: string; col: number; start: number; end: number; count: number; first: BranchItem }[] = [];
  columns.forEach((c, col) => {
    let i = 0;
    while (i < c.branch.length) {
      const b = c.branch[i];
      const batchId = b.kind === "node" && b.node.kind === "subagent_job" ? b.node.batch_id : undefined;
      if (!batchId) { i++; continue; }
      let j = i + 1;
      while (j < c.branch.length) {
        const next = c.branch[j];
        if (next.kind === "node" && next.node.kind === "subagent_job" && next.node.batch_id === batchId) j++;
        else break;
      }
      if (j - i >= 2) out.push({ key: `${col}:${batchId}:${i}`, col, start: i, end: j - 1, count: j - i, first: b });
      i = j;
    }
  });
  return out;
}

const WF_ACTIVE: Record<NodeStatus, string> = {
  done: "bg-state-done",
  running: "bg-accent",
  waiting: "bg-state-human",
  failed: "bg-state-blocked",
  pending: "bg-border-strong",
  cancelled: "bg-border-strong",
};

function groupJobsForWaterfall(jobs: SubagentJobNode[]) {
  type Entry = { kind: "single"; job: SubagentJobNode } | { kind: "batch"; batchId: string; jobs: SubagentJobNode[] };
  const byTurn = new Map<number, SubagentJobNode[]>();
  for (const j of jobs) byTurn.set(j.turn, [...(byTurn.get(j.turn) ?? []), j]);
  return [...byTurn.entries()]
    .sort((a, b) => a[0] - b[0])
    .map(([turn, list]) => {
      const entries: Entry[] = [];
      let i = 0;
      while (i < list.length) {
        const cur = list[i];
        if (!cur.batch_id) {
          entries.push({ kind: "single", job: cur });
          i++;
          continue;
        }
        let j = i + 1;
        while (j < list.length && list[j].batch_id === cur.batch_id) j++;
        if (j - i >= 2) entries.push({ kind: "batch", batchId: cur.batch_id, jobs: list.slice(i, j) });
        else entries.push({ kind: "single", job: cur });
        i = j;
      }
      return { turn, jobs: list, entries };
    });
}

function SubagentWaterfall({ d, jobs, selected, onSelect }: {
  d: RunDetail;
  jobs: SubagentJobNode[];
  selected?: string;
  onSelect: (id: string) => void;
}) {
  const latestMs = useMemo(() => {
    const times = [
      ...(d.run.ended_at ? [Date.parse(d.run.ended_at)] : []),
      ...d.events.map((e) => Date.parse(e.at)),
      ...jobs.flatMap((j) => [Date.parse(j.created_at), j.started_at ? Date.parse(j.started_at) : NaN, j.completed_at ? Date.parse(j.completed_at) : NaN]),
    ].filter(Number.isFinite);
    return times.length ? Math.max(...times) : 0;
  }, [d.run.ended_at, d.events, jobs]);

  const groups = useMemo(() => groupJobsForWaterfall(jobs), [jobs]);
  if (!groups.length) return <p className="text-13 text-fg-secondary">No subagent jobs recorded in this run.</p>;

  return (
    <div aria-label="Subagent waterfall" className="flex flex-col gap-3">
      {groups.map(({ turn, jobs: turnJobs, entries }) => {
        const turnMeta = d.turns.find((t) => t.seq === turn);
        const createdTimes = turnJobs.map((j) => Date.parse(j.created_at)).filter(Number.isFinite);
        const minMs = createdTimes.length ? Math.min(...createdTimes) : 0;
        const turnEnd = turnMeta?.ended_at ? Date.parse(turnMeta.ended_at) : NaN;
        const candidateEnds = [
          minMs + 1,
          latestMs,
          ...(Number.isFinite(turnEnd) ? [turnEnd] : []),
          ...turnJobs.flatMap((j) => [Date.parse(j.created_at), j.started_at ? Date.parse(j.started_at) : NaN, j.completed_at ? Date.parse(j.completed_at) : NaN]).filter(Number.isFinite),
        ];
        const maxMs = Math.max(...candidateEnds);
        const span = Math.max(1, maxMs - minMs);

        const renderRow = (job: SubagentJobNode) => {
          const created = Date.parse(job.created_at);
          const started = job.started_at ? Date.parse(job.started_at) : NaN;
          const completed = job.completed_at ? Date.parse(job.completed_at) : NaN;
          const activeEnd = Number.isFinite(completed) ? completed : maxMs;
          const queueEnd = Number.isFinite(started) ? started : activeEnd;
          const qLeft = Math.max(0, Math.min(100, ((created - minMs) / span) * 100));
          const qWidth = Math.max(0, Math.min(100 - qLeft, ((queueEnd - created) / span) * 100));
          const aLeft = Number.isFinite(started) ? Math.max(0, Math.min(100, ((started - minMs) / span) * 100)) : 0;
          const aWidth = Number.isFinite(started) ? Math.max(1.5, Math.min(100 - aLeft, ((activeEnd - started) / span) * 100)) : 0;
          const isSel = selected === job.id;
          return (
            <button
              key={job.id}
              type="button"
              aria-pressed={isSel}
              onClick={() => onSelect(job.id)}
              className={cx(
                "flex w-full flex-col gap-1.5 rounded-lg border px-3 py-2 text-left transition-colors duration-(--motion-fast) hover:bg-hover sm:flex-row sm:items-center sm:gap-3",
                isSel ? "border-fg bg-accent-soft/40 ring-1 ring-fg" : "border-border bg-surface",
              )}
            >
              <div className="flex min-w-0 flex-none flex-col gap-0.5 sm:w-56">
                <div className="flex min-w-0 items-center gap-1.5">
                  <span aria-hidden="true" className={cx("size-2 flex-none rounded-full", WF_ACTIVE[job.status])} />
                  <span className="min-w-0 truncate text-12 font-semibold text-fg">{job.role || job.agent_type}</span>
                  <TierPill tier={job.tier} />
                </div>
                <div className="flex min-w-0 flex-wrap items-center gap-1 text-11 text-fg-secondary">
                  <span className="truncate">{[job.model ? readableModelId(job.model) : job.agent_type, job.effort].filter(Boolean).join(" · ")}</span>
                  {job.flags.map((f) => <FlagBadge key={f} flag={f} />)}
                </div>
              </div>
              <div className="relative h-5 min-w-0 flex-1 overflow-hidden rounded bg-surface-sunken">
                {qWidth > 0 && (
                  <div
                    title={`Queued ${formatMs(job.queued_ms)}`}
                    style={{ left: `${qLeft}%`, width: `${Math.max(1, qWidth)}%` }}
                    className="absolute inset-y-1 rounded-sm border border-border-strong bg-[repeating-linear-gradient(-45deg,transparent,transparent_3px,var(--border-strong)_3px,var(--border-strong)_6px)] opacity-80"
                  />
                )}
                {Number.isFinite(started) && (
                  <div
                    title={`Ran ${formatMs(job.duration_ms)}`}
                    style={{ left: `${aLeft}%`, width: `${aWidth}%` }}
                    className={cx("absolute inset-y-1 rounded-sm", WF_ACTIVE[job.status])}
                  />
                )}
              </div>
              <div className="flex flex-none items-center justify-between gap-2 font-mono text-11 text-fg-tertiary sm:w-28 sm:justify-end">
                <span>{job.duration_ms != null ? formatMs(job.duration_ms) : STATUS_LABEL[job.status]}</span>
                <span>{job.tool_calls}c</span>
              </div>
            </button>
          );
        };

        return (
          <section key={turn} className="rounded-lg border border-border bg-surface p-3">
            <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
              <h3 className="text-13 font-semibold text-fg">
                {turn === 0 ? "Setup" : `Turn ${turn}`}{turnMeta ? ` · ${turnMeta.trigger}` : ""}
              </h3>
              <span className="font-mono text-11 text-fg-tertiary">
                {turnJobs.length} subagent{turnJobs.length === 1 ? "" : "s"} · {formatMs(span)} window
              </span>
            </div>
            <div className="flex flex-col gap-2">
              {entries.map((entry, idx) =>
                entry.kind === "batch" ? (
                  <div key={`${entry.batchId}:${idx}`} className="flex flex-col gap-1.5 rounded-lg border border-dashed border-border-strong bg-surface-sunken/35 p-2">
                    <span className="px-1 font-mono text-10 text-fg-tertiary">Parallel batch · {entry.jobs.length} subagents</span>
                    {entry.jobs.map(renderRow)}
                  </div>
                ) : (
                  renderRow(entry.job)
                ),
              )}
            </div>
          </section>
        );
      })}
    </div>
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

function spawnContextBeforeJob(events: RunDetail["events"], turnOfEvent: Map<number, number>, node: SubagentJobNode): { label: string; text: string } | null {
  if (node.reason) return { label: "Why spawned", text: node.reason };
  const sorted = [...events].sort((a, b) => a.seq - b.seq);
  const marker = sorted.find((e) => {
    if (e.type !== "lifecycle") return false;
    const p = (e.payload ?? {}) as P;
    return (p.state === "subagent_queued" || p.state === "subagent_started") && p.subagent_id === node.job_id;
  });
  const cutoffSeq = marker?.seq;
  const cutoffMs = Date.parse(node.created_at);
  let fallback: { isThinking: boolean; text: string } | null = null;
  for (const e of sorted) {
    if (cutoffSeq != null ? e.seq >= cutoffSeq : Date.parse(e.at) > cutoffMs) break;
    if ((turnOfEvent.get(e.seq) ?? 0) !== node.turn) continue;
    if (e.type !== "message") continue;
    const p = (e.payload ?? {}) as P;
    if (p.subagent === true) continue;
    const isThinking = p.kind === "thinking";
    if (p.kind && !isThinking) continue;
    const text = str(p.text).trim();
    if (text) fallback = { isThinking, text };
  }
  return fallback ? { label: fallback.isThinking ? "Thinking before spawn" : "Context before spawn", text: fallback.text } : null;
}

function flagDescription(flag: SubagentFlag, node: SubagentJobNode): string {
  switch (flag) {
    case "capped":
      return `Requested tier "${node.requested_tier}" capped to "${node.tier}" (parent tier ceiling).`;
    case "spinning":
      return `High tool count (${node.tool_calls} calls) — check for looping or overly broad search.`;
    case "queue_bound":
      return `Spent ${formatMs(node.queued_ms)} queued before starting (${formatMs(node.duration_ms)} active).`;
    case "serial":
      return `Spawned sequentially with other unbatched jobs in Turn ${node.turn} instead of run_subagents.`;
    case "failed":
      return node.error ? `Failed: ${node.error.split("\n")[0]}` : "Subagent execution failed.";
  }
}

function SubagentJobInspector({ node, d, turnOfEvent, onOpen }: {
  node: SubagentJobNode;
  d: RunDetail;
  turnOfEvent: Map<number, number>;
  onOpen: () => void;
}) {
  const why = spawnContextBeforeJob(d.events, turnOfEvent, node);
  const nestedRows = rowsOf(
    d.events.filter((e): e is typeof d.events[number] => {
      if (e.type !== "tool_call" && e.type !== "tool_result") return false;
      const p = (e.payload ?? {}) as P;
      return p.subagent_id === node.job_id;
    }) as Ev[],
  );
  const meta: [string, ReactNode][] = [
    ["Status", STATUS_LABEL[node.status]],
    ["Type", node.agent_type],
    ["Routing", node.flags.includes("capped") ? `${node.requested_tier} → ${node.tier} (capped)` : (node.tier || "default")],
    ["Model", [node.model ? readableModelId(node.model) : "", node.effort].filter(Boolean).join(" · ") || "–"],
  ];
  if (node.batch_size > 1) meta.push(["Batch", `parallel batch of ${node.batch_size}`]);
  if (node.queued_ms != null) meta.push(["Queued", formatMs(node.queued_ms)]);
  if (node.duration_ms != null) meta.push(["Ran", formatMs(node.duration_ms)]);
  meta.push(["Tool calls", String(node.tool_calls)]);
  meta.push(["Tokens", `${compact(node.input_tokens)} in / ${compact(node.output_tokens)} out${node.cached_tokens > 0 ? ` (${compact(node.cached_tokens)} cached)` : ""}`]);
  if (node.cost_usd != null) meta.push(["Cost", `$${node.cost_usd.toFixed(node.cost_usd < 0.01 ? 4 : 2)}`]);

  return (
    <div className="flex flex-col gap-2.5">
      {node.flags.length > 0 && (
        <ul className="flex flex-col gap-1">
          {node.flags.map((f) => (
            <li key={f} className={cx("rounded-md border px-2.5 py-1.5 text-12", f === "failed" ? "border-state-blocked bg-pill-blocked-bg text-pill-blocked-fg" : "border-state-human/50 bg-pill-human-bg text-pill-human-fg")}>
              {flagDescription(f, node)}
            </li>
          ))}
        </ul>
      )}
      {why && (
        <div className="flex flex-col gap-1">
          <p className="text-12 text-fg-secondary">{why.label}</p>
          <p className="whitespace-pre-line rounded-md bg-pill-neutral-bg p-2.5 text-12 leading-relaxed text-fg-2">{why.text}</p>
        </div>
      )}
      <dl className="grid grid-cols-[6rem_1fr] gap-y-1 text-12">
        {meta.map(([k, v]) => (
          <div key={k} className="contents"><dt className="text-fg-secondary">{k}</dt><dd className="min-w-0 break-words">{v}</dd></div>
        ))}
      </dl>
      {nestedRows.length > 0 && (
        <details className="rounded-md border border-border-subtle bg-surface-sunken/40 p-2 text-12">
          <summary className="cursor-pointer font-medium text-fg-secondary">Nested tool calls ({nestedRows.length})</summary>
          <ul className="mt-1.5 flex max-h-48 flex-col gap-1 overflow-y-auto font-mono text-11">
            {nestedRows.map((row) => {
              const e = rowEvent(row);
              if (row.kind !== "tool") return null;
              const cp = (row.call.payload ?? {}) as P;
              const rp = (row.result?.payload ?? {}) as P;
              const err = rp.is_error === true || cp.denied_by_harness === true;
              return (
                <li key={e.seq} className="flex items-center gap-1.5">
                  <span className={cx("flex-none font-medium", err ? "text-pill-blocked-fg" : "text-fg")}>{toolName(str(cp.tool))}</span>
                  <span className="min-w-0 flex-1 truncate text-fg-tertiary">{argSummary(cp.input)}</span>
                  <span className={cx("flex-none", err ? "text-pill-blocked-fg" : "text-fg-tertiary")}>{err ? "err" : row.result ? "done" : "running"}</span>
                </li>
              );
            })}
          </ul>
        </details>
      )}
      {node.prompt && (
        <details className="rounded-md border border-border-subtle bg-surface-sunken/40 p-2 text-12">
          <summary className="cursor-pointer font-medium text-fg-secondary">Prompt</summary>
          <pre className="mt-1.5 max-h-48 overflow-auto whitespace-pre-wrap font-mono text-11 leading-relaxed text-fg-2">{node.prompt}</pre>
        </details>
      )}
      {(node.error || node.result_text) && (
        <details open={!!node.error} className="rounded-md border border-border-subtle bg-surface-sunken/40 p-2 text-12">
          <summary className="cursor-pointer font-medium text-fg-secondary">{node.error ? "Error & output" : "Report"}</summary>
          {node.error && <pre className="mt-1.5 max-h-40 overflow-auto whitespace-pre-wrap rounded bg-pill-blocked-bg p-2 font-mono text-11 text-pill-blocked-fg">{node.error}</pre>}
          {node.result_text && <pre className="mt-1.5 max-h-56 overflow-auto whitespace-pre-wrap font-mono text-11 leading-relaxed text-fg-2">{node.result_text}</pre>}
        </details>
      )}
      <Button variant="primary" className="self-start" onClick={onOpen}>Open turn {node.turn}</Button>
    </div>
  );
}

function Summary({ node, d, turnOfEvent, onOpen, onClose }: {
  node: GraphNode; d: RunDetail; turnOfEvent: Map<number, number>; onOpen: () => void; onClose: () => void;
}) {
  if (node.kind === "subagent_job") {
    return (
      <aside aria-label="Selected node" className="flex w-full flex-none flex-col gap-2 self-start rounded-lg border border-border bg-surface p-4 lg:w-80">
        <div className="flex items-start justify-between gap-2">
          <div className="flex min-w-0 flex-wrap items-center gap-1.5">
            <h2 className="text-14 font-semibold">↳ {node.role || node.agent_type}</h2>
            <TierPill tier={node.tier} />
          </div>
          <button type="button" aria-label="Close summary" className="text-fg-tertiary hover:text-fg" onClick={onClose}>×</button>
        </div>
        <SubagentJobInspector node={node} d={d} turnOfEvent={turnOfEvent} onOpen={onOpen} />
      </aside>
    );
  }
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
