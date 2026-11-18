"use client";

import { useRecordVisit } from "@/components/shell/use-record-visit";
import { runTitle } from "@/lib/run-list";
import { TokenUsage } from "@/components/domain/token-usage";
import { eventTokenUsage, tokenBreakdown } from "@/lib/token-usage";
import { runCost } from "@/lib/format";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { useControlRunById, useDelegatedRunLogs, useRunLog } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { absoluteTime, compact, duration } from "@/lib/format";
import {
  PURPOSE_LABEL, argSummary, delegateChild, groupByTurn, isFailedRow, parseRunAnchor, pickRunView, rowEvent, rowsOf, str,
  toolLink, toolName, triggerLine, turnAt, turnByEvent, turnStarts, workHref, type Row, type RunViewMode,
} from "@/lib/run-view";
import { Button } from "@/components/ui/button";
import { Tabs, Toggle } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, Skeleton, TextInput } from "@/components/ui/primitives";
import { AgentAvatar } from "@/components/domain/avatars";
import { Stat } from "@/components/domain/data";
import { Flag, MonoChip, SmallPill } from "@/components/domain/labels";
import { RunCostChip } from "@/components/domain/cost-chip";
import { RUN_ENDED, RUN_STATE as STATE, StatusPill } from "@/components/domain/run-status";
import { TopBar, type Crumb } from "@/components/shell/topbar";
import { ActionBox, RunRail, confirmCancel } from "./run-panels";
import { CostValue, RunThread } from "./run-thread";
import { RunContext } from "./run-context";
import { RunFiles } from "./run-files";
import { RunGraphView } from "./run-graph-view";
import { CompactRunDetail } from "./run-compact";
import { useCompact } from "@/lib/viewport";

type RunDetail = Schemas["RunDetail"];
type RunEvent = Schemas["RunEvent"];
type Turn = Schemas["RunTurn"];
type Run = Schemas["Run"];
type P = Record<string, unknown>;

const TRIGGER: Record<Turn["trigger"], string> = {
  start: "Started by dispatch",
  approval: "Resumed: a person decided",
  comment: "Resumed: a person replied",
  resume: "Resumed",
  delegation: "Resumed: a sub agent finished",
  image_followup: "Resumed: generated images to react to",
};

const clock = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false });

function lifecycleText(p: P): ReactNode {
  switch (p.state) {
    case "queued":
      return "Dispatched; waiting for a runner slot";
    case "starting":
      return (
        <>
          Preparing the workspace on <code className="inline">{str(p.backend)}</code> ({str(p.runner)})
        </>
      );
    case "waiting_for_quota":
      return p.reset_known ? <>Out of provider usage on {str(p.harness)}; holding until the limit resets</> : <>Out of provider usage on {str(p.harness)}; holding, attempt {str(p.attempt)}, reset time unknown</>;
    case "quota_resume_requested":
      return "A person asked to try again now";
    case "quota_resumed":
      return <>Resumed after the provider limit on {str(p.harness)}</>;
    case "checkpoint_pushed":
      return <>Unpushed work saved to <code className="inline">{str(p.branch)}</code></>;
    case "checkpoint_recovered":
      return <>Recovered work from an earlier run: <code className="inline">{str(p.branch)}</code></>;
    case "checkpoint_failed":
      return <>Could not save unpushed work, so the workspace was kept: {str(p.reason)}</>;
    case "environment_snapshot":
      return <Link href="/settings/runner" className="underline underline-offset-2">Runner environment recorded</Link>;
    case "workspace_ready":
      return (
        <>
          Workspace ready on branch <code className="inline">{str(p.branch)}</code>
        </>
      );
    case "running":
      return p.trigger ? <>Running again: {str(p.message).split("\n")[0]}</> : "Running";
    case "turn_started":
      return (
        <>
          Turn {str(p.turn)} started{p.resume ? " · resumed the harness session" : ""}
        </>
      );
    case "harness_notice":
      return <>Harness notice: {str(p.message)}</>;
    case "harness_started":
      return (
        <>
          <code className="inline">{str(p.harness)}</code> started · session <span className="font-mono text-12">{str(p.session_id).slice(0, 13)}</span>
        </>
      );
    case "turn_ended":
      return (
        <>
          Turn {str(p.turn)} ended · exit <span className="font-mono">{str(p.exit_code)}</span>
        </>
      );
    case "waiting":
    case "paused":
    case "completed":
    case "failed":
    case "cancelled":
      return (
        <>
          Run is now <SmallPill tone={STATE[str(p.state)]?.tone ?? "neutral"}>{STATE[str(p.state)]?.label ?? str(p.state)}</SmallPill>
          {p.reason ? <span className="ml-2 whitespace-pre-line text-fg-secondary">{str(p.reason)}</span> : null}
        </>
      );
  }
  return str(p.state);
}


