import type { IconName } from "@/components/ui/icon";

/**
 * App-shell navigation and project scope (LAZYAGENTS-42). Pure so the rules are
 * unit-tested; the React side lives in components/shell/project-scope.tsx.
 */

export type ScopedProject = { key: string; name: string; color: string; archived: boolean };

/** required: the page needs one project (chooser otherwise). optional: no project means all projects. */
export type ProjectMode = "required" | "optional";

/** "inbox" is the Needs you badge (the pill and the compact tab), not every unread inbox item. */
export type NavBadge = "inbox" | "runs" | "wiki" | "settings" | "scheduled";
export type NavItem = { href: string; label: string; icon: IconName; badge?: NavBadge };
export type NavGroup = { label: "Work" | "Apps" | "Tools" | "You"; items: NavItem[] };

/**
 * The one menu (no Chat/Work modes): conversations first, then Work (what
 * agents are doing for you), the Apps row whose flyout holds Apps and Tools,
 * and Customization and Settings in the footer. The sidebar and the command
 * menu both read these.
 */
export const WORK_ITEMS: NavItem[] = [
  // No Inbox row: the Needs you pill above the menu opens the tray, and /inbox is its "Open all" page.
  { href: "/runs", label: "Runs", icon: "play", badge: "runs" },
  { href: "/tickets", label: "Tickets", icon: "tickets" },
];

/** Apps: a full page of their own. Knowledge holds documents, decks and designs and the wiki in one store (LAZYAGENTS-212); Finance has an Ask drawer backed by one of the person's spaces. */
export const APP_ITEMS: NavItem[] = [
  { href: "/knowledge", label: "Knowledge", icon: "wiki", badge: "wiki" },
  { href: "/apps/finance", label: "Finance", icon: "dollar" },
  { href: "/library", label: "Library", icon: "library" },
];

/** Tools: pages you open now and then, beside the apps in the same flyout. */
export const TOOL_ITEMS: NavItem[] = [
  { href: "/workflows", label: "Workflows", icon: "graph" },
  { href: "/scheduled", label: "Scheduled", icon: "clock", badge: "scheduled" },
  { href: "/learn", label: "Learn", icon: "learn" },
  // Costs and Highlights (LAZYAGENTS-163), formerly the Runs tabs. In the Apps flyout: the column's icon row holds the areas only.
  { href: "/reports", label: "Reports", icon: "dollar" },
];

export const FOOTER_ITEMS: NavItem[] = [
  { href: "/customization", label: "Customization", icon: "sliders" },
  { href: "/settings", label: "Settings", icon: "gear", badge: "settings" },
];

export const NAV_GROUPS: NavGroup[] = [
  { label: "Work", items: WORK_ITEMS },
  { label: "Apps", items: APP_ITEMS },
  { label: "Tools", items: TOOL_ITEMS },
  { label: "You", items: FOOTER_ITEMS },
];

/** Apps used often enough to have their own rail entry too; the flyout still lists them. */
export const RAIL_APP_ITEMS: NavItem[] = APP_ITEMS.filter((i) => i.href === "/knowledge");

/** The Apps row reads as current on any page its flyout opens, unless a rail entry of its own already does. */
export function inAppsMenu(pathname: string): boolean {
  if (RAIL_APP_ITEMS.some((i) => isActive(pathname, i.href))) return false;
  // Decks' and designs' old addresses lead to their Knowledge pages, so Knowledge reads as current.
  if (isActive(pathname, "/apps/slides") || isActive(pathname, "/apps/designs")) return false;
  return [...APP_ITEMS, ...TOOL_ITEMS].some((i) => isActive(pathname, i.href));
}

/** Routes whose content belongs to one project, read from ?project=. */
export const PROJECT_ROUTES: Record<string, ProjectMode> = {
  "/plans": "required",
  "/tickets": "optional",
};

/** Pages under a project route where switching only updates the remembered project (a draft would be lost). */
const STAY_ON_SWITCH = new Set(["/tickets/new"]);

/** Query parameters that name something inside one project; they don't survive a switch. */
const PROJECT_BOUND_PARAMS = ["project", "epic", "ticket", "id", "artifact", "attach", "attach_title"];

