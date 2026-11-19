/**
 * The navigation areas and active-screen navigator slot. Pure so the rules are unit-tested;
 * the screens publish NavModels through components/shell/navigator-slot.tsx.
 */
import type { IconName } from "@/components/ui/icon";
import { inAppsMenu, isActive, type NavBadge } from "./project-scope.ts";

/** The areas on the icon row, in order. Apps is the flyout of Custom Apps and tools. */
export type Area = "chat" | "work" | "runs" | "tickets" | "knowledge" | "library" | "apps";

export const AREAS: { area: Exclude<Area, "apps" | "runs" | "tickets">; href: string; label: string; icon: IconName; badge?: NavBadge }[] = [
  { area: "chat", href: "/chat", label: "Chat", icon: "msg" },
  { area: "work", href: "/work", label: "Work", icon: "tickets", badge: "runs" },
  { area: "knowledge", href: "/knowledge", label: "Knowledge", icon: "wiki", badge: "wiki" },
  { area: "library", href: "/library", label: "Library", icon: "library" },
];

/** The area a path belongs to, for the icon row's current mark; null on screens of no area (Settings, Customization). */
export function currentArea(pathname: string): Area | null {
  if (pathname === "/" || isActive(pathname, "/chat") || isActive(pathname, "/spaces")) return "chat";
  if (isActive(pathname, "/work") || isActive(pathname, "/runs")) return "work";
  if (isActive(pathname, "/tickets") || isActive(pathname, "/epics")) return "work";
  // Decks and designs are Knowledge pages; their old addresses lead there.
  if (isActive(pathname, "/knowledge") || isActive(pathname, "/apps/designs") || isActive(pathname, "/apps/slides")) return "knowledge";
  if (isActive(pathname, "/library")) return "library";
  if (inAppsMenu(pathname)) return "apps";
  return null;
}

// A screen that has a list of its own (Runs, the Knowledge explorer, an editor's structure)
// claims the navigator while mounted so the default Chats list stands down.
// Claims are a count, not a flag, so a screen replacing another during navigation never drops it.
let claims = 0;
const listeners = new Set<() => void>();
const notify = () => listeners.forEach((l) => l());

/** Mark the navigator as this screen's; call the returned function on unmount. */
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

export function subscribeNavigator(l: () => void): () => void {
  listeners.add(l);
  return () => {
    listeners.delete(l);
  };
}