type Entry = { row: Row<RunEvent>; source?: Run; runId: string; turn: number };

/** A collapsed tool row: name, args, status; click for the result. MCP reads link to the page or artifact. */
function ToolRow({ row, open, onToggle, runs, calls }: { row: Extract<Row<RunEvent>, { kind: "tool" }>; open: boolean; onToggle: () => void; runs: Run[]; calls: RunEvent[] }) {
  const { call, result } = row;
  const p = call.payload as P;
  const r = (result?.payload ?? {}) as P;
  const denied = p.denied_by_harness === true;
  const failed = r.is_error === true;
  const out = str(r.output);
  const link = toolLink(str(p.tool), p.input);
  const child = delegateChild(call, runs, calls);
  const took = result ? Math.max(0, Date.parse(result.at) - Date.parse(call.at)) : null;
  return (
    <div className={cx("min-w-0 rounded-lg border bg-surface", denied || failed ? "border-pill-blocked-bg" : "border-border")}>
      <div className="flex items-center gap-2 px-3 py-2">
        <button type="button" aria-expanded={open} onClick={onToggle} className="flex min-w-0 flex-1 items-center gap-2 text-left">
          <span aria-hidden className="w-3 flex-none text-fg-tertiary">{open ? "▾" : "▸"}</span>
          <span className="font-mono text-13 font-medium">{toolName(str(p.tool))}</span>
          <span className="min-w-0 flex-1 truncate font-mono text-12 text-fg-tertiary">{argSummary(p.input)}</span>
        </button>
        {link && <Link href={link.href} className="flex-none text-12 text-accent hover:underline">Open {link.label} ↗</Link>}
        {child && <Link href={`/runs/${child.id}`} className="flex-none text-12 text-accent hover:underline">{child.agent.name} run ↗</Link>}
        {denied ? (
          <Flag tone="blocked">denied by harness</Flag>
        ) : failed ? (
          <Flag tone="blocked">error{r.exit_code != null ? ` · exit ${str(r.exit_code)}` : ""}</Flag>
        ) : result ? (
          <span className="flex flex-none items-center gap-1.5 font-mono text-11 text-fg-tertiary">
            <Icon name="check" size={13} className="text-state-done" />
            <span className="sr-only">done</span>
            {took != null && took >= 1000 ? `${Math.round(took / 1000)}s` : ""}
          </span>
        ) : (
          <span className="text-11 text-fg-tertiary">running…</span>
        )}
      </div>
      {open && (
        out ? (
          <pre className="max-h-64 overflow-auto border-t border-border-subtle px-3 py-2 font-mono text-12 leading-relaxed text-fg-secondary">{out}</pre>
        ) : (
          <p className="border-t border-border-subtle px-3 py-2 text-12 text-fg-tertiary">{result ? "No output." : "No result yet."}</p>
        )
      )}
    </div>
  );
}

