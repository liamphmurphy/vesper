"use client";

import { Popover } from "radix-ui";
import { useContext, useId, useState } from "react";
import type { LinkTarget } from "@/lib/api/client";
import { useLinkSuggest } from "@/lib/api/hooks";
import { chipFromTarget, type Chip } from "@/lib/chat-context";
import { CREATE_KINDS, type CreateKind } from "@/lib/chat-commands";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { SuggestionList } from "@/components/domain/link-editor";
import { composerIconButton } from "./reply-tools";
import { OpenLinkedItem } from "./item-panel";
import type { LinkedItem } from "@/lib/chat-panels";

/** Only these kinds can be attached to a chat message. */
export const acceptTarget = (t: LinkTarget) => chipFromTarget(t) !== null;

const ICON = { artifact: "artifacts", page: "wiki", section: "artifacts", ticket: "tickets", canvas: "edit" } as const;

function Label({ chip }: { chip: Chip }) {
  return (
    <>
      <Icon name={ICON[chip.ref.kind]} size={12} className="flex-none text-fg-tertiary" />
      <span className="max-w-[220px] truncate">{chip.label}</span>
    </>
  );
}

const chipClass = "inline-flex h-6 items-center gap-1.5 rounded-md border border-border bg-surface px-2 text-12 text-fg-secondary";

/** Attachments waiting to be sent; each can be removed. */
export function ChipList({ chips, onRemove, disabled }: { chips: Chip[]; onRemove: (key: string) => void; disabled?: boolean }) {
  if (chips.length === 0) return null;
  return (
    <ul aria-label="Attached context" className="flex flex-wrap gap-1.5" data-testid="context-chips">
      {chips.map((c) => (
        <li key={c.key} className={chipClass} data-testid="context-chip">
          <Label chip={c} />
          <button
            type="button"
            aria-label={`Remove ${c.label}`}
            disabled={disabled}
            onClick={() => onRemove(c.key)}
            className="grid size-4 cursor-pointer place-items-center rounded-xs text-fg-tertiary hover:bg-hover hover:text-fg disabled:cursor-default"
          >
            <Icon name="x" size={11} />
          </button>
        </li>
      ))}
    </ul>
  );
}

/** What a sent message carried. On the chat page a ticket or page opens beside the chat. */
export function SentChips({ chips }: { chips: Chip[] }) {
  const open = useContext(OpenLinkedItem);
  if (chips.length === 0) return null;
  const linkOf = (c: Chip): LinkedItem | undefined =>
    c.ref.kind === "ticket" && c.ref.key ? { kind: "ticket", key: c.ref.key } : c.ref.kind === "page" && c.ref.id ? { kind: "page", id: c.ref.id } : undefined;
  return (
    <ul aria-label="Context" className="flex flex-wrap justify-end gap-1" data-testid="sent-chips">
      {chips.map((c) => {
        const item = open && linkOf(c);
        return (
          <li key={c.key} className={chipClass} data-testid="sent-chip">
            {item ? (
              <button type="button" onClick={() => open(item)} title={`Open ${c.label} beside the chat`} className="inline-flex min-w-0 items-center gap-1.5 hover:text-fg">
                <Label chip={c} />
              </button>
            ) : (
              <Label chip={c} />
            )}
          </li>
        );
      })}
    </ul>
  );
}

/** "Add context": the same suggestions as [[ in the composer, in a popover. */
/** The + menu's "Create with {persona}" section: a Doc, Slides or a Design made with the chat's persona. */
export type CreateWith = { persona: string; onCreate: (kind: CreateKind) => void };

const CREATE_ICON: Record<CreateKind, "edit" | "slides" | "designs" | "audio"> = {
  doc: "edit",
  slides: "slides",
  design: "designs",
  music: "audio",
};

