"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { workSettingsHref } from "@/lib/spaces";
import { DropdownMenu } from "radix-ui";
import { useEffect, useMemo, useRef, useState, useSyncExternalStore, type MouseEvent } from "react";
import { cx } from "@/lib/cx";
import { useCompact } from "@/lib/viewport";
import type { TicketStatus, TicketSummary } from "@/lib/api/client";
import {
  useBulkEach,
  useBootstrap,
  useEpicOverviews,
  useInbox,
  useSavedViews,
  useTickets,
  type TicketView,
} from "@/lib/api/hooks";
import { filterText, needsYouByTicket, resolveFilter, ticketNeedsYou, withoutProjectToken, workGroups, type WorkGroup } from "@/lib/work-rows";
import { computeSidebarEpics, computeTaskQueueCounts } from "@/lib/work-overview";
import {
  GROUPS,
  GROUP_NAME,
  viewQuery,
  applyLocalFilters,
  moveFocus,
  parseGroup,
  rangeKeys,
  type BulkResult,
} from "@/lib/ticket-list";
import { Button, ButtonLink } from "@/components/ui/button";
import { DispatchDialog } from "@/components/domain/dispatch-dialog";
import { Tabs } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, FilterChip, Kbd, Skeleton } from "@/components/ui/primitives";
import { UnassignedAvatar } from "@/components/domain/avatars";
import { WorkPersonaAvatar } from "@/components/domain/work-persona-avatar";
import { PriorityGlyph } from "@/components/domain/glyphs";
import { PRIORITY_NAME } from "@/components/domain/meta";
import { floatPanel } from "@/components/domain/pickers";
import { SavedViewHeader, SavedViewNativeDialogs, SavedViewTabs, savedViewSubtitle, useSavedViewsNav, useSavedViewsUi } from "@/components/domain/saved-views";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { rememberProject, ProjectScopeState, projectCrumbs, useProjectScope } from "@/components/shell/project-scope";
import { ticketsHref } from "@/lib/tickets-layout";
import type { NativeCommand } from "@/lib/native-shell/protocol";
import {
  buildTicketsNavModel,
  parseTicketsRow,
  TICKETS_OPEN_EPIC_DETAIL,
  TICKETS_OPEN_EPICS,
  type TicketQueue,
} from "@/lib/native-shell/models/tickets";
import { buildTicketsListExtras, parseTicketsListAction } from "@/lib/native-shell/models/tickets-toolbar";
import { handleWorkHeaderCommand } from "@/lib/native-shell/models/work";
import { BulkBar, BulkResultPanel } from "./bulk-bar";
import { CompactTicketRow, TicketRow, type Density } from "./ticket-row";
import { ChipScroller, TicketsTopBar } from "./layout-bar";

const VIEWS: Array<{ key: TicketView; label: string }> = [
  { key: "all", label: "All tickets" },
  { key: "active", label: "Active" },
  { key: "backlog", label: "Backlog" },
];

// Density is a per-browser preference, not part of the URL or a saved view.
const DENSITY_KEY = "la:tickets-density";
const DENSITY_EVENT = "la:tickets-density";
function readDensity(): Density {
  try {
    return window.localStorage.getItem(DENSITY_KEY) === "compact" ? "compact" : "comfortable";
  } catch {
    return "comfortable";
  }
}
function subscribeDensity(cb: () => void) {
  window.addEventListener("storage", cb);
  window.addEventListener(DENSITY_EVENT, cb);
  return () => {
    window.removeEventListener("storage", cb);
    window.removeEventListener(DENSITY_EVENT, cb);
  };
}
function setDensity(d: Density) {
  try {
    window.localStorage.setItem(DENSITY_KEY, d);
  } catch {
    /* Storage unavailable: the choice lasts until reload. */
  }
  window.dispatchEvent(new Event(DENSITY_EVENT));
}

