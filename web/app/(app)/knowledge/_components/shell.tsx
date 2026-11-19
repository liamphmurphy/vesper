"use client";

import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { cx } from "@/lib/cx";
import { HOME_TAB, START_TAB, ancestors, buildTree, closeOtherTabs, closeTab, closeTabsToRight, folderPaths, isoDay, joinPath, kindHref, movedPath, nameOf, openTab, pageHref, pageIcon, parentOf, parseKind, startTabKind, type Tab, type TreeFolder, type TreeRow } from "@/lib/knowledge";
import { useAllPages, useCreatePage, useDaily, useDeleteFolder, useDeletePage, useMoveFolder, useMovePage, usePage } from "@/lib/api/knowledge-hooks";
import { ContextMenu } from "radix-ui";
import { Icon, type IconName } from "@/components/ui/icon";
import { floatPanel } from "@/components/domain/pickers";
import { useSlideStarters, type StarterKey } from "@/lib/api/slides-hooks";
import { useNewDeck } from "@/components/domain/use-new-deck";
import { toast } from "@/lib/toast";
import { useCreateDesign, type DesignStarter } from "@/lib/api/designs-hooks";
import { Kbd } from "@/components/ui/primitives";
import { useToday } from "./kit";
import { isTyping } from "@/components/shell/shortcuts";
import { NavigatorPortal, openInNewTab } from "@/components/shell/navigator-slot";
import { TopBar } from "@/components/shell/topbar";
import { EditorEmbedContext, type EditorEmbed } from "@/components/shell/editor-layout";
import { openCommandPalette } from "@/components/shell/command-menu";
import { CaptureDialog } from "./capture";
import { ImportDialog } from "./import-dialog";
import { KnowledgeDock } from "./knowledge-dock";
import { buildKnowledgeNavModel, K } from "@/lib/native-shell/models/knowledge";
import { useIsNativeShell } from "@/lib/native-shell/hooks";
import type { NativeCommand } from "@/lib/native-shell/protocol";
import { KnowledgeChatProvider, useKnowledgeChat } from "./chat-context";
import { DeleteDialog, MoveDialog, NewFolderDialog, RenameDialog, type ExplorerTarget } from "./explorer-actions";

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

/** The tab a Knowledge address shows; ?kind= on Knowledge's own address is a kind's start page. */
function activeTab(pathname: string, kind: string | null): string | undefined {
  if (pathname === "/knowledge") return parseKind(kind) ? START_TAB : "home";
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
  if (t.kind === "start") return kindHref(startTabKind(t));
  return pageHref(t.id, t.title);
}

/**
 * Knowledge as a workspace, in the way Obsidian lays one out: the file
 * explorer on the left, tabs over the screen, and each screen's own right
 * sidebar and status bar. The Vesper sidebar folds to its icon rail while
 * it's open, as it does for the other apps.
 */
function isFormField(el: EventTarget | null): boolean {
  if (!(el instanceof HTMLElement)) return false;
  return ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName) || el.getAttribute("role") === "combobox";
}

function hasOpenOverlay(): boolean {
  return !!document.querySelector('[role="dialog"],[role="menu"],[role="listbox"]:not([hidden])');
}

const tabMenuItem =
  "flex h-8 cursor-default select-none items-center gap-2.5 rounded-md px-2 outline-none data-[highlighted]:bg-hover data-[disabled]:opacity-50";

