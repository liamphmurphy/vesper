"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { useEffect, useState, useSyncExternalStore } from "react";
import { SetupProgress } from "@/components/domain/setup-progress";
import { cx } from "@/lib/cx";
import { useNavCounts } from "@/lib/use-nav-counts";
import { isActive, type NavBadge } from "@/lib/project-scope";
import { currentArea, navigatorClaimed, setNavigatorSlot, subscribeNavigator, NAVIGATOR_WIDTH, type Area } from "@/lib/navigator";
import { badgeLabel } from "@/lib/tab-bar";
import { viewedChatId } from "@/lib/persona-dock";
import { Icon, Mark, type IconName } from "@/components/ui/icon";
import { ChatHistory, useNewConversation } from "@/app/(app)/chat/_components/chat-history";
import { SidebarSpaces } from "@/app/(app)/spaces/_components/spaces-nav";
import { NewSpaceDialog } from "@/app/(app)/spaces/_components/new-space-dialog";
import { AppsMenu } from "./apps-menu";
import { useReadingFocus } from "./editor-layout";
import { NeedsYou } from "./needs-you";
import { HarnessFooter } from "./harness-footer";
import { useAppearance } from "./theme";

/** The areas on the icon row, in order; Apps (the flyout of the other apps and tools) follows them. */
const AREAS: { area: Exclude<Area, "apps">; href: string; label: string; icon: IconName; badge?: NavBadge }[] = [
  { area: "chat", href: "/chat", label: "Chat", icon: "msg" },
  { area: "runs", href: "/runs", label: "Runs", icon: "play", badge: "runs" },
  { area: "tickets", href: "/tickets", label: "Tickets", icon: "tickets" },
  { area: "knowledge", href: "/knowledge", label: "Knowledge", icon: "wiki", badge: "wiki" },
];

const COLLAPSED_KEY = "lazyagents.column-collapsed";

/** The column starts expanded; collapsing it to the strip is remembered per browser, for every screen. */
function useCollapsed(): [boolean, (v: boolean) => void] {
  const [collapsed, setCollapsed] = useState(false);
  // Read after mount so the server render (always expanded) matches the first client render.
  useEffect(() => {
    try {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- reading browser-only storage after hydration
      if (localStorage.getItem(COLLAPSED_KEY) === "1") setCollapsed(true);
    } catch {
      /* No storage: stays expanded. */
    }
  }, []);
  const set = (v: boolean) => {
    setCollapsed(v);
    try {
      if (v) localStorage.setItem(COLLAPSED_KEY, "1");
      else localStorage.removeItem(COLLAPSED_KEY);
    } catch {
      /* Not remembered. */
    }
  };
  return [collapsed, set];
}

/** The mark doubles as the collapse control: the column's top has nothing else to spare. */
function MarkButton({ collapsed, onToggle }: { collapsed: boolean; onToggle: () => void }) {
  const label = collapsed ? "Expand sidebar" : "Collapse sidebar";
  return (
    <button type="button" aria-label={label} aria-expanded={!collapsed} title={label} onClick={onToggle}
      className="grid size-[30px] flex-none place-items-center rounded-md hover:bg-hover">
      <Mark />
    </button>
  );
}

const search = () => window.dispatchEvent(new Event("la:search"));

function SearchField() {
  return (
    <button type="button" aria-label="Search" title="Search (⌘K)" onClick={search}
      className="flex h-[30px] w-full items-center gap-2 rounded-[7px] border border-border bg-surface px-2.5 text-12 text-fg-tertiary hover:border-border-strong hover:text-fg-secondary">
      <Icon name="search" size={14} strokeWidth={1.6} className="flex-none" />
      <span aria-hidden className="flex-1 text-left">Search or jump to…</span>
      <span aria-hidden className="text-10">⌘K</span>
    </button>
  );
}

function SearchIcon() {
  return (
    <button type="button" aria-label="Search" title="Search (⌘K)" onClick={search}
      className="grid size-[30px] place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg">
      <Icon name="search" size={14} strokeWidth={1.6} />
    </button>
  );
}

