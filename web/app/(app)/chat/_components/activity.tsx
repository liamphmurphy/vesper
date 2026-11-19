"use client";

import { createContext, useContext, useEffect, useMemo, useRef, useState } from "react";
import type { LinkTarget } from "@/lib/api/client";
import { useChatRunEvents, useResolvedLinks } from "@/lib/api/hooks";
import { activityOf, chatCalls, chatStatus, chatStatusOf, chatSteps, finishedTurn, foldSteps, formatSpan, interimLine, NEXT_STEP_KEY, quietFor, turnActivity, turnClock, turnNotes, turnPulse, turnTrace, type Activity, type ChatStep, type IntentTag, type ToolCall, type TraceStep, type TurnOutcome, type TurnPulse } from "@/lib/chat-ui";
import { useConnectorApprovals } from "@/lib/api/connector-hooks";
import { useApiSecretApprovals } from "@/lib/api/secret-hooks";
import { LinkTargets, WikiLink } from "@/components/domain/wikilink";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { ActivityScene, useHeldScene } from "./activity-scene";
import { ConnectorApprovalCards } from "./connector-requests";
import { SecretApprovalCards } from "./secret-requests";
import { StepGlyph } from "./step-glyph";
import { PersonaAvatar, PersonaName, type PersonaLook } from "./persona";
import { Spinner } from "@/components/ui/loading";

const str = (v: unknown) => (v == null ? "" : typeof v === "string" ? v : JSON.stringify(v));

/** The page or ticket the newest call reads, linked once it resolves. Unknown refs stay plain text (no ghost "create" link). */
export function ActivityRef({ refText, label }: { refText: string; label: string }) {
  const resolved = useResolvedLinks([refText]);
  const targets = useMemo(() => {
    const m = new Map<string, LinkTarget>();
    for (const l of resolved.data ?? []) if (l.target.kind !== "unresolved" && l.target.href) m.set(l.ref, l.target);
    return m;
  }, [resolved.data]);
  if (!targets.has(refText)) return <span className="text-fg">{label}</span>;
  return (
    <LinkTargets.Provider value={targets}>
      <WikiLink refText={refText}>{label}</WikiLink>
    </LinkTargets.Provider>
  );
}

function LiveLine({ a }: { a: Activity }) {
  return (
    <p data-testid="live-activity" className="flex min-w-0 items-center gap-2 text-13 text-fg-secondary">
      <Spinner />
      <span className="min-w-0 truncate">
        {a.verb}
        {a.ref && a.label && (
          <>
            {" "}
            <ActivityRef refText={a.ref} label={a.label} />
          </>
        )}
        {a.text && ` ${a.text}`}…
      </span>
    </p>
  );
}

function CallList({ calls }: { calls: ToolCall[] }) {
  return (
    <details className="w-full text-13">
      <summary className="cursor-pointer text-fg-tertiary">Tool calls ({calls.length})</summary>
      <ul className="mt-2 flex flex-col gap-1 font-mono text-12">
        {calls.map((c) => (
          <li key={c.key} className="flex gap-2">
            <span className="text-fg">{c.tool}</span>
            <span className="min-w-0 flex-1 truncate text-fg-tertiary">{str(c.input)}</span>
            <span className="text-fg-tertiary">{c.done ? "done" : "running"}</span>
          </li>
        ))}
      </ul>
    </details>
  );
}

const TAG_LABEL: Record<IntentTag, string> = { approach: "changed approach", surprise: "surprise" };

function TagPill({ tag }: { tag: IntentTag }) {
  return (
    <span data-testid="intent-tag" className={`flex-none rounded-full px-1.5 text-11 ${tag === "surprise" ? "bg-[var(--state-review)]/15 text-fg-secondary" : "bg-accent/15 text-fg-secondary"}`}>
      {TAG_LABEL[tag]}
    </span>
  );
}

/** Where "View reasoning" on a chat step lands in the Activity tab. */
export const traceStepId = (key: string) => `trace-step-${key.replace(/[^\w-]/g, "_")}`;
/** A finished turn's step, named by the reply it led to: step keys repeat across a run's turns. */
export const turnStepKey = (replyId: string, key: string) => `${replyId}/${key}`;

