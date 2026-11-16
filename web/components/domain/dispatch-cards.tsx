"use client";

import Link from "next/link";
import { Dialog, Popover } from "radix-ui";
import { useQueries } from "@tanstack/react-query";
import { useContext, useEffect, useMemo, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { api, unwrap, type Schemas } from "@/lib/api/client";
import { keys as queryKeys, useChatTicketRuns, useControlRunById, useDecideApproval, useDispatchPreview, useStartChatTicketRun, useTicket } from "@/lib/api/hooks";
import { parseDispatchKeys, planLine, runEnded } from "@/lib/chat-dispatch";
import { chatStatusOf, type ChatStatusKind } from "@/lib/chat-ui";
import { minutesLabel } from "@/lib/chat-research";
import { cx } from "@/lib/cx";
import { repoShortName } from "@/lib/persona-ui";
import { Button, IconButton, buttonClass } from "@/components/ui/button";
import { usePulse } from "@/components/ui/motion";
import { AgentAvatar } from "./avatars";
import { CodeFence } from "./code-fence";
import { StartsLine } from "./dispatch-dialog";
import { RecommendActions } from "./recommend-fence";
import { RUN_STATE, WAIT_LABEL } from "./run-status";
import { SmallPill } from "./labels";
import { OpenInDevWorkspaceButton } from "./open-in-dev-button";
import { SvgFenceMessage } from "./svg-fence";
import { Spinner } from "@/components/ui/loading";

type TicketRun = Schemas["ChatTicketRun"];

/** Draws a chat activity scene; the chat passes its own (activity-scene.tsx). */
export type SceneRenderer = (kind: ChatStatusKind) => ReactNode;

const CARD = "flex w-full max-w-[680px] flex-col gap-3 rounded-xl border border-border bg-surface p-3.5";
const TERM = "text-13 text-fg-tertiary";

/** The run's state, bumping when it changes so a glance at the tray catches it. */
function RunPill({ run }: { run: Pick<TicketRun, "state" | "wait_reason"> }) {
  const ref = usePulse<HTMLSpanElement>(run.state);
  const s = RUN_STATE[run.state] ?? { tone: "neutral" as const, label: run.state };
  const wait = run.state === "waiting" && run.wait_reason ? WAIT_LABEL[run.wait_reason] ?? run.wait_reason : "";
  return (
    <span ref={ref} className="inline-flex flex-none">
      <SmallPill tone={s.tone}>{s.label}{wait && ` · ${wait}`}</SmallPill>
    </span>
  );
}

/** Minutes since the run started (or how long it took), refreshed while it's live. */
function useElapsed(run: TicketRun) {
  const ended = runEnded(run.state);
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    if (ended) return;
    const t = setInterval(() => setNow(Date.now()), 15000);
    return () => clearInterval(t);
  }, [ended]);
  return minutesLabel((run.ended_at ? Date.parse(run.ended_at) : now) - Date.parse(run.started_at));
}

/** An approval the run waits on, decided right here: the same decision as on the ticket. */
function ApprovalPanel({ run, approval }: { run: TicketRun; approval: NonNullable<TicketRun["approval"]> }) {
  const decide = useDecideApproval(run.ticket);
  return (
    <div data-testid="ticket-run-approval" className="flex flex-col gap-2 rounded-lg border border-state-human bg-surface-sunken p-2.5">
      <div className="flex items-baseline justify-between gap-2">
        <p className="text-13 font-semibold text-fg">{approval.action}</p>
        <span className="flex-none font-mono text-12 text-fg-tertiary">{approval.scope}</span>
      </div>
      {approval.risk && <p className="text-13 text-fg-secondary">Risk: {approval.risk}</p>}
      {approval.detail && approval.detail !== "{}" && (
        <details className="text-12">
          <summary className="cursor-pointer text-fg-tertiary">Details</summary>
          <pre className="mt-1 max-h-40 overflow-auto whitespace-pre-wrap break-all font-mono text-12 text-fg-secondary">{approval.detail}</pre>
        </details>
      )}
      {decide.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{decide.error.message}</p>}
      <div className="flex items-center gap-2">
        <Button variant="approve" disabled={decide.isPending} onClick={() => decide.mutate({ id: approval.id, decision: "approve" })}>Approve</Button>
        <Button variant="outline" disabled={decide.isPending} onClick={() => decide.mutate({ id: approval.id, decision: "deny" })}>Deny</Button>
      </div>
    </div>
  );
}

/** How long the hand-off plays over a run's card once it starts. */
const HANDOFF_MS = 2800;

/**
 * The persona passing the ticket to the agent that took it: the ticket's key travels from
 * one to the other. It covers the card rather than pushing it down, and announces the
 * hand-off once. Clicks pass through to the card. With reduced motion the chip simply sits by the agent.
 */
