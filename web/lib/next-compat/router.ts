// The one place that knows the app's data router. next/navigation and next/link
// (the shims beside this file) call through it, so ~200 files keep Next's API.
import { useEffect, useSyncExternalStore } from "react";
import { useLocation, type createBrowserRouter } from "react-router";
import { isNativeShell, post } from "../native-shell/bridge.ts";

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

/** Settings/Customization/Memory/Personas routes moved into the native Settings window on macOS. */
export function isNativeSettingsPath(pathname: string): boolean {
  const path = pathname.length > 1 ? pathname.replace(/\/+$/, "") : pathname;
  return (
    path === "/settings" ||
    path.startsWith("/settings/") ||
    path === "/customization" ||
    path.startsWith("/customization/") ||
    path === "/memory" ||
    path === "/personas" ||
    path === "/agents"
  );
}

export type NavigateOptions = { scroll?: boolean };

function go(href: string, replace: boolean, opts?: NavigateOptions) {
  setOverride(null);
  const url = new URL(href, window.location.href);
  if (isNativeShell() && url.origin === window.location.origin && isNativeSettingsPath(url.pathname)) {
    post({ v: 1, type: "openInMain", path: url.pathname + url.search + url.hash });
    return;
  }
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

/**
 * A URL written straight to window.history, until the data router has caught up with it. Next's
 * usePathname/useSearchParams follow such writes at once, and screens rely on it: a search box that
 * echoes its value into ?q= would otherwise see each echo arrive late and drop characters.
 *
 * Each write is numbered and handed to the router as location state ({foreignSeq}), so a committed
 * location says which write it holds. The override applies until the router commits that write (or a
 * later one); a navigation of the router's own, or Back/Forward, ends it.
 */
type Override = { seq: number; pathname: string; search: string };
type Loc = { pathname: string; search: string; state: unknown };
let override: Override | null = null;
let seq = 0;
const listeners = new Set<() => void>();
const subscribe = (l: () => void) => (listeners.add(l), () => void listeners.delete(l));
const getOverride = () => override;
function setOverride(o: Override | null) {
  override = o;
  listeners.forEach((l) => l());
}

const seqOf = (loc: Loc) => (loc.state as { foreignSeq?: number } | null)?.foreignSeq;
const applies = (o: Override, loc: Loc) => (seqOf(loc) ?? 0) < o.seq;

/** The location hooks read: the data router's, unless the URL was written around it. */
export function useLiveLocation(): { pathname: string; search: string } {
  const loc = useLocation();
  const o = useSyncExternalStore(subscribe, getOverride, getOverride);
  return o && applies(o, loc) ? { pathname: o.pathname, search: o.search } : { pathname: loc.pathname, search: loc.search };
}

/** Drops an override once the router has caught up with it or moved on. Mounted once, at the root. */
export function useOverrideJanitor() {
  const loc = useLocation();
  const o = useSyncExternalStore(subscribe, getOverride, getOverride);
  useEffect(() => {
    if (o && !applies(o, loc)) setOverride(null);
  }, [o, loc]);
}

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
  window.addEventListener("popstate", () => setOverride(null));
  for (const method of ["pushState", "replaceState"] as const) {
    const original = window.history[method].bind(window.history);
    window.history[method] = (state: unknown, unused: string, url?: string | URL | null) => {
      original(state, unused, url);
      if (isRouterState(state) || !dataRouter || url == null) return;
      const next = new URL(String(url), window.location.href);
      if (next.origin !== window.location.origin) return;
      const n = ++seq;
      setOverride({ seq: n, pathname: next.pathname, search: next.search });
      void dataRouter.navigate(next.pathname + next.search + next.hash, { replace: true, state: { foreignSeq: n }, preventScrollReset: true, flushSync: true });
    };
  }
}
