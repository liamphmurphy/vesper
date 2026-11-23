"use client";

import { useEffect } from "react";
import type { PageScope } from "@/lib/command-palette";
import { isNativeShell, post } from "@/lib/native-shell/bridge";
import { toPaletteRequest } from "@/lib/native-shell/palette";

export type OpenPaletteDetail = {
  scope?: PageScope | "all" | "page";
  includeAgent?: boolean;
  /** Text to start with, e.g. what was typed into the Mac app's toolbar search field. */
  query?: string;
};

/** Opens the native SwiftUI command palette globally or scoped to the current page. */
export function openCommandPalette(detail?: OpenPaletteDetail) {
  if (!isNativeShell()) return;
  const request = toPaletteRequest(detail, {
    pathname: typeof window !== "undefined" ? window.location.pathname : "/",
    search: typeof window !== "undefined" ? window.location.search : undefined,
  });
  post({ v: 1, type: "commandPalette.open", request });
}

/**
 * Keyboard proxy for web-hosted pages (Docs, Slides, Designs, Custom Apps) so ⌘K / ⇧⌘K
 * opens the native macOS SwiftUI Command Palette.
 */
export function CommandMenu() {
  useEffect(() => {
    if (!isNativeShell()) return;
    const key = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === "k") {
        e.preventDefault();
        openCommandPalette({ scope: e.shiftKey ? "page" : "all" });
      }
    };
    const onSearch = (e: Event) => {
      const detail = e instanceof CustomEvent ? (e.detail as OpenPaletteDetail | undefined) : undefined;
      openCommandPalette(detail);
    };
    window.addEventListener("keydown", key);
    window.addEventListener("la:search", onSearch);
    return () => {
      window.removeEventListener("keydown", key);
      window.removeEventListener("la:search", onSearch);
    };
  }, []);
  return null;
}
