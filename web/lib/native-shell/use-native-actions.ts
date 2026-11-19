"use client";

import { splitActions, type NativeAction } from "./actions.ts";
import { useNativeToolbar } from "./use-native-toolbar.ts";

/**
 * Publishes a screen's header actions to the native toolbar. Returns true when the screen gave
 * actions so `PageHeader` omits duplicate web action buttons while screens without `nativeActions`
 * still render their own controls.
 */
export function useNativeActions(actions: readonly NativeAction[] | undefined): boolean {
  const { items, dispatch } = splitActions(actions ?? []);
  useNativeToolbar({ items, onAction: dispatch });
  return !!actions;
}
