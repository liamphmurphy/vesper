"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { createContext, useCallback, useContext, useEffect, useMemo, useState, useSyncExternalStore, type ReactNode } from "react";
import { cx } from "@/lib/cx";
import { ancestors, buildTree, closeTab, folderPaths, isoDay, joinPath, movedPath, nameOf, openTab, pageHref, pageIcon, parentOf, type Tab, type TreeFolder, type TreeRow } from "@/lib/knowledge";
import { useAllPages, useCreatePage, useDaily, useDeleteFolder, useDeletePage, useMoveFolder, useMovePage, usePage } from "@/lib/api/knowledge-hooks";
import { DropdownMenu } from "radix-ui";
import { Icon, type IconName } from "@/components/ui/icon";
import { floatPanel } from "@/components/domain/pickers";
import { useSlideStarters, type StarterKey } from "@/lib/api/slides-hooks";
import { useNewDeck } from "@/components/domain/use-new-deck";
import { toast } from "@/lib/toast";
import { useCreateDesign, type DesignStarter } from "@/lib/api/designs-hooks";
import { Kbd, Skeleton } from "@/components/ui/primitives";
import { useToday } from "./kit";
import { isTyping } from "@/components/shell/shortcuts";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { TopBar } from "@/components/shell/topbar";
import { EditorEmbedContext, type EditorEmbed } from "@/components/shell/editor-layout";
import { QuickSwitcher } from "./switcher";
import { CaptureDialog } from "./capture";
import { ImportDialog } from "./import-dialog";
import { KnowledgeDock } from "./knowledge-dock";
import { KnowledgeChatProvider, useKnowledgeChat } from "./chat-context";
import { DeleteDialog, ExplorerMenu, MoveDialog, NewFolderDialog, RenameField, type ExplorerTarget, type MenuEntry } from "./explorer-actions";

type View = "yours" | "agent";

type Shell = {
  view: View;
  setView: (v: View) => void;
  openSwitcher: () => void;
  openCapture: () => void;
  openImport: () => void;
  openToday: () => void;
  /** Registers the screen showing now as a tab. */
  registerTab: (tab: Tab) => void;
  /** Closes the tabs of deleted pages, moving off the one shown if it went. */
  forgetPages: (ids: string[]) => void;
  /** Keeps a renamed page's tab title current, whether or not it's showing. */
  retitleTab: (id: string, title: string) => void;
};

const Ctx = createContext<Shell | null>(null);

export function useKnowledge(): Shell {
  const s = useContext(Ctx);
  if (!s) throw new Error("useKnowledge outside KnowledgeShell");
  return s;
}

/** Registers the current screen as a tab, and keeps its title current as it loads or is renamed. */
export function useKnowledgeTab(tab: Tab | undefined) {
  const { registerTab } = useKnowledge();
  const id = tab?.id;
  const title = tab?.title;
  const kind = tab?.kind;
  useEffect(() => {
    if (id) registerTab({ id, title: title ?? "", kind });
  }, [registerTab, id, title, kind]);
}

const TABS_KEY = "vesper.knowledge.tabs";
const OPEN_KEY = "vesper.knowledge.open";
const VIEW_KEY = "vesper.knowledge.view";
const PINNED_KEY = "vesper.knowledge.pinned";

/**
 * A value kept in localStorage and read with useSyncExternalStore: the server
 * render (and the first client render) see the fallback, then the stored
 * value, with no effect copying it into state.
 */
function localStore<T>(key: string, fallback: T) {
  let cache: T | undefined;
  const listeners = new Set<() => void>();
  const get = (): T => {
    if (cache === undefined) {
      try {
        cache = (JSON.parse(localStorage.getItem(key) ?? "null") as T) ?? fallback;
      } catch {
        cache = fallback;
      }
    }
    return cache;
  };
  return {
    get,
    server: () => fallback,
    set(next: T) {
      cache = next;
      localStorage.setItem(key, JSON.stringify(next));
      listeners.forEach((l) => l());
    },
    subscribe(l: () => void) {
      listeners.add(l);
      return () => listeners.delete(l);
    },
  };
}
function useStore<T>(s: ReturnType<typeof localStore<T>>): T {
  return useSyncExternalStore(s.subscribe, s.get, s.server);
}