function HandOff({ run, from }: { run: TicketRun; from?: ReactNode }) {
  return (
    <div data-testid="ticket-run-handoff" role="status" className="handoff pointer-events-none absolute inset-0 z-10 flex items-center gap-3 rounded-xl bg-surface px-3.5">
      <span className="flex-none">{from ?? <span aria-hidden className="block size-[26px] rounded-full bg-accent-soft ring-1 ring-accent" />}</span>
      <span aria-hidden className="relative h-6 w-36 flex-none max-sm:w-20">
        <span className="absolute inset-x-0 top-1/2 h-px -translate-y-1/2 bg-gradient-to-r from-accent/10 via-accent to-accent/10" />
        <span className="handoff-chip absolute top-1/2 whitespace-nowrap rounded-md border border-accent bg-accent-soft px-1.5 py-px font-mono text-11 text-accent shadow-sm">
          {run.ticket}
        </span>
      </span>
      <span className="handoff-agent flex-none">
        <AgentAvatar name={run.agent} colorIndex={0} label={false} />
      </span>
      <p className="min-w-0 truncate text-13 text-fg-secondary">
        Handing <span className="font-medium text-fg">{run.ticket}</span> to <span className="font-medium text-fg">@{run.agent}</span>
      </p>
    </div>
  );
}

/** How long the grouped hand-off takes to fade once its last run has landed. */
const HANDOFF_LEAVE_MS = 300;
/** Lanes in the grouped hand-off before the rest fold into "+N more". */
const HANDOFF_MAX_LANES = 5;
const HANDOFF_LANE_PX = 30;
const HANDOFF_TRACK_PX = 160;
const HANDOFF_LANE_STAGGER_MS = 60;

/** The persona → agent curve for lane i of n, in the track's own pixels. */
function laneCurve(i: number, n: number) {
  const from = (n * HANDOFF_LANE_PX) / 2;
  const to = i * HANDOFF_LANE_PX + HANDOFF_LANE_PX / 2;
  const mid = HANDOFF_TRACK_PX / 2;
  return `M0,${from} C${mid},${from} ${mid},${to} ${HANDOFF_TRACK_PX},${to}`;
}

/** The tray must be at least this tall while the grouped hand-off covers it. */
function groupHandOffHeight(runs: number) {
  return Math.min(runs, HANDOFF_MAX_LANES) * HANDOFF_LANE_PX + 64;
}

/**
 * Several runs starting together (Start all): the persona fans the tickets out to their
 * agents in one overlay over the tray, one lane per ticket, instead of a hand-off on every
 * card. Past HANDOFF_MAX_LANES the last lane stands for the rest. Clicks pass through.
 * With reduced motion it shows landed, without the travelling packets.
 */
function GroupHandOff({ runs, from, leaving }: { runs: TicketRun[]; from?: ReactNode; leaving: boolean }) {
  const folded = runs.length > HANDOFF_MAX_LANES ? runs.length - (HANDOFF_MAX_LANES - 1) : 0;
  const shown = folded ? runs.slice(0, HANDOFF_MAX_LANES - 1) : runs;
  const lanes = shown.length + (folded ? 1 : 0);
  const height = lanes * HANDOFF_LANE_PX;
  const agents = new Set(runs.map((r) => r.agent)).size;
  const delay = (i: number) => ({ "--lane-delay": `${i * HANDOFF_LANE_STAGGER_MS}ms` }) as CSSProperties;
  return (
    <div
      data-testid="ticket-run-handoff-group"
      role="status"
      data-leaving={leaving || undefined}
      className="handoff-group pointer-events-none absolute left-0 top-0 z-20 flex w-full max-w-[680px] flex-col gap-2 rounded-xl border border-border bg-surface p-3.5 shadow-sm"
    >
      <div className="flex items-center gap-3">
        <span className="flex-none">{from ?? <span aria-hidden className="block size-[26px] rounded-full bg-accent-soft ring-1 ring-accent" />}</span>
        <span aria-hidden className="relative flex-none text-accent max-sm:hidden" style={{ width: HANDOFF_TRACK_PX, height }}>
          <svg className="absolute inset-0 overflow-visible" width={HANDOFF_TRACK_PX} height={height} viewBox={`0 0 ${HANDOFF_TRACK_PX} ${height}`}>
            {Array.from({ length: lanes }, (_, i) => {
              const more = folded > 0 && i === lanes - 1;
              return (
                <path
                  key={i}
                  d={laneCurve(i, lanes)}
                  pathLength={1}
                  fill="none"
                  stroke="currentColor"
                  strokeOpacity={0.6}
                  strokeWidth={1.5}
                  strokeDasharray={more ? "0.03 0.03" : undefined}
                  className={more ? "handoff-lane-more" : "handoff-lane"}
                  style={delay(i)}
                />
              );
            })}
          </svg>
          {shown.map((r, i) => (
            <span key={r.run_id} className="handoff-packet absolute left-0 top-0 size-2 rounded-full bg-accent shadow-sm" style={{ ...delay(i), offsetPath: `path("${laneCurve(i, lanes)}")` }} />
          ))}
        </span>
        <ul className="flex min-w-0 flex-1 flex-col">
          {shown.map((r, i) => (
            <li key={r.run_id} data-testid="handoff-lane" className="flex min-w-0 items-center gap-2" style={{ ...delay(i), height: HANDOFF_LANE_PX }}>
              <span className="handoff-land flex-none"><AgentAvatar name={r.agent} colorIndex={0} label={false} /></span>
              <span className="truncate text-13 text-fg">@{r.agent}</span>
              <span className="handoff-key flex-none rounded-md border border-accent bg-accent-soft px-1.5 py-px font-mono text-11 text-accent">{r.ticket}</span>
            </li>
          ))}
          {folded > 0 && (
            <li className="flex min-w-0 items-center gap-2" style={{ height: HANDOFF_LANE_PX }}>
              <span className="flex-none rounded-full border border-accent bg-accent-soft px-2 text-11 text-accent">+{folded}</span>
              <span className="truncate text-13 text-fg-secondary">{folded} more tickets</span>
            </li>
          )}
        </ul>
      </div>
      <p className="truncate text-13 text-fg-secondary">
        Handing <span className="font-medium text-fg">{runs.length} tickets</span> to{" "}
        <span className="font-medium text-fg">{agents === 1 ? `@${runs[0].agent}` : `${agents} agents`}</span>
      </p>
    </div>
  );
}

