"use client";

import { createContext, useContext, useState, type ReactNode } from "react";
import { DropdownMenu } from "radix-ui";
import type { Harness, Schemas } from "@/lib/api/client";
import { Icon, type IconName } from "@/components/ui/icon";
import { cx } from "@/lib/cx";
import { SaveDialogs, type SaveMode } from "./save-actions";
import { SecondOpinionMenu, type SecondOpinionPick } from "./second-opinion-menu";

/**
 * What a message's toolbar can do to the conversation around it. A context, read through a ref by
 * the provider, so the memoized bubbles don't re-render as the draft changes.
 */
export type MessageActions = {
  /** Quotes the message into the composer, addressed to its author when someone else would answer. */
  reply: (body: string, authorId?: string, author?: string) => void;
  /** Starts a thread on the message: a side conversation about it, in the right panel. */
  thread?: (messageId: string) => void;
  /** Requests a read-only cross-harness second opinion anchored to the message. */
  secondOpinion?: {
    groups: Schemas["ChatHarnessModels"][] | undefined;
    currentHarness?: Harness;
    currentModel?: string;
    start: (messageId: string, pick: SecondOpinionPick) => void;
  };
};
export const MessageActionsContext = createContext<MessageActions | null>(null);

const itemClass = "flex cursor-default items-center gap-2 rounded-md px-2 py-1.5 text-13 text-fg outline-none data-[highlighted]:bg-hover data-[disabled]:opacity-50";
const iconButton = "grid size-7 place-items-center rounded-md text-fg-secondary hover:bg-hover hover:text-fg focus-visible:ring-2 focus-visible:ring-accent outline-none";

function ToolButton({ icon, label, onClick, children }: { icon: IconName; label: string; onClick: () => void; children?: ReactNode }) {
  return (
    <button type="button" aria-label={label} title={label} onClick={onClick} className={iconButton}>
      {children ?? <Icon name={icon} size={14} />}
    </button>
  );
}

type MoreItem = { icon: IconName; label: string; onSelect: () => void; danger?: boolean };

/**
 * The same small toolbar on every message, shown on hover or keyboard focus at its top right, the
 * way a messaging app does it: Reply, Thread, Copy, and ⋯ for the rest (Edit, Retry, Top of reply,
 * Save). It floats over the message so the transcript keeps no row of buttons under each reply.
 */
export function MessageToolbar({
  messageId,
  body,
  authorId,
  author,
  mine,
  chat,
  onEdit,
  onRetry,
  onTop,
  testId,
}: {
  messageId: string;
  body: string;
  authorId?: string;
  author?: string;
  mine: boolean;
  chat: { id: string; title: string; project?: string };
  onEdit?: () => void;
  onRetry?: () => void;
  onTop?: () => void;
  testId?: string;
}) {
  const actions = useContext(MessageActionsContext);
  const [copied, setCopied] = useState(false);
  const [save, setSave] = useState<SaveMode | null>(null);
  const [menuOpen, setMenuOpen] = useState(false);
  const [secondOpinionOpen, setSecondOpinionOpen] = useState(false);
  const more: MoreItem[] = [
    ...(onRetry ? [{ icon: "refresh" as const, label: "Retry", onSelect: onRetry }] : []),
    ...(onTop ? [{ icon: "chev" as const, label: "Top of reply", onSelect: onTop }] : []),
    ...(!mine ? [
      { icon: "wiki" as const, label: "Save to wiki", onSelect: () => setSave("wiki") },
      { icon: "artifacts" as const, label: "Save as artifact", onSelect: () => setSave("artifact") },
    ] : []),
  ];
  return (
    <>
      <div
        role="toolbar"
        aria-label="Message actions"
        data-testid={testId}
        data-open={(menuOpen || secondOpinionOpen) || undefined}
        className={cx(
          "absolute -top-4 right-0 z-10 flex items-center gap-0.5 rounded-lg border border-border-float bg-surface-raised p-0.5 shadow-[var(--shadow-float)]",
          // Out of sight until the message is hovered or a control in it has focus; kept open while its menu is.
          "opacity-0 transition-opacity duration-(--motion-fast) group-hover/msg:opacity-100 group-focus-visible/msg:opacity-100 focus-within:opacity-100 data-[open]:opacity-100",
          "pointer-coarse:static pointer-coarse:self-end pointer-coarse:opacity-100 pointer-coarse:shadow-none",
        )}
      >
        {actions && (
          <ToolButton icon="msg" label="Reply" onClick={() => actions.reply(body, mine ? undefined : authorId, mine ? undefined : author)}>
            <svg aria-hidden viewBox="0 0 16 16" width={14} height={14} fill="none" stroke="currentColor" strokeWidth={1.6} strokeLinecap="round" strokeLinejoin="round">
              <path d="M6.5 4 3 7.5 6.5 11M3.5 7.5H10a3 3 0 0 1 3 3V12" />
            </svg>
          </ToolButton>
        )}
        {actions?.thread && <ToolButton icon="branch" label="Start a thread" onClick={() => actions.thread!(messageId)} />}
        {!mine && actions?.secondOpinion && (
          <SecondOpinionMenu
            groups={actions.secondOpinion.groups}
            currentHarness={actions.secondOpinion.currentHarness}
            currentModel={actions.secondOpinion.currentModel}
            onOpenChange={setSecondOpinionOpen}
            onSelect={(pick) => actions.secondOpinion!.start(messageId, pick)}
          />
        )}
        <ToolButton
          icon={copied ? "check" : "link"}
          label={copied ? "Copied" : "Copy"}
          onClick={() => {
            void navigator.clipboard?.writeText(body).then(() => {
              setCopied(true);
              setTimeout(() => setCopied(false), 1500);
            });
          }}
        />
        {onEdit && <ToolButton icon="edit" label="Edit" onClick={onEdit} />}
        {more.length > 0 && (
          <DropdownMenu.Root open={menuOpen} onOpenChange={setMenuOpen}>
            <DropdownMenu.Trigger asChild>
              <button type="button" aria-label="More message actions" title="More" className={iconButton}>
                <Icon name="dots" size={14} />
              </button>
            </DropdownMenu.Trigger>
            <DropdownMenu.Portal>
              <DropdownMenu.Content align="end" sideOffset={4} className="z-50 min-w-[180px] rounded-[10px] border border-border-float bg-surface-raised p-1 shadow-[var(--shadow-float)]">
                {more.map((m) => (
                  <DropdownMenu.Item key={m.label} onSelect={m.onSelect} className={cx(itemClass, m.danger && "text-state-blocked")}>
                    <Icon name={m.icon} size={13} className="text-fg-secondary" />
                    {m.label}
                  </DropdownMenu.Item>
                ))}
              </DropdownMenu.Content>
            </DropdownMenu.Portal>
          </DropdownMenu.Root>
        )}
      </div>
      {!mine && <SaveDialogs chat={chat} body={body} mode={save} onClose={() => setSave(null)} />}
    </>
  );
}

/** Under a message with a thread: how many messages it holds, and a way back into it. */
export function ThreadLink({ messageId, count, running }: { messageId: string; count: number; running: boolean }) {
  const actions = useContext(MessageActionsContext);
  if (!actions?.thread) return null;
  return (
    <button type="button" onClick={() => actions.thread!(messageId)} data-testid="thread-link"
      className="flex items-center gap-1.5 rounded-md px-1 py-0.5 text-12 font-medium text-accent hover:bg-hover">
      <Icon name="branch" size={12} />
      {running ? "Thread · answering…" : `Thread · ${count} ${count === 1 ? "message" : "messages"}`}
    </button>
  );
}
