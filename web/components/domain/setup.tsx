"use client";

import Link from "next/link";
import { useChatModels } from "@/lib/api/hooks";
import { harnessHealth, orList, type HarnessHealth } from "@/lib/setup";

/** Harness availability from GET /chat-models; undefined until it loads. */
export function useHarnessHealth(): HarnessHealth | undefined {
  return harnessHealth(useChatModels().data);
}

/** Why nothing can start right now, with a link to fix it. Shown next to Start chat. */
export function NoHarnessNote({ health }: { health: HarnessHealth }) {
  if (health.checking) {
    return <p role="status" className="text-12 text-fg-secondary">Checking available models… This updates automatically.</p>;
  }
  return (
    <p role="status" className="text-12 text-pill-human-fg">
      No harness is available
      {health.secrets.length ? `: add ${orList(health.secrets)}.` : health.reasons.length ? `: ${health.reasons.join(" · ")}.` : "."}{" "}
      <Link href="/settings#secrets" className="text-accent hover:underline">
        Add a secret in Settings →
      </Link>
    </p>
  );
}
