"use client";

// The Runs list (LAZYAGENTS-163), styled like the chat history: Needs you (the
// sidebar tray's queue, non-run items included), Running, Queued, then
// finished runs by day. It sits beside the run thread on desktop and is the
// whole screen on compact, where a row pushes the run.

import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useMemo, useState } from "react";
import { useBootstrap, useCosts, useInbox, useRunnerStatus, useRunPages } from "@/lib/api/hooks";
import { presetRange, spendLabel } from "@/lib/costs";
import { ago } from "@/lib/format";
import { KIND, trayItems, waited } from "@/lib/inbox";
import { groupRuns, itemHref, matchesItem, matchesRun, runDot, runLine, runTitle } from "@/lib/run-list";
import {
  compactRunTime,
  computeActivityViewCounts,
  filterActivityRuns,
  groupActivitySidebarRuns,
  isRunNeedsYou,
} from "@/lib/work-overview";
import { useProjectScope } from "@/components/shell/project-scope";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import {
  buildRunsNavModel,
  needsItemId,
  RUN_AGENT_FILTER,
  RUN_OPTIONS_FILTER,
  RUN_SPACE_FILTER,
  RUN_HIDE_DONE,
  RUN_LOAD_MORE,
  RUN_RETRY,
  RUN_SEARCH,
  runItemId,
  type NeedsRowData,
  type RunListBody,
} from "@/lib/native-shell/models/runs";
import { agentAvatarColor } from "@/lib/native-shell/models/common";
import type { NativeCommand } from "@/lib/native-shell/protocol";

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

type RunListData = ReturnType<typeof useRunList>;
type ActivityFilterValue = "all" | "needs_you" | "active" | "failed";

/** What Work's Activity list shows: counts for the View filter, the filtered run groups and the Needs you items that have no run row. Shared by the list and by the native sidebar model. */
export function useActivityLists(data: RunListData, search: string, filter: ActivityFilterValue, now: Date) {
  const needsRunIds = useMemo(() => new Set(data.shownNeeds.flatMap((i) => (i.run_id ? [i.run_id] : []))), [data.shownNeeds]);
  const searchedRuns = useMemo(() => data.runs.filter((r) => matchesRun(r, search)), [data.runs, search]);
  const viewCounts = useMemo(() => computeActivityViewCounts(searchedRuns, needsRunIds, now), [searchedRuns, needsRunIds, now]);
  const embeddedGroups = useMemo(() => {
    const filtered = filterActivityRuns(searchedRuns, filter, needsRunIds, now);
    return groupActivitySidebarRuns(filtered, now);
  }, [searchedRuns, filter, needsRunIds, now]);
  const runIds = useMemo(() => new Set(data.runs.map((r) => r.id)), [data.runs]);
  const nonRunNeeds = useMemo(
    () => (filter === "all" || filter === "needs_you" ? data.shownNeeds.filter((i) => !i.run_id || !runIds.has(i.run_id)) : []),
    [filter, data.shownNeeds, runIds],
  );
  return { needsRunIds, viewCounts, embeddedGroups, nonRunNeeds };
}

function standaloneBody(data: RunListData, search: string, query: string): RunListBody {
  return {
    needs: data.shownNeeds.map((i): NeedsRowData => {
      const kind = KIND[i.kind] ?? { label: i.kind, tone: "human" };
      return {
        id: i.id,
        href: itemHref(i, query),
        title: i.title,
        subtitle: [kind.label, i.ticket_key || i.project, i.agent?.name].filter(Boolean).join(" · "),
        agentName: i.agent?.name,
        agentColor: i.agent ? agentAvatarColor(i.agent.color_index) : undefined,
        trailing: waited(i.created_at),
        tone: kind.tone === "blocked" ? "blocked" : "human",
      };
    }),
    needsLabel: "Needs you",
    groups: data.groups.map((g) => ({
      key: g.key,
      label: g.label,
      count: g.key === "running" || g.key === "queued" ? g.runs.length : undefined,
      runs: g.runs.map((r) => ({
        id: r.id,
        href: `/runs/${r.id}${query ? `?${query}` : ""}`,
        title: runTitle(r),
        subtitle: runLine(r),
        agentName: r.agent.name,
        agentColor: agentAvatarColor(r.agent.color_index),
        trailing: ago(r.started_at),
        dot: runDot(r),
      })),
    })),
    loading: !!data.loading,
    error: data.error?.message ?? null,
    hasMore: data.hasMore,
    loadingMore: data.loadingMore,
    emptyText: search ? "No runs match." : "No runs yet. Start one from a ticket or a chat.",
    withHref: true,
  };
}