/**
 * A turn as the steps the chat tab showed, each with the decisions the assistant
 * narrated, its thinking (folded) and every tool call. `focus` opens and scrolls to one step.
 */
function TurnTrace({ steps, live, scope, focus }: { steps: TraceStep[]; live?: boolean; scope?: string; focus?: { key: string; at: number } }) {
  const root = useRef<HTMLOListElement>(null);
  useEffect(() => {
    if (!focus || !root.current) return;
    const el = root.current.querySelector<HTMLElement>(`#${traceStepId(focus.key)}`);
    if (!el) return;
    el.querySelector("details[data-thinking]")?.setAttribute("open", "");
    el.scrollIntoView({ block: "start", behavior: "smooth" });
  }, [focus]);
  if (steps.length === 0) return null;
  return (
    <ol ref={root} data-testid="turn-trace" className="flex w-full flex-col gap-2">
      {steps.map((s) => {
        // A finished turn's last step was still "active" when it ended.
        const state = !live && s.state === "active" ? "done" : s.state;
        // The live turn's steps go by their own key; a finished turn's by the reply they led to.
        const key = live ? s.key : scope ? turnStepKey(scope, s.key) : undefined;
        return (
          <li key={s.key} id={key ? traceStepId(key) : undefined} data-testid="trace-step" data-step-state={state}
            className={`flex w-full scroll-mt-4 flex-col gap-1.5 rounded-lg border bg-surface px-3 py-2 ${key && focus?.key === key ? "border-accent" : "border-border"}`}>
            <div className="flex min-w-0 items-center gap-2 text-13">
              <StepGlyph step={{ state, kind: s.kind }} />
              <span className={`min-w-0 truncate ${state === "active" ? "font-medium text-fg" : "text-fg-secondary"}`}>{s.title}</span>
              {s.tag && <TagPill tag={s.tag} />}
            </div>
            {s.intents.map((t, j) => (
              <p key={j} data-testid="trace-intent" className="rounded-md bg-accent/10 px-2.5 py-1.5 text-13 italic text-fg-secondary">{t}</p>
            ))}
            {s.thinking.length > 0 && (
              <details data-thinking className="text-13">
                <summary className="cursor-pointer text-fg-tertiary">Thinking</summary>
                <div className="mt-1.5 flex flex-col gap-2 border-l-2 border-border pl-3">
                  {s.thinking.map((t, j) => (
                    <p key={j} data-testid="trace-thinking" className="whitespace-pre-wrap leading-relaxed text-fg-secondary">{t}</p>
                  ))}
                </div>
              </details>
            )}
            {s.calls.length > 0 && <CallList calls={s.calls} />}
          </li>
        );
      })}
    </ol>
  );
}

/**
 * While a turn runs: the newest tool call as a live line ("Reading [[ADR-012]]…",
 * ADR Decision 5), above the turn's steps with their intent, thinking and calls. Shown in the Activity tab only.
 */
export function RunActivity({ runId, since, focus }: { runId?: string; since?: string; focus?: { key: string; at: number } }) {
  const q = useChatRunEvents(runId);
  const steps = useMemo(() => turnTrace(q.data, since), [q.data, since]);
  const latest = steps.flatMap((s) => s.calls).at(-1);
  if (!latest && steps.length === 0) return null;
  return (
    <>
      {latest && <LiveLine a={activityOf(latest)} />}
      <TurnTrace steps={steps} live focus={focus} />
    </>
  );
}

/** A finished turn's steps, with their intent, thinking and tool calls, in the Activity tab. */
export function TurnToolCalls({ runId, since, until, replyId, focus }: { runId?: string; since?: string; until?: string; replyId?: string; focus?: { key: string; at: number } }) {
  const q = useChatRunEvents(runId, true, false);
  const steps = useMemo(() => turnTrace(q.data, since, until), [q.data, since, until]);
  return <TurnTrace steps={steps} scope={replyId} focus={focus} />;
}

