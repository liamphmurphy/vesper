"use client";

import Link from "next/link";
import { useCallback, useMemo, useSyncExternalStore, type ReactNode } from "react";
import type { WikiPageSummary } from "@/lib/api/client";
import { useArtifacts } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { timelineTime } from "@/lib/format";
import { ancestors, buildTree, type Folder } from "@/lib/wiki";
import { wikiHref } from "@/lib/wikilinks";
import { findNavItem } from "@/lib/native-shell/nav-model";
import { buildWikiNavModel } from "@/lib/native-shell/models/wiki";
import type { NativeCommand } from "@/lib/native-shell/protocol";
import { Icon } from "@/components/ui/icon";
import { Skeleton } from "@/components/ui/primitives";

type Tree = Folder<WikiPageSummary>;

/** Which wiki index is showing, for highlighting its tree row. */
export type WikiIndex = "patterns" | "adrs";

// ------------------------------------------------------------ open state

const OPEN_KEY = "lazyagents.wiki.open";
const OPEN_CHANGED = "lazyagents:wiki-open";
// Fallback when storage is unavailable (private mode), so toggles still apply until reload.
let openFallback = "[]";

function subscribeOpen(onChange: () => void) {
  window.addEventListener("storage", onChange);
  window.addEventListener(OPEN_CHANGED, onChange);
  return () => {
    window.removeEventListener("storage", onChange);
    window.removeEventListener(OPEN_CHANGED, onChange);
  };
}

function readOpen(): string {
  try {
    return window.localStorage.getItem(OPEN_KEY) ?? openFallback;
  } catch {
    return openFallback;
  }
}

/** Open folders, saved per device. Keys are lowercased folder paths (or a namespace id). */
function useOpenFolders() {
  const raw = useSyncExternalStore(subscribeOpen, readOpen, () => "[]");
  const open = useMemo(() => {
    try {
      const v: unknown = JSON.parse(raw);
      return new Set(Array.isArray(v) ? v.filter((x): x is string => typeof x === "string") : []);
    } catch {
      return new Set<string>();
    }
  }, [raw]);
  const toggle = useCallback(
    (key: string, next: boolean) => {
      const s = new Set(open);
      if (next) s.add(key);
      else s.delete(key);
      openFallback = JSON.stringify([...s]);
      try {
        window.localStorage.setItem(OPEN_KEY, openFallback);
      } catch {
        // Storage unavailable: openFallback keeps it for this page.
      }
      window.dispatchEvent(new Event(OPEN_CHANGED));
    },
    [open],
  );
  return { open, toggle };
}

function splitPages(pages: WikiPageSummary[] | undefined) {
  const published = (pages ?? []).filter((p) => p.published);
  const isMemory = (p: WikiPageSummary) => p.path.toLowerCase().startsWith("agents/");
  return { team: buildTree(published.filter((p) => !isMemory(p))), memory: buildTree(published.filter(isMemory), "agents/") };
}

function forcedFolders(current: string, index?: WikiIndex) {
  const s = new Set(current ? ancestors(current) : []);
  if (index === "patterns") s.add("patterns");
  if (index === "adrs") s.add("architecture");
  return s;
}

/** The wiki tree for the native sidebar: the same folders, open state and Reports as <PageTree>, and the commands the shell sends. */
export function useWikiNative(pages: WikiPageSummary[] | undefined, current: string, index?: WikiIndex) {
  const { open, toggle } = useOpenFolders();
  const { team, memory } = useMemo(() => splitPages(pages), [pages]);
  const forced = useMemo(() => forcedFolders(current, index), [current, index]);
  const reports = useArtifacts({ type: "report" });
  const list = reports.data?.artifacts ?? [];
  const other = { ...team, folders: new Map([...team.folders].filter(([k]) => k !== "architecture" && k !== "patterns")) };
  const model = buildWikiNavModel({
    loaded: !!pages,
    current,
    index,
    architecture: team.folders.get("architecture"),
    patterns: team.folders.get("patterns"),
    memory,
    other,
    reports: { state: reports.isError ? "error" : !reports.data ? "loading" : "ready", list, total: reports.data?.counts.report ?? list.length },
    open,
    forced,
  });
  const onCommand = (cmd: NativeCommand) => {
    if (cmd.type !== "nav.toggle" && cmd.type !== "nav.activate") return;
    if (!cmd.itemId.startsWith("f:")) return;
    const key = cmd.itemId.slice(2);
    if (forced.has(key)) return;
    // A folder row without a page toggles on click, as in the page.
    if (cmd.type === "nav.toggle") toggle(key, cmd.expanded);
    else if (!findNavItem(model, cmd.itemId)?.href) toggle(key, !open.has(key));
  };
  return { model, onCommand };
}

