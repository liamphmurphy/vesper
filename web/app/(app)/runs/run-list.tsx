"use client";

// The Runs list (LAZYAGENTS-163), styled like the chat history: Needs you (the
// sidebar tray's queue, non-run items included), Running, Queued, then
// finished runs by day. It sits beside the run thread on desktop and is the
// whole screen on compact, where a row pushes the run.

import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";
import type { Schemas } from "@/lib/api/client";
import { useBootstrap, useCosts, useInbox, useRunnerStatus, useRunPages } from "@/lib/api/hooks";
import { presetRange, spendLabel } from "@/lib/costs";
import { cx } from "@/lib/cx";
import { absoluteTime, ago } from "@/lib/format";
import { KIND, trayItems, waited } from "@/lib/inbox";
import { DOT_LABEL, groupRuns, itemHref, matchesItem, matchesRun, runDot, runLine, runTitle, type Dot } from "@/lib/run-list";
import {
  compactRunTime,
  computeActivityViewCounts,
  filterActivityRuns,
  groupActivitySidebarRuns,
  isRunNeedsYou,
  parseActivityFilter,
} from "@/lib/work-overview";
import { AgentAvatar } from "@/components/domain/avatars";
import { AgentOrPersonaAvatar } from "../tickets/_components/ticket-row";
import { FilterMenu } from "@/components/domain/pickers";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Kbd, Skeleton, TextInput } from "@/components/ui/primitives";
import { useProjectScope } from "@/components/shell/project-scope";
import { shortcutBlocked } from "@/components/shell/shortcuts";
import { WorkSectionLabel, WorkSidebarFilterRow } from "../work/work-nav-header";

type Run = Schemas["Run"];
type Item = Schemas["InboxItem"];

/** The list's filters live in the URL, so a selected run keeps them: ?project=, ?agent=, ?done=hide, ?filter=. */
const LIST_PARAMS = ["project", "agent", "done", "filter"] as const;

/** The query string the list's filters make, for links between runs. */
export function listQuery(params: URLSearchParams): string {
  const q = new URLSearchParams();
  for (const k of LIST_PARAMS) if (params.has(k)) q.set(k, params.get(k) ?? "");
  return q.toString();
}

/**
 * The list's data, shared by the list and /runs (which opens its first row).
 * React Query dedupes the requests, so both call it.
 */
export function useRunList(search = "") {
  const params = useSearchParams();
  const scope = useProjectScope("optional");
  // A bare /runs starts in the shell's project; an explicit ?project= (or "All spaces") wins.
  const scoped = scope.status === "ready" ? scope.project?.key : undefined;
  const project = params.has("project") ? params.get("project") || undefined : scoped;
  const agent = params.get("agent") || undefined;
  const hideDone = params.get("done") === "hide";
  const key = `${project}|${agent}`;
  const [loaded, setLoaded] = useState({ key, pages: 1 });
  const pages = loaded.key === key ? loaded.pages : 1;
  const [live] = useRunPages({ state: "live", project, agent }, 1);
  const recent = useRunPages({ state: "all", project, agent }, hideDone ? 0 : pages);
  const inbox = useInbox();
  const [now] = useState(() => new Date());

  const needs = useMemo(
    () => trayItems(inbox.data ?? []).needs.filter((i) => (!project || i.project === project) && (!agent || i.agent?.handle === agent)),
    [inbox.data, project, agent],
  );
  const shownNeeds = useMemo(() => needs.filter((i) => matchesItem(i, search)), [needs, search]);
  // Only runs whose Needs you row is shown leave the groups, so a search never hides a run from both.
  const needsRuns = useMemo(() => new Set(shownNeeds.flatMap((i) => (i.run_id ? [i.run_id] : []))), [shownNeeds]);
  const runs = useMemo(
    () => [...(live.data?.runs ?? []), ...recent.flatMap((r) => r.data?.runs ?? [])],
    [live.data, recent],
  );
  const groups = useMemo(() => groupRuns(runs.filter((r) => matchesRun(r, search)), needsRuns, now), [runs, search, needsRuns, now]);
  const last = recent.at(-1);
  return {
    project,
    agent,
    hideDone,
    needs,
    shownNeeds,
    groups,
    runs,
    loading: live.isPending || scope.status === "loading" || (!hideDone && recent[0]?.isPending),
    error: live.error ?? recent[0]?.error ?? null,
    retry: () => {
      void live.refetch();
      void recent[0]?.refetch();
    },
    hasMore: !hideDone && !!last?.data?.has_more,
    loadingMore: !!last?.isFetching,
    loadMore: () => setLoaded({ key, pages: pages + 1 }),
    /** What /runs opens: the first Needs you run, else the first listed run. */
    first: shownNeeds.find((i) => i.run_id)?.run_id ?? groups[0]?.runs[0]?.id,
  };
}

