"use client";

import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import {
  useBootstrap,
  useCosts,
  useRunnerStatus,
} from "@/lib/api/hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { presetRange, spendLabel } from "@/lib/costs";
import { itemHref } from "@/lib/run-list";
import {
  updateWorkUrl,
  workHref,
  workTarget,
  workView,
} from "@/lib/work-navigation";
import { parseActivityFilter } from "@/lib/work-overview";
import { ticketsHref } from "@/lib/tickets-layout";
import { pageOrigin } from "@/lib/native-shell/models/common";
import {
  buildWorkActivityNavModel,
  RUN_LOAD_MORE,
  RUN_OVERVIEW_ITEM,
  RUN_RETRY,
  RUN_VIEW_FILTER,
  type ActivityFilter,
} from "@/lib/native-shell/models/runs";
import { handleWorkHeaderCommand } from "@/lib/native-shell/models/work";
import {
  buildWorkToolbar,
  parseWorkToolbarAction,
} from "@/lib/native-shell/models/work-toolbars";
import type { NativeCommand } from "@/lib/native-shell/protocol";
import { useNativeToolbar } from "@/lib/native-shell/use-native-toolbar";
import { CompanionDock } from "@/components/shell/companion";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { useProjectScope } from "@/components/shell/project-scope";
import { useCompact } from "@/lib/viewport";
import { useNativeTitle } from "../tickets/_components/native-title";
import { RunLogScreen } from "../runs/[id]/run-log";
import {
  activityNativeBody,
  listQuery,
  useActivityLists,
  useRunList,
} from "../runs/run-list";
import { ActivityOverview } from "./activity-overview";

/** Native toolbar + title when Work is showing the unselected Runs Overview. */
function NativeOverviewHeader({
  needs,
  onNeeds,
}: {
  needs: number;
  onNeeds: () => void;
}) {
  useNativeTitle("Runs");
  useNativeToolbar({
    items: buildWorkToolbar({ needs }),
    onAction: (id) => {
      if (parseWorkToolbarAction(id) === "needs") onNeeds();
    },
  });
  return null;
}

