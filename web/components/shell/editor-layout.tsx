"use client";

import { createContext, useCallback, useContext, useEffect, useId, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { type IconName } from "@/components/ui/icon";
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
import { isTyping } from "./shortcuts";
import { NavigatorPortal, type NativeNavigator } from "./navigator-slot";
import { splitActions, type NativeAction, type NativeMenuEntry } from "@/lib/native-shell/actions";
import { inspectorPublisher, toCompanionSubject } from "@/lib/native-shell/inspector-publisher";
import type { InspectorAction, InspectorModel, InspectorSection, InspectorTab } from "@/lib/native-shell/protocol";
import { setTopBarTitle } from "@/lib/native-shell/title";
import { useNativeToolbar } from "@/lib/native-shell/use-native-toolbar";
import type { WorkSubject } from "@/lib/work-context";
import { usePathname, useRouter } from "next/navigation";
import { CompanionPortal, RightRailPortal } from "./companion";

/** Native macOS inspector representation for a dock tab (`native` SwiftUI or `companion` `/companion` WebView; omit for `web`). */
export type NativeDockTab =
  | {
      kind: "native";
      sections: InspectorSection[];
      headerActions?: InspectorAction[];
      emptyText?: string;
      onAction?: (actionId: string, itemId?: string, menuItemId?: string) => void;
      onChange?: (fieldId: string, value: string) => void;
      onToggle?: (fieldId: string, checked: boolean) => void;
    }
  | {
      kind: "companion";
      subject?: WorkSubject;
    };

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
  /** Native macOS inspector description (`native` SwiftUI or `companion` `/companion` WebView). */
  native?: NativeDockTab;
  content?: ReactNode;
  /**
   * A rail button that does this instead of showing a panel (the Mac app's Start playground). It has no
   * panel or header and is never the active tab; `content` is ignored.
   */
  run?: () => void;
};

/**
 * An editor's header for the Mac app: the title (and the title's menu) go to the window's
 * title, the actions to its toolbar (`placement: "leading"` ones sit next to the title: save state,
 * who is working on it).
 */
export type NativeEditorHeader = {
  title: string;
  subtitle?: string;
  actions: NativeAction[];
  titleMenu?: NativeMenuEntry[];
};

/**
 * Set by a host that opens an editor inside its own screen (Knowledge, for deck and design pages):
 * supplies the way back that heads the editor's structure in the left column.
 */