const DOT_CLASS: Record<Dot, string> = {
  human: "bg-state-human",
  running: "bg-state-done",
  queued: "border border-fg-tertiary",
  done: "bg-fg-tertiary/50",
  failed: "bg-state-blocked",
  idle: "bg-fg-tertiary/30",
};

function StatusDot({ dot }: { dot: Dot }) {
  return (
    <span title={DOT_LABEL[dot]} className="flex flex-none items-center">
      <span aria-hidden className={cx("size-2 rounded-full", DOT_CLASS[dot])} />
      <span className="sr-only">{DOT_LABEL[dot]}</span>
    </span>
  );
}

const rowClass = (active: boolean) =>
  cx("flex min-h-[44px] items-start gap-2.5 rounded-[10px] px-2.5 py-2 outline-none focus-visible:ring-1 focus-visible:ring-accent/60", active ? "bg-selected" : "hover:bg-hover");

function RunRow({ run, active, query }: { run: Run; active: boolean; query: string }) {
  return (
    <li>
      <Link
        href={`/runs/${run.id}${query ? `?${query}` : ""}`}
        aria-current={active ? "page" : undefined}
        data-run-row={run.id}
        title={`${runTitle(run)} · ${run.model} · started ${absoluteTime(run.started_at)}`}
        className={rowClass(active)}
      >
        <AgentAvatar name={run.agent.name} colorIndex={run.agent.color_index} label={false} />
        <span className="flex min-w-0 flex-1 flex-col">
          <span className="truncate text-13 text-fg">{runTitle(run)}</span>
          <span className="truncate text-12 text-fg-tertiary">{runLine(run)}</span>
        </span>
        <span className="flex flex-none flex-col items-end gap-1.5 pt-0.5">
          <time dateTime={run.started_at} className="text-11 text-fg-tertiary">{ago(run.started_at)}</time>
          <StatusDot dot={runDot(run)} />
        </span>
      </Link>
    </li>
  );
}

/** Compact single-line 28px run row for Work's Activity sidebar, matching ChatRow density. */
function CompactWorkRunRow({
  run,
  needsYou,
  active,
  query,
  now,
}: {
  run: Run;
  needsYou: boolean;
  active: boolean;
  query: string;
  now: Date;
}) {
  const dot = runDot(run, needsYou);
  const currentStep = run.plan.find((s) => s.state === "current")?.text;
  const tooltip = [
    runTitle(run),
    [run.ticket_key, run.agent.name, run.model].filter(Boolean).join(" · "),
    currentStep ?? DOT_LABEL[dot],
    `started ${absoluteTime(run.started_at)}`,
  ].join("\n");

  return (
    <li>
      <Link
        href={`/runs/${run.id}${query ? `?${query}` : ""}`}
        aria-current={active ? "page" : undefined}
        data-run-row={run.id}
        title={tooltip}
        className={cx(
          "flex h-[28px] items-center gap-2 rounded-md px-2 text-12 outline-none focus-visible:ring-1 focus-visible:ring-accent/60",
          active ? "bg-selected font-medium text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg",
        )}
      >
        <AgentOrPersonaAvatar agent={run.agent} size="sm" />
        <span
          title={DOT_LABEL[dot]}
          aria-hidden
          className={cx("size-1.5 flex-none rounded-full", DOT_CLASS[dot])}
        />
        <span className="min-w-0 flex-1 truncate">{runTitle(run)}</span>
        <time
          dateTime={run.ended_at ?? run.started_at}
          className={cx(
            "flex-none font-mono text-10",
            dot === "human"
              ? "text-pill-human-fg"
              : dot === "running"
                ? "text-state-done"
                : dot === "failed"
                  ? "text-pill-blocked-fg"
                  : "text-fg-tertiary",
          )}
        >
          {compactRunTime(run, dot, now)}
        </time>
      </Link>
    </li>
  );
}

