/**
 * Tickets shows one project's work three ways: the list, the board and the
 * epics. The layout is ?layout= on /tickets; the list is the default and
 * leaves it out, so existing /tickets links stay the list.
 */

export const TICKETS_PRIMARY_LAYOUTS = ["list", "board"] as const;
export const TICKETS_LAYOUTS = ["list", "board", "epics"] as const;
export type TicketsLayout = (typeof TICKETS_LAYOUTS)[number];

export const TICKETS_LAYOUT_LABEL: Record<TicketsLayout, string> = { list: "List", board: "Board", epics: "Epics" };

export function ticketsLayout(param: string | null | undefined): TicketsLayout {
  return (TICKETS_LAYOUTS as readonly string[]).includes(param ?? "") ? (param as TicketsLayout) : "list";
}

/** /tickets in a layout with these params; any layout already in them is replaced. */
export function ticketsHref(layout: TicketsLayout, params?: URLSearchParams | Record<string, string | undefined>): string {
  const next = new URLSearchParams();
  if (layout !== "list") next.set("layout", layout);
  const entries = params instanceof URLSearchParams ? [...params] : Object.entries(params ?? {});
  for (const [k, v] of entries) if (k !== "layout" && v) next.set(k, v);
  const qs = next.toString();
  return qs ? `/tickets?${qs}` : "/tickets";
}

/**
 * Filters every layout understands survive a switch; the rest (a list view,
 * the board's map tab, an open ticket) belong to the layout they were set in.
 * Epics lists every epic, so an epic filter doesn't carry into it.
 */
const SHARED: Record<TicketsLayout, string[]> = {
  list: ["project", "epic", "assignee"],
  board: ["project", "epic", "assignee"],
  epics: ["project"],
};

export function layoutSwitchHref(layout: TicketsLayout, current: URLSearchParams): string {
  return ticketsHref(layout, Object.fromEntries(SHARED[layout].map((k) => [k, current.get(k) ?? undefined])));
}
