"use client";

import { useEffect, useMemo, useRef } from "react";
import type { MenuItem, ToolbarItem } from "./protocol.ts";
import { useIsNativeShell, useNativeCommand } from "./hooks.ts";
import { setTitleMenu } from "./title.ts";
import { menuIds, setToolbarItems } from "./toolbar.ts";

export interface NativeToolbarOptions {
  /** The page's toolbar items; only in the native shell do they go anywhere. */
  items: ToolbarItem[];
  /** A button was pressed (`menuItemId` unset) or a menu item chosen. Only called for this hook's items. */
  onAction: (itemId: string, menuItemId?: string) => void;
  /** The title's own menu (rename, archive…), shown on a chevron beside the title. */
  titleMenu?: MenuItem[];
  onTitleAction?: (menuItemId: string) => void;
}

/**
 * Publishes the page's toolbar items (and the title's menu) to the native shell and routes the
 * shell's `toolbar.action` and `title.action` back to the handlers. Native mode only; it
 * withdraws everything on unmount. Several screens may use it at once: items merge in mount order.
 */
export function useNativeToolbar({ items, onAction, titleMenu, onTitleAction }: NativeToolbarOptions): void {
  const native = useIsNativeShell();
  const token = useRef<symbol>(undefined);
  token.current ??= Symbol("toolbar");
  const titleToken = useRef<symbol>(undefined);
  titleToken.current ??= Symbol("title-menu");

  const itemsJson = JSON.stringify(items);
  const titleJson = JSON.stringify(titleMenu ?? null);
  useEffect(() => {
    if (native) setToolbarItems(token.current!, JSON.parse(itemsJson) as ToolbarItem[]);
  }, [native, itemsJson]);
  useEffect(() => {
    if (native) setTitleMenu(titleToken.current!, JSON.parse(titleJson) as MenuItem[] | null);
  }, [native, titleJson]);
  useEffect(() => {
    if (!native) return;
    const own = token.current!;
    const ownTitle = titleToken.current!;
    return () => {
      setToolbarItems(own, null);
      setTitleMenu(ownTitle, null);
    };
  }, [native]);

  const itemIds = useMemo(() => new Set(items.map((i) => i.id)), [items]);
  const titleIds = useMemo(() => menuIds(titleMenu), [titleMenu]);
  useNativeCommand("toolbar.action", (cmd) => {
    if (itemIds.has(cmd.itemId)) onAction(cmd.itemId, cmd.menuItemId);
  });
  useNativeCommand("title.action", (cmd) => {
    if (onTitleAction && titleIds.has(cmd.menuItemId)) onTitleAction(cmd.menuItemId);
  });
}