export function WorkScreen() {
  const params = useSearchParams();
  const pathname = usePathname();
  const router = useRouter();
  const compact = useCompact();
  const boot = useBootstrap();
  const personas = usePersonas();
  const scope = useProjectScope("optional");

  const view = workView(params);
  const project = params.has("project")
    ? params.get("project") || undefined
    : scope.status === "ready"
      ? scope.project?.key
      : undefined;
  const agent = params.get("agent") || undefined;

  // Keep search input local to avoid dropping characters while URL params update.
  const urlSearch = params.get("q") ?? "";
  const [search, setSearch] = useState(urlSearch);
  const [seenUrlSearch, setSeenUrlSearch] = useState(urlSearch);
  if (urlSearch !== seenUrlSearch) {
    setSeenUrlSearch(urlSearch);
    setSearch(urlSearch);
  }

  // Redirect legacy ?view=tickets / ?view=epics URLs onto the canonical screens.
  const legacyTicket = params.get("ticket");
  const legacyEpic = params.get("epic");
  const legacyLayout = params.get("layout");
  useEffect(() => {
    if (view === "tickets") {
      if (legacyTicket) {
        router.replace(`/tickets/${encodeURIComponent(legacyTicket)}`);
        return;
      }
      const keep: Record<string, string> = {};
      if (project) keep.project = project;
      router.replace(ticketsHref(legacyLayout === "board" ? "board" : "list", keep));
    } else if (view === "epics") {
      if (legacyEpic) {
        router.replace(`/epics/${encodeURIComponent(legacyEpic)}`);
        return;
      }
      const keep: Record<string, string> = {};
      if (project) keep.project = project;
      router.replace(ticketsHref("epics", keep));
    }
  }, [view, legacyTicket, legacyEpic, legacyLayout, project, router]);

  const runs = useRunList(search);
  const runId = params.get("run") || undefined;

  const [nowDate] = useState(() => new Date());
  const [range7d] = useState(() => presetRange(7, nowDate));
  const runner = useRunnerStatus().data;
  const costs7d = useCosts({ ...range7d, project }).data;
  const activityFilter = parseActivityFilter(params.get("filter"), params.get("done"));
  const activityLists = useActivityLists(runs, search, activityFilter, nowDate);

  const openWorkPath = (path: string) => {
    const url = new URL(path, window.location.href);
    const current = new URLSearchParams(
      workHref(new URLSearchParams(window.location.search), {
        ...(runId ? { run: runId } : {}),
      }).split("?")[1],
    );
    const href = workTarget(url.pathname, current);
    if (href) window.history.pushState(null, "", href);
    else router.push(path);
  };

  const statusText = [
    runner &&
      (runner.online
        ? `${runner.busy} busy · ${runner.slots} slots`
        : runner.starting
          ? "Runner starting"
          : "Runner offline"),
    costs7d ? `${spendLabel(costs7d.total.cost_micros, costs7d.unpriced_runs)} 7d` : null,
  ]
    .filter(Boolean)
    .join(" · ");

  const nonRunSelected = runId
    ? runs.shownNeeds.find(
        (i) => i.run_id === runId && activityLists.nonRunNeeds.some((n) => n.id === i.id),
      )
    : undefined;

  const selectedId = !runId
    ? RUN_OVERVIEW_ITEM
    : nonRunSelected
      ? `needs:${nonRunSelected.id}`
      : `run:${runId}`;

  const activeCount = runs.runs.filter((r) => r.state === "running" || r.state === "queued").length;

  const activityNative =
    view === "activity"
      ? {
          model: buildWorkActivityNavModel({
            header: {
              active: "activity",
              project,
              projects: boot.data?.projects,
              agents: boot.data?.agents,
              agent: agent ?? "",
              counts: {
                activity: runs.needs.length + activeCount || undefined,
              },
              search: { value: search, placeholder: "Filter runs…" },
            },
            body: {
              ...activityNativeBody(runs, activityLists, {
                search,
                query: listQuery(params),
                now: nowDate,
                personas: personas.data?.personas,
                origin: pageOrigin(),
              }),
              hasMore: runs.hasMore && activityFilter === "all",
            },
            filter: activityFilter as ActivityFilter,
            counts: {
              all: activityLists.viewCounts.all,
              needs_you: Math.max(activityLists.viewCounts.needs_you, runs.shownNeeds.length),
              active: activityLists.viewCounts.active,
              failed: activityLists.viewCounts.failed,
            },
            statusLine: statusText
              ? {
                  text: statusText,
                  href: `/reports?tab=costs&range=7${project ? `&project=${encodeURIComponent(project)}` : ""}`,
                }
              : undefined,
            selectedId,
          }),
          onCommand: (cmd: NativeCommand) => {
            const handled = handleWorkHeaderCommand(cmd, {
              project,
              push: (href) => router.push(href),
              onProject: (v) => updateWorkUrl({ project: v || null }),
              onAgent: (v) => updateWorkUrl({ agent: v || null }),
              onSearch: (q) => {
                setSearch(q);
                updateWorkUrl({ q: q || null }, true);
              },
              onActivity: () => updateWorkUrl({ run: null, view: null }),
            });
            if (handled) return;
            if (cmd.type === "nav.filter" && cmd.filterId === RUN_VIEW_FILTER) {
              const next = cmd.value;
              const q = new URLSearchParams(params);
              q.delete("done");
              if (next === "all") q.delete("filter");
              else q.set("filter", next);
              router.replace(`${pathname}${q.size ? `?${q}` : ""}`, { scroll: false });
            } else if (cmd.type === "nav.activate") {
              if (cmd.itemId === RUN_OVERVIEW_ITEM) {
                updateWorkUrl({ run: null, view: null });
              } else if (cmd.itemId === RUN_LOAD_MORE) {
                runs.loadMore();
              } else if (cmd.itemId === RUN_RETRY) {
                runs.retry();
              } else if (cmd.itemId.startsWith("run:")) {
                openWorkPath(`/runs/${cmd.itemId.slice(4)}`);
              } else if (cmd.itemId.startsWith("needs:")) {
                const item = runs.shownNeeds.find((i) => i.id === cmd.itemId.slice(6));
                if (item) openWorkPath(itemHref(item, listQuery(params)));
              }
            }
          },
        }
      : undefined;

  if (view !== "activity") return null;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <NavigatorPortal native={activityNative} />
      {runId ? (
        <RunLogScreen key={runId} id={runId} inWork />
      ) : (
        <>
          <NativeOverviewHeader
            needs={runs.needs.length}
            onNeeds={() => updateWorkUrl({ run: null, view: null, filter: "needs_you" })}
          />
          <ActivityOverview
            project={project}
            runs={runs.runs}
            needs={runs.needs}
            filter={activityFilter}
            onSelectRun={(id) => updateWorkUrl({ run: id, view: null })}
          />
          {!compact && (
            <CompanionDock
              app="work"
              defaultOpen={false}
              tabs={[
                {
                  id: "chat",
                  label: "Chat",
                  icon: "msg",
                  native: { kind: "companion" },
                },
              ]}
            />
          )}
        </>
      )}
    </div>
  );
}