/** The runs a hand-off is showing for, and whether it's on its way out. */
type HandOffBatch = { ids: string[]; leaving: boolean };

/**
 * Runs that start while the tray is open get a hand-off for HANDOFF_MS. A run that starts
 * while one is still showing joins it and keeps it up, since Start all starts its tickets
 * one after another and each lands in its own tray refresh. Runs already live when the
 * chat opened (a reload, coming back later) don't replay it.
 */
function useHandOffBatch(ids: string[] | undefined): HandOffBatch {
  const seen = useRef<Set<string>>(null);
  const pending = useRef<string[]>([]);
  const timers = useRef<ReturnType<typeof setTimeout>[]>([]);
  const [batch, setBatch] = useState<HandOffBatch>({ ids: [], leaving: false });
  const key = ids?.join(",");
  useEffect(() => {
    if (key === undefined) return;
    const now = key ? key.split(",") : [];
    if (!seen.current) {
      seen.current = new Set(now);
      return;
    }
    const known = seen.current;
    const added = now.filter((id) => !known.has(id));
    if (added.length === 0) return;
    for (const id of added) known.add(id);
    // Queued rather than captured, so restarting the timers can't drop a run not yet shown.
    pending.current.push(...added);
    timers.current.forEach(clearTimeout);
    timers.current = [
      setTimeout(() => {
        const joining = pending.current;
        pending.current = [];
        setBatch((b) => ({ ids: b.leaving ? joining : [...b.ids, ...joining], leaving: false }));
      }, 0),
      setTimeout(() => setBatch((b) => ({ ...b, leaving: true })), HANDOFF_MS - HANDOFF_LEAVE_MS),
      setTimeout(() => setBatch({ ids: [], leaving: false }), HANDOFF_MS),
    ];
  }, [key]);
  useEffect(() => () => timers.current.forEach(clearTimeout), []);
  return batch;
}

