"use client";

// The run thread (LAZYAGENTS-163): the run in the chat's typography. A Now line
// with the plan's progress, finished steps condensed to a line each, the
// agent's messages at chat size, sub-runs as cards, the approval or question
// inline (A / ⇧A / D), a Next line to the next Needs you item (J), and the
// composer. The raw log, graph and files open from the Context panel.

import Link from "next/link";
import { chatStatus, toolCalls } from "@/lib/chat-ui";
import { ActivityScene } from "../../chat/_components/activity-scene";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { useInbox } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { absoluteTime, duration, runCost } from "@/lib/format";
import { KIND, trayItems } from "@/lib/inbox";
import { itemHref, nextNeedsItem, runTitle } from "@/lib/run-list";
import { stepProgress } from "@/lib/run-mobile";
import { latestQuestion } from "@/lib/run-question";
import { condenseFeed, delegateChild, finalMessage, nowLine, workHref, type FeedItem } from "@/lib/run-view";
import { WorkPersonaAvatar } from "@/components/domain/work-persona-avatar";
import { runCharacterState } from "@/lib/work-persona";
import { Markdown } from "@/components/domain/markdown";
import { RUN_ENDED, StatusPill } from "@/components/domain/run-status";
import { Button, ButtonLink } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Kbd, TextArea } from "@/components/ui/primitives";
import { Banner } from "@/components/ui/primitives";
import { WORK_COLUMN } from "@/components/domain/work-detail-header";
import { shortcutBlocked } from "@/components/shell/shortcuts";
import { ActionBox, useReply, waitsForReply } from "./run-panels";
import { listQuery } from "../run-list";

type RunDetail = Schemas["RunDetail"];
type Run = Schemas["Run"];

const clock = new Intl.DateTimeFormat(undefined, { hour: "2-digit", minute: "2-digit", hour12: false });
const COLUMN = "mx-auto w-full max-w-[760px] px-6 max-sm:px-3";

/** The run's cost, plus what its sub agents spent. */
export function CostValue({ d }: { d: RunDetail }) {
  const sub = d.child_runs.reduce((n, c) => n + c.cost_usd, 0);
  const subPriced = d.child_runs.every((c) => c.cost_source && c.cost_source !== "unknown");
  return (
    <>
      {runCost(d.run.cost_usd, d.run.cost_source)}
      {d.child_runs.length > 0 && <span className="ml-1.5 text-12 font-normal text-fg-tertiary">{subPriced ? "+" : "≥ +"}${sub.toFixed(2)} sub</span>}
    </>
  );
}

/** What the run works on: the ticket, the plan or the chat. */
export function WorkLink({ run }: { run: Run }) {
  const href = workHref(run);
  if (run.purpose === "ticket" && run.ticket_key) {
    return <Link href={`/tickets/${encodeURIComponent(run.ticket_key)}`} className="text-accent hover:underline"><span className="font-mono">{run.ticket_key}</span> ↗</Link>;
  }
  if (!href) return null;
  return <Link href={href} className="text-accent hover:underline">{run.purpose === "planning" ? "Open the plan" : "Open the chat"} ↗</Link>;
}