export function KnowledgeShell({ children }: { children: ReactNode }) {
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  const view = useStore(viewStore);
  const tabs = useStore(tabsStore);
  const active = activeTab(pathname, search.get("kind"));
  // A deck or design page opens its editor here: its structure is the column's list, its own
  // dock is the companion, and its actions sit in this bar (EditorEmbedContext).
  const activeKind = tabs.find((t) => t.id === active)?.kind;
  const editorOpen = activeKind === "deck" || activeKind === "design";
  // The Mac app opens pages as its own window tabs, so Knowledge draws no tab strip there (and its
  // screens put their actions in the window's toolbar).
  const native = useIsNativeShell();
  const [barActions, setBarActions] = useState<HTMLElement | null>(null);
  const embed = useMemo<EditorEmbed>(() => ({ actions: barActions, back: { href: "/knowledge", label: "Knowledge" } }), [barActions]);
  const [capture, setCapture] = useState(false);
  const [importing, setImporting] = useState(false);
  const daily = useDaily();

  const setView = useCallback((v: View) => viewStore.set(v), []);

  const openSwitcher = useCallback(() => {
    openCommandPalette({ scope: { kind: "knowledge", label: "Knowledge" }, includeAgent: view === "agent" });
  }, [view]);

  const openToday = useCallback(() => {
    daily.mutate({ date: isoDay(new Date()) }, { onSuccess: (p) => router.push(pageHref(p.id, p.title)) });
  }, [daily, router]);

  const applyTabResult = useCallback(
    (result: { tabs: Tab[]; next?: Tab }, redirectWhenEmpty = false) => {
      if (result.tabs.length === 0 && active === HOME_TAB.id) {
        tabsStore.set([HOME_TAB]);
        return;
      }
      tabsStore.set(result.tabs);
      if (result.next) {
        router.push(tabHref(result.next));
      } else if (redirectWhenEmpty && result.tabs.length === 0) {
        router.push("/knowledge");
      }
    },
    [active, router],
  );

  const close = useCallback(
    (id: string) => applyTabResult(closeTab(tabsStore.get(), id, active), id === active),
    [active, applyTabResult],
  );

  const closeOthers = useCallback(
    (id: string) => applyTabResult(closeOtherTabs(tabsStore.get(), id, active)),
    [active, applyTabResult],
  );

  const closeRight = useCallback(
    (id: string) => applyTabResult(closeTabsToRight(tabsStore.get(), id, active)),
    [active, applyTabResult],
  );

  const closeAll = useCallback(() => {
    tabsStore.set(active === HOME_TAB.id ? [HOME_TAB] : []);
    if (active !== HOME_TAB.id) router.push("/knowledge");
  }, [active, router]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      const isW = e.code === "KeyW" || e.key.toLowerCase() === "w";
      if (mod && !e.altKey && e.key.toLowerCase() === "o") {
        e.preventDefault();
        openSwitcher();
      } else if (mod && e.altKey && (e.key.toLowerCase() === "n" || e.code === "KeyN")) {
        e.preventDefault();
        setCapture(true);
      } else if (mod && e.key.toLowerCase() === "d" && !isTyping(e.target)) {
        e.preventDefault();
        openToday();
      } else if (!native && !mod && e.altKey && isW && !isFormField(e.target) && !hasOpenOverlay()) {
        e.preventDefault();
        if (e.shiftKey) {
          closeAll();
        } else if (active) {
          close(active);
        }
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [active, close, closeAll, native, openSwitcher, openToday]);

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
        // In the Mac app the hidden tab list isn't what the person sees, so fall back to Home.
        const next = native ? undefined : left.at(-1);
        router.push(next ? tabHref(next) : "/knowledge");
      }
    },
    [active, native, router],
  );

  const retitleTab = useCallback((id: string, title: string) => {
    const cur = tabsStore.get();
    if (cur.some((t) => t.id === id && t.title !== title)) tabsStore.set(cur.map((t) => (t.id === id ? { ...t, title } : t)));
  }, []);

  const shell: Shell = {
    view,
    setView,
    openSwitcher,
    openCapture: () => setCapture(true),
    openImport: () => setImporting(true),
    openToday,
    registerTab,
    forgetPages,
    retitleTab,
  };

  return (
    <Ctx.Provider value={shell}>
      <KnowledgeChatProvider>
      {/* flex-none, as in EditorLayout: in the app shell's column a flex-1 child grows to its content and ignores h-dvh. */}
      <div className="relative flex h-dvh min-h-0 min-w-0 flex-none bg-bg">
        {!editorOpen && <Explorer pathname={pathname} />}
        <div className="flex min-w-0 flex-1 flex-col">
          {/* The shared top bar, with the open pages as its tabs: the same height and back button as every page. */}
          {!native && (
            <TopBar
              tabs={
                <TabStrip
                  tabs={tabs}
                  active={active}
                  onClose={close}
                  onCloseOthers={closeOthers}
                  onCloseRight={closeRight}
                  onCloseAll={closeAll}
                />
              }
              actions={<div ref={setBarActions} className="contents" />}
            />
          )}
          <EditorEmbedContext.Provider value={embed}>
            <div className="flex min-h-0 flex-1 flex-col">{children}</div>
          </EditorEmbedContext.Provider>
        </div>
        {!editorOpen && <KnowledgeDock pageId={pageIdOf(pathname)} />}
      </div>
      <CaptureDialog open={capture} onOpenChange={setCapture} />
      <ImportDialog open={importing} onOpenChange={setImporting} />
      </KnowledgeChatProvider>
    </Ctx.Provider>
  );
}

