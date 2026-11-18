// The wiki page tree (wiki/_components/page-tree.tsx) as a NavModel.
import { timelineTime } from "../../format.ts";
import { wikiHref } from "../../wikilinks.ts";
import type { NavItem, NavModel } from "../protocol.ts";

export const WIKI_NAV_ID = "wiki";

export interface WikiPageLike {
  id: string;
  path: string;
  title: string;
  suggestions: number;
}
export interface WikiFolderLike {
  name: string;
  path: string;
  folders: Map<string, WikiFolderLike>;
  pages: WikiPageLike[];
  page?: WikiPageLike;
  count: number;
}
export interface WikiReport {
  id: string;
  title: string;
  updated_at: string;
  project?: { key: string } | null;
}

export interface WikiNavInput {
  /** Undefined while the page list loads. */
  loaded: boolean;
  /** The page on screen (a path), or "". */
  current: string;
  index?: "patterns" | "adrs";
  architecture?: WikiFolderLike;
  patterns?: WikiFolderLike;
  memory: WikiFolderLike;
  other: WikiFolderLike;
  reports: { state: "loading" | "error" | "ready"; list: readonly WikiReport[]; total: number };
  /** Open folder keys (lowercased paths or ids) and the ones forced open (hold the current page). */
  open: ReadonlySet<string>;
  forced: ReadonlySet<string>;
  now?: number;
}

const byName = <T,>(xs: T[], key: (x: T) => string) => [...xs].sort((a, b) => key(a).localeCompare(key(b)));

export const wikiFolderItemId = (key: string) => `f:${key}`;
export const wikiPageItemId = (path: string) => `p:${path}`;

export function buildWikiNavModel(input: WikiNavInput): NavModel {
  if (!input.loaded) return { id: WIKI_NAV_ID, title: "Wiki", sections: [{ id: "loading", items: [], emptyText: "Loading" }] };
  const cur = input.current.toLowerCase();
  let selectedId: string | null = null;

  const pageItem = (p: WikiPageLike): NavItem => {
    const id = wikiPageItemId(p.path);
    if (p.path.toLowerCase() === cur) selectedId = id;
    const item: NavItem = { id, title: p.title, icon: "artifacts", href: wikiHref(p.path) };
    if (p.suggestions > 0) item.badge = { text: String(p.suggestions), tone: "human" };
    return item;
  };
  const folder = (key: string, title: string, count: number, children: NavItem[], page?: WikiPageLike, extra?: Partial<NavItem>): NavItem => {
    const id = wikiFolderItemId(key);
    const item: NavItem = { id, title, trailing: String(count), icon: "folder", children, expanded: input.forced.has(key) || input.open.has(key), ...extra };
    if (page) {
      item.href = wikiHref(page.path);
      if (page.path.toLowerCase() === cur) selectedId = id;
    }
    return item;
  };
  const treeItems = (f: WikiFolderLike, label?: (f: WikiFolderLike) => string): NavItem[] => [
    ...byName([...f.folders.values()], (x) => x.name.toLowerCase()).map((c) => folder(c.path.toLowerCase(), label?.(c) ?? c.name, c.count, treeItems(c, label), c.page)),
    ...byName(f.pages, (p) => p.title.toLowerCase()).map(pageItem),
  ];
  const indexRow = (id: "adrs" | "patterns", title: string, subtitle?: string): NavItem => {
    const item: NavItem = { id: `index:${id}`, title, icon: "tickets", href: `/wiki?index=${id}`, ...(subtitle ? { trailing: subtitle } : {}) };
    if (input.index === id) selectedId = item.id;
    return item;
  };

  const reportsChildren: NavItem[] =
    input.reports.state === "error"
      ? [{ id: "reports-error", title: "Couldn’t load reports.", disabled: true }]
      : input.reports.state === "loading"
        ? [{ id: "reports-loading", title: "Loading", disabled: true }]
        : input.reports.list.length === 0
          ? [{ id: "reports-empty", title: "No reports yet.", disabled: true }]
          : [...input.reports.list]
              .sort((a, b) => b.updated_at.localeCompare(a.updated_at))
              .slice(0, 5)
              .map((r) => ({
                id: `report:${r.id}`,
                title: r.title,
                href: `/artifacts/${r.id}`,
                trailing: `${r.project?.key ? `${r.project.key} · ` : ""}${timelineTime(r.updated_at, input.now)}`,
              }));
  if (input.reports.state === "ready" && input.reports.total > Math.min(5, input.reports.list.length)) {
    reportsChildren.push({ id: "reports-all", title: `All ${input.reports.total} reports →`, href: "/library?source=projects&type=report" });
  }

  const namespaces: NavItem[] = [
    folder("architecture", "Architecture", input.architecture?.count ?? 0, [indexRow("adrs", "ADR index"), ...(input.architecture ? treeItems(input.architecture) : [])], input.architecture?.page),
    folder("patterns", "Patterns", input.patterns?.count ?? 0, [indexRow("patterns", "Pattern index", "by tag"), ...(input.patterns ? treeItems(input.patterns) : [])], input.patterns?.page),
    folder(
      "agents",
      "Agent memory",
      input.memory.count,
      input.memory.count
        ? treeItems(input.memory, (f) => (f.path.split("/").length === 2 ? `@${f.name}` : f.name))
        : [{ id: "agents-empty", title: "Agents add notes here as they work.", disabled: true }],
      undefined,
      { subtitle: "agents/" },
    ),
    folder("ns:reports", "Reports", input.reports.total, reportsChildren),
  ];
  const other = treeItems(input.other);
  return {
    id: WIKI_NAV_ID,
    title: "Wiki",
    sections: [
      { id: "namespaces", title: "Namespaces", items: namespaces },
      { id: "other", title: "Other pages", items: other, emptyText: "No other pages yet." },
    ],
    selectedId,
  };
}