function isTyping(el: EventTarget | null) {
  if (!(el instanceof HTMLElement)) return false;
  if (el instanceof HTMLInputElement && ["checkbox", "radio", "button", "submit", "reset"].includes(el.type)) return false;
  return el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName) || el.getAttribute("role") === "combobox";
}

function ListSkeleton() {
  return (
    <div aria-busy="true" aria-label="Loading tickets" className="px-3 pt-4">
      {[0, 1].map((g) => (
        <div key={g} className="mb-5">
          <Skeleton className="mx-3 mb-2 h-2.5 w-24" />
          {[0.6, 0.45, 0.7, 0.5].map((w, i) => (
            <div key={i} className="flex h-11 items-center gap-3 px-3">
              <Skeleton className="size-3.5 rounded-full" />
              <Skeleton className="h-3 w-16" />
              <Skeleton className="h-3" style={{ width: `${w * 50}%` }} />
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

/** The group's quiet uppercase label: Needs you, a status bucket, or the group-by's value. */
function GroupLabel({ g }: { g: WorkGroup }) {
  if (g.needs || g.by === "status") return <span className={g.needs ? "text-pill-human-fg" : undefined}>{g.title}</span>;
  if (g.by === "priority") {
    const p = g.id as TicketSummary["priority"];
    return (
      <>
        <PriorityGlyph priority={p} label={false} />
        <span>{PRIORITY_NAME[p]}</span>
      </>
    );
  }
  if (g.by === "epic") {
    return (
      <>
        <Icon name="epics" size={12} />
        <span>{g.id === "none" ? "No epic" : g.name}</span>
      </>
    );
  }
  const a = g.tickets[0]?.assignee;
  return a ? (
    <>
      <WorkPersonaAvatar agent={a} size="sm" />
      <span>{a.name}</span>
    </>
  ) : (
    <>
      <UnassignedAvatar />
      <span>Unassigned</span>
    </>
  );
}

function groupLabelText(g: WorkGroup) {
  if (g.needs || g.by === "status") return g.title;
  if (g.by === "priority") return PRIORITY_NAME[g.id as TicketSummary["priority"]];
  if (g.id === "none") return g.by === "epic" ? "No epic" : "Unassigned";
  return g.name;
}

/** Composer link that starts a ticket in this group. */
function newInGroup(g: WorkGroup, project?: string) {
  const p = new URLSearchParams();
  if (project) p.set("project", project);
  if (g.by === "status" && !g.needs) p.set("status", g.id === "done_week" ? "done" : g.id);
  return `/tickets/new${p.size ? `?${p}` : ""}`;
}

export function TicketsScreen() {
  const params = useSearchParams();
  const router = useRouter();
  const project = params.get("project") ?? undefined;
  const view = (params.get("view") as TicketView) ?? "all";
  const assignee = params.get("assignee") ?? undefined;
  const q = params.get("q") ?? "";
  const epic = params.get("epic") ?? undefined;
  const status = (params.get("status") as TicketStatus) ?? undefined;
  const ready = params.get("ready") === "true";
  const blockedOnly = params.get("blocked") === "true";
  const unestimated = params.get("unestimated") === "true";
  const group = parseGroup(params.get("group"));
  const svId = params.get("sv");
  const compact = useCompact();
  const density = useSyncExternalStore(subscribeDensity, readDensity, () => "comfortable" as Density);

  const boot = useBootstrap();
  // The filter box shows the URL's epic, agent and status as tokens, then the search.
  // project: tokens move the project picker, which shows the project.
  const urlText = filterText({ epic: epic && (boot.data?.epics.find((e) => e.id === epic)?.name ?? epic), agent: assignee, status, q });
  const [search, setSearch] = useState(urlText);
  // Opening a saved view (or Discard) changes the URL from outside the box; the
  // box's own debounced writes (pushedText) must not overwrite what's typed since.
  const [seenText, setSeenText] = useState(urlText);
  // Matches once: after the URL catches up, a later return to the same text (Back) must reset the box.
  const [pushedText, setPushedText] = useState<string | null>(null);
  if (urlText !== seenText) {
    setSeenText(urlText);
    if (urlText !== pushedText) setSearch(urlText);
    setPushedText(null);
  }
  const lookups = useMemo(
    () => ({ projects: boot.data?.projects ?? [], epics: boot.data?.epics ?? [], agents: boot.data?.agents ?? [], currentEpic: epic }),
    [boot.data, epic],
  );
  const bootReady = !!boot.data;
  const resolved = useMemo(() => resolveFilter(search, lookups), [search, lookups]);
  const each = useBulkEach();
  // No ?project= resolves to the remembered project; "All spaces" leaves it empty.
  const scope = useProjectScope("optional");
  const list = useTickets({ ready, project, view, status, assignee, epic, q: q || undefined });
  const baseList = useTickets({ project, assignee, view: "all" });
  const epicsQuery = useEpicOverviews();
  const savedViews = useSavedViews();
  const [dispatchKeys, setDispatchKeys] = useState<string[] | null>(null);
  const savedView = svId ? savedViews.data?.find((v) => v.id === svId) : undefined;
  const svUi = useSavedViewsUi();

  // Debounced box → URL, so views are shareable. Tokens that match nothing aren't applied.
  useEffect(() => {
    if (search === urlText || !bootReady) return;
    const id = setTimeout(() => {
      const r = resolveFilter(search, lookups);
      const epicName = r.epic && lookups.epics.find((e) => e.id === r.epic)?.name;
      setPushedText(filterText({ epic: epicName, agent: r.assignee, status: r.status, q: r.q }));
      // project: moves the picker, which then shows it; the token leaves the box so it can't reapply later.
      if (r.project) setSearch(withoutProjectToken(search));
      replaceParams((next) => {
        if (r.project) next.set("project", r.project);
        for (const [k, v] of [["epic", r.epic], ["assignee", r.assignee], ["status", r.status], ["q", r.q]] as const) {
          if (v) next.set(k, v);
          else next.delete(k);
        }
      });
    }, 250);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search, bootReady]);

  function replaceParams(edit: (p: URLSearchParams) => void) {
    // From the live URL, not this render's params: a debounced write that fires after a
    // navigation committed must not put back filters (or the project) from before it.
    const next = new URLSearchParams(window.location.search);
    edit(next);
    router.replace(`/tickets${next.size ? `?${next}` : ""}`);
  }
  function setParam(k: string, v: string | null) {
    replaceParams((next) => (v ? next.set(k, v) : next.delete(k)));
  }
  // The queues in the sidebar, as the web's rows and the native sidebar's both set them.
  function selectQueue(queue: TicketQueue) {
    replaceParams((next) => {
      next.delete("sv");
      if (queue === "needs_you" || queue === "in_progress") {
        next.set("view", queue === "needs_you" ? "needs_human" : "active");
        next.delete("ready");
        next.delete("blocked");
      } else if (queue === "ready") {
        next.set("view", "all");
        next.set("ready", "true");
        next.delete("blocked");
      } else if (queue === "blocked") {
        next.set("view", "all");
        next.set("blocked", "true");
        next.delete("ready");
      } else {
        next.delete("view");
        next.delete("ready");
        next.delete("blocked");
        next.delete("epic");
      }
    });
  }
  function toggleEpic(id: string) {
    replaceParams((next) => {
      if (epic === id) next.delete("epic");
      else next.set("epic", id);
      next.delete("sv");
    });
  }
  function pickProject(v: string) {
    const key = v || null;
    if (!key) rememberProject(null);
    router.push(ticketsHref("list", { ...(key ? { project: key } : {}), ...(view && view !== "all" ? { view } : {}) }));
  }
  const href = (v: TicketView) => {
    const next = new URLSearchParams(params);
    next.set("view", v);
    return `/tickets?${next}`;
  };

  const tickets = useMemo(() => applyLocalFilters(list.data ?? [], { blocked: blockedOnly, unestimated }), [list.data, blockedOnly, unestimated]);
  // Tickets whose run waits on the person, from the same queue as the Inbox.
  const inbox = useInbox(project);
  const needs = useMemo(() => needsYouByTicket(inbox.data), [inbox.data]);
  const queueCounts = useMemo(
    () => computeTaskQueueCounts(baseList.data ?? list.data ?? [], inbox.data ?? []),
    [baseList.data, list.data, inbox.data],
  );
  const sidebarEpics = useMemo(
    () => computeSidebarEpics(epicsQuery.data ?? [], project),
    [epicsQuery.data, project],
  );
  const readyKeys = useMemo(
    () =>
      tickets
        .filter((t) => t.status === "todo" && t.unmet_dependencies === 0 && !!t.assignee)
        .map((t) => t.key),
    [tickets],
  );
  const groups = useMemo(() => workGroups(tickets, needs, group), [tickets, needs, group]);
  const flat = useMemo(() => groups.flatMap((g) => g.tickets.map((t) => t.key)), [groups]);

  // Selection (x, Shift+x, shift-click ranges) and the j/k cursor, keyed by ticket key.
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [focused, setFocused] = useState<string | null>(null);
  const anchor = useRef<string | null>(null);
  const [result, setResult] = useState<BulkResult | null>(null);
  const visible = useMemo(() => new Set(flat), [flat]);
  const selectedKeys = flat.filter((k) => selected.has(k));

  function toggleKey(key: string, range: boolean) {
    const next = new Set(selected);
    if (range && anchor.current) {
      for (const k of rangeKeys(flat, anchor.current, key)) next.add(k);
    } else if (next.has(key)) next.delete(key);
    else next.add(key);
    anchor.current = key;
    setSelected(next);
  }
  function toggle(t: TicketSummary, e: MouseEvent<HTMLInputElement>) {
    toggleKey(t.key, e.shiftKey);
    setFocused(t.key);
  }

  // Latest state for the keyboard handler without re-subscribing every render.
  const keyState = useRef({ flat, focused, toggleKey, router });
  useEffect(() => {
    keyState.current = { flat, focused, toggleKey, router };
  });
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.metaKey || e.ctrlKey || e.altKey || isTyping(e.target) || document.querySelector('[role="dialog"], [role="menu"]')) return;
      const s = keyState.current;
      if (e.key === "Escape") {
        setSelected(new Set());
        anchor.current = null;
        return;
      }
      if (e.key === "j" || e.key === "k") {
        e.preventDefault();
        const next = moveFocus(s.flat, s.focused && s.flat.includes(s.focused) ? s.focused : null, e.key === "j" ? 1 : -1);
        setFocused(next);
        if (next) document.querySelector(`[data-ticket-row="${CSS.escape(next)}"]`)?.scrollIntoView({ block: "nearest" });
        return;
      }
      if ((e.key === "x" || e.key === "X") && s.focused && s.flat.includes(s.focused)) {
        e.preventDefault();
        s.toggleKey(s.focused, e.shiftKey);
        return;
      }
      if (e.key === "Enter" && s.focused && s.flat.includes(s.focused) && !(e.target instanceof HTMLButtonElement || e.target instanceof HTMLAnchorElement)) {
        e.preventDefault();
        s.router.push(`/tickets/${s.focused}`);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  async function applyBulk(patch: Parameters<typeof each.mutateAsync>[0]["patch"], label: string) {
    const keys = [...selectedKeys];
    try {
      const outcome = await each.mutateAsync({ keys, patch });
      onResult({ label, ...outcome });
    } catch (error) {
      onResult({ label, updated: [], failed: keys.map((key) => ({ key, status: 0, message: error instanceof Error ? error.message : String(error) })) });
    }
  }

  function onResult(r: BulkResult) {
    setResult(r);
    // Only the failed tickets stay selected, so they can be retried or opened.
    setSelected(new Set(r.failed.map((f) => f.key)));
    anchor.current = null;
  }
  // A clean result dismisses itself.
  useEffect(() => {
    if (!result || result.failed.length) return;
    const id = setTimeout(() => setResult(null), 5000);
    return () => clearTimeout(id);
  }, [result]);

  const proj = boot.data?.projects.find((p) => p.key === project);
  const crumbs = projectCrumbs(proj, "Tickets");
  if (savedView) {
    crumbs[crumbs.length - 1] = { ...crumbs[crumbs.length - 1], href: `/tickets${project ? `?project=${encodeURIComponent(project)}` : ""}` };
    crumbs.push({ label: savedView.name });
  }
  // Archived projects keep their read-only history (banner below); unknown keys and redirects don't list.
  const blocked = scope.status !== "ready" && !(scope.status === "unavailable" && scope.archived);
  const projectEpics = (boot.data?.epics ?? []).filter((e) => !proj || e.project_id === proj.id);
  const filtered = !!(q || assignee || status || blockedOnly || unestimated || epic || ready);
  const allSelected = flat.length > 0 && selectedKeys.length === flat.length;

  // The list's filters: in the bar beside the views when wide, one sideways-scrolling line of chips when compact.
  const chipH = compact ? "h-[32px]" : "h-[26px]";
  const filterBox = (
    <div className={cx("relative flex min-w-0 flex-col", compact ? "w-[260px]" : "w-[340px] max-lg:w-[260px]")}>
      <label className={`flex ${chipH} items-center gap-1.5 rounded-md border border-border-strong bg-surface-sunken px-2 text-12 text-fg-tertiary focus-within:border-accent`}>
        <Icon name="search" size={12} />
        <span className="sr-only">Filter tickets</span>
        <input
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Filter… project: epic: persona: status:"
          aria-describedby={resolved.unknown.length ? "ticket-filter-unknown" : undefined}
          className="min-w-0 flex-1 bg-transparent text-fg-2 outline-none placeholder:text-fg-tertiary"
        />
        {search && (
          <button type="button" aria-label="Clear filter" onClick={() => setSearch("")} className="text-fg-tertiary hover:text-fg">
            <Icon name="x" size={12} />
          </button>
        )}
      </label>
      {resolved.unknown.length > 0 && (
        <span id="ticket-filter-unknown" role="status" className="absolute left-0 top-full z-20 mt-1 whitespace-nowrap rounded-md border border-border-float bg-surface-raised px-2 py-1 text-12 text-pill-blocked-fg shadow-sm">
          No match for {resolved.unknown.join(", ")}
        </span>
      )}
    </div>
  );
  const onlyChips = (
    <>
      {blockedOnly && <FilterChip label="Only" value="Blocked ×" onClick={() => setParam("blocked", null)} title="Clear blocked filter" />}
      {unestimated && <FilterChip label="Only" value="Unestimated ×" onClick={() => setParam("unestimated", null)} title="Clear unestimated filter" />}
    </>
  );
  const filterControls = (
    <>
      <button type="button" aria-pressed={ready} className={cx(`${chipH} rounded-sm border border-border-strong px-2 text-12 hover:bg-hover`, ready && "bg-selected text-accent")} onClick={() => replaceParams((next) => { if (ready) next.delete("ready"); else { next.set("ready", "true"); next.set("view", "all"); } })}>Ready to dispatch</button>
      {readyKeys.length > 0 && !proj?.archived && (
        <Button
          variant="outline"
          icon="play"
          className={cx(chipH, "px-2.5 text-12 font-medium text-accent border-accent/45")}
          onClick={() => setDispatchKeys(readyKeys)}
        >
          Start ready ({readyKeys.length})
        </Button>
      )}
      {onlyChips}
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button
            type="button"
            aria-label={`Group by ${GROUP_NAME[group]}`}
            className={cx(`inline-flex ${chipH} items-center overflow-hidden rounded-sm border text-12 hover:bg-hover`, group === "status" ? "border-border-strong" : "border-accent/55")}
          >
            <span className="flex h-full items-center border-r border-border-strong px-2 text-fg-tertiary">Group</span>
            <span className="flex items-center gap-1 px-2 text-fg">
              {GROUP_NAME[group]}
              <Icon name="chev" size={12} className="text-fg-secondary" />
            </span>
          </button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content align="end" sideOffset={6} className={cx(floatPanel, "w-[200px]")}>
            <DropdownMenu.Label className="px-2 pb-1 pt-1.5 text-12 text-fg-tertiary">Group by</DropdownMenu.Label>
            <DropdownMenu.RadioGroup value={group} onValueChange={(g) => setParam("group", g === "status" ? null : g)}>
              {GROUPS.map((g) => (
                <DropdownMenu.RadioItem key={g} value={g} className="flex h-[30px] cursor-default select-none items-center rounded-md px-2 outline-none data-[highlighted]:bg-hover">
                  {GROUP_NAME[g]}
                  <DropdownMenu.ItemIndicator className="ml-auto text-accent">
                    <Icon name="check" size={14} strokeWidth={1.8} />
                  </DropdownMenu.ItemIndicator>
                </DropdownMenu.RadioItem>
              ))}
            </DropdownMenu.RadioGroup>
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
    </>
  );

  // The native sidebar's version of the column below: the same state and handlers, driven by the shell's commands.
  const savedNav = useSavedViewsNav({ ui: svUi, current: viewQuery(new URLSearchParams(params.toString())), project });
  const activeQueue: TicketQueue | null = svId
    ? null
    : view === "needs_human"
      ? "needs_you"
      : view === "active"
        ? "in_progress"
        : ready
          ? "ready"
          : blockedOnly
            ? "blocked"
            : view === "all" && !epic
              ? "all"
              : null;
  const nativeModel = buildTicketsNavModel({
    header: {
      project,
      projects: boot.data?.projects,
      agents: boot.data?.agents,
      agent: assignee ?? "",
      counts: { tickets: queueCounts.all || undefined },
      hideNewTicket: true,
      search: { value: search, placeholder: "Filter tasks… epic: persona:" },
    },
    counts: { needs_you: queueCounts.needs_you, in_progress: queueCounts.in_progress, ready: queueCounts.ready, blocked: queueCounts.blocked, all: queueCounts.all },
    queue: activeQueue,
    epics: sidebarEpics,
    epic,
    views: savedNav.rows,
    viewId: svId,
  });
  const nativeCommand = (cmd: NativeCommand) => {
    if (handleWorkHeaderCommand(cmd, { project, push: (href) => router.push(href), onProject: pickProject, onAgent: (v) => setParam("assignee", v || null), onSearch: setSearch })) return;
    if (savedNav.handle(cmd)) return;
    if (cmd.type === "nav.action") {
      if (cmd.actionId === TICKETS_OPEN_EPICS) {
        router.push(ticketsHref("epics", project ? { project } : undefined));
      } else if (cmd.actionId === TICKETS_OPEN_EPIC_DETAIL && cmd.itemId?.startsWith("epic:")) {
        router.push(`/epics/${encodeURIComponent(cmd.itemId.slice(5))}`);
      }
      return;
    }
    if (cmd.type === "nav.activate") {
      const row = parseTicketsRow(cmd.itemId);
      if (row?.type === "queue") selectQueue(row.queue);
      else if (row?.type === "epic") toggleEpic(row.id);
    }
  };

  return (
    <>
      <SavedViewNativeDialogs ui={svUi} />
      <NavigatorPortal native={{ model: nativeModel, onCommand: nativeCommand }} />
      <TicketsTopBar
        layout="list"
        // The project crumb is the bar's project pill.
        crumbs={proj ? crumbs.slice(1) : crumbs}
        subtitle={savedView ? savedViewSubtitle(savedView, new URLSearchParams(params.toString())) : undefined}
        action={
          proj?.archived
            ? { label: "Open the space", href: workSettingsHref(proj), primary: false }
            : { label: "New ticket", href: `/tickets/new${project ? `?project=${project}` : ""}`, primary: true }
        }
        extra={buildTicketsListExtras({
          readyCount: proj?.archived ? 0 : readyKeys.length,
          group,
          groups: GROUPS.map((g) => ({ value: g, label: GROUP_NAME[g] })),
          density,
        })}
        onExtra={(id, menuId) => {
          const a = parseTicketsListAction(id, menuId);
          if (a?.type === "startReady") setDispatchKeys(readyKeys);
          else if (a?.type === "group") setParam("group", a.value === "status" ? null : a.value);
          else if (a?.type === "density") setDensity(a.value);
        }}
      />
      {proj?.archived && <div className="px-6 py-3 max-md:px-4"><Banner tone="human" title="Archived work">Tickets and history remain available. Restore the work on the space’s page to start new work.</Banner></div>}
      {compact ? (
        <ChipScroller label="Filters">
          {filterBox}
          <Tabs label="Views" value={svId ? "" : view} items={VIEWS.map((v) => ({ ...v, href: href(v.key) }))} />
          <SavedViewTabs project={project} />
          {filterControls}
        </ChipScroller>
      ) : (
        // The filter box is the sidebar's search, group and density are toolbar items; what's left is what can't be one.
        (blockedOnly || unestimated || resolved.unknown.length > 0) && (
          <div className="flex flex-wrap items-center gap-2 border-b border-border-subtle px-6 py-2">
            {onlyChips}
            {resolved.unknown.length > 0 && <span role="status" className="text-12 text-pill-blocked-fg">No match for {resolved.unknown.join(", ")}</span>}
          </div>
        )
      )}

      {savedView && <SavedViewHeader view={savedView} />}

      {blocked ? (
        <ProjectScopeState base="/tickets" scope={scope} />
      ) : list.isError ? (
        <div className="p-6">
          <Banner tone="blocked" title="Couldn't load tickets">
            {list.error.message}
          </Banner>
        </div>
      ) : list.isPending ? (
        <ListSkeleton />
      ) : tickets.length === 0 ? (
        <EmptyState
          icon="tickets"
          title={filtered ? "No tickets match" : "No tickets in this view"}
          actions={<ButtonLink href="/tickets/new" variant="outline" icon="plus">New ticket</ButtonLink>}
        >
          {filtered ? "Try a different search or clear a filter." : "Tickets you create, or that agents open as follow-ups, will appear here."}
        </EmptyState>
      ) : compact ? (
        <div className="pb-8 pt-2">
          {groups.map((g) => (
            <section
              key={`${g.by}:${g.id}`}
              aria-label={`${groupLabelText(g)}, ${g.tickets.length}`}
              className={cx("mb-3", g.needs && "mx-3 rounded-xl border border-border bg-surface-raised py-1 shadow-sm")}
            >
              <h2 className={cx("flex h-8 items-center gap-2 text-11 font-medium uppercase tracking-[0.06em] text-fg-tertiary", g.needs ? "px-3" : "px-4")}>
                <GroupLabel g={g} />
                <span className="font-mono">{g.tickets.length}</span>
                <span className="flex-1" />
                {g.points > 0 && <span className="whitespace-nowrap normal-case tracking-normal">{g.points} pts</span>}
              </h2>
              {g.tickets.map((t) => (
                <CompactTicketRow key={t.id} t={t} needs={ticketNeedsYou(t, needs.get(t.key))} />
              ))}
            </section>
          ))}
        </div>
      ) : (
        <div className="overflow-x-auto pb-32">
          <div className="min-w-[760px] px-3 pt-3">
            <div className="flex h-7 items-center gap-3 border-b border-border-subtle px-3 text-10 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">
              <input
                type="checkbox"
                aria-label={allSelected ? "Clear selection" : "Select all tickets"}
                checked={allSelected}
                ref={(el) => {
                  if (el) el.indeterminate = selectedKeys.length > 0 && !allSelected;
                }}
                onChange={() => setSelected(allSelected ? new Set() : new Set(flat))}
                className="size-3.5 flex-none accent-[var(--accent)]"
              />
              <span className="w-3.5 flex-none" aria-hidden />
              <span className="w-[72px] flex-none">Key ({tickets.length})</span>
              <span className="min-w-0 flex-1">Task</span>
              <span className="w-[220px] flex-none max-lg:w-[150px]">State</span>
              {density !== "compact" && <span className="hidden w-[68px] flex-none lg:block">Crit</span>}
              <span className="w-8 flex-none text-center">Pts</span>
              {group !== "epic" && <span className="hidden w-[150px] flex-none md:block">Epic</span>}
              <span className="w-6 flex-none text-center">Own</span>
              <span className="w-[44px] flex-none text-right">Act</span>
            </div>
            {groups.map((g) => (
              <section
                key={`${g.by}:${g.id}`}
                aria-label={`${groupLabelText(g)}, ${g.tickets.length}`}
                className={cx("group/section mb-4", g.needs && "rounded-xl border border-border bg-surface-raised p-1 shadow-sm")}
              >
                <h2 className="flex h-8 items-center gap-2 px-3 text-11 font-medium uppercase tracking-[0.06em] text-fg-tertiary">
                  <GroupLabel g={g} />
                  <span className="font-mono">{g.tickets.length}</span>
                  <span className="flex-1" />
                  {g.criteriaTotal > 0 && (
                    <span className="font-mono normal-case tracking-normal" title="Criteria done in this group">
                      {g.criteriaDone}/{g.criteriaTotal}
                    </span>
                  )}
                  {g.points > 0 && (
                    <span className="whitespace-nowrap normal-case tracking-normal" title="Estimated points in this group">
                      {g.points} pts
                    </span>
                  )}
                  {!g.needs && (
                    <ButtonLink
                      href={newInGroup(g, project)}
                      variant="ghost"
                      icon="plus"
                      aria-label={`New ticket in ${groupLabelText(g)}`}
                      className="h-6 px-1.5 text-fg-tertiary"
                    />
                  )}
                </h2>
                {g.tickets.map((t) => (
                  <TicketRow
                    key={t.id}
                    t={t}
                    needs={ticketNeedsYou(t, needs.get(t.key))}
                    selected={selected.has(t.key)}
                    focused={focused === t.key}
                    density={density}
                    showEpic={group !== "epic"}
                    onSelect={(e) => toggle(t, e)}
                    onFocusRow={() => setFocused(t.key)}
                    onStart={proj?.archived ? undefined : (ticket) => setDispatchKeys([ticket.key])}
                  />
                ))}
              </section>
            ))}
          </div>
        </div>
      )}

      {result && (
        <BulkResultPanel
          result={result}
          raised={selectedKeys.length > 0}
          onSelectFailed={() => setSelected(new Set(result.failed.map((f) => f.key).filter((k) => visible.has(k))))}
          onDismiss={() => setResult(null)}
        />
      )}
      {selectedKeys.length > 0 && boot.data && (
        <>
          <BulkBar keys={selectedKeys} agents={boot.data.agents} epics={projectEpics} onClear={() => setSelected(new Set())} onApply={applyBulk} saving={each.isPending} />
          <p aria-hidden className="pointer-events-none fixed bottom-1 left-1/2 z-40 hidden -translate-x-1/2 whitespace-nowrap text-12 text-fg-tertiary md:block">
            <Kbd>x</Kbd> select · <Kbd>Shift+x</Kbd> range · <Kbd>j</Kbd>/<Kbd>k</Kbd> move · <Kbd>Enter</Kbd> open · <Kbd>Esc</Kbd> clear
          </p>
        </>
      )}
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
  );
}