const STEP_BAR: Record<ChatStep["state"], string> = {
  planned: "bg-border",
  active: "bg-accent",
  done: "bg-[var(--state-done)]",
  failed: "bg-[var(--state-blocked)]",
};

/** Pulses the step under way, until the person presses Stop. */
const stepPulse = (s: ChatStep, stopping?: boolean) => (s.state === "active" && !stopping ? "motion-safe:animate-pulse" : "");

/** How long a step took, or has taken so far while it's under way; nothing under a second. */
function StepTimer({ step, now }: { step: ChatStep; now: number }) {
  if (step.startedAt === undefined) return null;
  const active = step.state === "active";
  const ms = (active ? now : (step.endedAt ?? step.startedAt)) - step.startedAt;
  if (ms < 1000) return null;
  return (
    <span data-testid="step-timer" className={`flex-none text-11 tabular-nums ${active ? "rounded-full bg-accent/15 px-1.5 text-fg-secondary" : "text-fg-tertiary"}`}>
      {formatSpan(ms)}
    </span>
  );
}

function StepRail({ steps, now, stopping, awaiting, onOpenStep, fold = foldSteps }: { steps: ChatStep[]; now: number; stopping?: boolean; awaiting?: boolean; onOpenStep?: (key: string) => void; fold?: (steps: ChatStep[]) => ReturnType<typeof foldSteps> }) {
  const { earlier, shown, later } = fold(steps);
  return (
    <ol data-testid="chat-steps" className="flex flex-col gap-2 border-t border-border-subtle px-3 py-2.5 text-13">
      {earlier > 0 && (
        <li className="flex items-center gap-2.5 text-fg-tertiary">
          <StepGlyph step={{ state: "done" }} />
          {earlier} earlier steps
        </li>
      )}
      {shown.map((s) => (
        <li key={s.key} data-step-state={s.state} className="flex min-w-0 items-start gap-2.5 motion-safe:animate-[scene-in_240ms_ease-out]">
          <StepGlyph step={s} stopping={stopping} />
          <div className="min-w-0 flex-1">
            <div className="flex min-w-0 items-center gap-2.5">
              <span className={`min-w-0 truncate ${s.state === "active" ? "font-medium text-fg" : s.state === "done" || s.state === "failed" ? "text-fg-secondary" : "text-fg-tertiary"}`}>{s.title}</span>
              {s.state === "failed" && <span className="sr-only">(failed)</span>}
              {awaiting && s.state === "active" && <span data-testid="step-awaiting" className="flex-none rounded-full bg-pill-human-bg px-2 text-11 text-pill-human-fg">Waiting for approval</span>}
              {s.added && <span className="flex-none rounded bg-[var(--state-progress)]/15 px-1.5 text-11 text-fg-secondary">added</span>}
              {s.tag && <TagPill tag={s.tag} />}
              <span className="ml-auto flex flex-none items-center gap-2.5">
                {onOpenStep && (s.reasoning || s.intent) && (
                  <button type="button" data-testid="view-reasoning" onClick={() => onOpenStep(s.key)} className="flex-none text-12 text-fg-tertiary hover:text-fg-secondary">
                    View reasoning ›
                  </button>
                )}
                <StepTimer step={s} now={now} />
              </span>
            </div>
            {s.detail && <p data-testid="chat-step-detail" className="truncate text-12 text-fg-tertiary">{s.detail}</p>}
            {s.intent && <p data-testid="chat-step-intent" className="line-clamp-2 text-12 italic text-fg-secondary">{s.intent}</p>}
          </div>
        </li>
      ))}
      {later > 0 && <li className="pl-[26px] text-fg-tertiary">+{later} more</li>}
    </ol>
  );
}

