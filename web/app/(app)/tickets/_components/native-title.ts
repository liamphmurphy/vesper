"use client";

import { useEffect } from "react";
import { setTopBarTitle } from "@/lib/native-shell/title";

/** Sets the native window title (and subtitle) for a screen that draws no top bar. */
export function useNativeTitle(title: string, subtitle?: string) {
  useEffect(() => {
    if (!title) return;
    const token = Symbol("title");
    setTopBarTitle(token, { title, ...(subtitle ? { subtitle } : {}) });
    return () => setTopBarTitle(token, null);
  }, [title, subtitle]);
}
