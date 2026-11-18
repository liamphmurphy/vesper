// The Tickets header (tickets/_components/layout-bar.tsx: the project pill, the List/Board/Epics
// switch and the primary action) as native toolbar items. Pure: the screen adds its own items
// (group by, density, board toggles) and acts on the decoded press. Ids are the protocol between
// the builder and the parser.
import { TICKETS_LAYOUTS, TICKETS_LAYOUT_LABEL, type TicketsLayout } from "../../tickets-layout.ts";
import type { MenuItem, ToolbarItem } from "../protocol.ts";

export const TT = { space: "tickets.space", layout: "tickets.layout", action: "tickets.action" } as const;

const LAYOUT_ICON: Record<TicketsLayout, string> = { list: "tickets", board: "board", epics: "epics" };

export interface TicketsToolbarInput {
  /** The project picker as the project-picker model builds it; its label reads "Space: Name". */
  space: { label: string; menu: MenuItem[] };
  layout: TicketsLayout;
  /** The layout's primary action: New ticket, or Open the space for an archived one. */
  action?: { label: string; primary: boolean };
  /** Items between the space and the layout (the screen's own). */
  extra?: ToolbarItem[];
}

export function buildTicketsToolbar(i: TicketsToolbarInput): ToolbarItem[] {
  const items: ToolbarItem[] = [
    { id: TT.space, label: i.space.label.replace(/^Space: /, ""), kind: "menu", icon: "folder", showsLabel: true, placement: "leading", menu: i.space.menu },
    ...(i.extra ?? []),
    {
      id: TT.layout, label: TICKETS_LAYOUT_LABEL[i.layout], kind: "menu", icon: LAYOUT_ICON[i.layout], showsLabel: true,
      menu: TICKETS_LAYOUTS.map((l) => ({ id: `layout:${l}`, label: TICKETS_LAYOUT_LABEL[l], icon: LAYOUT_ICON[l], checked: l === i.layout })),
    },
  ];
  if (i.action) items.push({ id: TT.action, label: i.action.label, kind: "button", icon: i.action.primary ? "plus" : "gear", showsLabel: true, accent: i.action.primary });
  return items;
}

export type TicketsToolbarAction =
  | { type: "space"; menuItemId: string }
  | { type: "layout"; layout: TicketsLayout }
  | { type: "action" };

/** What a press of one of buildTicketsToolbar's own items means; null for the screen's extras. */
export function parseTicketsToolbarAction(itemId: string, menuItemId?: string): TicketsToolbarAction | null {
  if (itemId === TT.space) return menuItemId ? { type: "space", menuItemId } : null;
  if (itemId === TT.action) return { type: "action" };
  if (itemId === TT.layout && menuItemId?.startsWith("layout:")) {
    const layout = menuItemId.slice(7);
    return (TICKETS_LAYOUTS as readonly string[]).includes(layout) ? { type: "layout", layout: layout as TicketsLayout } : null;
  }
  return null;
}

// The Tickets list's own items.

export const TL = { startReady: "list.start-ready", group: "list.group", density: "list.density" } as const;

export function buildTicketsListExtras(i: {
  readyCount: number;
  group: string;
  groups: readonly { value: string; label: string }[];
  density: "comfortable" | "compact";
}): ToolbarItem[] {
  const items: ToolbarItem[] = [];
  if (i.readyCount > 0) items.push({ id: TL.startReady, label: `Start ready (${i.readyCount})`, kind: "button", icon: "play", showsLabel: true });
  items.push(
    {
      id: TL.group, label: `Group: ${i.groups.find((g) => g.value === i.group)?.label ?? i.group}`, kind: "menu", icon: "sliders", showsLabel: true,
      menu: i.groups.map((g) => ({ id: `group:${g.value}`, label: g.label, checked: g.value === i.group })),
    },
    {
      id: TL.density, label: "Density", kind: "menu", icon: "sidebar",
      menu: [
        { id: "density:comfortable", label: "Comfortable rows", checked: i.density === "comfortable" },
        { id: "density:compact", label: "Compact rows", checked: i.density === "compact" },
      ],
    },
  );
  return items;
}

export type TicketsListAction = { type: "startReady" } | { type: "group"; value: string } | { type: "density"; value: "comfortable" | "compact" };

export function parseTicketsListAction(itemId: string, menuItemId?: string): TicketsListAction | null {
  if (itemId === TL.startReady) return { type: "startReady" };
  if (itemId === TL.group && menuItemId?.startsWith("group:")) return { type: "group", value: menuItemId.slice(6) };
  if (itemId === TL.density && (menuItemId === "density:comfortable" || menuItemId === "density:compact")) return { type: "density", value: menuItemId.slice(8) as "comfortable" | "compact" };
  return null;
}

// The board's toggles (the row of switches beside Board | Map).

export const TB = { canceled: "board.canceled", blocked: "board.blocked" } as const;

export function buildBoardExtras(i: { showCanceled: boolean; blockedOnly: boolean }): ToolbarItem[] {
  return [
    { id: TB.canceled, label: "Show canceled", kind: "toggle", icon: "x", showsLabel: true, on: i.showCanceled },
    { id: TB.blocked, label: "Blocked only", kind: "toggle", icon: "alert", showsLabel: true, on: i.blockedOnly },
  ];
}

export type BoardToggle = { type: "canceled" | "blocked" };
export const parseBoardToggle = (itemId: string): BoardToggle | null => (itemId === TB.canceled ? { type: "canceled" } : itemId === TB.blocked ? { type: "blocked" } : null);
