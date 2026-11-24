"use client";

import { useRouter, useSelectedLayoutSegment } from "next/navigation";
import { Suspense, useEffect, type ReactNode } from "react";
import { useBootstrap } from "@/lib/api/hooks";
import { useDevWorkspace } from "@/lib/api/dev-workspace-hooks";
import { currentArea } from "@/lib/navigator";
import { LiveUpdates } from "./live-updates";
import { ViewedChatReader } from "./viewed-chat-reader";
import { CommandMenu } from "./command-menu";
import { CompanionColumn } from "./companion";
import { DocumentTitle } from "./document-title";
import { shortcutBlocked, ShortcutsDialog } from "./shortcuts";
import { NativeShellHost } from "./native-shell";
import { SystemBanner } from "./system-banner";

/** Global and area-scoped single-key shortcuts (DESIGN.md §6). */
function useShortcuts() {
  const router = useRouter();
  const devEnabled = !!useDevWorkspace().data?.enabled;
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      // HTTP Client and Dev workspace left the right rail for the Apps menu; ⌘⇧H and ⌘⇧D stay as the
      // jump-and-return toggles for them.
      const toggle = (e.metaKey || e.ctrlKey) && e.shiftKey ? ({ h: "/http", d: "/dev" } as Record<string, string>)[e.key.toLowerCase()] : undefined;
      if (toggle && (toggle !== "/dev" || devEnabled)) {
        e.preventDefault();
        if (window.location.pathname.startsWith(toggle)) {
          if (window.history.length > 1) router.back();
          else router.push("/");
        } else {
          router.push(toggle);
        }
        return;
      }
      if (e.defaultPrevented || shortcutBlocked(e)) return;
      if (e.key === "?") {
        e.preventDefault();
        window.dispatchEvent(new Event("la:shortcuts"));
        return;
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [router, devEnabled]);
}

const PAGE = "flex min-h-0 min-w-0 flex-1 flex-col";

/**
 * Fades in a new section; navigation within one stays instant. CSS rather than <ViewTransition>:
 * a view transition around the page drops clicks and shortcuts made while it plays.
 */
function SectionFade({ children }: { children: ReactNode }) {
  const section = useSelectedLayoutSegment();
  // Work screens scroll within the viewport, with room for the banner and tab bar.
  const work = section === "work" || section === "runs" || section === "tickets" || section === "epics";
  return (
    <div key={section} className={`motion-page ${work ? "flex h-app min-h-0 min-w-0 flex-none flex-col overflow-hidden" : PAGE}`}>
      <SystemBanner />
      {work ? (
        <div className="relative flex min-h-0 flex-1 flex-col overflow-auto">{children}</div>
      ) : children}
    </div>
  );
}

/**
 * Wide: a wrapping flex row with the sidebar beside the content. Below COMPACT:
 * the content over a bottom tab bar, which detail screens hide (DESIGN.md §3 Responsive).
 */
export function AppShell({ children }: { children: ReactNode }) {
  const { data } = useBootstrap();
  useShortcuts();
  return (
    <div className="flex min-h-dvh overflow-x-clip bg-bg text-fg">
      <LiveUpdates />
      {/* usePathname needs a Suspense boundary for prerendering. */}
      <Suspense fallback={null}>
        <DocumentTitle />
        <CommandMenu />
      </Suspense>
      <ShortcutsDialog />
      {/* Read tracking stays mounted even when the sidebar is hidden. */}
      <Suspense fallback={null}>
        <ViewedChatReader />
      </Suspense>
      <Suspense fallback={null}>
        <NativeShellHost />
      </Suspense>
      <main className="flex min-w-0 flex-1 flex-col">
        {/* The segment needs a Suspense boundary for prerendering; the page still paints meanwhile. */}
        <Suspense fallback={<div className={PAGE}><SystemBanner />{children}</div>}>
          <SectionFade>{children}</SectionFade>
        </Suspense>
      </main>
      {/* The companion: the page's own dock, or the work chat, in one place beside every page. */}
      {data && (
        <Suspense fallback={null}>
          <CompanionColumn />
        </Suspense>
      )}
    </div>
  );
}
