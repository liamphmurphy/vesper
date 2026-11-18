"use client";

import { useEffect, useRef, useSyncExternalStore, type RefObject } from "react";
import { isNativeShell, nativeContextMenu, onCommand } from "./bridge.ts";
import { keepsSystemMenu, splitMenu, type ContextMenuEntry } from "./context-menu.ts";
import type { NativeCommand } from "./protocol.ts";

const noSubscription = () => () => {};

/** Whether the page runs in the native shell. False on the server and the first render, so hydration matches. */
export function useIsNativeShell(): boolean {
  return useSyncExternalStore(noSubscription, isNativeShell, () => false);
}

/** Run `handler` for each shell command of this type. */
export function useNativeCommand<T extends NativeCommand["type"]>(type: T, handler: (cmd: Extract<NativeCommand, { type: T }>) => void): void {
  const ref = useRef(handler);
  useEffect(() => {
    ref.current = handler;
  });
  useEffect(
    () =>
      onCommand((cmd) => {
        if (cmd.type === type) ref.current(cmd as Extract<NativeCommand, { type: T }>);
      }),
    [type],
  );
}

/** Run `handler` for every shell command. */
export function useAnyNativeCommand(handler: (cmd: NativeCommand) => void): void {
  const ref = useRef(handler);
  useEffect(() => {
    ref.current = handler;
  });
  useEffect(() => onCommand((cmd) => ref.current(cmd)), []);
}

/**
 * In the Mac app, right-clicking the element shows `build()` as a native menu and runs the chosen
 * entry's onSelect. In the browser it does nothing, so the browser's menu is unchanged. Fields,
 * editable text, a text selection and (unless `links` is "menu") links keep the system menu.
 * `target` picks the element to listen on from `ref`'s, e.g. the message a toolbar floats over.
 * An inner element's menu wins over an outer one's.
 */
export function useNativeContextMenu(
  ref: RefObject<HTMLElement | null>,
  build: () => ContextMenuEntry[],
  opts: { links?: "system" | "menu"; target?: (el: HTMLElement) => HTMLElement | null } = {},
): void {
  const buildRef = useRef(build);
  const targetRef = useRef(opts.target);
  useEffect(() => {
    buildRef.current = build;
    targetRef.current = opts.target;
  });
  const links = opts.links ?? "system";
  useEffect(() => {
    if (!isNativeShell() || !ref.current) return;
    const el = targetRef.current ? targetRef.current(ref.current) : ref.current;
    if (!el) return;
    const onMenu = (e: MouseEvent) => {
      if (e.defaultPrevented) return;
      const sel = window.getSelection();
      const selectionInside = !!sel && !sel.isCollapsed && sel.rangeCount > 0 && el.contains(sel.getRangeAt(0).commonAncestorContainer);
      if (keepsSystemMenu(e.target instanceof Element ? e.target : null, { selectionInside, links })) return;
      const { items, handlers } = splitMenu(buildRef.current());
      if (items.length === 0) return;
      e.preventDefault();
      void nativeContextMenu(items, e.clientX, e.clientY).then((id) => {
        if (id) handlers.get(id)?.();
      });
    };
    el.addEventListener("contextmenu", onMenu);
    return () => el.removeEventListener("contextmenu", onMenu);
  }, [ref, links]);
}
