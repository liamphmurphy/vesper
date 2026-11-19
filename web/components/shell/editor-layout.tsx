"use client";

import Link from "next/link";
import { createContext, useCallback, useContext, useEffect, useId, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { Icon, type IconName } from "@/components/ui/icon";
import { Sheet } from "@/components/ui/sheet";
import { cx } from "@/lib/cx";
import {
  actOnDock,
  dockReducer,
  readingFocusActive,
  subscribeReadingFocus,
  dockShortcut,
  loadDock,
  saveDock,
  type DockAction,
  type DockState,
} from "@/lib/editor-layout";
import { useCompact } from "@/lib/viewport";
import { isTyping } from "./shortcuts";
import { HistoryNav } from "./history-nav";
import { NavigatorPortal, type NativeNavigator } from "./navigator-slot";
import { splitActions, type NativeAction, type NativeMenuEntry } from "@/lib/native-shell/actions";
import { useIsNativeShell } from "@/lib/native-shell/hooks";
import { setTopBarTitle } from "@/lib/native-shell/title";
import { useNativeToolbar } from "@/lib/native-shell/use-native-toolbar";
import { useRouter } from "next/navigation";
import { CompanionPortal, RightRailPortal } from "./companion";

/** A tab in the right dock. `busy` pulses its ring, `unread` adds a dot (Chat uses both for the persona). */
export type DockTab = {
  id: string;
  label: string;
  icon: IconName;
  /** Drawn instead of `icon`, e.g. the persona's avatar on Chat. */
  avatar?: ReactNode;
  badge?: ReactNode;
  busy?: boolean;
  unread?: boolean;
  /** Needs the room of a document or a running app rather than a side conversation: the dock widens while it shows. "max" leaves the content beside it only 400px (a design under review). */
  wide?: boolean | "max";
  content: ReactNode;
  /**
   * A rail button that does this instead of showing a panel (the Mac app's Start playground). It has no
   * panel or header and is never the active tab; `content` is ignored.
   */
  run?: () => void;
};

export type EditorHeader = {
  back: { href: string; label: string };
  title: ReactNode;
  /** The document's name as text, shown over its structure in the left column (the title may be a rename field). */
  name?: string;
  /** The ▾ menu beside the title (rename, duplicate, …). */
  titleMenu?: ReactNode;
  saveState?: ReactNode;
  /** Beside the save state: what waits on the document, e.g. Designs' "Review 3" pill. */
  status?: ReactNode;
  presence?: ReactNode;
  /** Up to two primary actions. */
  actions?: [ReactNode, ReactNode?];
  /** The ⋯ menu. */
  overflow?: ReactNode;
};

/**
 * An editor's header row for the Mac app: the title (and the title's ▾ menu) go to the window's
 * title, the actions to its toolbar (`placement: "leading"` ones sit next to the title: save state,
 * who is working on it), and the page draws no header row. A browser keeps `EditorHeader`.
 */
export type NativeEditorHeader = {
  title: string;
  subtitle?: string;
  actions: NativeAction[];
  titleMenu?: NativeMenuEntry[];
};

/**
 * Set by a host that opens an editor inside its own screen (Knowledge, for deck and design pages):
 * the element in the host's bar where the editor's actions go (save state, Present, Share…), and the
 * way back that heads the editor's structure in the left column. The host's bar is then the only bar.
 */
export type EditorEmbed = { actions: HTMLElement | null; back: { href: string; label: string } };
export const EditorEmbedContext = createContext<EditorEmbed | null>(null);

/** True while the chat's ⌘. reading focus is on: the Vesper sidebar then hides. */
export function useReadingFocus(): boolean {
  return useSyncExternalStore(subscribeReadingFocus, readingFocusActive, () => false);
}

/** The header action that returns to the app, added to an editor's native structure. */
export const EDITOR_BACK_ACTION = "editor-back";

const COMPOSER = "[data-dock-composer], textarea, [contenteditable='true'], input:not([type='hidden'])";

/**
 * The layout every app editor uses (mockup "EditorLayout: Designs editor"): a header, an optional
 * structure panel on the left, the canvas, and a dock of tabs on the right that collapses to a 44px
 * rail in place. ⌘\ collapses or reopens the dock, ⌘J opens `chatTab` and focuses its composer, ⌘.
 * hides the left panel and the dock and restores them. The dock's open state and tab are remembered
 * per `app`. Below xl the open dock overlays the canvas; below md it opens as a sheet.
 */
export function EditorLayout({
  app,
  header,
  left,
  main,
  dock,
  chatTab = "chat",
  show,
  onDockChange,
  defaultOpen = true,
  nativeLeft,
  nativeHeader,
}: {
  /** Key for the remembered dock state, e.g. "designs". */
  app: string;
  header: EditorHeader;
  left?: ReactNode;
  /**
   * `left` as a NavModel for the native sidebar. The layout adds the way back (and the document's name as the title);
   * the editor handles its own rows' commands. Without it the structure stays in the page (the fallback column).
   */
  nativeLeft?: NativeNavigator;
  /** `header` as the window's title and toolbar in the Mac app, where the page draws no header row. */
  nativeHeader?: NativeEditorHeader;
  main: ReactNode;
  dock: DockTab[];
  chatTab?: string;
  /** Opens `tab` whenever `n` changes, e.g. when the canvas asks to start a review. */
  show?: { tab: string; n: number };
  /** The dock's state after every change, e.g. to clear an unread mark while its tab shows. `open` is false while a phone's sheet is closed. */
  onDockChange?: (s: DockState) => void;
  /** Whether the dock starts open for someone with no remembered choice. Once they collapse or open it, theirs wins. */
  defaultOpen?: boolean;
}) {
  const uid = useId();
  const compact = useCompact();
  const router = useRouter();
  const embed = useContext(EditorEmbedContext);
  const back = embed?.back ?? header.back;
  // An editor with a native header always shows its column, if only the way back (its structure may still be loading).
  const navSource: NativeNavigator | undefined = nativeLeft ?? (nativeHeader ? { model: { id: `editor-${app}`, sections: [] } } : undefined);
  const nativeNav: NativeNavigator | undefined = navSource && {
    model: {
      ...navSource.model,
      title: header.name ?? navSource.model.title,
      actions: [{ id: EDITOR_BACK_ACTION, label: back.label, icon: "chev" }, ...(navSource.model.actions ?? [])],
    },
    onCommand: (cmd) => {
      if (cmd.type === "nav.action" && cmd.actionId === EDITOR_BACK_ACTION) router.push(back.href);
      else navSource.onCommand?.(cmd);
    },
  };
  // The header row in the Mac app's toolbar. Not drawn there, so nothing is lost to the page.
  const isNative = useIsNativeShell();
  const nativeBar = isNative && !!nativeHeader;
  const bar = splitActions(nativeHeader?.actions ?? []);
  const titleMenu = splitActions(nativeHeader?.titleMenu ? [{ id: "title", label: "", kind: "menu", menu: nativeHeader.titleMenu }] : []);
  useNativeToolbar({
    items: bar.items,
    onAction: bar.dispatch,
    titleMenu: titleMenu.items[0]?.menu,
    onTitleAction: (id) => titleMenu.dispatch("title", id),
  });
  const barTitle = nativeHeader?.title;
  const barSubtitle = nativeHeader?.subtitle;
  useEffect(() => {
    if (!nativeBar || !barTitle) return;
    const token = Symbol("editor-title");
    setTopBarTitle(token, { title: barTitle, ...(barSubtitle ? { subtitle: barSubtitle } : {}) });
    return () => setTopBarTitle(token, null);
  }, [nativeBar, barTitle, barSubtitle]);
  const tabIds = dock.map((t) => t.id).join("\n");
  const [state, setState] = useState<DockState>({ open: defaultOpen, tab: dock[0]?.id ?? "", hidden: false });
  const [loaded, setLoaded] = useState(false);
  // On phones the sheet starts closed whatever was remembered, and isn't remembered itself.
  const [sheetOpen, setSheetOpen] = useState(false);
  const [focusChat, setFocusChat] = useState(0);


  // Read after mount so the server render matches the first client render. Later tab changes (a
  // tab that comes and goes, like Review) keep the state and only move off a tab that left.
  const loadedApp = useRef<string>(undefined);
  useEffect(() => {
    const tabs = tabIds.split("\n");
    if (loadedApp.current !== app) {
      loadedApp.current = app;
      setState(loadDock(window.localStorage, app, tabs, defaultOpen));
      setLoaded(true);
    } else setState((s) => (tabs.includes(s.tab) ? s : { ...s, tab: tabs[0] ?? "" }));
  }, [app, tabIds, defaultOpen]);

  useEffect(() => {
    if (loaded) saveDock(window.localStorage, app, state);
  }, [app, state, loaded]);

  // On phones the dock is visible only while its sheet is open, so that's what `open` reports.
  const reportedOpen = compact ? sheetOpen && state.open : state.open;
  useEffect(() => {
    onDockChange?.({ ...state, open: reportedOpen });
  }, [state, reportedOpen, onDockChange]);

  const dispatch = useCallback(
    (a: DockAction) => {
      setState((s) => actOnDock(s, a));
      if (!compact) return;
      if (a.type === "open" || a.type === "select") setSheetOpen(true);
      else if (a.type === "collapse" || a.type === "toggleHidden") setSheetOpen(false);
      else setSheetOpen((o) => !o);
    },
    [compact],
  );

  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      const action = dockShortcut(e, isTyping(e.target));
      if (!action) return;
      e.preventDefault();
      if (action === "toggle") dispatch({ type: "toggle" });
      else if (action === "hideAll") dispatch({ type: "toggleHidden" });
      else if (dock.some((t) => t.id === chatTab)) {
        dispatch({ type: "open", tab: chatTab });
        setFocusChat((n) => n + 1);
      }
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [dispatch, dock, chatTab]);

  // A new `show` opens its tab (adjusting state while rendering, so it lands with the same paint).
  // It waits for the remembered state to load, so a `show` present at mount isn't overwritten by it.
  const showN = show?.n ?? 0;
  const [shownN, setShownN] = useState(0);
  if (loaded && showN !== shownN) {
    setShownN(showN);
    if (show?.tab) {
      setState((s) => dockReducer(s, { type: "open", tab: show.tab }));
      if (compact) setSheetOpen(true);
    }
  }

  // After ⌘J renders the Chat panel (or the sheet's focus trap settles), focus its composer.
  useEffect(() => {
    if (!focusChat) return;
    const id = requestAnimationFrame(() => {
      const panel = document.querySelector(`[data-dock-panel="${CSS.escape(`${uid}:${chatTab}`)}"]:not([hidden])`);
      panel?.querySelector<HTMLElement>(COMPOSER)?.focus();
    });
    return () => cancelAnimationFrame(id);
  }, [focusChat, uid, chatTab]);

  const active = dock.find((t) => t.id === state.tab) ?? dock[0];
  const hasDock = dock.length > 0;
  const showLeft = !!left && !state.hidden;
  const docked = hasDock && !state.hidden;

  const panels = dockPanels(uid, dock, active?.id, compact);

  return (
    <div data-editor-layout={app} className={cx("flex min-h-0 min-w-0 flex-col bg-bg", embed ? "flex-1" : "h-[calc(100dvh-var(--tab-bar-h,0px))] flex-none md:h-dvh")}>
      <div className="relative flex min-h-0 flex-1">
        {/* The structure is the left column's list, under the way back to the app and the document's name. */}
        {(showLeft || nativeNav) && (
          <NavigatorPortal native={nativeNav}>
            {showLeft && <aside aria-label="Structure" className="flex min-h-0 flex-1 flex-col">
              <div className="flex flex-none flex-col gap-0.5 px-4 pb-2">
                <Link href={back.href} className="text-11 text-fg-tertiary hover:text-fg-secondary">‹ {back.label}</Link>
                {header.name && <span className="truncate text-13 font-semibold text-fg">{header.name}</span>}
              </div>
              <div className="min-h-0 flex-1 overflow-y-auto">{left}</div>
            </aside>}
          </NavigatorPortal>
        )}
        {/* The editor's bar spans only the work; the dock is a full-height column whose own first row,
            the same height, continues the bar: its header (the chat's, for Chat) is the top of the dock. */}
        <div className="flex min-h-0 min-w-0 flex-1 flex-col">
          {nativeBar ? <h1 className="sr-only">{nativeHeader.title}</h1> : embed ? <EmbeddedBar {...header} slot={embed.actions} /> : <Header {...header} backInColumn={!!left} />}
          <div className="relative flex min-h-0 min-w-0 flex-1 flex-col overflow-auto bg-bg">{main}</div>
        </div>
        {/* The dock is the companion: in the shell's right-hand column on wide screens, here on phones.
            An app's panels unmount once the dock finishes collapsing, as they always have. */}
        <CompanionPortal>
          {docked && <Dock uid={uid} tabs={dock} state={state} dispatch={dispatch} unmountWhenClosed railOnly={compact} />}
        </CompanionPortal>
      </div>
      {compact && docked && (
        <Sheet open={sheetOpen} onOpenChange={(o) => (o ? setSheetOpen(true) : dispatch({ type: "collapse" }))} title={active?.label ?? ""} className="h-[85dvh]">
          <div className="flex h-full min-h-0 flex-col">{panels}</div>
        </Sheet>
      )}
    </div>
  );
}

