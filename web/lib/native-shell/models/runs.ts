// The Runs list as a NavModel: the standalone list (/runs) and the compact one in Work's Activity
// view (app/(app)/runs/run-list.tsx).
import type { Avatar, MenuItem, NavAction, NavItem, NavModel, NavPicker, NavSearch, Tone } from "../protocol.ts";
import { workHeader, type WorkHeaderInput } from "./work.ts";

export type RunDot = "human" | "running" | "queued" | "done" | "failed" | "idle";

const DOT_TONE: Partial<Record<RunDot, Tone>> = { human: "human", running: "done", failed: "blocked", queued: "neutral" };

export interface RunRowData {
  id: string;
  href: string;
  title: string;
  subtitle?: string;
  agentName?: string;
  trailing: string;
  dot: RunDot;
}
export interface NeedsRowData {
  id: string;
  href: string;
  title: string;
  subtitle?: string;
  agentName?: string;
  trailing: string;
  /** Blocked kinds read as failures. */
  tone: "human" | "blocked";
}
export interface RunGroupData {
  key: string;
  label: string;
  /** Shown beside the label. */
  count?: number;
  runs: RunRowData[];
}

export const RUNS_NAV_ID = "runs";
export const RUN_LOAD_MORE = "load-more";
export const RUN_RETRY = "retry";
export const RUN_HIDE_DONE = "hide-done";
export const RUN_FILTER_ACTION = "filter";
export const RUN_SEARCH = "run-search";
export const RUN_VIEW_ACTION = "view";
export const RUN_STATUS_ITEM = "status";

export const runItemId = (id: string) => `run:${id}`;
export const needsItemId = (id: string) => `needs:${id}`;

const initial = (name: string): Avatar => ({ initials: name.trim().slice(0, 1).toUpperCase() || "?" });

function runItem(r: RunRowData, withHref: boolean): NavItem {
  const item: NavItem = { id: runItemId(r.id), title: r.title, trailing: r.trailing };
  if (withHref) item.href = r.href;
  if (r.subtitle) item.subtitle = r.subtitle;
  if (r.agentName) item.avatar = initial(r.agentName);
  const tone = DOT_TONE[r.dot];
  if (tone) item.status = tone;
  return item;
}

function needsItem(n: NeedsRowData, withHref: boolean): NavItem {
  const item: NavItem = { id: needsItemId(n.id), title: n.title, trailing: n.trailing, status: n.tone };
  if (withHref) item.href = n.href;
  if (n.subtitle) item.subtitle = n.subtitle;
  if (n.agentName) item.avatar = initial(n.agentName);
  else item.icon = "inbox";
  return item;
}

export interface RunListBody {
  needs: NeedsRowData[];
  needsLabel: string;
  /** Needs you rows after the run groups (Work lists non-run items last when runs are active). */
  needsAfterGroups?: boolean;
  groups: RunGroupData[];
  loading: boolean;
  error?: string | null;
  hasMore: boolean;
  loadingMore: boolean;
  emptyText: string;
  /** Rows carry hrefs the shell opens itself (the standalone list); Work handles activation. */
  withHref: boolean;
}

function bodySections(b: RunListBody): NavModel["sections"] {
  const titled = (label: string, count?: number) => (count != null ? `${label} ${count}` : label);
  const needs: NavModel["sections"] = b.needs.length
    ? [{ id: "needs-you", title: titled(b.needsLabel, b.needs.length), items: b.needs.map((n) => needsItem(n, b.withHref)) }]
    : [];
  const tail: NavItem[] = [];
  if (b.error) tail.push({ id: RUN_RETRY, title: `Couldn’t load runs. ${b.error}`, subtitle: "Retry", icon: "refresh" });
  if (b.hasMore && !b.error && !b.loading) tail.push({ id: RUN_LOAD_MORE, title: "Load older runs", icon: "history", disabled: b.loadingMore });
  if (b.error) return [...needs, { id: "error", items: tail }];
  if (b.loading) return [...needs, { id: "loading", items: [], emptyText: "Loading" }];
  const groups = b.groups.map((g) => ({
    id: `runs-${g.key}`,
    title: titled(g.label, g.count),
    items: g.runs.map((r) => runItem(r, b.withHref)),
  }));
  if (groups.length === 0 && b.needs.length === 0) return [{ id: "empty", items: [], emptyText: b.emptyText }];
  const out = b.needsAfterGroups ? [...groups, ...needs] : [...needs, ...groups];
  if (tail.length) out.push({ id: "more", items: tail });
  return out;
}

export interface RunFilterData {
  project?: string;
  agent?: string;
  hideDone: boolean;
  projects: readonly { key: string; name: string }[];
  agents: readonly { handle: string; name: string }[];
}

/** The standalone /runs list: status line, search, a Filter menu, then the list. */
export function buildRunsNavModel(input: {
  body: RunListBody;
  filters: RunFilterData;
  search: string;
  /** "3 busy · 1 queued · 4 slots · $1.20 this week" */
  statusLine?: { text: string; href: string };
  selectedId?: string | null;
}): NavModel {
  const f = input.filters;
  const menu: MenuItem[] = [
    { id: RUN_HIDE_DONE, label: "Hide done", checked: f.hideDone },
    { id: "sep", separator: true },
    {
      id: "space-menu",
      label: "Space",
      children: [{ id: "space:", label: "All spaces", checked: !f.project }, ...f.projects.map((p) => ({ id: `space:${p.key}`, label: p.name, checked: f.project === p.key }))],
    },
    {
      id: "agent-menu",
      label: "Persona",
      children: [{ id: "agent:", label: "All personas", checked: !f.agent }, ...f.agents.map((a) => ({ id: `agent:${a.handle}`, label: a.name, checked: f.agent === a.handle }))],
    },
  ];
  const sections = bodySections(input.body);
  if (input.statusLine) {
    sections.unshift({ id: "status", items: [{ id: RUN_STATUS_ITEM, title: input.statusLine.text, href: input.statusLine.href, icon: "activity" }] });
  }
  return {
    id: RUNS_NAV_ID,
    title: "Runs",
    actions: [{ id: RUN_FILTER_ACTION, label: "Filter runs", icon: "sliders", menu }],
    search: { id: RUN_SEARCH, placeholder: "Search runs", value: input.search },
    sections,
    selectedId: input.selectedId ?? null,
  };
}

export type ActivityFilter = "all" | "needs_you" | "active" | "failed";

/** Work's Activity view: the Work header, a View menu and the compact list. */
export function buildWorkActivityNavModel(input: {
  header: WorkHeaderInput;
  body: RunListBody;
  filter: ActivityFilter;
  counts: Record<ActivityFilter, number>;
  selectedId?: string | null;
}): NavModel {
  const head = workHeader(input.header);
  const options: { value: ActivityFilter; label: string }[] = [
    { value: "all", label: "All activity" },
    { value: "needs_you", label: "Needs you" },
    { value: "active", label: "Running & queued" },
    { value: "failed", label: "Failed today" },
  ];
  const actions: NavAction[] = [
    ...head.actions,
    {
      id: RUN_VIEW_ACTION,
      label: `View: ${options.find((o) => o.value === input.filter)?.label ?? "All activity"}`,
      icon: "activity",
      menu: options.map((o) => ({ id: `view:${o.value}`, label: `${o.label} (${input.counts[o.value]})`, checked: input.filter === o.value })),
    },
  ];
  const picker: NavPicker = head.picker;
  const search: NavSearch | undefined = head.search;
  return { id: "work-activity", title: head.title, actions, picker, ...(search ? { search } : {}), sections: bodySections(input.body), selectedId: input.selectedId ?? null };
}
