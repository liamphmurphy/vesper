// The default Chats navigator as a NavModel: the same data the web's chat history and spaces
// section show (components/shell/sidebar.tsx ChatsList). Pure so it is unit-tested.

import { chatTitle, rowMark } from "../chat-ui.ts";
import { shortAgo } from "../format.ts";
import type { Avatar, NavItem, NavModel } from "./protocol.ts";

export const CHATS_NAVIGATOR_ID = "chats";
export const NEW_CHAT_ACTION = "new-chat";
export const NEW_SPACE_ACTION = "new-space";
export const PERSONA_PICKER = "persona";

export interface ChatLike {
  id: string;
  title: string;
  state: string;
  unread?: number;
  temporary?: boolean;
  last_message_at?: string | null;
  created_at: string;
  persona?: { name: string; color: string; avatar_url?: string } | null;
}

export interface SpaceLike {
  id: string;
  name: string;
  color?: string;
  chat_count?: number;
  work?: { key?: string; archived?: boolean } | null;
}

export interface ChatsModelInput {
  chats: readonly ChatLike[];
  /** The chat on screen (marked read, so never unread), or null. */
  viewedChatId: string | null;
  /** The space page on screen, or null. */
  viewedSpaceId?: string | null;
  spaces?: readonly SpaceLike[];
  /** The persona filter, when personas exist. */
  personas?: { value: string; options: { value: string; label: string }[] };
  /** Disable the new chat action (no harness is ready). */
  newChatDisabled?: boolean;
  /** Where relative avatar urls are served from. */
  origin?: string;
  now?: number;
}

/** "Ada Lovelace" -> "AL", "Assistant" -> "A". */
export function initials(name: string): string {
  const words = name.trim().split(/\s+/).filter(Boolean);
  const letters = words.length > 1 ? [words[0], words[words.length - 1]] : words;
  return letters.map((w) => [...w][0]?.toUpperCase() ?? "").join("") || "?";
}

function avatar(name: string, color: string | undefined, imageUrl: string | undefined, origin: string | undefined): Avatar {
  const a: Avatar = { initials: initials(name) };
  // var(--accent) and other non-literal colors mean nothing to the shell.
  if (color && /^#|^rgb|^hsl/i.test(color)) a.color = color;
  if (imageUrl) {
    try {
      a.imageUrl = origin ? new URL(imageUrl, origin).toString() : imageUrl;
    } catch {
      /* no image */
    }
  }
  return a;
}

export function chatItem(chat: ChatLike, viewedChatId: string | null, origin?: string, now?: number): NavItem {
  const open = chat.id === viewedChatId;
  const mark = rowMark(chat, open);
  const item: NavItem = { id: chat.id, title: chatTitle(chat), href: `/chat/${chat.id}` };
  if (chat.persona) item.avatar = avatar(chat.persona.name, chat.persona.color, chat.persona.avatar_url, origin);
  if (mark === "running") item.status = "done";
  if (mark === "unread") item.badge = { text: String(chat.unread), tone: "human" };
  else item.trailing = shortAgo(chat.last_message_at ?? chat.created_at, now);
  if (chat.state === "failed") item.subtitle = "Failed";
  return item;
}

export function buildChatsNavModel(input: ChatsModelInput): NavModel {
  const { viewedChatId, viewedSpaceId = null } = input;
  const sections: NavModel["sections"] = [
    {
      id: "chats",
      title: "Chats",
      actions: [{ id: NEW_CHAT_ACTION, label: "New chat", icon: "plus", accent: true }],
      items: input.chats.map((c) => chatItem(c, viewedChatId, input.origin, input.now)),
      emptyText: "No conversations yet",
    },
  ];
  const spaces = (input.spaces ?? []).filter((s) => !s.work?.archived);
  if (spaces.length > 0) {
    sections.push({
      id: "spaces",
      title: "Spaces",
      actions: [{ id: NEW_SPACE_ACTION, label: "New space", icon: "plus" }],
      collapsible: true,
      items: spaces.map((s) => {
        const item: NavItem = { id: `space:${s.id}`, title: s.name, href: `/spaces/${s.id}`, avatar: avatar(s.name, s.color, undefined, input.origin) };
        if (s.work?.key) item.subtitle = s.work.key;
        if (s.chat_count != null) item.trailing = String(s.chat_count);
        return item;
      }),
    });
  }
  const model: NavModel = {
    id: CHATS_NAVIGATOR_ID,
    title: "Chat",
    sections,
    selectedId: viewedSpaceId ? `space:${viewedSpaceId}` : viewedChatId,
  };
  if (input.personas && input.personas.options.length > 1) {
    model.picker = { id: PERSONA_PICKER, value: input.personas.value, options: input.personas.options };
  }
  // NavAction can't be disabled, so without a ready harness the action is left out.
  if (input.newChatDisabled) delete sections[0].actions;
  return model;
}