/**
 * The chat tab's card while a turn runs: "<Persona> is reading the code…" beside a small
 * scene for that kind of work, from the newest tool call at a high level only. The exact
 * calls stay in the Activity tab. Once a turn has two steps, or one with a detail to show, a rail below lists them; the active one says what it's on, by safe label only.
 * A step the assistant narrated a decision on shows that line, tagged when it changed approach or hit a surprise,
 * and links to its full reasoning in the Activity tab. It
 * collapses to a progress strip, and folds old steps so a long turn stays short.
 *
 * Under the headline, a pulse: how long the turn has run and how long since anything happened,
 * so a quiet stretch and a stuck one look different. Once the newest call has finished for a
 * few seconds the card switches to a contextual follow-up phase instead of repeating that call; after
 * a long silence it says so, and offers to ask what it's doing (an aside) or to stop.
 */
export function ChatStatus({ chatId, disabled, runId, since, persona, stopping, folded = false, onOpenStep, onAsk, onStop }: { chatId: string; disabled?: boolean; runId?: string; since?: string; persona: PersonaLook; stopping?: boolean; folded?: boolean; onOpenStep?: (key: string) => void; onAsk?: () => void; onStop?: () => void }) {
  const q = useChatRunEvents(runId);
  const now = useNow();
  const calls = useMemo(() => chatCalls(q.data, since), [q.data, since]);
  const clock = useMemo(() => turnClock(q.data, since), [q.data, since]);
  const activity = useMemo(() => turnActivity(q.data, since), [q.data, since]);
  const pulse = turnPulse(calls, clock, now);
  const status = useMemo(() => chatStatus(calls, pulse.between, activity), [calls, pulse.between, activity]);
  const notes = useMemo(() => turnNotes(q.data, since), [q.data, since]);
  const { steps, planned } = useMemo(() => chatSteps(calls, notes, { between: pulse.between, clock, activity }), [calls, notes, pulse.between, clock, activity]);
  // A dock is narrow: its card starts as a strip (scene, status, progress and the step under way) so the conversation stays in view.
  const [collapsed, setCollapsed] = useState(folded);
  // Asking once per quiet stretch: the button comes back only after something happens.
  const [askedAt, setAskedAt] = useState<number>();
  const scene = useHeldScene(status.kind);
  const hasRail = steps.length > 1 || !!steps[0]?.detail || !!steps[0]?.intent;
  const done = steps.filter((s) => s.state === "done").length;
  const work = steps.filter((s) => s.key !== NEXT_STEP_KEY).length;
  // A tool call or API request waiting on the person is part of this turn, so it opens in this card.
  const connectorWaiting = useConnectorApprovals(chatId).data?.approvals.length ?? 0;
  const secretWaiting = useApiSecretApprovals(chatId).data?.approvals.length ?? 0;
  const awaiting = !stopping && connectorWaiting + secretWaiting > 0;
  const quiet = !stopping && !awaiting && pulse.quiet;
  const asked = askedAt !== undefined && askedAt >= (clock.last ?? 0);
  const newest = calls.at(-1);
  // What the folded strip names: the step under way, else the last one that ran.
  const current = steps.find((s) => s.state === "active") ?? steps.findLast((s) => s.state !== "planned");
  return (
    <div data-testid="chat-status-card" data-folded={collapsed || undefined} data-awaiting={awaiting || undefined} data-quiet={quiet || undefined}
      className={`@container w-full max-w-[min(540px,100%)] overflow-hidden rounded-[13px] border bg-surface transition-[border-color,box-shadow] duration-(--motion-slow) ${awaiting ? "border-pill-human-fg/60 shadow-[0_0_0_3px_var(--pill-human-bg)]" : quiet ? "border-[var(--state-progress)]/50" : "border-border"}`}>
      <div className="flex items-center gap-3.5 px-3 py-2.5">
        {awaiting ? (
          <span aria-hidden className="grid h-[54px] w-[112px] flex-none place-items-center rounded-[9px] border border-pill-human-fg/50 bg-pill-human-bg/50 text-pill-human-fg motion-safe:animate-pulse @max-[380px]:h-[46px] @max-[380px]:w-[92px] @max-[280px]:hidden">
            <Icon name="shield" size={20} />
          </span>
        ) : (
          <ActivityScene current={scene.current} previous={scene.previous} stopping={stopping} />
        )}
        <span className="hidden flex-none @max-[280px]:inline-flex">
          <PersonaAvatar persona={persona} size={24} />
        </span>
        <div className="flex min-w-0 flex-1 flex-col justify-center gap-1">
          <p role="status" aria-live="polite" className={`truncate text-14 font-medium leading-[1.2] ${awaiting ? "text-pill-human-fg" : "text-fg"}`} data-testid="chat-status">
            {stopping
              ? "Stopping…"
              : awaiting
                ? `${persona.name} needs your approval`
                : quiet
                  ? `${persona.name} has been quiet for ${quietFor(pulse.idle ?? 0)}`
                  : `${persona.name} is ${status.phrase}…`}
          </p>
          <p aria-hidden data-testid="chat-pulse" className="flex min-w-0 items-center gap-1.5 truncate text-12 leading-[1.2] text-fg-tertiary tabular-nums">
            {awaiting ? (
              "Paused until you decide"
            ) : quiet ? (
              ["Still running", `last: ${newest ? chatStatusOf(newest).phrase : "thinking"}`, pulse.elapsed !== undefined && `${formatSpan(pulse.elapsed)} in all`].filter(Boolean).join(" · ")
            ) : (
              <PulseLine planned={planned ? `Step ${Math.min(done + 1, steps.length)} of ${steps.length}` : undefined} work={planned ? 0 : work} pulse={pulse} heard={clock.last !== undefined} stopping={stopping} />
            )}
          </p>
        </div>
        {hasRail && (
          <button
            type="button"
            aria-expanded={!collapsed}
            aria-label={collapsed ? "Show steps" : "Hide steps"}
            onClick={() => setCollapsed((c) => !c)}
            className="flex flex-none items-center gap-1 rounded-[7px] border border-border bg-surface-sunken px-2 py-1 text-11 font-medium tabular-nums text-fg-secondary transition-colors hover:border-border-strong hover:bg-hover hover:text-fg"
          >
            <span aria-hidden>{planned ? `${Math.min(done + 1, steps.length)}/${steps.length}` : `${steps.length}`}</span>
            <span aria-hidden className="text-10 leading-none">{collapsed ? "▾" : "▴"}</span>
          </button>
        )}
      </div>
      {/* Always mounted so the panel can animate open and shut instead of popping in. */}
      <div className={`grid transition-[grid-template-rows] duration-(--motion-slow) ease-out motion-reduce:transition-none ${awaiting ? "grid-rows-[1fr]" : "grid-rows-[0fr]"}`}>
        <div className="overflow-hidden">
          <div role="group" aria-label="Waiting for your approval" className="flex flex-col gap-2 px-3 pb-3">
            <ConnectorApprovalCards chatId={chatId} disabled={disabled} />
            <SecretApprovalCards chatId={chatId} disabled={disabled} />
          </div>
        </div>
      </div>
      {quiet && (onAsk || onStop) && (
        <div data-testid="quiet-actions" className="flex flex-wrap gap-2 px-3 pb-3">
          {onAsk && !asked && (
            <Button variant="outline" icon="branch" disabled={disabled} onClick={() => { setAskedAt(Date.now()); onAsk(); }}>
              Ask what it&apos;s doing
            </Button>
          )}
          {onStop && (
            <Button variant="outline" icon="pause" onClick={onStop}>
              Stop
            </Button>
          )}
        </div>
      )}
      {hasRail && (
        collapsed ? (
          <>
            <div aria-hidden className={`flex gap-[3px] px-3 ${current ? "pb-2" : "pb-2.5"}`}>
              {steps.map((s) => (
                <i key={s.key} className={`h-[3px] flex-1 rounded-full ${STEP_BAR[s.state]} ${stepPulse(s, stopping)}`} />
              ))}
            </div>
            {current && (
              <p data-testid="chat-step-now" className="flex min-w-0 items-center gap-2 px-3 pb-2.5 text-12">
                <StepGlyph step={current} stopping={stopping} />
                <span className="min-w-0 truncate font-medium text-fg">{current.title}</span>
                <span className="flex-none tabular-nums text-fg-tertiary">{steps.indexOf(current) + 1} of {steps.length}</span>
              </p>
            )}
          </>
        ) : (
          <StepRail steps={steps} now={now} stopping={stopping} awaiting={awaiting} onOpenStep={onOpenStep} />
        )
      )}
    </div>
  );
}