/** The icon row in the expanded column, the stack in the strip: the same areas, the same badges, one click each. */
function Areas({ vertical, counts, onNewSpace }: { vertical: boolean; counts: Record<NavBadge, number>; onNewSpace: () => void }) {
  const pathname = usePathname();
  const current = currentArea(pathname);
  return (
    <div role="list" aria-label="Areas" className={cx("flex w-full", vertical ? "flex-col gap-px" : "items-center justify-between")}>
      {AREAS.map((a) => {
        const on = current === a.area;
        const dot = !!a.badge && counts[a.badge] > 0;
        return (
          <div key={a.area} role="listitem" className={vertical ? "w-full" : "w-9"}>
            <Link href={a.href} aria-current={on ? "page" : undefined} aria-label={badgeLabel(a.label, a.badge, counts)} title={a.label}
              className={cx("relative grid w-full place-items-center rounded-lg", vertical ? "h-[30px]" : "h-8", on ? "bg-selected text-accent" : "text-fg-tertiary hover:bg-hover hover:text-fg")}>
              <Icon name={a.icon} />
              {dot && <span aria-hidden className={cx("absolute right-1.5 top-1 size-1.5 rounded-full", a.badge === "runs" ? "bg-state-done" : "bg-accent")} />}
            </Link>
          </div>
        );
      })}
      <div role="listitem" className={vertical ? "w-full" : "w-9"}>
        <AppsMenu rail counts={counts} onNewSpace={onNewSpace} />
      </div>
    </div>
  );
}

/** The column's default middle: your chats, with the persona filter, then spaces. Personas sit here and nowhere else in the column. */
function ChatsList({ viewed }: { viewed: string | null }) {
  const conversation = useNewConversation(viewed ?? undefined);
  return (
    <div data-navigator="chats" className="flex min-h-0 flex-1 flex-col gap-3 px-2.5 pb-2">
      <div className="flex flex-none items-center justify-between pl-1.5">
        <h2 className="text-13 font-semibold text-fg">Chats</h2>
        <button type="button" aria-label="New chat" title="New chat" disabled={conversation.disabled} onClick={conversation.start}
          className="grid size-7 place-items-center rounded-md text-accent hover:bg-hover disabled:cursor-not-allowed disabled:opacity-50">
          <Icon name="plus" size={15} strokeWidth={1.7} />
        </button>
      </div>
      <ChatHistory id={viewed ?? undefined} viewed={viewed} />
      <SidebarSpaces viewed={viewed} hideWhenEmpty />
      <SetupProgress />
    </div>
  );
}

function FootLinks({ collapsed, settingsNeedYou }: { collapsed: boolean; settingsNeedYou: boolean }) {
  const pathname = usePathname();
  const link = (href: string) => cx(
    "relative flex items-center rounded-md text-12",
    collapsed ? "size-[30px] justify-center" : "h-7 gap-2 px-1.5",
    isActive(pathname, href) ? "bg-selected text-fg" : "text-fg-tertiary hover:bg-hover hover:text-fg",
  );
  return (
    <div className={cx("flex flex-none", collapsed ? "flex-col items-center gap-1 pb-3" : "items-center justify-between px-2.5 pb-2.5 pt-1")}>
      <Link href="/customization" aria-label="Customization" title="Customization: personas, agents, memory and your profile"
        aria-current={isActive(pathname, "/customization") ? "page" : undefined} className={link("/customization")}>
        <Icon name="sliders" size={15} />
        {!collapsed && <span aria-hidden>Customization</span>}
      </Link>
      <Link href="/settings" title="Settings: credentials, projects and runners" aria-current={isActive(pathname, "/settings") ? "page" : undefined} className={link("/settings")}>
        {collapsed ? <Icon name="gear" size={15} /> : <span aria-hidden>Settings</span>}
        <span className="sr-only">Settings{settingsNeedYou && ": a setting runs need is missing"}</span>
        {settingsNeedYou && <span aria-hidden className={cx("size-1.5 rounded-full bg-state-human", collapsed && "absolute right-1 top-1")} />}
      </Link>
    </div>
  );
}