/** One ticket run a chat started: live in the tray, or as its card's summary once it ends. */
export function TicketRunCard({ run, scene, onReview, handoff }: { run: TicketRun; scene?: SceneRenderer; onReview?: () => void; handoff?: { from?: ReactNode } }) {
  const control = useControlRunById(run.run_id);
  const [devError, setDevError] = useState<string | null>(null);
  const elapsed = useElapsed(run);
  const live = !runEnded(run.state);
  const step = planLine(run);
  const waiting = run.state === "waiting" || run.state === "paused";
  const pct = run.steps_total > 0 ? Math.round((run.steps_done / run.steps_total) * 100) : 0;
  // What it's doing, in the chat's words ("Running tests"), never the command itself.
  const doing = run.state === "running" && run.activity ? chatStatusOf({ tool: run.activity.tool, input: run.activity.command ? { command: run.activity.command } : {} }) : undefined;
  const replyWanted = run.state === "waiting" && run.wait_reason === "human_reply";
  return (
    <div data-testid="ticket-run" className={cx(CARD, "relative gap-2.5 transition-colors", waiting ? "border-state-human" : run.state === "failed" || run.state === "blocked" ? "border-state-blocked" : "")}>
      {handoff && <HandOff run={run} from={handoff.from} />}
      <div className="flex min-w-0 items-center gap-3">
        {live && scene && doing && <div className="flex-none max-sm:hidden">{scene(doing.kind)}</div>}
        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <div className="flex min-w-0 items-center gap-2">
            <Link href={`/tickets/${run.ticket}`} className="flex-none font-mono text-12 text-fg-tertiary hover:underline">{run.ticket}</Link>
            <span className="min-w-0 flex-1 truncate text-14 font-medium text-fg">{run.ticket_title}</span>
            <RunPill run={run} />
          </div>
          {doing && <p data-testid="ticket-run-doing" className="truncate text-13 text-fg">{doing.phrase.charAt(0).toUpperCase() + doing.phrase.slice(1)}</p>}
          {replyWanted && <p className="text-13 text-fg">@{run.agent} asked you something. Answer in this chat and it&apos;s passed on.</p>}
        </div>
      </div>
      {live && run.approval && <ApprovalPanel run={run} approval={run.approval} />}
      {live && (
        <div className="h-1.5 overflow-hidden rounded-full bg-surface-sunken">
          <div className={cx("h-full rounded-full transition-[width,background-color] duration-(--motion-progress)", waiting ? "bg-state-human" : "live-sheen bg-accent")} style={{ width: `${Math.max(pct, 4)}%` }} />
        </div>
      )}
      <p className="truncate text-12 text-fg-tertiary">
        @{run.agent} · {elapsed} · ${run.cost_usd.toFixed(2)}{step && ` · ${step}`}
      </p>
      {control.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{control.error.message}</p>}
      {devError && <p role="alert" className="text-12 text-pill-blocked-fg">{devError}</p>}
      <div className="flex flex-wrap items-center gap-2">
        {run.pr_url && <a href={run.pr_url} target="_blank" rel="noreferrer" className={buttonClass(live ? "outline" : "primary")}>Open PR</a>}
        <OpenInDevWorkspaceButton
          repository={run.repository}
          branch={run.branch}
          prUrl={run.pr_url}
          prState={run.pr_state}
          onError={setDevError}
        />
        {!live && run.pr_url && onReview && <Button variant="outline" onClick={onReview}>Review it with me</Button>}
        <Link href={`/runs/${run.run_id}`} className={buttonClass("outline")}>Open run</Link>
        {live && <Button variant="ghost" disabled={control.isPending} onClick={() => control.mutate("cancel")}>Stop</Button>}
        {live && <span className="text-12 text-fg-tertiary">Safe to leave this chat.</span>}
      </div>
    </div>
  );
}

const DOT: Record<string, string> = { done: "bg-state-done", human: "bg-state-human", blocked: "bg-state-blocked", review: "bg-state-done" };

/** A run's state as a dot, the colour of its pill; the words live in the flyout. */
function RunDot({ run }: { run: TicketRun }) {
  const s = RUN_STATE[run.state] ?? { tone: "neutral" as const, label: run.state };
  const live = !runEnded(run.state);
  return (
    <span
      role="img"
      aria-label={s.label}
      title={s.label}
      className={cx("size-2 flex-none rounded-full", DOT[s.tone] ?? "bg-fg-tertiary", live && s.tone === "done" && "animate-pulse motion-reduce:animate-none")}
    />
  );
}

/**
 * Several live runs from this chat as one graphic (the hand-off's fan-out, kept on screen)
 * instead of a card each. "Details" flies out every run's own card, so progress, approvals,
 * Stop and Open PR stay one click away; a run that needs the person is flagged on the button.
 */