function NeedsRow({ item, active, query }: { item: Item; active: boolean; query: string }) {
  const kind = KIND[item.kind] ?? { label: item.kind, tone: "human" };
  const meta = [kind.label, item.ticket_key || item.project, item.agent?.name].filter(Boolean).join(" · ");
  return (
    <li>
      <Link href={itemHref(item, query)} aria-current={active ? "page" : undefined} data-needs-row={item.id} className={rowClass(active)}>
        {item.agent ? (
          <AgentAvatar name={item.agent.name} colorIndex={item.agent.color_index} label={false} />
        ) : (
          <span aria-hidden className="grid size-5 flex-none place-items-center rounded-md bg-track text-fg-tertiary">
            <Icon name="inbox" size={12} />
          </span>
        )}
        <span className="flex min-w-0 flex-1 flex-col">
          <span className="truncate text-13 font-medium text-fg">{item.title}</span>
          <span className={cx("truncate text-12", kind.tone === "blocked" ? "text-pill-blocked-fg" : "text-fg-tertiary")}>{meta}</span>
        </span>
        <span className="flex flex-none flex-col items-end gap-1.5 pt-0.5">
          <span className="text-11 text-fg-tertiary">{waited(item.created_at)}</span>
          <StatusDot dot={kind.tone === "blocked" ? "failed" : "human"} />
        </span>
      </Link>
    </li>
  );
}

function Group({ id, label, count, tone, children }: { id: string; label: string; count?: number; tone?: "human"; children: React.ReactNode }) {
  return (
    <section id={id} aria-label={label} className="flex scroll-mt-2 flex-col gap-0.5">
      <h2 className={cx("flex items-center gap-1.5 px-2.5 pb-0.5 pt-2 text-12 font-medium", tone === "human" ? "text-pill-human-fg" : "text-fg-tertiary")}>
        {label}
        {count != null && <span className="font-mono">{count}</span>}
      </h2>
      <ul className="flex flex-col gap-px">{children}</ul>
    </section>
  );
}

/** The runner's busy · queued · slots and the last 7 days' spend, one quiet line linking to Reports. */
function StatusLine({ project }: { project?: string }) {
  const runner = useRunnerStatus().data;
  const [range] = useState(() => presetRange(7, new Date()));
  const costs = useCosts({ ...range, project }).data;
  const href = `/reports?tab=costs&range=7${project ? `&project=${encodeURIComponent(project)}` : ""}`;
  return (
    <p role="status" className="flex flex-wrap items-center gap-x-1.5 px-2.5 font-mono text-11 text-fg-tertiary">
      {runner && <span>{runner.online ? `${runner.busy} busy · ${runner.queued} queued · ${runner.slots} slots` : `Runner offline · ${runner.queued} queued`}</span>}
      {runner && <span aria-hidden>·</span>}
      <Link href={href} className="hover:text-fg hover:underline" title="Spend in the last 7 days, in Reports">
        {costs ? spendLabel(costs.total.cost_micros, costs.unpriced_runs) : "–"} this week
      </Link>
    </p>
  );
}