function EventRow({ entry, plan, tools, runs, calls }: { entry: Entry; plan: Run["plan"]; tools: { open: (key: string) => boolean; toggle: (key: string) => void }; runs: Run[]; calls: RunEvent[] }) {
  const { row, source } = entry;
  const e = rowEvent(row);
  const p = e.payload as P;
  const red = e.type === "error" || isFailedRow(row);
  const amber = e.type === "lifecycle" && (p.state === "waiting" || p.state === "paused");
  const key = `${entry.runId}:${e.seq}`;
  let body: ReactNode;
  switch (row.kind === "tool" ? "tool" : e.type) {
    case "tool":
      body = <ToolRow row={row as Extract<Row<RunEvent>, { kind: "tool" }>} open={tools.open(key)} onToggle={() => tools.toggle(key)} runs={runs} calls={calls} />;
      break;
    case "message": {
      // Agent text from the harness, or a Vesper event logged by a tool
      // (plan posted, step moved, log_event).
      const stepText = p.kind === "step" ? (plan.find((s) => s.position === Number(p.step)) ?? plan[Number(p.step) - 1])?.text : undefined;
      body =
        p.kind === "plan" ? (
          <span className="text-13 text-fg-2">Posted a plan: {Array.isArray(p.steps) ? p.steps.length : 0} steps</span>
        ) : p.kind === "step" ? (
          <span className="text-13 text-fg-2">
            Step {str(p.step)} → <span className="font-mono text-12">{str(p.state)}</span>
            {stepText && <span className="ml-2 text-fg-secondary">{stepText}</span>}
          </span>
        ) : p.kind === "thinking" ? (
          <details className="text-13">
            <summary className="cursor-pointer text-fg-secondary">Thinking</summary>
            <p className="mt-1 whitespace-pre-wrap border-l-2 border-border pl-3 leading-relaxed text-fg-secondary">{str(p.text)}</p>
          </details>
        ) : p.kind ? (
          <span className="font-mono text-12 text-fg-secondary">
            {str(p.kind)} {p.payload ? JSON.stringify(p.payload) : ""}
          </span>
        ) : (
          <p className="whitespace-pre-wrap text-14 leading-relaxed text-fg-2">{str(p.text)}</p>
        );
      break;
    }
    case "usage":
      body = (
        <span className="font-mono text-12 text-fg-secondary">
          turn total · {compact(Number(p.input_tokens ?? 0))} in · {compact(Number(p.output_tokens ?? 0))} out
          {(() => { const t = tokenBreakdown(eventTokenUsage(p)); return t.hasBreakdown ? ` · ${compact(t.cached)} cached · ${compact(t.uncached)} uncached${t.unknown ? ` · ${compact(t.unknown)} cache unknown` : ""}` : " · cache breakdown unavailable"; })()}
          {` · ${runCost(Number(p.cost_usd ?? 0), p.cost_source === "harness" || p.cost_source === "computed" ? String(p.cost_source) : p.cost_known === true || (p.cost_known === undefined && Number(p.cost_usd ?? 0) > 0) ? "harness" : "unknown")}`}
        </span>
      );
      break;
    case "error":
      body = <span className="whitespace-pre-wrap text-13 text-pill-blocked-fg">{str(p.message)}</span>;
      break;
    case "tool_result":
      body = <span className="font-mono text-12 text-fg-tertiary">result for {toolName(str(p.tool))}</span>;
      break;
    default:
      body = <span className="text-13 text-fg-2">{lifecycleText(p)}</span>;
  }
  return (
    <li
      id={source ? undefined : `event-${e.seq}`}
      className={cx(
        "grid grid-cols-[72px_76px_1fr] items-start gap-3 border-b border-border-subtle px-5 py-2.5 max-sm:grid-cols-[60px_1fr] max-sm:px-3",
        red && "shadow-[inset_2px_0_0_var(--state-blocked)]",
        amber && "shadow-[inset_2px_0_0_var(--state-human)]",
      )}
    >
      <time dateTime={e.at} title={absoluteTime(e.at)} className="pt-0.5 font-mono text-12 text-fg-tertiary">
        {clock.format(new Date(e.at))}
      </time>
      <span className="pt-0.5 font-mono text-12 text-fg-tertiary max-sm:hidden">{row.kind === "tool" ? "tool" : e.type}</span>
      <div className="min-w-0 max-sm:col-start-2">
        {source && <Link href={`/runs/${source.id}`} className="mb-1 block text-12 font-medium text-accent hover:underline">{source.agent.name} · delegated agent</Link>}
        {body}
      </div>
    </li>
  );
}

