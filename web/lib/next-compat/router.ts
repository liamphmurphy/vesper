// The one place that knows the app's data router. next/navigation and next/link
// (the shims beside this file) call through it, so ~200 files keep Next's API.
import type { createBrowserRouter } from "react-router";

type DataRouter = ReturnType<typeof createBrowserRouter>;

let dataRouter: DataRouter | undefined;

export function setDataRouter(router: DataRouter) {
  dataRouter = router;
  installHistorySync();
}

export function getDataRouter(): DataRouter {
  if (!dataRouter) throw new Error("next-compat: the router isn't mounted yet");
  return dataRouter;
}

/** Paths the server owns (API, MCP, SSE, the design worker): a link to one is a plain browser navigation. */
export function isServerPath(pathname: string): boolean {
  return /^\/(api|mcp|events|internal)(\/|$)/.test(pathname);
}

export type NavigateOptions = { scroll?: boolean };

function go(href: string, replace: boolean, opts?: NavigateOptions) {
  const url = new URL(href, window.location.href);
  if (url.origin !== window.location.origin || isServerPath(url.pathname)) {
    if (replace) window.location.replace(url.href);
    else window.location.assign(url.href);
    return;
  }
  const done = getDataRouter().navigate(url.pathname + url.search + url.hash, { replace, preventScrollReset: true, flushSync: true });
  // Next scrolls to the top on every navigation unless scroll: false.
  if (opts?.scroll !== false) void done.then(() => window.scrollTo(0, 0));
}

/** Next's AppRouterInstance. A single stable object: effects list `router` as a dependency. */
export const appRouter = {
  push: (href: string, opts?: NavigateOptions) => go(href, false, opts),
  replace: (href: string, opts?: NavigateOptions) => go(href, true, opts),
  back: () => window.history.back(),
  forward: () => window.history.forward(),
  // Next re-fetches server components; nothing here is server-rendered, so there's nothing to refresh.
  refresh: () => {},
  prefetch: (href: string) => void href,
};

/** The data router's own history writes carry its {usr, key, idx} state. */
const isRouterState = (s: unknown) => typeof s === "object" && s !== null && "idx" in s && "key" in s;

/**
 * Next integrates window.history.pushState/replaceState with useSearchParams and
 * usePathname (board-screen.tsx relies on it). The URL still changes synchronously, as
 * the caller expects; the data router is then told, so its location catches up.
 */
let installed = false;
function installHistorySync() {
  if (installed) return;
  installed = true;
  for (const method of ["pushState", "replaceState"] as const) {
    const original = window.history[method].bind(window.history);
    window.history[method] = (state: unknown, unused: string, url?: string | URL | null) => {
      original(state, unused, url);
      if (isRouterState(state) || !dataRouter || url == null) return;
      const next = new URL(String(url), window.location.href);
      if (next.origin !== window.location.origin) return;
      void dataRouter.navigate(next.pathname + next.search + next.hash, { replace: true, preventScrollReset: true, flushSync: true });
    };
  }
}
