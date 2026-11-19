"use client";

import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useEffect, useRef } from "react";
import { useChat, useChats, useCreateChat } from "@/lib/api/hooks";
import { newestChat } from "@/lib/chat-ui";
import { isActive } from "@/lib/project-scope";
import { useHarnessHealth } from "@/components/domain/setup";
import { usePersonaFilter } from "./persona";

/**
 * Opens the welcome, where the chat is only made with its first message. The persona picked in
 * the menu is preselected; under All, the open conversation's; otherwise the welcome's default.
 */
export function useNewConversation(id?: string) {
  const router = useRouter();
  const current = useChat(id);
  const filter = usePersonaFilter();
  const health = useHarnessHealth();
  const noHarness = !!health && !health.ready;
  function start() {
    const persona = filter.value === "all" ? current.data?.persona?.id : filter.value === "default" ? filter.defaultId : filter.value;
    router.push(persona ? `/chat?new&persona=${encodeURIComponent(persona)}` : "/chat?new");
  }
  return { start, disabled: noHarness };
}

/**
 * The persona filter plus "follow the pick": choosing a persona opens its newest
 * conversation, unless the open one is already with it. A persona with no chats
 * shows "Start one" in the list instead.
 */
export function usePersonaNav(id: string | undefined) {
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  // The persona filter starts on every persona; GET /chats does the filtering.
  const filter = usePersonaFilter();
  const active = useChats(false, filter.query);
  const create = useCreateChat();
  const startWith = (personaId?: string) =>
    create.mutate(personaId ? { persona_id: personaId } : {}, { onSuccess: (c) => router.push(`/chat/${c.id}`) });
  const open = (chatId: string) => {
    // Only the chat page's own params (?view=) carry over.
    const q = new URLSearchParams(isActive(pathname, "/chat") ? search.toString() : undefined);
    const qs = q.toString();
    router.push(qs ? `/chat/${chatId}?${qs}` : `/chat/${chatId}`);
  };
  // Set by a pick; the effect below runs once that persona's list arrives (a new query, so new data).
  const following = useRef(false);
  const follow = useRef(() => {});
  useEffect(() => {
    follow.current = () => {
      following.current = false;
      const chats = active.data?.chats ?? [];
      if (chats.some((c) => c.id === id)) return;
      const target = newestChat(chats);
      if (target) open(target.id);
    };
  });
  const loaded = active.data;
  useEffect(() => {
    if (following.current && loaded) follow.current();
  }, [loaded]);
  const pick = (v: string) => {
    if (v === filter.value) return;
    following.current = v !== "all";
    filter.set(v);
  };
  return { filter, active, pick, create, startWith };
}

/** Active or Archived, kept in ?view= on the chat page; setView moves there from any other screen. */
export function useChatListView(): { view: "active" | "archived"; setView: (v: "active" | "archived") => void } {
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  const onChat = isActive(pathname, "/chat");
  const view = onChat && search.get("view") === "archived" ? "archived" : "active";
  const setView = (v: "active" | "archived") => {
    const q = new URLSearchParams(onChat ? search.toString() : undefined);
    if (v === "archived") q.set("view", "archived");
    else q.delete("view");
    if (onChat) router.replace(`${pathname}?${q.toString()}`);
    else router.push(`/chat?${q.toString()}`);
  };
  return { view, setView };
}
