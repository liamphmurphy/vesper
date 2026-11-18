"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { useCallback, useEffect, useId, useMemo, useRef, useState, useSyncExternalStore, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { WorkChat } from "@/components/domain/work-chat";
import { Icon } from "@/components/ui/icon";
import { useNavCounts } from "@/lib/use-nav-counts";
import { useDevWorkspace } from "@/lib/api/dev-workspace-hooks";
import { useDismissedReviewRequests, useGitHubReviewRequests, useRefreshGitHubReviewRequests, useReviewFilterPrefs } from "@/lib/api/github-reviews-hooks";
import { useInbox, usePersonaDock } from "@/lib/api/hooks";
import { COMPANION_OPEN_EVENT } from "@/lib/dev-workspace";
import { claimCompanion, companionClaimed, companionSlot, rightRailSlot, setCompanionSlot, setRightRailSlot, subscribeCompanion } from "@/lib/companion";
import { cx } from "@/lib/cx";
import { actOnDock, dockReducer, dockShortcut, loadDock, saveDock, type DockAction, type DockState } from "@/lib/editor-layout";
import { connectedHarnesses } from "@/lib/harness-activity";
import { countReviewRequests, excludeDismissedReviewRequests, filterReviewRequests, isReviewRequestDismissed } from "@/lib/github-reviews";
import { isOpen } from "@/lib/inbox";
import { postDeduped } from "@/lib/native-shell/bridge";
import { useIsNativeShell, useNativeCommand } from "@/lib/native-shell/hooks";
import { buildRailModel, dockRail, dockRailAction, dockRailItems, railEffect, type DockRailTab } from "@/lib/native-shell/models/rail";
import { isActive } from "@/lib/project-scope";
import { useCompact } from "@/lib/viewport";
import { Dock, useReadingFocus, type DockTab } from "./editor-layout";
import { HarnessFooter, harnessRailInputs } from "./harness-footer";
import { NeedsYou } from "./needs-you";
import { PrReviewRequests } from "./pr-review-requests";
import { isTyping } from "./shortcuts";
import { useAppearance } from "./theme";

/**
 * Puts a page's own dock in the shell's right-hand column, in place of the default companion, so
 * every page's panel sits in the same place at the same width (DESIGN.md §3). The content keeps
 * this page's React context. Phones have no column: there the dock renders where it is.
 */
export function CompanionPortal({ children }: { children: ReactNode }) {
  const slot = useSyncExternalStore(subscribeCompanion, companionSlot, () => null);
  const compact = useCompact();
  useEffect(() => claimCompanion(), []);
  if (slot) return createPortal(children, slot);
  return compact ? <>{children}</> : null;
}

/**
 * A dock's state, remembered per `app` (its tab) and shared across pages (open or folded), with
 * ⌘\ to fold or reopen it. For docks that aren't an EditorLayout's: a run's, a ticket's, an
 * epic's and the default companion.
 */
export function useDockState(
  app: string,
  tabIds: string[],
  defaultOpen: boolean,
  show?: { tab: string; n: number },
): [DockState, (a: DockAction) => void] {
  const key = tabIds.join("\n");
  const [state, setState] = useState<DockState>({ open: defaultOpen, tab: tabIds[0] ?? "", hidden: false });
  const [loaded, setLoaded] = useState(false);
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reading browser-only storage after hydration
    setState(loadDock(window.localStorage, app, key.split("\n"), defaultOpen));
    setLoaded(true);
  }, [app, key, defaultOpen]);
  useEffect(() => {
    if (loaded) saveDock(window.localStorage, app, state);
  }, [app, state, loaded]);
  const showN = show?.n ?? 0;
  const [shownN, setShownN] = useState(0);
  if (loaded && showN !== shownN) {
    setShownN(showN);
    if (show?.tab) setState((s) => dockReducer(s, { type: "open", tab: show.tab }));
  }
  const dispatch = useCallback((a: DockAction) => setState((s) => actOnDock(s, a)), []);
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (dockShortcut(e, isTyping(e.target)) !== "toggle") return;
      e.preventDefault();
      dispatch({ type: "toggle" });
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [dispatch]);
  return [state, dispatch];
}