type TreeCtx = { current: string; forced: Set<string>; open: Set<string>; toggle: (key: string, next: boolean) => void };

// ------------------------------------------------------------ rows

const sortBy = <T,>(xs: T[], key: (x: T) => string) => [...xs].sort((a, b) => key(a).localeCompare(key(b)));
const indent = (depth: number) => ({ paddingLeft: 4 + depth * 12 });

function Count({ n, label }: { n: number; label?: string }) {
  return (
    <span className="ml-auto flex-none pl-2 font-mono text-12 text-fg-tertiary" title={label ?? `${n} pages`}>
      {n}
    </span>
  );
}

/** A tree row that links somewhere; the current one gets the accent bar. */
function RowLink({ href, on, depth, icon, children, right }: { href: string; on: boolean; depth: number; icon?: ReactNode; children: ReactNode; right?: ReactNode }) {
  return (
    <Link
      href={href}
      aria-current={on ? "page" : undefined}
      className={cx(
        "relative flex h-7 items-center gap-1.5 rounded-sm pr-2 text-13",
        on ? "bg-selected font-medium text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg",
      )}
      style={{ paddingLeft: 32 + depth * 12 }}
    >
      {on && <span aria-hidden className="absolute top-1.5 bottom-1.5 left-0 w-[2.5px] rounded-full bg-accent" />}
      {icon}
      <span className="min-w-0 flex-1 truncate">{children}</span>
      {right}
    </Link>
  );
}

function PageRow({ p, depth, ctx }: { p: WikiPageSummary; depth: number; ctx: TreeCtx }) {
  return (
    <li>
      <RowLink
        href={wikiHref(p.path)}
        on={p.path.toLowerCase() === ctx.current.toLowerCase()}
        depth={depth}
        icon={<Icon name="artifacts" size={13} className="flex-none text-fg-tertiary" />}
        right={
          p.suggestions > 0 ? (
            <span className="font-mono text-11 text-pill-human-fg" title={`${p.suggestions} suggested edits`}>
              {p.suggestions}
            </span>
          ) : undefined
        }
      >
        {p.title}
      </RowLink>
    </li>
  );
}

/** A collapsible row: chevron button (aria-expanded) and a name that links to the folder's page, if any. */
function FolderRow({
  id,
  name,
  count,
  countLabel,
  depth,
  ctx,
  href,
  on = false,
  hint,
  ariaName,
  children,
}: {
  id: string;
  /** Distinguishes nested folders that share a name ("Patterns/Architecture"). */
  ariaName?: string;
  name: ReactNode;
  count: number;
  countLabel?: string;
  depth: number;
  ctx: TreeCtx;
  href?: string;
  on?: boolean;
  hint?: ReactNode;
  children: ReactNode;
}) {
  const forced = ctx.forced.has(id);
  const expanded = forced || ctx.open.has(id);
  const label = ariaName ?? (typeof name === "string" ? name : id);
  return (
    <li>
      <div className={cx("relative flex h-7 items-center rounded-sm", on && "bg-selected")} style={indent(depth)}>
        {on && <span aria-hidden className="absolute top-1.5 bottom-1.5 left-0 w-[2.5px] rounded-full bg-accent" />}
        <button
          type="button"
          aria-expanded={expanded}
          aria-disabled={forced || undefined}
          aria-label={`${expanded ? "Collapse" : "Expand"} ${label}`}
          title={forced ? "Contains the current page" : undefined}
          onClick={() => !forced && ctx.toggle(id, !expanded)}
          className="grid size-6 flex-none place-items-center rounded-sm text-fg-tertiary hover:bg-hover"
        >
          <Icon name={expanded ? "chev" : "chevr"} size={12} />
        </button>
        {href ? (
          <Link
            href={href}
            aria-current={on ? "page" : undefined}
            className={cx("flex h-7 min-w-0 flex-1 items-center gap-2 rounded-sm px-1 text-13 font-medium", on ? "text-fg" : "text-fg-2 hover:bg-hover")}
          >
            <span className="truncate">{name}</span>
            {hint}
          </Link>
        ) : (
          <button
            type="button"
            tabIndex={-1}
            onClick={() => !forced && ctx.toggle(id, !expanded)}
            className="flex h-7 min-w-0 flex-1 items-center gap-2 px-1 text-left text-13 font-medium text-fg-2"
          >
            <span className="truncate">{name}</span>
            {hint}
          </button>
        )}
        <Count n={count} label={countLabel} />
      </div>
      {expanded && children}
    </li>
  );
}

