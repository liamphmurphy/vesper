"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useCallback, useEffect, useId, useState, useSyncExternalStore, type ReactNode } from "react";
import { createPortal } from "react-dom";
import { WorkChat } from "@/components/domain/work-chat";
import { Icon } from "@/components/ui/icon";
import { useNavCounts } from "@/lib/use-nav-counts";
import { claimCompanion, companionClaimed, companionSlot, rightRailSlot, setCompanionSlot, setRightRailSlot, subscribeCompanion } from "@/lib/companion";
import { cx } from "@/lib/cx";
import { actOnDock, dockShortcut, loadDock, saveDock, type DockAction, type DockState } from "@/lib/editor-layout";
import { isActive } from "@/lib/project-scope";
import { useCompact } from "@/lib/viewport";
import { Dock, useReadingFocus, type DockTab } from "./editor-layout";
import { HarnessFooter } from "./harness-footer";
import { NeedsYou } from "./needs-you";
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
export function useDockState(app: string, tabIds: string[], defaultOpen: boolean): [DockState, (a: DockAction) => void] {
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
export function CompanionDock({ app, tabs, defaultOpen = true }: { app: string; tabs: DockTab[]; defaultOpen?: boolean }) {
  const uid = useId();
  const [state, dispatch] = useDockState(app, tabs.map((t) => t.id), defaultOpen);
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
  return <Dock uid={uid} tabs={tabs} state={state} dispatch={dispatch} panels={state.open ? undefined : null} />;
}

/** Puts a Dock's collapsed rail buttons into the permanent right rail's top dynamic slot on wide screens. */
export function RightRailPortal({ children }: { children: ReactNode }) {
  const slot = useSyncExternalStore(subscribeCompanion, rightRailSlot, () => null);
  return slot ? createPortal(children, slot) : null;
}

function RailFootLinks({ settingsNeedYou }: { settingsNeedYou: boolean }) {
  const pathname = usePathname();
  const link = (href: string) => cx(
    "relative grid size-[30px] place-items-center rounded-md text-12",
    isActive(pathname, href) ? "bg-selected text-fg" : "text-fg-tertiary hover:bg-hover hover:text-fg",
  );
  return (
    <div className="flex flex-none flex-col items-center gap-1 pb-1">
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

/**
 * The permanent 44px right rail on every desktop screen: dynamic page controls (Dock rail) at the
 * top, and persistent utilities (Needs you, harnesses, Customization, Settings) anchored at the bottom.
 */
function RightRail() {
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