/**
 * The header's live line while a reply runs, the way a messaging app shows someone typing:
 * "Hackerman · reading 4 files". It reads the run events the status card already caches.
 * Pressing it opens the turn's Activity.
 */
export function ChatPresence({ runId, since, persona, dotOnly = false, onOpen }: { runId?: string; since?: string; persona: PersonaLook; dotOnly?: boolean; onOpen?: () => void }) {
  const q = useChatRunEvents(runId);
  const calls = useMemo(() => chatCalls(q.data, since), [q.data, since]);
  const activity = useMemo(() => turnActivity(q.data, since), [q.data, since]);
  const status = useMemo(() => chatStatus(calls, false, activity), [calls, activity]);
  return (
    <button type="button" onClick={onOpen} disabled={!onOpen} data-testid="chat-presence" data-dot-only={dotOnly || undefined} title={dotOnly ? `${persona.name} · ${status.phrase}… (open Activity)` : "Open Activity"}
      className="flex min-w-0 max-w-full items-center gap-1.5 truncate px-1.5 text-left text-12 text-state-progress hover:underline disabled:hover:no-underline">
      <span aria-hidden className="size-1.5 flex-none rounded-full bg-state-progress motion-safe:animate-pulse" />
      {/* While the status card is on screen it already says this; the line comes back once it scrolls away. */}
      <span className={dotOnly ? "sr-only" : "truncate"}>{persona.name} · {status.phrase}…</span>
    </button>
  );
}

