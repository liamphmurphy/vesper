// The route tree, generated from the web/app filesystem at build time (import.meta.glob),
// with Next's conventions: (route groups), [dynamic], [...catch-all], [[...optional]],
// nested layout.tsx, and page.tsx. Pages are code-split; layouts are bundled with the shell.
import { Component, createElement, useEffect, useMemo, type ComponentType, type ReactNode } from "react";
import { Outlet, createBrowserRouter, redirect as routerRedirect, useRouteError, type RouteObject } from "react-router";
import { LayoutDepthContext, paramsFor, signalOf, type RoutePattern } from "./navigation";
import { appRouter, setDataRouter, useLiveLocation, useOverrideJanitor } from "./router";
import { redirectFor } from "./redirects";

type PageModule = { default: ComponentType<Record<string, unknown>>; metadata?: { title?: string } };
type LayoutModule = { default: ComponentType<{ children: ReactNode }> };

const pageFiles = import.meta.glob<PageModule>("/app/**/page.tsx");
const layoutFiles = import.meta.glob<LayoutModule>("/app/**/layout.tsx", { eager: true });

/** A promise React's use() reads without suspending: Next hands pages their params and searchParams as promises. */
function settled<T>(value: T): Promise<T> {
  return Object.assign(Promise.resolve(value), { status: "fulfilled" as const, value });
}

function queryObject(search: string) {
  const out: Record<string, string | string[]> = {};
  for (const [k, v] of new URLSearchParams(search)) {
    const prev = out[k];
    out[k] = prev === undefined ? v : Array.isArray(prev) ? [...prev, v] : [prev, v];
  }
  return out;
}

function PageHost({ Page, pattern, title }: { Page: PageModule["default"]; pattern: string[]; title?: string }) {
  const { pathname, search } = useLiveLocation();
  const params = useMemo(() => settled(paramsFor(pattern, pathname)), [pattern, pathname]);
  const searchParams = useMemo(() => settled(queryObject(search)), [search]);
  useEffect(() => {
    if (title) document.title = title;
  }, [title]);
  return createElement(Page, { params, searchParams });
}

function LayoutHost({ Layout, depth }: { Layout: LayoutModule["default"]; depth: number }) {
  return (
    <LayoutDepthContext.Provider value={depth}>
      <Layout>
        <Outlet />
      </Layout>
    </LayoutDepthContext.Provider>
  );
}

type Dir = { seg: string; children: Map<string, Dir>; page?: () => Promise<PageModule>; layout?: LayoutModule["default"] };

function buildTree(): Dir {
  const root: Dir = { seg: "", children: new Map() };
  const dirOf = (file: string, leaf: string) => {
    let dir = root;
    for (const seg of file.slice("/app/".length, -`/${leaf}`.length).split("/").filter(Boolean)) {
      if (!dir.children.has(seg)) dir.children.set(seg, { seg, children: new Map() });
      dir = dir.children.get(seg)!;
    }
    return dir;
  };
  for (const [file, load] of Object.entries(pageFiles)) {
    if (file === "/app/page.tsx") root.page = load;
    else dirOf(file, "page.tsx").page = load;
  }
  for (const [file, mod] of Object.entries(layoutFiles)) {
    if (file === "/app/layout.tsx") root.layout = mod.default;
    else dirOf(file, "layout.tsx").layout = mod.default;
  }
  return root;
}

const isGroup = (s: string) => /^\(.+\)$/.test(s);
const isOptionalCatchAll = (s: string) => /^\[\[\.\.\..+\]\]$/.test(s);
const isCatchAll = (s: string) => /^\[\.\.\..+\]$/.test(s);

function rrPath(seg: string): string | undefined {
  if (isGroup(seg)) return undefined;
  if (isCatchAll(seg) || isOptionalCatchAll(seg)) return "*";
  const dyn = /^\[(.+)\]$/.exec(seg);
  return dyn ? `:${dyn[1]}` : seg;
}

