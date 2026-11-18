// The Work navigator's shared header (WorkNavHeader + the Space/Persona filters in
// app/(app)/work/work-nav-header.tsx) as NavModel parts, used by the Activity, Tasks, Epics and
// Board screens. Pure: the screens add their own sections.
import { ticketsHref } from "../../tickets-layout.ts";
import type { NativeCommand, NavAction, NavFilterMenu, NavModel, NavPicker, NavSearch } from "../protocol.ts";

export type WorkTab = "activity" | "tickets" | "epics";

export const WORK_NEW_TICKET_ACTION = "new-ticket";
export const WORK_SPACE_FILTER = "filter-space";
export const WORK_AGENT_FILTER = "filter-agent";
export const WORK_VIEW_PICKER = "work-view";
export const WORK_SEARCH = "work-search";

export interface WorkHeaderInput {
  active: WorkTab;
  project?: string;
  projects?: readonly { key: string; name: string; archived?: boolean }[];
  agents?: readonly { handle: string; name: string }[];
  /** Selected persona handle ("" for all). */
  agent: string;
  /** Offer "All spaces" (Board has no all-spaces view). */
  allowAllProjects?: boolean;
  counts?: { activity?: number; tickets?: number; epics?: number };
  /** A detail screen shows no Space or Persona filters. */
  noFilters?: boolean;
  /** Epics has no Persona filter. */
  noPersona?: boolean;
  /** The screen's toolbar carries New ticket, so the sidebar header doesn't. */
  hideNewTicket?: boolean;
  /** Present when the screen has a filter box. */
  search?: { value: string; placeholder: string };
}

export interface WorkHeader {
  title: string;
  actions: NavAction[];
  filters: NavFilterMenu[];
  picker: NavPicker;
  search?: NavSearch;
}

export function workTabHref(tab: WorkTab, project?: string): string {
  if (tab === "activity") return project ? `/work?view=activity&project=${encodeURIComponent(project)}` : "/work";
  return ticketsHref(tab === "tickets" ? "list" : "epics", project ? { project } : undefined);
}

export const workNewTicketHref = (project?: string) => (project ? `/tickets/new?project=${encodeURIComponent(project)}` : "/tickets/new");

const withCount = (label: string, n?: number) => (n != null && n > 0 ? `${label} ${n}` : label);

export function workHeader(input: WorkHeaderInput): WorkHeader {
  const space: NavFilterMenu["options"] = [
    ...(input.allowAllProjects === false ? [] : [{ value: "", label: "All spaces", checked: !input.project }]),
    ...(input.projects ?? []).filter((p) => !p.archived).map((p) => ({ value: p.key, label: p.name, checked: input.project === p.key })),
  ];
  const persona: NavFilterMenu["options"] = [
    { value: "", label: "All personas", checked: !input.agent },
    ...(input.agents ?? []).map((a) => ({ value: a.handle, label: a.name, checked: input.agent === a.handle })),
  ];
  const header: WorkHeader = {
    title: "Work",
    actions: input.hideNewTicket ? [] : [{ id: WORK_NEW_TICKET_ACTION, label: "New ticket", icon: "plus", accent: true }],
    filters: [
      ...(input.noFilters ? [] : [{ id: WORK_SPACE_FILTER, label: "Space", icon: "briefcase", options: space }]),
      ...(input.noPersona || input.noFilters ? [] : [{ id: WORK_AGENT_FILTER, label: "Persona", icon: "agents", options: persona }]),
    ],
    picker: {
      id: WORK_VIEW_PICKER,
      value: input.active,
      options: [
        { value: "activity", label: withCount("Activity", input.counts?.activity) },
        { value: "tickets", label: withCount("Tasks", input.counts?.tickets) },
        { value: "epics", label: withCount("Epics", input.counts?.epics) },
      ],
    },
  };
  if (input.search) header.search = { id: WORK_SEARCH, placeholder: input.search.placeholder, value: input.search.value };
  return header;
}

/** A model with the shared header and the screen's sections. */
export function workModel(id: string, input: WorkHeaderInput, sections: NavModel["sections"], selectedId?: string | null): NavModel {
  return { id, ...workHeader(input), sections, selectedId: selectedId ?? null };
}

export interface WorkCommandContext {
  project?: string;
  push: (href: string) => void;
  onProject: (key: string) => void;
  onAgent: (handle: string) => void;
  onSearch?: (value: string) => void;
  /** Overrides navigating to Activity (the Work screen switches its own view). */
  onActivity?: () => void;
}

/** Handles the header's commands; returns whether it did. */
export function handleWorkHeaderCommand(cmd: NativeCommand, ctx: WorkCommandContext): boolean {
  if (cmd.type === "nav.action") {
    if (cmd.actionId === WORK_NEW_TICKET_ACTION) ctx.push(workNewTicketHref(ctx.project));
    else return false;
    return true;
  }
  if (cmd.type === "nav.filter") {
    if (cmd.filterId === WORK_SPACE_FILTER) ctx.onProject(cmd.value);
    else if (cmd.filterId === WORK_AGENT_FILTER) ctx.onAgent(cmd.value);
    else return false;
    return true;
  }
  if (cmd.type === "nav.picker" && cmd.pickerId === WORK_VIEW_PICKER) {
    if (cmd.value === "activity" && ctx.onActivity) ctx.onActivity();
    else ctx.push(workTabHref(cmd.value as WorkTab, ctx.project));
    return true;
  }
  if (cmd.type === "nav.search" && cmd.searchId === WORK_SEARCH && ctx.onSearch) {
    ctx.onSearch(cmd.value);
    return true;
  }
  return false;
}
