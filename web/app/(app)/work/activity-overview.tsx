"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useMemo, useRef, useState } from "react";
import type { Schemas } from "@/lib/api/client";
import { useCosts, useRunnerStatus, useTickets } from "@/lib/api/hooks";
import { useNativeContextMenu } from "@/lib/native-shell/hooks";
import { toast } from "@/lib/toast";
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
import { runCharacterState } from "@/lib/work-persona";
import { UnassignedAvatar } from "@/components/domain/avatars";
import { DispatchDialog } from "@/components/domain/dispatch-dialog";
import { WorkPersonaAvatar } from "@/components/domain/work-persona-avatar";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Skeleton } from "@/components/ui/primitives";

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

function SectionHeading({
  children,
  count,
  tone,
  right,
}: {
  children: string;
  count?: number;
  tone?: "human";
  right?: React.ReactNode;
}) {
  return (
    <div className="flex items-center justify-between gap-3 px-0.5">
      <h2
        className={cx(
          "flex items-center gap-1.5 text-11 font-semibold uppercase tracking-[0.06em]",
          tone === "human" ? "text-pill-human-fg" : "text-fg-tertiary",
        )}
      >
        <span>{children}</span>
        {count != null && count > 0 && (
          <span className="font-mono font-normal">{count}</span>
        )}
      </h2>
      {right}
    </div>
  );
}

function needsBadgeTone(tone: string) {
  if (tone === "blocked") return "bg-pill-blocked-bg text-pill-blocked-fg";
  return "bg-pill-human-bg text-pill-human-fg";
}

