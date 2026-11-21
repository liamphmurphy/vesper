"use client";

import { useRecordVisit } from "@/components/shell/use-record-visit";
import { runTitle, touchedFiles } from "@/lib/run-list";
import { eventTokenUsage, tokenBreakdown } from "@/lib/token-usage";
import { runCost } from "@/lib/format";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useLayoutEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { useControlRunById, useDelegatedRunLogs, useRunLog } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { absoluteTime, compact, duration } from "@/lib/format";
import {
  argSummary, delegateChild, groupByTurn, isFailedRow, parseRunAnchor, pickRunView, rowEvent, rowsOf, runViewTabs, str,
  toolLink, toolName, triggerLine, turnAt, turnByEvent, turnStarts, workHref, type Row, type RunViewMode,
} from "@/lib/run-view";
import type { NativeAction } from "@/lib/native-shell/actions";
import { useNativeActions } from "@/lib/native-shell/use-native-actions";
import { useNativeTitle } from "../../tickets/_components/native-title";
import { Button } from "@/components/ui/button";
import { Tabs, Toggle } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, Skeleton, TextInput } from "@/components/ui/primitives";
import { WorkPersonaAvatar } from "@/components/domain/work-persona-avatar";
import { runCharacterState } from "@/lib/work-persona";
import { Flag, SmallPill } from "@/components/domain/labels";
import { Markdown } from "@/components/domain/markdown";
import { RUN_ENDED, RUN_STATE as STATE, StatusPill } from "@/components/domain/run-status";
import { WORK_COLUMN, WorkDetailHeader, WorkEyebrow, WorkViewTabs, type EyebrowItem } from "@/components/domain/work-detail-header";
import { ActionBox, confirmCancel } from "./run-panels";
import { CostValue, RunThread } from "./run-thread";
import { RunContext } from "./run-context";
import { RunFiles } from "./run-files";
import { RunGraphView } from "./run-graph-view";
import { CompactRunDetail } from "./run-compact";
import { useCompact } from "@/lib/viewport";

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
const shortClock = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", hour12: false });

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
    case "checkpoint_deleted":
      return <>Removed checkpoint <code className="inline">{str(p.branch)}</code> after PR shipped</>;
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

/** A Vesper-native collapsible tool step card: tool pill, arg summary, status & duration; click for output. */
function ToolRow({ row, open, onToggle, runs, calls, at }: {
  row: Extract<Row<RunEvent>, { kind: "tool" }>;
  open: boolean;
  onToggle: () => void;
  runs: Run[];
  calls: RunEvent[];
  at: string;
}) {
  const { call, result } = row;
  const p = call.payload as P;
  const r = (result?.payload ?? {}) as P;
  const denied = p.denied_by_harness === true;
  const failed = r.is_error === true;
  const out = str(r.output);
  const link = toolLink(str(p.tool), p.input);
  const child = delegateChild(call, runs, calls);
  const took = result ? Math.max(0, Date.parse(result.at) - Date.parse(call.at)) : null;
  const name = toolName(str(p.tool));
  return (
    <div className={cx("min-w-0 overflow-hidden rounded-lg border bg-surface", denied || failed ? "border-pill-blocked-bg" : open ? "border-border-strong" : "border-border-subtle")}>
      <div className="flex items-center gap-2 px-3 py-2">
        <button type="button" aria-expanded={open} onClick={onToggle} className="flex min-w-0 flex-1 items-center gap-2 text-left">
          <span aria-hidden className="w-3 flex-none text-11 text-fg-tertiary">{open ? "▾" : "▸"}</span>
          <span className={cx(
            "flex-none rounded px-1.5 py-[1px] font-mono text-11 font-medium",
            denied || failed ? "bg-pill-blocked-bg text-pill-blocked-fg" : open ? "bg-accent-soft text-accent" : "bg-surface-sunken text-fg-2",
          )}>
            {name}
          </span>
          <span className="min-w-0 flex-1 truncate font-mono text-12 text-fg-secondary">{argSummary(p.input)}</span>
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
        <time dateTime={at} title={absoluteTime(at)} className="flex-none font-mono text-11 text-fg-tertiary max-sm:hidden">
          {shortClock.format(new Date(at))}
        </time>
      </div>
      {open && (
        out ? (
          <pre className="max-h-72 overflow-auto border-t border-border-subtle bg-surface-sunken px-3.5 py-2.5 font-mono text-12 leading-relaxed text-fg-secondary">{out}</pre>
        ) : (
          <p className="border-t border-border-subtle bg-surface-sunken px-3.5 py-2 text-12 text-fg-tertiary">{result ? "No output." : "No result yet."}</p>
        )
      )}
    </div>
  );
}

