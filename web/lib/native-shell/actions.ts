// A screen's header actions described once for the native toolbar: each item (and each menu entry)
// carries the handler to run, and `splitActions` separates the wire items from the dispatcher. Pure;
// the hook that publishes them is use-native-actions.ts.

import type { MenuItem, ToolbarItem } from "./protocol.ts";

export type NativeMenuEntry = MenuItem & { run?: () => void; children?: NativeMenuEntry[] };
export type NativeAction = Omit<ToolbarItem, "menu"> & { run?: () => void; menu?: NativeMenuEntry[] };

function strip(entries: NativeMenuEntry[]): MenuItem[] {
  return entries.map((e) => {
    const { children, ...rest } = e;
    delete (rest as { run?: unknown }).run;
    return children ? { ...rest, children: strip(children) } : rest;
  });
}

function find(entries: NativeMenuEntry[] | undefined, id: string): NativeMenuEntry | undefined {
  for (const e of entries ?? []) {
    if (!e.separator && e.id === id) return e;
    const hit = find(e.children, id);
    if (hit) return hit;
  }
  return undefined;
}

/** The toolbar items to publish, and the function that runs the handler of a pressed item or chosen menu entry. */
export function splitActions(actions: readonly NativeAction[]): { items: ToolbarItem[]; dispatch: (itemId: string, menuItemId?: string) => void } {
  const items = actions.map((a): ToolbarItem => {
    const { menu, ...rest } = a;
    delete (rest as { run?: unknown }).run;
    return menu ? { ...rest, menu: strip(menu) } : rest;
  });
  const dispatch = (itemId: string, menuItemId?: string) => {
    const action = actions.find((a) => a.id === itemId);
    if (!action || action.disabled) return;
    const entry = menuItemId === undefined ? undefined : find(action.menu, menuItemId);
    if (entry) {
      if (!entry.disabled) entry.run?.();
    } else if (menuItemId === undefined) action.run?.();
  };
  return { items, dispatch };
}