function Chips({ project, agent, hideDone, doneOnly = false }: { project?: string; agent?: string; hideDone: boolean; doneOnly?: boolean }) {
  const params = useSearchParams();
  const router = useRouter();
  const pathname = usePathname();
  const boot = useBootstrap();
  const projects = (boot.data?.projects ?? []).filter((p) => !p.archived || p.key === project);
  const agents = boot.data?.agents ?? [];
  const set = (k: string, v: string | undefined) => {
    const q = new URLSearchParams(params);
    if (v === undefined) q.delete(k);
    else q.set(k, v);
    router.replace(`${pathname}${q.size ? `?${q}` : ""}`, { scroll: false });
  };
  return (
    <div className="flex flex-wrap items-center gap-1.5 px-1">
      {/* "All spaces" stays explicit (?project=), so the shell's project doesn't come back. */}
      {/* Work has its own Space and Persona filters above the list, so it only takes Hide done. */}
      {!doneOnly && <FilterMenu label="Space" value={project ?? ""} onChange={(v) => set("project", v)}
        options={[{ value: "", label: "All spaces" }, ...projects.map((p) => ({ value: p.key, label: p.name }))]} />}
      {!doneOnly && <FilterMenu label="Persona" value={agent ?? ""} onChange={(v) => set("agent", v || undefined)}
        options={[{ value: "", label: "All personas" }, ...agents.map((a) => ({ value: a.handle, label: a.name }))]} />}
      <button
        type="button"
        aria-pressed={hideDone}
        onClick={() => set("done", hideDone ? undefined : "hide")}
        className={cx("flex h-8 items-center gap-1 rounded-md border px-2.5 text-12", hideDone ? "border-accent bg-accent-soft text-fg" : "border-border-strong bg-surface text-fg hover:bg-hover")}
      >
        {hideDone && <Icon name="check" size={12} />}
        Hide done
      </button>
    </div>
  );
}