/** The run list for the native sidebar: its state (search, filters in the URL) and the commands the shell sends. The page renders <RunList> only in a browser. */
function useRunsNative(selected?: string) {
  const params = useSearchParams();
  const router = useRouter();
  const pathname = usePathname();
  const boot = useBootstrap();
  const [search, setSearch] = useState("");
  const data = useRunList(search);
  const query = listQuery(params);
  const runner = useRunnerStatus().data;
  const [range] = useState(() => presetRange(7, new Date()));
  const costs = useCosts({ ...range, project: data.project }).data;
  const set = (k: string, v: string | undefined) => {
    const q = new URLSearchParams(params);
    if (v === undefined) q.delete(k);
    else q.set(k, v);
    router.replace(`${pathname}${q.size ? `?${q}` : ""}`, { scroll: false });
  };
  const body = standaloneBody(data, search, query);
  const selectedNeeds = data.shownNeeds.find((i) => i.run_id === selected)?.id;
  const statusText = [
    runner &&
      (runner.online
        ? `${runner.busy} busy · ${runner.queued} queued · ${runner.slots} slots`
        : `${runner.starting ? "Runner starting" : "Runner offline"} · ${runner.queued} queued`),
    `${costs ? spendLabel(costs.total.cost_micros, costs.unpriced_runs) : "–"} this week`,
  ].filter(Boolean).join(" · ");
  const model = buildRunsNavModel({
    body,
    filters: {
      project: data.project,
      agent: data.agent,
      hideDone: data.hideDone,
      projects: (boot.data?.projects ?? []).filter((p) => !p.archived || p.key === data.project),
      agents: boot.data?.agents ?? [],
    },
    search,
    statusLine: { text: statusText, href: `/reports?tab=costs&range=7${data.project ? `&project=${encodeURIComponent(data.project)}` : ""}` },
    selectedId: selectedNeeds ? needsItemId(selectedNeeds) : selected ? runItemId(selected) : null,
  });
  const onCommand = (cmd: NativeCommand) => {
    if (cmd.type === "nav.search" && cmd.searchId === RUN_SEARCH) setSearch(cmd.value);
    else if (cmd.type === "nav.filter") {
      if (cmd.filterId === RUN_OPTIONS_FILTER && cmd.value === RUN_HIDE_DONE) set("done", cmd.checked ? "hide" : undefined);
      else if (cmd.filterId === RUN_SPACE_FILTER) set("project", cmd.value);
      else if (cmd.filterId === RUN_AGENT_FILTER) set("agent", cmd.value || undefined);
    } else if (cmd.type === "nav.activate") {
      if (cmd.itemId === RUN_LOAD_MORE) data.loadMore();
      else if (cmd.itemId === RUN_RETRY) data.retry();
    }
  };
  return { model, onCommand };
}

/** The Runs list in the native left column. */
export function RunsNavigator({ selected }: { selected?: string }) {
  const native = useRunsNative(selected);
  return <NavigatorPortal native={native} />;
}

/** Work's Activity list for the native sidebar. */
export function activityNativeBody(
  data: RunListData,
  lists: ReturnType<typeof useActivityLists>,
  opts: { search: string; query: string; now: Date },
): RunListBody {
  const hasActiveGroup = lists.embeddedGroups.some((g) => g.kind === "active");
  const empty = !data.loading && !data.error && lists.embeddedGroups.length === 0 && lists.nonRunNeeds.length === 0;
  return {
    needs: lists.nonRunNeeds.map((i) => ({
      id: i.id,
      href: itemHref(i, opts.query),
      title: i.title,
      agentName: undefined,
      trailing: waited(i.created_at),
      tone: "human" as const,
    })),
    needsLabel: hasActiveGroup ? "Waiting" : "Needs you",
    needsAfterGroups: hasActiveGroup,
    groups: lists.embeddedGroups.map((g) => ({
      key: g.label,
      label: g.label,
      count: g.runs.length,
      runs: g.runs.map((r) => {
        const dot = runDot(r, isRunNeedsYou(r, lists.needsRunIds));
        return {
          id: r.id,
          href: `/runs/${r.id}${opts.query ? `?${opts.query}` : ""}`,
          title: runTitle(r),
          agentName: r.agent.name,
          agentColor: agentAvatarColor(r.agent.color_index),
          trailing: compactRunTime(r, dot, opts.now),
          dot,
        };
      }),
    })),
    loading: !!data.loading,
    error: data.error?.message ?? null,
    hasMore: data.hasMore,
    loadingMore: data.loadingMore,
    emptyText: empty && opts.search ? "No runs match." : "No runs in this view.",
    withHref: false,
  };
}
