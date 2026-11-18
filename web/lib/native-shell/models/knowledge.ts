// The Knowledge explorer (knowledge/_components/shell.tsx Explorer) as a NavModel: the header
// buttons and "+" menu, the Yours / Agent knowledge switch, Home, pinned pages, the folder tree with
// per-row menus, and the Today / Quick capture / Import entries.
import type { MenuItem, NavItem, NavModel } from "../protocol.ts";

export const KNOWLEDGE_NAV_ID = "knowledge";

export interface KPage {
  id: string;
  title: string;
  path: string;
  pending?: number;
}
export interface KFolder {
  name: string;
  path: string;
  folders: KFolder[];
  pages: KPage[];
  count: number;
}

/** Action ids (header buttons, the + menu's items, row menu items) and picker/item ids. */
export const K = {
  graph: "graph",
  connect: "connect",
  collapse: "collapse-all",
  search: "search",
  newMenu: "new",
  newDoc: "new:doc",
  newFolder: "new:folder",
  deck: (key: string) => `new:deck:${key}`,
  design: (key: string) => `new:design:${key}`,
  viewPicker: "view",
  home: "home",
  today: "today",
  capture: "capture",
  import: "import",
  page: (id: string) => `p:${id}`,
  pinned: (id: string) => `pin:${id}`,
  folder: (path: string) => `f:${path}`,
  more: (path: string) => `more:${path}`,
  // Row menu ids
  ask: "ask",
  pin: "pin",
  rename: "rename",
  move: "move",
  copyLink: "copy-link",
  newBeside: "new-beside",
  del: "delete",
  newPageIn: "new-page",
  newFolderIn: "new-folder",
} as const;

/** Pages shown in a folder before "+ N more". */
export const FOLDER_PAGES = 8;

export interface KnowledgeInput {
  view: "yours" | "agent";
  loading: boolean;
  tree: KFolder;
  pinned: readonly KPage[];
  pinnedIds: readonly string[];
  activeId?: string;
  /** Knowledge's Home is showing. */
  home?: boolean;
  open: ReadonlySet<string>;
  /** Folders whose "+ N more" was opened. */
  showAll: ReadonlySet<string>;
  pageHref: (p: KPage) => string;
  pageIcon: (p: KPage) => string;
  deckStarters: readonly { key: string; name: string; slide_count: number }[];
  designStarters: readonly { key: string; label: string }[];
  /** Creating a deck or design is in flight. */
  busy?: boolean;
  todayLabel?: string;
}

const pageMenu = (pinned: boolean): MenuItem[] => [
  { id: K.ask, label: "Ask a Persona", icon: "msg" },
  { id: K.pin, label: pinned ? "Unpin" : "Pin to top", icon: "bookmark" },
  { id: "s1", separator: true },
  { id: K.rename, label: "Rename", icon: "edit" },
  { id: K.move, label: "Move to…", icon: "folder" },
  { id: K.copyLink, label: "Copy link", icon: "link" },
  { id: "s2", separator: true },
  { id: K.newBeside, label: "New page beside it", icon: "plus" },
  { id: "s3", separator: true },
  { id: K.del, label: "Delete", icon: "trash", destructive: true },
];

const folderMenu: MenuItem[] = [
  { id: K.ask, label: "Ask a Persona", icon: "msg" },
  { id: "s1", separator: true },
  { id: K.newPageIn, label: "New page", icon: "plus" },
  { id: K.newFolderIn, label: "New folder", icon: "folder" },
  { id: "s2", separator: true },
  { id: K.rename, label: "Rename", icon: "edit" },
  { id: K.move, label: "Move to…", icon: "folder" },
  { id: "s3", separator: true },
  { id: K.del, label: "Delete folder", icon: "trash", destructive: true },
];