function EventRow({ entry, run, plan, tools, runs, calls }: {
  entry: Entry;
  run: Run;
  plan: Run["plan"];
  tools: { open: (key: string) => boolean; toggle: (key: string) => void };
  runs: Run[];
  calls: RunEvent[];
}) {
  const { row, source } = entry;
  const e = rowEvent(row);
  const p = e.payload as P;
  const red = e.type === "error" || isFailedRow(row);
  const amber = e.type === "lifecycle" && (p.state === "waiting" || p.state === "paused");
  const key = `${entry.runId}:${e.seq}`;
  const delegatedBanner = source ? (
    <Link href={`/runs/${source.id}`} className="mb-1 inline-block text-11 font-medium text-accent hover:underline">
      {source.agent.name} · delegated agent
    </Link>
  ) : null;

  if (row.kind === "tool") {
    return (
      <li id={source ? undefined : `event-${e.seq}`}>
        {delegatedBanner}
        <ToolRow row={row} open={tools.open(key)} onToggle={() => tools.toggle(key)} runs={runs} calls={calls} at={e.at} />
      </li>
    );
  }

  if (e.type === "message" && !p.kind) {
    const author = source?.agent.name ?? run.agent.name;
    return (
      <li id={source ? undefined : `event-${e.seq}`}>
        {delegatedBanner}
        <div className="rounded-lg border border-border-subtle border-l-2 border-l-accent/60 bg-surface px-3.5 py-2.5">
          <div className="mb-1 flex items-baseline justify-between gap-2 text-12">
            <span className="font-medium text-fg">{author}</span>
            <time dateTime={e.at} title={absoluteTime(e.at)} className="font-mono text-11 text-fg-tertiary">
              {clock.format(new Date(e.at))}
            </time>
          </div>
          <div className="text-13 leading-relaxed text-fg-2">
            <Markdown>{str(p.text)}</Markdown>
          </div>
        </div>
      </li>
    );
  }

  if (e.type === "usage") {
    const t = tokenBreakdown(eventTokenUsage(p));
    const costText = runCost(
      Number(p.cost_usd ?? 0),
      p.cost_source === "harness" || p.cost_source === "computed"
        ? String(p.cost_source)
        : p.cost_known === true || (p.cost_known === undefined && Number(p.cost_usd ?? 0) > 0)
          ? "harness"
          : "unknown",
    );
    return (
      <li id={source ? undefined : `event-${e.seq}`} className="flex flex-wrap items-baseline justify-between gap-2 px-1 py-1 font-mono text-11 text-fg-tertiary">
        <span>
          turn total · {compact(Number(p.input_tokens ?? 0))} in · {compact(Number(p.output_tokens ?? 0))} out
          {t.hasBreakdown ? ` · ${compact(t.cached)} cached · ${compact(t.uncached)} uncached${t.unknown ? ` · ${compact(t.unknown)} cache unknown` : ""}` : " · cache breakdown unavailable"}
          {` · ${costText}`}
        </span>
        <time dateTime={e.at} title={absoluteTime(e.at)}>{clock.format(new Date(e.at))}</time>
      </li>
    );
  }

  let body: ReactNode;
  if (e.type === "message") {
    const stepText = p.kind === "step" ? (plan.find((s) => s.position === Number(p.step)) ?? plan[Number(p.step) - 1])?.text : undefined;
    body =
      p.kind === "plan" ? (
        <span className="text-12 text-fg-2">Posted a plan: {Array.isArray(p.steps) ? p.steps.length : 0} steps</span>
      ) : p.kind === "step" ? (
        <span className="text-12 text-fg-2">
          Step {str(p.step)} → <span className="font-mono text-11">{str(p.state)}</span>
          {stepText && <span className="ml-2 text-fg-secondary">{stepText}</span>}
        </span>
      ) : p.kind === "thinking" ? (
        <details className="text-12">
          <summary className="cursor-pointer text-fg-secondary">Thinking</summary>
          <p className="mt-1.5 whitespace-pre-wrap border-l-2 border-border pl-3 leading-relaxed text-fg-secondary">{str(p.text)}</p>
        </details>
      ) : (
        <span className="font-mono text-11 text-fg-secondary">
          {str(p.kind)} {p.payload ? JSON.stringify(p.payload) : ""}
        </span>
      );
  } else if (e.type === "error") {
    body = <span className="whitespace-pre-wrap text-13 text-pill-blocked-fg">{str(p.message)}</span>;
  } else if (e.type === "tool_result") {
    body = <span className="font-mono text-11 text-fg-tertiary">result for {toolName(str(p.tool))}</span>;
  } else {
    body = <span className="text-12 text-fg-secondary">{lifecycleText(p)}</span>;
  }

  return (
    <li
      id={source ? undefined : `event-${e.seq}`}
      className={cx(
        "flex items-start justify-between gap-3 rounded-md px-2.5 py-1.5",
        red && "border border-pill-blocked-bg bg-pill-blocked-bg/30",
        amber && "border border-state-human/40 bg-pill-human-bg/30",
      )}
    >
      <div className="min-w-0 flex-1">
        {delegatedBanner}
        {body}
      </div>
      <time dateTime={e.at} title={absoluteTime(e.at)} className="flex-none pt-0.5 font-mono text-11 text-fg-tertiary">
        {clock.format(new Date(e.at))}
      </time>
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

/** Turn markers become group headers and activity heartbeats drive the live card, so neither clutters the log. */
const isTurnMarker = (r: Row<RunEvent>) => {
  if (r.kind !== "event" || r.e.type !== "lifecycle") return false;
  const state = (r.e.payload as P).state;
  return state === "turn_started" || state === "turn_ended" || state === "activity";
};

function TurnGroup({ turn, t, items, open, onToggle, runId }: { turn: number; t?: Turn; items: ReactNode; open: boolean; onToggle: () => void; runId: string }) {
  const u = (t?.usage ?? {}) as P;
  const cost = runCost(Number(u.cost_usd ?? 0), typeof u.cost_source === "string" ? u.cost_source : undefined);
  const id = `turn-${turn}`;
  return (
    <section aria-label={turn === 0 ? "Setup" : `Turn ${turn}`} className="mb-3 overflow-hidden rounded-xl border border-border bg-surface/35">
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 bg-surface-sunken/70 px-4 py-2">
        <button
          type="button"
          aria-expanded={open}
          aria-controls={id}
          onClick={onToggle}
          className="flex min-w-0 flex-1 flex-wrap items-center gap-x-2.5 gap-y-0.5 text-left"
        >
          <span aria-hidden className="w-3 flex-none text-11 text-fg-tertiary">{open ? "▾" : "▸"}</span>
          <span className="text-12 font-semibold text-fg">{turn === 0 ? "Setup" : `Turn ${turn}`}</span>
          {t && <span className="min-w-0 flex-1 truncate text-12 text-fg-secondary">{triggerLine(t.trigger, t.input_message, TRIGGER)}</span>}
        </button>
        {t && (
          <span className="flex flex-none items-center gap-2 font-mono text-11 text-fg-tertiary">
            {t.status === "pending" ? "waiting for the runner" : t.status === "running" ? <span className="text-pill-done-fg">running</span> : (
              <>
                {clock.format(new Date(t.process_started_at ?? t.started_at)).slice(0, 5)}
                {t.process_started_at && ` · ${duration(t.process_started_at, t.ended_at ?? undefined)}`}
                {u.tool_calls != null && ` · ${str(u.tool_calls)} calls`}
                {` · ${cost}`}
                {t.exit_code != null && t.exit_code !== 0 ? ` · exit ${t.exit_code}` : ""}
              </>
            )}
            {t.has_log && (
              <a href={`/api/v1/runs/${runId}/turns/${t.seq}/log`} className="text-accent hover:underline" aria-label={`Raw log of turn ${t.seq}`}>
                raw ↗
              </a>
            )}
          </span>
        )}
      </div>
      {open && (
        <div id={id} className="border-t border-border-subtle">
          <ol className="flex flex-col gap-2 p-3">{items}</ol>
          {t && (t.has_log || t.status === "done") && (
            <p className="flex items-center justify-between gap-3 border-t border-border-subtle px-4 py-2 font-mono text-11 text-fg-tertiary">
              <span>Turn {turn} total · {compact(Number(u.input_tokens ?? 0))} in · {compact(Number(u.output_tokens ?? 0))} out · {cost}</span>
              {t.has_log && <a href={`/api/v1/runs/${runId}/turns/${t.seq}/log`} className="text-accent hover:underline">raw log ↗</a>}
            </p>
          )}
        </div>
      )}
    </section>
  );
}

export function RunLogScreen({ id, inWork = false }: { id: string; inWork?: boolean }) {
  const { data: d, isError, error } = useRunLog(id);
  useRecordVisit(d ? { id: `run-${id}`, title: runTitle(d.run), meta: [d.run.ticket_key, d.run.agent.name].filter(Boolean).join(" · "), href: `/runs/${id}`, kind: "Runs" } : undefined);
  const children = useDelegatedRunLogs(d?.child_runs ?? []);
  const router = useRouter();
  const control = useControlRunById(id);
  const [tab, setTab] = useState("all");
  const [filter, setFilter] = useState("");
  const params = useSearchParams();
  // The hash (a deep link to a turn or event) is read once on load; ?view= is
  // read on every render, so the URL stays the truth.
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

  const run = d?.run;
  const live = run ? !RUN_ENDED.includes(run.state) : false;

  useNativeTitle(
    run ? runTitle(run) : "Run",
    run ? [run.project_key, run.ticket_key].filter(Boolean).join(" · ") || undefined : undefined,
  );
  const nativeActions: NativeAction[] | undefined = run
    ? [
        ...(live && run.mode === "managed"
          ? [run.state === "paused"
            ? { id: "run.resume", label: "Resume", kind: "button" as const, icon: "play", showsLabel: true, disabled: control.isPending, run: () => control.mutate("resume") }
            : { id: "run.pause", label: "Pause", kind: "button" as const, icon: "pause", showsLabel: true, disabled: control.isPending || run.state === "queued", run: () => control.mutate("pause") }]
          : []),
        ...((run.state === "failed" || run.state === "cancelled") && run.ticket_key && !run.parent_run_id
          ? [{
              id: "run.retry",
              label: "Retry run",
              kind: "button" as const,
              icon: "refresh",
              showsLabel: true,
              accent: true,
              disabled: control.isPending,
              run: () =>
                control.mutate("retry", {
                  onSuccess: (r) => {
                    if (inWork) {
                      const q = new URLSearchParams(params.toString());
                      q.set("run", r.id);
                      q.delete("view");
                      router.push(`/work?${q}`);
                    } else {
                      router.push(`/runs/${r.id}`);
                    }
                  },
                }),
            }]
          : []),
        ...(live
          ? [{ id: "run.cancel", label: "Cancel run", kind: "button" as const, icon: "x", showsLabel: true, disabled: control.isPending, run: async () => { if (await confirmCancel(run.agent.name)) control.mutate("cancel"); } }]
          : []),
      ]
    : undefined;
  useNativeActions(nativeActions);

  const parentTurn = turnByEvent(d?.events ?? []);
  const starts = turnStarts(d?.events ?? []);
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
  const focusTurn = anchor ? (anchor.kind === "turn" ? anchor.n : parentTurn.get(anchor.n)) : undefined;

  const fileCount = useMemo(
    () => (d ? touchedFiles([...d.events, ...children.flatMap((c) => c.data?.events ?? [])]).length : 0),
    [d, children],
  );

  const loaded = !!d;
  useEffect(() => {
    const el = scroller.current;
    if (follow && el) el.scrollTop = el.scrollHeight;
  }, [follow, shown.length, tab, filter, loaded, mode]);
  useLayoutEffect(() => {
    const el = scroller.current;
    if (mode === "details" && el && !follow && !anchor && detailsScroll.current != null) el.scrollTop = detailsScroll.current;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [mode, loaded]);
  useEffect(() => {
    if (!anchor || !loaded) return;
    const el = document.getElementById(`${anchor.kind}-${anchor.n}`);
    (anchor.kind === "turn" ? el?.closest("section") : el)?.scrollIntoView({ block: "start" });
  }, [anchor?.kind, anchor?.n, loaded]); // eslint-disable-line react-hooks/exhaustive-deps

  const switchMode = (m: RunViewMode, hash = "") => {
    setNav({ hash });
    const q = new URLSearchParams(params.toString());
    if (m === "simple") q.delete("view");
    else q.set("view", m);
    if (inWork) {
      q.set("run", id);
      router.replace(`/work${q.size ? `?${q}` : ""}${hash}`, { scroll: false });
    } else {
      router.replace(`/runs/${id}${q.size ? `?${q}` : ""}${hash}`, { scroll: false });
    }
  };
  const openTurn = (n: number) => {
    setFollow(false);
    setAllOpen(false);
    setTurnOpen({});
    switchMode("details", `#turn-${n}`);
  };
  const openEvent = (seq: number) => {
    setFollow(false);
    setAllOpen(false);
    setTurnOpen({});
    switchMode("details", `#event-${seq}`);
  };

  if (isError) {
    return (
      <div className="p-6">
        <Banner tone="blocked" title="Couldn't load this run">
          {error.message}
        </Banner>
      </div>
    );
  }
  if (!d || !run) {
    return (
      <div aria-busy="true" className={`${WORK_COLUMN} flex flex-col gap-3 py-8`}>
        <Skeleton className="h-6 w-2/3" />
        <Skeleton className="h-3 w-1/2" />
        <Skeleton className="h-32 w-full rounded-xl" />
      </div>
    );
  }

  const eyebrow: EyebrowItem[] = [
    ...(run.project_key ? [{ label: run.project_key, href: `/tickets?project=${encodeURIComponent(run.project_key)}`, mono: true }] : []),
    ...(run.purpose === "ticket" && run.ticket_key
      ? [{ label: `${run.ticket_key} ↗`, href: `/tickets/${encodeURIComponent(run.ticket_key)}`, mono: true, accent: true }]
      : workHref(run)
        ? [{ label: run.purpose === "planning" ? "Plan ↗" : "Chat ↗", href: workHref(run)!, accent: true }]
        : []),
    { label: `Run ${run.id.slice(0, 8)}`, mono: true },
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
              <EventRow
                key={`${entry.runId}:${rowEvent(entry.row).seq}`}
                entry={entry}
                run={run}
                plan={run.plan}
                tools={tools}
                runs={d.child_runs}
                calls={d.events}
              />
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
      {control.isError && (
        <div className={`${WORK_COLUMN} pt-3`}>
          <Banner tone="blocked" title={control.variables === "retry" ? "Couldn't retry the run" : "Couldn't change the run"}>
            {control.error.message}
          </Banner>
        </div>
      )}
      <div className="flex min-h-0 flex-1">
        <div className="flex min-h-0 min-w-0 flex-1 flex-col">
          {/* Unified document-first header + inline view tabs across Thread, Trace, Graph, and Files. */}
          <div className={`${WORK_COLUMN} flex-none pt-6 pb-2`}>
            <WorkDetailHeader
              eyebrow={<WorkEyebrow items={eyebrow} />}
              title={<h1 className="type-title text-fg">{runTitle(run)}</h1>}
              meta={
                <>
                  <span className="inline-flex items-center gap-1.5 font-medium text-fg">
                    <WorkPersonaAvatar agent={run.agent} size="sm" state={runCharacterState(run)} />
                    {run.agent.name}
                  </span>
                  <StatusPill run={run} />
                  <span aria-hidden className="text-fg-tertiary">·</span>
                  <span className="font-mono text-fg-2">{duration(run.started_at, run.ended_at)}</span>
                  <span aria-hidden className="text-fg-tertiary">·</span>
                  <span className="font-mono text-fg-2"><CostValue d={d} /></span>
                  {run.tool_calls > 0 && (
                    <>
                      <span aria-hidden className="text-fg-tertiary">·</span>
                      <span className="font-mono text-fg-tertiary">{run.tool_calls} step{run.tool_calls === 1 ? "" : "s"}</span>
                    </>
                  )}
                  <span aria-hidden className="text-fg-tertiary max-sm:hidden">·</span>
                  <span className="text-fg-tertiary max-sm:hidden">{absoluteTime(run.started_at)}</span>
                  {run.pr_url && run.pr_number && (
                    <>
                      <span aria-hidden className="text-fg-tertiary">·</span>
                      <a href={run.pr_url} target="_blank" rel="noreferrer" className="font-mono text-accent hover:underline">
                        PR #{run.pr_number} ↗
                      </a>
                    </>
                  )}
                  {run.parent_run_id && (
                    <>
                      <span aria-hidden className="text-fg-tertiary">·</span>
                      <Link href={`/runs/${run.parent_run_id}`} className="text-accent hover:underline">Delegated by ↗</Link>
                    </>
                  )}
                </>
              }
              tabs={
                <WorkViewTabs
                  label="Run views"
                  value={mode}
                  onChange={(k) => switchMode(k as RunViewMode)}
                  items={runViewTabs({
                    countsAll: counts.all,
                    fileCount,
                    childRunCount: Math.max(d.child_runs.length, run.child_count ?? 0),
                    mode,
                  })}
                  trailing={
                    <>
                      <span>{run.harness}</span>
                      <span aria-hidden>·</span>
                      <span>{run.model}</span>
                    </>
                  }
                />
              }
            />
          </div>

          {mode !== "simple" && (
            <div className={WORK_COLUMN}>
              <ActionBox d={d} inThread />
            </div>
          )}

          {mode === "simple" ? (
            <RunThread d={d} embeddedHeader onOpenTurn={openTurn} onOpenTrace={() => switchMode("details")} />
          ) : mode === "graph" ? (
            <RunGraphView d={d} childDetails={childDetails} onOpenTurn={openTurn} onOpenEvent={openEvent} />
          ) : mode === "files" ? (
            <RunFiles d={d} childDetails={childDetails} />
          ) : (
            <section aria-label="Events" className="flex min-h-0 min-w-0 flex-1 flex-col">
              <div className={`${WORK_COLUMN} flex flex-none flex-wrap items-center gap-2 py-2.5`}>
                <Tabs
                  label="Event types"
                  value={tab}
                  onChange={setTab}
                  items={[
                    { key: "all", label: "All", count: counts.all },
                    { key: "messages", label: "Messages", count: counts.messages },
                    { key: "tools", label: "Tools", count: counts.tools },
                    { key: "errors", label: "Errors", count: counts.errors },
                  ]}
                />
                <TextInput
                  aria-label="Filter events"
                  placeholder="Filter trace…"
                  value={filter}
                  onChange={(e) => setFilter(e.target.value)}
                  className="ml-auto w-36 max-sm:w-full"
                />
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
              <div
                ref={scroller}
                role="log"
                aria-label="Run log"
                tabIndex={0}
                onScroll={(e) => onLogScroll(e.currentTarget)}
                className="min-h-0 flex-1 overflow-y-auto outline-none"
              >
                <div className={`${WORK_COLUMN} flex flex-col gap-3 pb-6 pt-1`}>
                  {run.outcome && !live && (
                    <div className="rounded-xl border border-border bg-surface px-4 py-3 text-13 leading-relaxed text-fg-2">
                      <Markdown>{run.outcome}</Markdown>
                    </div>
                  )}
                  {children.some((child) => child.isError) && (
                    <Banner tone="blocked" title="Couldn't load delegated agent logs">
                      Some delegated activity is unavailable. Open the delegated run or try again.
                    </Banner>
                  )}
                  {children.some((child) => child.isPending) && (
                    <p role="status" className="text-12 text-fg-secondary">Loading delegated agent logs…</p>
                  )}
                  {logBody}
                  <p className="text-11 text-fg-tertiary">
                    Normalized events. The raw harness stream of each turn is kept with the run ({run.mode === "managed" ? "raw links on each turn" : "unmanaged sessions have none"}). Plan and usage live in the Context panel.
                  </p>
                </div>
              </div>
            </section>
          )}
        </div>
        {/* The run's companion: Context (Plan, Ticket, Code, Run facts, Usage/Cache) and Chat. */}
        <RunContext d={d} mode={mode} setMode={(m) => switchMode(m)} grandchildren={grandchildren} />
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
