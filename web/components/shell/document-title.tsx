"use client";

import { usePathname } from "next/navigation";
import { useEffect } from "react";
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
    };
    apply();
    const main = document.querySelector("main");
    if (!main) return;
    const observer = new MutationObserver(apply);
    observer.observe(main, { childList: true, subtree: true, characterData: true });
    return () => observer.disconnect();
  }, [pathname]);
  return null;
}