/** The tab panels of a dock, one per tab, only the active one shown. Kept mounted so switching tabs or collapsing keeps their state. */
export function dockPanels(uid: string, tabs: DockTab[], activeId: string | undefined, compact = false): ReactNode {
  // A lone tab has no tab to be labelled by (the dock shows tabs only when there is a choice).
  const labelled = !compact && tabs.length > 1;
  return tabs.map((t) => (
    <div
      key={t.id}
      role="tabpanel"
      id={`${uid}-panel-${t.id}`}
      aria-labelledby={labelled ? `${uid}-tab-${t.id}` : undefined}
      aria-label={labelled ? undefined : t.label}
      data-dock-panel={`${uid}:${t.id}`}
      hidden={t.id !== activeId}
      className="flex min-h-0 min-w-0 flex-1 flex-col"
    >
      <DockTabContext.Provider value={t.id}>{t.content}</DockTabContext.Provider>
    </div>
  ));
}

// The dock's first row is its active tab's header. A panel renders its header into its slot (useDockHeaderSlot);
// each tab has its own slot (only the active one shows), so a hidden panel's header stays hidden.
const DockTabContext = createContext<string | undefined>(undefined);
const DockSlotsContext = createContext<Record<string, HTMLElement | null> | undefined>(undefined);

/** The element a docked panel's header renders into, or null outside a dock (a phone's sheet, the chat page): render it inline then. */
export function useDockHeaderSlot(): HTMLElement | null {
  const tab = useContext(DockTabContext);
  const slots = useContext(DockSlotsContext);
  return (tab && slots?.[tab]) || null;
}

