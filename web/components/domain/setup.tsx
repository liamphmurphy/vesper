"use client";

import { workSettingsHref } from "@/lib/spaces";
import Link from "next/link";
import { useQuery } from "@tanstack/react-query";
import { useEffect, useSyncExternalStore } from "react";
import { api, unwrap } from "@/lib/api/client";
import { useBootstrap, useChatModels, useRunnerStatus, useSecrets } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { harnessHealth, orList, setupChecklist, type HarnessHealth, type SetupStep } from "@/lib/setup";
import { Button, ButtonLink } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { ProgressBar } from "@/components/domain/data";

// ------------------------------------------------------------ stored flags

const FLAG_EVENT = "la:flags";

function subscribe(cb: () => void) {
  window.addEventListener("storage", cb);
  window.addEventListener(FLAG_EVENT, cb);
  return () => {
    window.removeEventListener("storage", cb);
    window.removeEventListener(FLAG_EVENT, cb);
  };
}

type Store = "local" | "session";
const storage = (s: Store) => (s === "local" ? window.localStorage : window.sessionStorage);

/** A "1" flag in local or session storage that re-renders every reader when it changes. */
export function useStoredFlag(store: Store, key: string | undefined): boolean {
  return useSyncExternalStore(
    subscribe,
    () => {
      if (!key) return false;
      try {
        return storage(store).getItem(key) === "1";
      } catch {
        return false;
      }
    },
    () => false,
  );
}

export function setStoredFlag(store: Store, key: string) {
  try {
    storage(store).setItem(key, "1");
  } catch {
    // Storage disabled: the flag lasts until the next render only.
  }
  window.dispatchEvent(new Event(FLAG_EVENT));
}

const reviewedKey = (ws: string) => `la:setup:${ws}:agents-reviewed`;
const dismissedKey = (ws: string) => `la:setup:${ws}:dismissed`;
export const setupIntroKey = (ws: string) => `la:setup:${ws}:intro-done`;

/** Opening the Agents page ticks the agent review step. */
export function useMarkAgentsReviewed() {
  const ws = useBootstrap().data?.workspace.id;
  useEffect(() => {
    if (ws) setStoredFlag("local", reviewedKey(ws));
  }, [ws]);
}

// ------------------------------------------------------------ data

/** Harness availability from GET /chat-models; undefined until it loads. */
export function useHarnessHealth(): HarnessHealth | undefined {
  return harnessHealth(useChatModels().data);
}

function usePlanList() {
  // Same key as the Plans screen, so starting a plan there ticks the checklist.
  return useQuery({ queryKey: ["planning", "list"], queryFn: () => unwrap(api.GET("/planning-sessions")) });
}

/**
 * The first-run checklist from live data. Each source refreshes on its own
 * (secret saves invalidate chat models, the runner polls, plans share the
 * Plans cache), so steps tick without a reload. Undefined until enough loads.
 */
export function useSetupChecklist(): { steps?: SetupStep[]; workspace?: string } {
  const boot = useBootstrap();
  const secrets = useSecrets();
  const runner = useRunnerStatus();
  const models = useChatModels();
  const plans = usePlanList();
  const workspace = boot.data?.workspace.id;
  const reviewed = useStoredFlag("local", workspace && reviewedKey(workspace));
  const harness = harnessHealth(models.data) ?? (models.isError ? { ready: false, reasons: [], secrets: [] } : undefined);
  const planCount = plans.data?.length ?? (plans.isError ? 0 : undefined);
  const runnerReady = runner.data || runner.isError;
  if (!boot.data || !harness || planCount === undefined || !runnerReady) return { workspace };
  const steps = setupChecklist({
    repos: boot.data.projects.filter((p) => !p.archived && p.repo_url).length,
    repoHref: workSettingsHref(boot.data.projects.find((p) => !p.archived)),
    harnessSecret: !!secrets.data?.secrets.some((s) => s.name.startsWith("harness:") && !s.project),
    harness,
    runnerOnline: !!runner.data?.online,
    runnerStarting: !!runner.data?.starting,
    runners: runner.data?.runners ?? [],
    agents: boot.data.agents.length,
    agentsReviewed: reviewed,
    plans: planCount,
  });
  return { steps, workspace };
}

