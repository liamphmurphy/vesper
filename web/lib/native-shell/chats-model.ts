// The default Chats navigator as a NavModel: the same data the web's chat history and spaces
// section show (components/shell/sidebar.tsx ChatsList). Pure so it is unit-tested.

import { chatTitle, groupByDay, rowMark } from "../chat-ui.ts";
import { shortAgo } from "../format.ts";
import type { Avatar, MenuItem, NavAction, NavItem, NavModel, NavSection } from "./protocol.ts";

export const CHATS_NAVIGATOR_ID = "chats";
export const NEW_CHAT_ACTION = "new-chat";
export const NEW_SPACE_ACTION = "new-space";
export const PERSONA_PICKER = "persona";
export const CHATS_VIEW_ACTION = "chats-view";
export const VIEW_ACTIVE = "view-active";
export const VIEW_ARCHIVED = "view-archived";
export const CHAT_SEARCH = "chat-search";
/** Row menu item ids; the shell sends them as nav.action's actionId with the chat id as itemId. */
export const CHAT_MENU = { rename: "rename", archive: "archive", restore: "restore", delete: "delete" } as const;
export const START_WITH_PREFIX = "start-with:";
const MATCH_MARKS = /[\uE000\uE001]/g;

export interface ChatLike {
  id: string;
  title: string;
  state: string;
  unread?: number;
  temporary?: boolean;
  last_message_at?: string | null;
  created_at: string;
  persona?: { name: string; color: string; avatar_url?: string } | null;
  /** Every persona in the chat, host first; listed in the row once more than one has joined. */
  participants?: { name: string }[] | null;
}

export interface ChatHitLike {
  message_id: string;
  chat_id: string;
  chat_title: string;
  role: string;
  archived: boolean;
  persona_name?: string | null;
  /** Matches are wrapped in U+E000 and U+E001. */
  snippet: string;
}

/** What the message search is showing (the same states the web's results list has). */
export type ChatSearchState =
  | { status: "short" | "pending" }
  | { status: "error"; message: string }
  | { status: "ready"; hits: readonly ChatHitLike[] };

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
  /** Active (by day) or Archived, as the web's ?view=. */
  view?: "active" | "archived";
  /** The text in the search box; non-empty replaces the chat list with message hits. */
  query?: string;
  search?: ChatSearchState;
  /** The persona the list is filtered to, offered a "New chat with" row. */
  filteredTo?: { id: string; name: string } | null;
  /** The list failed to load. */
  error?: string;
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