/**
 * The one left column (DESIGN.md §3), the same on every screen. Its top (the mark, search, Needs
 * you, the areas) and its foot (the harness characters, Customization, Settings) never change;
 * between them sits the current area's own list: Chats by default, or what a screen puts there
 * (the Runs list, the Knowledge explorer, an editor's pages and layers). Collapsed, it is a strip
 * of the same fixed items, remembered for every screen. Personas and spaces appear only in Chats.
 */
export function Sidebar() {
  const pathname = usePathname();
  const counts = useNavCounts();
  const [appearance] = useAppearance();
  const [collapsed, setCollapsed] = useCollapsed();
  // The chat's ⌘. reading focus hides the column altogether, leaving the preference alone.
  const readingFocus = useReadingFocus();
  const claimed = useSyncExternalStore(subscribeNavigator, navigatorClaimed, () => false);
  const [creatingSpace, setCreatingSpace] = useState(false);
  const viewed = viewedChatId(pathname);
  const settingsNeedYou = counts.settings > 0;
  const newSpace = () => setCreatingSpace(true);
  if (readingFocus) return null;
  const harness = appearance.showHarnessActivity !== false;

  if (collapsed) {
    return (
      <aside aria-label="Main menu" className="flex w-[52px] flex-none flex-col items-center border-r border-border-subtle bg-sidebar px-1.5 pt-3 min-[612px]:sticky min-[612px]:top-0 min-[612px]:h-dvh">
        <nav aria-label="Primary" className="flex min-h-0 w-full flex-1 flex-col items-center gap-4">
          <MarkButton collapsed onToggle={() => setCollapsed(false)} />
          <div className="flex flex-col items-center gap-1">
            <SearchIcon />
            <NeedsYou variant="rail" count={counts.inbox} />
          </div>
          <Areas vertical counts={counts} onNewSpace={newSpace} />
          <div className="mt-auto flex w-full flex-col items-center gap-2">
            {harness && <HarnessFooter />}
            <FootLinks collapsed settingsNeedYou={settingsNeedYou} />
          </div>
        </nav>
        <NewSpaceDialog open={creatingSpace} onOpenChange={setCreatingSpace} />
      </aside>
    );
  }
  return (
    <aside aria-label="Main menu" data-expanded className={cx(NAVIGATOR_WIDTH, "flex flex-none flex-col border-r border-border-subtle bg-sidebar min-[612px]:sticky min-[612px]:top-0 min-[612px]:h-dvh")}>
      <nav aria-label="Primary" className="flex min-h-0 flex-1 flex-col">
        <div className="flex flex-none flex-col gap-2 px-3 pt-3">
          <div className="flex items-center gap-1.5">
            <MarkButton collapsed={false} onToggle={() => setCollapsed(true)} />
            <span className="text-14 font-semibold tracking-[-0.01em] text-fg">Vesper</span>
          </div>
          <SearchField />
          <NeedsYou variant="pill" count={counts.inbox} />
          <Areas vertical={false} counts={counts} onNewSpace={newSpace} />
        </div>
        <div aria-hidden className="mx-3 my-2 h-px flex-none bg-border-subtle" />
        {/* The area's list: Chats unless the screen puts its own here (NavigatorPortal). */}
        <div ref={setNavigatorSlot} data-navigator-slot className="flex min-h-0 flex-1 flex-col">
          {!claimed && <ChatsList viewed={viewed} />}
        </div>
        {harness && (
          <div className="flex-none px-2.5">
            <HarnessFooter layout="row" />
          </div>
        )}
        <FootLinks collapsed={false} settingsNeedYou={settingsNeedYou} />
      </nav>
      <NewSpaceDialog open={creatingSpace} onOpenChange={setCreatingSpace} />
    </aside>
  );
}