function RunGroupCard({ runs, from, scene }: { runs: TicketRun[]; from?: ReactNode; scene?: SceneRenderer }) {
  const folded = runs.length > HANDOFF_MAX_LANES ? runs.length - (HANDOFF_MAX_LANES - 1) : 0;
  const shown = folded ? runs.slice(0, HANDOFF_MAX_LANES - 1) : runs;
  const lanes = shown.length + (folded ? 1 : 0);
  const height = lanes * HANDOFF_LANE_PX;
  const agents = new Set(runs.map((r) => r.agent)).size;
  const needsYou = runs.filter((r) => r.approval || r.state === "waiting" || r.state === "paused").length;
  return (
    <div data-testid="ticket-run-group" className={cx(CARD, "gap-2", needsYou > 0 && "border-state-human")}>
      <div className="flex items-center gap-3">
        <span className="flex-none">{from ?? <span aria-hidden className="block size-[26px] rounded-full bg-accent-soft ring-1 ring-accent" />}</span>
        <span aria-hidden className="relative flex-none text-accent max-sm:hidden" style={{ width: HANDOFF_TRACK_PX, height }}>
          <svg className="absolute inset-0 overflow-visible" width={HANDOFF_TRACK_PX} height={height} viewBox={`0 0 ${HANDOFF_TRACK_PX} ${height}`}>
            {Array.from({ length: lanes }, (_, i) => (
              <path key={i} d={laneCurve(i, lanes)} fill="none" stroke="currentColor" strokeOpacity={0.6} strokeWidth={1.5} strokeDasharray={folded > 0 && i === lanes - 1 ? "2 2" : undefined} />
            ))}
          </svg>
        </span>
        <ul className="flex min-w-0 flex-1 flex-col">
          {shown.map((r) => (
            <li key={r.run_id} data-testid="group-lane" className="flex min-w-0 items-center gap-2" style={{ height: HANDOFF_LANE_PX }}>
              <AgentAvatar name={r.agent} colorIndex={0} label={false} />
              <span className="truncate text-13 text-fg">@{r.agent}</span>
              <span className="flex-none rounded-md border border-accent bg-accent-soft px-1.5 py-px font-mono text-11 text-accent">{r.ticket}</span>
              <RunDot run={r} />
            </li>
          ))}
          {folded > 0 && (
            <li className="flex min-w-0 items-center gap-2" style={{ height: HANDOFF_LANE_PX }}>
              <span className="flex-none rounded-full border border-accent bg-accent-soft px-2 text-11 text-accent">+{folded}</span>
              <span className="truncate text-13 text-fg-secondary">{folded} more tickets</span>
            </li>
          )}
        </ul>
      </div>
      <div className="flex items-center justify-between gap-3">
        <p className="min-w-0 truncate text-12 text-fg-tertiary">
          {runs.length} tickets · {agents === 1 ? `@${runs[0].agent}` : `${agents} agents`}
        </p>
        <Popover.Root>
          <Popover.Trigger asChild>
            <button
              type="button"
              data-testid="ticket-run-group-details"
              className={cx(buttonClass("outline"), "flex-none gap-1.5")}
            >
              Ticket status
              {needsYou > 0 && <span className="rounded-full bg-pill-human-bg px-1.5 text-11 text-pill-human-fg">{needsYou} need you</span>}
            </button>
          </Popover.Trigger>
          <Popover.Portal>
            <Popover.Content
              data-testid="ticket-run-flyout"
              align="end"
              side="top"
              sideOffset={8}
              collisionPadding={12}
              aria-label="Ticket status"
              className="z-50 flex max-h-[min(70vh,560px)] w-[min(460px,calc(100vw-24px))] flex-col gap-2 overflow-y-auto rounded-xl border border-border-strong bg-surface-raised p-2.5 shadow-float"
            >
              {runs.map((r) => <TicketRunCard key={r.run_id} run={r} scene={scene} />)}
            </Popover.Content>
          </Popover.Portal>
        </Popover.Root>
      </div>
    </div>
  );
}

/** Ticket runs still going in this chat, above the composer so they never scroll away. */
export function ChatTicketRunTray({ chatId, scene, persona }: { chatId: string; scene?: SceneRenderer; persona?: ReactNode }) {
  const runs = useChatTicketRuns(chatId);
  const live = (runs.data?.runs ?? []).filter((r) => !runEnded(r.state));
  const handoff = useHandOffBatch(runs.data ? live.map((r) => r.run_id) : undefined);
  if (live.length === 0) return null;
  // In start order, leaving out any that already ended.
  const handed = handoff.ids.flatMap((id) => live.filter((r) => r.run_id === id));
  const handingGroup = handed.length > 1;
  // One run keeps its own card; two or more share the graphic.
  const grouped = live.length > 1;
  return (
    <div data-testid="ticket-run-tray" className="relative flex flex-col gap-2" style={handingGroup ? { minHeight: groupHandOffHeight(handed.length) } : undefined}>
      {handingGroup && <GroupHandOff runs={handed} from={persona} leaving={handoff.leaving} />}
      {grouped ? (
        <RunGroupCard runs={live} from={persona} scene={scene} />
      ) : (
        live.map((r) => <TicketRunCard key={r.run_id} run={r} scene={scene} handoff={handed.includes(r) ? { from: persona } : undefined} />)
      )}
    </div>
  );
}

/** The chat header's run status: how many of this chat's ticket runs are going, opening the run (or all runs). */
export function ChatRunsPill({ chatId }: { chatId: string }) {
  const runs = useChatTicketRuns(chatId);
  const live = (runs.data?.runs ?? []).filter((r) => !runEnded(r.state));
  if (live.length === 0) return null;
  const label = `${live.length} ${live.length === 1 ? "run" : "runs"} active`;
  return (
    <Link
      href={live.length === 1 ? `/runs/${live[0].run_id}` : "/runs"}
      data-testid="chat-runs-pill"
      className="flex h-6 flex-none items-center gap-1.5 rounded-full bg-pill-done-bg px-2.5 text-12 font-medium text-pill-done-fg hover:brightness-110"
    >
      <span aria-hidden className="size-1.5 animate-pulse rounded-full bg-state-done motion-reduce:animate-none" />
      {label}
    </Link>
  );
}

