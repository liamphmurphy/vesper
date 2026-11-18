"use client";

import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useEffect, useState, type MouseEvent } from "react";
import type { TicketStatus } from "@/lib/api/client";
import {
  useBootstrap,
  useEpicOverviews,
  useTickets,
  type TicketView,
} from "@/lib/api/hooks";
import {
  workHref,
  workTarget,
  workView,
  updateWorkUrl,
} from "@/lib/work-navigation";
import { runTitle } from "@/lib/run-list";
import type { WorkSubject } from "@/lib/work-context";
import { useCompact } from "@/lib/viewport";
import { cx } from "@/lib/cx";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { CompanionDock } from "@/components/shell/companion";
import { WorkChat } from "@/components/domain/work-chat";
import { TopBar } from "@/components/shell/topbar";
import { useProjectScope } from "@/components/shell/project-scope";
import { STATUS_NAME } from "@/components/domain/meta";
import { Button } from "@/components/ui/button";
import { WorkSavedViews } from "./work-saved-views";
import { ActivityOverview } from "./activity-overview";
import { parseActivityFilter } from "@/lib/work-overview";
import {
  TicketBrief,
  EpicBrief,
  LiveRun,
  LoadState,
  WorkTopRunLinks,
  type Navigate,
} from "./work-details";
import { WorkNavHeader, WorkSpacePersonaFilters } from "./work-nav-header";
import { BoardView } from "../tickets/_components/board-screen";
import { activityNativeBody, RunList, useActivityLists, useRunList } from "../runs/run-list";
import { itemHref } from "@/lib/run-list";
import { listQuery } from "../runs/run-list";
import { buildWorkActivityNavModel, RUN_LOAD_MORE, RUN_RETRY, RUN_VIEW_FILTER, type ActivityFilter } from "@/lib/native-shell/models/runs";
import { handleWorkHeaderCommand } from "@/lib/native-shell/models/work";
import { ticketsHref } from "@/lib/tickets-layout";
import type { NativeCommand } from "@/lib/native-shell/protocol";
import "./work.css";