/**
 * Opens the Activity tab on a finished turn's step, given its turnStepKey. A context, so the
 * memoized reply bubbles don't re-render when the conversation's callbacks change.
 */
export const OpenTurnStep = createContext<((key: string) => void) | undefined>(undefined);

const OUTCOME_VERB: Record<TurnOutcome, string> = { done: "Worked for", failed: "Failed after", stopped: "Stopped after" };

/** Every step of a finished turn: the person opened the strip to see them, so nothing folds. */
const showAll = (steps: ChatStep[]) => ({ earlier: 0, shown: steps, later: 0 });
/** A failed turn opens on where it failed: the steps before the first failure fold into a count. */
const fromFailure = (steps: ChatStep[]) => {
  const at = Math.max(0, steps.findIndex((s) => s.state === "failed"));
  return { earlier: at, shown: steps.slice(at), later: 0 };
};

/**
 * What the live card leaves behind once its turn ends: a one-line strip above the reply
 * ("Worked for 2m 14s · 7 steps") that opens to the steps the card showed, all finished.
 * A failed turn opens on its failed step; a stopped one says so. `replyId` names the reply in
 * the Activity tab, so "View reasoning" can open there; turns without a reply have no entry.
 */
export function TurnSteps({ runId, outcome, since, until, end, replyId }: { runId?: string; outcome: TurnOutcome; since?: string; until?: string; end?: number; replyId?: string }) {
  const q = useChatRunEvents(runId, true, false);
  const turn = useMemo(() => finishedTurn(q.data, outcome, since, until, end), [q.data, outcome, since, until, end]);
  const openStep = useContext(OpenTurnStep);
  const [open, setOpen] = useState(outcome === "failed");
  if (turn.steps.length === 0) return null;
  const count = `${turn.steps.length} ${turn.steps.length === 1 ? "step" : "steps"}`;
  const took = turn.duration !== undefined && turn.duration >= 1000 ? ` ${formatSpan(turn.duration)}` : "";
  const view = replyOpen(openStep, replyId);
  return (
    <>
      <div data-testid="turn-steps" data-outcome={outcome}
        className={`w-full max-w-[min(720px,100%)] rounded-xl border bg-surface ${outcome === "failed" ? "border-[var(--state-blocked)]/40" : "border-border"} ${open ? "" : "sm:w-fit sm:min-w-[320px]"}`}>
        <button type="button" aria-expanded={open} onClick={() => setOpen((o) => !o)} className="flex w-full items-center gap-2.5 px-3.5 py-2 text-left text-13">
          {outcome === "stopped" ? (
            <span aria-hidden className="grid size-4 flex-none place-items-center rounded-full bg-fg-tertiary text-surface"><Icon name="pause" size={10} /></span>
          ) : (
            <StepGlyph step={{ state: outcome === "failed" ? "failed" : "done" }} />
          )}
          <span data-testid="turn-steps-summary" className="min-w-0 flex-1 truncate text-fg-secondary">
            {took ? `${OUTCOME_VERB[outcome]}${took}` : OUTCOME_VERB[outcome].split(" ")[0]} · {count}
          </span>
          <span className="flex-none pl-3 text-12 text-fg-tertiary">{open ? "Hide steps ‹" : "Show steps ›"}</span>
        </button>
        {open && (
          <>
            <StepRail steps={turn.steps} now={0} fold={outcome === "failed" ? fromFailure : showAll} onOpenStep={view} />
            {view && (
              <button type="button" onClick={() => view(turn.steps[0].key)} className="px-3.5 pb-2.5 text-12 text-fg-tertiary hover:text-fg-secondary">
                All tool calls in Activity ›
              </button>
            )}
          </>
        )}
      </div>
      {outcome === "stopped" && <p className="text-12 italic text-fg-tertiary">Stopped before it replied.</p>}
    </>
  );
}

