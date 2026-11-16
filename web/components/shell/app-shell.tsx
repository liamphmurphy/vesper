"use client";

import { useRouter, useSelectedLayoutSegment } from "next/navigation";
import { Suspense, useEffect, type ReactNode } from "react";
import { useBootstrap } from "@/lib/api/hooks";
import { currentArea } from "@/lib/navigator";
import { useCompact } from "@/lib/viewport";
import { Skeleton } from "@/components/ui/primitives";
import { LiveUpdates } from "./live-updates";
import { ViewedChatReader } from "./viewed-chat-reader";
import { CommandMenu } from "./command-menu";
import { CompanionColumn } from "./companion";
import { DocumentTitle } from "./document-title";
import { shortcutBlocked, ShortcutsDialog } from "./shortcuts";
import { Sidebar } from "./sidebar";
import { SystemBanner } from "./system-banner";
import { TabBar } from "./tab-bar";

/** Global and area-scoped single-key shortcuts (DESIGN.md §6). */
function useShortcuts() {
  const router = useRouter();
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.defaultPrevented || shortcutBlocked(e)) return;
      if (e.key === "?") {
        e.preventDefault();
        window.dispatchEvent(new Event("la:shortcuts"));
        return;
      }
      if (
        (e.key === "c" || e.key === "C") &&
        currentArea(window.location.pathname) === "work" &&
        window.location.pathname !== "/tickets/new"
      ) {
        e.preventDefault();
        // Keep the project in view as the composer's default.
        const project = new URLSearchParams(window.location.search).get(
          "project",
        );
        router.push(
          `/tickets/new${project ? `?project=${encodeURIComponent(project)}` : ""}`,
        );
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [router]);
}

function SidebarSkeleton() {
  return (
    // Matches the menu's collapsed default (a slim icon strip).
    <aside
      aria-busy="true"
      className="flex w-[52px] max-md:hidden flex-none flex-col items-center gap-3 border-r border-border-subtle bg-sidebar px-1.5 pb-3.5 pt-3"
    >
      {[0, 1, 2, 3, 4, 5].map((i) => (
        <Skeleton key={i} className="size-[26px]" />
      ))}
    </aside>
  );
}

const PAGE = "flex min-h-0 min-w-0 flex-1 flex-col";

/**
 * Fades in a new section; navigation within one stays instant. CSS rather than <ViewTransition>:
 * a view transition around the page drops clicks and shortcuts made while it plays.
 */
function SectionFade({ children }: { children: ReactNode }) {
  const section = useSelectedLayoutSegment();
  // Work screens scroll within the viewport, with room for the banner and tab bar.
  const work = section === "work" || section === "runs" || section === "tickets";
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
  const compact = useCompact();
  useShortcuts();
  return (
    <div className={compact ? "flex min-h-dvh flex-col bg-bg text-fg" : "flex min-h-dvh bg-bg text-fg"}>
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
      {compact ? null : data ? (
        <Suspense fallback={<SidebarSkeleton />}>
          <Sidebar />
        </Suspense>
      ) : (
        <SidebarSkeleton />
      )}
      <main className={compact ? "flex min-w-0 flex-1 flex-col pb-[var(--tab-bar-h,0px)]" : "flex min-w-0 flex-1 flex-col"}>
        {/* The segment needs a Suspense boundary for prerendering; the page still paints meanwhile. */}
        <Suspense fallback={<div className={PAGE}><SystemBanner />{children}</div>}>
          <SectionFade>{children}</SectionFade>
        </Suspense>
      </main>
      {/* The companion: the page's own dock, or the work chat, in one place beside every page. */}
      {!compact && data && (
        <Suspense fallback={null}>
          <CompanionColumn />
        </Suspense>
      )}
      {compact && (
        <Suspense fallback={null}>
          <TabBar />
        </Suspense>
      )}
    </div>
  );
}