// ------------------------------------------------------------ checklist

function StepMark({ done, next }: { done: boolean; next: boolean }) {
  return done ? (
    <span role="img" aria-label="Done" className="flex size-[18px] flex-none items-center justify-center rounded-full bg-state-done text-white">
      <Icon name="check" size={12} strokeWidth={2.4} />
    </span>
  ) : (
    <span role="img" aria-label="Not done" className={cx("size-[18px] flex-none rounded-full border-[1.6px]", next ? "border-state-human" : "border-border-strong")} />
  );
}

/**
 * First-run checklist (Dashboard and Settings). Hidden while loading and once
 * dismissed; Dismiss only appears when every step is done, and the choice is
 * remembered per workspace.
 */
export function SetupChecklist({ className }: { className?: string }) {
  const { steps, workspace } = useSetupChecklist();
  const dismissed = useStoredFlag("local", workspace && dismissedKey(workspace));
  if (!steps || !workspace || dismissed) return null;
  const done = steps.filter((s) => s.done).length;

  if (done === steps.length) {
    return (
      <section aria-label="Setup complete" className={cx("flex flex-wrap items-center gap-3 rounded-xl border border-border bg-surface px-[18px] py-3.5", className)}>
        <span className="flex size-[22px] flex-none items-center justify-center rounded-full bg-state-done text-white">
          <Icon name="check" size={13} strokeWidth={2.4} />
        </span>
        <div className="flex flex-1 flex-col">
          <span className="font-semibold">You’re set up</span>
          <span className="text-13 text-fg-secondary">All {steps.length} steps done. Agents can run.</span>
        </div>
        <Button variant="outline" onClick={() => setStoredFlag("local", dismissedKey(workspace))}>
          Dismiss
        </Button>
      </section>
    );
  }

  const next = steps.find((s) => !s.done);
  return (
    <section aria-labelledby="setup-title" className={cx("rounded-xl border border-border bg-surface", className)}>
      <div className="flex flex-col gap-2 px-[18px] pb-3 pt-3.5">
        <h2 id="setup-title" className="type-heading">Get set up</h2>
        <p className="text-13 text-fg-secondary">
          {done} of {steps.length} done · ticks update as you finish each step
        </p>
        <ProgressBar value={done / steps.length} color="var(--state-done)" label={`${done} of ${steps.length} setup steps done`} />
      </div>
      <ul>
        {steps.map((s) => {
          const isNext = s === next;
          return (
            <li key={s.key} className="flex flex-wrap items-center gap-3 border-t border-border-row px-[18px] py-2.5">
              <StepMark done={s.done} next={isNext} />
              <div className="flex min-w-0 flex-[1_1_240px] flex-col">
                <span className={cx("text-13", s.done ? "text-fg-secondary line-through" : "font-medium", isNext && "font-semibold")}>{s.label}</span>
                <span className={cx("text-12", !s.done && s.key === "secret" ? "text-pill-human-fg" : "text-fg-tertiary")}>{s.detail}</span>
              </div>
              {isNext ? (
                <ButtonLink href={s.href} variant="primary">
                  {s.link} →
                </ButtonLink>
              ) : (
                <Link href={s.href} className={cx("text-13", s.done ? "text-fg-secondary hover:text-accent" : "text-accent")}>
                  {s.link} →
                </Link>
              )}
            </li>
          );
        })}
      </ul>
    </section>
  );
}

// ------------------------------------------------------------ guards

/** Why nothing can start right now, with a link to fix it. Shown next to New chat / Start chat. */
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
