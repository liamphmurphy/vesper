// The header actions of the ticket page, the epic page and the Work screen as native toolbar items.
// Pure: the screens act on the decoded press. Ids are the protocol between builder and parser.
import type { ToolbarItem } from "../protocol.ts";

// The ticket page: spend, the place among its siblings, previous, next, copy link.

export interface TicketToolbarInput {
  /** All-time spend label (the web's cost chip); absent when there is none. */
  cost?: string;
  pager?: { index: number; total: number };
  hasPrev: boolean;
  hasNext: boolean;
  copied: boolean;
}

export function buildTicketToolbar(i: TicketToolbarInput): ToolbarItem[] {
  const items: ToolbarItem[] = [];
  if (i.cost) items.push({ id: "ticket.cost", label: i.cost, kind: "button", icon: "dollar", showsLabel: true });
  if (i.pager && i.pager.total > 0 && i.pager.index >= 0) {
    items.push({ id: "ticket.pager", label: `${i.pager.index + 1} / ${i.pager.total}`, kind: "button", showsLabel: true, disabled: true });
  }
  items.push(
    // The icon set has no left or right arrow that points the right way, so these are text.
    { id: "ticket.prev", label: "← Previous (K)", kind: "button", showsLabel: true, disabled: !i.hasPrev },
    { id: "ticket.next", label: "Next (J) →", kind: "button", showsLabel: true, disabled: !i.hasNext },
    { id: "ticket.copy", label: i.copied ? "Link copied" : "Copy link", kind: "button", icon: i.copied ? "check" : "link" },
  );
  return items;
}

export type TicketToolbarAction = "cost" | "prev" | "next" | "copy";
const TICKET: Record<string, TicketToolbarAction> = { "ticket.cost": "cost", "ticket.prev": "prev", "ticket.next": "next", "ticket.copy": "copy" };
export const parseTicketToolbarAction = (itemId: string): TicketToolbarAction | null => TICKET[itemId] ?? null;

// The epic page.

export const EPIC_BOARD = "epic.board";
export const buildEpicToolbar = (): ToolbarItem[] => [{ id: EPIC_BOARD, label: "View on board", kind: "button", icon: "board", showsLabel: true }];

// The Work screen: what needs you, and the open run's links.

export interface WorkToolbarInput {
  /** Runs waiting on the person, shown only when the page has no companion pane. */
  needs: number;
  run?: { ticketKey?: string | null; epic?: { id: string; name: string } | null; context: string | null };
}

export function buildWorkToolbar(i: WorkToolbarInput): ToolbarItem[] {
  const items: ToolbarItem[] = [];
  if (i.needs > 0) items.push({ id: "work.needs", label: `Needs you · ${i.needs}`, kind: "button", icon: "inbox", showsLabel: true, accent: true });
  const r = i.run;
  if (r) {
    if (r.ticketKey) items.push({ id: "work.ticket", label: r.ticketKey, kind: "button", icon: "tickets", showsLabel: true });
    if (r.epic) items.push({ id: "work.epic", label: r.epic.name, kind: "button", icon: "epics", showsLabel: true });
    if (r.ticketKey) items.push({ id: "work.details", label: "Details", kind: "toggle", icon: "sidebar", showsLabel: true, on: r.context === "ticket" });
    items.push({ id: "work.run", label: "Run details", kind: "button", icon: "expand", showsLabel: true });
  }
  return items;
}

export type WorkToolbarAction = "needs" | "ticket" | "epic" | "details" | "run";
export const parseWorkToolbarAction = (itemId: string): WorkToolbarAction | null =>
  itemId.startsWith("work.") && ["needs", "ticket", "epic", "details", "run"].includes(itemId.slice(5)) ? (itemId.slice(5) as WorkToolbarAction) : null;
