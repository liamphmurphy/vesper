/**
 * First-run setup and system health (LAZYAGENTS-45). Pure so they're
 * unit-tested: the checklist and the shell banner read state the API already
 * reports (chat-model availability, secrets, runner heartbeat, projects,
 * agents, plans). Secret values never reach the web app; only names do.
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

export type SetupKey = "repo" | "secret" | "runner" | "agents" | "plan";
export type SetupStep = { key: SetupKey; label: string; href: string; link: string; done: boolean; detail: string };

export type SetupState = {
  /** Spaces whose (active) work has a repository URL. */
  repos: number;
  /** Where to set a repository: the first space that tracks work, or a new one (LAZYAGENTS-213). */
  repoHref?: string;
  /** A workspace-wide harness:* secret is stored. */
  harnessSecret: boolean;
  harness: HarnessHealth;
  runnerOnline: boolean;
  runnerStarting?: boolean;
  runners: { backend: string; max_concurrent: number }[];
  agents: number;
  /** The person opened the Agents page in this browser. */
  agentsReviewed: boolean;
  plans: number;
};

/** First-run checklist, in the order a new workspace should do it. */
export function setupChecklist(s: SetupState): SetupStep[] {
  const backends = [...new Set(s.runners.map((r) => r.backend))].join(", ");
  const slots = s.runners.reduce((n, r) => n + r.max_concurrent, 0);
  const secretDone = s.harnessSecret || s.harness.ready;
  return [
    {
      key: "repo",
      label: "Connect a repository to a space",
      href: s.repoHref ?? "/spaces/new?work=1",
      link: "Spaces",
      done: s.repos > 0,
      detail: s.repos > 0 ? `${s.repos} ${s.repos === 1 ? "space has" : "spaces have"} a repository` : "Without one, runs start in an empty workspace and can’t push.",
    },
    {
      key: "secret",
      label: "Add at least one provider credential",
      href: "/settings#secrets",
      link: "Provider credentials",
      done: secretDone,
      detail: secretDone ? "A harness can run agents" : s.harness.reasons.join(" · ") || "No harness is available.",
    },
    {
      key: "runner",
      label: "Check the runner backend",
      href: "/settings#runners",
      link: "Runner backends",
      done: s.runnerOnline,
      detail: s.runnerOnline
        ? `${s.runners.length} ${s.runners.length === 1 ? "runner" : "runners"} online · ${backends} · ${slots} ${slots === 1 ? "slot" : "slots"}`
        : s.runnerStarting
          ? "Runner is starting…"
          : "No runner online. Dispatched work stays queued.",
    },
    {
      key: "agents",
      label: s.agents > 0 ? "Review who does the work" : "Give a persona work",
      href: "/settings?section=personas&filter=tickets",
      link: "Personas",
      // Someone who already ran a plan has used the personas that work.
      done: s.agents > 0 && (s.agentsReviewed || s.plans > 0),
      detail: s.agents > 0 ? `${s.agents} ${s.agents === 1 ? "persona works" : "personas work"} on tickets or runs · ticked once you open Personas` : "No persona takes tickets yet.",
    },
    {
      key: "plan",
      label: "Run a sample planning goal",
      href: "/plans",
      link: "Plans",
      done: s.plans > 0,
      detail: s.plans > 0 ? `${s.plans} ${s.plans === 1 ? "plan" : "plans"} so far` : secretDone ? "Ticked when any plan exists" : "Needs a harness first · ticked when any plan exists",
    },
  ];
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
