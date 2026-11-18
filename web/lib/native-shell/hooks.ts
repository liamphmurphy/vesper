"use client";

import { useEffect, useRef, useSyncExternalStore } from "react";
import { isNativeShell, onCommand } from "./bridge.ts";
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
