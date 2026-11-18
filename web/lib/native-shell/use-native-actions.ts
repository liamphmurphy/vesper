"use client";

import { splitActions, type NativeAction } from "./actions.ts";
import { useIsNativeShell } from "./hooks.ts";
import { useNativeToolbar } from "./use-native-toolbar.ts";

/**
 * Publishes a screen's header actions to the native toolbar. Returns true when they are in the
 * toolbar (native shell, and the screen gave some), so the web row that draws the same actions
 * should not render. Pass undefined for a screen with nothing to move.
 */
export function useNativeActions(actions: readonly NativeAction[] | undefined): boolean {
  const native = useIsNativeShell();
  const { items, dispatch } = splitActions(actions ?? []);
  useNativeToolbar({ items, onAction: dispatch });
  return native && !!actions;
}