export function AddContext({ onPick, onClosed, disabled, compact, create }: { onPick: (t: LinkTarget) => void; onClosed?: () => void; disabled?: boolean; compact?: boolean; create?: CreateWith }) {
  const [open, setOpen] = useState(false);
  const [q, setQ] = useState("");
  const [active, setActive] = useState(0);
  const listId = useId();
  const suggest = useLinkSuggest(q, open);
  const items = (suggest.data ?? []).filter(acceptTarget);

  function pick(t: LinkTarget) {
    onPick(t);
    setOpen(false);
  }
  return (
    <Popover.Root
      open={open}
      onOpenChange={(o) => {
        setOpen(o);
        if (o) {
          setQ("");
          setActive(0);
        }
      }}
    >
      <Popover.Trigger asChild>
        {compact ? (
          <button type="button" aria-label="Add context" title="Add context: a page, ticket, run or file" disabled={disabled} className={composerIconButton}>
            <Icon name="plus" size={15} strokeWidth={1.7} />
          </button>
        ) : (
          <Button variant="outline" icon="plus" disabled={disabled}>
            Add context
          </Button>
        )}
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Content
          align="start"
          sideOffset={6}
          onCloseAutoFocus={(e) => {
            // Back to the composer rather than the trigger button.
            e.preventDefault();
            onClosed?.();
          }}
          className="motion-float z-50 flex w-80 flex-col gap-1 rounded-xl border border-border-float bg-surface-raised p-1 shadow-[var(--shadow-float)] outline-none">
          <input
            role="combobox"
            aria-label="Search pages, artifacts and tickets"
            aria-expanded={items.length > 0}
            aria-controls={listId}
            aria-autocomplete="list"
            aria-activedescendant={items.length ? `${listId}-${active}` : undefined}
            autoFocus
            value={q}
            placeholder="Search pages, artifacts, tickets"
            onChange={(e) => {
              setQ(e.target.value);
              setActive(0);
            }}
            onKeyDown={(e) => {
              if (!items.length) return;
              if (e.key === "ArrowDown" || e.key === "ArrowUp") {
                e.preventDefault();
                setActive((a) => (a + (e.key === "ArrowDown" ? 1 : items.length - 1)) % items.length);
              } else if (e.key === "Enter") {
                e.preventDefault();
                pick(items[active] ?? items[0]);
              }
            }}
            className="h-8 rounded-md border border-border-strong bg-surface px-2 text-13 text-fg outline-none focus-visible:border-accent"
          />
          <SuggestionList id={listId} label="Context to attach" items={items} active={active} onActive={setActive} onPick={pick} className="!border-0 !p-0 !shadow-none" />
          {suggest.isError ? (
            <p role="alert" className="px-2 py-1 text-12 text-pill-blocked-fg">Couldn’t load suggestions.</p>
          ) : suggest.data && items.length === 0 ? (
            <p className="px-2 py-1 text-12 text-fg-tertiary">No matches.</p>
          ) : null}
          {create && (
            <div role="group" aria-label={`Create with ${create.persona}`} data-testid="create-with" className="mt-1 flex flex-col gap-0.5 border-t border-border pt-1.5">
              <p className="px-2 pb-0.5 text-11 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">Create with {create.persona}</p>
              <div className="flex gap-0.5">
                {CREATE_KINDS.filter((k) => !k.hint).map((k) => (
                  <button key={k.kind} type="button" onClick={() => { setOpen(false); create.onCreate(k.kind); }} className="flex items-center gap-2 rounded-md px-2 py-1.5 text-13 text-fg-secondary hover:bg-hover hover:text-fg">
                    <Icon name={CREATE_ICON[k.kind]} size={14} />
                    {k.label}
                  </button>
                ))}
              </div>
              {CREATE_KINDS.filter((k) => k.hint).map((k) => (
                <button key={k.kind} type="button" onClick={() => { setOpen(false); create.onCreate(k.kind); }} className="flex items-center gap-2.5 rounded-md bg-accent/15 px-2 py-1.5 text-left hover:bg-accent/25">
                  <Icon name={CREATE_ICON[k.kind]} size={16} className="flex-none text-accent" />
                  <span className="flex min-w-0 flex-1 flex-col">
                    <span className="text-13 font-semibold text-fg">{k.label}</span>
                    <span className="text-12 text-fg-secondary">{k.hint}</span>
                  </span>
                  {k.command && <span className="flex-none text-11 text-fg-tertiary">{k.command}</span>}
                </button>
              ))}
            </div>
          )}
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  );
}