/** The Start card: what a run of this ticket would get, and nothing starts until Start. */
function StartCard({ ticketKey, chatId, messageId, onDismiss }: { ticketKey: string; chatId: string; messageId?: string; onDismiss: () => void }) {
  const preview = useDispatchPreview(ticketKey);
  const ticket = useTicket(ticketKey);
  const start = useStartChatTicketRun(chatId);
  if (preview.isPending) return <div aria-label={`Loading ${ticketKey}`} className={cx(CARD, "h-44 animate-pulse")} />;
  if (preview.isError) {
    return (
      <div data-testid="dispatch-card" className={CARD}>
        <h4 className="text-14 font-semibold text-fg">Start a run for {ticketKey}?</h4>
        <p role="alert" className="text-13 text-fg-secondary">{preview.error.message || `Couldn’t load ${ticketKey}.`}</p>
        <div><Link href={`/tickets/${ticketKey}`} className={buttonClass("outline")}>Open ticket</Link></div>
      </div>
    );
  }
  const p = preview.data;
  const refused = p.blockers.length > 0;
  return (
    <div data-testid="dispatch-card" className={CARD}>
      <div className="flex items-baseline justify-between gap-3">
        <h4 className="text-14 font-semibold text-fg">Start a run for {ticketKey}?</h4>
        <span className="flex-none font-mono text-12 text-fg-tertiary">{p.resolved.harness} · {p.resolved.model}</span>
      </div>
      {ticket.data && <p className="truncate text-13 text-fg">{ticket.data.title}</p>}
      <dl className="grid grid-cols-[92px_1fr] items-center gap-x-3 gap-y-1.5 text-13">
        <dt className={TERM}>Persona</dt>
        <dd className="flex items-center gap-1.5"><AgentAvatar name={p.agent.name} colorIndex={p.agent.color_index} label={false} />@{p.agent.handle}</dd>
        {p.repo_url && (
          <>
            <dt className={TERM}>Repository</dt>
            <dd className="font-mono text-12">{repoShortName(p.repo_url)}{p.base_branch && ` · ${p.base_branch}`}</dd>
          </>
        )}
        <dt className={TERM}>Starts</dt>
        <dd className="min-w-0"><StartsLine p={p} /></dd>
        {p.queued_behind.length > 0 && (
          <>
            <dt className={TERM}>Waits for</dt>
            <dd>{p.queued_behind.join(", ")}</dd>
          </>
        )}
        <dt className={TERM}>Progress</dt>
        <dd className="text-fg-secondary">Above the message box</dd>
      </dl>
      {refused && <p role="alert" className="text-12 text-pill-blocked-fg">{p.blockers.join(" ")}</p>}
      {start.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{start.error.message || "Couldn’t start the run."}</p>}
      <div className="flex flex-wrap items-center gap-2">
        <Button variant="primary" disabled={refused || start.isPending || !messageId} onClick={() => start.mutate({ ticket: ticketKey, message_id: messageId })}>
          {start.isPending ? "Starting…" : "Start run"}
        </Button>
        <Link href={`/tickets/${ticketKey}`} className={buttonClass("outline")}>Open ticket</Link>
        <Button variant="ghost" onClick={onDismiss}>Not now</Button>
      </div>
    </div>
  );
}

/** ```dispatch: a persona's offer to start one ticket's run, or several. Once started it points at the run. */
export function DispatchFence({ code, info }: { code: string; info?: string }) {
  const ticketKeys = useMemo(() => parseDispatchKeys(code), [code]);
  const messageId = useContext(SvgFenceMessage);
  const actions = useContext(RecommendActions);
  const chatId = actions?.chatId;
  const runs = useChatTicketRuns(ticketKeys.length ? chatId : undefined);
  const [dismissed, setDismissed] = useState(false);
  // Outside a chat (a saved page) or while it's still streaming, it's just text.
  if (!ticketKeys.length || !chatId) return <CodeFence code={code} info={info} />;
  if (runs.isPending) return <div aria-label={`Loading ${ticketKeys.join(", ")}`} className={cx(CARD, "h-44 animate-pulse")} />;
  // A reply starts at most one run per ticket it offers.
  const fromCard = (runs.data?.runs ?? []).filter((r) => r.message_id === messageId && ticketKeys.includes(r.ticket));
  if (dismissed) return <p data-testid="dispatch-dismissed" className="text-12 text-fg-tertiary">Not started.</p>;
  if (ticketKeys.length > 1) {
    return <MultiStartCard ticketKeys={ticketKeys} chatId={chatId} messageId={messageId} started={fromCard} onDismiss={() => setDismissed(true)} />;
  }
  const ticketKey = ticketKeys[0];
  const run = fromCard[0];
  if (run) {
    // Hand the pull request to this chat's persona, as a message from the person.
    const review = run.pr_url && messageId && actions && !actions.disabled ? () => actions.ask(messageId, `Review the pull request for ${run.ticket}: ${run.pr_url}`) : undefined;
    return runEnded(run.state) ? <TicketRunCard run={run} onReview={review} /> : (
      <p data-testid="dispatch-started" className="text-13 text-fg-tertiary">
        Started <Link className="text-accent hover:underline" href={`/tickets/${run.ticket}`}>{run.ticket}</Link> with @{run.agent}. Follow it above the message box.
      </p>
    );
  }
  return <StartCard ticketKey={ticketKey} chatId={chatId} messageId={messageId} onDismiss={() => setDismissed(true)} />;
}

