// Right-click menus in the native shell, drawn as AppKit menus (bridge.ts nativeContextMenu). No
// React here, so `node --test` covers it; the hook is useNativeContextMenu in hooks.ts.

import type { MenuItem } from "./protocol.ts";

/** A menu row with what choosing it does. Children make a submenu; a separator ignores the rest. */
export interface ContextMenuEntry {
  id: string;
  label?: string;
  icon?: string;
  separator?: boolean;
  destructive?: boolean;
  disabled?: boolean;
  checked?: boolean;
  children?: ContextMenuEntry[];
  onSelect?: () => void;
}

/**
 * The protocol's items for `entries`, and each item's handler by id. Separators at either end or
 * next to one another are dropped, so builders can add them unconditionally around optional rows.
 */
export function splitMenu(entries: ContextMenuEntry[]): { items: MenuItem[]; handlers: Map<string, () => void> } {
  const handlers = new Map<string, () => void>();
  const convert = (list: ContextMenuEntry[]): MenuItem[] => {
    const out: MenuItem[] = [];
    for (const e of list) {
      if (e.separator) {
        if (out.length > 0 && !out[out.length - 1].separator) out.push({ id: e.id, separator: true });
        continue;
      }
      const { onSelect, children, ...rest } = e;
      const item: MenuItem = { ...rest };
      if (children) {
        const sub = convert(children);
        if (sub.length === 0) continue;
        item.children = sub;
      } else if (onSelect) {
        handlers.set(e.id, onSelect);
      }
      out.push(item);
    }
    while (out.length > 0 && out[out.length - 1].separator) out.pop();
    return out;
  };
  return { items: convert(entries), handlers };
}

/** Where a right-click keeps WebKit's own menu (Copy, Look Up, Paste, Open Link…) instead of ours. */
const SYSTEM_MENU_TARGETS = 'input, textarea, select, [contenteditable=""], [contenteditable="true"], [contenteditable="plaintext-only"]';

/**
 * Whether a right-click should show the system menu: on a field or editable text, while text
 * in the element is selected (so Copy and Look Up work on it), and, unless the
 * caller's menu covers links itself, on a link.
 */
export function keepsSystemMenu(
  target: { closest(selector: string): unknown } | null,
  opts: { selectionInside: boolean; links: "system" | "menu" },
): boolean {
  if (opts.selectionInside) return true;
  if (!target) return false;
  if (target.closest(SYSTEM_MENU_TARGETS)) return true;
  return opts.links === "system" && !!target.closest("a[href]");
}
