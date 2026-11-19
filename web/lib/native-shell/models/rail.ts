// The native right rail's model (protocol.ts RailModel) and the button handlers behind it. Pure:
// the React side (components/shell/companion.tsx) feeds it what the web rail's buttons read and
// runs the actions it names. `node --test` covers it (lib/native-shell/rail.test.mjs).

import type { Avatar, MenuItem, RailItem, RailModel, RailUsage } from "../protocol.ts";

// MARK: Item ids

export const RAIL_DOCK_TOGGLE = "dock.toggle";
export const RAIL_DOCK_TAB = "dock.tab:";
export const RAIL_PR = "pr";
export const RAIL_PR_OPEN = "pr:";
export const RAIL_PR_DISMISS = "pr.dismiss:";
export const RAIL_PR_CLEAR = "pr.clear";
export const RAIL_PR_RESTORE = "pr.restore";
export const RAIL_PR_REFRESH = "pr.refresh";
export const RAIL_PR_DIRECT = "pr.direct";
export const RAIL_PR_TEAM = "pr.team";
export const RAIL_NEEDS_YOU = "needsYou";
export const RAIL_HARNESS = "harness:";
export const RAIL_HARNESS_USAGE = "usage";
export const RAIL_CUSTOMIZATION = "customization";
export const RAIL_SETTINGS = "settings";

const isActive = (pathname: string, href: string) => pathname === href || pathname.startsWith(`${href}/`);

// MARK: The page's dock

export interface DockRailTab {
  id: string;
  label: string;
  icon: string;
  busy?: boolean;
  unread?: boolean;
  /** A button that runs an action (e.g. Start playground) instead of showing a panel: never active. */
  action?: boolean;
}

/** What a dock's rail buttons dispatch (the same actions the web buttons do); `run` is an action tab's own. */
export type DockRailAction = { type: "collapse" } | { type: "open"; tab: string } | { type: "select"; tab: string } | { type: "run"; tab: string };

/** A dock's rail controls as items: fold or unfold, then one per tab. */
export function dockRailItems(tabs: readonly DockRailTab[], activeId: string | undefined, expanded: boolean): RailItem[] {
  if (!tabs.length) return [];
  const items: RailItem[] = [
    {
      id: RAIL_DOCK_TOGGLE,
      label: expanded ? "Collapse panel" : "Expand panel",
      icon: "panel-right",
      active: expanded,
    },
  ];
  for (const t of tabs) {
    const item: RailItem = {
      id: RAIL_DOCK_TAB + t.id,
      label: t.busy ? `${t.label} (working)` : t.unread ? `${t.label} (unread)` : t.label,
      icon: t.icon,
      active: !t.action && expanded && t.id === activeId,
    };
    if (t.unread) item.badge = { tone: "human" };
    if (t.busy) item.status = "accent";
    items.push(item);
  }
  return items;
}

/** What the rail button `itemId` does for this dock; null for an id that isn't one of its buttons. */
export function dockRailAction(itemId: string, tabs: readonly DockRailTab[], activeId: string | undefined, expanded: boolean): DockRailAction | null {
  if (itemId === RAIL_DOCK_TOGGLE) return expanded ? { type: "collapse" } : { type: "open", tab: activeId ?? tabs[0]?.id ?? "" };
  if (!itemId.startsWith(RAIL_DOCK_TAB)) return null;
  const tab = itemId.slice(RAIL_DOCK_TAB.length);
  const target = tabs.find((t) => t.id === tab);
  if (!target) return null;
  if (target.action) return { type: "run", tab };
  return { type: expanded ? "select" : "open", tab };
}

// MARK: Dock registry

interface DockEntry {
  items: RailItem[];
  act: (itemId: string) => void;
}

/**
 * The docks that currently describe their rail controls. The latest to register wins (a page
 * replacing another during navigation), like the navigator's screens.
 */
