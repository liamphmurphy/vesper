"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useSyncExternalStore, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { claimNavigator, fallbackSlot, navigatorSlot, subscribeNavigator } from "@/lib/navigator";
import { onCommand } from "@/lib/native-shell/bridge";
import { useIsNativeShell } from "@/lib/native-shell/hooks";
import { routeNavCommand } from "@/lib/native-shell/nav-model";
import { publisher } from "@/lib/native-shell/publisher";
import type { NativeCommand, NavModel } from "@/lib/native-shell/protocol";

/** A new tab in the Mac app: the shell opens a link with no target window as a tab beside this one. */
export function openInNewTab(href: string) {
  window.open(href, "_blank", "noopener");
}

/** A screen's list described as data for the native sidebar, with a handler for its commands. */
export type NativeNavigator = { model: NavModel; onCommand?: (cmd: NativeCommand) => void };

/**
 * Puts a screen's own list (the Runs list, the Knowledge explorer, an editor's pages and layers)
 * in the left column's middle, in place of Chats, so the screen draws no second column. It renders
 * nothing while the column is collapsed or hidden, as the column's other lists don't show then.
 * The content keeps this screen's React context, so it can share state with the page.
 *
 * In the native Mac app the shell draws the column. A screen passes `native` (its list as a
 * NavModel) and the page renders nothing here; a screen that doesn't yet keeps its children in a
 * fallback column inside the content area. nav.* commands for the model's id go to `native.onCommand`;
 * nav.activate on an item with an href navigates by itself.
 */
export function NavigatorPortal({ children, native }: { children?: ReactNode; native?: NativeNavigator }) {
  const isNative = useIsNativeShell();
  const slot = useSyncExternalStore(subscribeNavigator, navigatorSlot, () => null);
  const fallback = useSyncExternalStore(subscribeNavigator, fallbackSlot, () => null);
  const router = useRouter();
  useEffect(() => claimNavigator(), []);

  const model = isNative ? native?.model : undefined;
  const json = model ? JSON.stringify(model) : null;
  const handler = useRef(native?.onCommand);
  useEffect(() => {
    handler.current = native?.onCommand;
  });
  useEffect(() => {
    if (!json) return;
    const token = Symbol("navigator");
    const parsed = JSON.parse(json) as NavModel;
    publisher.setScreen(token, parsed);
    const off = onCommand((cmd) => routeNavCommand(parsed, cmd, (href) => router.push(href), handler.current, openInNewTab));
    return () => {
      off();
      publisher.setScreen(token, null);
    };
  }, [json, router]);

  const inFallback = isNative && !native;
  useEffect(() => {
    if (!inFallback) return;
    const token = Symbol("fallback");
    publisher.setFallback(token, true);
    return () => publisher.setFallback(token, false);
  }, [inFallback]);

  if (isNative) return inFallback && fallback ? createPortal(children, fallback) : null;
  return slot ? createPortal(children, slot) : null;
}
