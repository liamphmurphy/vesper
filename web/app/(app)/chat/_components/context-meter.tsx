"use client";

import { useState } from "react";
import { Popover } from "radix-ui";
import type { Schemas } from "@/lib/api/client";
import { useCompactChat, useSetChatAutoRollover } from "@/lib/api/hooks";
import { contextMeterState, ROLLOVER_PRESETS } from "@/lib/context-meter";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { cx } from "@/lib/cx";

/** Compact context-window meter pill with popover for 1-click compaction and auto-rollover threshold. */
export function ContextMeter({
  chat,
  pinnedCount,
  disabled,
}: {
  chat: Schemas["ChatSession"];
  pinnedCount: number;
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [focus, setFocus] = useState("");
  const compact = useCompactChat(chat.id);
  const setRollover = useSetChatAutoRollover(chat.id);

  const state = contextMeterState(chat.context_tokens, chat.effective_auto_rollover_tokens);
  const barTone =
    state.tone === "danger"
      ? "bg-state-blocked"
      : state.tone === "warning"
        ? "bg-state-human"
        : "bg-accent";
  const pillTone =
    state.tone === "danger"
      ? "border-state-blocked/50 text-state-blocked"
      : state.tone === "warning"
        ? "border-state-human/50 text-state-human"
        : "border-border text-fg-secondary hover:text-fg";

  const currentOverride = chat.auto_rollover_tokens === undefined ? null : chat.auto_rollover_tokens;

  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      <Popover.Trigger asChild>
        <button
          type="button"
          data-testid="context-meter"
          title={
            chat.compact_pending
              ? "Context compacted — next turn starts a fresh window"
              : `Context window: ${state.label}`
          }
          className={cx(
            "inline-flex h-7 items-center gap-1.5 rounded-full border bg-surface px-2.5 text-11 font-medium transition-colors hover:bg-hover",
            pillTone,
          )}
        >
          {state.limit > 0 && (
            <span aria-hidden className="h-1.5 w-8 overflow-hidden rounded-full bg-border-subtle">
              <span
                className={cx("block h-full rounded-full transition-all duration-(--motion-fast)", barTone)}
                style={{ width: `${Math.max(state.tokens > 0 ? 6 : 0, Math.round(state.ratio * 100))}%` }}
              />
            </span>
          )}
          <span className="font-mono">{chat.compact_pending ? "Compacted" : state.label}</span>
        </button>
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Content
          align="end"
          sideOffset={6}
          data-testid="context-meter-popover"
          className="motion-float z-50 flex w-72 flex-col gap-3 rounded-xl border border-border-float bg-surface-raised p-3.5 shadow-[var(--shadow-float)] outline-none"
        >
          <div className="flex items-center justify-between">
            <span className="text-13 font-semibold text-fg">Context window</span>
            <span className="font-mono text-12 text-fg-secondary">{state.label}</span>
          </div>

          {state.limit > 0 && (
            <div className="h-2 w-full overflow-hidden rounded-full bg-surface-sunken">
              <div
                className={cx("h-full rounded-full transition-all duration-(--motion-fast)", barTone)}
                style={{ width: `${Math.round(state.ratio * 100)}%` }}
              />
            </div>
          )}

          <p className="text-12 text-fg-secondary">
            {pinnedCount > 0
              ? `${pinnedCount} pinned ${pinnedCount === 1 ? "message" : "messages"} will be preserved verbatim when compacting.`
              : "Pin key messages with the bookmark icon to preserve them verbatim across compaction."}
          </p>

          <div className="flex flex-col gap-1.5">
            <span className="text-11 font-semibold uppercase tracking-wide text-fg-tertiary">Auto-compact threshold</span>
            <div className="flex flex-wrap gap-1">
              {ROLLOVER_PRESETS.map((preset) => {
                const active = currentOverride === preset.value;
                return (
                  <button
                    key={preset.label}
                    type="button"
                    disabled={disabled || setRollover.isPending}
                    onClick={() =>
                      setRollover.mutate({
                        revision: chat.revision,
                        autoRolloverTokens: preset.value,
                      })
                    }
                    className={cx(
                      "rounded-md border px-2 py-1 text-11 font-medium transition-colors",
                      active
                        ? "border-accent bg-accent-soft text-accent"
                        : "border-border bg-surface text-fg-secondary hover:bg-hover hover:text-fg",
                    )}
                  >
                    {preset.label}
                  </button>
                );
              })}
            </div>
          </div>

          <div className="flex flex-col gap-2 border-t border-border-subtle pt-2.5">
            <input
              type="text"
              aria-label="Optional compaction focus"
              value={focus}
              onChange={(e) => setFocus(e.target.value)}
              placeholder="Optional focus (e.g. keep API schema)…"
              disabled={disabled || compact.isPending}
              className="h-7 w-full rounded-md border border-border bg-surface px-2 text-12 text-fg placeholder:text-fg-tertiary focus:border-accent focus:outline-none"
            />
            <Button
              variant="primary"
              disabled={disabled || compact.isPending || !!chat.compact_pending}
              onClick={() =>
                compact.mutate(focus.trim() || undefined, {
                  onSuccess: () => {
                    setFocus("");
                    setOpen(false);
                  },
                })
              }
            >
              <Icon name="refresh" size={13} />
              {chat.compact_pending ? "Compacted for next turn" : compact.isPending ? "Compacting…" : "Compact now"}
            </Button>
            {(compact.error || setRollover.error) && (
              <p role="alert" className="text-11 text-pill-blocked-fg">
                {((compact.error || setRollover.error) as Error).message}
              </p>
            )}
          </div>
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  );
}