export function createDockRailStore() {
  const entries = new Map<symbol, DockEntry>();
  const listeners = new Set<() => void>();
  let snapshot: RailItem[] = [];
  const refresh = () => {
    const last = [...entries.values()].at(-1);
    const next = last?.items ?? [];
    if (JSON.stringify(next) === JSON.stringify(snapshot)) return;
    snapshot = next;
    listeners.forEach((l) => l());
  };
  return {
    set(token: symbol, items: RailItem[], act: (itemId: string) => void) {
      entries.delete(token);
      entries.set(token, { items, act });
      refresh();
    },
    clear(token: symbol) {
      entries.delete(token);
      refresh();
    },
    /** Stable between changes (for useSyncExternalStore). */
    items: () => snapshot,
    subscribe(l: () => void) {
      listeners.add(l);
      return () => {
        listeners.delete(l);
      };
    },
    /** Runs the newest dock's handler for `itemId`; false when no dock is registered. */
    act(itemId: string): boolean {
      const last = [...entries.values()].at(-1);
      if (!last) return false;
      last.act(itemId);
      return true;
    },
  };
}

export const dockRail = createDockRailStore();

// MARK: The whole rail

export interface ReviewRailInput {
  /** The workspace has a GitHub token; without one the button explains instead of listing. */
  configured: boolean;
  /** The requests that pass the Direct/Team filter. */
  requests: readonly { id: string; number: number; title: string; repository: string; draft?: boolean }[];
  /** Pull requests of yours that were approved (unread inbox items). */
  approved: number;
  prefs: { direct: boolean; team: boolean };
  counts: { direct: number; team: number };
  /** Requests matching the active filter that were dismissed locally until updated on GitHub. */
  dismissed?: number;
}

export interface HarnessRailInput {
  harness: string;
  label: string;
  /** Two letters on the avatar. */
  initials: string;
  color: string;
  /** The label under the character on the web rail. */
  name: string;
  state: "idle" | "working" | "limited";
  /** The usage bubble's reading (the same row the web bubble shows; `footnote` is when it was checked). */
  usage: RailUsage;
}

export interface RailInput {
  dock: readonly RailItem[];
  pathname: string;
  review: ReviewRailInput;
  needsYou: number;
  /** Null: the person turned harness activity off. */
  harnesses: readonly HarnessRailInput[] | null;
  settingsNeedYou: boolean;
}

const count = (n: number) => (n > 99 ? "99+" : String(n));
const shorten = (s: string, max: number) => (s.length > max ? `${s.slice(0, max - 1)}…` : s);

const MAX_PRS = 15;

function reviewItem(r: ReviewRailInput): RailItem {
  const n = r.requests.length;
  const waiting = r.configured ? n : 0;
  const parts = [
    "GitHub review requests",
    waiting > 0 ? `${waiting} waiting` : "",
    r.approved > 0 ? `${r.approved} of yours approved` : "",
  ].filter(Boolean);
  const menu: MenuItem[] = [];
  if (!r.configured) {
    menu.push({ id: "pr.setup", label: "Add a GitHub token in Settings…", icon: "gear" });
  } else {
    if (!n) menu.push({ id: "pr.none", label: "No review requests", disabled: true });
    for (const pr of r.requests.slice(0, MAX_PRS)) {
      menu.push({ id: RAIL_PR_OPEN + pr.id, label: shorten(`${pr.repository} #${pr.number}  ${pr.title}`, 64), icon: "pr" });
    }
    if (n > MAX_PRS) menu.push({ id: "pr.more", label: `${n - MAX_PRS} more on GitHub`, disabled: true });
    menu.push({ id: "pr.sep", separator: true });
    menu.push({ id: RAIL_PR_DIRECT, label: `Directly requested (${r.counts.direct})`, checked: r.prefs.direct });
    menu.push({ id: RAIL_PR_TEAM, label: `Requested of a team (${r.counts.team})`, checked: r.prefs.team });
    menu.push({ id: "pr.sep2", separator: true });
    menu.push({ id: RAIL_PR_REFRESH, label: "Refresh", icon: "refresh" });
    if (n > 0) {
      menu.push({ id: RAIL_PR_CLEAR, label: "Clear all", icon: "x" });
      menu.push({ id: "pr.sep3", separator: true });
      menu.push({
        id: "pr.dismiss",
        label: "Dismiss",
        children: r.requests.slice(0, MAX_PRS).map((pr) => ({
          id: RAIL_PR_DISMISS + pr.id,
          label: shorten(`${pr.repository} #${pr.number}  ${pr.title}`, 56),
          icon: "x",
        })),
      });
    } else if (r.dismissed && r.dismissed > 0) {
      menu.push({ id: RAIL_PR_RESTORE, label: `Restore dismissed (${r.dismissed})`, icon: "history" });
    }
  }
  const item: RailItem = { id: RAIL_PR, label: parts.join(", "), icon: "pr", menu };
  if (waiting > 0) item.badge = { text: count(waiting), tone: "accent" };
  else if (r.approved > 0) item.badge = { text: count(r.approved), tone: "done" };
  return item;
}

