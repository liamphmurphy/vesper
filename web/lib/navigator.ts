/**
 * The shell's left column (the one-column workbench): a fixed top and foot that never change, and
 * in between the current area's own list. Pure so the rules are unit-tested; the column is
 * components/shell/sidebar.tsx and the lists come from the areas (navigator-slot.tsx).
 */
import { inAppsMenu, isActive } from "./project-scope.ts";

/**
 * Every list in the column has the same width, whoever draws it: Chats, the Runs list, the
 * Knowledge explorer, an editor's pages and layers. A literal class so Tailwind finds it.
 */
export const NAVIGATOR_WIDTH = "w-[248px]";

/** The areas on the column's icon row, in order. Apps is the flyout of the other apps and tools. */
export type Area = "chat" | "runs" | "tickets" | "knowledge" | "apps";

/** The area a path belongs to, for the icon row's current mark; null on screens of no area (Settings, Customization). */
export function currentArea(pathname: string): Area | null {
  if (pathname === "/" || isActive(pathname, "/chat") || isActive(pathname, "/spaces")) return "chat";
  if (isActive(pathname, "/runs")) return "runs";
  if (isActive(pathname, "/tickets") || isActive(pathname, "/epics")) return "tickets";
  // Decks and designs are Knowledge pages; their old addresses lead there.
  if (isActive(pathname, "/knowledge") || isActive(pathname, "/apps/designs") || isActive(pathname, "/apps/slides")) return "knowledge";
  if (inAppsMenu(pathname)) return "apps";
  return null;
}

// The column's middle: a screen that has a list of its own (Runs, the Knowledge explorer, an
// editor's structure) claims it and renders into its element; otherwise the column shows Chats.
// Claims are a count, not a flag, so a screen replacing another during navigation never drops it.
let claims = 0;
let slot: HTMLElement | null = null;
const listeners = new Set<() => void>();
const notify = () => listeners.forEach((l) => l());

/** Mark the column's middle as this screen's; call the returned function on unmount. */
export function claimNavigator(): () => void {
  claims++;
  notify();
  let released = false;
  return () => {
    if (released) return;
    released = true;
    claims--;
    notify();
  };
}

export const navigatorClaimed = () => claims > 0;

/** The element the column's middle renders into, set by the column while it is expanded. */
export function setNavigatorSlot(el: HTMLElement | null): void {
  if (el === slot) return;
  slot = el;
  notify();
}

export const navigatorSlot = () => slot;

export function subscribeNavigator(l: () => void): () => void {
  listeners.add(l);
  return () => {
    listeners.delete(l);
  };
}
