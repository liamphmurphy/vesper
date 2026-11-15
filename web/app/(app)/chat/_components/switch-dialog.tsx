"use client";

import { Dialog } from "radix-ui";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";

type Label = { harness: string; model: string };

/**
 * Confirms a switch to another harness (ADR Decision 3): the next message starts
 * a new session with a transcript handoff, so hidden state is lost. A model
 * change on the same harness keeps the session and never shows this.
 */
export function HarnessSwitchDialog({
  from,
  to,
  agent,
  onConfirm,
  onSecondOpinion,
  onCancel,
  onClosed,
}: {
  from: Label;
  to: Label | null;
  agent: string;
  onConfirm: () => void;
  onSecondOpinion?: () => void;
  onCancel: () => void;
  /** Where focus goes on close: the menu item that opened the dialog is gone by then. */
  onClosed: () => void;
}) {
  return (
    <Dialog.Root open={!!to} onOpenChange={(o) => !o && onCancel()}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          onCloseAutoFocus={(e) => {
            e.preventDefault();
            onClosed();
          }}
          className="motion-dialog fixed left-1/2 top-[14vh] z-50 flex w-[min(560px,calc(100%-32px))] -translate-x-1/2 flex-col gap-4 rounded-2xl border border-border-float bg-surface-raised p-6 shadow-[var(--shadow-float)] outline-none"
        >
          {to && (
            <>
              <div className="flex flex-col gap-1.5">
                <Dialog.Title className="type-heading">
                  Switch to {to.harness} · {to.model}?
                </Dialog.Title>
                <Dialog.Description className="text-13 text-fg-secondary">
                  {to.harness} is a different harness, so the next message starts a new session. It gets a handoff of this
                  chat instead of {from.harness}’s session.
                </Dialog.Description>
              </div>
              <section aria-label="Carries over" className="flex flex-col gap-1.5">
                <h3 className="flex items-center gap-1.5 text-13 font-semibold text-state-done">
                  <Icon name="check" size={13} strokeWidth={2} /> Carries over
                </h3>
                <ul className="ml-5 flex flex-col gap-1 text-13">
                  <li>The latest messages, up to 40 or 24,000 characters</li>
                  <li>The chat title and the context you attached</li>
                  <li>{agent}’s instructions</li>
                </ul>
              </section>
              <section aria-label="Is lost" className="flex flex-col gap-1.5">
                <h3 className="flex items-center gap-1.5 text-13 font-semibold text-pill-blocked-fg">
                  <Icon name="x" size={13} strokeWidth={2} /> Is lost
                </h3>
                <ul className="ml-5 flex flex-col gap-1 text-13">
                  <li>{from.harness}’s hidden reasoning</li>
                  <li>Its tool calls and their results (only replies are kept)</li>
                  <li>Files and pages it read into its context</li>
                  <li>The prompt cache, so the first reply costs more</li>
                  <li>Older messages beyond the handoff budget</li>
                </ul>
              </section>
              <p className="border-t border-border-subtle pt-3 text-12 text-fg-tertiary">
                Changing model within {from.harness} keeps the session and doesn’t ask. The switch applies from your next
                message; you can still pick again.
              </p>
              <div className="flex flex-wrap justify-end gap-2">
                <Dialog.Close asChild>
                  <Button variant="outline">Cancel</Button>
                </Dialog.Close>
                {onSecondOpinion && (
                  <Button variant="outline" icon="compare" data-testid="switch-second-opinion" onClick={onSecondOpinion}>
                    Second opinion instead
                  </Button>
                )}
                <Button variant="primary" onClick={onConfirm}>
                  Switch harness
                </Button>
              </div>
            </>
          )}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
