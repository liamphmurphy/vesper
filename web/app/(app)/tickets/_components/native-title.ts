"use client";

import { useEffect } from "react";
import { setTopBarTitle } from "@/lib/native-shell/title";
import { useIsNativeShell } from "@/lib/native-shell/hooks";

/**
 * The window title (and the line under it) of a screen that draws no top bar in the Mac app. In a
 * browser the bar's own breadcrumb is the title, so this does nothing.
 */
export function useNativeTitle(title: string, subtitle?: string) {
  const native = useIsNativeShell();
  useEffect(() => {
    if (!native || !title) return;
    const token = Symbol("title");
    setTopBarTitle(token, { title, ...(subtitle ? { subtitle } : {}) });
    return () => setTopBarTitle(token, null);
  }, [native, title, subtitle]);
}