const TAB_FILTER: Record<string, (r: Row<RunEvent>) => boolean> = {
  all: () => true,
  messages: (r) => r.kind === "event" && r.e.type === "message" && !(r.e.payload as P).kind,
  tools: (r) => r.kind === "tool",
  errors: (r) => (r.kind === "event" && r.e.type === "error") || isFailedRow(r),
};

function rowText(r: Row<RunEvent>) {
  return JSON.stringify(r.kind === "tool" ? [r.call.payload, r.result?.payload] : r.e.payload).toLowerCase();
}

/** Turn markers become group headers, so their lifecycle rows are not repeated. */
const isTurnMarker = (r: Row<RunEvent>) => r.kind === "event" && r.e.type === "lifecycle" && ((r.e.payload as P).state === "turn_started" || (r.e.payload as P).state === "turn_ended");

function TurnGroup({ turn, t, items, open, onToggle, runId }: { turn: number; t?: Turn; items: ReactNode; open: boolean; onToggle: () => void; runId: string }) {
  const u = (t?.usage ?? {}) as P;
  const cost = runCost(Number(u.cost_usd ?? 0), typeof u.cost_source === "string" ? u.cost_source : undefined);
  const id = `turn-${turn}`;
  return (
    <section aria-label={turn === 0 ? "Setup" : `Turn ${turn}`} className="border-b border-border">
      <button
        type="button"
        aria-expanded={open}
        aria-controls={id}
        onClick={onToggle}
        className="flex w-full flex-wrap items-center gap-x-3 gap-y-0.5 bg-surface-sunken px-5 py-2 text-left hover:bg-hover max-sm:px-3"
      >
        <span aria-hidden className="w-3 flex-none text-fg-tertiary">{open ? "▾" : "▸"}</span>
        <span className="text-13 font-semibold">{turn === 0 ? "Setup" : `Turn ${turn}`}</span>
        {t && <span className="min-w-0 flex-1 truncate text-12 text-fg-secondary">{triggerLine(t.trigger, t.input_message, TRIGGER)}</span>}
        {t && (
          <span className="font-mono text-11 text-fg-tertiary">
            {t.status === "pending" ? "waiting for the runner" : t.status === "running" ? <span className="text-pill-done-fg">running</span> : (
              <>
                {clock.format(new Date(t.process_started_at ?? t.started_at)).slice(0, 5)}
                {t.process_started_at && ` · ${duration(t.process_started_at, t.ended_at ?? undefined)}`}
                {u.tool_calls != null && ` · ${str(u.tool_calls)} calls`}
                {` · ${compact(Number(u.input_tokens ?? 0))} in / ${compact(Number(u.output_tokens ?? 0))} out · ${cost}`}
                {t.exit_code != null ? ` · exit ${t.exit_code}` : ""}
              </>
            )}
          </span>
        )}
      </button>
      {open && (
        <div id={id}>
          <ol>{items}</ol>
          {t && (t.has_log || t.status === "done") && (
            <p className="flex items-center justify-between gap-3 px-5 py-2 font-mono text-11 text-fg-tertiary max-sm:px-3">
              <span>Turn {turn} total · {compact(Number(u.input_tokens ?? 0))} in · {compact(Number(u.output_tokens ?? 0))} out · {cost}</span>
              {t.has_log && <a href={`/api/v1/runs/${runId}/turns/${t.seq}/log`} className="text-accent hover:underline" aria-label={`Raw log of turn ${t.seq}`}>raw log</a>}
            </p>
          )}
        </div>
      )}
    </section>
  );
}