const NO_TABS: Tab[] = [];
const DEFAULT_OPEN = ["Daily"];
const tabsStore = localStore<Tab[]>(TABS_KEY, NO_TABS);
const viewStore = localStore<View>(VIEW_KEY, "yours");
const openStore = localStore<string[]>(OPEN_KEY, DEFAULT_OPEN);
const NO_PINS: string[] = [];
const pinnedStore = localStore<string[]>(PINNED_KEY, NO_PINS);
// A folder lists this many pages until "+ N more", so one big folder can't bury the rest of the tree.
const FOLDER_PAGES = 8;

/** The tab a Knowledge address shows. */
function activeTab(pathname: string): string | undefined {
  if (pathname === "/knowledge") return "home";
  if (pathname.startsWith("/knowledge/graph")) return "graph";
  if (pathname.startsWith("/knowledge/connect")) return "connect";
  return /^\/knowledge\/([0-9a-f-]{36})/.exec(pathname)?.[1];
}
// The tab shown before the one being opened, so a new tab lands beside it.
let lastActive: string | undefined;

export function tabHref(t: Tab): string {
  if (t.kind === "graph") return "/knowledge/graph";
  if (t.kind === "connect") return "/knowledge/connect";
  if (t.kind === "home") return "/knowledge";
  return pageHref(t.id, t.title);
}

/**
 * Knowledge as a workspace, in the way Obsidian lays one out: the file
 * explorer on the left, tabs over the screen, and each screen's own right
 * sidebar and status bar. The Vesper sidebar folds to its icon rail while
 * it's open, as it does for the other apps.
 */