/** The grouped list. `selected` is the run (or Needs you run) open beside it. */
export function RunList({ selected, fill, embedded = false, search: workSearch }: { selected?: string; fill?: boolean; embedded?: boolean; search?: string }) {
  const params = useSearchParams();
  const router = useRouter();
  const path = usePathname();
  const [search, setSearch] = useState("");
  const effectiveSearch = workSearch ?? search;
  const data = useRunList(effectiveSearch);
  const query = listQuery(params);
  const searchRef = useRef<HTMLInputElement>(null);
  const listRef = useRef<HTMLDivElement>(null);
  const [now] = useState(() => new Date());
  const activityFilter = parseActivityFilter(params.get("filter"), params.get("done"));

  const setActivityFilter = (next: "all" | "needs_you" | "active" | "failed") => {
    const q = new URLSearchParams(params);
    q.delete("done");
    if (next === "all") q.delete("filter");
    else q.set("filter", next);
    router.replace(`${path}${q.size ? `?${q}` : ""}`, { scroll: false });
  };

  // "/" focuses the standalone /runs search box (embedded search lives in WorkNavHeader).
  useEffect(() => {
    if (embedded) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "/" || shortcutBlocked(e)) return;
      e.preventDefault();
      searchRef.current?.focus();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [embedded]);

  // The tray's "Open all" lands on /work#needs-you: bring the group into view once it's there.
  const hasNeeds = data.shownNeeds.length > 0;
  useEffect(() => {
    if (hasNeeds && window.location.hash === "#needs-you") document.getElementById("needs-you")?.scrollIntoView({ block: "start" });
  }, [hasNeeds, path]);

  const needsRunIds = useMemo(
    () => new Set(data.shownNeeds.flatMap((i) => (i.run_id ? [i.run_id] : []))),
    [data.shownNeeds],
  );
  const searchedRuns = useMemo(
    () => data.runs.filter((r) => matchesRun(r, effectiveSearch)),
    [data.runs, effectiveSearch],
  );
  const viewCounts = useMemo(
    () => computeActivityViewCounts(searchedRuns, needsRunIds, now),
    [searchedRuns, needsRunIds, now],
  );
  const embeddedGroups = useMemo(() => {
    const filtered = filterActivityRuns(searchedRuns, activityFilter, needsRunIds, now);
    return groupActivitySidebarRuns(filtered, now);
  }, [searchedRuns, activityFilter, needsRunIds, now]);

  const selectedNeeds = data.shownNeeds.find((i) => i.run_id === selected)?.id;
  const runIds = useMemo(() => new Set(data.runs.map((r) => r.id)), [data.runs]);
  const nonRunNeeds = useMemo(
    () =>
      activityFilter === "all" || activityFilter === "needs_you"
        ? data.shownNeeds.filter((i) => !i.run_id || !runIds.has(i.run_id))
        : [],
    [activityFilter, data.shownNeeds, runIds],
  );
  const hasActiveGroup = embeddedGroups.some((g) => g.kind === "active");
  const empty = embedded
    ? !data.loading && !data.error && embeddedGroups.length === 0 && nonRunNeeds.length === 0
    : !data.loading && !data.error && data.shownNeeds.length === 0 && data.groups.length === 0;

  if (embedded) {
    const extraNeedsSection = nonRunNeeds.length > 0 && (
      <section
        id={hasActiveGroup ? "needs-you-items" : "needs-you"}
        aria-label={hasActiveGroup ? "Other needs you" : "Needs you"}
        className="flex scroll-mt-2 flex-col"
      >
        <WorkSectionLabel count={nonRunNeeds.length} tone="human">
          {hasActiveGroup ? "Waiting" : "Needs you"}
        </WorkSectionLabel>
        <ul className="flex flex-col gap-0.5">
          {nonRunNeeds.map((i) => (
            <li key={i.id}>
              <Link
                href={itemHref(i, query)}
                aria-current={i.id === selectedNeeds ? "page" : undefined}
                data-needs-row={i.id}
                className="flex h-[28px] items-center gap-2 rounded-md px-2 text-12 text-fg-secondary hover:bg-hover hover:text-fg"
              >
                <span aria-hidden className="grid size-5 flex-none place-items-center rounded bg-pill-human-bg text-pill-human-fg">
                  <Icon name="inbox" size={11} />
                </span>
                <span aria-hidden className="size-1.5 flex-none rounded-full bg-state-human" />
                <span className="min-w-0 flex-1 truncate">{i.title}</span>
                <span className="flex-none font-mono text-10 text-pill-human-fg">{waited(i.created_at)}</span>
              </Link>
            </li>
          ))}
        </ul>
      </section>
    );

    return (
      <aside aria-label="Runs" className="flex min-h-0 flex-1 flex-col gap-1">
        <div className="flex flex-col gap-0.5 pb-1">
          <WorkSectionLabel>View</WorkSectionLabel>
          <WorkSidebarFilterRow
            label="All activity"
            count={viewCounts.all}
            active={activityFilter === "all"}
            dotClass="bg-accent"
            onClick={() => setActivityFilter("all")}
          />
          <WorkSidebarFilterRow
            label="Needs you"
            count={Math.max(viewCounts.needs_you, data.shownNeeds.length)}
            active={activityFilter === "needs_you"}
            dotClass="bg-state-human"
            countTone="human"
            onClick={() => setActivityFilter("needs_you")}
          />
          <WorkSidebarFilterRow
            label="Running & queued"
            count={viewCounts.active}
            active={activityFilter === "active"}
            dotClass="bg-state-done"
            onClick={() => setActivityFilter("active")}
          />
          <WorkSidebarFilterRow
            label="Failed today"
            count={viewCounts.failed}
            active={activityFilter === "failed"}
            dotClass="bg-state-blocked"
            countTone="blocked"
            onClick={() => setActivityFilter("failed")}
          />
        </div>

        <div ref={listRef} className="relative flex min-h-0 flex-1 flex-col gap-1 overflow-y-auto pb-3">
          {!hasActiveGroup && extraNeedsSection}
          {data.error ? (
            <div role="alert" className="flex flex-col items-start gap-2 px-2 py-4 text-12 text-pill-blocked-fg">
              Couldn’t load runs. {data.error.message}
              <Button variant="outline" onClick={data.retry}>Retry</Button>
            </div>
          ) : data.loading ? (
            <div aria-busy="true" className="flex flex-col gap-1 px-1 pt-2">
              {[0, 1, 2, 3, 4].map((i) => <Skeleton key={i} className="h-7" />)}
            </div>
          ) : empty ? (
            <p className="px-2 py-6 text-center text-12 text-fg-tertiary">
              {effectiveSearch ? "No runs match." : "No runs in this view."}
            </p>
          ) : (
            <>
              {embeddedGroups.map((g, idx) => (
                <section
                  key={g.label}
                  id={g.kind === "active" && idx === 0 ? "needs-you" : `runs-${g.label.toLowerCase().replace(/\W+/g, "-")}`}
                  aria-label={g.label}
                  className="flex scroll-mt-2 flex-col"
                >
                  <WorkSectionLabel count={g.runs.length}>{g.label}</WorkSectionLabel>
                  <ul className="flex flex-col gap-0.5">
                    {g.runs.map((r) => (
                      <CompactWorkRunRow
                        key={r.id}
                        run={r}
                        needsYou={isRunNeedsYou(r, needsRunIds)}
                        active={r.id === selected}
                        query={query}
                        now={now}
                      />
                    ))}
                  </ul>
                </section>
              ))}
              {hasActiveGroup && extraNeedsSection}
              {data.hasMore && activityFilter === "all" && (
                <div className="px-2 pt-1">
                  <Button variant="ghost" disabled={data.loadingMore} onClick={data.loadMore}>
                    Load older runs
                  </Button>
                </div>
              )}
            </>
          )}
        </div>
      </aside>
    );
  }

  return (
    <aside
      aria-label="Runs"
      className={cx("flex min-h-0 flex-1 flex-col gap-2", fill ? "px-2 pt-safe" : "px-1.5")}
    >
      <div className="flex flex-col gap-2 px-1">
        <div className="flex items-center gap-2 px-1.5">
          <h1 className={cx("flex-1 font-semibold", fill ? "type-display" : "text-13")}>Runs</h1>
        </div>
        <StatusLine project={data.project} />
        <div className="relative px-1">
          <TextInput
            ref={searchRef}
            type="search"
            aria-label="Search runs"
            placeholder="Search runs"
            value={search}
            onChange={(e) => setSearch(e.target.value)}
            onKeyDown={(e) => e.key === "Escape" && (setSearch(""), e.currentTarget.blur())}
            className={cx("w-full pr-8", fill ? "h-[44px] text-16" : "h-8")}
          />
          {!search && <Kbd className="pointer-events-none absolute right-3 top-1/2 -translate-y-1/2 pointer-coarse:hidden">/</Kbd>}
        </div>
        <Chips project={data.project} agent={data.agent} hideDone={data.hideDone} />
      </div>
      {/* Contain absolute screen-reader labels as well as the visible rows. */}
      <div ref={listRef} className="relative flex min-h-0 flex-1 flex-col gap-2 overflow-y-auto pb-3">
        {data.shownNeeds.length > 0 && (
          <Group id="needs-you" label="Needs you" count={data.shownNeeds.length} tone="human">
            {data.shownNeeds.map((i) => <NeedsRow key={i.id} item={i} active={i.id === selectedNeeds} query={query} />)}
          </Group>
        )}
        {data.error ? (
          <div role="alert" className="flex flex-col items-start gap-2 px-3 py-4 text-13 text-pill-blocked-fg">
            Couldn’t load runs. {data.error.message}
            <Button variant="outline" onClick={data.retry}>Retry</Button>
          </div>
        ) : data.loading ? (
          <div aria-busy="true" className="flex flex-col gap-2 px-1.5">
            {[0, 1, 2, 3].map((i) => <Skeleton key={i} className="h-11" />)}
          </div>
        ) : empty ? (
          <p className="px-3 py-8 text-center text-13 text-fg-tertiary">
            {search ? "No runs match." : "No runs yet. Start one from a ticket or a chat."}
          </p>
        ) : (
          <>
            {data.groups.map((g) => (
              <Group key={g.key} id={`runs-${g.key.replace(/\W+/g, "-")}`} label={g.label} count={g.key === "running" || g.key === "queued" ? g.runs.length : undefined}>
                {g.runs.map((r) => <RunRow key={r.id} run={r} active={r.id === selected && !selectedNeeds} query={query} />)}
              </Group>
            ))}
            {data.hasMore && (
              <div className="px-2.5">
                <Button variant="ghost" disabled={data.loadingMore} onClick={data.loadMore}>Load older runs</Button>
              </div>
            )}
          </>
        )}
      </div>
    </aside>
  );
}
