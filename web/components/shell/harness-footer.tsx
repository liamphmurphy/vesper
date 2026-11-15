"use client";

import Link from "next/link";
import { Popover } from "radix-ui";
import { useState } from "react";
import { usePersonaDock } from "@/lib/api/hooks";
import { ANTIGRAVITY, checkedAgo, connectedHarnesses, harnessWorking, sessionPercent, usageSub, usageTone, type HarnessActivity } from "@/lib/harness-activity";
import { HarnessCharacter } from "./harness-character";

const status = (h: HarnessActivity) => (h.limited_until ? "limited" : harnessWorking(h) ? "working" : "idle");

/** One harness's reading, shown in a bubble beside its character. */
function UsageBubble({ h, all, onNavigate }: { h: HarnessActivity; all: HarnessActivity[]; onNavigate: () => void }) {
  const pct = sessionPercent(h);
  const primary = h.usage_available ? h.windows.find((w) => w.kind === "session") ?? h.windows[0] : undefined;
  const working = harnessWorking(h);
  return (
    <div className="harness-usage-row" data-harness={h.harness} data-tone={usageTone(h)}>
      <div className="harness-usage-heading">
        <h3>{h.label}</h3>
        <span className="harness-usage-value">{pct === null ? (h.usage_checking ? "…" : "—") : `${pct}%`}</span>
      </div>
      <div className="harness-usage-track" data-unavailable={pct === null}
        role={pct === null ? undefined : "progressbar"} aria-label={`${h.label} allowance used`}
        aria-valuemin={pct === null ? undefined : 0} aria-valuemax={pct === null ? undefined : 100} aria-valuenow={pct ?? undefined}>
        {pct !== null && <i style={{ width: `${Math.max(0, Math.min(100, pct))}%` }} />}
      </div>
      <div className="harness-usage-meta">
        <span>{primary ? `${primary.label} allowance used` : h.usage_checking ? "Checking usage…" : h.harness === ANTIGRAVITY ? "Allowance not reported" : "Usage unavailable"}</span>
        <span>{h.limited_until ? "Limited" : working ? `${h.running} working` : "Idle"}</span>
      </div>
      <p className="harness-usage-sub">{usageSub(h, all)}</p>
      <div className="harness-bubble-footer">
        <span>{checkedAgo([h])}</span>
        <Link href="/settings/runner" onClick={onNavigate}>Usage settings →</Link>
      </div>
    </div>
  );
}

/**
 * The harnesses that can run here; each character opens its own usage bubble. A stack in the
 * collapsed strip (the bubble opens to the right); a row above the expanded column's foot links
 * and in the phone header (the bubble opens above, or below where there's no room, so it never
 * covers the characters beside it).
 */
export function HarnessFooter({ layout = "rail" }: { layout?: "rail" | "row" }) {
  const rail = layout === "rail";
  const dock = usePersonaDock();
  const harnesses = connectedHarnesses(dock.data?.harnesses ?? []);
  const [open, setOpen] = useState<string | null>(null);
  if (!harnesses.length) return null;
  return (
    <div role="region" aria-label="Harness activity" className="harness-footer" data-rail={rail}>
      <div className="harness-characters">
        {harnesses.map((h) => (
          <Popover.Root key={h.harness} open={open === h.harness} onOpenChange={(next) => setOpen(next ? h.harness : null)}>
            <Popover.Trigger asChild>
              <button type="button" className="harness-button" data-harness={h.harness}
                aria-label={`${h.label}, ${status(h)}; show usage`}
                title={`${h.label} · ${h.limited_until ? "Limited" : harnessWorking(h) ? `${h.running} working` : "Idle"}`}>
                <HarnessCharacter harness={h.harness} working={harnessWorking(h)} />
                <span className="harness-name">{h.harness === ANTIGRAVITY ? "AG" : h.label}</span>
                {harnessWorking(h) && <i aria-hidden className="harness-working-dot" />}
              </button>
            </Popover.Trigger>
            <Popover.Portal>
              <Popover.Content side={rail ? "right" : "top"} sideOffset={6} collisionPadding={8} aria-label={`${h.label} usage`} className="harness-bubble">
                <UsageBubble h={h} all={harnesses} onNavigate={() => setOpen(null)} />
                <Popover.Arrow className="harness-bubble-arrow" width={14} height={7} />
              </Popover.Content>
            </Popover.Portal>
          </Popover.Root>
        ))}
      </div>
    </div>
  );
}