type Preview = Schemas["DispatchPreview"];

/** One ticket a multi-ticket card offers: what Start would do for it, or the run it started. */
type Offer = { key: string; title?: string; preview?: Preview; error?: string; run?: TicketRun };

const startable = (o: Offer) => !o.run && !!o.preview && o.preview.blockers.length === 0;

/** Why a ticket can't start, that it will wait, or that it's ready: one short line. */
function OfferStatus({ o }: { o: Offer }) {
  if (o.run) return <RunPill run={o.run} />;
  if (o.error) return <span className="text-12 text-pill-blocked-fg">{o.error}</span>;
  if (!o.preview) return <span className="h-3 w-20 animate-pulse rounded bg-surface-sunken" />;
  if (o.preview.blockers.length) return <span className="text-12 text-pill-blocked-fg">{o.preview.blockers.join(" ")}</span>;
  if (o.preview.queued_behind.length) return <span className="text-12 text-pill-human-fg">Waits for {o.preview.queued_behind.map((b) => b.replace(/^Blocked by (\S+).*$/, "$1")).join(", ")}</span>;
  return <span className="text-12 text-fg-tertiary">Ready</span>;
}

/** Every ticket a card offers, with its preview and title, loaded together. */
function useOffers(ticketKeys: string[], started: TicketRun[]): Offer[] {
  const previews = useQueries({
    queries: ticketKeys.map((key) => ({
      queryKey: ["tickets", "dispatch", key] as const,
      queryFn: () => unwrap(api.GET("/tickets/{key}/dispatch", { params: { path: { key } } })),
      staleTime: 5_000,
    })),
  });
  const tickets = useQueries({
    queries: ticketKeys.map((key) => ({
      queryKey: queryKeys.ticket(key),
      queryFn: () => unwrap(api.GET("/tickets/{key}", { params: { path: { key } } })),
    })),
  });
  return ticketKeys.map((key, i) => ({
    key,
    title: tickets[i]?.data?.title,
    preview: previews[i]?.data,
    error: previews[i]?.isError ? previews[i].error?.message || `Couldn’t load ${key}.` : undefined,
    run: started.find((r) => r.ticket === key),
  }));
}

/**
 * A card offering several tickets: one line each, and Start all opens a dialog
 * to confirm which. Each start is its own dispatch, run as the person.
 */
function MultiStartCard({ ticketKeys, chatId, messageId, started, onDismiss }: { ticketKeys: string[]; chatId: string; messageId?: string; started: TicketRun[]; onDismiss: () => void }) {
  const offers = useOffers(ticketKeys, started);
  const [open, setOpen] = useState(false);
  const ready = offers.filter(startable);
  const begun = offers.filter((o) => o.run).length;
  const loading = offers.some((o) => !o.run && !o.preview && !o.error);
  return (
    <div data-testid="dispatch-card" className={CARD}>
      <div className="flex items-baseline justify-between gap-3">
        <h4 className="text-14 font-semibold text-fg">Start runs for {ticketKeys.length} tickets?</h4>
        {begun > 0 && <span className="flex-none text-12 text-fg-tertiary">{begun} of {ticketKeys.length} started</span>}
      </div>
      <ul className="flex flex-col divide-y divide-border-subtle rounded-lg border border-border-subtle">
        {offers.map((o) => (
          <li key={o.key} data-testid="dispatch-offer" className="flex min-w-0 items-center gap-2.5 px-3 py-2 text-13">
            <Link href={`/tickets/${o.key}`} className="flex-none font-mono text-12 text-fg-tertiary hover:underline">{o.key}</Link>
            <span className="min-w-0 flex-1 truncate text-fg">{o.title ?? ""}</span>
            <span className="flex max-w-[45%] flex-none justify-end truncate"><OfferStatus o={o} /></span>
          </li>
        ))}
      </ul>
      <div className="flex flex-wrap items-center gap-2">
        {ready.length > 0 ? (
          <>
            <Button variant="primary" disabled={!messageId || loading} onClick={() => setOpen(true)}>
              {loading && <Spinner />}{`Start all (${ready.length})…`}
            </Button>
            <Button variant="ghost" onClick={onDismiss}>Not now</Button>
          </>
        ) : begun > 0 ? (
          <p className="text-13 text-fg-tertiary">Follow them above the message box.</p>
        ) : !loading && <p className="text-13 text-fg-tertiary">None of these can start yet.</p>}
      </div>
      {open && messageId && <StartAllDialog chatId={chatId} messageId={messageId} offers={offers} onOpenChange={setOpen} />}
    </div>
  );
}

type StartResult = "started" | { error: string };