/** A page's own dock in the companion column: its tabs (its facts, then Chat), folding to a rail. */
export function CompanionDock({
  app,
  tabs,
  defaultOpen = true,
  show,
}: {
  app: string;
  tabs: DockTab[];
  defaultOpen?: boolean;
  show?: { tab: string; n: number };
}) {
  const uid = useId();
  const [state, dispatch] = useDockState(app, tabs.map((t) => t.id), defaultOpen, show);
  return (
    <CompanionPortal>
      <Dock uid={uid} tabs={tabs} state={state} dispatch={dispatch} />
    </CompanionPortal>
  );
}

/** The work chat, as the companion on every page with no panel of its own. Starts folded to its rail. */
function DefaultCompanion() {
  const uid = useId();
  const tabs: DockTab[] = [{ id: "chat", label: "Chat", icon: "msg", content: <WorkChat /> }];
  const [state, dispatch] = useDockState("companion", ["chat"], false);
  useEffect(() => {
    const onOpen = () => dispatch({ type: "open", tab: "chat" });
    window.addEventListener(COMPANION_OPEN_EVENT, onOpen);
    return () => window.removeEventListener(COMPANION_OPEN_EVENT, onOpen);
  }, [dispatch]);
  return <Dock uid={uid} tabs={tabs} state={state} dispatch={dispatch} panels={state.open ? undefined : null} />;
}

/**
 * Puts a Dock's rail controls into the permanent right rail's top dynamic slot on wide screens. In
 * the Mac app the shell draws the rail, so the dock describes its controls as data (`native`)
 * instead and the shell's `rail.action` runs the same dispatches the buttons do.
 */
export function RightRailPortal({
  children,
  native,
}: {
  children: ReactNode;
  native?: { tabs: readonly DockRailTab[]; activeId: string | undefined; expanded: boolean; dispatch: (a: DockAction) => void };
}) {
  const slot = useSyncExternalStore(subscribeCompanion, rightRailSlot, () => null);
  const isNative = useIsNativeShell();
  const registered = isNative && !!native;
  const items = useMemo(
    () => (native ? dockRailItems(native.tabs, native.activeId, native.expanded) : []),
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the tabs' content is by id; their description is what matters
    [native && JSON.stringify([native.tabs.map((t) => [t.id, t.label, t.icon, t.busy, t.unread]), native.activeId, native.expanded])],
  );
  const latest = useRef(native);
  useEffect(() => {
    latest.current = native;
  });
  useEffect(() => {
    if (!registered) return;
    const token = Symbol("dock-rail");
    dockRail.set(token, items, (itemId) => {
      const n = latest.current;
      const action = n && dockRailAction(itemId, n.tabs, n.activeId, n.expanded);
      if (action) n.dispatch(action);
    });
    return () => dockRail.clear(token);
  }, [registered, items]);
  if (isNative) return null;
  return slot ? createPortal(children, slot) : null;
}