/** Live activity bar (with SVG scene and step progress); collapses to the progress strip once ended. */
function NowLine({ d, col }: { d: RunDetail; col: string }) {
  const run = d.run;
  const p = stepProgress(run);
  const ended = RUN_ENDED.includes(run.state);
  // The step is shown beside the status, so the headline leaves it out when a current step exists.
  const now = nowLine({ ...run, plan: [] }, d.events) ?? (ended ? null : p.current?.text ?? null);
  if (ended && !p.total) return null;
  if (!ended && !now && !p.total) return null;
  const pct = p.total ? Math.round((p.done / p.total) * 100) : 0;
  return (
    <div className={cx("flex flex-none flex-col border-b border-border-subtle", ended ? "py-1.5" : "gap-1.5 py-2")}>
      {!ended && (
        <div className={cx(col, "flex items-center gap-3")}>
          <ActivityScene current={chatStatus(toolCalls(d.events)).kind} stopping={false} />
          <span role="status" className="min-w-0 flex-1 truncate text-13 text-fg">
            {p.current?.text ?? now}
            <small className="flex flex-wrap items-center gap-1.5 text-11 text-fg-tertiary">
              <span>{run.harness}</span>
              {p.total > 0 && (
                <>
                  <span aria-hidden>·</span>
                  <span className="font-mono">Step {p.current?.position ?? p.done} of {p.total}</span>
                </>
              )}
            </small>
          </span>
        </div>
      )}
      {p.total > 0 && (
        <div className={col}>
          <div
            role="progressbar"
            aria-label="Plan progress"
            aria-valuemin={0}
            aria-valuemax={p.total}
            aria-valuenow={p.done}
            aria-valuetext={`${p.done} of ${p.total} steps done`}
            className="h-0.5 overflow-hidden rounded-full bg-surface-sunken"
          >
            <div className={cx("h-full rounded-full", run.state === "waiting" ? "bg-state-human" : run.state === "running" ? "live-sheen bg-state-done" : "bg-state-done")} style={{ width: `${pct}%` }} />
          </div>
        </div>
      )}
    </div>
  );
}

const STEP_MARK: Record<string, string> = { done: "✓", failed: "✕", needs_human: "!" };
const STEP_TEXT: Record<string, string> = { done: "done", failed: "failed", needs_human: "needs a person" };
const GATE_TEXT: Record<string, string> = { approval: "Asked for approval", reply: "Asked a question", mockup: "Submitted a mockup for review" };

function Line({ at, mark, tone, children, onClick, label }: { at: string; mark: ReactNode; tone?: "error" | "gate" | "done"; children: ReactNode; onClick?: () => void; label?: string }) {
  const body = (
    <>
      <span
        aria-hidden
        className={cx(
          "flex h-5 min-w-5 flex-none items-center justify-center rounded px-1 font-mono text-11 font-semibold",
          tone === "error" ? "bg-pill-blocked-bg text-pill-blocked-fg" : tone === "gate" ? "bg-pill-human-bg text-pill-human-fg" : tone === "done" ? "text-state-done" : "bg-surface-sunken text-fg-secondary",
        )}
      >
        {mark}
      </span>
      <span className="min-w-0 flex-1">{children}</span>
      <time dateTime={at} title={absoluteTime(at)} className="flex-none pt-0.5 font-mono text-11 text-fg-tertiary">{clock.format(new Date(at))}</time>
    </>
  );
  const cls = "flex w-full items-start gap-2.5 py-1 text-left text-13 text-fg-secondary";
  return (
    <li>
      {onClick ? <button type="button" aria-label={label} onClick={onClick} className={cx(cls, "rounded-md hover:bg-hover")}>{body}</button> : <div className={cls}>{body}</div>}
    </li>
  );
}

function SubRunCard({ child, agent, task, at }: { child?: Run; agent: string; task: string; at: string }) {
  return (
    <li className="py-1.5">
      <div className="flex items-start gap-3 rounded-xl border border-border bg-surface px-3.5 py-3">
        {child ? <WorkPersonaAvatar agent={child.agent} size="md" state={runCharacterState(child)} /> : <span aria-hidden className="size-7 flex-none rounded-full bg-surface-sunken" />}
        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <p className="flex flex-wrap items-center gap-2 text-13">
            <span className="font-medium text-fg">{child?.agent.name ?? agent}</span>
            <span className="text-fg-tertiary">sub-run</span>
            {child && <StatusPill run={child} />}
          </p>
          {task && <p className="line-clamp-2 text-13 text-fg-2">{task}</p>}
          <p className="font-mono text-11 text-fg-tertiary">
            {clock.format(new Date(at))}
            {child && ` · ${child.model} · ${duration(child.started_at, child.ended_at)} · ${runCost(child.cost_usd, child.cost_source)}`}
          </p>
        </div>
        {child && <Link href={`/runs/${child.id}`} className="flex-none text-12 text-accent hover:underline">Open run ↗</Link>}
      </div>
    </li>
  );
}

