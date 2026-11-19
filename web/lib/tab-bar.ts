/**
 * The compact shell's bottom tab bar (DESIGN.md §3 Responsive): which tabs it
 * has, which one a path belongs to, and which screens hide it. Pure so the
 * rules are unit-tested; the bar itself is components/shell/tab-bar.tsx.
 */
import type { IconName } from "@/components/ui/icon";
import { NAV_GROUPS, isActive, type NavBadge, type NavGroup } from "./project-scope.ts";

/** tray: the tab opens the Needs you tray instead of navigating; href is the page it stands for (Open all). */
export type Tab = { key: "chat" | "needs" | "runs" | "tickets" | "more"; href: string; label: string; icon: IconName; badge?: NavBadge; tray?: boolean };

export const TABS: Tab[] = [
  { key: "chat", href: "/chat", label: "Chat", icon: "msg" },
  { key: "needs", href: "/inbox", label: "Needs you", icon: "inbox", badge: "inbox", tray: true },
  { key: "runs", href: "/work", label: "Work", icon: "tickets", badge: "runs" },
  { key: "more", href: "/more", label: "More", icon: "dots" },
];

/** The tab a path is under. Pages reached from More (apps, tools, settings) keep More current. */
export function currentTab(pathname: string): Tab["key"] {
  if (pathname === "/") return "chat";
  if (/^\/(runs|tickets|epics)(\/|$)/.test(pathname)) return "runs";
  return TABS.find((t) => t.key !== "more" && isActive(pathname, t.href))?.key ?? "more";
}

/** Detail screens (a run, a ticket, an epic, the ticket composer) take the whole screen and have their own way back. */
export function hidesTabBar(pathname: string): boolean {
  return /^\/(runs|tickets|epics)\/[^/]+/.test(pathname);
}

const BADGE_WORD: Partial<Record<NavBadge, string>> = { inbox: "waiting", runs: "running" };

/** A badge shown only as a dot or number has to reach screen readers through the link's name. */
export function badgeLabel(label: string, badge: NavBadge | undefined, counts: Record<NavBadge, number>): string {
  const n = badge ? counts[badge] : 0;
  const word = badge && BADGE_WORD[badge];
  return n > 0 && word ? `${label} ${n} ${word}` : label;
}

/**
 * What More lists: every NAV_GROUPS group with the items the bar has no tab for, in the
 * sidebar's order. Read from NAV_GROUPS so a new nav item lands here too.
 */
export function moreSections(groups: NavGroup[] = NAV_GROUPS): NavGroup[] {
  const tabbed = new Set(TABS.map((t) => t.href));
  return groups.map((g) => ({ ...g, items: g.items.filter((i) => !tabbed.has(i.href)) })).filter((g) => g.items.length > 0);
}

/** A More row's accessible name, carrying the badge the row shows as a number or a dot. */
export function moreLabel(label: string, badge: NavBadge | undefined, counts: Record<NavBadge, number>): string {
  const n = badge ? counts[badge] : 0;
  if (!badge || n <= 0) return label;
  if (badge === "settings") return `${label}: a setting runs need is missing`;
  if (badge === "wiki") return `${label}, ${n} suggested edit${n === 1 ? "" : "s"} to review`;
  return `${label}, ${n} need${n === 1 ? "s" : ""} you`;
}