function RailFootLinks({ settingsNeedYou }: { settingsNeedYou: boolean }) {
  const pathname = usePathname();
  const router = useRouter();
  const devWorkspace = useDevWorkspace();
  const onDevPage = isActive(pathname, "/dev");
  const onHttpPage = isActive(pathname, "/http");
  const link = (href: string) => cx(
    "relative grid size-[30px] place-items-center rounded-md text-12",
    isActive(pathname, href) ? "bg-selected text-fg" : "text-fg-tertiary hover:bg-hover hover:text-fg",
  );
  return (
    <div className="flex flex-none flex-col items-center gap-1 pb-1">
      <Link
        href="/http"
        data-testid="http-launcher"
        aria-label={onHttpPage ? "Return to previous page" : "HTTP Client"}
        title={onHttpPage ? "Return to previous page (⌘⇧H)" : "HTTP Client (⌘⇧H)"}
        aria-current={onHttpPage ? "page" : undefined}
        onClick={(e) => {
          if (!onHttpPage) return;
          e.preventDefault();
          if (window.history.length > 1) router.back();
          else router.push("/");
        }}
        className={link("/http")}
      >
        <Icon name="plug" size={15} />
      </Link>
      {devWorkspace.data?.enabled && (
        <Link
          href="/dev"
          aria-label={onDevPage ? "Return to previous page" : "Dev workspace"}
          title={onDevPage ? "Return to previous page" : "Dev workspace: Nix + LazyVim terminal"}
          aria-current={onDevPage ? "page" : undefined}
          onClick={(e) => {
            if (!onDevPage) return;
            e.preventDefault();
            if (window.history.length > 1) router.back();
            else router.push("/");
          }}
          className={link("/dev")}
        >
          <Icon name="terminal" size={15} />
        </Link>
      )}
      <Link href="/customization" aria-label="Customization" title="Customization: personas, agents, memory and your profile"
        aria-current={isActive(pathname, "/customization") ? "page" : undefined} className={link("/customization")}>
        <Icon name="sliders" size={15} />
      </Link>
      <Link href="/settings" title="Settings: credentials and runners" aria-current={isActive(pathname, "/settings") ? "page" : undefined} className={link("/settings")}>
        <Icon name="gear" size={15} />
        <span className="sr-only">Settings{settingsNeedYou && ": a setting runs need is missing"}</span>
        {settingsNeedYou && <span aria-hidden className="absolute right-1 top-1 size-1.5 rounded-full bg-state-human" />}
      </Link>
    </div>
  );
}

/** What the page tells the Mac shell about the rail: the page's dock, then reviews, Needs you, harnesses and links. */
function NativeRail() {
  const counts = useNavCounts();
  const [appearance] = useAppearance();
  const pathname = usePathname();
  const router = useRouter();
  const devWorkspace = useDevWorkspace();
  const dock = useSyncExternalStore(dockRail.subscribe, dockRail.items, () => []);
  const [prefs, setPrefs] = useReviewFilterPrefs();
  const { dismissed, dismiss: dismissReview, clearAll: clearReviews, restore: restoreReviews } = useDismissedReviewRequests();
  const reviews = useGitHubReviewRequests();
  const refreshReviews = useRefreshGitHubReviewRequests();
  const allReviews = useMemo(() => reviews.data?.items ?? [], [reviews.data?.items]);
  const activeReviews = useMemo(() => excludeDismissedReviewRequests(allReviews, dismissed), [allReviews, dismissed]);
  const requests = useMemo(() => filterReviewRequests(activeReviews, prefs), [activeReviews, prefs]);
  const hiddenReviews = useMemo(
    () => filterReviewRequests(allReviews, prefs).filter((r) => isReviewRequestDismissed(r, dismissed)),
    [allReviews, prefs, dismissed],
  );
  const inbox = useInbox();
  const approved = useMemo(() => (inbox.data ?? []).filter((i) => i.kind === "pr_approved" && isOpen(i)).length, [inbox.data]);
  const readings = usePersonaDock().data?.harnesses;
  const harnesses = useMemo(() => connectedHarnesses(readings ?? []), [readings]);
  const showHarness = appearance.showHarnessActivity !== false;

  const model = useMemo(
    () =>
      buildRailModel({
        dock,
        pathname,
        review: {
          configured: !!reviews.data?.configured,
          requests: requests.map((r) => ({ id: r.id, number: r.number, title: r.title, repository: r.repository, draft: r.draft })),
          approved,
          prefs,
          counts: countReviewRequests(activeReviews),
          dismissed: hiddenReviews.length,
        },
        needsYou: counts.inbox,
        harnesses: showHarness ? harnessRailInputs(harnesses) : null,
        devWorkspace: !!devWorkspace.data?.enabled,
        settingsNeedYou: counts.settings > 0,
      }),
    [dock, pathname, reviews.data?.configured, requests, approved, prefs, activeReviews, hiddenReviews.length, counts.inbox, counts.settings, showHarness, harnesses, devWorkspace.data?.enabled],
  );
  useEffect(() => {
    postDeduped({ v: 1, type: "rail", model });
  }, [model]);
  // The column unmounting (a narrow window, reading focus) means no rail.
  useEffect(() => () => postDeduped({ v: 1, type: "rail", model: null }), []);

  const back = () => {
    if (window.history.length > 1) router.back();
    else router.push("/");
  };
  useNativeCommand("rail.action", (cmd) => {
    const effect = railEffect(cmd.itemId, cmd.menuItemId, { reviewUrl: (id) => allReviews.find((r) => r.id === id)?.url });
    if (!effect) return;
    switch (effect.type) {
      case "dock":
        dockRail.act(effect.itemId);
        break;
      case "navigate":
        router.push(effect.path);
        break;
      case "toggle":
        if (isActive(pathname, effect.path)) back();
        else router.push(effect.path);
        break;
      case "open":
        // A command from the shell carries no click, so WebKit would block window.open. A main-frame
        // navigation to another site goes through the shell's link policy instead: it opens in the
        // default browser and this page stays put.
        window.location.assign(effect.url);
        break;
      case "refreshReviews":
        refreshReviews.mutate();
        break;
      case "clearReviews":
        clearReviews(requests);
        break;
      case "dismissReview": {
        const item = allReviews.find((r) => r.id === effect.id);
        if (item) dismissReview(item);
        break;
      }
      case "restoreReviews":
        restoreReviews(hiddenReviews);
        break;
      case "reviewPrefs":
        setPrefs({ ...prefs, [effect.key]: !prefs[effect.key] });
        break;
    }
  });
  return null;
}