function FeedRow({ item, d, onOpenTurn }: { item: FeedItem; d: RunDetail; onOpenTurn: (turn: number) => void }) {
  const run = d.run;
  switch (item.kind) {
    case "turn":
      return (
        <li className="pb-1 pt-3">
          <button
            type="button"
            onClick={() => onOpenTurn(item.turn)}
            aria-label={`Turn ${item.turn}, ${item.tools} tool calls. Open in the raw log`}
            className="inline-flex items-center gap-1.5 rounded-full border border-border-subtle bg-surface/70 px-2.5 py-0.5 text-11 text-fg-tertiary transition-colors hover:border-border hover:bg-hover hover:text-fg"
          >
            <span aria-hidden>▸</span>
            <span>Turn {item.turn}</span>
            {item.tools > 0 && <span className="font-mono">· {item.tools} tool call{item.tools === 1 ? "" : "s"}</span>}
          </button>
        </li>
      );
    case "message":
      return (
        <li className="flex gap-3 py-2">
          <WorkPersonaAvatar agent={run.agent} size="md" />
          <div className="min-w-0 flex-1">
            <p className="mb-0.5 flex items-baseline gap-2 text-13">
              <span className="font-semibold text-fg">{run.agent.name}</span>
              <time dateTime={item.at} title={absoluteTime(item.at)} className="text-11 text-fg-tertiary">{clock.format(new Date(item.at))}</time>
            </p>
            <div className="text-15 leading-relaxed text-fg-2"><Markdown>{item.text}</Markdown></div>
          </div>
        </li>
      );
    case "step": {
      const text = (run.plan.find((s) => s.position === item.step) ?? run.plan[item.step - 1])?.text;
      return (
        <Line at={item.at} mark={STEP_MARK[item.state]} tone={item.state === "done" ? "done" : item.state === "failed" ? "error" : "gate"}>
          Step {item.step} {STEP_TEXT[item.state]}{text && <span className="text-fg-2"> · {text}</span>}
        </Line>
      );
    }
    case "delegation":
      return <SubRunCard child={delegateChild(item.call, d.child_runs, d.events)} agent={item.agent} task={item.task} at={item.at} />;
    case "error":
      return (
        <Line at={item.at} mark="!" tone="error" onClick={() => onOpenTurn(item.turn)} label={`Error: ${item.text}. Open in the raw log`}>
          <span className="whitespace-pre-wrap text-pill-blocked-fg">{item.text}</span>
        </Line>
      );
    case "gate":
      return (
        <Line at={item.at} mark="◆" tone="gate">
          {GATE_TEXT[item.gate]}{item.text && <span className="text-fg-2"> · {item.text}</span>}
        </Line>
      );
  }
}

