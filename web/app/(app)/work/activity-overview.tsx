"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import type { Schemas } from "@/lib/api/client";
import { useCosts, useRunnerStatus } from "@/lib/api/hooks";
import { presetRange, spendLabel } from "@/lib/costs";
import { cx } from "@/lib/cx";
import { duration, runCost, shortAgo } from "@/lib/format";
import { KIND, waited } from "@/lib/inbox";
import { DOT_LABEL, isEnded, runDot, runTitle } from "@/lib/run-list";
import {
  computeActivityStats,
  isSameLocalDay,
  type ActivityFilter,
} from "@/lib/work-overview";
import { Icon } from "@/components/ui/icon";
import { Skeleton } from "@/components/ui/primitives";
import { AgentOrPersonaAvatar } from "../tickets/_components/ticket-row";
import { WorkSectionLabel } from "./work-nav-header";

type Run = Schemas["Run"];
type InboxItem = Schemas["InboxItem"];

const DOT_BG: Record<ReturnType<typeof runDot>, string> = {
  human: "bg-state-human",
  running: "bg-state-done",
  queued: "border border-fg-tertiary",
  done: "bg-state-done",
  failed: "bg-state-blocked",
  idle: "bg-fg-tertiary/40",
};

function needsBadgeTone(tone: string) {
  if (tone === "blocked") return "bg-pill-blocked-bg text-pill-blocked-fg";
  return "bg-pill-human-bg text-pill-human-fg";
}

/**
 * Center telemetry + actionable queue + live execution overview for Work -> Activity.
 * Sits beside the Run Companion on wide desktop viewports without touching LiveRun mount state.
 */
