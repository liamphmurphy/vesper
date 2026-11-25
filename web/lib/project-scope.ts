import type { IconName } from "@/components/ui/icon";

/**
 * App-shell navigation definitions (pure so the rules are unit-tested).
 */

/** "inbox" is the Needs you badge (the pill and the compact tab), not every unread inbox item. */
export type NavBadge = "inbox" | "runs" | "wiki" | "settings" | "scheduled";
export type NavItem = { href: string; label: string; icon: IconName; badge?: NavBadge };

/** Apps: a full page of their own. Knowledge holds documents, decks and designs and the wiki in one store (LAZYAGENTS-212); Custom Apps hosts user-built apps inside the workbench. */
export const APP_ITEMS: NavItem[] = [
  { href: "/knowledge", label: "Knowledge", icon: "wiki", badge: "wiki" },
  { href: "/apps", label: "Custom Apps", icon: "dashboard" },
  { href: "/library", label: "Library", icon: "library" },
];

/** Tools: pages you open now and then, beside the apps in the same flyout. */
export const TOOL_ITEMS: NavItem[] = [
  { href: "/workflows", label: "Workflows", icon: "graph" },
  { href: "/scheduled", label: "Scheduled", icon: "clock", badge: "scheduled" },
  { href: "/learn", label: "Learn", icon: "learn" },
  { href: "/reports", label: "Reports", icon: "dollar" },
  { href: "/http", label: "HTTP Client", icon: "plug" },
];

/** The Dev workspace is a tool only while it's enabled, so it isn't in TOOL_ITEMS. */
export const DEV_TOOL_ITEM: NavItem = { href: "/dev", label: "Dev workspace", icon: "terminal" };

/** Every tool the person can open now: TOOL_ITEMS, plus the Dev workspace when it's enabled. */
export function toolItems(devWorkspaceEnabled: boolean): NavItem[] {
  return devWorkspaceEnabled ? [...TOOL_ITEMS, DEV_TOOL_ITEM] : TOOL_ITEMS;
}

/** Apps promoted to their own main-bar entries, so they no longer sit in the flyout. */
export const RAIL_APP_ITEMS: NavItem[] = APP_ITEMS.filter((i) => i.href === "/knowledge" || i.href === "/library");

export function isActive(pathname: string, href: string): boolean {
  return href === "/" ? pathname === "/" : pathname === href || pathname.startsWith(`${href}/`);
}

/** The Apps row reads as current on any page its flyout opens, unless a rail entry of its own already does. */
export function inAppsMenu(pathname: string): boolean {
  if (RAIL_APP_ITEMS.some((i) => isActive(pathname, i.href))) return false;
  // Decks' and designs' old addresses lead to their Knowledge pages, so Knowledge reads as current.
  if (isActive(pathname, "/apps/slides") || isActive(pathname, "/apps/designs")) return false;
  return [...APP_ITEMS, ...toolItems(true)].some((i) => isActive(pathname, i.href));
}
