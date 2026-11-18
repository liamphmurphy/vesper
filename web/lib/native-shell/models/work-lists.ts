// The Work screen's Tickets and Epics lists (work/work-screen.tsx, opened with a ticket or epic
// beside them) as NavModels: the Work header, a List/Board choice for tickets, the saved views and
// the rows.
import type { NavFilterMenu, NavItem, NavModel, NavSection, Tone } from "../protocol.ts";
import { buildSavedViewsSection, type SavedViewRow } from "./saved-views.ts";
import { workModel, type WorkHeaderInput } from "./work.ts";

export const WORK_LAYOUT_FILTER = "work-layout";
export const workTicketId = (key: string) => `ticket:${key}`;
export const workEpicId = (id: string) => `epic:${id}`;

const STATUS_TONE: Record<string, Tone> = { todo: "neutral", in_progress: "accent", in_review: "warning", done: "done" };

export function buildWorkTicketsNavModel(input: {
  header: Omit<WorkHeaderInput, "active">;
  board: boolean;
  tickets: readonly { key: string; title: string; status: string; blocked: boolean }[];
  statusNames: Record<string, string>;
  views: readonly SavedViewRow[];
  loading?: boolean;
  selectedKey?: string;
}): NavModel {
  const layout: NavFilterMenu = {
    id: WORK_LAYOUT_FILTER,
    label: "Layout",
    icon: "board",
    options: [
      { value: "list", label: "List", checked: !input.board },
      { value: "board", label: "Board", checked: input.board },
    ],
  };
  const model = workModel(
    "work-tickets",
    { ...input.header, active: "tickets" },
    [
      buildSavedViewsSection(input.views),
      {
        id: "tickets",
        title: "Tickets",
        items: input.tickets.map((t): NavItem => ({
          id: workTicketId(t.key),
          title: t.title,
          subtitle: `${t.key} · ${t.blocked ? "Blocked" : (input.statusNames[t.status] ?? t.status)}`,
          ...(t.blocked ? { status: "blocked" as const } : STATUS_TONE[t.status] ? { status: STATUS_TONE[t.status] } : {}),
        })),
        ...(input.loading ? {} : { emptyText: "No tickets match." }),
      },
    ],
    input.selectedKey ? workTicketId(input.selectedKey) : null,
  );
  model.filters = [...model.filters!, layout];
  return model;
}

export function buildWorkEpicsNavModel(input: {
  header: Omit<WorkHeaderInput, "active">;
  epics: readonly { id: string; name: string; done: number; total: number }[];
  loading?: boolean;
  selectedId?: string;
}): NavModel {
  const sections: NavSection[] = [
    {
      id: "epics",
      title: "Epics",
      items: input.epics.map((e) => ({ id: workEpicId(e.id), title: e.name, subtitle: `${e.done} of ${e.total} tickets` })),
      ...(input.loading ? {} : { emptyText: "No epics match." }),
    },
  ];
  return workModel("work-epics", { ...input.header, active: "epics" }, sections, input.selectedId ? workEpicId(input.selectedId) : null);
}