export type EditorEmbed = { back: { href: string; label: string } };
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
  back,
  header,
  main,
  dock,
  chatTab = "chat",
  show,
  onDockChange,
  defaultOpen = true,
  nativeLeft,
}: {
  /** Key for the remembered dock state, e.g. "designs". */
  app: string;
  back: { href: string; label: string };
  /** The window's title and toolbar in the Mac app. */
  header: NativeEditorHeader;
  /**
   * `left` as a NavModel for the native sidebar. The layout adds the way back (and the document's name as the title);
   * the editor handles its own rows' commands.
   */
  nativeLeft?: NativeNavigator;
  main: ReactNode;
  dock: DockTab[];
  chatTab?: string;
  /** Opens `tab` whenever `n` changes, e.g. when the canvas asks to start a review. */
  show?: { tab: string; n: number };
  /** The dock's state after every change, e.g. to clear an unread mark while its tab shows. */
  onDockChange?: (s: DockState) => void;
  /** Whether the dock starts open for someone with no remembered choice. Once they collapse or open it, theirs wins. */
  defaultOpen?: boolean;
}) {
  const uid = useId();
  const router = useRouter();
  const embed = useContext(EditorEmbedContext);
  const resolvedBack = embed?.back ?? back;
  // An editor always shows its back button in the native sidebar, even while its structure is loading.
  const navSource: NativeNavigator = nativeLeft ?? { model: { id: `editor-${app}`, sections: [] } };
  const nativeNav: NativeNavigator = {
    model: {
      ...navSource.model,
      title: header.title || navSource.model.title,
      actions: [{ id: EDITOR_BACK_ACTION, label: resolvedBack.label, icon: "chev" }, ...(navSource.model.actions ?? [])],
    },
    onCommand: (cmd) => {
      if (cmd.type === "nav.action" && cmd.actionId === EDITOR_BACK_ACTION) router.push(resolvedBack.href);
      else navSource.onCommand?.(cmd);
    },
  };
  const bar = splitActions(header.actions ?? []);
  const titleMenu = splitActions(header.titleMenu ? [{ id: "title", label: "", kind: "menu", menu: header.titleMenu }] : []);
  useNativeToolbar({
    items: bar.items,
    onAction: bar.dispatch,
    titleMenu: titleMenu.items[0]?.menu,
    onTitleAction: (id) => titleMenu.dispatch("title", id),
  });
  const barTitle = header.title;
  const barSubtitle = header.subtitle;
  useEffect(() => {
    if (!barTitle) return;
    const token = Symbol("editor-title");
    setTopBarTitle(token, { title: barTitle, ...(barSubtitle ? { subtitle: barSubtitle } : {}) });
    return () => setTopBarTitle(token, null);
  }, [barTitle, barSubtitle]);
  const tabIds = dock.map((t) => t.id).join("\n");
  const [state, setState] = useState<DockState>({ open: defaultOpen, tab: dock[0]?.id ?? "", hidden: false });
  const [loaded, setLoaded] = useState(false);
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

  useEffect(() => {
    onDockChange?.(state);
  }, [state, onDockChange]);

  const dispatch = useCallback((a: DockAction) => {
    setState((s) => actOnDock(s, a));
  }, []);

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
    }
  }

  // After ⌘J renders the Chat panel, focus its composer.
  useEffect(() => {
    if (!focusChat) return;
    const id = requestAnimationFrame(() => {
      const panel = document.querySelector(`[data-dock-panel="${CSS.escape(`${uid}:${chatTab}`)}"]:not([hidden])`);
      panel?.querySelector<HTMLElement>(COMPOSER)?.focus();
    });
    return () => cancelAnimationFrame(id);
  }, [focusChat, uid, chatTab]);

  const hasDock = dock.length > 0;
  const docked = hasDock && !state.hidden;

  return (
    <div data-editor-layout={app} className={cx("flex min-h-0 min-w-0 flex-col bg-bg", embed ? "flex-1" : "h-dvh flex-none")}>
      <div className="relative flex min-h-0 flex-1">
        {nativeNav && <NavigatorPortal native={nativeNav} />}
        {/* The editor's bar spans only the work; the dock is a full-height column whose own first row,
            the same height, continues the bar: its header (the chat's, for Chat) is the top of the dock. */}
        <div className="flex min-h-0 min-w-0 flex-1 flex-col">
          <h1 className="sr-only">{header.title}</h1>
          <div className="relative flex min-h-0 min-w-0 flex-1 flex-col overflow-auto bg-bg">{main}</div>
        </div>
        {/* The dock is the companion: in the shell's right-hand column.
            An app's panels unmount once the dock finishes collapsing, as they always have. */}
        <CompanionPortal>
          {docked && <Dock uid={uid} tabs={dock} state={state} dispatch={dispatch} unmountWhenClosed />}
        </CompanionPortal>
      </div>
    </div>
  );
}