/**
 * The desktop dock on the right of an EditorLayout or the chat: a full-height column whose first
 * row, as tall as the page's top bar beside it, holds the active tab's header (the chat's own, via
 * useDockHeaderSlot; else the tab's name), and the active tab's panel below. Its collapse/expand
 * control and tab icons stay in the permanent right rail whether open or folded. Controlled: the owner
 * keeps the state (EditorLayout in localStorage, the chat in the URL). By default the panels stay
 * mounted while collapsed (the chat's playground shouldn't reload). `overlay` is the breakpoint below which the open dock floats over the content.
 */
export function Dock({
  uid,
  tabs,
  state,
  dispatch,
  panels,
  unmountWhenClosed = false,
  overlay = "xl",
  railOnly = false,
}: {
  uid: string;
  tabs: DockTab[];
  state: DockState;
  dispatch: (a: DockAction) => void;
  /** The tab panels, if not the default dockPanels; null renders none (they unmount while collapsed). */
  panels?: ReactNode;
  /** Unmount tab panels once the collapse animation finishes (keeps them visible during the slide; ⌘. hiding keeps them mounted). */
  unmountWhenClosed?: boolean;
  overlay?: "xl" | "lg";
  /** Phones: only the rail, whose icons open the owner's sheet. */
  railOnly?: boolean;
}) {
  const panelTabs = tabs.filter((t) => !t.run);
  const active = panelTabs.find((t) => t.id === state.tab) ?? panelTabs[0];
  const [slots, setSlots] = useState<Record<string, HTMLElement | null>>({});
  // One stable ref callback per tab: a new function each render would detach and reattach the slot,
  // setting state on every render.
  const [slotRefs] = useState(() => new Map<string, (el: HTMLElement | null) => void>());
  const slotRef = (id: string) => {
    let ref = slotRefs.get(id);
    if (!ref) {
      ref = (el) => setSlots((s) => (s[id] === el ? s : { ...s, [id]: el }));
      slotRefs.set(id, ref);
    }
    return ref;
  };
  // ⌘. hides the dock but keeps its panels mounted (the owner passes null panels or unmountWhenClosed to unmount them).
  const shown = state.open && !state.hidden;
  const expanded = !railOnly && shown;
  const [phase, setPhase] = useState<"idle" | "opening" | "closing">("idle");
  const [wasShown, setWasShown] = useState(shown);
  if (shown !== wasShown) {
    setWasShown(shown);
    setPhase(shown ? "opening" : "closing");
  }
  useEffect(() => {
    if (phase === "idle") return;
    // Settle even when transitionend doesn't fire (hidden ancestor, zero-width viewport, JSDOM).
    const id = window.setTimeout(() => setPhase("idle"), 300);
    return () => window.clearTimeout(id);
  }, [phase]);
  if (!tabs.length) return null;
  const visible = shown || phase === "closing";
  const animating = phase !== "idle";
  const widthClass =
    active?.wide === "max"
      ? "[--dock-w:clamp(360px,calc(100vw-692px),984px)] max-xl:[--dock-w:min(984px,calc(100vw-96px))]"
      : active?.wide
        ? overlay === "xl"
          ? "[--dock-w:min(540px,50vw)] max-xl:[--dock-w:min(540px,calc(100vw-96px))]"
          : "[--dock-w:min(540px,50vw)] max-lg:[--dock-w:min(540px,calc(100vw-96px))]"
        : overlay === "xl"
          ? "[--dock-w:360px] max-xl:[--dock-w:min(360px,calc(100vw-96px))]"
          : "[--dock-w:360px] max-lg:[--dock-w:min(360px,calc(100vw-96px))]";
  const renderTab = (t: DockTab) => {
    if (t.run) {
      return (
        <button key={t.id} type="button" aria-label={t.label} title={t.label} onClick={t.run}
          className="relative grid size-8 place-items-center rounded-full text-fg-secondary hover:bg-hover hover:text-fg">
          <TabIcon tab={t} size={16} />
        </button>
      );
    }
    const selected = expanded && t.id === active?.id;
    const asTab = expanded && panelTabs.length > 1;
    const status = `${t.busy ? ", working" : ""}${t.unread ? ", unread" : ""}`;
    return (
      <button
        key={t.id}
        type="button"
        role={asTab ? "tab" : undefined}
        id={asTab ? `${uid}-tab-${t.id}` : undefined}
        aria-selected={asTab ? selected : undefined}
        aria-controls={asTab ? `${uid}-panel-${t.id}` : undefined}
        aria-pressed={!asTab && expanded ? true : undefined}
        aria-label={asTab ? undefined : `${expanded ? "Collapse" : "Open"} ${t.label}${status}`}
        title={selected ? `${t.label}: click to collapse` : t.label}
        onClick={() => dispatch({ type: expanded ? "select" : "open", tab: t.id })}
        className={cx(
          "relative grid size-8 place-items-center rounded-full hover:bg-hover hover:text-fg",
          selected ? "bg-selected text-fg" : "text-fg-secondary",
        )}
      >
        <TabIcon tab={t} size={16} />
        {asTab && <span className="sr-only">{t.label}</span>}
        {t.badge && <span className="pointer-events-none absolute -right-1 -top-1">{t.badge}</span>}
      </button>
    );
  };
  const railControls = (
    <>
      <button
        type="button"
        aria-label={expanded ? "Collapse panel" : "Expand panel"}
        title={expanded ? "Collapse panel (⌘\\)" : "Expand panel (⌘\\)"}
        onClick={() => dispatch(expanded ? { type: "collapse" } : { type: "open", tab: active?.id ?? "" })}
        className="grid size-7 place-items-center rounded-md border border-border text-fg-secondary hover:bg-hover hover:text-fg"
      >
        <span aria-hidden>{expanded ? "⇥" : "⇤"}</span>
      </button>
      {expanded && panelTabs.length > 1 ? (
        <div role="tablist" aria-label="Panel tabs" aria-orientation="vertical" className="flex flex-col items-center gap-2">
          {tabs.map(renderTab)}
        </div>
      ) : (
        tabs.map(renderTab)
      )}
    </>
  );
  return (
    <>
      {!railOnly && <aside
        aria-label="Panel"
        hidden={!visible}
        data-open={shown}
        onTransitionEnd={(e) => {
          if (e.target === e.currentTarget && e.propertyName === "width") setPhase("idle");
        }}
        className={cx(
          "flex min-w-0 flex-none flex-col border-l border-border-subtle bg-surface w-(--dock-w)",
          widthClass,
          overlay === "xl"
            ? "max-xl:absolute max-xl:inset-y-0 max-xl:right-0 max-xl:z-20 max-xl:shadow-[var(--shadow-float)]"
            : "max-lg:absolute max-lg:inset-y-0 max-lg:right-0 max-lg:z-20 max-lg:shadow-[var(--shadow-float)]",
          animating && "motion-dock",
          !visible && "hidden",
        )}
      >
        <div className="flex min-h-0 flex-1 flex-col w-(--dock-w)">
          {/* One row, as tall as the page's top bar it continues: the active tab's header (the chat's, for
              Chat; else the tab's name). Its controls stay in the right rail. */}
          <div data-testid="dock-header" className="flex h-[44px] flex-none items-center gap-1 border-b border-border-subtle bg-surface pl-1 pr-2">
            <div className="flex min-w-0 flex-1 items-center">
              {panelTabs.map((t) => (
                <div key={t.id} ref={slotRef(t.id)} data-dock-header={t.id} hidden={t.id !== active?.id}
                  className={cx("min-w-0 flex-1 items-center", t.id === active?.id && "peer flex empty:hidden")} />
              ))}
              <span className="hidden min-w-0 flex-1 truncate px-2 text-13 font-semibold text-fg peer-empty:block">{active?.label}</span>
            </div>
          </div>
          <DockSlotsContext.Provider value={slots}>
          {panels !== undefined ? panels : unmountWhenClosed && !state.open && phase !== "closing" ? null : dockPanels(uid, panelTabs, active?.id)}
          </DockSlotsContext.Provider>
        </div>
      </aside>}
      {!state.hidden && (
        railOnly ? (
          <nav aria-label="Panel rail" className="flex w-[44px] flex-none flex-col items-center gap-2 border-l border-border-subtle bg-sidebar py-2.5">
            {railControls}
          </nav>
        ) : (
          <RightRailPortal native={{ tabs, activeId: active?.id, expanded, dispatch }}>
            <nav aria-label="Panel rail" className="flex w-full flex-col items-center gap-2">
              {railControls}
            </nav>
          </RightRailPortal>
        )
      )}
    </>
  );
}