function pageRoute(load: () => Promise<PageModule>, pattern: string[], path?: string): RouteObject {
  const handle: RoutePattern = { pattern };
  const base = {
    handle,
    lazy: async () => {
      const mod = await load();
      return { Component: () => <PageHost Page={mod.default} pattern={pattern} title={mod.metadata?.title} /> };
    },
  };
  return path ? { ...base, path } : { ...base, index: true };
}

function dirRoute(dir: Dir, pattern: string[]): RouteObject {
  const children: RouteObject[] = [];
  if (dir.page) children.push(pageRoute(dir.page, pattern));
  for (const child of dir.children.values()) {
    const childPattern = isGroup(child.seg) ? pattern : [...pattern, child.seg];
    if (isCatchAll(child.seg) || isOptionalCatchAll(child.seg)) {
      if (!child.page) continue;
      if (isOptionalCatchAll(child.seg)) children.push(pageRoute(child.page, childPattern));
      children.push(pageRoute(child.page, childPattern, "*"));
    } else children.push(dirRoute(child, childPattern));
  }
  const route: RouteObject = { path: rrPath(dir.seg), children };
  if (dir.layout) route.element = <LayoutHost Layout={dir.layout} depth={pattern.length} />;
  return route;
}

class NavigationBoundaryImpl extends Component<{ loc: string; children: ReactNode }, { err: unknown }> {
  state = { err: null as unknown };
  static getDerivedStateFromError(err: unknown) {
    return { err };
  }
  componentDidUpdate(prev: { loc: string }) {
    if (this.state.err && prev.loc !== this.props.loc) this.setState({ err: null });
  }
  render() {
    const { err } = this.state;
    if (err == null) return this.props.children;
    const signal = signalOf(err);
    if (signal?.kind === "redirect") return <Redirect to={signal.url} />;
    if (signal?.kind === "notFound") return <NotFound />;
    throw err;
  }
}

function Redirect({ to }: { to: string }) {
  useEffect(() => appRouter.replace(to), [to]);
  return null;
}

/** redirect() and notFound(), thrown from a page or layout as in Next, end up here. */
function NavigationBoundary({ children }: { children: ReactNode }) {
  useOverrideJanitor();
  const { pathname, search } = useLiveLocation();
  return <NavigationBoundaryImpl loc={pathname + search}>{children}</NavigationBoundaryImpl>;
}

export function NotFound() {
  return (
    <main className="grid min-h-dvh place-items-center px-4 text-center">
      <div>
        <h1 className="text-title font-semibold">404</h1>
        <p className="mt-2 text-fg-secondary">This page could not be found.</p>
        <a href="/" className="mt-4 inline-block text-accent underline">Go home</a>
      </div>
    </main>
  );
}

function RouteError({ error }: { error: unknown }) {
  const message = error instanceof Error ? error.message : String(error);
  return (
    <main className="grid min-h-dvh place-items-center px-4 text-center">
      <div>
        <h1 className="text-title font-semibold">Something went wrong</h1>
        <p className="mt-2 text-fg-secondary">{message}</p>
        <button type="button" className="mt-4 underline" onClick={() => window.location.reload()}>Reload</button>
      </div>
    </main>
  );
}

function RootError() {
  return <RouteError error={useRouteError()} />;
}

export function createAppRouter() {
  const tree = buildTree();
  const Root = tree.layout;
  const top = dirRoute({ ...tree, layout: undefined }, []);
  const router = createBrowserRouter([
    {
      // next.config.ts's redirects, performed before anything renders.
      loader: ({ request }) => {
        const to = redirectFor(new URL(request.url));
        return to ? routerRedirect(to) : null;
      },
      element: (
        <NavigationBoundary>
          {Root ? (
            <Root>
              <Outlet />
            </Root>
          ) : (
            <Outlet />
          )}
        </NavigationBoundary>
      ),
      errorElement: <RootError />,
      HydrateFallback: () => null,
      children: [...(top.children ?? []), { path: "*", element: <NotFound /> }],
    },
  ]);
  setDataRouter(router);
  return router;
}
