"use client";

import { usePathname, useRouter } from "next/navigation";
import { useEffect, useMemo, useRef, useState } from "react";
import { useChats } from "@/lib/api/hooks";
import { useCustomApps } from "@/lib/api/custom-app-hooks";
import { useSpaces } from "@/lib/api/space-hooks";
import { resolveAppIcon } from "@/lib/custom-app-bridge";
import { currentArea, subscribeNavigator } from "@/lib/navigator";
import { viewedChatId } from "@/lib/persona-dock";
import { TOOL_ITEMS } from "@/lib/project-scope";
import { useNavCounts } from "@/lib/use-nav-counts";
import { onCommand, post, postDeduped } from "@/lib/native-shell/bridge";
import { buildChatsNavModel, CHATS_NAVIGATOR_ID, NEW_CHAT_ACTION, NEW_SPACE_ACTION, PERSONA_PICKER } from "@/lib/native-shell/chats-model";
import { useAnyNativeCommand } from "@/lib/native-shell/hooks";
import { routeNavCommand } from "@/lib/native-shell/nav-model";
import { publisher } from "@/lib/native-shell/publisher";
import { buildShellModel, protocolArea } from "@/lib/native-shell/shell-model";
import type { NativeCommand, NavModel, ShellCommandName } from "@/lib/native-shell/protocol";
import { useHarnessHealth } from "@/components/domain/setup";
import { useNewConversation } from "@/app/(app)/chat/_components/chat-history";
import { usePersonaFilter } from "@/app/(app)/chat/_components/persona";
import { NewSpaceDialog } from "@/app/(app)/spaces/_components/new-space-dialog";
import { openCommandPalette } from "./command-menu";
import { openShortcuts } from "./shortcuts";
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
  const filter = usePersonaFilter();
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
  const chats = useChats(false, filter.query);
  const spaces = useSpaces();
  const onSpace = /^\/spaces\/([^/]+)/.exec(pathname)?.[1];
  const model = useMemo(
    () =>
      buildChatsNavModel({
        chats: chats.data?.chats ?? [],
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
    [chats.data, spaces.data, viewed, onSpace, filter.value, filter.defaultId, filter.defaultLook, filter.personas, health],
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
  const pickPersona = useRef(filter.set);
  useEffect(() => {
    chatsModel.current = model;
    start.current = conversation.start;
    pickPersona.current = filter.set;
  });
  useEffect(
    () =>
      onCommand((cmd) => {
        const m = chatsModel.current;
        if (m.id !== CHATS_NAVIGATOR_ID || !routeNavCommand(m, cmd, (href) => router.push(href))) return;
        if (cmd.type === "nav.action" && cmd.actionId === NEW_CHAT_ACTION) start.current();
        if (cmd.type === "nav.action" && cmd.actionId === NEW_SPACE_ACTION) setCreatingSpace(true);
        if (cmd.type === "nav.picker" && cmd.pickerId === PERSONA_PICKER) pickPersona.current(cmd.value);
      }),
    [router],
  );

  // Page-level commands.
  useAnyNativeCommand((cmd: NativeCommand) => {
    if (cmd.type === "navigate") router.push(cmd.path);
    if (cmd.type !== "command") return;
    const run: Record<ShellCommandName, () => void> = {
      openCommandMenu: () => openCommandPalette(),
      newChat: () => conversation.disabled || conversation.start(),
      toggleCompanion,
      showShortcuts: openShortcuts,
      find: focusFind,
      focusContent,
    };
    run[cmd.name]();
  });

  return <NewSpaceDialog open={creatingSpace} onOpenChange={setCreatingSpace} />;
}