export function isActive(pathname: string, href: string): boolean {
  return href === "/" ? pathname === "/" : pathname === href || pathname.startsWith(`${href}/`);
}

/** The project route a path belongs to, e.g. /chat/123 → /chat. */
export function projectSection(pathname: string): string | undefined {
  return Object.keys(PROJECT_ROUTES).find((base) => isActive(pathname, base));
}

export function withProject(href: string, key: string | null | undefined): string {
  if (!key || !PROJECT_ROUTES[href]) return href;
  return `${href}?project=${encodeURIComponent(key)}`;
}

/**
 * Where to go when the person picks a project (null = All projects) in the switcher.
 * null result: stay on the current page.
 */
export function switchHref(pathname: string, search: URLSearchParams, key: string | null): string | null {
  const base = projectSection(pathname);
  if (!base || STAY_ON_SWITCH.has(pathname)) return null;
  const next = new URLSearchParams(pathname === base ? search : undefined);
  for (const p of PROJECT_BOUND_PARAMS) next.delete(p);
  if (key) next.set("project", key);
  const qs = next.toString();
  return qs ? `${base}?${qs}` : base;
}

/** Params that pick how a page shows its project (Tickets' ?layout=, Runs' ?tab=, Library's ?source=), not what it shows. */
const VIEW_PARAMS = ["project", "layout", "tab", "source"];

/**
 * Where a page's own project picker goes: a project route switches as the
 * menu's switcher did; any other page (Runs' Costs tab) just changes its
 * ?project=. null: stay put (a draft would be lost).
 */
export function pickerHref(pathname: string, search: URLSearchParams, key: string | null): string | null {
  if (projectSection(pathname)) return switchHref(pathname, search, key);
  const next = new URLSearchParams(search);
  for (const p of PROJECT_BOUND_PARAMS) next.delete(p);
  if (key) next.set("project", key);
  const qs = next.toString();
  return qs ? `${pathname}?${qs}` : pathname;
}

/**
 * A URL with filters but no project (/tickets?assignee=…) is a
 * deliberate cross-project link: optional routes honor it instead of narrowing
 * it to the remembered project.
 */
export function hasFilters(search: URLSearchParams): boolean {
  return [...search.keys()].some((k) => !VIEW_PARAMS.includes(k));
}

/** The board is a Tickets layout that, unlike the list, needs one project. */
export function needsOneProject(section: string, search: URLSearchParams): boolean {
  return PROJECT_ROUTES[section] === "required" || (section === "/tickets" && search.get("layout") === "board");
}

export type ProjectResolution<P extends ScopedProject = ScopedProject> =
  /** The URL names an active project. */
  | { state: "project"; project: P }
  /** The URL names an archived (project set) or unknown project. */
  | { state: "unavailable"; key: string; archived?: P }
  /** No project in the URL; replace the URL with the remembered one. */
  | { state: "redirect"; key: string }
  /** No project in the URL and nothing usable remembered. */
  | { state: "none" };

/** URL first, then the remembered project. Archived projects are never resolved. */
export function resolveProject<P extends ScopedProject>(
  requested: string | null | undefined,
  remembered: string | null | undefined,
  projects: P[],
): ProjectResolution<P> {
  if (requested) {
    const found = projects.find((p) => p.key === requested);
    if (found && !found.archived) return { state: "project", project: found };
    return { state: "unavailable", key: requested, archived: found };
  }
  if (remembered && projects.some((p) => p.key === remembered && !p.archived)) {
    return { state: "redirect", key: remembered };
  }
  return { state: "none" };
}

/**
 * The project the switcher shows: the URL's on project routes, nothing on a
 * cross-project link (it lists all projects), else the remembered one.
 */
export function currentProject<P extends ScopedProject>(
  pathname: string,
  search: URLSearchParams,
  remembered: string | null | undefined,
  projects: P[],
): P | undefined {
  const active = projects.filter((p) => !p.archived);
  const section = projectSection(pathname);
  const requested = search.get("project");
  if (section && requested) return active.find((p) => p.key === requested);
  if (section === pathname && !needsOneProject(section, search) && hasFilters(search)) return undefined;
  return remembered ? active.find((p) => p.key === remembered) : undefined;
}