function Header({ d }: { d: RunDetail }) {
  const run = d.run;
  const href = workHref(run);
  return (
    <>
      <div className="flex flex-wrap items-center gap-x-8 gap-y-3 border-b border-border-subtle px-6 py-3.5">
        <div className="flex items-center gap-3">
          <AgentAvatar name={run.agent.name} colorIndex={run.agent.color_index} size="md" label={false} />
          <div className="flex flex-col leading-tight">
            <span className="flex flex-wrap items-center gap-2 font-semibold">
              {run.agent.name}
              <StatusPill run={run} />
              <MonoChip variant="outline">{PURPOSE_LABEL[run.purpose]}</MonoChip>
              <RunCostChip run={run} />
            </span>
            <span className="text-12 text-fg-tertiary">
              {run.purpose === "ticket" && run.ticket_key ? (
                <Link href={`/tickets/${encodeURIComponent(run.ticket_key)}`} className="text-accent hover:underline"><span className="font-mono">{run.ticket_key}</span> {run.work_title} ↗</Link>
              ) : href ? (
                <Link href={href} className="text-accent hover:underline">{run.purpose === "planning" ? "Plan" : "Chat"}: {run.work_title || "untitled"} ↗</Link>
              ) : null}
              {href && " · "}
              {run.mode} · started {absoluteTime(run.started_at)}
              {run.dispatched_by && ` · dispatched by ${run.dispatched_by.name}`}
              {run.parent_run_id && <> · <Link href={`/runs/${run.parent_run_id}`} className="text-accent hover:underline">Delegated by ↗</Link></>}
            </span>
          </div>
        </div>
        <Stat label="Harness" value={run.harness} />
        <Stat label="Model" value={run.model} />
        <Stat label="Elapsed" value={duration(run.started_at, run.ended_at)} />
        <Stat label="Cost" value={<CostValue d={d} />} />
        <Stat label="Tokens" value={compact(run.input_tokens + run.output_tokens)} />
        <Stat label="Tool calls" value={run.tool_calls} />
        {run.purpose === "ticket" && (
          <>
            <Stat label="Branch" value={run.branch ? <span className="font-mono text-12">{run.branch}</span> : "–"} />
            <Stat
              label="Pull request"
              value={run.pr_url && run.pr_number ? <a href={run.pr_url} target="_blank" rel="noreferrer" className="text-accent hover:underline">#{run.pr_number} ↗</a> : "–"}
            />
          </>
        )}
      </div>
      <TokenUsage usage={run} />
    </>
  );
}

export function RunLogScreen({ id }: { id: string }) {
  const { data: d, isError, error } = useRunLog(id);
  useRecordVisit(d ? { id: `run-${id}`, title: runTitle(d.run), meta: [d.run.ticket_key, d.run.agent.name].filter(Boolean).join(" · "), href: `/runs/${id}`, kind: "Runs" } : undefined);
  const children = useDelegatedRunLogs(d?.child_runs ?? []);
  const router = useRouter();
  const control = useControlRunById(id);
  const [tab, setTab] = useState("all");
  const [filter, setFilter] = useState("");
  const params = useSearchParams();
  // The hash (a deep link to a turn or event) is read once on load; ?view= is
  // read on every render, so the URL stays the truth. The thread is the default:
  // the Raw log (details), Graph and Files open from the companion's Context tab.
  const [nav, setNav] = useState(() => ({ hash: typeof window === "undefined" ? "" : window.location.hash }));
  const mode = pickRunView(params.get("view"), nav.hash, null);
  const anchor = mode === "details" ? parseRunAnchor(nav.hash) : null;
  const [follow, setFollow] = useState(() => !anchor);
  const detailsScroll = useRef<number | null>(null);
  const [allOpen, setAllOpen] = useState(false);
  const [turnOpen, setTurnOpen] = useState<Record<number, boolean>>({});
  const [toolOpen, setToolOpen] = useState<Record<string, boolean>>({});
  const scroller = useRef<HTMLDivElement>(null);
  const compactView = useCompact();

  const parentTurn = turnByEvent(d?.events ?? []);
  const starts = turnStarts(d?.events ?? []);
  // Pair tools within each run before merging: sequence numbers and tool IDs
  // are scoped to their own run and can collide across delegated agents.
  const entries: Entry[] = [
    ...rowsOf<RunEvent>(d?.events ?? []).map((row) => ({ row, source: undefined as Run | undefined, runId: id, turn: parentTurn.get(rowEvent(row).seq) ?? 0 })),
    ...children.flatMap((child) => child.data ? rowsOf<RunEvent>(child.data.events).map((row) => ({ row, source: child.data!.run as Run | undefined, runId: child.data!.run.id, turn: turnAt(starts, rowEvent(row).at) })) : []),
  ].sort((a, b) => {
    const ae = rowEvent(a.row);
    const be = rowEvent(b.row);
    return Date.parse(ae.at) - Date.parse(be.at) || a.runId.localeCompare(b.runId) || ae.seq - be.seq;
  });
  const visible = entries.filter(({ row }) => !isTurnMarker(row));
  const rows = visible.map(({ row }) => row);
  const counts = Object.fromEntries(Object.entries(TAB_FILTER).map(([k, f]) => [k, rows.filter(f).length]));
  const shown = visible.filter(({ row, source }) => TAB_FILTER[tab](row) &&
    (!filter || `${source?.agent.name ?? ""} ${rowText(row)}`.toLowerCase().includes(filter.toLowerCase())));
  const groups = groupByTurn(shown, (e) => e.turn);
  const lastTurn = Math.max(0, ...(d?.turns.map((t) => t.seq) ?? []), ...groups.map((g) => g.turn));
  // A deep link opens its turn and collapses the others.
  const focusTurn = anchor ? (anchor.kind === "turn" ? anchor.n : parentTurn.get(anchor.n)) : undefined;

  const loaded = !!d;
  useEffect(() => {
    const el = scroller.current;
    if (follow && el) el.scrollTop = el.scrollHeight;
  }, [follow, shown.length, tab, filter, loaded, mode]);
  // Coming back to Details puts the timeline where it was.
  useLayoutEffect(() => {
    const el = scroller.current;
    if (mode === "details" && el && !follow && !anchor && detailsScroll.current != null) el.scrollTop = detailsScroll.current;
    // Only on a mode switch: follow and anchor changes are handled elsewhere.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, loaded]);
  useEffect(() => {
    if (!anchor || !loaded) return;
    const el = document.getElementById(`${anchor.kind}-${anchor.n}`);
    (anchor.kind === "turn" ? el?.closest("section") : el)?.scrollIntoView({ block: "start" });
  }, [anchor?.kind, anchor?.n, loaded]); // eslint-disable-line react-hooks/exhaustive-deps

  /** Sets ?view= (no history entry); the thread drops it. */
  const switchMode = (m: RunViewMode, hash = "") => {
    setNav({ hash });
    const q = new URLSearchParams(params.toString());
    if (m === "simple") q.delete("view");
    else q.set("view", m);
    router.replace(`/runs/${id}${q.size ? `?${q}` : ""}${hash}`, { scroll: false });
  };
  /** From the thread: open turn n in the raw log, scrolled into view, the others collapsed. */
  const openTurn = (n: number) => {
    setFollow(false);
    setAllOpen(false);
    setTurnOpen({});
    switchMode("details", `#turn-${n}`);
  };
  /** From Graph: open an event (an error) in Details. */
  const openEvent = (seq: number) => {
    setFollow(false);
    setAllOpen(false);
    setTurnOpen({});
    switchMode("details", `#event-${seq}`);
  };

  if (isError) {
    return (
      <>
        <TopBar crumbs={[{ label: "Runs", href: "/runs" }, { label: "Not found" }]} />
        <div className="p-6">
          <Banner tone="blocked" title="Couldn't load this run">
            {error.message}
          </Banner>
        </div>
      </>
    );
  }
  if (!d) {
    return (
      <>
        <TopBar crumbs={[{ label: "Run" }]} />
        <div aria-busy="true" className="flex flex-col gap-3 p-6">
          <Skeleton className="h-10 w-full" />
          <Skeleton className="h-3 w-2/3" />
          <Skeleton className="h-3 w-1/2" />
        </div>
      </>
    );
  }
  const run = d.run;
  const live = !RUN_ENDED.includes(run.state);
  const crumbs: Crumb[] = [
    ...(run.project_key ? [{ label: run.project_key, href: `/tickets?project=${encodeURIComponent(run.project_key)}`, mono: true }] : []),
    ...(run.purpose === "ticket" && run.ticket_key
      ? [{ label: run.ticket_key, href: `/tickets/${encodeURIComponent(run.ticket_key)}`, mono: true }]
      : run.purpose === "planning"
        ? [{ label: "Plans", href: workHref(run) ?? "/plans" }]
        : [{ label: "Chat", href: workHref(run) ?? "/chat" }]),
    { label: `Run ${run.id.slice(0, 8)}` },
  ];
  const tools = {
    open: (key: string) => toolOpen[key] ?? allOpen,
    toggle: (key: string) => setToolOpen((o) => ({ ...o, [key]: !(o[key] ?? allOpen) })),
  };
  const isOpen = (n: number) => turnOpen[n] ?? (allOpen || n === (focusTurn ?? lastTurn));
  const grandchildren = children.map((c) => c.data?.child_runs as Run[] | undefined);
  const childDetails = children.map((c) => c.data);
  const logBody = (
    groups.length ? (
      <div aria-live={follow ? "polite" : "off"}>
        {groups.map((g) => (
          <TurnGroup
            key={g.turn}
            turn={g.turn}
            t={d.turns.find((t) => t.seq === g.turn)}
            runId={run.id}
            open={isOpen(g.turn)}
            onToggle={() => setTurnOpen((o) => ({ ...o, [g.turn]: !isOpen(g.turn) }))}
            items={g.items.map((entry) => (
              <EventRow key={`${entry.runId}:${rowEvent(entry.row).seq}`} entry={entry} plan={run.plan} tools={tools} runs={d.child_runs} calls={d.events} />
            ))}
          />
        ))}
      </div>
    ) : (
      <EmptyState icon="terminal" title={rows.length ? "No events match" : "No events yet"}>
        {rows.length ? "Try another tab or filter." : run.state === "queued" ? "The run starts when a runner slot is free." : "Events appear as the harness works."}
      </EmptyState>
    )
  );
  const onLogScroll = (el: HTMLDivElement) => {
    detailsScroll.current = el.scrollTop;
    setFollow(el.scrollHeight - el.scrollTop - el.clientHeight < 24);
  };
  if (compactView) return <CompactRunDetail d={d} log={logBody} scroller={scroller} onScroll={onLogScroll} control={control} />;
  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <TopBar
        crumbs={crumbs}
        nativeActions={[
          ...(mode !== "simple" ? [{ id: "run.thread", label: "Back to thread", kind: "button" as const, icon: "chev", showsLabel: true, run: () => switchMode("simple") }] : []),
          ...(live && run.mode === "managed"
            ? [run.state === "paused"
              ? { id: "run.resume", label: "Resume", kind: "button" as const, icon: "play", showsLabel: true, disabled: control.isPending, run: () => control.mutate("resume") }
              : { id: "run.pause", label: "Pause", kind: "button" as const, icon: "pause", showsLabel: true, disabled: control.isPending || run.state === "queued", run: () => control.mutate("pause") }]
            : []),
          ...((run.state === "failed" || run.state === "cancelled") && run.ticket_key && !run.parent_run_id
            ? [{ id: "run.retry", label: "Retry run", kind: "button" as const, icon: "refresh", showsLabel: true, accent: true, disabled: control.isPending, run: () => control.mutate("retry", { onSuccess: (r) => router.push(`/runs/${r.id}`) }) }]
            : []),
          ...(live
            ? [{ id: "run.cancel", label: "Cancel run", kind: "button" as const, icon: "x", showsLabel: true, disabled: control.isPending, run: async () => { if (await confirmCancel(run.agent.name)) control.mutate("cancel"); } }]
            : []),
        ]}
        actions={
          <>
            {mode !== "simple" && <Button variant="ghost" icon="chev" className="[&_svg]:rotate-90" onClick={() => switchMode("simple")}>Back to thread</Button>}
            {live && run.mode === "managed" && (
              run.state === "paused" ? (
                <Button variant="outline" icon="play" disabled={control.isPending} onClick={() => control.mutate("resume")}>
                  Resume
                </Button>
              ) : (
                <Button variant="outline" icon="pause" disabled={control.isPending || run.state === "queued"} onClick={() => control.mutate("pause")}>
                  Pause
                </Button>
              )
            )}
            {(run.state === "failed" || run.state === "cancelled") && run.ticket_key && !run.parent_run_id && (
              <Button
                variant="approve"
                icon="refresh"
                disabled={control.isPending}
                onClick={() => control.mutate("retry", { onSuccess: (r) => router.push(`/runs/${r.id}`) })}
              >
                Retry run
              </Button>
            )}
            {live && (
              <Button variant="outline" icon="x" className="text-pill-blocked-fg" disabled={control.isPending} onClick={async () => { if (await confirmCancel(run.agent.name)) control.mutate("cancel"); }}>
                Cancel run
              </Button>
            )}
          </>
        }
      />
      {control.isError && (
        <div className="px-6 pt-3">
          <Banner tone="blocked" title={control.variables === "retry" ? "Couldn't retry the run" : "Couldn't change the run"}>
            {control.error.message}
          </Banner>
        </div>
      )}
      <div className="flex min-h-0 flex-1">
      <div className="flex min-h-0 min-w-0 flex-1 flex-col">
      {mode === "details" && <Header d={d} />}
      {mode !== "simple" && <ActionBox d={d} />}
      {mode === "simple" ? (
        <RunThread d={d} onOpenTurn={openTurn} />
      ) : mode === "graph" ? (
        <RunGraphView d={d} childDetails={childDetails} onOpenTurn={openTurn} onOpenEvent={openEvent} />
      ) : mode === "files" ? (
        <RunFiles d={d} childDetails={childDetails} />
      ) : (
      <div className="flex min-h-0 flex-1 flex-col xl:flex-row">
        <section aria-label="Events" className="flex min-h-0 min-w-0 flex-1 flex-col">
          <div className="flex flex-wrap items-center gap-3 border-b border-border-subtle px-5 py-2.5">
            <Tabs
              label="Event types"
              value={tab}
              onChange={setTab}
              items={[
                { key: "all", label: "All", count: counts.all },
                { key: "messages", label: "Messages", count: counts.messages },
                { key: "tools", label: "Tool calls", count: counts.tools },
                { key: "errors", label: "Errors", count: counts.errors },
              ]}
            />
            <TextInput aria-label="Filter events" placeholder="Filter events" value={filter} onChange={(e) => setFilter(e.target.value)} className="ml-auto w-56 max-sm:w-full" />
            <Button
              variant="outline"
              onClick={() => {
                setTurnOpen({});
                setToolOpen({});
                setAllOpen(!allOpen);
              }}
            >
              {allOpen ? "Collapse all" : "Expand all"}
            </Button>
            <Toggle checked={follow} onChange={setFollow} label="Follow" />
          </div>
          {run.outcome && !live && (
            <div className="px-5 pt-3">
              <p className="whitespace-pre-line rounded-lg border border-border bg-surface px-3.5 py-2.5 text-13 text-fg-2">{run.outcome}</p>
            </div>
          )}
          {children.some((child) => child.isError) && (
            <div className="px-5 pt-3"><Banner tone="blocked" title="Couldn't load delegated agent logs">Some delegated activity is unavailable. Open the delegated run or try again.</Banner></div>
          )}
          {children.some((child) => child.isPending) && <p role="status" className="px-5 py-2 text-12 text-fg-secondary">Loading delegated agent logs…</p>}
          <div
            ref={scroller}
            role="log"
            aria-label="Run log"
            tabIndex={0}
            onScroll={(e) => onLogScroll(e.currentTarget)}
            className="min-h-0 flex-1 overflow-y-auto max-xl:max-h-[70dvh]"
          >
          {logBody}
          <p className="px-5 py-4 text-12 text-fg-tertiary">
            Normalized events. The raw harness stream of each turn is kept with the run ({run.mode === "managed" ? "raw links on each turn" : "unmanaged sessions have none"}).
          </p>
          </div>
        </section>
        <RunRail d={d} grandchildren={grandchildren} />
      </div>
      )}
      </div>
      {/* The run's companion: Context and Chat, in the shell's right-hand column. */}
      <RunContext d={d} mode={mode} setMode={(m) => switchMode(m)} />
      </div>
      {mode === "details" && !follow && (
        <Button
          variant="secondary"
          className="fixed bottom-6 right-6 z-20 shadow-md"
          onClick={() => {
            const el = scroller.current;
            if (el) el.scrollTop = el.scrollHeight;
            setFollow(true);
          }}
        >
          <span aria-hidden="true">↓</span> Jump to latest
        </Button>
      )}
    </div>
  );
}
