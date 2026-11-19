"use client";

import { useCompact } from "@/lib/viewport";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import { useBootstrap, useCosts, useEpicOverviews, useTickets } from "@/lib/api/hooks";
import { dueDate } from "@/lib/format";
import {
  EPIC_SORTS, HEALTH_LABEL, epicFilterQuery, filterEpics, isOverdue, parseEpicFilters, ratio, sortEpics, statusCounts, ymd,
  type EpicFilters, type EpicHealthFilter, type EpicSort, type EpicStatusFilter,
} from "@/lib/epics";
import { presetRange, spendLabel } from "@/lib/costs";
import { computeEpicPortfolioStats, computeEpicWaves } from "@/lib/work-overview";
import { Button, ButtonLink } from "@/components/ui/button";
import { DispatchDialog } from "@/components/domain/dispatch-dialog";
import { Banner, Card, EmptyState, Skeleton } from "@/components/ui/primitives";
import { Segmented } from "@/components/ui/controls";
import { StatusGlyph } from "@/components/domain/glyphs";
import { Content } from "@/components/shell/topbar";
import { CompanionDock } from "@/components/shell/companion";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { rememberProject, ProjectScopeState, useProjectScope } from "@/components/shell/project-scope";
import { HealthPill, type EpicOverview } from "@/components/domain/overview";
import { HumanAvatar } from "@/components/domain/avatars";
import { SmallPill } from "@/components/domain/labels";
import { StackedBar } from "@/components/domain/data";
import { cx } from "@/lib/cx";
import { FilterMenu } from "@/components/domain/pickers";
import { ticketsHref } from "@/lib/tickets-layout";
import { buildEpicsNavModel, EPICS_HEALTH_FILTER, EPICS_STATUS_FILTER } from "@/lib/native-shell/models/epics";
import { STATUS_NAME } from "@/components/domain/meta";
import { epicHealthTone, ticketStatusTone } from "@/lib/native-shell/models/common";
import { buildEpicsOverviewInspectorSections } from "@/lib/native-shell/models/epic-inspector";
import { handleWorkHeaderCommand } from "@/lib/native-shell/models/work";
import { TicketsTopBar } from "./layout-bar";