/** Confirm which of a card's tickets to start, then start them one by one, saying how each went. */
function StartAllDialog({ chatId, messageId, offers, onOpenChange }: { chatId: string; messageId: string; offers: Offer[]; onOpenChange: (o: boolean) => void }) {
  const start = useStartChatTicketRun(chatId);
  const [picked, setPicked] = useState(() => new Set(offers.filter(startable).map((o) => o.key)));
  const [results, setResults] = useState<Record<string, StartResult>>({});
  const [busy, setBusy] = useState<string | null>(null);
  const runner = offers.find((o) => o.preview)?.preview;
  const chosen = offers.filter((o) => picked.has(o.key) && startable(o) && results[o.key] !== "started");
  const failed = Object.values(results).some((r) => r !== "started");

  async function startChosen() {
    let ok = true;
    // One at a time: each start locks the chat, and a refusal names its own ticket.
    for (const o of chosen) {
      setBusy(o.key);
      try {
        await start.mutateAsync({ ticket: o.key, message_id: messageId });
        setResults((r) => ({ ...r, [o.key]: "started" }));
      } catch (e) {
        ok = false;
        setResults((r) => ({ ...r, [o.key]: { error: e instanceof Error && e.message ? e.message : "Couldn’t start the run." } }));
      }
    }
    setBusy(null);
    if (ok) onOpenChange(false);
  }

  const toggle = (key: string, on: boolean) => setPicked((p) => {
    const next = new Set(p);
    if (on) next.add(key);
    else next.delete(key);
    return next;
  });

  return (
    <Dialog.Root open onOpenChange={(o) => !busy && onOpenChange(o)}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          data-testid="start-all-dialog"
          aria-describedby="start-all-desc"
          className="motion-dialog fixed left-1/2 top-[6vh] z-50 flex max-h-[88vh] w-[min(640px,calc(100%-32px))] -translate-x-1/2 flex-col overflow-hidden rounded-2xl border border-border-float bg-surface-raised shadow-[var(--shadow-float)] outline-none"
        >
          <div className="flex items-start gap-3 border-b border-border-subtle px-[18px] py-3.5">
            <div className="flex flex-1 flex-col">
              <Dialog.Title className="type-heading">Start {chosen.length} {chosen.length === 1 ? "run" : "runs"}</Dialog.Title>
              <p id="start-all-desc" className="text-13 text-fg-secondary">
                Each ticket starts with its assigned agent, dispatched by you. A ticket with unfinished blockers queues until they&apos;re Done.
              </p>
            </div>
            <Dialog.Close asChild>
              <IconButton icon="x" label="Close" disabled={!!busy} />
            </Dialog.Close>
          </div>
          <ul className="flex flex-col divide-y divide-border-subtle overflow-y-auto px-[18px] py-2">
            {offers.map((o) => {
              const can = startable(o) && results[o.key] !== "started";
              const result = results[o.key];
              return (
                <li key={o.key} className="flex items-start gap-3 py-2.5 text-13">
                  <input
                    type="checkbox"
                    aria-label={`Start ${o.key}`}
                    className="mt-0.5 size-4 flex-none accent-[var(--color-accent)]"
                    checked={can && picked.has(o.key)}
                    disabled={!can || !!busy}
                    onChange={(e) => toggle(o.key, e.target.checked)}
                  />
                  <div className="flex min-w-0 flex-1 flex-col gap-0.5">
                    <span className="flex min-w-0 items-baseline gap-2">
                      <span className="flex-none font-mono text-12 text-fg-tertiary">{o.key}</span>
                      <span className="truncate font-medium text-fg">{o.title ?? ""}</span>
                    </span>
                    {o.preview && !o.run && (
                      <span className="text-12 text-fg-secondary">
                        @{o.preview.agent.handle || "nobody"} · {o.preview.resolved.harness} · {o.preview.resolved.model}
                      </span>
                    )}
                    {result && result !== "started" ? (
                      <span role="alert" className="text-12 text-pill-blocked-fg">{result.error}</span>
                    ) : (
                      <span className="text-12"><OfferStatus o={o} /></span>
                    )}
                  </div>
                  <span className="flex-none pt-0.5 text-12 text-fg-tertiary">
                    {busy === o.key ? "Starting…" : result === "started" ? "Started" : ""}
                  </span>
                </li>
              );
            })}
          </ul>
          {runner && (
            <div className="border-t border-border-subtle px-[18px] py-2.5 text-13">
              <StartsLine p={runner} />
            </div>
          )}
          <div className="flex flex-wrap items-center gap-3 border-t border-track bg-surface-sunken px-[18px] py-3">
            <span className="mr-auto text-12 text-fg-tertiary">{failed ? "Some didn’t start: see why above." : "Logged on each ticket as dispatched by you"}</span>
            <Dialog.Close asChild>
              <Button variant="ghost" disabled={!!busy}>{failed ? "Close" : "Cancel"}</Button>
            </Dialog.Close>
            <Button variant="approve" disabled={!chosen.length || !!busy} onClick={startChosen}>
              {busy ? "Starting…" : `Start ${chosen.length} ${chosen.length === 1 ? "run" : "runs"}`}
            </Button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
