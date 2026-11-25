/**
 * Harness availability helpers (pure so they're unit-tested).
 * Secret values never reach the web app; only names do.
 */

/** One harness as GET /chat-models reports it. */
export type HarnessGroup = { harness: string; label: string; available: boolean; checking?: boolean; unavailable_reason?: string };

export type HarnessHealth = {
  /** At least one harness can run agents. */
  ready: boolean;
  /** An initial model listing is still in progress. */
  checking?: boolean;
  /** "Claude Code: no harness:anthropic secret", one per unavailable harness. */
  reasons: string[];
  /** Missing secret names mentioned by the reasons (names only, deduped). */
  secrets: string[];
};

/** The model picker's wording (LAZYAGENTS-12), so every surface says the same thing. */
export function unavailableReason(g: HarnessGroup): string {
  return g.unavailable_reason ?? "not configured";
}

export function harnessHealth(groups: HarnessGroup[] | undefined): HarnessHealth | undefined {
  if (!groups) return undefined;
  const down = groups.filter((g) => !g.available);
  const reasons = down.map((g) => `${g.label}: ${unavailableReason(g)}`);
  const secrets = [...new Set(down.flatMap((g) => unavailableReason(g).match(/\bharness:[a-z0-9_-]+/gi) ?? []))];
  return { ready: groups.some((g) => g.available), checking: groups.some((g) => g.checking), reasons, secrets };
}

/** "a", "a or b", "a, b or c" */
export function orList(items: string[]): string {
  if (items.length <= 1) return items.join("");
  return `${items.slice(0, -1).join(", ")} or ${items[items.length - 1]}`;
}

/** Which shell banner to show, if any: no harness wins over no runner. */
export function systemBanner(
  harness: HarnessHealth | undefined,
  runnerOnline: boolean | undefined,
  runnerStarting?: boolean,
): "harness" | "runner" | undefined {
  if (harness && !harness.ready && !harness.checking) return "harness";
  if (runnerOnline === false && !runnerStarting) return "runner";
  return undefined;
}
