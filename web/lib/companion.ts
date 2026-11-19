/**
 * The shell's right-hand column: one companion panel beside every page (DESIGN.md §3). A page with a
 * panel of its own (an editor's dock, Knowledge's, a run's or a ticket's) claims the column and
 * renders its Dock into it (CompanionPortal); otherwise the shell shows the default companion, the
 * work chat. The same store shape as the left column's slot (navigator.ts), and every dock shares one
 * open/closed state (companionOpen), so the panel stays open or folded as you move between pages.
 */

// Claims are a count, so a page replacing another during navigation never drops the column.
let claims = 0;
let slot: HTMLElement | null = null;
const listeners = new Set<() => void>();
const notify = () => listeners.forEach((l) => l());

/** Mark the right column as this page's; call the returned function on unmount. */
export function claimCompanion(): () => void {
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

export const companionClaimed = () => claims > 0;

/** The element the right column's panel renders into, set by the shell on wide screens. */
export function setCompanionSlot(el: HTMLElement | null): void {
  if (el === slot) return;
  slot = el;
  notify();
}

export const companionSlot = () => slot;

export function subscribeCompanion(l: () => void): () => void {
  listeners.add(l);
  return () => {
    listeners.delete(l);
  };
}

/** localStorage key for whether the companion is open, shared by every page's dock. */
export const COMPANION_OPEN_KEY = "lazyagents.companion-open";

type KV = Pick<Storage, "getItem" | "setItem">;

/** The shared open state, if one was ever chosen: "1" open, "0" folded to its rail. */
export function companionOpen(store: KV | undefined): boolean | undefined {
  try {
    const v = store?.getItem(COMPANION_OPEN_KEY);
    return v === "1" ? true : v === "0" ? false : undefined;
  } catch {
    return undefined;
  }
}

export function setCompanionOpen(store: KV | undefined, open: boolean): void {
  try {
    store?.setItem(COMPANION_OPEN_KEY, open ? "1" : "0");
  } catch {
    /* Not remembered. */
  }
}
