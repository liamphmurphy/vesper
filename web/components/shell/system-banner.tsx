"use client";

import Link from "next/link";
import { useRunnerStatus } from "@/lib/api/hooks";
import { orList, systemBanner } from "@/lib/setup";
import { Icon } from "@/components/ui/icon";
import { IconButton } from "@/components/ui/button";
import { setStoredFlag, useHarnessHealth, useStoredFlag } from "@/components/domain/setup";

/**
 * Slim shell banner (LAZYAGENTS-45) on every screen while agents can't run:
 * no harness is available, or no runner is online. Names missing secrets by
 * name only. × hides it for this browser session; it returns next session if
 * the problem is still there.
 */
export function SystemBanner() {
  const harness = useHarnessHealth();
  const runner = useRunnerStatus();
  const kind = systemBanner(harness, runner.data?.online, runner.data?.starting);
  const key = kind && `la:banner:${kind}:dismissed`;
  const dismissed = useStoredFlag("session", key);
  if (!kind || !key || dismissed) return null;

  const [title, body, href, link] =
    kind === "harness"
      ? [
          "Agents can’t run yet.",
          harness!.secrets.length
            ? <>No harness is available: add {harness!.secrets.map((s, i) => <span key={s}>{i > 0 && (i === harness!.secrets.length - 1 ? " or " : ", ")}<code className="font-mono">{s}</code></span>)}.</>
            : `No harness is available${harness!.reasons.length ? `: ${harness!.reasons.join(" · ")}` : ""}.`,
          "/settings#secrets",
          "Fix in Provider credentials →",
        ]
      : ["No runner online.", "Dispatched work stays queued.", "/settings#runners", "Runner backends →"];

  return (
    <div
      role="status"
      aria-label={kind === "harness" ? `Agents can’t run: missing ${orList(harness!.secrets) || "a harness"}` : "No runner online"}
      className="flex flex-wrap items-center gap-3 border-b px-4 py-2 text-13 text-pill-human-fg"
      style={{
        borderColor: "color-mix(in srgb, var(--state-human) 30%, transparent)",
        background: "color-mix(in srgb, var(--state-human) 10%, transparent)",
      }}
    >
      <Icon name="alert" size={15} className="flex-none" />
      <span className="min-w-0 flex-1">
        <span className="font-semibold">{title}</span> {body}
      </span>
      <Link href={href} className="flex h-[26px] items-center rounded-md border border-pill-human-bg bg-surface px-2.5 text-13 hover:bg-hover">
        {link}
      </Link>
      <IconButton icon="x" label="Hide this banner for this session" size={24} onClick={() => setStoredFlag("session", key)} />
    </div>
  );
}
