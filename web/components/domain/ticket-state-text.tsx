"use client";

import type { TicketSummary } from "@/lib/api/client";
import { cx } from "@/lib/cx";
import { stateText, type NeedsYou } from "@/lib/work-rows";

/** The current state: amber when the ticket's run waits on the person, red when blocked. */
export function StateText({ t, needs, className }: { t: TicketSummary; needs?: NeedsYou; className?: string }) {
  const s = stateText(t, needs);
  return (
    <span
      data-state-text
      title={s.text}
      className={cx("truncate text-13", s.tone === "human" ? "text-pill-human-fg" : s.tone === "blocked" ? "text-pill-blocked-fg" : "text-fg-tertiary", className)}
    >
      {s.text}
    </span>
  );
}