function Outcome({ d }: { d: RunDetail }) {
  const run = d.run;
  const final = finalMessage(d.events);
  const href = workHref(run);
  return (
    <section aria-label="Outcome" className={cx("my-3 flex flex-col gap-2.5 rounded-xl border bg-surface p-4", run.state === "failed" ? "border-pill-blocked-bg" : "border-border")}>
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="flex items-center gap-1.5 text-11 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">
          {run.state === "completed" && <Icon name="check" size={12} className="text-state-done" />}
          Outcome
        </h2>
        <div className="flex flex-wrap items-center gap-2">
          {run.pr_url && run.pr_number ? <ButtonLink variant="outline" href={run.pr_url}>PR #{run.pr_number} ↗</ButtonLink> : null}
          {href && <ButtonLink variant="outline" href={href}>{run.purpose === "ticket" ? run.ticket_key : run.purpose === "planning" ? "Review proposals" : "Open chat"}</ButtonLink>}
        </div>
      </div>
      {run.outcome ? (
        <div className="text-14 leading-relaxed text-fg-2"><Markdown>{run.outcome}</Markdown></div>
      ) : (
        <p className="text-13 text-fg-secondary">The run ended without an outcome.</p>
      )}
      {final && final !== run.outcome && !run.outcome && (
        <div className="max-h-40 overflow-y-auto text-13 leading-relaxed text-fg-secondary"><Markdown>{final}</Markdown></div>
      )}
    </section>
  );
}

/** Chat-native folded step strip linking directly into the Trace tab. */
function TraceSummaryStrip({ d, onOpenTrace }: { d: RunDetail; onOpenTrace: () => void }) {
  const run = d.run;
  const p = stepProgress(run);
  if (run.tool_calls === 0 && p.total === 0) return null;
  const parts = [
    `Worked for ${duration(run.started_at, run.ended_at)}`,
    run.tool_calls > 0 ? `${run.tool_calls} tool call${run.tool_calls === 1 ? "" : "s"}` : null,
    p.total > 0 ? `${p.done}/${p.total} plan steps` : null,
  ].filter(Boolean);
  return (
    <button
      type="button"
      onClick={onOpenTrace}
      className="my-2 flex w-full items-center justify-between gap-3 rounded-lg border border-border-subtle bg-surface/60 px-3.5 py-2 text-left text-12 text-fg-secondary transition-colors hover:bg-hover hover:text-fg"
    >
      <span className="flex min-w-0 items-center gap-2 truncate">
        <span aria-hidden className="text-fg-tertiary">▸</span>
        <span className="truncate">{parts.join(" · ")}</span>
      </span>
      <span className="flex-none text-11 font-medium text-accent">Inspect trace →</span>
    </button>
  );
}

/** The agent's open question, above the composer that answers it. */
function Question({ run, question }: { run: Run; question: string | null }) {
  return (
    <div role="group" aria-label="Needs attention" className="my-2 flex flex-col gap-1.5 rounded-xl border border-state-human/50 bg-pill-human-bg/20 p-3.5">
      <p className="text-12 font-medium text-pill-human-fg">{run.agent.name} is waiting for your reply</p>
      {question && <div className="max-h-60 overflow-y-auto text-14 leading-relaxed text-fg-2"><Markdown>{question}</Markdown></div>}
      <p className="text-12 text-fg-tertiary">Answer in the box below.</p>
    </div>
  );
}

/** Next: the Needs you item after this run, opened with J. */
function NextLine({ next, query }: { next: Schemas["InboxItem"]; query: string }) {
  const router = useRouter();
  const href = itemHref(next, query);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key.toLowerCase() !== "j" || e.shiftKey || shortcutBlocked(e)) return;
      e.preventDefault();
      router.push(href);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [href, router]);
  const kind = KIND[next.kind]?.label ?? next.kind;
  return (
    <p className="my-3 flex items-center gap-2 text-13">
      <span className="flex-none text-11 font-semibold uppercase tracking-wide text-fg-tertiary">Next</span>
      <Link href={href} data-next-line className="min-w-0 truncate text-accent hover:underline">
        {kind} · {next.title}{next.agent ? ` · ${next.agent.name}` : ""}
      </Link>
      <Kbd className="pointer-coarse:hidden">J</Kbd>
    </p>
  );
}

/**
 * The composer: a reply (or a follow-up while the run works) sent the way the
 * Inbox replies, as a ticket comment mentioning the agent. A run waiting on
 * `human_reply` resumes with it; a working agent reads it from the ticket.
 * The run API has no aside or interrupt, so this is Follow-up only.
 */
