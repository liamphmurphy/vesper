"use client";

import { createContext } from "react";
import type { LinkedItem } from "@/lib/chat-panels";
import { Icon, type IconName } from "@/components/ui/icon";

/**
 * Opens a linked item beside the chat. A context, so the memoized message bubbles (their sent
 * chips) can open one without re-rendering when the conversation's callbacks change. Unset in a
 * dock's chat, which has no dock of its own to open into: its chips stay plain.
 */
export const OpenLinkedItem = createContext<((item: LinkedItem) => void) | undefined>(undefined);

export const ITEM_ICON: Record<LinkedItem["kind"], IconName> = { ticket: "tickets", run: "play", page: "wiki" };

/**
 * The row under the chat's header naming what the conversation links to (the tickets and pages its
 * messages carried, its runs); each opens beside the chat.
 */
export function LinkedRow({ items, label, onOpen }: { items: LinkedItem[]; label: (item: LinkedItem) => string; onOpen: (item: LinkedItem) => void }) {
  if (items.length === 0) return null;
  return (
    <nav aria-label="Linked items" data-testid="linked-row" className="flex flex-none items-center gap-1.5 overflow-x-auto border-b border-border-subtle px-6 py-1.5">
      <span className="flex-none text-12 text-fg-tertiary">Linked</span>
      {items.map((item) => (
        <button key={itemKey(item)} type="button" onClick={() => onOpen(item)} title={`Open ${label(item)} beside the chat`}
          className="inline-flex h-6 max-w-[220px] flex-none items-center gap-1.5 rounded-full border border-border bg-surface px-2 text-12 text-fg-secondary hover:bg-hover hover:text-fg">
          <Icon name={ITEM_ICON[item.kind]} size={12} className="flex-none text-fg-tertiary" />
          <span className="truncate">{label(item)}</span>
        </button>
      ))}
    </nav>
  );
}

const itemKey = (i: LinkedItem) => (i.kind === "ticket" ? `ticket:${i.key}` : `${i.kind}:${i.id}`);
