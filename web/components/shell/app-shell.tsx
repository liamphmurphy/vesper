"use client";

import { usePathname, useSearchParams } from "next/navigation";
import { Suspense, useEffect, type ReactNode } from "react";
import { isStandaloneCustomAppRoute } from "@/lib/custom-app-bridge";
import { onCommand, post } from "@/lib/native-shell/bridge";
import { LiveUpdates } from "./live-updates";
import { DocumentTitle } from "./document-title";
import { NativeShellHost } from "./native-shell";
import { applyNativeAppearance } from "./theme";

const PAGE = "flex min-h-0 min-w-0 flex-1 flex-col";

/** Minimal native shell sync for standalone Custom App windows (appearance only, no workbench chrome). */
function StandaloneNativeBridge({ pathname }: { pathname: string }) {
  useEffect(() => {
    post({ v: 1, type: "ready", path: pathname });
  }, [pathname]);
  useEffect(
    () =>
      onCommand((cmd) => {
        if (cmd.type === "appearance") applyNativeAppearance(cmd);
      }),
    [],
  );
  return null;
}

function EmbeddedShell({ children }: { children: ReactNode }) {
  return (
    <div className="flex min-h-dvh overflow-x-clip bg-bg text-fg">
      <LiveUpdates />
      <Suspense fallback={null}>
        <DocumentTitle />
      </Suspense>
      <Suspense fallback={null}>
        <NativeShellHost />
      </Suspense>
      <main className="flex min-w-0 flex-1 flex-col">
        <Suspense fallback={<div className={PAGE}>{children}</div>}>
          <div className={PAGE}>{children}</div>
        </Suspense>
      </main>
    </div>
  );
}

function AppShellRouter({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  if (isStandaloneCustomAppRoute(pathname, searchParams.toString())) {
    return (
      <div className="flex h-dvh min-h-0 overflow-hidden bg-bg text-fg">
        <LiveUpdates />
        <StandaloneNativeBridge pathname={pathname} />
        <main className="flex min-h-0 min-w-0 flex-1 flex-col">{children}</main>
      </div>
    );
  }
  return <EmbeddedShell>{children}</EmbeddedShell>;
}

/**
 * Minimal embedded shell for the remaining web surfaces (Custom Apps, rich editors, artifact mockup editor).
 * Standalone Custom App routes (`/apps/<slug>?standalone=1`) render chromeless with appearance sync only.
 */
export function AppShell({ children }: { children: ReactNode }) {
  return (
    <Suspense fallback={<div className="flex min-h-dvh bg-bg text-fg">{children}</div>}>
      <AppShellRouter>{children}</AppShellRouter>
    </Suspense>
  );
}