function Composer({ run, lastSeq, unified, col }: { run: Run; lastSeq: number; unified?: boolean; col: string }) {
  const { comment, body, setBody, sent, again, submit } = useReply(run, lastSeq);
  const ref = useRef<HTMLTextAreaElement>(null);
  const waiting = waitsForReply(run);
  useEffect(() => {
    if (waiting) ref.current?.focus({ preventScroll: true });
  }, [waiting]);
  const label = waiting ? `Reply to ${run.agent.name}` : `Follow up with ${run.agent.name}`;
  return (
    <form
      aria-label={label}
      onSubmit={(e) => {
        e.preventDefault();
        submit();
      }}
      className={cx(col, "flex flex-none flex-col gap-1.5 pb-4 pt-2")}
    >
      {comment.isError && <Banner tone="blocked" title="Couldn't send">{comment.error.message}</Banner>}
      {sent ? (
        <p role="status" className="flex items-center justify-between gap-3 rounded-xl border border-border bg-surface px-3.5 py-2.5 text-13 text-fg-secondary">
          {waiting ? `Sent. Resuming ${run.agent.name}…` : `Sent to ${run.agent.name} as a comment on ${run.ticket_key}.`}
          <Button variant="outline" onClick={again}>Write another</Button>
        </p>
      ) : (
        <>
        {/* The main pane talks to what it shows: this run's agent. Your persona is in the side panel's Chat. */}
        {!unified && <div data-testid="run-composer-to" className="flex items-center gap-1.5 px-1">
          <span className="text-12 text-fg-tertiary">To</span>
          <span className="inline-flex h-[24px] items-center gap-1.5 rounded-md border border-border bg-surface pl-0.5 pr-2 text-12 font-medium text-fg-2">
            <WorkPersonaAvatar agent={run.agent} size="sm" />
            {run.agent.name}{run.ticket_key ? ` · ${run.ticket_key}` : ""}
          </span>
        </div>}
        <div className={cx("flex items-end gap-2 rounded-[14px] border bg-surface p-2 focus-within:border-accent", waiting ? "border-state-human/60" : "border-border-strong")}>
          <label className="sr-only" htmlFor="run-composer">{label}</label>
          <TextArea
            ref={ref}
            id="run-composer"
            rows={unified ? 2 : 1}
            value={body}
            placeholder={waiting ? `Reply to ${run.agent.name}…` : `Follow up with ${run.agent.name}…`}
            onChange={(e) => setBody(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey && !e.nativeEvent.isComposing) {
                e.preventDefault();
                submit();
              }
            }}
            className="max-h-48 min-h-9 flex-1 resize-none border-0 bg-transparent py-1.5 text-14 shadow-none focus:ring-0 focus-visible:outline-none"
          />
          <Button type="submit" variant={waiting ? "approve" : "primary"} disabled={!body.trim() || comment.isPending}>
            {comment.isPending ? "Sending…" : "Send"}
          </Button>
        </div>
        </>
      )}
      <p className="px-1 text-11 text-fg-tertiary">
        {unified ? `Reply to ${run.agent.name} · ${waiting ? "Reply" : "Follow-up"}` : waiting ? "Your reply resumes the run." : `Goes to ${run.agent.name} as a comment on ${run.ticket_key}; it reads it on its next look at the ticket.`}
      </p>
    </form>
  );
}

