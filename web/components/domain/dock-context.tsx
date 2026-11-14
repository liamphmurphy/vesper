import type { ReactNode } from "react";
import { cx } from "@/lib/cx";

/** A chip above a dock composer: whom the message goes to, or what it carries. */
export const dockChip = "inline-flex h-6 max-w-full items-center gap-1.5 rounded-md border px-2 text-12";
/** A chip for what the message carries (the item in view, a selection, a folder). */
export const dockContextChip = cx(dockChip, "border-border bg-surface text-fg-secondary");

/**
 * The row of chips above a dock's composer, led by whom the message goes to: the dock always
 * talks to your persona, whatever the main pane shows.
 */
export function DockContext({ persona, label, children }: { persona?: string; label: string; children: ReactNode }) {
  return (
    <div className="flex flex-wrap items-center gap-1" aria-label={label} data-testid="dock-context">
      <span className="text-11 text-fg-tertiary">To</span>
      <span data-testid="dock-chat-to" className={cx(dockChip, "border-accent/35 bg-accent-soft font-medium text-accent")}>{persona ?? "your persona"}</span>
      {children}
    </div>
  );
}
