"use client";

import { useEffect, useState } from "react";
import { WorkChat } from "@/components/domain/work-chat";
import { LiveUpdates } from "@/components/shell/live-updates";
import { setSystemAccent } from "@/components/shell/theme";
import { onCommand, post } from "@/lib/native-shell/bridge";
import { fromCompanionSubject } from "@/lib/native-shell/inspector-publisher";
import type { WorkSubject } from "@/lib/work-context";

/**
 * Window-level persistent companion host mounted inside macOS's native inspector WKWebView.
 * `<WorkChat />` stays mounted across main-pane route and tab switches; only `subject` updates via
 * `companion.context`, and internal links clicked inside the transcript route to the main pane.
 */
export default function NativeCompanionPage() {
  const [subject, setSubject] = useState<WorkSubject | undefined>();

  useEffect(() => {
    post({ v: 1, type: "ready", path: "/companion" });
    const offCommand = onCommand((cmd) => {
      if (cmd.type === "appearance") {
        setSystemAccent(cmd.accent);
      } else if (cmd.type === "companion.context") {
        setSubject(fromCompanionSubject(cmd.context.subject));
      }
    });

    function onDocumentClick(e: MouseEvent) {
      if (e.defaultPrevented || !(e.target instanceof Element)) return;
      const anchor = e.target.closest<HTMLAnchorElement>("a[href]");
      if (!anchor || anchor.hasAttribute("download")) return;
      const rawHref = anchor.getAttribute("href");
      if (!rawHref || rawHref.startsWith("#")) return;
      let url: URL;
      try {
        url = new URL(anchor.href, window.location.origin);
      } catch {
        return;
      }
      if (url.origin !== window.location.origin) return;
      if (!url.pathname.startsWith("/") || url.pathname === "/companion") return;
      e.preventDefault();
      e.stopPropagation();
      post({
        v: 1,
        type: "openInMain",
        path: `${url.pathname}${url.search}${url.hash}`,
        newTab: e.metaKey || e.ctrlKey || e.shiftKey || e.button === 1,
      });
    }

    document.addEventListener("click", onDocumentClick, true);
    return () => {
      offCommand();
      document.removeEventListener("click", onDocumentClick, true);
    };
  }, []);

  return (
    <div className="flex h-dvh min-h-0 flex-col bg-surface text-fg">
      <LiveUpdates />
      <WorkChat subject={subject} />
    </div>
  );
}
