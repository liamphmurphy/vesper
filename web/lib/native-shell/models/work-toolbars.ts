// The header actions of the ticket page and the epic page as native toolbar items.
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