export function buildKnowledgeNavModel(input: KnowledgeInput): NavModel {
  const agent = input.view === "agent";
  const pageItem = (p: KPage): NavItem => {
    const item: NavItem = { id: K.page(p.id), title: p.title, icon: input.pageIcon(p), href: input.pageHref(p), contextMenu: pageMenu(input.pinnedIds.includes(p.id)) };
    if ((p.pending ?? 0) > 0) item.status = "human";
    return item;
  };
  const folderItems = (f: KFolder, depth: number): NavItem[] => {
    const isInbox = (x: KFolder) => depth === 0 && x.name === "Inbox";
    const folders = [...f.folders].sort((a, b) => (depth === 0 ? Number(isInbox(b)) - Number(isInbox(a)) : 0));
    const out: NavItem[] = folders.map((c) => {
      const item: NavItem = {
        id: K.folder(c.path),
        title: c.name,
        icon: isInbox(c) ? "inbox" : "folder",
        children: folderItems(c, depth + 1),
        expanded: input.open.has(c.path),
        contextMenu: folderMenu,
      };
      if (isInbox(c) || c.name === "Proposed") item.badge = { text: String(c.count), tone: "accent" };
      return item;
    });
    const all = input.showAll.has(f.path);
    const cut = all ? f.pages : f.pages.filter((p, i) => i < FOLDER_PAGES || p.id === input.activeId);
    out.push(...cut.map(pageItem));
    const hidden = f.pages.length - cut.length;
    if (hidden > 0) out.push({ id: K.more(f.path), title: `+ ${hidden} more` });
    return out;
  };

  const deck: MenuItem[] = [
    { id: K.deck("blank"), label: "Blank" },
    ...input.deckStarters.map((s) => ({ id: K.deck(s.key), label: `${s.name} (${s.slide_count})` })),
  ];
  const design: MenuItem[] = input.designStarters.map((s) => ({ id: K.design(s.key), label: s.label }));
  const newMenu: MenuItem[] = [
    { id: K.newDoc, label: "Document", icon: "artifacts" },
    { id: "deck", label: "Deck", icon: "slides", children: deck, disabled: input.busy },
    { id: "design", label: "Design", icon: "designs", children: design, disabled: input.busy },
    { id: "s1", separator: true },
    { id: K.newFolder, label: "Folder", icon: "folder" },
  ];

  // The Mac app has no Knowledge tab strip, so Home (the strip's first tab in the browser) leads the list.
  const sections: NavModel["sections"] = [{ id: "home", items: [{ id: K.home, title: "Home", icon: "home", href: "/knowledge" }] }];
  if (input.loading) {
    sections.push({ id: "loading", items: [], emptyText: "Loading" });
  } else if (input.tree.count === 0) {
    sections.push({
      id: "empty",
      items: [],
      emptyText: agent
        ? "No agent knowledge yet. Runs write their memory and proposed patterns here."
        : "No pages yet. Create one, capture a thought, or import your Obsidian vault.",
    });
  } else {
    if (input.pinned.length > 0) sections.push({ id: "pinned", title: "Pinned", items: input.pinned.map((p) => ({ ...pageItem(p), id: K.pinned(p.id), icon: "bookmark" })) });
    sections.push({ id: "tree", title: input.pinned.length > 0 ? "Folders" : undefined, items: folderItems(input.tree, 0) });
  }
  sections.push({
    id: "quick",
    items: [
      { id: K.today, title: "Today", icon: "clock", ...(input.todayLabel ? { trailing: input.todayLabel } : {}) },
      { id: K.capture, title: "Quick capture", icon: "inbox", trailing: "⌥⌘N" },
      { id: K.import, title: "Import Obsidian vault", icon: "upload" },
    ],
  });

  return {
    id: KNOWLEDGE_NAV_ID,
    title: "Knowledge",
    actions: [
      { id: K.search, label: "Search pages and #tags", icon: "search" },
      { id: K.graph, label: "Graph view", icon: "graph" },
      { id: K.connect, label: "Keep notes connected", icon: "link" },
      { id: K.collapse, label: "Collapse all folders", icon: "shrink" },
      { id: K.newMenu, label: "New page, deck or design", icon: "plus", accent: true, menu: newMenu },
    ],
    picker: {
      id: K.viewPicker,
      value: input.view,
      options: [
        { value: "yours", label: "Yours" },
        { value: "agent", label: "Agent knowledge", icon: "agents" },
      ],
    },
    sections,
    selectedId: input.activeId ? K.page(input.activeId) : input.home ? K.home : null,
  };
}