export function ActivityOverview({
  project,
  runs,
  needs,
  selectedRunId,
  filter,
  onSelectRun,
}: {
  project?: string;
  runs: readonly Run[];
  needs: readonly InboxItem[];
  selectedRunId?: string;
  filter: ActivityFilter;
  onSelectRun: (runId: string) => void;
}) {
  const [now] = useState(() => new Date());
  const [range7d] = useState(() => presetRange(7, now));
  const runner = useRunnerStatus().data;
  const costs7d = useCosts({ ...range7d, project }).data;

  const stats = useMemo(
    () => computeActivityStats(runs, needs, runner, costs7d, now),
    [runs, needs, runner, costs7d, now],
  );

  const uniqueRuns = useMemo(() => {
    const seen = new Set<string>();
    return runs.filter((r) => {
      if (seen.has(r.id)) return false;
      seen.add(r.id);
      return true;
    });
  }, [runs]);

  const runningNow = useMemo(
    () => uniqueRuns.filter((r) => !isEnded(r.state)),
    [uniqueRuns],
  );

  const finishedToday = useMemo(
    () =>
      uniqueRuns
        .filter((r) => isEnded(r.state) && isSameLocalDay(r.ended_at ?? r.started_at, now))
        .slice(0, 12),
    [uniqueRuns, now],
  );

  const reportsHref = `/reports?tab=costs&range=7${project ? `&project=${encodeURIComponent(project)}` : ""}`;
  const slotPct =
    stats.slotsMax > 0
      ? Math.min(100, Math.round((stats.slotsBusy / stats.slotsMax) * 100))
      : 0;

  return (
    <section
      aria-label="Activity overview"
      className="work-activity-main"
    >
      <div className="work-telemetry-strip" role="region" aria-label="Activity telemetry">
        <div className="work-telemetry-cell">
          <div className="flex items-center justify-between text-11 text-fg-tertiary">
            <span>Runner slots</span>
            <span
              className={cx(
                "font-mono text-10",
                stats.online ? "text-state-done" : stats.starting ? "text-fg-tertiary" : "text-pill-blocked-fg",
              )}
            >
              {stats.online ? "online" : stats.starting ? "starting" : "offline"}
            </span>
          </div>
          <div className="flex items-baseline gap-2">
            <span className="font-mono text-16 font-semibold leading-tight text-fg tabular-nums">
              {stats.slotsBusy}
              <span className="text-12 font-normal text-fg-tertiary">
                {" "}
                / {stats.slotsMax}
              </span>
            </span>
            <span className="text-11 text-fg-tertiary">
              {stats.queued} queued
            </span>
          </div>
          <div className="h-1 w-full overflow-hidden rounded-full bg-surface-sunken">
            <div
              className="h-full rounded-full bg-state-done transition-all"
              style={{ width: `${slotPct}%` }}
            />
          </div>
        </div>

        <div className="work-telemetry-cell">
          <div className="flex items-center justify-between text-11 text-fg-tertiary">
            <span>Needs you</span>
            {stats.needsYouCount > 0 && (
              <span className="size-1.5 rounded-full bg-state-human" />
            )}
          </div>
          <div
            className={cx(
              "font-mono text-16 font-semibold leading-tight tabular-nums",
              stats.needsYouCount > 0 ? "text-pill-human-fg" : "text-fg",
            )}
          >
            {stats.needsYouCount}
          </div>
          <div className="truncate text-11 text-fg-tertiary">
            {stats.needsYouCount === 0
              ? "Queue clear"
              : [
                  stats.needsApprovals && `${stats.needsApprovals} approval`,
                  stats.needsQuestions && `${stats.needsQuestions} question`,
                  stats.needsReviews && `${stats.needsReviews} review`,
                ]
                  .filter(Boolean)
                  .join(" · ")}
          </div>
        </div>

        <div className="work-telemetry-cell">
          <div className="text-11 text-fg-tertiary">Today&apos;s velocity</div>
          <div className="flex items-baseline gap-2">
            <span className="font-mono text-16 font-semibold leading-tight text-fg tabular-nums">
              {stats.completedToday}
            </span>
            <span className="text-11 text-fg-tertiary">runs done</span>
          </div>
          <div className="truncate text-11 text-fg-tertiary">
            {stats.prsToday} PR{stats.prsToday === 1 ? "" : "s"} ·{" "}
            {stats.passRatePct != null
              ? `${stats.passRatePct}% 24h pass`
              : "no 24h runs"}
          </div>
        </div>

        <div className="work-telemetry-cell">
          <div className="flex items-center justify-between text-11 text-fg-tertiary">
            <span>7-day spend</span>
            <Link href={reportsHref} className="text-accent hover:underline">
              Reports →
            </Link>
          </div>
          <div className="font-mono text-16 font-semibold leading-tight text-fg tabular-nums">
            {costs7d
              ? spendLabel(costs7d.total.cost_micros, costs7d.unpriced_runs)
              : "–"}
          </div>
          <div className="truncate text-11 text-fg-tertiary">
            {costs7d
              ? `${costs7d.total.runs} run${costs7d.total.runs === 1 ? "" : "s"} in range`
              : <Skeleton className="h-3 w-20" />}
          </div>
        </div>
      </div>

      {/* Needs you right now */}
      {filter !== "failed" && (
        <div className="flex flex-col gap-1.5">
          <WorkSectionLabel count={needs.length} tone={needs.length > 0 ? "human" : undefined}>
            Needs you right now
          </WorkSectionLabel>
          {needs.length === 0 ? (
            <div className="flex items-center gap-2 rounded-lg border border-border-subtle bg-surface px-3 py-2.5 text-12 text-fg-tertiary">
              <Icon name="check" size={14} className="text-state-done" />
              All caught up — no approvals or questions waiting on you.
            </div>
          ) : (
            <div className="flex flex-col gap-1.5">
              {needs.map((item) => {
                const kind = KIND[item.kind] ?? { label: item.kind, tone: "human" };
                const active = item.run_id && item.run_id === selectedRunId;
                return (
                  <div
                    key={item.id}
                    className={cx(
                      "flex items-center justify-between gap-3 rounded-lg border bg-surface px-3 py-2.5 transition-colors",
                      active
                        ? "border-accent bg-selected/40"
                        : "border-pill-human-bg/70 hover:bg-hover/40",
                    )}
                  >
                    <div className="flex min-w-0 flex-1 items-start gap-2.5">
                      {item.agent ? (
                        <AgentOrPersonaAvatar agent={item.agent} size="sm" />
                      ) : (
                        <span className="grid size-5 flex-none place-items-center rounded bg-pill-human-bg text-pill-human-fg">
                          <Icon name="inbox" size={12} />
                        </span>
                      )}
                      <div className="flex min-w-0 flex-1 flex-col gap-0.5">
                        <div className="flex flex-wrap items-center gap-1.5">
                          <span
                            className={cx(
                              "rounded px-1.5 py-[1px] text-10 font-medium",
                              needsBadgeTone(kind.tone),
                            )}
                          >
                            {kind.label}
                          </span>
                          {item.ticket_key && (
                            <span className="font-mono text-11 text-fg-tertiary">
                              {item.ticket_key}
                            </span>
                          )}
                          <span className="truncate text-13 font-medium text-fg">
                            {item.title}
                          </span>
                        </div>
                        <div className="flex items-center gap-2 text-11 text-fg-tertiary">
                          {item.agent && <span>{item.agent.name}</span>}
                          <span>waiting {waited(item.created_at)}</span>
                          {item.summary && (
                            <span className="truncate text-fg-secondary">
                              · {item.summary}
                            </span>
                          )}
                        </div>
                      </div>
                    </div>
                    <div className="flex flex-none items-center gap-1.5">
                      {item.run_id ? (
                        <button
                          type="button"
                          onClick={() => onSelectRun(item.run_id!)}
                          className={cx(
                            "inline-flex h-7 items-center rounded-md border px-2.5 text-12 font-medium transition-colors",
                            active
                              ? "border-accent bg-accent text-on-accent"
                              : "border-pill-human-bg text-pill-human-fg hover:bg-pill-human-bg",
                          )}
                        >
                          {active ? "Inspecting" : "Review →"}
                        </button>
                      ) : (
                        <Link
                          href={item.href}
                          className="inline-flex h-7 items-center rounded-md border border-border-strong px-2.5 text-12 font-medium text-fg hover:bg-hover"
                        >
                          Open →
                        </Link>
                      )}
                    </div>
                  </div>
                );
              })}
            </div>
          )}
        </div>
      )}

      {/* Running now */}
      {filter !== "failed" && runningNow.length > 0 && (
        <div className="flex flex-col gap-1.5">
          <WorkSectionLabel count={runningNow.length}>Running now</WorkSectionLabel>
          <div className="flex flex-col gap-1.5">
            {runningNow.map((r) => {
              const dot = runDot(r);
              const totalSteps = r.plan.length;
              const doneSteps = r.plan.filter((s) => s.state === "done").length;
              const currentStep = r.plan.find((s) => s.state === "current");
              const pct =
                totalSteps > 0 ? Math.round((doneSteps / totalSteps) * 100) : 0;
              const active = r.id === selectedRunId;

              return (
                <button
                  key={r.id}
                  type="button"
                  aria-current={active ? "true" : undefined}
                  onClick={() => onSelectRun(r.id)}
                  className={cx(
                    "flex flex-col gap-1.5 rounded-lg border px-3 py-2.5 text-left transition-colors",
                    active
                      ? "border-accent bg-selected/50"
                      : "border-border-subtle bg-surface hover:bg-hover/40",
                  )}
                >
                  <div className="flex items-center justify-between gap-2">
                    <div className="flex min-w-0 items-center gap-2">
                      <AgentOrPersonaAvatar agent={r.agent} size="sm" />
                      <span
                        aria-hidden
                        className={cx("size-2 flex-none rounded-full", DOT_BG[dot])}
                      />
                      {r.ticket_key && (
                        <span className="flex-none font-mono text-11 text-fg-tertiary">
                          {r.ticket_key}
                        </span>
                      )}
                      <span className="truncate text-13 font-medium text-fg">
                        {runTitle(r)}
                      </span>
                    </div>
                    <div className="flex flex-none items-center gap-2 font-mono text-11 text-fg-tertiary">
                      <span>{duration(r.started_at, r.ended_at)}</span>
                      {r.cost_usd > 0 && <span>{runCost(r.cost_usd, r.cost_source)}</span>}
                    </div>
                  </div>
                  <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-11 text-fg-secondary">
                    <span className="text-fg-tertiary">
                      {r.agent.name} · {r.harness}/{r.model}
                    </span>
                    {r.branch && (
                      <span className="inline-flex items-center gap-1 truncate font-mono text-10 text-fg-tertiary">
                        <Icon name="branch" size={11} />
                        {r.branch}
                      </span>
                    )}
                    {currentStep && (
                      <span className="truncate text-state-done">
                        Step {currentStep.position}/{totalSteps} · {currentStep.text}
                      </span>
                    )}
                  </div>
                  {totalSteps > 0 && (
                    <div className="h-1 w-full overflow-hidden rounded-full bg-surface-sunken">
                      <div
                        className="h-full rounded-full bg-state-done"
                        style={{ width: `${Math.max(8, pct)}%` }}
                      />
                    </div>
                  )}
                </button>
              );
            })}
          </div>
        </div>
      )}

      {/* Finished today */}
      <div className="flex flex-col gap-1">
        <WorkSectionLabel count={finishedToday.length}>
          Finished today
        </WorkSectionLabel>
        {finishedToday.length === 0 ? (
          <p className="rounded-lg border border-border-subtle bg-surface px-3 py-3 text-12 text-fg-tertiary">
            No completed runs recorded earlier today.
          </p>
        ) : (
          <div className="overflow-hidden rounded-lg border border-border-subtle bg-surface">
            <div className="divide-y divide-border-subtle">
              {finishedToday.map((r) => {
                const dot = runDot(r);
                const active = r.id === selectedRunId;
                return (
                  <button
                    key={r.id}
                    type="button"
                    aria-current={active ? "true" : undefined}
                    onClick={() => onSelectRun(r.id)}
                    className={cx(
                      "flex w-full items-center gap-2.5 px-3 py-2 text-left text-12 transition-colors",
                      active ? "bg-selected/60 text-fg" : "hover:bg-hover/50",
                    )}
                  >
                    <span
                      title={DOT_LABEL[dot]}
                      aria-hidden
                      className={cx("size-2 flex-none rounded-full", DOT_BG[dot])}
                    />
                    {r.ticket_key && (
                      <span className="w-16 flex-none truncate font-mono text-11 text-fg-tertiary">
                        {r.ticket_key}
                      </span>
                    )}
                    <span className="min-w-0 flex-1 truncate font-medium text-fg">
                      {runTitle(r)}
                    </span>
                    <span className="hidden flex-none text-11 text-fg-tertiary sm:inline">
                      {r.agent.name}
                    </span>
                    {r.pr_number && (
                      <span className="flex-none rounded bg-surface-sunken px-1.5 py-[1px] font-mono text-10 text-fg-secondary">
                        PR #{r.pr_number}
                      </span>
                    )}
                    <span className="w-12 flex-none text-right font-mono text-11 text-fg-tertiary">
                      {duration(r.started_at, r.ended_at)}
                    </span>
                    <span className="w-10 flex-none text-right font-mono text-11 text-fg-tertiary">
                      {shortAgo(r.ended_at ?? r.started_at)}
                    </span>
                  </button>
                );
              })}
            </div>
          </div>
        )}
      </div>
    </section>
  );
}