export function RunThread({
  d,
  onOpenTurn,
  onOpenTrace,
  unified,
  embeddedHeader,
  workLinks,
}: {
  d: RunDetail;
  onOpenTurn: (turn: number) => void;
  onOpenTrace?: () => void;
  unified?: boolean;
  embeddedHeader?: boolean;
  workLinks?: ReactNode;
}) {
  const run = d.run;
  const params = useSearchParams();
  const query = listQuery(params);
  const ended = RUN_ENDED.includes(run.state);
  const feed = useMemo(() => condenseFeed(d.events, () => "", { messages: true }), [d.events]);
  const inbox = useInbox();
  const needs = useMemo(() => trayItems(inbox.data ?? []).needs, [inbox.data]);
  const mine = needs.some((i) => i.run_id === run.id);
  const next = mine ? undefined : nextNeedsItem(needs, run.id);
  const scroller = useRef<HTMLDivElement>(null);
  const [follow, setFollow] = useState(true);
  useEffect(() => {
    const el = scroller.current;
    if (follow && el) el.scrollTop = el.scrollHeight;
  }, [follow, feed.length, run.state, next?.id]);
  const asking = waitsForReply(run);
  const canWrite = !ended && run.purpose === "ticket" && !!run.ticket_key;
  const steps = stepProgress(run);
  const col = embeddedHeader ? WORK_COLUMN : COLUMN;
  return (
    <section aria-label="Run thread" className="flex min-h-0 min-w-0 flex-1 flex-col">
      {!embeddedHeader && (unified ? (
        <div className="flex flex-none items-center gap-2.5 border-b border-border-subtle px-4 py-2 md:px-6">
          <WorkPersonaAvatar agent={run.agent} size="sm" state={runCharacterState(run)} />
          <h1 className="min-w-0 flex-1 truncate text-14 font-semibold leading-snug text-fg">{runTitle(run)}</h1>
          <p data-run-inline-meta className="hidden shrink-0 truncate font-mono text-11 text-fg-tertiary sm:block">
            {run.agent.name} · {run.harness} · {duration(run.started_at, run.ended_at)}
            {run.cost_usd > 0 ? ` · ${runCost(run.cost_usd, run.cost_source)}` : ""}
            {steps.total > 0 ? ` · step ${steps.done}/${steps.total}` : ""}
            {run.parent_run_id && (
              <>
                {" · "}
                <Link href={`/runs/${run.parent_run_id}`} className="text-accent hover:underline">Delegated by ↗</Link>
              </>
            )}
          </p>
          <StatusPill run={run} />
        </div>
      ) : (
        <div className={cx(col, "flex flex-none items-center gap-3 py-3")}>
          <WorkPersonaAvatar agent={run.agent} size="md" state={runCharacterState(run)} />
          <div className="flex min-w-0 flex-1 flex-col leading-tight">
            <h1 className="truncate text-16 font-semibold text-fg">{runTitle(run)}</h1>
            <span className="flex min-w-0 flex-wrap items-center gap-x-2 text-12 text-fg-tertiary">
              {run.agent.name}
              <span aria-hidden>·</span>
              <WorkLink run={run} />
              {run.parent_run_id && <><span aria-hidden>·</span><Link href={`/runs/${run.parent_run_id}`} className="text-accent hover:underline">Delegated by ↗</Link></>}
            </span>
          </div>
          <StatusPill run={run} />
        </div>
      ))}
      {workLinks}
      <NowLine d={d} col={col} />
      <div
        ref={scroller}
        role="log"
        aria-label="Run thread"
        tabIndex={0}
        onScroll={(e) => {
          const el = e.currentTarget;
          setFollow(el.scrollHeight - el.scrollTop - el.clientHeight < 24);
        }}
        className="min-h-0 flex-1 overflow-y-auto outline-none"
      >
        <div className={cx(col, "py-3")}>
          {ended && <Outcome d={d} />}
          {onOpenTrace && <TraceSummaryStrip d={d} onOpenTrace={onOpenTrace} />}
          {feed.length ? (
            <ol aria-live={follow ? "polite" : "off"}>
              {feed.map((item, i) => <FeedRow key={`${item.kind}:${item.at}:${i}`} item={item} d={d} onOpenTurn={onOpenTurn} />)}
            </ol>
          ) : !ended ? (
            <p className="py-8 text-center text-13 text-fg-tertiary">
              {run.state === "queued" ? "The run starts when a runner slot is free." : `Messages appear as ${run.agent.name} works.`}
            </p>
          ) : null}
          {/* An unmanaged session's await_human logs no run event; its Needs you item carries the question. */}
          {asking && <Question run={run} question={latestQuestion(d.events) ?? (needs.find((i) => i.run_id === run.id && i.kind === "question")?.summary || null)} />}
          <ActionBox d={d} inThread keys={!ended} />
          {next && <NextLine next={next} query={query} />}
        </div>
      </div>
      {canWrite ? (
        <Composer run={run} unified={unified} col={col} lastSeq={d.events.at(-1)?.seq ?? 0} />
      ) : !ended && (run.purpose === "planning" || run.purpose === "chat") && workHref(run) ? (
        <p className={cx(col, "flex-none pb-4 pt-2 text-12 text-fg-tertiary")}>
          Write to {run.agent.name} in the {run.purpose === "planning" ? <Link href={workHref(run)!} className="text-accent hover:underline">plan</Link> : <Link href={workHref(run)!} className="text-accent hover:underline">chat</Link>}.
        </p>
      ) : null}
    </section>
  );
}

