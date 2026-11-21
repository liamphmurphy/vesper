// The Tickets list screen's left column (tickets/_components/tickets-screen.tsx) as a NavModel:
// the Work header, the queues, the epics and the saved views.
import type { NavItem, NavModel, NavSection } from "../protocol.ts";
import { buildSavedViewsSection, savedViewRowId, type SavedViewRow } from "./saved-views.ts";
import { workModel, type WorkHeaderInput } from "./work.ts";

export const TICKETS_NAV_ID = "tickets";
export const TICKETS_OPEN_EPICS = "tickets.open-epics";
export const TICKETS_OPEN_EPIC_DETAIL = "epic.open-detail";

export type TicketQueue = "needs_you" | "in_progress" | "ready" | "blocked" | "all";

export const ticketQueueId = (q: TicketQueue) => `queue:${q}`;
export const ticketEpicId = (id: string) => `epic:${id}`;

/** A queue row or epic row id back to what it means; null for other rows. */
export function parseTicketsRow(itemId: string): { type: "queue"; queue: TicketQueue } | { type: "epic"; id: string } | null {
  if (itemId.startsWith("queue:")) return { type: "queue", queue: itemId.slice(6) as TicketQueue };
  if (itemId.startsWith("epic:")) return { type: "epic", id: itemId.slice(5) };
  return null;
}

const QUEUES: { queue: TicketQueue; title: string; status?: NavItem["status"]; tone?: "human" | "blocked" }[] = [
  { queue: "needs_you", title: "Needs you", status: "human", tone: "human" },
  { queue: "in_progress", title: "In progress", status: "done" },
  { queue: "ready", title: "Ready to dispatch", status: "accent" },
  { queue: "blocked", title: "Blocked", status: "blocked", tone: "blocked" },
  { queue: "all", title: "All tasks", status: "neutral" },
];

export interface TicketsNavInput {
  header: Omit<WorkHeaderInput, "active">;
  counts: Record<TicketQueue, number>;
  /** The queue the URL's filters amount to; null when a saved view is open. */
  queue: TicketQueue | null;
  epics: readonly { id: string; name: string; done: number; total: number }[];
  /** The epic filter in the URL. */
  epic?: string;
  views: readonly SavedViewRow[];
  /** The open saved view. */
  viewId?: string | null;
}

export function buildTicketsNavModel(input: TicketsNavInput): NavModel {
  const sections: NavSection[] = [
    {
      id: "queues",
      title: "Queues",
      items: QUEUES.map((q) => ({
        id: ticketQueueId(q.queue),
        title: q.title,
        ...(q.status ? { status: q.status } : {}),
        ...(input.counts[q.queue] > 0 ? { badge: { text: String(input.counts[q.queue]), ...(q.tone ? { tone: q.tone } : {}) } } : {}),
      })),
    },
  ];
  if (input.epics.length) {
    sections.push({
      id: "by-epic",
      title: "By epic",
      badge: { text: String(input.epics.length) },
      actions: [{ id: TICKETS_OPEN_EPICS, label: "All epics", icon: "epics" }],
      items: input.epics.map((e) => ({
        id: ticketEpicId(e.id),
        title: e.name,
        trailing: `${e.done}/${e.total}`,
        contextMenu: [{ id: TICKETS_OPEN_EPIC_DETAIL, label: "Open epic details", icon: "epics" }],
      })),
    });
  }
  sections.push(buildSavedViewsSection(input.views));
  const selected = input.viewId ? savedViewRowId(input.viewId) : input.epic ? ticketEpicId(input.epic) : input.queue ? ticketQueueId(input.queue) : null;
  return workModel(TICKETS_NAV_ID, { ...input.header, active: "tickets" }, sections, selected);
}