export function KnowledgeShell({ children }: { children: ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const view = useStore(viewStore);
  const tabs = useStore(tabsStore);
  const active = activeTab(pathname);
  // A deck or design page opens its editor here: its structure is the column's list, its own
  // dock is the companion, and its actions sit in this bar (EditorEmbedContext).
  const activeKind = tabs.find((t) => t.id === active)?.kind;
  const editorOpen = activeKind === "deck" || activeKind === "design";
  const [barActions, setBarActions] = useState<HTMLElement | null>(null);
  const embed = useMemo<EditorEmbed>(() => ({ actions: barActions, back: { href: "/knowledge", label: "Knowledge" } }), [barActions]);
  const [switcher, setSwitcher] = useState(false);
  const [capture, setCapture] = useState(false);
  const [importing, setImporting] = useState(false);
  const daily = useDaily();

  const setView = useCallback((v: View) => viewStore.set(v), []);

  const openToday = useCallback(() => {
    daily.mutate({ date: isoDay(new Date()) }, { onSuccess: (p) => router.push(pageHref(p.id, p.title)) });
  }, [daily, router]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (mod && !e.altKey && e.key.toLowerCase() === "o") {
        e.preventDefault();
        setSwitcher(true);
      } else if (mod && e.altKey && (e.key.toLowerCase() === "n" || e.code === "KeyN")) {
        e.preventDefault();
        setCapture(true);
      } else if (mod && e.key.toLowerCase() === "d" && !isTyping(e.target)) {
        e.preventDefault();
        openToday();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [openToday]);

  const registerTab = useCallback((tab: Tab) => {
    const cur = tabsStore.get();
    const next = openTab(cur, tab, lastActive);
    if (next !== cur) tabsStore.set(next);
    lastActive = tab.id;
  }, []);

  const forgetPages = useCallback(
    (ids: string[]) => {
      const gone = new Set(ids);
      const cur = tabsStore.get();
      const left = cur.filter((t) => !gone.has(t.id));
      if (left.length !== cur.length) tabsStore.set(left);
      if (active && gone.has(active)) {
        const next = left.at(-1);
        router.push(next ? tabHref(next) : "/knowledge");
      }
    },
    [active, router],
  );

  const retitleTab = useCallback((id: string, title: string) => {
    const cur = tabsStore.get();
    if (cur.some((t) => t.id === id && t.title !== title)) tabsStore.set(cur.map((t) => (t.id === id ? { ...t, title } : t)));
  }, []);

  const shell: Shell = {
    view,
    setView,
    openSwitcher: () => setSwitcher(true),
    openCapture: () => setCapture(true),
    openImport: () => setImporting(true),
    openToday,
    registerTab,
    forgetPages,
    retitleTab,
  };

  const close = (id: string) => {
    const { tabs: left, next } = closeTab(tabs, id, active);
    tabsStore.set(left);
    if (id === active) router.push(next ? tabHref(next) : "/knowledge");
  };

  return (
    <Ctx.Provider value={shell}>
      <KnowledgeChatProvider>
      {/* flex-none, as in EditorLayout: in the app shell's column a flex-1 child grows to its content and ignores h-dvh. */}
      <div className="relative flex h-[calc(100dvh-var(--tab-bar-h,0px))] min-h-0 min-w-0 flex-none bg-bg md:h-dvh">
        {!editorOpen && <Explorer pathname={pathname} />}
        <div className="flex min-w-0 flex-1 flex-col">
          {/* The shared top bar, with the open pages as its tabs: the same height and back button as every page. */}
          <TopBar tabs={<TabStrip tabs={tabs} active={active} onClose={close} />} actions={<div ref={setBarActions} className="contents" />} />
          <EditorEmbedContext.Provider value={embed}>
            <div className="flex min-h-0 flex-1 flex-col">{children}</div>
          </EditorEmbedContext.Provider>
        </div>
        {!editorOpen && <KnowledgeDock pageId={pageIdOf(pathname)} />}
      </div>
      <QuickSwitcher open={switcher} onOpenChange={setSwitcher} includeAgent={view === "agent"} />
      <CaptureDialog open={capture} onOpenChange={setCapture} />
      <ImportDialog open={importing} onOpenChange={setImporting} />
      </KnowledgeChatProvider>
    </Ctx.Provider>
  );
}

function TabStrip({ tabs, active, onClose }: { tabs: Tab[]; active?: string; onClose: (id: string) => void }) {
  const icon = (t: Tab): IconName =>
    t.kind === "graph" ? "graph" : t.kind === "connect" ? "link" : t.kind === "home" ? "dashboard" : t.kind === "deck" ? "slides" : t.kind === "design" ? "designs" : "artifacts";
  return (
    <div role="tablist" aria-label="Open pages" className="flex min-w-0 flex-1 items-end gap-1 overflow-x-auto pl-1">
      {tabs.map((t) => {
        const on = t.id === active;
        return (
          <div
            key={t.id}
            role="tab"
            aria-selected={on}
            className={cx(
              "group relative -mb-px flex h-[34px] max-w-[220px] flex-none items-center gap-2 rounded-t-lg pl-3 pr-1.5 text-12 font-medium",
              on ? "border-x border-t border-border-subtle bg-bg text-fg" : "text-fg-tertiary hover:bg-hover hover:text-fg-secondary",
            )}
          >
            <Icon name={icon(t)} size={13} className={on ? "text-accent" : undefined} />
            <Link href={tabHref(t)} className="min-w-0 flex-1 truncate after:absolute after:inset-0" title={t.title}>
              {t.title || "Untitled"}
            </Link>
            <button
              type="button"
              aria-label={`Close ${t.title}`}
              onClick={() => onClose(t.id)}
              className="relative z-10 grid size-5 place-items-center rounded text-fg-tertiary opacity-60 hover:bg-hover hover:opacity-100 group-hover:opacity-100"
            >
              <Icon name="x" size={11} />
            </button>
          </div>
        );
      })}
      <Link href="/knowledge" aria-label="New tab" className="mb-[9px] grid size-6 flex-none place-items-center rounded text-fg-tertiary hover:bg-hover">
        <Icon name="plus" size={13} />
      </Link>
    </div>
  );
}

// A folder's pages go into the message as context; past this many the persona lists the rest itself.
const FOLDER_CONTEXT_PAGES = 50;

/** The paths of the pages under a folder, depth first, up to limit. */
function pagePaths(folder: TreeFolder, limit: number): string[] {
  const out: string[] = [];
  const walk = (f: TreeFolder) => {
    for (const c of f.folders) {
      if (out.length >= limit) return;
      walk(c);
    }
    for (const p of f.pages) {
      if (out.length >= limit) return;
      out.push(p.path);
    }
  };
  walk(folder);
  return out;
}

/** A fresh page name in a folder, unique enough not to collide with the last one made there. */
const untitledName = () => `Untitled ${Date.now().toString(36)}`;

const pageIdOf = (pathname: string) => /^\/knowledge\/([0-9a-f-]{36})/.exec(pathname)?.[1];

function Explorer({ pathname }: { pathname: string }) {
  const k = useKnowledge();
  const chat = useKnowledgeChat();
  const today = useToday();
  const router = useRouter();
  const agent = k.view === "agent";
  const pages = useAllPages(agent);
  const activeId = pageIdOf(pathname);
  const current = usePage(activeId).data;
  const create = useCreatePage();
  const tree = useMemo(() => buildTree((pages.data ?? []) as TreeRow[]), [pages.data]);
  const stored = useStore(openStore);
  const pinnedIds = useStore(pinnedStore);
  const pinned = useMemo(() => {
    const byId = new Map((pages.data ?? []).map((p) => [p.id, p as TreeRow]));
    return pinnedIds.flatMap((id) => byId.get(id) ?? []);
  }, [pinnedIds, pages.data]);
  const togglePin = (id: string) => pinnedStore.set(pinnedIds.includes(id) ? pinnedIds.filter((p) => p !== id) : [...pinnedIds, id]);
  // Folds every folder; the open page's own path stays open, as it does on arrival.
  const collapseAll = () => {
    openStore.set([]);
    setClosed(new Set());
  };
  // The folders down to the page you're on are open too, until you close one.
  const [closed, setClosed] = useState<Set<string>>(new Set());
  const open = useMemo(() => new Set([...stored, ...ancestors(current?.path).filter((f) => !closed.has(f))]), [stored, current?.path, closed]);
  const toggle = (path: string) => {
    if (open.has(path)) {
      openStore.set(stored.filter((f) => f !== path));
      setClosed((c) => new Set([...c, path]));
    } else {
      openStore.set([...stored, path]);
      setClosed((c) => new Set([...c].filter((f) => f !== path)));
    }
  };
  /** Opens a folder and its parents, so a page made or moved into it shows. */
  const reveal = (folder: string) => {
    if (!folder) return;
    const want = ancestors(`${folder}/page`);
    const cur = openStore.get();
    if (want.some((f) => !cur.includes(f))) openStore.set([...new Set([...cur, ...want])]);
    setClosed((c) => new Set([...c].filter((f) => !want.includes(f))));
  };
  /** Open folders follow a folder that moved, so it stays open under its new path. */
  const followMove = (from: string, to: string) => {
    openStore.set([...new Set(openStore.get().map((p) => movedPath(p, from, to)))]);
    reveal(parentOf(to));
  };
  const newPageIn = (folder: string) => {
    create.mutate(
      { title: "Untitled", path: folder ? `${folder}/${untitledName()}` : undefined, body_md: "" },
      {
        onSuccess: (p) => {
          reveal(folder);
          router.push(pageHref(p.id, p.title));
        },
      },
    );
  };
  const newPage = () => newPageIn(parentOf(current?.path ?? ""));

  // The context menu's actions: one inline rename or one dialog at a time.
  const movePage = useMovePage();
  const moveFolder = useMoveFolder();
  const deletePage = useDeletePage();
  const deleteFolder = useDeleteFolder();
  const [renaming, setRenaming] = useState<string | null>(null);
  const [dialog, setDialog] = useState<{ kind: "move" | "delete"; target: ExplorerTarget } | { kind: "folder"; parent: string } | null>(null);
  const clearErrors = () => [movePage, moveFolder, deletePage, deleteFolder, create].forEach((m) => m.reset());
  const startRename = (key: string) => {
    clearErrors();
    setRenaming(key);
  };
  const openDialog = (d: NonNullable<typeof dialog>) => {
    clearErrors();
    setDialog(d);
  };
  const closeDialog = () => setDialog(null);

  const renamePage = (p: TreeRow, name: string) =>
    movePage.mutate(
      { id: p.id, title: name, path: joinPath(parentOf(p.path), name) },
      {
        onSuccess: (pg) => {
          setRenaming(null);
          k.retitleTab(pg.id, pg.title);
        },
      },
    );
  const renameFolder = (f: TreeFolder, name: string) => {
    const to = joinPath(parentOf(f.path), name);
    moveFolder.mutate(
      { from: f.path, to, agent },
      {
        onSuccess: () => {
          setRenaming(null);
          followMove(f.path, to);
        },
      },
    );
  };
  const moveTo = (t: ExplorerTarget, folder: string) => {
    if (t.kind === "page") {
      movePage.mutate(
        { id: t.page.id, path: joinPath(folder, nameOf(t.page.path)) },
        {
          onSuccess: () => {
            closeDialog();
            reveal(folder);
          },
        },
      );
      return;
    }
    const to = joinPath(folder, t.folder.name);
    moveFolder.mutate(
      { from: t.folder.path, to, agent },
      {
        onSuccess: () => {
          closeDialog();
          followMove(t.folder.path, to);
        },
      },
    );
  };
  const remove = (t: ExplorerTarget) => {
    const done = (r: { deleted: string[] }) => {
      closeDialog();
      k.forgetPages(r.deleted);
    };
    if (t.kind === "page") deletePage.mutate(t.page.id, { onSuccess: done });
    else deleteFolder.mutate({ folder: t.folder.path, agent }, { onSuccess: done });
  };
  const newFolder = (parent: string, name: string) => {
    const folder = joinPath(parent, name);
    create.mutate(
      { title: "Untitled", path: `${folder}/Untitled`, body_md: "" },
      {
        onSuccess: (p) => {
          closeDialog();
          reveal(folder);
          router.push(pageHref(p.id, p.title));
        },
      },
    );
  };

  const blankMenu: MenuEntry[] = [
    { icon: "edit", label: "New page", onSelect: () => newPageIn("") },
    { icon: "folder", label: "New folder", onSelect: () => openDialog({ kind: "folder", parent: "" }) },
  ];
  const actions: TreeActions = {
    renaming,
    renameError: (renaming?.startsWith("p:") ? movePage.error : moveFolder.error)?.message,
    renamePending: movePage.isPending || moveFolder.isPending,
    cancelRename: () => setRenaming(null),
    renamePage,
    renameFolder,
    pageMenu: (p) => [
      { icon: "msg", label: "Ask a Persona", onSelect: () => chat.ask(p) },
      { icon: "bookmark", label: pinnedIds.includes(p.id) ? "Unpin" : "Pin to top", onSelect: () => togglePin(p.id) },
      "separator",
      { icon: "edit", label: "Rename", onSelect: () => startRename(`p:${p.id}`) },
      { icon: "folder", label: "Move to…", onSelect: () => openDialog({ kind: "move", target: { kind: "page", page: p } }) },
      { icon: "link", label: "Copy link", onSelect: () => void navigator.clipboard?.writeText(`[[${p.title}]]`) },
      "separator",
      { icon: "plus", label: "New page beside it", onSelect: () => newPageIn(parentOf(p.path)) },
      "separator",
      { icon: "trash", label: "Delete", danger: true, onSelect: () => openDialog({ kind: "delete", target: { kind: "page", page: p } }) },
    ],
    folderMenu: (f) => [
      { icon: "msg", label: "Ask a Persona", onSelect: () => chat.askFolder({ path: f.path, pages: pagePaths(f, FOLDER_CONTEXT_PAGES), count: f.count }) },
      "separator",
      { icon: "plus", label: "New page", onSelect: () => newPageIn(f.path) },
      { icon: "folder", label: "New folder", onSelect: () => openDialog({ kind: "folder", parent: f.path }) },
      "separator",
      { icon: "edit", label: "Rename", onSelect: () => startRename(`f:${f.path}`) },
      { icon: "folder", label: "Move to…", onSelect: () => openDialog({ kind: "move", target: { kind: "folder", folder: f } }) },
      "separator",
      { icon: "trash", label: "Delete folder", danger: true, onSelect: () => openDialog({ kind: "delete", target: { kind: "folder", folder: f } }) },
    ],
  };


  return (
    // The explorer is the left column's list on Knowledge screens, not a second sidebar beside it.
    <NavigatorPortal>
    <aside aria-label="Knowledge explorer" className="flex min-h-0 flex-1 flex-col">
      <div className="flex h-8 flex-none items-center gap-1 pl-4 pr-2.5">
        <span className="flex-1 text-13 font-semibold text-fg">Knowledge</span>
        <ExplorerButton icon="graph" label="Graph view" href="/knowledge/graph" />
        <ExplorerButton icon="link" label="Keep notes connected" href="/knowledge/connect" />
        <ExplorerButton icon="shrink" label="Collapse all folders" onClick={collapseAll} />
        {/* Last and in the accent, like Chats' New chat: every list in the column ends its title row with its own +. */}
        <NewPageMenu onDocument={newPage} />
      </div>
      <div role="radiogroup" aria-label="Which knowledge" className="mx-3 flex h-7 flex-none rounded-md border border-border-subtle bg-surface-sunken p-0.5">
        {(
          [
            ["yours", "Yours", undefined],
            ["agent", "Agent knowledge", "agents"],
          ] as const
        ).map(([v, label, icon]) => (
          <button
            key={v}
            role="radio"
            aria-checked={k.view === v}
            onClick={() => k.setView(v)}
            className={cx("flex items-center justify-center gap-1.5 whitespace-nowrap rounded text-12 font-medium", v === "yours" ? "w-[72px] flex-none" : "flex-1", k.view === v ? "bg-selected text-fg" : "text-fg-tertiary hover:text-fg-secondary")}
          >
            {icon && <Icon name={icon} size={12} />}
            {label}
          </button>
        ))}
      </div>
      <button
        onClick={k.openSwitcher}
        className="mx-3 mt-2.5 flex h-[30px] flex-none items-center gap-2 rounded-md border border-border bg-surface px-2.5 text-left text-12 text-fg-tertiary hover:border-border-strong"
      >
        <Icon name="search" size={13} />
        <span className="flex-1 truncate">Search pages and #tags</span>
        <Kbd>⌘O</Kbd>
      </button>
      <nav aria-label="Pages" className="mt-3 min-h-0 flex-1 overflow-y-auto px-2 pb-3">
        {pages.isPending ? (
          <div className="space-y-2 px-2">
            {Array.from({ length: 8 }, (_, i) => (
              <Skeleton key={i} className="h-4" style={{ width: `${50 + ((i * 17) % 40)}%` }} />
            ))}
          </div>
        ) : tree.count === 0 ? (
          <p className="px-2 py-3 text-12 leading-relaxed text-fg-tertiary">{agent ? "No agent knowledge yet. Runs write their memory and proposed patterns here." : "No pages yet. Create one, capture a thought, or import your Obsidian vault."}</p>
        ) : (
          <ExplorerMenu entries={blankMenu} className="min-h-full">
            {pinned.length > 0 && (
              <section aria-label="Pinned" className="mb-3">
                <h3 className="px-2 pb-1 text-10 font-bold uppercase tracking-[0.06em] text-fg-tertiary">Pinned</h3>
                <ul className="space-y-px">
                  {pinned.map((p) => (
                    <li key={p.id}>
                      <ExplorerMenu entries={actions.pageMenu(p)} className={menuRow}>
                        <TreeLink href={pageHref(p.id, p.title)} icon="bookmark" label={p.title} depth={-1} active={p.id === activeId} />
                      </ExplorerMenu>
                    </li>
                  ))}
                </ul>
                <h3 className="px-2 pb-1 pt-3 text-10 font-bold uppercase tracking-[0.06em] text-fg-tertiary">Folders</h3>
              </section>
            )}
            <FolderItems folder={tree} depth={0} open={open} toggle={toggle} activeId={activeId} actions={actions} />
          </ExplorerMenu>
        )}
      </nav>
      <div className="flex-none border-t border-border-subtle px-2 py-2">
        <button onClick={k.openToday} className="flex h-8 w-full items-center gap-2.5 rounded-md px-2 text-13 font-medium text-fg-2 hover:bg-hover">
          <Icon name="clock" size={14} className="text-fg-secondary" />
          Today
          <span className="text-12 font-normal text-fg-tertiary">{today?.toLocaleDateString("en", { weekday: "short", month: "short", day: "numeric" })}</span>
        </button>
        <button onClick={k.openCapture} className="flex h-8 w-full items-center gap-2.5 rounded-md px-2 text-13 font-medium text-fg-2 hover:bg-hover">
          <Icon name="inbox" size={14} className="text-fg-secondary" />
          Quick capture
          <Kbd className="ml-auto">⌥⌘N</Kbd>
        </button>
        <button onClick={k.openImport} className="flex h-8 w-full items-center gap-2.5 rounded-md px-2 text-13 font-medium text-fg-2 hover:bg-hover">
          <Icon name="upload" size={14} className="text-fg-secondary" />
          Import Obsidian vault
        </button>
      </div>
      {dialog?.kind === "move" && (
        <MoveDialog
          target={dialog.target}
          folders={folderPaths(tree)}
          pending={movePage.isPending || moveFolder.isPending}
          error={(dialog.target.kind === "page" ? movePage.error : moveFolder.error)?.message}
          onMove={(f) => moveTo(dialog.target, f)}
          onClose={closeDialog}
        />
      )}
      {dialog?.kind === "delete" && (
        <DeleteDialog
          target={dialog.target}
          pending={deletePage.isPending || deleteFolder.isPending}
          error={(dialog.target.kind === "page" ? deletePage.error : deleteFolder.error)?.message}
          onDelete={() => remove(dialog.target)}
          onClose={closeDialog}
        />
      )}
      {dialog?.kind === "folder" && <NewFolderDialog parent={dialog.parent} pending={create.isPending} error={create.error?.message} onCreate={(n) => newFolder(dialog.parent, n)} onClose={closeDialog} />}
    </aside>
    </NavigatorPortal>
  );
}

type TreeActions = {
  renaming: string | null;
  renameError?: string;
  renamePending: boolean;
  cancelRename: () => void;
  renamePage: (p: TreeRow, name: string) => void;
  renameFolder: (f: TreeFolder, name: string) => void;
  pageMenu: (p: TreeRow) => MenuEntry[];
  folderMenu: (f: TreeFolder) => MenuEntry[];
};

// The row whose menu is open stays highlighted, as in Obsidian.
const menuRow = "rounded-md data-[state=open]:bg-hover";

const DESIGN_STARTERS: { key: DesignStarter; label: string }[] = [
  { key: "blank", label: "Blank" },
  { key: "mobile-flow", label: "Mobile flow" },
  { key: "web-flow", label: "Web flow" },
  { key: "diagram", label: "Diagram" },
  { key: "wireframe", label: "Wireframe" },
];
const newItem = "flex h-8 cursor-default select-none items-center gap-2 rounded-md px-2 text-13 outline-none data-[highlighted]:bg-hover data-[disabled]:opacity-50";

/**
 * The explorer's +: a document, a deck or a design (LAZYAGENTS-212). A deck or design is made with
 * its own chat and gets its page as it's made; its old address finds that page and opens it here.
 */
function NewPageMenu({ onDocument }: { onDocument: () => void }) {
  const router = useRouter();
  const deck = useNewDeck();
  const design = useCreateDesign();
  const starters = useSlideStarters();
  const busy = deck.pending || design.isPending;
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button type="button" aria-label="New page" title="New page, deck or design" disabled={busy}
          className="grid size-7 place-items-center rounded-md text-accent hover:bg-hover disabled:opacity-50">
          <Icon name="plus" size={14} />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={4} className={cx(floatPanel, "w-[200px]")}>
          <DropdownMenu.Item className={newItem} onSelect={onDocument}>
            <Icon name="artifacts" size={13} className="text-fg-tertiary" />Document
          </DropdownMenu.Item>
          <DropdownMenu.Sub>
            <DropdownMenu.SubTrigger className={newItem}>
              <Icon name="slides" size={13} className="text-fg-tertiary" />
              <span className="flex-1">Deck</span>
              <Icon name="chevr" size={12} className="text-fg-tertiary" />
            </DropdownMenu.SubTrigger>
            <DropdownMenu.Portal>
              <DropdownMenu.SubContent sideOffset={4} className={cx(floatPanel, "w-[200px]")}>
                <DropdownMenu.Item className={newItem} onSelect={() => deck.start()}>Blank</DropdownMenu.Item>
                {(starters.data ?? []).map((st) => (
                  <DropdownMenu.Item key={st.key} className={newItem} title={st.description} onSelect={() => deck.start(st.key as StarterKey)}>
                    <span className="min-w-0 flex-1 truncate">{st.name}</span>
                    <span className="flex-none font-mono text-11 text-fg-tertiary">{st.slide_count}</span>
                  </DropdownMenu.Item>
                ))}
              </DropdownMenu.SubContent>
            </DropdownMenu.Portal>
          </DropdownMenu.Sub>
          <DropdownMenu.Sub>
            <DropdownMenu.SubTrigger className={newItem}>
              <Icon name="designs" size={13} className="text-fg-tertiary" />
              <span className="flex-1">Design</span>
              <Icon name="chevr" size={12} className="text-fg-tertiary" />
            </DropdownMenu.SubTrigger>
            <DropdownMenu.Portal>
              <DropdownMenu.SubContent sideOffset={4} className={cx(floatPanel, "w-[160px]")}>
                {DESIGN_STARTERS.map((st) => (
                  <DropdownMenu.Item key={st.key} className={newItem}
                    onSelect={() => design.mutate({ starter: st.key, title: "" }, { onSuccess: (d) => router.push(`/apps/designs/${d.id}`), onError: (e) => toast({ id: "new-design", tone: "error", title: "Couldn’t make the design", description: e.message }) })}>
                    {st.label}
                  </DropdownMenu.Item>
                ))}
              </DropdownMenu.SubContent>
            </DropdownMenu.Portal>
          </DropdownMenu.Sub>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

function ExplorerButton({ icon, label, onClick, href, accent }: { icon: IconName; label: string; onClick?: () => void; href?: string; accent?: boolean }) {
  const cls = cx("grid size-7 place-items-center rounded-md hover:bg-hover", accent ? "text-accent" : "text-fg-tertiary hover:text-fg-secondary");
  return href ? (
    <Link href={href} aria-label={label} title={label} className={cls}>
      <Icon name={icon} size={14} />
    </Link>
  ) : (
    <button type="button" aria-label={label} title={label} onClick={onClick} className={cls}>
      <Icon name={icon} size={14} />
    </button>
  );
}

function FolderItems({ folder, depth, open, toggle, activeId, actions }: { folder: TreeFolder; depth: number; open: Set<string>; toggle: (p: string) => void; activeId?: string; actions: TreeActions }) {
  const [all, setAll] = useState(false);
  // The open page always shows, even past the cut.
  const cut = all ? folder.pages : folder.pages.filter((p, i) => i < FOLDER_PAGES || p.id === activeId);
  const hidden = folder.pages.length - cut.length;
  return (
    <ul role={depth ? "group" : "tree"} className="space-y-px">
      {/* Inbox heads the tree, as the place new captures land. */}
      {[...folder.folders].sort((a, b) => (depth === 0 ? Number(b.name === "Inbox") - Number(a.name === "Inbox") : 0)).map((f) => {
        const isOpen = open.has(f.path);
        return (
          <li key={f.path} role="treeitem" aria-expanded={isOpen} aria-selected={false}>
            {actions.renaming === `f:${f.path}` ? (
              <RenameField initial={f.name} icon="folder" indent={24 + depth * 16} error={actions.renameError} pending={actions.renamePending} onCommit={(name) => actions.renameFolder(f, name)} onCancel={actions.cancelRename} />
            ) : (
              <ExplorerMenu entries={actions.folderMenu(f)} className={menuRow}>
                <button
                  onClick={() => toggle(f.path)}
                  style={{ paddingLeft: 6 + depth * 16 }}
                  className="flex h-[26px] w-full items-center gap-1.5 rounded-md pr-2 text-13 font-medium text-fg-2 hover:bg-hover"
                >
                  <Icon name={isOpen ? "chev" : "chevr"} size={12} className="text-fg-tertiary" />
                  <Icon name={depth === 0 && f.name === "Inbox" ? "inbox" : "folder"} size={14} className="text-fg-secondary" />
                  <span className="min-w-0 flex-1 truncate text-left">{f.name}</span>
                  {((depth === 0 && f.name === "Inbox") || f.name === "Proposed") && <span className="rounded-full bg-accent-soft px-1.5 text-10 font-semibold text-accent">{f.count}</span>}
                </button>
              </ExplorerMenu>
            )}
            {isOpen && <FolderItems folder={f} depth={depth + 1} open={open} toggle={toggle} activeId={activeId} actions={actions} />}
          </li>
        );
      })}
      {cut.map((p) => (
        <li key={p.id} role="treeitem" aria-selected={p.id === activeId}>
          {actions.renaming === `p:${p.id}` ? (
            <RenameField initial={p.title} icon={pageIcon(p)} indent={24 + depth * 16} error={actions.renameError} pending={actions.renamePending} onCommit={(name) => actions.renamePage(p, name)} onCancel={actions.cancelRename} />
          ) : (
            <ExplorerMenu entries={actions.pageMenu(p)} className={menuRow}>
              <TreeLink
                href={pageHref(p.id, p.title)}
                icon={pageIcon(p)}
                label={p.title}
                depth={depth}
                active={p.id === activeId}
                dot={(p.pending ?? 0) > 0}
              />
            </ExplorerMenu>
          )}
        </li>
      ))}
      {hidden > 0 && (
        <li>
          <button onClick={() => setAll(true)} style={{ paddingLeft: 24 + depth * 16 }} className="flex h-[26px] w-full items-center rounded-md pr-2 text-left text-12 text-fg-tertiary hover:bg-hover hover:text-fg-secondary">
            + {hidden} more
          </button>
        </li>
      )}
    </ul>
  );
}

function TreeLink({ href, icon, label, depth, active, badge, dot }: { href: string; icon: IconName; label: string; depth: number; active?: boolean; badge?: number; dot?: boolean }) {
  return (
    <Link
      href={href}
      style={{ paddingLeft: 24 + depth * 16 }}
      aria-current={active ? "page" : undefined}
      className={cx(
        "relative flex h-[26px] items-center gap-1.5 rounded-md pr-2 text-13",
        active ? "bg-selected font-medium text-fg before:absolute before:left-0 before:top-1.5 before:h-3.5 before:w-0.5 before:rounded before:bg-accent" : "text-fg-secondary hover:bg-hover",
      )}
    >
      <Icon name={icon} size={13} className={active ? "text-accent" : "text-fg-tertiary"} />
      <span className="min-w-0 flex-1 truncate">{label}</span>
      {dot && <span title="Persona changes to review" className="size-1.5 rounded-full bg-state-human" />}
      {badge !== undefined && <span className="rounded-full bg-accent-soft px-1.5 text-10 font-semibold text-accent">{badge}</span>}
    </Link>
  );
}
