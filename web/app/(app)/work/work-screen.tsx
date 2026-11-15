"use client";

import { useRouter, useSearchParams } from "next/navigation";
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
import { useCompact } from "@/lib/viewport";
import { cx } from "@/lib/cx";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { useClaimCompanion } from "@/components/shell/companion";
import { TopBar } from "@/components/shell/topbar";
import { useProjectScope } from "@/components/shell/project-scope";
import { STATUS_NAME } from "@/components/domain/meta";
import { Button } from "@/components/ui/button";
import { WorkSavedViews } from "./work-saved-views";
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
import { RunList, useRunList } from "../runs/run-list";
import { ticketsHref } from "@/lib/tickets-layout";
import "./work.css";

export function WorkScreen() {
  useClaimCompanion();
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
  return (
    <div className="work-page" onClickCapture={intercept}>
      {!compact && <NavigatorPortal>{nav}</NavigatorPortal>}
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
        <div
          className={cx(
            "work-run",
            companion && "work-run-companion",
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
    </div>
  );
}
