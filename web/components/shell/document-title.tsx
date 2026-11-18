"use client";

import { usePathname } from "next/navigation";
import { useEffect } from "react";
import { isNativeShell } from "@/lib/native-shell/bridge";
import { publishTitle } from "@/lib/native-shell/title";
import { cleanHeadingTitle, formatDocumentTitle, routeFallbackTitle } from "@/lib/document-title";

function readActiveTitle(pathname: string): string {
  const main = document.querySelector("main");
  const heading =
    cleanHeadingTitle(main?.querySelector("h1")?.textContent) ||
    cleanHeadingTitle(main?.querySelector('[aria-label="Breadcrumb"] [aria-current="page"]')?.textContent) ||
    routeFallbackTitle(pathname);
  return formatDocumentTitle(heading);
}

/** Keeps the browser tab title aligned with the active page or route. */
export function DocumentTitle() {
  const pathname = usePathname();
  useEffect(() => {
    const apply = () => {
      const next = readActiveTitle(pathname);
      if (document.title !== next) document.title = next;
      // The native shell shows the title itself (minus the suffix); it dedupes unchanged ones.
      if (isNativeShell()) publishTitle();
    };
    apply();

    const onFocus = () => apply();
    const onVisibility = () => {
      if (document.visibilityState === "visible") apply();
    };
    window.addEventListener("focus", onFocus);
    document.addEventListener("visibilitychange", onVisibility);

    const observers: MutationObserver[] = [];
    const main = document.querySelector("main");
    if (main) {
      const mainObs = new MutationObserver(apply);
      mainObs.observe(main, { childList: true, subtree: true, characterData: true });
      observers.push(mainObs);
    }
    if (document.head) {
      const headObs = new MutationObserver(apply);
      headObs.observe(document.head, { childList: true, subtree: true, characterData: true });
      observers.push(headObs);
    }

    return () => {
      window.removeEventListener("focus", onFocus);
      document.removeEventListener("visibilitychange", onVisibility);
      for (const obs of observers) obs.disconnect();
    };
  }, [pathname]);
  return null;
}
