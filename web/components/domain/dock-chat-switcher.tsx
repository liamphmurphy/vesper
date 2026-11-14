"use client";

import Link from "next/link";
import { DropdownMenu } from "radix-ui";
import { PersonaAvatar, personaLook } from "@/app/(app)/chat/_components/persona";
import { Icon } from "@/components/ui/icon";
import type { Schemas } from "@/lib/api/client";
import { cx } from "@/lib/cx";
import { ago } from "@/lib/format";

type Chat = Schemas["ChatSession"];

/** One group of chats in the switcher, e.g. "This page" and "Elsewhere in Knowledge". */
export type DockChatSection = { label: string; chats: Chat[] };

/**
 * The header of an app dock's chat tab: which chat is open, a menu to switch to another one the dock
 * keeps (grouped by section), and New chat. Shared by every app dock that keeps more than one chat.
 * `inline` drops the title and avatar so it fits in the open conversation's own header, which already
 * shows both: one header row instead of two that each name the chat.
 */
export function DockChatSwitcher({ current, sections, newLabel, onSelect, onNew, creating, inline = false }: {
  current?: Chat;
  sections: DockChatSection[];
  /** The menu's New entry, e.g. "New chat about this page". */
  newLabel: string;
  onSelect: (id: string) => void;
  onNew: () => void;
  creating?: boolean;
  inline?: boolean;
}) {
  const count = new Set(sections.flatMap((s) => s.chats.map((c) => c.id))).size;
  const who = current?.speaker ?? current?.persona;
  const label = `Switch chat${current ? `, now ${current.title}` : ""}`;
  const menu = (
    <DropdownMenu.Portal>
      <DropdownMenu.Content align="start" sideOffset={6} className="z-50 max-h-[420px] w-[340px] overflow-y-auto rounded-[10px] border border-border-float bg-surface-raised p-1 shadow-[var(--shadow-float)]">
        {sections.filter((s) => s.chats.length > 0).map((s, i) => (
          <DropdownMenu.Group key={s.label}>
            {i > 0 && <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />}
            <DropdownMenu.Label className="px-2 pb-1 pt-2 text-11 font-semibold uppercase tracking-wide text-fg-tertiary">{s.label}</DropdownMenu.Label>
            {s.chats.map((c) => (
              <ChatRow key={c.id} chat={c} selected={c.id === current?.id} onSelect={() => onSelect(c.id)} />
            ))}
          </DropdownMenu.Group>
        ))}
        {count > 0 && <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />}
        <DropdownMenu.Item onSelect={onNew} disabled={creating} className="flex cursor-default items-center gap-2 rounded-md px-2 py-2 text-13 font-semibold text-accent outline-none data-[highlighted]:bg-hover data-[disabled]:opacity-50">
          <Icon name="plus" size={13} />
          {newLabel}
        </DropdownMenu.Item>
        <DropdownMenu.Item asChild className="flex cursor-default items-center gap-2 rounded-md px-2 py-2 text-13 text-fg-secondary outline-none data-[highlighted]:bg-hover">
          <Link href="/chat">Open all in Chat <Icon name="expand" size={12} /></Link>
        </DropdownMenu.Item>
      </DropdownMenu.Content>
    </DropdownMenu.Portal>
  );
  if (inline)
    return (
      <span className="flex flex-none items-center gap-0.5" data-testid="dock-chat-switcher">
        <DropdownMenu.Root>
          <DropdownMenu.Trigger
            className="flex h-6 items-center gap-1 rounded-md px-1 text-11 font-semibold text-fg-tertiary outline-none hover:bg-hover hover:text-fg focus-visible:ring-2 focus-visible:ring-accent"
            aria-label={label}
            title="Switch chat"
          >
            <Icon name="msg" size={12} />
            {count > 0 && count}
          </DropdownMenu.Trigger>
          {menu}
        </DropdownMenu.Root>
        <button
          type="button"
          onClick={onNew}
          disabled={creating}
          className="grid size-6 place-items-center rounded-md text-accent hover:bg-hover disabled:opacity-50"
          aria-label={newLabel}
          title={newLabel}
        >
          <Icon name="plus" size={13} />
        </button>
      </span>
    );
  return (
    <div className="flex flex-none items-center gap-2 border-b border-border-subtle px-3 py-2" data-testid="dock-chat-switcher">
      <PersonaAvatar persona={personaLook(who)} size={20} />
      <DropdownMenu.Root>
        <DropdownMenu.Trigger
          className="flex min-w-0 flex-1 items-center gap-2 rounded-md bg-surface px-2 py-1 text-left text-13 font-semibold text-fg outline-none hover:bg-hover focus-visible:ring-2 focus-visible:ring-accent"
          aria-label={label}
        >
          <span className="min-w-0 flex-1 truncate">{current?.title || "New chat"}</span>
          {count > 0 && <span className="flex-none text-11 font-semibold text-fg-tertiary">{count}</span>}
          <Icon name="chev" size={12} className="flex-none text-fg-tertiary" />
        </DropdownMenu.Trigger>
        {menu}
      </DropdownMenu.Root>
      <button
        type="button"
        onClick={onNew}
        disabled={creating}
        className="flex flex-none items-center gap-1 rounded-md bg-selected px-2 py-1 text-12 font-semibold text-accent hover:bg-hover disabled:opacity-50"
        aria-label={newLabel}
        title={newLabel}
      >
        <Icon name="plus" size={12} /> New
      </button>
    </div>
  );
}

function ChatRow({ chat, selected, onSelect }: { chat: Chat; selected: boolean; onSelect: () => void }) {
  const who = chat.speaker ?? chat.persona;
  const when = chat.last_message_at ?? chat.created_at;
  const detail = [who?.name ?? "Assistant", ago(when), chat.state === "running" ? "replying…" : ""].filter(Boolean).join(" · ");
  return (
    <DropdownMenu.Item
      onSelect={onSelect}
      className={cx("flex cursor-default items-center gap-2.5 rounded-md px-2 py-1.5 outline-none data-[highlighted]:bg-hover", selected && "bg-selected")}
      aria-current={selected ? "true" : undefined}
    >
      <PersonaAvatar persona={personaLook(who)} size={22} />
      <span className="min-w-0 flex-1">
        <span className="block truncate text-13 font-semibold text-fg">{chat.title || "Untitled chat"}</span>
        <span className="block truncate text-11 text-fg-tertiary">{detail}</span>
      </span>
      {selected && <Icon name="check" size={13} className="flex-none text-accent" />}
    </DropdownMenu.Item>
  );
}