function FolderNode({ f, depth, ctx, label }: { f: Tree; depth: number; ctx: TreeCtx; label?: string }) {
  return (
    <FolderRow
      id={f.path.toLowerCase()}
      name={label ?? f.name}
      ariaName={f.path}
      count={f.count}
      depth={depth}
      ctx={ctx}
      href={f.page ? wikiHref(f.page.path) : undefined}
      on={!!f.page && f.page.path.toLowerCase() === ctx.current.toLowerCase()}
    >
      <TreeList f={f} depth={depth + 1} ctx={ctx} />
    </FolderRow>
  );
}

function TreeList({ f, depth, ctx, first, folderLabel }: { f: Tree; depth: number; ctx: TreeCtx; first?: ReactNode; folderLabel?: (f: Tree) => string }) {
  return (
    <ul className="flex flex-col">
      {first}
      {sortBy([...f.folders.values()], (x) => x.name.toLowerCase()).map((c) => (
        <FolderNode key={c.path} f={c} depth={depth} ctx={ctx} label={folderLabel?.(c)} />
      ))}
      {sortBy(f.pages, (p) => p.title.toLowerCase()).map((p) => (
        <PageRow key={p.id} p={p} depth={depth} ctx={ctx} />
      ))}
    </ul>
  );
}

function IndexRow({ href, on, depth, children, hint }: { href: string; on: boolean; depth: number; children: ReactNode; hint?: string }) {
  return (
    <li>
      <RowLink href={href} on={on} depth={depth} icon={<Icon name="tickets" size={13} className="flex-none text-fg-tertiary" />} right={hint && <span className="text-11 text-fg-tertiary">{hint}</span>}>
        {children}
      </RowLink>
    </li>
  );
}

// ------------------------------------------------------------ reports

function Reports({ depth, ctx }: { depth: number; ctx: TreeCtx }) {
  const reports = useArtifacts({ type: "report" });
  const list = reports.data?.artifacts ?? [];
  const total = reports.data?.counts.report ?? list.length;
  const newest = [...list].sort((a, b) => b.updated_at.localeCompare(a.updated_at)).slice(0, 5);
  return (
    <FolderRow id="ns:reports" name="Reports" count={total} countLabel={`${total} reports`} depth={depth} ctx={ctx}>
      <ul className="flex flex-col">
        {reports.isError ? (
          <li className="py-1 text-12 text-fg-tertiary" style={{ paddingLeft: 44 + depth * 12 }}>
            Couldn&apos;t load reports.
          </li>
        ) : !reports.data ? (
          <li className="py-1" style={{ paddingLeft: 44 + depth * 12 }}>
            <Skeleton className="h-3 w-2/3" />
          </li>
        ) : newest.length === 0 ? (
          <li className="py-1 text-12 text-fg-tertiary" style={{ paddingLeft: 44 + depth * 12 }}>
            No reports yet.
          </li>
        ) : (
          newest.map((r) => (
            <li key={r.id}>
              <RowLink
                href={`/artifacts/${r.id}`}
                on={false}
                depth={depth + 1}
                right={
                  <span className="flex-none font-mono text-11 text-fg-tertiary">
                    {r.project?.key ? `${r.project.key} · ` : ""}
                    {timelineTime(r.updated_at)}
                  </span>
                }
              >
                {r.title}
              </RowLink>
            </li>
          ))
        )}
        {total > newest.length && (
          <li>
            <Link href="/library?source=projects&type=report" className="flex h-7 items-center text-12 text-accent hover:underline" style={{ paddingLeft: 44 + depth * 12 }}>
              All {total} reports →
            </Link>
          </li>
        )}
      </ul>
    </FolderRow>
  );
}