function harnessItem(h: HarnessRailInput): RailItem {
  const avatar: Avatar = { initials: h.initials, color: h.color };
  const item: RailItem = {
    id: RAIL_HARNESS + h.harness,
    label: `${h.label}, ${h.state}`,
    avatar,
    character: { harness: h.harness, working: h.state === "working", name: h.name },
    usage: [h.usage],
    menu: [{ id: RAIL_HARNESS_USAGE, label: "Usage settings…", icon: "gear" }],
  };
  if (h.state === "working") item.status = "done";
  else if (h.state === "limited") item.status = "warning";
  return item;
}

/** The whole rail: the page's dock on top, then reviews, Needs you and the harnesses, then Settings. */
export function buildRailModel(input: RailInput): RailModel {
  const { pathname } = input;
  const settings: RailItem = {
    id: RAIL_SETTINGS,
    label: input.settingsNeedYou ? "Settings: a setting runs need is missing" : "Settings",
    icon: "gear",
    active: isActive(pathname, "/settings"),
  };
  if (input.settingsNeedYou) settings.badge = { tone: "human" };
  const foot: RailItem[] = [settings];

  const needsYou: RailItem = {
    id: RAIL_NEEDS_YOU,
    label: input.needsYou > 0 ? `Needs you, ${input.needsYou} waiting` : "Needs you",
    icon: "inbox",
    kind: "needsYou",
  };
  if (input.needsYou > 0) needsYou.badge = { text: count(input.needsYou), tone: "human" };

  const middle: RailItem[] = [reviewItem(input.review), needsYou, ...(input.harnesses ?? []).map(harnessItem)];
  return { top: [...input.dock], middle, foot };
}

// MARK: Actions

/** What a rail.action from the shell asks the page to do. */
export type RailEffect =
  | { type: "dock"; itemId: string }
  | { type: "navigate"; path: string }
  | { type: "open"; url: string }
  | { type: "refreshReviews" }
  | { type: "clearReviews" }
  | { type: "dismissReview"; id: string }
  | { type: "restoreReviews" }
  | { type: "reviewPrefs"; key: "direct" | "team" }
  | null;

/** Resolves the shell's `rail.action` to an effect; the component runs it with the web buttons' own functions. */
export function railEffect(
  itemId: string,
  menuItemId: string | undefined,
  ctx: { reviewUrl: (id: string) => string | undefined },
): RailEffect {
  if (itemId === RAIL_DOCK_TOGGLE || itemId.startsWith(RAIL_DOCK_TAB)) return { type: "dock", itemId };
  switch (itemId) {
    case RAIL_SETTINGS:
      return { type: "navigate", path: "/settings" };
    case RAIL_PR: {
      if (menuItemId === "pr.setup") return { type: "navigate", path: "/settings" };
      if (menuItemId === RAIL_PR_REFRESH) return { type: "refreshReviews" };
      if (menuItemId === RAIL_PR_CLEAR) return { type: "clearReviews" };
      if (menuItemId === RAIL_PR_RESTORE) return { type: "restoreReviews" };
      if (menuItemId === RAIL_PR_DIRECT) return { type: "reviewPrefs", key: "direct" };
      if (menuItemId === RAIL_PR_TEAM) return { type: "reviewPrefs", key: "team" };
      if (menuItemId?.startsWith(RAIL_PR_DISMISS)) {
        const id = menuItemId.slice(RAIL_PR_DISMISS.length);
        return id ? { type: "dismissReview", id } : null;
      }
      if (menuItemId?.startsWith(RAIL_PR_OPEN)) {
        const url = ctx.reviewUrl(menuItemId.slice(RAIL_PR_OPEN.length));
        return url ? { type: "open", url } : null;
      }
      return null;
    }
    case RAIL_NEEDS_YOU:
      return { type: "navigate", path: "/inbox" };
    default:
      if (itemId.startsWith(RAIL_HARNESS) && menuItemId === RAIL_HARNESS_USAGE) return { type: "navigate", path: "/settings/runner" };
      return null;
  }
}
