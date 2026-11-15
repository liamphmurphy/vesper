"use client";

import { runCost } from "@/lib/format";
import Link from "next/link";
import { useState } from "react";
import type { Approval, Run, Ticket } from "@/lib/api/client";
import { useControlRun, useDecideApproval } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { compact, duration } from "@/lib/format";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, TextInput } from "@/components/ui/primitives";
import { AgentOrPersonaAvatar } from "../_components/ticket-row";
import { Stat } from "@/components/domain/data";
import { MonoChip, SmallPill, type PillTone } from "@/components/domain/labels";
import { DispatchDialog } from "@/components/domain/dispatch-dialog";

const ENDED: Array<Run["state"]> = ["completed", "failed", "cancelled"];

/** An assigned Ready ticket with no live run waits for a person to dispatch it (§6.6). */
export function needsDispatch(t: Ticket) {
  return !!t.assignee && t.status === "todo" && (!t.run || ENDED.includes(t.run.state));
}

/** "Pike is assigned and waiting for dispatch" (dispatch.html). Amber: a person acts. */
export function DispatchBanner({ t }: { t: Ticket }) {
  const [open, setOpen] = useState(false);
  if (!t.assignee) return null;
  const again = t.run && ENDED.includes(t.run.state);
  const blockers=t.blocked_by.filter(d => d.status !== "done");
  return (
    <>
      <Banner
        lead={<AgentOrPersonaAvatar agent={t.assignee} size="md" />}
        title={blockers.length ? `Queues behind ${blockers.map(d => d.key).join(", ")}` : `${t.assignee.name} is assigned and waiting for dispatch`}
        actions={
          <Button variant="approve" disabled={t.project.archived} onClick={() => setOpen(true)}>
            Review &amp; dispatch…
          </Button>
        }
      >
        {blockers.length ? "You can dispatch now: the run queues and starts on its own once the blocker tickets are Done." : again
          ? `The last run ${t.run!.state}. Dispatch again to start a new run.`
          : "Assigning doesn't start work. Review what the run will get, then dispatch it."}
      </Banner>
      {open && <DispatchDialog keys={[t.key]} open onOpenChange={setOpen} />}
    </>
  );
}

export const RUN_STATE: Record<Run["state"], { tone: PillTone; label: string }> = {
  queued: { tone: "neutral", label: "Queued" },
  starting: { tone: "neutral", label: "Starting" },
  running: { tone: "done", label: "Running" },
  waiting: { tone: "human", label: "Waiting" },
  waiting_for_quota: { tone: "neutral", label: "Waiting for quota" },
  paused: { tone: "human", label: "Paused" },
  blocked: { tone: "blocked", label: "Blocked" },
  completed: { tone: "review", label: "Completed" },
  failed: { tone: "blocked", label: "Failed" },
  cancelled: { tone: "neutral", label: "Cancelled" },
};

/**
 * Approval banner (DESIGN.md §4): the exact action, its risk, and what will
 * run for brokered scopes. Amber because a person must act.
 */
export function ApprovalBanner({ t, ap, expanded = false }: { t: Ticket; ap: Approval; expanded?: boolean }) {
  const decide = useDecideApproval(t.key);
  const [showAction, setShowAction] = useState(expanded);
  const [note, setNote] = useState("");
  const send = (decision: "approve" | "deny") => decide.mutate({ id: ap.id, decision, note: note.trim() || undefined });

  return (
    <div className="flex flex-col gap-2">
      <Banner
        lead={<AgentOrPersonaAvatar agent={ap.agent} size="md" />}
        title={`${ap.agent.name} is waiting for your approval`}
        actions={
          <>
            <Button variant="approve-outline" disabled={decide.isPending} onClick={() => send("deny")}>
              Deny
            </Button>
            {ap.action_preview && (
              <Button variant="outline" onClick={() => setShowAction((v) => !v)} aria-expanded={showAction}>
                {showAction ? "Hide action" : "View action"}
              </Button>
            )}
            <Button variant="approve" disabled={decide.isPending} onClick={() => send("approve")}>
              Approve &amp; continue
            </Button>
          </>
        }
      >
        <span className="text-fg-2">
          <MonoChip>{ap.scope}</MonoChip> {ap.action_summary}
          {ap.risk_summary && <span className="text-fg-tertiary"> · {ap.risk_summary}</span>}
        </span>
      </Banner>
      {(showAction || decide.isError) && (
        <div className="flex flex-col gap-2 rounded-xl border border-border bg-surface p-3">
          {showAction && ap.action_preview && (
            <>
              <span className="text-12 text-fg-tertiary">
                {ap.brokered ? "Vesper runs exactly this after you approve; the agent never sees the credential." : "Requested action"}
              </span>
              <pre className="max-h-64 overflow-auto rounded-lg bg-surface-sunken p-3 font-mono text-12 leading-relaxed text-fg-2">{ap.action_preview}</pre>
            </>
          )}
          <label className="flex items-center gap-2 text-12 text-fg-tertiary">
            Note to {ap.agent.name}
            <TextInput value={note} onChange={(e) => setNote(e.target.value)} placeholder="Optional; sent with your decision" className="flex-1" />
          </label>
          {decide.isError && <span role="alert" className="text-12 text-pill-blocked-fg">{decide.error.message}</span>}
        </div>
      )}
    </div>
  );
}