function TabIcon({ tab, size = 14 }: { tab: DockTab; size?: number }) {
  return (
    <span className="relative grid place-items-center">
      {tab.busy && (
        <span aria-hidden data-busy className="absolute -inset-1.5 animate-pulse rounded-full border-2 border-accent motion-reduce:animate-none" />
      )}
      {tab.avatar ?? <Icon name={tab.icon} size={size} />}
      {tab.unread && <span aria-hidden data-unread className="absolute -right-1.5 -top-1.5 size-2 rounded-full bg-state-human" />}
      {(tab.busy || tab.unread) && <span className="sr-only">{[tab.busy && "working", tab.unread && "unread"].filter(Boolean).join(", ")}</span>}
    </span>
  );
}

/**
 * The editor's bar inside a host's screen: its actions go into the host's bar (the title is the
 * host's tab), so the page keeps one bar. The title stays as the page's heading for assistive tech.
 */
function EmbeddedBar({ title, titleMenu, saveState, status, presence, actions, overflow, slot }: EditorHeader & { slot: HTMLElement | null }) {
  const heading = <h1 className="sr-only">{title}</h1>;
  if (!slot) return heading;
  return createPortal(
    <div className="flex min-w-0 items-center gap-3">
      {heading}
      {titleMenu}
      {saveState && <span className="flex-none text-12 text-fg-tertiary" aria-live="polite">{saveState}</span>}
      {status}
      {presence && <div className="flex flex-none items-center max-md:hidden">{presence}</div>}
      {actions && <div className="flex flex-none items-center gap-2">{actions}</div>}
      {overflow}
    </div>,
    slot,
  );
}

/** The editor's bar: back and forward first, as on every page, then the title; the way up to the app is in the left column when the structure is. */
function Header({ back, title, titleMenu, saveState, status, presence, actions, overflow, backInColumn }: EditorHeader & { backInColumn: boolean }) {
  return (
    <header className="flex h-[44px] flex-none items-center gap-3 border-b border-border-subtle bg-surface pl-3 pr-4">
      <HistoryNav className="max-md:hidden" />
      {/* Phones have no left column, so the way up stays here for them. */}
      <Link href={back.href} className={cx("flex flex-none items-center gap-1 text-13 text-fg-secondary hover:text-fg", backInColumn && "md:hidden")}>
        <span aria-hidden>←</span>
        {back.label}
      </Link>
      <div className="flex min-w-0 items-center gap-1">
        <h1 className="truncate text-14 font-semibold">{title}</h1>
        {titleMenu}
      </div>
      {saveState && <span className="flex-none text-12 text-fg-tertiary" aria-live="polite">{saveState}</span>}
      {status}
      <div className="flex-1" />
      {presence && <div className="flex flex-none items-center max-md:hidden">{presence}</div>}
      {actions && <div className="flex flex-none items-center gap-2">{actions}</div>}
      {overflow}
    </header>
  );
}