// ------------------------------------------------------------ tree

/**
 * The wiki tree (docs/dev/plan.md §12.6): the namespaces Architecture, Patterns,
 * Agent memory (agents/) and Reports, then other pages. Each folder shows
 * its page count; open folders are remembered per device and the current
 * page's folders are always open.
 */
export function PageTree({ pages, current, index }: { pages: WikiPageSummary[] | undefined; current: string; index?: WikiIndex }) {
  const { open, toggle } = useOpenFolders();
  const { team, memory } = useMemo(() => splitPages(pages), [pages]);
  const forced = useMemo(() => forcedFolders(current, index), [current, index]);

  if (!pages) {
    return (
      <div aria-busy="true" className="flex flex-col gap-2 p-2">
        {[70, 55, 80, 50].map((w) => (
          <Skeleton key={w} className="h-3" style={{ width: `${w}%` }} />
        ))}
      </div>
    );
  }

  const ctx: TreeCtx = { current, forced, open, toggle };
  const arch = team.folders.get("architecture");
  const patterns = team.folders.get("patterns");
  const other: Tree = {
    ...team,
    folders: new Map([...team.folders].filter(([k]) => k !== "architecture" && k !== "patterns")),
  };
  const empty: Tree = { name: "", path: "", folders: new Map(), pages: [], count: 0 };

  return (
    <nav aria-label="Wiki pages" className="flex flex-col gap-4">
      <div className="flex flex-col gap-1">
        <h2 className="px-2 text-12 font-medium text-fg-tertiary">Namespaces</h2>
        <ul className="flex flex-col">
          <FolderRow
            id="architecture"
            name="Architecture"
            count={arch?.count ?? 0}
            depth={0}
            ctx={ctx}
            href={arch?.page ? wikiHref(arch.page.path) : undefined}
            on={!!arch?.page && arch.page.path.toLowerCase() === current.toLowerCase()}
          >
            <TreeList
              f={arch ?? empty}
              depth={1}
              ctx={ctx}
              first={
                <IndexRow href="/wiki?index=adrs" on={index === "adrs"} depth={1}>
                  ADR index
                </IndexRow>
              }
            />
          </FolderRow>
          <FolderRow
            id="patterns"
            name="Patterns"
            count={patterns?.count ?? 0}
            depth={0}
            ctx={ctx}
            href={patterns?.page ? wikiHref(patterns.page.path) : undefined}
            on={!!patterns?.page && patterns.page.path.toLowerCase() === current.toLowerCase()}
          >
            <TreeList
              f={patterns ?? empty}
              depth={1}
              ctx={ctx}
              first={
                <IndexRow href="/wiki?index=patterns" on={index === "patterns"} depth={1} hint="by tag">
                  Pattern index
                </IndexRow>
              }
            />
          </FolderRow>
          <FolderRow
            id="agents"
            name="Agent memory"
            hint={<span className="font-mono text-11 font-normal text-fg-tertiary">agents/</span>}
            count={memory.count}
            depth={0}
            ctx={ctx}
          >
            {memory.count ? (
              <TreeList f={memory} depth={1} ctx={ctx} folderLabel={(f) => (f.path.split("/").length === 2 ? `@${f.name}` : f.name)} />
            ) : (
              <p className="py-1 pl-11 text-12 text-fg-tertiary">Agents add notes here as they work.</p>
            )}
          </FolderRow>
          <Reports depth={0} ctx={ctx} />
        </ul>
      </div>
      <div className="flex flex-col gap-1">
        <h2 className="px-2 text-12 font-medium text-fg-tertiary">Other pages</h2>
        {other.folders.size + other.pages.length ? (
          <TreeList f={other} depth={0} ctx={ctx} />
        ) : (
          <p className="px-2 text-12 text-fg-tertiary">No other pages yet.</p>
        )}
      </div>
    </nav>
  );
}