/** Agent run card in the properties panel (ticket-detail.html). */
export function RunCard({ t, run }: { t: Ticket; run: Run }) {
  const control = useControlRun(t.key);
  const st = RUN_STATE[run.state];
  const live = !["completed", "failed", "cancelled"].includes(run.state);
  return (
    <section aria-label="Agent run" className="flex flex-col gap-3 rounded-xl border border-border bg-surface p-3.5">
      <div className="flex items-center gap-2.5">
        <AgentOrPersonaAvatar agent={run.agent} size="md" />
        <div className="flex min-w-0 flex-1 flex-col leading-tight">
          <span className="font-semibold">{run.agent.name}</span>
          <span className="truncate font-mono text-11 text-fg-tertiary">
            {run.model} · {run.harness}
            {run.mode === "unmanaged" && " · unmanaged"}
          </span>
        </div>
        <SmallPill tone={st.tone}>{st.label}</SmallPill>
      </div>
      {run.state === "queued" && (
        <p className="text-12 text-fg-secondary">Dispatched{run.dispatched_by && ` by ${run.dispatched_by.name}`}. Starts when a runner slot is free.</p>
      )}
      {run.state === "waiting" && run.wait_reason === "human_reply" && (
        <p className="text-12 text-pill-human-fg">Waiting for a reply. Mention @{run.agent.handle} in a comment to resume.</p>
      )}
      {run.state === "waiting" && run.wait_reason === "mockup_review" && (
        <p className="text-12 text-pill-human-fg">Waiting for mockup review. The run resumes once a person reviews the mockup.</p>
      )}
      <div className="grid grid-cols-2 gap-3">
        <Stat label="Run time" value={duration(run.started_at, run.ended_at)} />
        <Stat label="Tool calls" value={run.tool_calls} />
        <Stat label="Tokens" value={compact(run.input_tokens + run.output_tokens)} />
        <Stat label="Spend" value={runCost(run.cost_usd, run.cost_source)} />
      </div>
      {(run.scopes.length > 0 || run.approval_scopes.length > 0) && (
        <div className="flex flex-col gap-1.5 border-t border-border-subtle pt-3">
          <span className="text-12 text-fg-tertiary">Permissions</span>
          <div className="flex flex-wrap gap-1">
            {run.scopes.map((s) => (
              <MonoChip key={s} variant="outline">{s}</MonoChip>
            ))}
            {run.approval_scopes.map((s) => (
              <span key={s} className="rounded-[5px] bg-pill-human-bg px-[7px] py-0.5 font-mono text-11 text-pill-human-fg">
                {s} · approval
              </span>
            ))}
          </div>
        </div>
      )}
      {run.outcome && <p className="whitespace-pre-line text-12 text-fg-secondary">{run.outcome}</p>}
      {run.mode === "managed" && (
        <Link href={`/runs/${run.id}`} className="flex items-center gap-1.5 text-12 text-accent hover:underline">
          <Icon name="terminal" size={13} /> View run log
        </Link>
      )}
      {live && (
        <div className="grid grid-cols-2 gap-2">
          {run.state === "paused" || run.state === "waiting_for_quota" ? (
            <Button variant="outline" icon="play" className="justify-center" onClick={() => control.mutate({ id: run.id, action: "resume" })}>
              {run.state === "paused" ? "Resume" : "Try now"}
            </Button>
          ) : (
            <Button variant="outline" icon="pause" className="justify-center" onClick={() => control.mutate({ id: run.id, action: "pause" })}>
              Pause agent
            </Button>
          )}
          <Button variant="outline" className="justify-center text-pill-blocked-fg" onClick={() => control.mutate({ id: run.id, action: "cancel" })}>
            Cancel run
          </Button>
        </div>
      )}
      {control.isError && <span role="alert" className="text-12 text-pill-blocked-fg">{control.error.message}</span>}
    </section>
  );
}

function StepGlyph({ state }: { state: Run["plan"][number]["state"] }) {
  if (state === "done") {
    return (
      <span aria-label="Done" className="grid size-4 place-items-center rounded-full bg-state-done text-on-accent">
        <Icon name="check" size={10} strokeWidth={2.4} />
      </span>
    );
  }
  if (state === "current")
    return <span aria-label="Current" className="size-4 rounded-full border-[1.5px] border-state-human" style={{ background: "conic-gradient(var(--state-human) 0 50%, transparent 0)", boxShadow: "inset 0 0 0 2px var(--surface)" }} />;
  if (state === "needs_human") return <span aria-label="Needs a person" className="size-4 rounded-full bg-state-human" />;
  if (state === "failed") return <span aria-label="Failed" className="size-4 rounded-full bg-state-blocked" />;
  return <span aria-label="Pending" className="size-4 rounded-full border-[1.5px] border-state-backlog" />;
}

/** The plan card under "posted an execution plan" (DESIGN.md §4 timeline). */
export function PlanCard({ plan }: { plan: Run["plan"] }) {
  return (
    <ol className="mt-2 flex flex-col gap-1.5 rounded-xl border border-border bg-surface px-4 py-3">
      {plan.map((s) => (
        <li key={s.position} className="flex items-center gap-3 text-13">
          <StepGlyph state={s.state} />
          <span className="w-4 font-mono text-12 text-fg-tertiary">{s.position}</span>
          <span className={cx(s.state === "pending" ? "text-fg-secondary" : "text-fg-2", s.state === "current" && "font-medium text-fg")}>{s.text}</span>
        </li>
      ))}
    </ol>
  );
}
