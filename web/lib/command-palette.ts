// Recent-visit helpers and `?` keyboard shortcut reference for web pages.
// Kept free of React so `npm run test:unit` covers it.

/** A navigable result, as stored in the recent list. */
export type PaletteLink = {
  id: string;
  title: string;
  meta?: string;
  href: string;
  kind: string;
  status?: string;
};

export const MAX_RECENT = 6;

/** Most recent first, deduped by href, capped. */
export function pushRecent(list: PaletteLink[], item: PaletteLink, max = MAX_RECENT): PaletteLink[] {
  return [item, ...list.filter((r) => r.href !== item.href)].slice(0, max);
}

/** Reads the stored recent list, dropping anything malformed. */
export function parseRecent(raw: string | null): PaletteLink[] {
  if (!raw) return [];
  try {
    const v: unknown = JSON.parse(raw);
    if (!Array.isArray(v)) return [];
    return v
      .filter(
        (r): r is PaletteLink =>
          !!r &&
          typeof r === "object" &&
          typeof (r as PaletteLink).href === "string" &&
          (r as PaletteLink).href.startsWith("/") &&
          typeof (r as PaletteLink).title === "string" &&
          typeof (r as PaletteLink).id === "string",
      )
      .slice(0, MAX_RECENT);
  } catch {
    return [];
  }
}

/** Where ⌘K keeps its Recent list (localStorage). */
export const RECENT_KEY = "la:palette-recent";

type RecentStore = Pick<Storage, "getItem" | "setItem">;

/**
 * Remembers an opened item as recent, as picking it in ⌘K does: back and forward cover the last
 * few steps, Recent the places you have been. Blocked or full storage just skips it.
 */
export function recordRecent(store: RecentStore, item: PaletteLink): void {
  try {
    const next = pushRecent(parseRecent(store.getItem(RECENT_KEY)), item);
    store.setItem(RECENT_KEY, JSON.stringify(next));
  } catch {
    /* Recents are a nicety. */
  }
}

/** `?` reference (keep in sync with the handlers in app-shell.tsx). */
export const SHORTCUTS: { section: string; items: { label: string; keys: string[] }[] }[] = [
  {
    section: "Global",
    items: [
      { label: "Open command palette", keys: ["⌘/Ctrl", "K"] },
      { label: "Open page-scoped command palette", keys: ["⌘/Ctrl", "⇧", "K"] },
      { label: "Show this reference", keys: ["?"] },
    ],
  },
  {
    section: "Chat",
    items: [
      { label: "Next / previous message", keys: ["J", "K"] },
      { label: "Reply to the message (quote it)", keys: ["R"] },
      { label: "Start a thread on the message", keys: ["T"] },
      { label: "Edit your last message", keys: ["E"] },
      { label: "Back to the message box", keys: ["Esc"] },
    ],
  },
  {
    section: "Palette",
    items: [
      { label: "Move / open / close", keys: ["↑", "↓", "↵", "Esc"] },
      { label: "Next / previous type", keys: ["Tab", "⇧Tab"] },
      { label: "Expand / collapse a chat's matching messages", keys: ["→", "←"] },
      { label: "Attach to a chat", keys: ["⌥", "↵"] },
      { label: "People · commands only", keys: ["@", ">"] },
      { label: "Open in a new tab", keys: ["⌘/Ctrl", "↵"] },
    ],
  },
  {
    section: "Needs you tray",
    items: [
      { label: "Next / previous item", keys: ["J", "K"] },
      { label: "Open the item’s page", keys: ["↵"] },
      { label: "Switch between Needs you and Updates", keys: ["←", "→"] },
      { label: "Approve the selected approval", keys: ["A"] },
      { label: "Deny the selected approval (with an optional reason)", keys: ["D"] },
      { label: "Reply to the selected question", keys: ["R"] },
      { label: "Clear the selected item until it changes", keys: ["X"] },
      { label: "Close the tray, or leave the reply box", keys: ["Esc"] },
    ],
  },
  {
    section: "Inbox",
    items: [
      { label: "Next / previous item", keys: ["J", "K"] },
      { label: "Open the item’s page", keys: ["↵"] },
      { label: "Approve (approvals, mockups)", keys: ["A"] },
      { label: "Deny (approvals)", keys: ["D"] },
      { label: "Reply (questions) or focus the note", keys: ["R"] },
      { label: "Mark done: hide until it changes", keys: ["E"] },
      { label: "Send the reply or note", keys: ["⌘/Ctrl", "↵"] },
      { label: "Leave the text box, back to the list", keys: ["Esc"] },
    ],
  },
  {
    section: "Knowledge",
    items: [
      { label: "Go to page", keys: ["⌘/Ctrl", "O"] },
      { label: "Quick capture", keys: ["⌘/Ctrl", "⌥", "N"] },
      { label: "Today’s daily note", keys: ["⌘/Ctrl", "D"] },
      { label: "Close active tab", keys: ["⌥", "W"] },
      { label: "Close all tabs", keys: ["⌥", "⇧", "W"] },
    ],
  },
];