/** "View reasoning" for a finished turn's step, which only has somewhere to go when the turn has a reply in Activity. */
const replyOpen = (openStep: ((key: string) => void) | undefined, replyId: string | undefined) =>
  openStep && replyId ? (key: string) => openStep(turnStepKey(replyId, key)) : undefined;

/** Only show "last activity Xs ago" once the turn has been idle long enough that it's useful signal, not per-second churn. */
const IDLE_HINT_MS = 10_000;

/** "● Step 2 of 3 · 4m 12s" (plus "· last activity 14s ago" after a brief pause). */
function PulseLine({ planned, work, pulse, heard, stopping }: { planned?: string; work: number; pulse: TurnPulse; heard: boolean; stopping?: boolean }) {
  const parts = [planned, work > 1 && `${work} steps`, pulse.elapsed !== undefined && formatSpan(pulse.elapsed)].filter(Boolean);
  const showIdle = heard && pulse.idle !== undefined && pulse.idle >= IDLE_HINT_MS;
  return (
    <>
      <span className={`size-1.5 flex-none rounded-full ${stopping ? "bg-fg-tertiary" : "bg-accent motion-safe:animate-pulse"}`} />
      {parts.length > 0 && <span className="truncate">{parts.join(" · ")}</span>}
      {showIdle && (
        <>
          {parts.length > 0 && <span>·</span>}
          <span className="truncate tabular-nums">last activity {formatSpan(pulse.idle!)} ago</span>
        </>
      )}
    </>
  );
}

/** The time now, ticking every second while mounted: the card's timers count without new events. */
function useNow() {
  const [now, setNow] = useState(() => Date.now());
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, []);
  return now;
}

/**
 * The running turn's opening line ("Good question, let me check the runs."), shown as a
 * reply bubble while the assistant works. The prompt asks for one only on turns that
 * need real work; when the turn ends the server saves it as its own message ahead of the reply.
 */
export function InterimReply({ runId, since, persona }: { runId?: string; since?: string; persona: PersonaLook }) {
  const q = useChatRunEvents(runId);
  const line = useMemo(() => interimLine(q.data, since), [q.data, since]);
  if (!line) return null;
  return (
    <div className="flex flex-col items-start gap-1" data-testid="interim-reply">
      <span className="flex items-center gap-1.5 text-12 text-fg-tertiary">
        <PersonaAvatar persona={persona} size={22} />
        <PersonaName persona={persona} className="text-13" />
      </span>
      <p className="max-w-[min(720px,100%)] whitespace-pre-wrap rounded-xl border border-border bg-surface px-3.5 py-2.5 text-14">{line}</p>
    </div>
  );
}