/** The tab panels of a dock, one per web tab, only the active one shown. Kept mounted so switching tabs or collapsing keeps their state. */
export function dockPanels(uid: string, tabs: DockTab[], activeId: string | undefined): ReactNode {
  const webTabs = tabs.filter((t) => !t.native);
  // A lone tab has no tab to be labelled by (the dock shows tabs only when there is a choice).
  const labelled = webTabs.length > 1;
  return webTabs.map((t) => (
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
}) {
  const pathname = usePathname();
  const [inspectorToken] = useState(() => Symbol("inspector"));
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
  const nativeHosted = !!active?.native;
  const webShown = shown && !nativeHosted;
  const expanded = shown;
  const [phase, setPhase] = useState<"idle" | "preparing" | "opening" | "closing">("idle");
  const [wasWebShown, setWasWebShown] = useState(webShown);
  if (webShown !== wasWebShown) {
    setWasWebShown(webShown);
    if (nativeHosted) {
      setPhase("idle");
    } else {
      setPhase(webShown ? "preparing" : "closing");
    }
  }
  useEffect(() => {
    if (phase !== "preparing") return;
    let outer = 0;
    let inner = 0;
    outer = window.requestAnimationFrame(() => {
      inner = window.requestAnimationFrame(() => setPhase("opening"));
    });
    return () => {
      window.cancelAnimationFrame(outer);
      window.cancelAnimationFrame(inner);
    };
  }, [phase]);
  useEffect(() => {
    if (phase === "idle") return;
    // Settle even when transitionend doesn't fire (hidden ancestor, zero-width viewport, JSDOM).
    const id = window.setTimeout(() => setPhase("idle"), 350);
    return () => window.clearTimeout(id);
  }, [phase]);

  const companionTab = panelTabs.find((t) => t.native?.kind === "companion");
  const companionNative = companionTab?.native?.kind === "companion" ? companionTab.native : undefined;
  const inspectorModel: InspectorModel | null =
    panelTabs.length > 0
      ? {
          id: uid,
          open: shown,
          activeTabId: active?.id ?? "",
          tabs: panelTabs.map((t): InspectorTab => ({
            id: t.id,
            label: t.label,
            icon: t.icon,
            kind: t.native?.kind ?? "web",
            ...(t.busy ? { busy: true } : {}),
            ...(t.unread ? { unread: true } : {}),
            ...(t.native?.kind === "native"
              ? {
                  sections: t.native.sections,
                  ...(t.native.headerActions?.length ? { headerActions: t.native.headerActions } : {}),
                  ...(t.native.emptyText ? { emptyText: t.native.emptyText } : {}),
                }
              : {}),
          })),
          ...(companionNative
            ? {
                companion: {
                  ...(companionNative.subject ? { subject: toCompanionSubject(companionNative.subject) } : {}),
                  path: pathname,
                },
              }
            : {}),
        }
      : null;
  const inspectorJson = inspectorModel ? JSON.stringify(inspectorModel) : null;
  const inspectorLatest = useRef({ tabs: panelTabs, activeId: active?.id ?? "", dispatch });
  useEffect(() => {
    inspectorLatest.current = { tabs: panelTabs, activeId: active?.id ?? "", dispatch };
  });
  useEffect(() => {
    if (!inspectorJson) {
      inspectorPublisher.clear(inspectorToken);
      return;
    }
    const model = JSON.parse(inspectorJson) as InspectorModel;
    inspectorPublisher.set(inspectorToken, {
      model,
      onCommand: (cmd) => {
        const cur = inspectorLatest.current;
        switch (cmd.type) {
          case "inspector.visibility":
            cur.dispatch(cmd.open ? { type: "open", tab: cur.activeId } : { type: "collapse" });
            break;
          case "inspector.selectTab":
            cur.dispatch({ type: "open", tab: cmd.tabId });
            break;
          case "inspector.action": {
            const tab = cur.tabs.find((t) => t.id === cmd.tabId);
            if (tab?.native?.kind === "native") {
              tab.native.onAction?.(cmd.actionId, cmd.itemId, cmd.menuItemId);
            }
            break;
          }
          case "inspector.change": {
            const tab = cur.tabs.find((t) => t.id === cmd.tabId);
            if (tab?.native?.kind === "native") {
              tab.native.onChange?.(cmd.fieldId, cmd.value);
            }
            break;
          }
          case "inspector.toggle": {
            const tab = cur.tabs.find((t) => t.id === cmd.tabId);
            if (tab?.native?.kind === "native") {
              tab.native.onToggle?.(cmd.fieldId, cmd.checked);
            }
            break;
          }
        }
      },
    });
  }, [inspectorToken, inspectorJson]);
  useEffect(() => () => inspectorPublisher.clear(inspectorToken), [inspectorToken]);

  if (!tabs.length) return null;
  const visible = webShown || phase === "closing";
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
  return (
    <>
      {!nativeHosted && <aside
        aria-label="Panel"
        hidden={!visible}
        data-open={webShown}
        data-preparing={phase === "preparing" ? "true" : undefined}
        onTransitionEnd={(e) => {
          if (e.target === e.currentTarget && e.propertyName === "transform") setPhase("idle");
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
      {!state.hidden && <RightRailPortal native={{ tabs, activeId: active?.id, expanded, dispatch }} />}
    </>
  );
}
