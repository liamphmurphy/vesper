// next/navigation for the static app, on React Router's data router.
import { createContext, useContext, useMemo } from "react";
import { useLocation, useMatches } from "react-router";
import { appRouter } from "./router";

export const useRouter = () => appRouter;

export function usePathname(): string {
  return useLocation().pathname;
}

export type ReadonlyURLSearchParams = URLSearchParams;

export function useSearchParams(): ReadonlyURLSearchParams {
  const { search } = useLocation();
  return useMemo(() => new URLSearchParams(search), [search]);
}

/** A page file's directory, as route-group-free segments: ["tickets", "[key]"]. Set as a route's `handle`. */
export type RoutePattern = { pattern: string[] };

/**
 * Params from the raw (still percent-encoded) pathname, as Next hands them over:
 * pages decode them themselves. Catch-alls are string[]; an absent optional one is undefined.
 */
export function paramsFor(pattern: string[], pathname: string): Record<string, string | string[] | undefined> {
  const parts = pathname.split("/").filter(Boolean);
  const out: Record<string, string | string[] | undefined> = {};
  let i = 0;
  for (const seg of pattern) {
    const optional = /^\[\[\.\.\.(.+)\]\]$/.exec(seg);
    const rest = /^\[\.\.\.(.+)\]$/.exec(seg);
    const one = /^\[(.+)\]$/.exec(seg);
    if (optional) out[optional[1]] = i < parts.length ? parts.slice(i) : undefined;
    else if (rest) out[rest[1]] = parts.slice(i);
    else if (one) out[one[1]] = parts[i];
    if (optional || rest) i = parts.length;
    else i++;
  }
  return out;
}

export function useParams<T extends Record<string, string | string[] | undefined> = Record<string, string | string[] | undefined>>(): T {
  const { pathname } = useLocation();
  const matches = useMatches();
  const pattern = (matches[matches.length - 1]?.handle as RoutePattern | undefined)?.pattern;
  return useMemo(() => (pattern ? paramsFor(pattern, pathname) : {}) as T, [pattern, pathname]);
}

/** How many URL segments the layouts above (and including) this one consume. Set by each layout's host. */
export const LayoutDepthContext = createContext(0);

export function useSelectedLayoutSegments(): string[] {
  const { pathname } = useLocation();
  const depth = useContext(LayoutDepthContext);
  return useMemo(() => pathname.split("/").filter(Boolean).slice(depth), [pathname, depth]);
}

export function useSelectedLayoutSegment(): string | null {
  return useSelectedLayoutSegments()[0] ?? null;
}

const REDIRECT = "NEXT_REDIRECT";
const NOT_FOUND = "NEXT_NOT_FOUND";

export class NavigationSignal extends Error {
  digest: string;
  constructor(digest: string) {
    super(digest);
    this.digest = digest;
  }
}

/** Thrown in render; the NavigationBoundary at the app root performs it. */
export function redirect(url: string): never {
  throw new NavigationSignal(`${REDIRECT};${url}`);
}

export function notFound(): never {
  throw new NavigationSignal(NOT_FOUND);
}

export function signalOf(err: unknown): { kind: "redirect"; url: string } | { kind: "notFound" } | null {
  const digest = (err as { digest?: unknown } | null)?.digest;
  if (typeof digest !== "string") return null;
  if (digest === NOT_FOUND) return { kind: "notFound" };
  if (digest.startsWith(`${REDIRECT};`)) return { kind: "redirect", url: digest.slice(REDIRECT.length + 1) };
  return null;
}
