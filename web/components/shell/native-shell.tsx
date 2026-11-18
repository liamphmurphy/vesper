"use client";

import { usePathname, useRouter } from "next/navigation";
import { useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import { useChats, useChatSearch } from "@/lib/api/hooks";
import { useCustomApps } from "@/lib/api/custom-app-hooks";
import { useSpaces } from "@/lib/api/space-hooks";
import { resolveAppIcon } from "@/lib/custom-app-bridge";
import { currentArea, subscribeNavigator } from "@/lib/navigator";
import { viewedChatId } from "@/lib/persona-dock";
import { TOOL_ITEMS } from "@/lib/project-scope";
import { useNavCounts } from "@/lib/use-nav-counts";
import { onCommand, post, postDeduped } from "@/lib/native-shell/bridge";
import { buildChatsNavModel, CHAT_SEARCH, CHATS_NAVIGATOR_ID, CHATS_VIEW_ACTION, NEW_CHAT_ACTION, NEW_SPACE_ACTION, PERSONA_PICKER, START_WITH_PREFIX, VIEW_ACTIVE, VIEW_ARCHIVED, type ChatSearchState } from "@/lib/native-shell/chats-model";
import { useAnyNativeCommand } from "@/lib/native-shell/hooks";
import { routeNavCommand } from "@/lib/native-shell/nav-model";
import { publisher } from "@/lib/native-shell/publisher";
import { buildShellModel, protocolArea } from "@/lib/native-shell/shell-model";
import type { NativeCommand, NavModel, ShellCommandName } from "@/lib/native-shell/protocol";
import { useHarnessHealth } from "@/components/domain/setup";
import { useChatListView, useNewConversation, usePersonaNav } from "@/app/(app)/chat/_components/chat-history";
import { NewSpaceDialog } from "@/app/(app)/spaces/_components/new-space-dialog";
import { openCommandPalette } from "./command-menu";
import { openShortcuts } from "./shortcuts";
import { useNativeChatActions } from "./native-chat-actions";
import { AREAS } from "./sidebar";

/** The page's find box: the first search or filter field in the content, if any. */
function focusFind(): void {
  const field = document.querySelector<HTMLElement>(
    'main input[type="search"], main [role="searchbox"], main input[placeholder*="ilter" i], main input[placeholder*="earch" i]',
  );
  field?.focus();
  if (field instanceof HTMLInputElement) field.select();
}

/** ⌘\ folds or reopens the page's dock; the docks listen for the keystroke, so send them that. */
function toggleCompanion(): void {
  window.dispatchEvent(new KeyboardEvent("keydown", { key: "\\", code: "Backslash", metaKey: true, bubbles: true }));
}

function focusContent(): void {
  const main = document.querySelector<HTMLElement>("main");
  if (!main) return;
  if (!main.hasAttribute("tabindex")) main.setAttribute("tabindex", "-1");
  main.focus({ preventScroll: true });
}

/**
 * The page's half of the native Mac shell, mounted by the app shell in native mode only. It draws
 * nothing: it tells the shell where the page is (ready, route), what the sidebar's fixed top holds
 * (shell), the default Chats list (navigator) and runs the shell's commands.
 */
export function NativeShellHost() {
  const router = useRouter();
  const pathname = usePathname();
  const viewed = viewedChatId(pathname);
  const conversation = useNewConversation(viewed ?? undefined);
  // The same persona filter as the web's list; picking one follows to its newest conversation.
  const { filter, active, pick, startWith } = usePersonaNav(viewed ?? undefined);
  const { view, setView } = useChatListView();
  const [query, setQuery] = useState("");
  const health = useHarnessHealth();
  const [creatingSpace, setCreatingSpace] = useState(false);

  // ready once, route on every change.
  const sentReady = useRef(false);
  useEffect(() => {
    if (!sentReady.current) {
      sentReady.current = true;
      post({ v: 1, type: "ready", path: pathname });
    }
    post({ v: 1, type: "route", path: pathname, area: protocolArea(currentArea(pathname)) });
  }, [pathname]);

  // The sidebar's top.
  const counts = useNavCounts();
  const customApps = useCustomApps();
  const shell = useMemo(
    () =>
      buildShellModel({
        areas: AREAS,
        counts,
        current: currentArea(pathname),
        customApps: (customApps.data?.apps ?? []).map((a) => ({ slug: a.slug, name: a.name, icon: resolveAppIcon(a.icon) })),
        tools: TOOL_ITEMS,
      }),
    [counts, customApps.data, pathname],
  );
  const shellJson = JSON.stringify(shell);
  useEffect(() => {
    postDeduped({ v: 1, type: "shell", model: JSON.parse(shellJson) });
  }, [shellJson]);

  // The default navigator (Chats), shown when no screen claims the column.
  // Archived chats from spaces are listed too, as in the web's archived view.
  const archived = useChats(true, filter.query, view === "archived", "all");
  const chats = view === "archived" ? archived : active;
  const deferredQuery = useDeferredValue(query);
  const hits = useChatSearch(deferredQuery);
  const searchState: ChatSearchState =
    deferredQuery.trim().length < 2 ? { status: "short" } : hits.isPending ? { status: "pending" } : hits.isError ? { status: "error", message: hits.error instanceof Error ? hits.error.message : "Search failed." } : { status: "ready", hits: hits.data?.hits ?? [] };
  const searchJson = JSON.stringify(searchState);
  const picked = filter.value !== "default" && filter.query !== "all" ? filter.personas.find((p) => p.id === filter.value) : undefined;
  const filteredTo = filter.value === "default" ? filter.personas.find((p) => p.id === filter.defaultId) : picked;
  const actions = useNativeChatActions((id) => [...(active.data?.chats ?? []), ...(archived.data?.chats ?? [])].find((c) => c.id === id), viewed);
  const spaces = useSpaces();
  const onSpace = /^\/spaces\/([^/]+)/.exec(pathname)?.[1];
  const model = useMemo(
    () =>
      buildChatsNavModel({
        chats: chats.data?.chats ?? [],
        view,
        query,
        search: JSON.parse(searchJson) as ChatSearchState,
        filteredTo: filteredTo ? { id: filteredTo.id, name: filteredTo.name } : null,
        error: chats.isError ? (chats.error instanceof Error ? chats.error.message : "Couldn’t load conversations") : undefined,
        viewedChatId: viewed,
        viewedSpaceId: onSpace ? decodeURIComponent(onSpace) : null,
        spaces: spaces.data?.spaces ?? [],
        personas: {
          value: filter.value,
          options: [
            { value: "all", label: "All" },
            ...(filter.defaultId ? [{ value: "default", label: filter.defaultLook.name }] : []),
            ...filter.personas.filter((p) => p.id !== filter.defaultId).map((p) => ({ value: p.id, label: p.name })),
          ],
        },
        newChatDisabled: !!health && !health.ready,
        origin: window.location.origin,
      }),
    [chats.data, chats.isError, chats.error, view, query, searchJson, filteredTo, spaces.data, viewed, onSpace, filter.value, filter.defaultId, filter.defaultLook, filter.personas, health],
  );
  const modelJson = JSON.stringify(model);
  useEffect(() => {
    publisher.setDefault(JSON.parse(modelJson) as NavModel);
    return () => publisher.setDefault(null);
  }, [modelJson]);
  // A screen claiming or releasing the column changes which model the shell sees.
  useEffect(() => subscribeNavigator(publisher.refresh), []);

  // The default navigator's commands.
  const chatsModel = useRef(model);
  const start = useRef(conversation.start);
  const pickPersona = useRef(pick);
  const chatAction = useRef(actions.run);
  const startWithPersona = useRef(startWith);
  const changeView = useRef(setView);
  useEffect(() => {
    chatsModel.current = model;
    start.current = conversation.start;
    pickPersona.current = pick;
    chatAction.current = actions.run;
    startWithPersona.current = startWith;
    changeView.current = setView;
  });
  useEffect(
    () =>
      onCommand((cmd) => {
        const m = chatsModel.current;
        if (m.id !== CHATS_NAVIGATOR_ID || !routeNavCommand(m, cmd, (href) => router.push(href))) return;
        if (cmd.type === "nav.action" && cmd.actionId === NEW_CHAT_ACTION) start.current();
        if (cmd.type === "nav.action" && cmd.actionId === NEW_SPACE_ACTION) setCreatingSpace(true);
        if (cmd.type === "nav.activate" && cmd.itemId.startsWith(START_WITH_PREFIX)) startWithPersona.current(cmd.itemId.slice(START_WITH_PREFIX.length));
        if (cmd.type === "nav.picker" && cmd.pickerId === PERSONA_PICKER) pickPersona.current(cmd.value);
        if (cmd.type === "nav.search" && cmd.searchId === CHAT_SEARCH) setQuery(cmd.value);
        if (cmd.type === "nav.action" && cmd.actionId === CHATS_VIEW_ACTION) {
          if (cmd.menuItemId === VIEW_ARCHIVED || cmd.menuItemId === VIEW_ACTIVE) changeView.current(cmd.menuItemId === VIEW_ARCHIVED ? "archived" : "active");
        }
        // A row's menu: the menu item id is the actionId, the chat the itemId.
        if (cmd.type === "nav.action" && cmd.itemId && !cmd.menuItemId) void chatAction.current(cmd.actionId, cmd.itemId);
      }),
    [router],
  );

  // Page-level commands.
  useAnyNativeCommand((cmd: NativeCommand) => {
    if (cmd.type === "navigate") router.push(cmd.path);
    if (cmd.type !== "command") return;
    const run: Record<ShellCommandName, () => void> = {
      openCommandMenu: () => openCommandPalette(typeof cmd.query === "string" ? { query: cmd.query } : undefined),
      newChat: () => conversation.disabled || conversation.start(),
      toggleCompanion,
      showShortcuts: openShortcuts,
      find: focusFind,
      focusContent,
    };
    run[cmd.name]();
  });

  return (
    <>
      <NewSpaceDialog open={creatingSpace} onOpenChange={setCreatingSpace} />
      {actions.dialog}
    </>
  );
}