function Timeline({
  epics,
  onSelect,
}: {
  epics: EpicOverview[];
  onSelect: (id: string) => void;
}) {
  const now = new Date();
  const [quarter, setQuarter] = useState(
    () => now.getFullYear() * 4 + Math.floor(now.getMonth() / 3),
  );
  const year = Math.floor(quarter / 4),
    month = (quarter % 4) * 3;
  const start = new Date(year, month, 1),
    end = new Date(year, month + 3, 1),
    span = end.getTime() - start.getTime();
  const at = (iso: string) => new Date(`${iso}T00:00:00`).getTime();
  const visible = epics.filter(
    (e) =>
      e.start_date &&
      e.target_date &&
      at(e.start_date) < end.getTime() &&
      at(e.target_date) + 86400000 > start.getTime(),
  );
  const today = ((now.getTime() - start.getTime()) / span) * 100;
  return (
    <Card
      title={`Q${(quarter % 4) + 1} ${year} timeline`}
      action={
        <div className="flex gap-1">
          <Button
            variant="ghost"
            aria-label="Previous quarter"
            onClick={() => setQuarter(quarter - 1)}
          >
            ←
          </Button>
          <Button
            variant="ghost"
            onClick={() =>
              setQuarter(now.getFullYear() * 4 + Math.floor(now.getMonth() / 3))
            }
          >
            Today
          </Button>
          <Button
            variant="ghost"
            aria-label="Next quarter"
            onClick={() => setQuarter(quarter + 1)}
          >
            →
          </Button>
        </div>
      }
      bodyClassName="p-0"
    >
      {visible.length ? (
        <div className="overflow-x-auto">
          <div className="min-w-[600px] px-4 pb-4">
            <div className="grid grid-cols-[180px_1fr] border-b border-border-subtle">
              <span className="py-3 text-12 text-fg-tertiary">Epic</span>
              <div className="grid grid-cols-3">
                {[0, 1, 2].map((i) => (
                  <span
                    key={i}
                    className="border-l border-border-subtle px-3 py-3 text-12 text-fg-tertiary"
                  >
                    {new Date(year, month + i, 1).toLocaleDateString(
                      undefined,
                      { month: "long" },
                    )}
                  </span>
                ))}
              </div>
            </div>
            {visible.map((e) => {
              const left = Math.max(
                0,
                ((at(e.start_date!) - start.getTime()) / span) * 100,
              );
              const right = Math.min(
                100,
                ((at(e.target_date!) + 86400000 - start.getTime()) / span) *
                  100,
              );
              return (
                <div
                  key={e.epic.id}
                  className="grid min-h-[46px] grid-cols-[180px_1fr] border-b border-border-subtle last:border-0"
                >
                  <button
                    onClick={() => onSelect(e.epic.id)}
                    className="truncate pr-3 text-left text-13 hover:text-accent"
                  >
                    {e.epic.name}
                  </button>
                  <div className="relative my-1.5 grid grid-cols-3">
                    {[0, 1, 2].map((i) => (
                      <span key={i} className="border-l border-border-subtle" />
                    ))}
                    {today >= 0 && today <= 100 && (
                      <span
                        aria-label="Today"
                        className="pointer-events-none absolute inset-y-[-6px] z-10 w-px bg-accent"
                        style={{ left: `${today}%` }}
                      />
                    )}
                    <button
                      onClick={() => onSelect(e.epic.id)}
                      title={`${e.epic.name}: ${dueDate(e.start_date!)} – ${dueDate(e.target_date!)}`}
                      aria-label={`${e.epic.name}, ${e.start_date} to ${e.target_date}`}
                      className="absolute inset-y-1 overflow-hidden rounded-md border px-2 text-left text-11"
                      style={{
                        left: `${left}%`,
                        width: `${Math.max(0.5, right - left)}%`,
                        borderColor: `color-mix(in srgb, ${e.project.color} 40%, transparent)`,
                        background: `color-mix(in srgb, ${e.project.color} 15%, var(--surface))`,
                      }}
                    >
                      <span className="whitespace-nowrap">{e.epic.name}</span>
                    </button>
                  </div>
                </div>
              );
            })}
          </div>
        </div>
      ) : (
        <p className="p-5 text-14 text-fg-tertiary">
          No epics are scheduled in this quarter.
        </p>
      )}
      {epics.some((e) => !e.start_date || !e.target_date) && (
        <p className="border-t border-border-subtle px-5 py-3 text-12 text-fg-tertiary">
          {epics.filter((e) => !e.start_date || !e.target_date).length} epics
          have no complete schedule.
        </p>
      )}
    </Card>
  );
}

/**
 * One epic as a row in the chat look: health dot, name and objective, a
 * progress bar (done, running, still open) with points, criteria, open
 * tickets, owner and target. The name is a stretched link to the epic.
 */
export function EpicRow({ epic: e, today }: { epic: EpicOverview; today: string }) {
  const { epic, counts } = e;
  const pct = Math.round(ratio(epic.points_done, epic.points_total) * 100);
  const overdue = isOverdue(e, today);
  const running = counts.in_progress + counts.in_review;
  const open = counts.todo + counts.backlog;
  return (
    <article aria-label={epic.name} className="group relative flex items-center gap-4 rounded-lg px-3 py-2.5 hover:bg-row-hover max-md:flex-wrap">
      <span aria-hidden title={HEALTH_LABEL[epic.health]} className={cx("size-2 flex-none rounded-full", HEALTH_DOT[epic.health])} />
      <span className="flex min-w-0 flex-1 flex-col gap-0.5">
        <span className="flex min-w-0 items-center gap-2">
          {/* The stretched link makes the whole row open the epic. */}
          <Link href={`/epics/${epic.id}`} className="truncate text-14 font-medium text-fg after:absolute after:inset-0 after:rounded-lg">
            {epic.name}
          </Link>
          {epic.status === "done" && <SmallPill tone="done">Done</SmallPill>}
          <HealthPill health={epic.health} />
        </span>
        <span className="truncate text-12 text-fg-tertiary">
          {e.project.name} · {e.objective || "No objective yet."}
        </span>
      </span>
      <span className="flex w-[220px] flex-none flex-col gap-1 max-md:w-full">
        <span role="progressbar" aria-label={`Progress for ${epic.name}`} aria-valuemin={0} aria-valuemax={counts.total || 1} aria-valuenow={counts.done}>
          <StackedBar segments={[
            { value: counts.done, label: "done", color: "var(--state-done)" },
            { value: running, label: "running", color: "var(--state-progress)" },
            { value: open, label: "open", color: "var(--track)" },
          ]} />
        </span>
        <span className="flex justify-between gap-2 font-mono text-11 text-fg-tertiary">
          <span>{epic.points_total ? `${epic.points_done} / ${epic.points_total} pts · ${pct}%` : "No estimates yet"}</span>
          <span title="Epic acceptance criteria">{epic.criteria_total ? `${epic.criteria_done} / ${epic.criteria_total} met` : epic.status === "open" ? <span className="text-pill-human-fg">No criteria</span> : "None yet"}</span>
        </span>
      </span>
      <span className="w-[96px] flex-none text-12 text-fg-secondary"><span className="font-mono text-fg">{epic.tickets_open}</span> open tickets</span>
      <span className="flex w-[120px] flex-none items-center gap-2 truncate text-12 text-fg-secondary">
        {e.owner ? <><HumanAvatar name={e.owner.name} initials={e.owner.initials} color={e.owner.avatar_color} src={e.owner.avatar_url} />{e.owner.name}</>
          : <span className="text-fg-tertiary">No owner</span>}
      </span>
      <span className={cx("w-[120px] flex-none text-right text-12 max-md:text-left", overdue ? "text-pill-blocked-fg" : "text-fg-tertiary")}>
        {e.target_date ? `${overdue ? "Overdue ·" : "Target"} ${dueDate(e.target_date)}` : "No target date"}
      </span>
    </article>
  );
}

