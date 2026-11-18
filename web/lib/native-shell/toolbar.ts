// The page's toolbar items for the native shell, from every screen that contributes some. The
// shell has one `toolbar` message, so the sources are merged here (in the order they appeared) and
// each source clears its own when it goes away. No React: hooks are in use-native-toolbar.ts.

import { postDeduped } from "./bridge.ts";
import type { MenuItem, ToolbarItem } from "./protocol.ts";

const sources = new Map<symbol, ToolbarItem[]>();

/** Send the merged items (deduped). */
export function publishToolbar(): void {
  postDeduped({ v: 1, type: "toolbar", items: [...sources.values()].flat() });
}

/** A source's items; pass null to withdraw them. */
export function setToolbarItems(token: symbol, items: ToolbarItem[] | null): void {
  if (items) sources.set(token, items);
  else sources.delete(token);
  publishToolbar();
}

/** Every id in a menu tree, submenus included. */
export function menuIds(menu: readonly MenuItem[] | undefined): Set<string> {
  const ids = new Set<string>();
  const walk = (items: readonly MenuItem[]) => {
    for (const m of items) {
      if (!m.separator) ids.add(m.id);
      if (m.children) walk(m.children);
    }
  };
  walk(menu ?? []);
  return ids;
}