function TabStrip({
  tabs,
  active,
  onClose,
  onCloseOthers,
  onCloseRight,
  onCloseAll,
}: {
  tabs: Tab[];
  active?: string;
  onClose: (id: string) => void;
  onCloseOthers: (id: string) => void;
  onCloseRight: (id: string) => void;
  onCloseAll: () => void;
}) {
  const icon = (t: Tab): IconName =>
    t.kind === "graph" ? "graph" : t.kind === "connect" ? "link" : t.kind === "home" ? "dashboard" : t.kind === "start" ? pageIcon({ kind: startTabKind(t) }) : t.kind === "deck" ? "slides" : t.kind === "design" ? "designs" : "artifacts";
  return (
    <div role="tablist" aria-label="Open pages" className="flex min-w-0 flex-1 items-end gap-1 overflow-x-auto pl-1">
      {tabs.map((t, i) => {
        const on = t.id === active;
        const onlyHome = tabs.length === 1 && t.id === HOME_TAB.id;
        return (
          <ContextMenu.Root key={t.id}>
            <ContextMenu.Trigger asChild>
              <div
                role="tab"
                aria-selected={on}
                onMouseDown={(e) => {
                  if (e.button === 1) e.preventDefault();
                }}
                onAuxClick={(e) => {
                  if (e.button === 1) {
                    e.preventDefault();
                    onClose(t.id);
                  }
                }}
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
            </ContextMenu.Trigger>
            <ContextMenu.Portal>
              <ContextMenu.Content
                collisionPadding={8}
                onCloseAutoFocus={(e) => e.preventDefault()}
                className={cx(floatPanel, "min-w-[210px]")}
              >
                <ContextMenu.Item className={tabMenuItem} disabled={onlyHome} onSelect={() => onClose(t.id)}>
                  Close
                  {on && <Kbd className="ml-auto">⌥W</Kbd>}
                </ContextMenu.Item>
                <ContextMenu.Item className={tabMenuItem} disabled={tabs.length <= 1} onSelect={() => onCloseOthers(t.id)}>
                  Close others
                </ContextMenu.Item>
                <ContextMenu.Item className={tabMenuItem} disabled={i >= tabs.length - 1} onSelect={() => onCloseRight(t.id)}>
                  Close tabs to the right
                </ContextMenu.Item>
                <ContextMenu.Separator className="mx-1 my-1 h-px bg-border-subtle" />
                <ContextMenu.Item className={tabMenuItem} disabled={onlyHome} onSelect={onCloseAll}>
                  Close all tabs
                  <Kbd className="ml-auto">⌥⇧W</Kbd>
                </ContextMenu.Item>
              </ContextMenu.Content>
            </ContextMenu.Portal>
          </ContextMenu.Root>
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
  const search = useSearchParams();
  const chat = useKnowledgeChat();
  const today = useToday();
  const router = useRouter();
  const agent = k.view === "agent";
  const pages = useAllPages(agent);
  const activeId = pageIdOf(pathname);
  const current = usePage(activeId).data;
  const create = useCreatePage();
  const rows = useMemo(() => (pages.data ?? []) as TreeRow[], [pages.data]);
  const tree = useMemo(() => buildTree(rows), [rows]);
  const stored = useStore(openStore);
  const pinnedIds = useStore(pinnedStore);
  const pinned = useMemo(() => {
    const byId = new Map(rows.map((p) => [p.id, p]));
    return pinnedIds.flatMap((id) => byId.get(id) ?? []);
  }, [pinnedIds, rows]);
  const togglePin = (id: string) => pinnedStore.set(pinnedIds.includes(id) ? pinnedIds.filter((p) => p !== id) : [...pinnedIds, id]);
  // Folders manually closed while on the active page; navigating to a different page starts fresh so its path always opens.
  const [closedState, setClosedState] = useState<{ forId: string | undefined; paths: Set<string> }>({ forId: activeId, paths: new Set() });
  const closed = useMemo(() => (closedState.forId === activeId ? closedState.paths : new Set<string>()), [closedState, activeId]);
  const setClosed = useCallback(
    (update: (prev: Set<string>) => Set<string>) =>
      setClosedState((s) => ({ forId: activeId, paths: update(s.forId === activeId ? s.paths : new Set()) })),
    [activeId],
  );
  // Folds every folder; the open page's own path stays open, as it does on arrival.
  const collapseAll = () => {
    openStore.set([]);
    setClosed(() => new Set());
  };
  // Prefer the already-loaded tree row so ancestor folders expand on the first frame after navigation.
  const activePath = useMemo(() => rows.find((r) => r.id === activeId)?.path ?? current?.path, [rows, activeId, current?.path]);
  const open = useMemo(() => new Set([...stored, ...ancestors(activePath).filter((f) => !closed.has(f))]), [stored, activePath, closed]);
  // When navigating to a page that lives in the other Knowledge view (Yours vs Agent knowledge), switch the tree to match.
  const syncedViewFor = useRef<string | undefined>(undefined);
  useEffect(() => {
    if (!activeId) {
      syncedViewFor.current = undefined;
      return;
    }
    if (!current || current.id !== activeId || syncedViewFor.current === activeId) return;
    syncedViewFor.current = activeId;
    const wantView: View = current.audience === "agent" ? "agent" : "yours";
    if (viewStore.get() !== wantView) viewStore.set(wantView);
  }, [activeId, current]);
  // Reveal the opened page's folders in the file tree.
  useEffect(() => {
    const onReveal = (e: Event) => {
      const href = e instanceof CustomEvent ? (e.detail as { href?: string } | undefined)?.href : undefined;
      if (href && !href.startsWith("/knowledge/")) return;
      setClosed(() => new Set());
    };
    window.addEventListener("la:knowledge-reveal", onReveal);
    return () => window.removeEventListener("la:knowledge-reveal", onReveal);
  }, [setClosed]);
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

  // The native sidebar's version of this list: the same state and handlers, driven by the shell's commands.
  const deck = useNewDeck();
  const design = useCreateDesign();
  const starters = useSlideStarters();
  const [showAll, setShowAll] = useState<Set<string>>(new Set());
  const findFolder = (path: string): TreeFolder | undefined => {
    const walk = (f: TreeFolder): TreeFolder | undefined => (f.path === path ? f : f.folders.map(walk).find(Boolean));
    return walk(tree);
  };
  const nativeModel = buildKnowledgeNavModel({
    view: k.view,
    loading: pages.isPending,
    tree,
    pinned,
    pinnedIds,
    activeId,
    home: activeTab(pathname, search.get("kind")) === HOME_TAB.id,
    open,
    showAll,
    pageHref: (p) => pageHref(p.id, p.title),
    pageIcon: (p) => pageIcon(p as TreeRow),
    deckStarters: starters.data ?? [],
    designStarters: DESIGN_STARTERS,
    busy: deck.pending || design.isPending,
    todayLabel: today?.toLocaleDateString("en", { weekday: "short", month: "short", day: "numeric" }),
  });
  const nativeCommand = (cmd: NativeCommand) => {
    if (cmd.type === "nav.picker" && cmd.pickerId === K.viewPicker) return k.setView(cmd.value as View);
    if (cmd.type === "nav.toggle" && cmd.itemId.startsWith("f:")) {
      const path = cmd.itemId.slice(2);
      if (open.has(path) !== cmd.expanded) toggle(path);
      return;
    }
    if (cmd.type === "nav.activate") {
      const id = cmd.itemId;
      if (id === K.today) k.openToday();
      else if (id === K.capture) k.openCapture();
      else if (id === K.import) k.openImport();
      else if (id.startsWith("more:")) setShowAll((s) => new Set([...s, id.slice(5)]));
      else if (id.startsWith("f:")) toggle(id.slice(2));
      return;
    }
    if (cmd.type !== "nav.action") return;
    const a = cmd.actionId;
    if (!cmd.itemId) {
      if (a === K.graph) router.push("/knowledge/graph");
      else if (a === K.connect) router.push("/knowledge/connect");
      else if (a === K.collapse) collapseAll();
      else if (a === K.search) k.openSwitcher();
      else if (a === K.newMenu && cmd.menuItemId) {
        const m = cmd.menuItemId;
        if (m === K.newDoc) newPage();
        else if (m === K.newFolder) openDialog({ kind: "folder", parent: "" });
        else if (m.startsWith("new:deck:")) {
          const key = m.slice("new:deck:".length);
          if (key === "blank") deck.start();
          else deck.start(key as StarterKey);
        } else if (m.startsWith("new:design:")) {
          design.mutate(
            { starter: m.slice("new:design:".length) as DesignStarter, title: "" },
            { onSuccess: (d) => router.push(`/apps/designs/${d.id}`), onError: (e) => toast({ id: "new-design", tone: "error", title: "Couldn’t make the design", description: e.message }) },
          );
        }
      }
      return;
    }
    // A row's context menu: the action id is the menu item, the item id is the row.
    const itemId = cmd.itemId;
    if (itemId.startsWith("p:") || itemId.startsWith("pin:")) {
      const id = itemId.slice(itemId.indexOf(":") + 1);
      const p = rows.find((r) => r.id === id);
      if (!p) return;
      if (a === K.openNewTab) openInNewTab(pageHref(p.id, p.title));
      else if (a === K.ask) chat.ask(p);
      else if (a === K.pin) togglePin(p.id);
      else if (a === K.rename) startRename(`p:${p.id}`);
      else if (a === K.move) openDialog({ kind: "move", target: { kind: "page", page: p } });
      else if (a === K.copyLink) void navigator.clipboard?.writeText(`[[${p.title}]]`);
      else if (a === K.newBeside) newPageIn(parentOf(p.path));
      else if (a === K.del) openDialog({ kind: "delete", target: { kind: "page", page: p } });
    } else if (itemId.startsWith("f:")) {
      const f = findFolder(itemId.slice(2));
      if (!f) return;
      if (a === K.ask) chat.askFolder({ path: f.path, pages: pagePaths(f, FOLDER_CONTEXT_PAGES), count: f.count });
      else if (a === K.newPageIn) newPageIn(f.path);
      else if (a === K.newFolderIn) openDialog({ kind: "folder", parent: f.path });
      else if (a === K.rename) startRename(`f:${f.path}`);
      else if (a === K.move) openDialog({ kind: "move", target: { kind: "folder", folder: f } });
      else if (a === K.del) openDialog({ kind: "delete", target: { kind: "folder", folder: f } });
    }
  };
  const renamingPage = renaming?.startsWith("p:") ? rows.find((r) => r.id === renaming.slice(2)) : undefined;
  const renamingFolder = renaming?.startsWith("f:") ? findFolder(renaming.slice(2)) : undefined;

  return (
    <>
    <NavigatorPortal native={{ model: nativeModel, onCommand: nativeCommand }} />
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
      {renamingPage && (
        <RenameDialog initial={renamingPage.title} error={movePage.error?.message} pending={movePage.isPending} onCommit={(name) => renamePage(renamingPage, name)} onCancel={() => setRenaming(null)} />
      )}
      {renamingFolder && (
        <RenameDialog initial={renamingFolder.name} error={moveFolder.error?.message} pending={moveFolder.isPending} onCommit={(name) => renameFolder(renamingFolder, name)} onCancel={() => setRenaming(null)} />
      )}
    </>
  );
}

const DESIGN_STARTERS: { key: DesignStarter; label: string }[] = [
  { key: "blank", label: "Blank" },
  { key: "mobile-flow", label: "Mobile flow" },
  { key: "web-flow", label: "Web flow" },
  { key: "diagram", label: "Diagram" },
  { key: "wireframe", label: "Wireframe" },
];