const HEALTH_OPTIONS: EpicHealthFilter[] = ["any", "on_track", "at_risk", "off_track"];
const HEALTH_DOT: Record<Exclude<EpicHealthFilter, "any">, string> = {
  on_track: "bg-state-done", at_risk: "bg-state-human", off_track: "bg-state-blocked",
};

function groupEpicsBySpace(list: readonly EpicOverview[]) {
  const groups = new Map<string, { label: string; epics: EpicOverview[] }>();
  for (const e of list) {
    const k = e.project.key;
    const existing = groups.get(k);
    if (existing) existing.epics.push(e);
    else groups.set(k, { label: e.project.name, epics: [e] });
  }
  return [...groups.entries()];
}

export function EpicsScreen() {
  const boot = useBootstrap();
  const query = useEpicOverviews();
  const params = useSearchParams(),
    router = useRouter();
  // The layout bar's picker sets ?project=; none (All projects) lists every epic.
  const scope = useProjectScope("optional");
  const current = scope.status === "ready" ? scope.project : undefined;
  const project = current?.key ?? "";
  const legacy = params.get("epic");
  // Old links (/epics?epic=…) open the detail page.
  useEffect(() => {
    if (legacy) router.replace(`/epics/${encodeURIComponent(legacy)}`);
  }, [legacy, router]);
  const compact = useCompact();
  const filters = parseEpicFilters(params);
  const setFilters = (patch: Partial<EpicFilters>, nextProject = project) =>
    router.replace(ticketsHref("epics", new URLSearchParams(epicFilterQuery({ ...filters, ...patch }, nextProject))), { scroll: false });
  const [search, setSearch] = useState("");
  const [selectedEpicId, setSelectedEpicId] = useState<string | null>(null);
  const [openCount, setOpenCount] = useState(0);
  const openEpic = (id: string) => {
    setSelectedEpicId(id);
    setOpenCount((n) => n + 1);
  };
  const [dispatchKeys, setDispatchKeys] = useState<string[] | null>(null);
  const inProject = (query.data ?? []).filter((e) => !project || e.project.key === project);
  const counts = statusCounts(inProject);
  const filtered = sortEpics(filterEpics(inProject, filters), filters.sort);
  const shown = search
    ? filtered.filter((e) => e.epic.name.toLowerCase().includes(search.toLowerCase()))
    : filtered;
  const activeFeaturedEpic = selectedEpicId
    ? inProject.find((e) => e.epic.id === selectedEpicId)
    : shown[0];
  const selectedEpic = selectedEpicId
    ? inProject.find((e) => e.epic.id === selectedEpicId)
    : undefined;
  const featuredTicketsQuery = useTickets(
    { epic: activeFeaturedEpic?.epic.id, view: "all" },
    !!activeFeaturedEpic?.epic.id,
  );
  const [now] = useState(() => new Date());
  const [range30d] = useState(() => presetRange(30, now));
  const costs = useCosts({ ...range30d, project: project || undefined }).data;
  const featuredWaves = activeFeaturedEpic
    ? computeEpicWaves(featuredTicketsQuery.data ?? activeFeaturedEpic.tickets)
    : [];
  const featuredReadyKeys = featuredWaves.flatMap((w) => w.readyTickets.map((t) => t.key));
  const portfolioStats = computeEpicPortfolioStats(
    inProject,
    activeFeaturedEpic
      ? new Map([[activeFeaturedEpic.epic.id, featuredWaves]])
      : new Map(),
  );
  const epicsBySpace = groupEpicsBySpace(shown);
  const atRiskCount = inProject.filter(
    (e) => e.epic.status === "open" && (e.epic.health === "at_risk" || e.epic.health === "off_track"),
  ).length;
  const today = ymd(new Date());
  return (
    <>
      <NavigatorPortal
        native={{
          model: buildEpicsNavModel({
            header: {
              project: project || undefined,
              projects: boot.data?.projects,
              counts: { epics: counts.open || undefined },
              hideNewTicket: true,
              search: { value: search, placeholder: "Filter epics…" },
            },
            status: filters.status,
            counts,
            health: filters.health,
            healthOptions: HEALTH_OPTIONS.map((h) => ({ value: h, label: h === "any" ? "Any" : HEALTH_LABEL[h] })),
            atRiskCount,
            groups: epicsBySpace.map(([key, g]) => ({
              key,
              label: g.label,
              epics: g.epics.map((e) => ({ id: e.epic.id, name: e.epic.name, health: e.epic.health, done: e.counts.done, total: e.counts.total })),
            })),
            selectedEpicId: activeFeaturedEpic?.epic.id,
            loading: query.isLoading,
          }),
          onCommand: (cmd) => {
            const handled = handleWorkHeaderCommand(cmd, {
              project: project || undefined,
              push: (href) => router.push(href),
              onProject: (v) => {
                if (!v) rememberProject(null);
                setFilters({}, v);
              },
              onAgent: () => {},
              onSearch: setSearch,
            });
            if (handled) return;
            if (cmd.type === "nav.filter") {
              if (cmd.filterId === EPICS_STATUS_FILTER) setFilters({ status: cmd.value as EpicFilters["status"] });
              else if (cmd.filterId === EPICS_HEALTH_FILTER) setFilters({ health: cmd.value as EpicHealthFilter });
            } else if (cmd.type === "nav.activate") openEpic(cmd.itemId);
          },
        }}
      />
      {!compact && selectedEpic && (
        <CompanionDock
          app="epics-list"
          show={{ tab: "context", n: openCount }}
          tabs={[
            {
              id: "context",
              label: "Context",
              icon: "sidebar",
              native: {
                kind: "native",
                sections: buildEpicsOverviewInspectorSections({
                  epicId: selectedEpic.epic.id,
                  name: selectedEpic.epic.name,
                  projectName: selectedEpic.project.name,
                  healthLabel: HEALTH_LABEL[selectedEpic.epic.health],
                  healthTone: epicHealthTone(selectedEpic.epic.health),
                  status: selectedEpic.epic.status,
                  doneCount: selectedEpic.counts.done,
                  totalCount: selectedEpic.counts.total,
                  pointsDone: selectedEpic.epic.points_done,
                  pointsTotal: selectedEpic.epic.points_total,
                  ownerName: selectedEpic.owner?.name ?? "Unassigned",
                  targetDate: selectedEpic.target_date ? dueDate(selectedEpic.target_date) : "No target date",
                  objective: selectedEpic.objective,
                  tickets: ((selectedEpic.epic.id === activeFeaturedEpic?.epic.id ? featuredTicketsQuery.data : undefined) ?? selectedEpic.tickets).map((t) => ({
                    key: t.key,
                    title: t.title,
                    statusLabel: STATUS_NAME[t.status] ?? t.status,
                    statusTone: ticketStatusTone(t.status),
                  })),
                }),
                onAction: (actionId) => {
                  if (actionId === "open_epic") router.push(`/epics/${encodeURIComponent(selectedEpic.epic.id)}`);
                },
              },
            },
            { id: "chat", label: "Chat", icon: "msg", native: { kind: "companion" } },
          ]}
        />
      )}
      <TicketsTopBar
        layout="epics"
        action={{ label: "New ticket", primary: true, href: project ? `/tickets/new?project=${encodeURIComponent(project)}` : "/tickets/new" }}
      />
      <Content>
        <div className="space-y-6">
          {scope.status !== "ready" ? (
            <ProjectScopeState base="/tickets" scope={scope} />
          ) : query.isError ? (
            <Banner
              tone="blocked"
              title="Couldn’t load epics"
              actions={<Button onClick={() => query.refetch()}>Retry</Button>}
            >
              {query.error.message}
            </Banner>
          ) : query.isLoading || legacy ? (
            <div aria-busy="true" className="space-y-2">
              {[0, 1, 2].map((i) => <Skeleton key={i} className="h-12 rounded-lg" />)}
            </div>
          ) : !inProject.length ? (
            <EmptyState icon="epics" title="No epics here yet">
              Epics and their objectives will appear here once they’re created.
            </EmptyState>
          ) : (
            <>
              <div className="flex flex-wrap items-center gap-3">
                {compact && (
                  <>
                    <Segmented<EpicStatusFilter>
                      label="Epic status"
                      value={filters.status}
                      onChange={(status) => setFilters({ status })}
                      options={(["open", "done", "all"] as const).map((s) => ({
                        value: s,
                        label: <>{s === "open" ? "Open" : s === "done" ? "Done" : "All"} <span className="font-mono text-fg-tertiary">{counts[s]}</span></>,
                      }))}
                    />
                    <div role="radiogroup" aria-label="Health" className="flex flex-wrap items-center gap-1.5">
                      <span className="text-12 text-fg-tertiary">Health</span>
                      {HEALTH_OPTIONS.map((h) => (
                        <button key={h} type="button" role="radio" aria-checked={filters.health === h} onClick={() => setFilters({ health: h })}
                          className={cx("flex h-7 items-center gap-1.5 rounded-full border px-3 text-12",
                            filters.health === h ? "border-border-strong bg-selected text-fg" : "border-border text-fg-secondary hover:text-fg")}>
                          {h !== "any" && <span aria-hidden className={cx("size-2 rounded-full", HEALTH_DOT[h])} />}
                          {h === "any" ? "Any" : HEALTH_LABEL[h]}
                        </button>
                      ))}
                    </div>
                  </>
                )}
                <span className="ml-auto font-mono text-12 text-fg-tertiary" role="status">{shown.length} {shown.length === 1 ? "epic" : "epics"}</span>
                <span className="flex items-center gap-2 text-12 text-fg-secondary">
                  Sort
                  <FilterMenu label="Sort epics" value={filters.sort} onChange={(v) => setFilters({ sort: v as EpicSort })}
                    options={(Object.keys(EPIC_SORTS) as EpicSort[]).map((s) => ({ value: s, label: EPIC_SORTS[s] }))} />
                </span>
              </div>
              {shown.length > 0 && (
                <div className="work-kpi-grid" role="region" aria-label="Epics portfolio">
                  <div className="work-kpi-card">
                    <span className="text-11 text-fg-tertiary">Open epics</span>
                    <span className="font-mono text-20 font-semibold text-fg tabular-nums">
                      {portfolioStats.openCount}
                    </span>
                    <span className="text-11 text-fg-tertiary">
                      {atRiskCount > 0 ? `${atRiskCount} need attention` : "All on track"}
                    </span>
                  </div>
                  <div className="work-kpi-card">
                    <span className="text-11 text-fg-tertiary">Portfolio progress</span>
                    <span className="font-mono text-20 font-semibold text-fg tabular-nums">
                      {portfolioStats.progressPct}%
                    </span>
                    <span className="text-11 text-fg-tertiary">
                      {portfolioStats.pointsDone} / {portfolioStats.pointsTotal} pts done
                    </span>
                  </div>
                  <div className="work-kpi-card">
                    <span className="text-11 text-fg-tertiary">Execution waves</span>
                    <span className="font-mono text-20 font-semibold text-fg tabular-nums">
                      {featuredWaves.length}
                    </span>
                    <span className="text-11 text-fg-tertiary">
                      {featuredReadyKeys.length} ready to start
                    </span>
                  </div>
                  <div className="work-kpi-card">
                    <span className="text-11 text-fg-tertiary">30-day spend</span>
                    <span className="font-mono text-20 font-semibold text-fg tabular-nums">
                      {costs ? spendLabel(costs.total.cost_micros, costs.unpriced_runs) : "–"}
                    </span>
                    <span className="text-11 text-fg-tertiary">
                      {costs ? `${costs.total.runs} runs in window` : "Active workspace"}
                    </span>
                  </div>
                </div>
              )}

              {activeFeaturedEpic && featuredWaves.length > 0 && (
                <section
                  aria-label="Epic execution waves"
                  className="flex flex-col gap-3 rounded-xl border border-border-subtle bg-surface p-4"
                >
                  <div className="flex flex-wrap items-center justify-between gap-3">
                    <div className="flex min-w-0 flex-wrap items-center gap-2">
                      <span className="text-10 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">
                        Execution plan
                      </span>
                      <Link
                        href={`/epics/${encodeURIComponent(activeFeaturedEpic.epic.id)}`}
                        className="truncate text-14 font-semibold text-fg hover:text-accent"
                      >
                        {activeFeaturedEpic.epic.name}
                      </Link>
                      <HealthPill health={activeFeaturedEpic.epic.health} />
                    </div>
                    <div className="flex items-center gap-2">
                      {featuredReadyKeys.length > 0 && (
                        <Button
                          variant="primary"
                          icon="play"
                          className="h-7 px-2.5 text-12"
                          onClick={() => setDispatchKeys(featuredReadyKeys)}
                        >
                          Start {featuredReadyKeys.length} ready
                        </Button>
                      )}
                      <ButtonLink
                        href={`/tickets?layout=board&project=${encodeURIComponent(activeFeaturedEpic.project.key)}&epic=${encodeURIComponent(activeFeaturedEpic.epic.id)}`}
                        variant="outline"
                        className="h-7 px-2.5 text-12"
                      >
                        Board →
                      </ButtonLink>
                    </div>
                  </div>
                  <div className="grid grid-cols-1 gap-2.5 md:grid-cols-2 lg:grid-cols-3">
                    {featuredWaves.map((w) => (
                      <div
                        key={w.wave}
                        className={cx(
                          "flex flex-col gap-1.5 rounded-lg border p-2.5",
                          w.status === "current"
                            ? "border-accent/40 bg-surface-raised"
                            : "border-border-subtle bg-surface-sunken/60",
                        )}
                      >
                        <div className="flex items-center justify-between gap-2 text-11">
                          <span className="font-semibold text-fg">Wave {w.wave}</span>
                          <span
                            className={cx(
                              "rounded px-1.5 py-[1px] font-mono text-10 uppercase",
                              w.status === "done"
                                ? "bg-state-done/15 text-state-done"
                                : w.status === "current"
                                  ? "bg-accent-soft text-accent"
                                  : "text-fg-tertiary",
                            )}
                          >
                            {w.status}
                          </span>
                        </div>
                        <ul className="flex flex-col gap-1">
                          {w.tickets.map((t) => (
                            <li key={t.id}>
                              <Link
                                href={`/tickets/${t.key}`}
                                className="flex items-center gap-1.5 rounded px-1.5 py-1 text-12 hover:bg-hover"
                              >
                                <StatusGlyph state={t.status} />
                                <span className="flex-none font-mono text-11 text-fg-tertiary">
                                  {t.key}
                                </span>
                                <span className="min-w-0 flex-1 truncate text-fg">
                                  {t.title}
                                </span>
                                {t.estimate_points != null && (
                                  <span className="flex-none font-mono text-10 text-fg-tertiary">
                                    {t.estimate_points}p
                                  </span>
                                )}
                              </Link>
                            </li>
                          ))}
                        </ul>
                      </div>
                    ))}
                  </div>
                </section>
              )}

              {shown.length ? (
                <section aria-label={`Epics, ${shown.length}`}>
                  <h2 className="flex h-8 items-center gap-2 px-3 text-11 font-medium uppercase tracking-[0.06em] text-fg-tertiary">
                    Epics <span className="font-mono">{shown.length}</span>
                  </h2>
                  {shown.map((e) => <EpicRow key={e.epic.id} epic={e} today={today} />)}
                </section>
              ) : (
                <EmptyState icon="epics" title="No epics match"
                  actions={<Button onClick={() => setFilters({ status: "all", health: "any" })}>Clear filters</Button>}>
                  No {filters.status === "all" ? "" : `${filters.status} `}epics{filters.health === "any" ? "" : ` are ${HEALTH_LABEL[filters.health].toLowerCase()}`}.
                </EmptyState>
              )}
              <Timeline epics={shown} onSelect={(id) => router.push(`/epics/${id}`)} />
              {dispatchKeys && dispatchKeys.length > 0 && (
                <DispatchDialog
                  keys={dispatchKeys}
                  open
                  onOpenChange={(open) => {
                    if (!open) setDispatchKeys(null);
                  }}
                />
              )}
            </>
          )}
        </div>
      </Content>
    </>
  );
}
