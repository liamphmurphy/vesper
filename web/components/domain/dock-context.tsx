import type { ReactNode } from "react";
import { cx } from "@/lib/cx";

/** A chip above a dock composer: whom the message goes to, or what it carries. */
export const dockChip = "inline-flex h-6 min-w-0 max-w-full items-center gap-1.5 rounded-md border px-2 text-12";
/** A chip for what the message carries (the item in view, a selection, a folder). */
export const dockContextChip = cx(dockChip, "border-border bg-surface text-fg-secondary");

/**
 * The row of chips above a dock's composer, led by whom the message goes to: the dock always
 * talks to your persona, whatever the main pane shows.
 */
export function DockContext({ persona, label, children, className }: { persona?: string; label: string; children: ReactNode; className?: string }) {
  return (
    <div className={cx("flex w-full min-w-0 max-w-full flex-wrap items-center gap-1.5", className)} aria-label={label} data-testid="dock-context">
      <span className="flex-none text-12 text-fg-tertiary">To</span>
      <span data-testid="dock-chat-to" className={cx(dockChip, "border-accent/35 bg-accent-soft font-medium text-accent")}>
        <span className="min-w-0 truncate">{persona ?? "your persona"}</span>
      </span>
      {children}
    </div>
  );
}