function NeedsYouCard({
  item,
  onSelectRun,
}: {
  item: InboxItem;
  onSelectRun: (runId: string) => void;
}) {
  const router = useRouter();
  const cardRef = useRef<HTMLDivElement>(null);
  const kind = KIND[item.kind] ?? { label: item.kind, tone: "human" };
  const targetHref = item.href || (item.run_id ? `/work?run=${encodeURIComponent(item.run_id)}` : "/work");
  const copy = (text: string, title: string) => {
    void navigator.clipboard?.writeText(text).then(() => toast({ title, tone: "success" }));
  };

  useNativeContextMenu(
    cardRef,
    () => [
      ...(item.run_id
        ? [{ id: "inspect", label: "Open run", icon: "activity", onSelect: () => onSelectRun(item.run_id!) }]
        : []),
      { id: "open", label: "Open", icon: "inbox", onSelect: () => router.push(targetHref) },
      { id: "open-tab", label: "Open in new tab", icon: "external", onSelect: () => window.open(targetHref, "_blank") },
      ...(item.ticket_key
        ? [{ id: "open-ticket", label: `Open ${item.ticket_key}`, icon: "tickets", onSelect: () => router.push(`/tickets/${item.ticket_key}`) }]
        : []),
      { id: "sep-copy", separator: true },
      { id: "copy-link", label: "Copy link", icon: "link", onSelect: () => copy(new URL(targetHref, window.location.href).href, "Link copied") },
    ],
    { links: "menu" },
  );

  return (
    <div
      ref={cardRef}
      className="flex items-center justify-between gap-3 rounded-xl border border-state-human/40 bg-pill-human-bg/15 px-3.5 py-2.5 transition-colors hover:bg-pill-human-bg/25"
    >
      <div className="flex min-w-0 flex-1 items-start gap-2.5">
        {item.agent ? (
          <WorkPersonaAvatar agent={item.agent} size="sm" state="needs_you" />
        ) : (
          <span className="grid size-5 flex-none place-items-center rounded-full bg-pill-human-bg text-pill-human-fg">
            <Icon name="inbox" size={11} />
          </span>
        )}
        <div className="flex min-w-0 flex-1 flex-col gap-0.5">
          <div className="flex flex-wrap items-center gap-1.5">
            <span className={cx("rounded px-1.5 py-[1px] text-10 font-medium", needsBadgeTone(kind.tone))}>
              {kind.label}
            </span>
            {item.ticket_key && (
              <span className="font-mono text-11 text-fg-tertiary">{item.ticket_key}</span>
            )}
            <span className="truncate text-13 font-medium text-fg">{item.title}</span>
          </div>
          <div className="flex items-center gap-2 text-11 text-fg-tertiary">
            {item.agent && <span>{item.agent.name}</span>}
            <span>waiting {waited(item.created_at)}</span>
            {item.summary && (
              <span className="truncate text-fg-secondary">· {item.summary}</span>
            )}
          </div>
        </div>
      </div>
      <div className="flex flex-none items-center gap-1.5">
        {item.run_id ? (
          <Button
            variant="approve-outline"
            onClick={() => onSelectRun(item.run_id!)}
            className="h-7 px-2.5 text-12"
          >
            Review →
          </Button>
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
}

function useRunRowContextMenu(
  ref: React.RefObject<HTMLButtonElement | null>,
  r: Run,
  onSelectRun: (runId: string) => void,
) {
  const router = useRouter();
  const href = `/runs/${r.id}`;
  const copy = (text: string, title: string) => {
    void navigator.clipboard?.writeText(text).then(() => toast({ title, tone: "success" }));
  };
  useNativeContextMenu(ref, () => [
    { id: "inspect", label: "Open run", icon: "activity", onSelect: () => onSelectRun(r.id) },
    { id: "open", label: "Open full page", icon: "play", onSelect: () => router.push(href) },
    { id: "open-tab", label: "Open in new tab", icon: "external", onSelect: () => window.open(href, "_blank") },
    ...(r.ticket_key
      ? [{ id: "open-ticket", label: `Open ${r.ticket_key}`, icon: "tickets", onSelect: () => router.push(`/tickets/${r.ticket_key}`) }]
      : []),
    { id: "sep-copy", separator: true },
    { id: "copy-id", label: "Copy run ID", icon: "copy", onSelect: () => copy(r.id, "Run ID copied") },
    { id: "copy-link", label: "Copy link", icon: "link", onSelect: () => copy(new URL(href, window.location.href).href, "Link copied") },
  ]);
}

function RunningRunRow({
  r,
  onSelectRun,
}: {
  r: Run;
  onSelectRun: (runId: string) => void;
}) {
  const btnRef = useRef<HTMLButtonElement>(null);
  useRunRowContextMenu(btnRef, r, onSelectRun);
  const dot = runDot(r);
  const totalSteps = r.plan.length;
  const doneSteps = r.plan.filter((s) => s.state === "done").length;
  const currentStep = r.plan.find((s) => s.state === "current");
  const pct = totalSteps > 0 ? Math.round((doneSteps / totalSteps) * 100) : 0;

  return (
    <button
      ref={btnRef}
      type="button"
      onClick={() => onSelectRun(r.id)}
      className="flex flex-col gap-1.5 rounded-xl border border-border bg-surface px-3.5 py-2.5 text-left transition-colors hover:border-border-hover hover:bg-hover/40"
    >
      <div className="flex items-center justify-between gap-2">
        <div className="flex min-w-0 items-center gap-2">
          <WorkPersonaAvatar agent={r.agent} size="sm" state={runCharacterState(r)} />
          <span aria-hidden className={cx("size-2 flex-none rounded-full", DOT_BG[dot])} />
          {r.ticket_key && (
            <span className="flex-none font-mono text-11 text-fg-tertiary">{r.ticket_key}</span>
          )}
          <span className="truncate text-13 font-medium text-fg">{runTitle(r)}</span>
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
        {currentStep && (
          <span className="truncate text-state-done">
            Step {currentStep.position}/{totalSteps} · {currentStep.text}
          </span>
        )}
      </div>
      {totalSteps > 0 && (
        <div className="h-1 w-full overflow-hidden rounded-full bg-surface-sunken">
          <div className="h-full rounded-full bg-state-done" style={{ width: `${Math.max(8, pct)}%` }} />
        </div>
      )}
    </button>
  );
}

function FinishedRunRow({
  r,
  onSelectRun,
}: {
  r: Run;
  onSelectRun: (runId: string) => void;
}) {
  const btnRef = useRef<HTMLButtonElement>(null);
  useRunRowContextMenu(btnRef, r, onSelectRun);
  const dot = runDot(r);

  return (
    <button
      ref={btnRef}
      type="button"
      onClick={() => onSelectRun(r.id)}
      className="flex w-full items-center gap-2.5 px-3.5 py-2 text-left text-12 transition-colors hover:bg-hover/50"
    >
      <span title={DOT_LABEL[dot]} aria-hidden className={cx("size-2 flex-none rounded-full", DOT_BG[dot])} />
      {r.ticket_key && (
        <span className="w-16 flex-none truncate font-mono text-11 text-fg-tertiary">{r.ticket_key}</span>
      )}
      <span className="min-w-0 flex-1 truncate font-medium text-fg">{runTitle(r)}</span>
      <span className="hidden flex-none items-center gap-1.5 text-11 text-fg-tertiary sm:inline-flex">
        <WorkPersonaAvatar agent={r.agent} size="sm" />
        <span>{r.agent.name}</span>
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
}

/**
 * Calm single-column overview shown on `/work` when no run is selected:
 * one hairline telemetry strip, items needing your decision, any active runs,
 * and ready tasks you can dispatch next.
 */
export function ActivityOverview({
  project,
  runs,
  needs,
  filter,
  onSelectRun,
}: {
  project?: string;
  runs: readonly Run[];
  needs: readonly InboxItem[];
  filter: ActivityFilter;
  onSelectRun: (runId: string) => void;
}) {
  const [now] = useState(() => new Date());
  const [range7d] = useState(() => presetRange(7, now));
  const [dispatchOpen, setDispatchOpen] = useState(false);
  const runner = useRunnerStatus().data;
  const costs7d = useCosts({ ...range7d, project }).data;
  const tickets = useTickets({ project, view: "all" });

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
        .slice(0, 6),
    [uniqueRuns, now],
  );

  const activeTicketKeys = useMemo(
    () => new Set(runningNow.map((r) => r.ticket_key).filter(Boolean)),
    [runningNow],
  );

  const readyTickets = useMemo(
    () =>
      (tickets.data ?? [])
        .filter((t) => t.status === "todo" && t.unmet_dependencies === 0 && !activeTicketKeys.has(t.key))
        .slice(0, 6),
    [tickets.data, activeTicketKeys],
  );
  const assignedReadyKeys = useMemo(
    () =>
      (tickets.data ?? [])
        .filter(
          (t) =>
            t.status === "todo" &&
            t.unmet_dependencies === 0 &&
            !activeTicketKeys.has(t.key) &&
            !!t.assignee,
        )
        .map((t) => t.key),
    [tickets.data, activeTicketKeys],
  );

  const reportsHref = `/reports?tab=costs&range=7${project ? `&project=${encodeURIComponent(project)}` : ""}`;
  const tasksHref = `/tickets${project ? `?project=${encodeURIComponent(project)}` : ""}`;

  return (
    <section
      aria-label="Activity overview"
      className="mx-auto flex w-full max-w-[780px] flex-1 flex-col gap-6 px-6 py-7 max-sm:px-4"
    >
      {/* Single hairline telemetry strip */}
      <div
        role="region"
        aria-label="Activity telemetry"
        className="grid grid-cols-4 divide-x divide-border-subtle overflow-hidden rounded-xl border border-border bg-surface max-sm:grid-cols-2 max-sm:divide-y"
      >
        <div className="flex flex-col gap-0.5 px-3.5 py-2.5">
          <div className="flex items-center justify-between text-11 text-fg-tertiary">
            <span>Runner</span>
            <span
              className={cx(
                "font-mono text-10",
                stats.online ? "text-state-done" : stats.starting ? "text-fg-tertiary" : "text-pill-blocked-fg",
              )}
            >
              {stats.online ? "online" : stats.starting ? "starting" : "offline"}
            </span>
          </div>
          <div className="font-mono text-16 font-semibold leading-tight text-fg tabular-nums">
            {stats.slotsBusy}
            <span className="text-12 font-normal text-fg-tertiary"> / {stats.slotsMax}</span>
          </div>
          <div className="text-11 text-fg-tertiary">{stats.queued} queued</div>
        </div>

        <div className="flex flex-col gap-0.5 px-3.5 py-2.5">
          <div className="flex items-center justify-between text-11 text-fg-tertiary">
            <span>Needs you</span>
            {stats.needsYouCount > 0 && <span className="size-1.5 rounded-full bg-state-human" />}
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

        <div className="flex flex-col gap-0.5 px-3.5 py-2.5">
          <div className="text-11 text-fg-tertiary">Today</div>
          <div className="flex items-baseline gap-1.5">
            <span className="font-mono text-16 font-semibold leading-tight text-fg tabular-nums">
              {stats.completedToday}
            </span>
            <span className="text-11 text-fg-tertiary">done</span>
          </div>
          <div className="truncate text-11 text-fg-tertiary">
            {stats.prsToday} PR{stats.prsToday === 1 ? "" : "s"}
            {stats.passRatePct != null ? ` · ${stats.passRatePct}% pass` : ""}
          </div>
        </div>

        <div className="flex flex-col gap-0.5 px-3.5 py-2.5">
          <div className="flex items-center justify-between text-11 text-fg-tertiary">
            <span>7d spend</span>
            <Link href={reportsHref} className="text-accent hover:underline">
              Reports →
            </Link>
          </div>
          <div className="font-mono text-16 font-semibold leading-tight text-fg tabular-nums">
            {costs7d ? spendLabel(costs7d.total.cost_micros, costs7d.unpriced_runs) : "–"}
          </div>
          <div className="truncate text-11 text-fg-tertiary">
            {costs7d ? (
              `${costs7d.total.runs} run${costs7d.total.runs === 1 ? "" : "s"}`
            ) : (
              <Skeleton className="h-3 w-16" />
            )}
          </div>
        </div>
      </div>

      {/* Needs you */}
      {filter !== "failed" && (
        <div id="needs-you" className="flex flex-col gap-2">
          <SectionHeading count={needs.length} tone={needs.length > 0 ? "human" : undefined}>
            Needs you
          </SectionHeading>
          {needs.length === 0 ? (
            <div className="flex items-center gap-2 rounded-xl border border-border bg-surface px-3.5 py-3 text-13 text-fg-tertiary">
              <Icon name="check" size={14} className="text-state-done" />
              All caught up — no approvals or questions waiting on you.
            </div>
          ) : (
            <div className="flex flex-col gap-2">
              {needs.map((item) => (
                <NeedsYouCard key={item.id} item={item} onSelectRun={onSelectRun} />
              ))}
            </div>
          )}
        </div>
      )}

      {/* Running now */}
      {filter !== "failed" && runningNow.length > 0 && (
        <div className="flex flex-col gap-2">
          <SectionHeading count={runningNow.length}>Running now</SectionHeading>
          <div className="flex flex-col gap-2">
            {runningNow.map((r) => (
              <RunningRunRow key={r.id} r={r} onSelectRun={onSelectRun} />
            ))}
          </div>
        </div>
      )}

      {/* Ready to start */}
      {filter !== "failed" && (
        <div className="flex flex-col gap-2">
          <SectionHeading
            count={readyTickets.length}
            right={
              <div className="flex items-center gap-2">
                {assignedReadyKeys.length > 0 && (
                  <Button
                    variant="approve-outline"
                    icon="play"
                    onClick={() => setDispatchOpen(true)}
                    className="h-7 px-2.5 text-12"
                  >
                    Start ready ({assignedReadyKeys.length})
                  </Button>
                )}
                <Link href={tasksHref} className="text-12 text-accent hover:underline">
                  All tasks →
                </Link>
              </div>
            }
          >
            Ready to start
          </SectionHeading>
          {tickets.isPending ? (
            <Skeleton className="h-16 rounded-xl" />
          ) : readyTickets.length === 0 ? (
            <div className="flex items-center justify-between gap-3 rounded-xl border border-border bg-surface px-3.5 py-3 text-13 text-fg-tertiary">
              <span>No unblocked tasks queued for dispatch.</span>
              <Link href={tasksHref} className="flex-none text-12 font-medium text-accent hover:underline">
                Open Tasks →
              </Link>
            </div>
          ) : (
            <div className="divide-y divide-border-subtle overflow-hidden rounded-xl border border-border bg-surface">
              {readyTickets.map((t) => (
                <Link
                  key={t.id}
                  href={`/tickets/${encodeURIComponent(t.key)}`}
                  className="flex items-center gap-3 px-3.5 py-2.5 text-13 transition-colors hover:bg-hover/50"
                >
                  <span className="w-16 flex-none truncate font-mono text-11 text-fg-tertiary">
                    {t.key}
                  </span>
                  <span className="min-w-0 flex-1 truncate font-medium text-fg">
                    {t.title}
                  </span>
                  {t.estimate_points != null && (
                    <span className="flex-none font-mono text-11 text-fg-tertiary">
                      {t.estimate_points} pt
                    </span>
                  )}
                  <span className="flex flex-none items-center gap-1.5 text-12 text-fg-secondary">
                    {t.assignee ? (
                      <>
                        <WorkPersonaAvatar agent={t.assignee} size="sm" />
                        <span className="hidden sm:inline">{t.assignee.name}</span>
                      </>
                    ) : (
                      <UnassignedAvatar size={18} />
                    )}
                  </span>
                </Link>
              ))}
            </div>
          )}
        </div>
      )}

      {/* Finished today */}
      {finishedToday.length > 0 && (
        <div className="flex flex-col gap-2">
          <SectionHeading count={finishedToday.length}>Finished today</SectionHeading>
          <div className="divide-y divide-border-subtle overflow-hidden rounded-xl border border-border bg-surface">
            {finishedToday.map((r) => (
              <FinishedRunRow key={r.id} r={r} onSelectRun={onSelectRun} />
            ))}
          </div>
        </div>
      )}

      {dispatchOpen && assignedReadyKeys.length > 0 && (
        <DispatchDialog
          keys={assignedReadyKeys}
          open
          onOpenChange={setDispatchOpen}
        />
      )}
    </section>
  );
}