export function WorkScreen() {
  const params = useSearchParams();
  const compact = useCompact();
  const boot = useBootstrap();
  const scope = useProjectScope("optional");
  const view = workView(params);
  const project = params.has("project")
    ? params.get("project") || undefined
    : scope.status === "ready"
      ? scope.project?.key
      : undefined;
  const agent = params.get("agent") || undefined;
  // The box keeps its own value: reading it back from the URL each keystroke
  // dropped characters typed before Next re-rendered the new search params.
  const urlSearch = params.get("q") ?? "";
  const [search, setSearch] = useState(urlSearch);
  const [seenUrlSearch, setSeenUrlSearch] = useState(urlSearch);
  if (urlSearch !== seenUrlSearch) {
    // Back/Forward or a saved view changed ?q=: follow it.
    setSeenUrlSearch(urlSearch);
    setSearch(urlSearch);
  }
  const tickets = useTickets({
    project,
    assignee: agent,
    view: (["active", "backlog", "agent_owned", "needs_human", "all"].includes(
      params.get("ticket_view") ?? "",
    )
      ? params.get("ticket_view")
      : "all") as TicketView,
    status: (params.get("status") || undefined) as TicketStatus | undefined,
    label: params.get("label") || undefined,
    epic: params.get("filter_epic") || undefined,
    ready: params.get("ready") === "true" || undefined,
  });
  const epics = useEpicOverviews();
  const runs = useRunList(search);
  const runId = params.get("run") ?? runs.first;
  const selectedRun = runs.runs.find((r) => r.id === runId);
  const ticketKey =
    params.get("ticket") ??
    selectedRun?.ticket_key ??
    (view === "tickets" ? tickets.data?.[0]?.key : undefined);
  const epicId =
    params.get("epic") ??
    tickets.data?.find((t) => t.key === ticketKey)?.epic?.id ??
    (view === "epics"
      ? epics.data?.find((e) => !project || e.project.key === project)?.epic.id
      : undefined);
  const context = params.get("context");
  const selectedTicket = ticketKey ? tickets.data?.find((t) => t.key === ticketKey) : undefined;
  const workSubject: WorkSubject | undefined =
    (view === "tickets" || context === "ticket") && selectedTicket
      ? { kind: "ticket", key: selectedTicket.key, title: selectedTicket.title }
      : selectedRun
        ? {
            kind: "run",
            id: selectedRun.id,
            title: runTitle(selectedRun),
            agent: selectedRun.agent.name,
            ticketKey: selectedRun.ticket_key ?? undefined,
          }
        : undefined;
  const companion = view !== "activity";
  const showRun = !!runId && (!companion || params.get("companion") !== "hide");
  const showBrief = companion || context === "ticket" || context === "epic";
  const navigate: Navigate = updateWorkUrl;
  const router = useRouter();
  // Browsing tickets or epics belongs to the full Tickets screens; Work's own
  // ticket and epic views are only for a focused item beside its run.
  const browse =
    (view === "tickets" && !params.get("ticket")) ||
    (view === "epics" && !params.get("epic"));
  useEffect(() => {
    if (!browse) return;
    const keep: Record<string, string> = {};
    if (project) keep.project = project;
    if (view === "tickets" && params.get("layout") === "board") {
      router.replace(ticketsHref("board", keep));
    } else {
      router.replace(ticketsHref(view === "epics" ? "epics" : "list", keep));
    }
  }, [browse, view, project, params, router]);
  // Pin inferred selections into the URL before opening context or changing views.
  const go: Navigate = (patch) =>
    navigate({
      ...(runId ? { run: runId } : {}),
      ...(ticketKey ? { ticket: ticketKey } : {}),
      ...(epicId ? { epic: epicId } : {}),
      ...patch,
    });
  function intercept(e: MouseEvent) {
    if (
      e.defaultPrevented ||
      e.button ||
      e.metaKey ||
      e.ctrlKey ||
      e.shiftKey ||
      e.altKey
    )
      return;
    const a = (e.target as HTMLElement).closest("a");
    if (!a || a.target || a.hasAttribute("download")) return;
    const url = new URL(a.href, window.location.href);
    if (
      url.origin !== window.location.origin ||
      url.searchParams.get("view") === "details" ||
      url.searchParams.get("full") === "1"
    )
      return;
    const href = workTarget(
      url.pathname,
      new URLSearchParams(
        workHref(new URLSearchParams(window.location.search), {
          ...(runId ? { run: runId } : {}),
        }).split("?")[1],
      ),
    );
    if (href) {
      e.preventDefault();
      e.stopPropagation();
      window.history.pushState(null, "", href);
    }
  }
  const shownTickets = (tickets.data ?? []).filter(
    (t) =>
      `${t.key} ${t.title}`.toLowerCase().includes(search.toLowerCase()) &&
      (params.get("blocked") !== "true" || t.unmet_dependencies > 0) &&
      (params.get("unestimated") !== "true" || !t.estimate_points),
  );
  const shownEpics = (epics.data ?? []).filter(
    (e) =>
      (!project || e.project.key === project) &&
      (!agent || e.agents.some((a) => a.handle === agent)) &&
      e.epic.name.toLowerCase().includes(search.toLowerCase()),
  );
  const openEpicsCount = epics.data?.filter(
    (e) => (!project || e.project.key === project) && e.epic.status === "open",
  ).length;
  const openTicketsCount = tickets.data?.filter(
    (t) => t.status !== "done" && t.status !== "canceled",
  ).length;
  // The Activity list in the native sidebar. The Tickets and Epics lists (with saved views) stay in the page's fallback column.
  const pathname = usePathname();
  const [nowDate] = useState(() => new Date());
  const activityFilterNow = parseActivityFilter(params.get("filter"), params.get("done"));
  const activityLists = useActivityLists(runs, search, activityFilterNow, nowDate);
  const goActivity = () => go({ view: "activity", context: null, companion: null, list: null, layout: null });
  const openWorkPath = (path: string) => {
    const url = new URL(path, window.location.href);
    const href = workTarget(
      url.pathname,
      new URLSearchParams(workHref(new URLSearchParams(window.location.search), { ...(runId ? { run: runId } : {}) }).split("?")[1]),
    );
    if (href) window.history.pushState(null, "", href);
    else router.push(path);
  };
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
                activity: runs.needs.length + runs.runs.filter((r) => r.state === "running" || r.state === "queued").length || undefined,
                tickets: openTicketsCount || undefined,
                epics: openEpicsCount || undefined,
              },
              search: { value: search, placeholder: "Filter work…" },
            },
            body: {
              ...activityNativeBody(runs, activityLists, { search, query: listQuery(params), now: nowDate }),
              hasMore: runs.hasMore && activityFilterNow === "all",
            },
            filter: activityFilterNow as ActivityFilter,
            counts: {
              all: activityLists.viewCounts.all,
              needs_you: Math.max(activityLists.viewCounts.needs_you, runs.shownNeeds.length),
              active: activityLists.viewCounts.active,
              failed: activityLists.viewCounts.failed,
            },
            selectedId: runs.shownNeeds.find((i) => i.run_id === runId && activityLists.nonRunNeeds.some((n) => n.id === i.id))
              ? `needs:${runs.shownNeeds.find((i) => i.run_id === runId)!.id}`
              : runId
                ? `run:${runId}`
                : null,
          }),
          onCommand: (cmd: NativeCommand) => {
            const handled = handleWorkHeaderCommand(cmd, {
              project,
              push: (href) => router.push(href),
              onProject: (v) => go({ project: v, ticket: null, epic: null }),
              onAgent: (v) => go({ agent: v || null }),
              onSearch: (q) => {
                setSearch(q);
                updateWorkUrl({ q: q || null }, true);
              },
              onActivity: goActivity,
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
              if (cmd.itemId === RUN_LOAD_MORE) runs.loadMore();
              else if (cmd.itemId === RUN_RETRY) runs.retry();
              else if (cmd.itemId.startsWith("run:")) openWorkPath(`/runs/${cmd.itemId.slice(4)}`);
              else if (cmd.itemId.startsWith("needs:")) {
                const item = runs.shownNeeds.find((i) => i.id === cmd.itemId.slice(6));
                if (item) openWorkPath(itemHref(item, listQuery(params)));
              }
            }
          },
        }
      : undefined;
  const nav = (
    <nav aria-label="Work" className="work-nav">
      <WorkNavHeader
        active={view}
        project={project}
        search={search}
        onSearchChange={(q) => {
          setSearch(q);
          updateWorkUrl({ q: q || null }, true);
        }}
        counts={{
          activity: runs.needs.length + runs.runs.filter((r) => r.state === "running" || r.state === "queued").length || undefined,
          tickets: openTicketsCount || undefined,
          epics: openEpicsCount || undefined,
        }}
        onActivityClick={() =>
          go({
            view: "activity",
            context: null,
            companion: null,
            list: null,
            layout: null,
          })
        }
      />
      <WorkSpacePersonaFilters
        projects={boot.data?.projects}
        agents={boot.data?.agents}
        project={project ?? ""}
        onProjectChange={(v) => go({ project: v, ticket: null, epic: null })}
        agent={agent ?? ""}
        onAgentChange={(v) => go({ agent: v || null })}
      />
      {view === "activity" ? (
        <RunList selected={runId} embedded search={search} />
      ) : (
        <div className="work-nav-list">
          {view === "tickets" && (
            <>
              <div className="work-list-controls">
                <button
                  aria-pressed={params.get("layout") !== "board"}
                  onClick={() => go({ layout: null })}
                >
                  List
                </button>
                <span>/</span>
                <button
                  aria-pressed={params.get("layout") === "board"}
                  onClick={() => go({ layout: "board" })}
                >
                  Board
                </button>
              </div>
              <WorkSavedViews />
            </>
          )}
          <LoadState query={view === "tickets" ? tickets : epics} />
          {view === "tickets" ? (
            <>
              {shownTickets.map((t) => (
                <button
                  key={t.key}
                  aria-current={ticketKey === t.key ? "page" : undefined}
                  onClick={() =>
                    go({ ticket: t.key, context: null, list: null })
                  }
                >
                  <strong>{t.title}</strong>
                  <small>
                    {t.key} ·{" "}
                    {t.unmet_dependencies ? "Blocked" : STATUS_NAME[t.status]}
                  </small>
                </button>
              ))}
              {!tickets.isPending && !shownTickets.length && (
                <p className="p-3 text-13 text-fg-tertiary">
                  No tickets match.
                </p>
              )}
            </>
          ) : (
            <>
              {shownEpics.map((e) => (
                <button
                  key={e.epic.id}
                  aria-current={epicId === e.epic.id ? "page" : undefined}
                  onClick={() =>
                    go({ epic: e.epic.id, context: null, list: null })
                  }
                >
                  <strong>{e.epic.name}</strong>
                  <small>
                    {e.counts.done} of {e.counts.total} tickets
                  </small>
                </button>
              ))}
              {!epics.isPending && !shownEpics.length && (
                <p className="p-3 text-13 text-fg-tertiary">No epics match.</p>
              )}
            </>
          )}
        </div>
      )}
    </nav>
  );
  const mobileList =
    compact &&
    (params.get("list") === "show" || (!runId && !ticketKey && !epicId));
  const mobileBrief = compact && (showBrief || mobileList);
  const activityFilter = parseActivityFilter(params.get("filter"), params.get("done"));
  const showActivityOverview = view === "activity" && !compact && !showBrief;
  return (
    <div className="work-page" onClickCapture={intercept}>
      {!compact && <NavigatorPortal native={activityNative}>{nav}</NavigatorPortal>}
      <TopBar
        crumbs={[
          { label: "Work", href: "/work" },
          { label: view[0].toUpperCase() + view.slice(1) },
        ]}
        actions={
          <>
            {compact && (
              <Button onClick={() => go({ list: "show" })}>Browse work</Button>
            )}
            {!companion && !mobileList && runs.needs.length > 0 && (
              <button
                type="button"
                onClick={() => go({ filter: "needs_you", context: null })}
                className="hidden items-center gap-1.5 rounded-md border border-pill-human-bg/80 bg-pill-human-bg px-2 py-1 text-11 font-medium text-pill-human-fg hover:brightness-105 md:inline-flex"
              >
                <span aria-hidden className="size-1.5 rounded-full bg-state-human" />
                Needs you · {runs.needs.length}
              </button>
            )}
            {!companion && !mobileList && runId && (
              <WorkTopRunLinks id={runId} context={context} navigate={go} />
            )}
          </>
        }
      />
      {mobileList && nav}
      <div
        className={cx(
          "work-body",
          companion && "work-planning",
          mobileList && "work-hidden",
        )}
      >
        {view === "activity" && (
          <div className={cx(!showActivityOverview ? "work-hidden" : "flex min-w-0 flex-1")}>
            <ActivityOverview
              project={project}
              runs={runs.runs}
              needs={runs.needs}
              selectedRunId={runId}
              filter={activityFilter}
              onSelectRun={(id) => go({ run: id })}
            />
          </div>
        )}
        <div
          className={cx(
            "work-run",
            companion && "work-run-companion",
            showActivityOverview && "work-run-panel",
            (!showRun || mobileBrief) && "work-hidden",
          )}
        >
          {runId ? (
            <LiveRun
              key={runId}
              id={runId}
              companion={companion}
              navigate={go}
            />
          ) : (
            <p className="p-8 text-13 text-fg-tertiary">
              Choose a run from Activity.
            </p>
          )}
        </div>
        {showBrief && (
          <section
            aria-label={companion ? "Focused work" : "Work context"}
            className={cx("work-details", companion && "work-primary")}
          >
            {(!companion || compact || !showRun) && (
              <div className="work-pane-header">
                <button
                  onClick={() =>
                    go({
                      view: "activity",
                      context:
                        context === "epic" && ticketKey && !compact
                          ? "ticket"
                          : null,
                      list: null,
                    })
                  }
                >
                  {compact
                    ? "‹ Back to run · draft saved"
                    : context === "epic" && ticketKey
                      ? "‹ Ticket / Epic"
                      : view === "epics"
                        ? "Epic"
                        : "Ticket"}
                </button>
                {context && (
                  <button
                    aria-label="Close context"
                    onClick={() => go({ context: null })}
                  >
                    ×
                  </button>
                )}
                {companion && !showRun && runId && (
                  <Button onClick={() => go({ companion: null })}>
                    Show run
                  </Button>
                )}
              </div>
            )}
            <div className="work-detail-scroll">
              {view === "tickets" && params.get("layout") === "board" ? (
                project ? (
                  <BoardView
                    project={project}
                    filters={{
                      assignee: agent,
                      epic: params.get("filter_epic") || undefined,
                      include_canceled: false,
                    }}
                    blockedOnly={false}
                    onOpen={(key) => go({ ticket: key, layout: null })}
                  />
                ) : (
                  <p className="p-8">Choose a space to view its board.</p>
                )
              ) : (context === "epic" || view === "epics") && epicId ? (
                <EpicBrief epicId={epicId} navigate={go} focused={companion} />
              ) : ticketKey ? (
                <TicketBrief
                  key={ticketKey}
                  ticketKey={ticketKey}
                  navigate={go}
                  focused={companion}
                />
              ) : (
                <p className="p-8 text-13 text-fg-tertiary">
                  Choose {view === "epics" ? "an epic" : "a ticket"}.
                </p>
              )}
            </div>
          </section>
        )}
      </div>
      {!compact && (
        <CompanionDock
          app="work"
          defaultOpen={false}
          tabs={[
            {
              id: "chat",
              label: "Chat",
              icon: "msg",
              content: <WorkChat subject={workSubject} />,
            },
          ]}
        />
      )}
    </div>
  );
}