export function avatar(name: string, color: string | undefined, imageUrl: string | undefined, origin: string | undefined): Avatar {
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

/** The row menu the web's row offers: Rename, Archive, Delete; an archived row Restore, Delete. */
export function chatMenu(archived: boolean): MenuItem[] {
  return archived
    ? [{ id: CHAT_MENU.restore, label: "Restore", icon: "refresh" }, { id: "sep", separator: true }, { id: CHAT_MENU.delete, label: "Delete…", icon: "trash", destructive: true }]
    : [
        { id: CHAT_MENU.rename, label: "Rename…", icon: "edit" },
        { id: CHAT_MENU.archive, label: "Archive", icon: "folder" },
        { id: "sep", separator: true },
        { id: CHAT_MENU.delete, label: "Delete…", icon: "trash", destructive: true },
      ];
}

export function chatItem(chat: ChatLike, viewedChatId: string | null, origin?: string, now?: number, archived = false): NavItem {
  const open = chat.id === viewedChatId;
  const mark = rowMark(chat, open);
  const item: NavItem = { id: chat.id, title: chatTitle(chat), href: archived ? `/chat/${chat.id}?view=archived` : `/chat/${chat.id}` };
  if (chat.persona) item.avatar = avatar(chat.persona.name, chat.persona.color, chat.persona.avatar_url, origin);
  if (mark === "running") item.status = "done";
  if (mark === "unread") item.badge = { text: String(chat.unread), tone: "human" };
  else item.trailing = shortAgo(chat.last_message_at ?? chat.created_at, now);
  const sub: string[] = [];
  if (chat.state === "failed") sub.push("Failed");
  if (chat.temporary) sub.push("Temporary");
  // The web stacks every persona's avatar once more than one has joined; the row lists them.
  const who = chat.participants ?? [];
  if (who.length > 1) sub.push(who.map((p) => p.name).join(", "));
  if (sub.length) item.subtitle = sub.join(" · ");
  item.contextMenu = chatMenu(archived);
  return item;
}

/** A message hit as a row: the chat's title, the excerpt, and who said it. */
export function hitItem(h: ChatHitLike): NavItem {
  const item: NavItem = {
    id: `hit:${h.message_id}`,
    title: h.chat_title.trim() || "New conversation",
    subtitle: h.snippet.replace(MATCH_MARKS, ""),
    href: `/chat/${h.chat_id}?message=${h.message_id}`,
    trailing: h.role === "user" ? "You" : (h.persona_name ?? "Assistant"),
  };
  if (h.archived) item.badge = { text: "Archived" };
  return item;
}

function chatSections(input: ChatsModelInput, archived: boolean): NavSection[] {
  const row = (c: ChatLike) => chatItem(c, input.viewedChatId, input.origin, input.now, archived);
  if (archived) {
    return [{ id: "chats-archived", title: "Archived", items: input.chats.map(row), emptyText: input.error ?? "No archived conversations." }];
  }
  const groups = groupByDay(input.chats, input.now);
  const sections: NavSection[] = groups.filter((g) => g.chats.length > 0).map((g) => ({ id: `chats-${g.label.toLowerCase()}`, title: g.label, items: g.chats.map(row) }));
  if (sections.length === 0) sections.push({ id: "chats", title: "Chats", items: [], emptyText: input.error ?? "No conversations yet" });
  return sections;
}

export function buildChatsNavModel(input: ChatsModelInput): NavModel {
  const { viewedSpaceId = null } = input;
  const archived = input.view === "archived";
  const query = input.query ?? "";
  let sections: NavSection[];
  if (query) {
    const s = input.search ?? { status: "short" as const };
    const items = s.status === "ready" ? s.hits.map(hitItem) : [];
    const empty =
      s.status === "ready" ? "No messages match." : s.status === "error" ? s.message : s.status === "pending" ? "Searching…" : "Keep typing…";
    sections = [{ id: "chat-search-results", title: "Search results", items, emptyText: empty }];
  } else {
    sections = chatSections(input, archived);
    if (!archived && input.filteredTo && !input.error) {
      sections[sections.length - 1].items.push({ id: `${START_WITH_PREFIX}${input.filteredTo.id}`, title: `New chat with ${input.filteredTo.name}`, icon: "plus" });
    }
  }
  const newChat: NavAction = { id: NEW_CHAT_ACTION, label: "New chat", icon: "plus", accent: true };
  // NavAction can't be disabled, so without a ready harness the action is left out.
  if (!input.newChatDisabled) sections[0].actions = [newChat];
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
    // The persona picker has the picker slot, so Archived is a header menu with the view checked.
    actions: [
      {
        id: CHATS_VIEW_ACTION,
        label: "View",
        icon: "folder",
        menu: [
          { id: VIEW_ACTIVE, label: "Recent", checked: !archived },
          { id: VIEW_ARCHIVED, label: "Archived", icon: "folder", checked: archived },
        ],
      },
    ],
    search: { id: CHAT_SEARCH, placeholder: "Find in chats", value: query },
    sections,
    selectedId: viewedSpaceId ? `space:${viewedSpaceId}` : input.viewedChatId,
  };
  if (input.personas && input.personas.options.length > 1) {
    model.picker = { id: PERSONA_PICKER, value: input.personas.value, options: input.personas.options };
  }
  return model;
}
