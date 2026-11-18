// Pure helpers over a NavModel: finding an item and the default handling of the shell's nav.* commands.

import type { NativeCommand, NavItem, NavModel } from "./protocol.ts";

export function findNavItem(model: NavModel, id: string): NavItem | undefined {
  const walk = (items: NavItem[]): NavItem | undefined => {
    for (const item of items) {
      if (item.id === id) return item;
      const inner = item.children && walk(item.children);
      if (inner) return inner;
    }
    return undefined;
  };
  for (const s of model.sections) {
    const found = walk(s.items);
    if (found) return found;
  }
  return undefined;
}

/**
 * Routes a command to the navigator it names: nav.* commands whose navigatorId is `model.id` go to
 * `onCommand`; nav.activate on an item with an href also navigates, whether or not there is an
 * `onCommand` (so rows with an href need no handler). A ⌘-clicked row with an href (newTab) opens in
 * a new tab instead, and neither navigates nor reaches `onCommand`: this tab's selection stays put.
 * Returns whether the command was for this navigator.
 */
export function routeNavCommand(
  model: NavModel,
  cmd: NativeCommand,
  push: (href: string) => void,
  onCommand?: (cmd: NativeCommand) => void,
  openInNewTab?: (href: string) => void,
): boolean {
  if (!cmd.type.startsWith("nav.") || !("navigatorId" in cmd) || cmd.navigatorId !== model.id) return false;
  if (cmd.type === "nav.activate" && cmd.newTab && openInNewTab) {
    const href = findNavItem(model, cmd.itemId)?.href;
    if (href) {
      openInNewTab(href);
      return true;
    }
  }
  onCommand?.(cmd);
  if (cmd.type === "nav.activate") {
    const href = findNavItem(model, cmd.itemId)?.href;
    if (href) push(href);
  }
  return true;
}
