"use client";

import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { useDeferredValue, useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { useChat, useChats, useChatSearch, useCreateChat, useDeleteChat, useUpdateChat } from "@/lib/api/hooks";
import { chatTitle, groupByDay, newestChat, rowMark } from "@/lib/chat-ui";
import { shortAgo } from "@/lib/format";
import { cx } from "@/lib/cx";
import { isActive } from "@/lib/project-scope";
import { Button, IconButton } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, Skeleton, TextInput } from "@/components/ui/primitives";
import { useHarnessHealth } from "@/components/domain/setup";
import { RestoreChat } from "./restore";
import { PersonaAvatar, PersonaStack, PersonaFilter, personaLook, usePersonaActivity, usePersonaFilter } from "./persona";
import { hoverReveal } from "@/lib/reveal";
import { useEntrances } from "@/components/ui/motion";

type Chat = Schemas["ChatSession"];
const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

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

/** New chat: an icon on the rail, the menu's first button otherwise. */
export function NewConversationButton({ id, rail }: { id?: string; rail?: boolean }) {
  const conversation = useNewConversation(id);
  return (
    <div className={cx(rail ? "flex-none" : "min-w-0 flex-1")}>
      <button
        type="button"
        aria-label={rail ? "New chat" : undefined}
        title="New chat"
        disabled={conversation.disabled}
        onClick={conversation.start}
        className={cx(
          "disabled:cursor-not-allowed disabled:opacity-50",
          rail
            ? "grid size-[30px] place-items-center rounded-md border border-border-strong bg-btn-outline text-fg-2 hover:bg-hover"
            : "flex h-[34px] w-full items-center gap-2 rounded-[9px] border border-accent/35 bg-accent-soft px-3 text-14 font-semibold text-accent hover:brightness-110",
        )}
      >
        <Icon name="plus" size={15} strokeWidth={1.7} />
        {!rail && "New chat"}
      </button>
    </div>
  );
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

/**
 * Who's in the conversation: every persona, stacked, once more than one has joined (whichever
 * persona is picked, so a guest's list shows the host too); under All, the host's avatar alone.
 */
function RowPersonas({ chat, all }: { chat: Chat; all: boolean }) {
  const participants = chat.participants ?? [];
  if (participants.length > 1) {
    const names = participants.map((p) => p.name).join(", ");
    return (
      <span title={names} className="flex-none">
        <PersonaStack personas={participants.map(personaLook)} size={18} />
        <span className="sr-only">With {names}: </span>
      </span>
    );
  }
  return all ? <PersonaAvatar persona={personaLook(chat.persona)} /> : null;
}

/** When the conversation was last active, right-aligned on its one-line row. */
function RowAge({ chat }: { chat: Chat }) {
  return <time dateTime={chat.last_message_at ?? chat.created_at} className="flex-none text-12 text-fg-tertiary">{shortAgo(chat.last_message_at ?? chat.created_at)}</time>;
}

/** Trash button that asks first, inline in the row; deleting can't be undone. */
function DeleteChat({ chat, onDeleted }: { chat: Chat; onDeleted: () => void }) {
  const del = useDeleteChat();
  const [asking, setAsking] = useState(false);
  const label = chatTitle(chat);
  if (!asking) return <IconButton icon="trash" label={`Delete ${label}`} onClick={() => setAsking(true)} />;
  return (
    <div role="group" aria-label={`Confirm delete ${label}`} className="flex basis-full flex-wrap items-center gap-1.5 px-2 pb-1.5">
      <span className="flex-1 text-12 text-fg">Delete this conversation? This can’t be undone.</span>
      <Button
        variant="primary"
        className="!h-6 bg-state-blocked !px-2 !text-12"
        disabled={del.isPending}
        // mutateAsync: the row unmounts when the list refetches.
        onClick={() => del.mutateAsync(chat.id).then(onDeleted, () => undefined)}
      >
        Delete
      </Button>
      <Button variant="outline" className="!h-6 !px-2 !text-12" onClick={() => setAsking(false)}>
        Cancel
      </Button>
      {del.isError && <p role="alert" className="basis-full text-12 text-pill-blocked-fg">{errorText(del.error)}</p>}
    </div>
  );
}

/** An archived conversation: open it read-only, or restore it to the active list. */
function ArchivedRow({ chat, active, onDeleted, all }: { chat: Chat; active: boolean; onDeleted: () => void; all: boolean }) {
  return (
    <li className={cx("flex flex-wrap items-center gap-1 rounded-md pr-1", active ? "bg-selected" : "hover:bg-hover")}>
      <Link
        href={`/chat/${chat.id}?view=archived`}
        aria-current={active ? "page" : undefined}
        className="flex min-w-0 flex-1 items-center gap-2 px-2 py-1.5 text-13"
      >
        <RowPersonas chat={chat} all={all} />
        <span className="min-w-0 flex-1 truncate">{chatTitle(chat)}</span>
        <RowAge chat={chat} />
      </Link>
      <RestoreChat chat={chat} compact />
      <DeleteChat chat={chat} onDeleted={onDeleted} />
    </li>
  );
}

function ChatRow({ chat, active, onLeave, all }: { chat: Chat; active: boolean; onLeave: () => void; all: boolean }) {
  const update = useUpdateChat();
  const [editing, setEditing] = useState(false);
  const [title, setTitle] = useState(chat.title);
  const label = chatTitle(chat);
  const mark = rowMark(chat, active);

  function save(e: FormEvent) {
    e.preventDefault();
    const t = title.trim();
    if (!t || t === chat.title) return setEditing(false);
    // mutateAsync: the row may unmount on refetch before mutate-level callbacks run.
    update.mutateAsync({ id: chat.id, patch: { revision: chat.revision, title: t } }).then(() => setEditing(false), () => undefined);
  }
  return (
    <li data-enter-key={chat.id} className="flex flex-col">
      {editing ? (
        <form onSubmit={save} className="flex items-center gap-1 px-1 py-1">
          <TextInput
            aria-label="Conversation title"
            value={title}
            placeholder="New conversation"
            autoFocus
            onChange={(e) => setTitle(e.target.value)}
            onKeyDown={(e) => e.key === "Escape" && setEditing(false)}
          />
          <IconButton icon="check" label="Save title" type="submit" />
          <IconButton icon="x" label="Cancel rename" onClick={() => setEditing(false)} />
        </form>
      ) : (
        <div className={cx("group relative flex flex-wrap items-center gap-1 rounded-md pr-1", active ? "bg-selected" : "hover:bg-hover")}>
          <Link
            href={`/chat/${chat.id}`}
            aria-current={active ? "page" : undefined}
            className="flex min-w-0 flex-1 items-center gap-2 px-2 py-1.5 text-13"
          >
            <RowPersonas chat={chat} all={all} />
            <span className="flex min-w-0 flex-1 items-center gap-2">
              {mark === "running" && <span aria-hidden data-running className="size-1.5 flex-none rounded-full bg-state-done" />}
              {mark === "unread" && <span aria-hidden data-unread className="size-1.5 flex-none rounded-full bg-state-human" />}
              <span className={cx("truncate", mark === "unread" && "font-semibold text-fg")}>{label}</span>
              {chat.temporary && (
                <span title="Temporary chat: deleted after a day without messages" className="flex-none text-fg-tertiary">
                  <Icon name="clock" size={12} />
                  <span className="sr-only"> (temporary)</span>
                </span>
              )}
              {mark === "running" && <span className="sr-only"> (running)</span>}
              {mark === "unread" && <span className="sr-only"> (unread)</span>}
              {chat.state === "failed" && <span className="text-12 text-pill-blocked-fg">Failed</span>}
            </span>
            <RowAge chat={chat} />
          </Link>
          {/* Over the row until hovered, so titles get the full width. A delete confirmation takes its own line. */}
          <div className={cx("absolute right-1 top-1/2 flex -translate-y-1/2 items-center gap-1 rounded-md transition-opacity focus-within:opacity-100 has-[[role=group]]:static has-[[role=group]]:basis-full has-[[role=group]]:translate-y-0 has-[[role=group]]:flex-wrap has-[[role=group]]:opacity-100", hoverReveal(), active ? "bg-selected" : "bg-hover")}>
          <IconButton icon="edit" label={`Rename ${label}`} onClick={() => { setTitle(chat.title); setEditing(true); }} />
          <IconButton
            icon="folder"
            label={`Archive ${label}`}
            disabled={update.isPending}
            onClick={() =>
              update.mutateAsync({ id: chat.id, patch: { revision: chat.revision, archived: true } }).then(onLeave, () => undefined)
            }
          />
          <DeleteChat chat={chat} onDeleted={onLeave} />
          </div>
        </div>
      )}
      {update.isError && (
        <p role="alert" className="px-2 pb-1 text-12 text-pill-blocked-fg">
          {errorText(update.error)}
        </p>
      )}
    </li>
  );
}

const MATCH = /(\uE000[^\uE001]*\uE001)/;

/** A search hit's excerpt with its matches marked; the excerpt is only ever text. */
function Snippet({ text }: { text: string }) {
  return (
    <span className="line-clamp-2 text-12 text-fg-secondary">
      {text.split(MATCH).map((part, i) => (i % 2 ? <mark key={i} className="rounded-sm bg-accent-soft px-px text-fg">{part.slice(1, -1)}</mark> : part))}
    </span>
  );
}

/** Message search across the person's chats: results stand in for the list while there's a query. */
function ChatSearchResults({ query, onPick }: { query: string; onPick: () => void }) {
  const results = useChatSearch(query);
  const hits = results.data?.hits ?? [];
  if (query.trim().length < 2 || results.isPending) return <p className="px-2 py-1.5 text-12 text-fg-tertiary">{query.trim().length < 2 ? "Keep typing…" : "Searching…"}</p>;
  if (results.isError) return <p role="alert" className="px-2 py-1.5 text-12 text-pill-blocked-fg">{errorText(results.error)}</p>;
  if (hits.length === 0) return <p className="px-2 py-1.5 text-12 text-fg-tertiary">No messages match.</p>;
  return (
    <ul aria-label="Search results" className="flex flex-col gap-0.5">
      {hits.map((h) => (
        <li key={h.message_id} data-testid="chat-search-hit">
          <Link href={`/chat/${h.chat_id}?message=${h.message_id}`} onClick={onPick} className="flex flex-col gap-0.5 rounded-md px-2 py-1.5 hover:bg-hover">
            <span className="truncate text-13 text-fg">{h.chat_title || "New conversation"}</span>
            <Snippet text={h.snippet} />
            <span className="truncate text-12 text-fg-tertiary">{h.role === "user" ? "You" : (h.persona_name ?? "Assistant")}{h.archived ? " · archived" : ""}</span>
          </Link>
        </li>
      ))}
    </ul>
  );
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

/**
 * The conversation history at the top of the menu: persona strip, then Active by day or
 * Archived (kept in ?view= on the chat page). `between` goes under the persona strip (the
 * history drawer's spaces); `fill` drops the narrow-screen height cap for a drawer of its own and
 * puts a Search chats box on top, where a phone has no room to tuck it into a heading.
 */
export function ChatHistory({ id, viewed, between, fill, action }: { id?: string; viewed: string | null; between?: ReactNode; fill?: boolean; action?: ReactNode }) {
  const router = useRouter();
  const { view, setView } = useChatListView();
  const { filter, active, pick, create, startWith } = usePersonaNav(id);
  const activity = usePersonaActivity(viewed);
  const all = filter.query === "all";
  // Archived chats from spaces are listed too: the archive is one place.
  const archived = useChats(true, filter.query, view === "archived", "all");
  const chats = view === "archived" ? archived : active;
  const list = chats.data?.chats;
  // An empty filter on a persona other than the default offers to start a conversation with it.
  const picked = filter.value !== "default" && !all ? filter.personas.find((p) => p.id === filter.value) : undefined;
  // Filtered to one persona, the list ends with a way to start another chat with it (mockup frame B).
  const filteredTo = filter.value === "default" ? filter.personas.find((p) => p.id === filter.defaultId) : picked;
  // Archiving or deleting the open conversation goes back to /chat, which resumes the newest one.
  const leave = (chatId: string) => chatId === id && router.push("/chat");
  const [query, setQuery] = useState("");
  const [finding, setFinding] = useState(false);
  const deferredQuery = useDeferredValue(query);
  const stopFinding = () => {
    setQuery("");
    setFinding(false);
  };
  // Find and Archived sit at the end of the list's first heading ("Today", "Archived"), and
  // finding turns that heading into the search box, so the two stay in one row.
  const headingRow = (label: string) => (
    <div className="flex items-center gap-0.5 pb-1 pl-2">
      {finding ? (
        <TextInput aria-label="Find in chats" placeholder="Find in chats" autoFocus className="h-[26px] min-w-0 flex-1 text-12" value={query} onChange={(e) => setQuery(e.target.value)} onKeyDown={(e) => e.key === "Escape" && stopFinding()} />
      ) : (
        <h3 className="min-w-0 flex-1 truncate text-12 font-medium text-fg-tertiary">{label}</h3>
      )}
      <IconButton icon="search" size={24} label="Find in chats" aria-pressed={finding} onClick={() => (finding ? stopFinding() : setFinding(true))} />
      <IconButton icon="folder" size={24} label="Archived conversations" aria-pressed={view === "archived"} onClick={() => setView(view === "archived" ? "active" : "archived")} />
    </div>
  );
  const groups = list && view === "active" && !query ? groupByDay(list) : [];
  // While finding, the row stays on top, so the box keeps focus as results replace the days.
  const onTop = finding || groups.length === 0;
  // A conversation started elsewhere (another tab, a persona) rises in at the top.
  const nav = useRef<HTMLElement>(null);
  useEntrances(nav);
  return (
    <aside aria-label="Chat history" className={cx("flex min-h-0 flex-1 flex-col gap-1.5", !fill && "max-[799px]:max-h-64")}>
      {fill && (
        <TextInput type="search" aria-label="Search chats" placeholder="Search chats" className="!h-[44px] w-full !text-16" value={query} onChange={(e) => setQuery(e.target.value)} />
      )}
      <PersonaFilter filter={{ ...filter, set: pick }} activity={activity} trailing={action} />
      {between}
      <nav ref={nav} aria-label="Chats" className="mt-1 min-h-0 flex-1 overflow-y-auto">
        {onTop && headingRow(view === "archived" ? "Archived" : "Recent")}
        {query ? (
          <ChatSearchResults query={deferredQuery} onPick={() => undefined} />
        ) : chats.isError ? (
          <Banner tone="blocked" title="Couldn’t load conversations">{errorText(chats.error)}</Banner>
        ) : !list ? (
          <div aria-busy="true" className="flex flex-col gap-2">
            {[80, 60, 70].map((w) => (
              <Skeleton key={w} className="h-5" style={{ width: `${w}%` }} />
            ))}
          </div>
        ) : list.length === 0 ? (
          view === "active" && picked ? (
            <div className="flex flex-col items-start gap-1 px-2 py-4 text-13">
              <p className="text-fg-secondary">No conversations with {picked.name} yet.</p>
              <button type="button" className="text-accent hover:underline disabled:opacity-50" disabled={create.isPending} onClick={() => startWith(picked.id)}>
                Start one with {picked.name} →
              </button>
              {create.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{errorText(create.error)}</p>}
            </div>
          ) : (
            <p className="px-2 py-4 text-13 text-fg-secondary">
              {view === "archived" ? "No archived conversations." : "No conversations yet."}
            </p>
          )
        ) : view === "archived" ? (
          <>
            <ul className="flex flex-col gap-px">
              {list.map((c) => (
                <ArchivedRow key={c.id} chat={c} active={c.id === id} all={all} onDeleted={() => leave(c.id)} />
              ))}
            </ul>
            <p className="px-2 py-3 text-12 text-fg-tertiary">Archived conversations are read-only. Restore one to continue it.</p>
          </>
        ) : (
          <div className="flex flex-col gap-3">
            {filteredTo && view === "active" && (
              <button type="button" disabled={create.isPending} onClick={() => startWith(filteredTo.id)}
                className="order-last flex h-7 items-center gap-1.5 rounded-md px-2 text-left text-13 font-medium text-accent hover:bg-hover disabled:opacity-50">
                <Icon name="plus" size={13} />
                New chat with {filteredTo.name}
              </button>
            )}
            {groups.map((g, i) => (
              <section key={g.label} aria-label={g.label} className="flex flex-col gap-px">
                {i === 0 && !onTop ? headingRow(g.label) : <h3 className="px-2 pb-1 text-12 font-medium text-fg-tertiary">{g.label}</h3>}
                <ul className="flex flex-col gap-px">
                  {g.chats.map((c) => (
                    <ChatRow key={c.id} chat={c} active={c.id === id} all={all} onLeave={() => leave(c.id)} />
                  ))}
                </ul>
              </section>
            ))}
          </div>
        )}
      </nav>
    </aside>
  );
}