/**
 * The permanent 44px right rail on every desktop screen: dynamic page controls (Dock rail) at the
 * top, and persistent utilities (Needs you, harnesses, Customization, Settings) anchored at the bottom.
 */
function RightRail() {
  const native = useIsNativeShell();
  return native ? <NativeRail /> : <WebRail />;
}

function WebRail() {
  const counts = useNavCounts();
  const [appearance] = useAppearance();
  const harness = appearance.showHarnessActivity !== false;
  const settingsNeedYou = counts.settings > 0;
  return (
    <aside
      aria-label="Right rail"
      data-right-rail
      className="flex w-[44px] flex-none flex-col items-center border-l border-border-subtle bg-sidebar py-2.5"
    >
      <div ref={setRightRailSlot} data-right-rail-top className="flex w-full flex-col items-center gap-2 empty:hidden" />
      <div className="mt-auto flex w-full flex-col items-center gap-2 pt-2">
        <PrReviewRequests />
        <NeedsYou variant="rail" count={counts.inbox} />
        {harness && <HarnessFooter layout="rail" />}
        <div aria-hidden className="h-px w-6 bg-border-subtle" />
        <RailFootLinks settingsNeedYou={settingsNeedYou} />
      </div>
    </aside>
  );
}

/**
 * The shell's right-hand column (wide screens): the page's own dock when it has one, else the
 * default companion, alongside the permanent right rail. Sticky to the viewport like the left
 * column, and the positioning context a narrow window's overlaid dock floats from.
 */
export function CompanionColumn() {
  const claimed = useSyncExternalStore(subscribeCompanion, companionClaimed, () => false);
  const readingFocus = useReadingFocus();
  return (
    <div
      data-companion-column
      className={cx(
        "relative flex min-h-0 flex-none min-[612px]:sticky min-[612px]:top-0 min-[612px]:h-dvh",
        readingFocus && "hidden",
      )}
    >
      <div ref={setCompanionSlot} data-companion className="relative flex min-h-0 flex-none">
        {!claimed && <DefaultCompanion />}
      </div>
      {!readingFocus && <RightRail />}
    </div>
  );
}

/** For a page whose own right-hand panel stays in its layout (the chat page's): no default companion beside it. */
export function useClaimCompanion() {
  useEffect(() => claimCompanion(), []);
}
