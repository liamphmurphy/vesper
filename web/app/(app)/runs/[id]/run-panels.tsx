"use client";

import Link from "next/link";
import { useQueryClient } from "@tanstack/react-query";
import { useEffect, useRef, useState, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { useComment, useControlRunById, useDecideRunApproval } from "@/lib/api/hooks";
import { workHref } from "@/lib/run-view";
import { latestQuestion, withMention } from "@/lib/run-question";
import { AgentAvatar } from "@/components/domain/avatars";
import { MonoChip } from "@/components/domain/labels";
import { RUN_ENDED, StatusPill } from "@/components/domain/run-status";
import { Button, ButtonLink } from "@/components/ui/button";
import { Banner, Kbd, TextArea } from "@/components/ui/primitives";
import { shortcutBlocked } from "@/components/shell/shortcuts";
import { confirmAction } from "@/components/ui/confirm";

/** The ActionBox carries this id; the Graph view focuses it from a pending gate. */
export const ACTION_BOX_ID = "run-action-box";

type Run = Schemas["Run"];
type RunDetail = Schemas["RunDetail"];

/** Cancel always asks first: it ends the run and discards its workspace session. */
export function confirmCancel(agent: string) {
  return confirmAction({ title: `Cancel ${agent}'s run?`, body: "It stops now and can't be resumed.", confirmLabel: "Cancel run", cancelLabel: "Keep running" });
}

/** Sends a reply to a run waiting on `human_reply`: a ticket comment mentioning the agent. */
export function useReply(run: Run, lastSeq: number) {
  const qc = useQueryClient();
  const comment = useComment(run.ticket_key);
  const [body, setBody] = useState("");
  const [sentAt, setSentAt] = useState<number | null>(null);
  const sent = sentAt === lastSeq;
  const submit = () => {
    if (!body.trim() || comment.isPending) return;
    comment.mutate(
      { body_md: withMention(body, run.agent.handle) },
      {
        onSuccess: () => {
          setBody("");
          setSentAt(lastSeq);
        },
        onSettled: () => qc.invalidateQueries({ queryKey: ["runs", run.id] }),
      },
    );
  };
  return { comment, body, setBody, sent, again: () => setSentAt(null), submit };
}

/** Whether the run waits for a reply that the run page itself sends (ticket runs; plans and chats reply in place). */
export function waitsForReply(run: Run) {
  return run.state === "waiting" && run.wait_reason === "human_reply" && run.purpose !== "planning" && run.purpose !== "chat";
}

/** Chat-style prompt for a run waiting on `human_reply`; replies go out as a ticket comment mentioning the agent. */
function ReplyBox({ run, question, lastSeq }: { run: Run; question: string | null; lastSeq: number }) {
  const { comment, body, setBody, sent, again, submit } = useReply(run, lastSeq);
  return (
    <>
      <p className="text-12 font-medium text-pill-human-fg">{run.agent.name} is waiting for your reply</p>
      {question && <p className="max-h-40 overflow-y-auto whitespace-pre-wrap text-14 leading-relaxed text-fg-2">{question}</p>}
      {sent ? (
        <p role="status" className="flex items-center gap-3 text-13 text-fg-secondary">
          Sent. Resuming {run.agent.name}…
          <Button variant="outline" onClick={again}>Reply again</Button>
        </p>
      ) : (
        <>
          <label className="sr-only" htmlFor="run-reply">Reply to {run.agent.name}</label>
          <TextArea
            id="run-reply"
            value={body}
            rows={3}
            placeholder={`Reply to ${run.agent.name}`}
            onChange={(e) => setBody(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
                e.preventDefault();
                submit();
              }
            }}
          />
          {comment.isError && (
            <Banner tone="blocked" title="Couldn't send the reply">
              {comment.error.message}
            </Banner>
          )}
          <div className="flex items-center justify-end gap-3">
            <span className="text-12 text-fg-tertiary pointer-coarse:hidden">
              <kbd className="font-mono">⌘↵</kbd> to send
            </span>
            <Button variant="approve" disabled={!body.trim() || comment.isPending} onClick={submit}>
              {comment.isPending ? "Sending…" : "Send"}
            </Button>
          </div>
        </>
      )}
    </>
  );
}

/**
 * The pending approval: Approve, Approve all … for this run (when the run asks
 * for more than one), or Deny… with an optional reason. With `keys`, A, ⇧A
 * and D decide from the keyboard while focus isn't in a field.
 */
export function ApprovalBox({ run, approvals: open, keys, onDecided }: { run: Run; approvals: Schemas["Approval"][]; keys?: boolean; onDecided?: () => void }) {
  const decide = useDecideRunApproval(run.id);
  // Decided here but not yet gone from the refetched run: hidden, so a quick second A acts on the next one.
  const [decided, setDecided] = useState<ReadonlySet<string>>(new Set());
  const approvals = open.filter((a) => !decided.has(a.id));
  const markDecided = (id: string) => setDecided((d) => new Set(d).add(id));
  const [note, setNote] = useState("");
  const [denying, setDenying] = useState(false);
  const [more, setMore] = useState(false);
  const [busy, setBusy] = useState(false);
  const noteRef = useRef<HTMLTextAreaElement>(null);
  const approval = approvals[0];
  const preview = approval?.action_preview ?? "";
  const long = preview.length > 400 || preview.split("\n").length > 6;
  const shown = more || !long ? preview : preview.split("\n").slice(0, 6).join("\n").slice(0, 400);
  const pending = decide.isPending || busy;
  const go = (decision: "approve" | "deny") => {
    if (pending || !approval) return;
    decide.mutate({ id: approval.id, decision, note: decision === "deny" ? note.trim() || undefined : undefined }, {
      onSuccess: () => {
        markDecided(approval.id);
        setNote("");
        setDenying(false);
        onDecided?.();
      },
    });
  };
  /** No server call grants a scope for the rest of a run, so this approves every request the run has open now. */
  const approveAll = async () => {
    if (pending || approvals.length < 2) return;
    if (!await confirmAction({ title: `Approve all ${approvals.length} requests from ${run.agent.name}?`, body: "Each one is approved for this run only.", confirmLabel: "Approve all", tone: "neutral" })) return;
    setBusy(true);
    let failed = false;
    // Keep going past one that fails (say, decided elsewhere meanwhile); decide.error shows the last failure.
    for (const a of approvals) {
      try {
        await decide.mutateAsync({ id: a.id, decision: "approve" });
        markDecided(a.id);
      } catch {
        failed = true;
      }
    }
    setBusy(false);
    if (!failed) onDecided?.();
  };
  const startDeny = () => {
    setDenying(true);
    requestAnimationFrame(() => noteRef.current?.focus());
  };
  // Re-subscribed each render, so the keys always act on the current approval and note.
  useEffect(() => {
    if (!keys) return;
    const onKey = (e: KeyboardEvent) => {
      if (shortcutBlocked(e)) return;
      const k = e.key.toLowerCase();
      if (k === "a" && e.shiftKey) void approveAll();
      else if (k === "a") go("approve");
      else if (k === "d" && !e.shiftKey) startDeny();
      else return;
      e.preventDefault();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  if (!approval) return null;
  return (
    <>
      <p className="flex flex-wrap items-center gap-2 text-12 font-medium text-pill-human-fg">
        {run.agent.name} needs a decision <MonoChip>{approval.scope}</MonoChip>
        {approvals.length > 1 && <span className="font-normal text-fg-tertiary">1 of {approvals.length}</span>}
      </p>
      <p className="text-14 font-medium text-fg">{approval.action_summary}</p>
      {approval.risk_summary && <p className="text-13 text-fg-secondary">{approval.risk_summary}</p>}
      {preview && (
        <div>
          <pre className="overflow-x-auto whitespace-pre-wrap rounded-md border border-border-subtle bg-surface-sunken px-3 py-2 font-mono text-12 leading-relaxed text-fg-2">{shown}{long && !more ? "…" : ""}</pre>
          {long && (
            <button type="button" aria-expanded={more} onClick={() => setMore(!more)} className="mt-1 text-12 text-accent hover:underline">
              {more ? "less" : "more"}
            </button>
          )}
        </div>
      )}
      {denying && (
        <form
          className="flex flex-col gap-2"
          onSubmit={(e) => {
            e.preventDefault();
            go("deny");
          }}
        >
          <TextArea
            ref={noteRef}
            rows={2}
            aria-label={`Reason for denying, sent to ${run.agent.name} (optional)`}
            placeholder={`Why not? (optional, sent to ${run.agent.name})`}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                go("deny");
              } else if (e.key === "Escape") {
                setDenying(false);
              }
            }}
          />
          <div className="flex items-center justify-end gap-2">
            <Button variant="ghost" onClick={() => setDenying(false)}>Cancel</Button>
            <Button type="submit" variant="outline" disabled={pending}>Deny</Button>
          </div>
        </form>
      )}
      {decide.isError && (
        <Banner tone="blocked" title="Couldn't record the decision">
          {decide.error.message}
        </Banner>
      )}
      {!denying && (
        <div className="flex flex-wrap items-center justify-end gap-2">
          {keys && (
            <span className="mr-auto flex items-center gap-2 text-12 text-fg-tertiary pointer-coarse:hidden">
              <span><Kbd>A</Kbd> approve</span>
              {approvals.length > 1 && <span><Kbd>⇧A</Kbd> all</span>}
              <span><Kbd>D</Kbd> deny</span>
            </span>
          )}
          <Button variant="outline" disabled={pending} onClick={startDeny}>Deny…</Button>
          {approvals.length > 1 && (
            <Button variant="approve-outline" disabled={pending} onClick={approveAll}>Approve all {approvals.length} for this run</Button>
          )}
          <Button variant="approve" disabled={pending} onClick={() => go("approve")}>
            {pending ? "Saving…" : "Approve"}
          </Button>
        </div>
      )}
    </>
  );
}

/**
 * What the run waits for and how to unblock it, inline under the header. `compact` (the
 * compact run detail) shows it inside the log and leaves replies to the pinned ReplyComposer.
 */
export function ActionBox({ d, compact, inThread, keys, onDecided }: { d: RunDetail; compact?: boolean; inThread?: boolean; keys?: boolean; onDecided?: () => void }) {
  const run = d.run;
  const control = useControlRunById(run.id);
  const cancel = (
    <Button
      variant="outline"
      icon="x"
      className="text-pill-blocked-fg"
      disabled={control.isPending}
      onClick={async () => { if (await confirmCancel(run.agent.name)) control.mutate("cancel"); }}
    >
      Cancel run
    </Button>
  );
  const pending = d.approvals.filter((a) => a.state === "pending");
  const liveChildren = d.child_runs.filter((c) => !RUN_ENDED.includes(c.state));
  let body: ReactNode = null;
  if (run.state === "queued") {
    body = (
      <div className="flex items-center justify-between gap-3">
        <p className="text-13 text-fg-2">Waiting for a runner slot. It starts when one is free.</p>
        {cancel}
      </div>
    );
  } else if (run.state === "paused") {
    body = (
      <div className="flex items-center justify-between gap-3">
        <p className="text-13 text-fg-2"><span className="font-medium text-pill-human-fg">Paused.</span> Nothing runs until it is resumed.</p>
        <span className="flex gap-2">
          <Button variant="approve" icon="play" disabled={control.isPending} onClick={() => control.mutate("resume")}>Resume</Button>
          {cancel}
        </span>
      </div>
    );
  } else if (run.state === "waiting_for_quota") {
    const at = run.hold_until ? new Date(run.hold_until).toLocaleString() : "soon";
    body = (
      <div className="flex items-center justify-between gap-3">
        <p className="text-13 text-fg-2">
          <span className="font-medium text-fg">Out of provider usage.</span>{" "}
          {run.hold_reset_known ? `It resumes after the limit resets at ${at}.` : `The reset time is unknown, so it tries again at ${at}.`}
        </p>
        <span className="flex gap-2">
          <Button variant="approve" icon="play" disabled={control.isPending} onClick={() => control.mutate("resume")}>Try now</Button>
          {cancel}
        </span>
      </div>
    );
  } else if (run.state === "waiting") {
    switch (run.wait_reason) {
      case "approval":
        body = pending.length ? <ApprovalBox run={run} approvals={pending} keys={keys} onDecided={onDecided} /> : <p className="text-13 text-fg-2">Waiting for an approval decision.</p>;
        break;
      case "human_reply":
        if (run.purpose === "planning") {
          body = <p className="text-13 text-fg-2">{run.agent.name} is waiting for your reply. <Link className="text-accent hover:underline" href={workHref(run) ?? "/plans"}>Open the plan</Link></p>;
        } else if (run.purpose === "chat") {
          body = <p className="text-13 text-fg-2">{run.agent.name} is waiting for your reply. <Link className="text-accent hover:underline" href={workHref(run) ?? "/chat"}>Open chat</Link></p>;
        } else if (!compact && !inThread) {
          body = <ReplyBox run={run} question={latestQuestion(d.events)} lastSeq={d.events.at(-1)?.seq ?? 0} />;
        }
        break;
      case "mockup_review":
        body = (
          <div className="flex items-center justify-between gap-3">
            <p className="text-13 text-fg-2">Waiting for a mockup review. The next turn starts when a person reviews it.</p>
            <span className="flex gap-2">
              {run.ticket_key && <ButtonLink variant="primary" href={`/tickets/${encodeURIComponent(run.ticket_key)}`}>Review mockup</ButtonLink>}
              {cancel}
            </span>
          </div>
        );
        break;
      case "delegation":
        body = (
          <div className="flex flex-col gap-2">
            <p className="text-13 font-medium text-fg-2">
              Waiting for {liveChildren.length} sub agent{liveChildren.length === 1 ? "" : "s"}
            </p>
            <ul className="flex flex-col gap-1">
              {liveChildren.map((c) => (
                <li key={c.id} className="flex items-center gap-2 text-13">
                  <AgentAvatar name={c.agent.name} colorIndex={c.agent.color_index} label={false} />
                  <Link href={`/runs/${c.id}`} className="font-medium text-accent hover:underline">{c.agent.name} ↗</Link>
                  <StatusPill run={c} />
                </li>
              ))}
            </ul>
            <div>{cancel}</div>
          </div>
        );
        break;
      default:
        body = (
          <div className="flex items-center justify-between gap-3">
            <p className="text-13 text-fg-2">Waiting for {run.agent.name}.</p>
            {cancel}
          </div>
        );
    }
  }
  if (!body) return null;
  return (
    <div className={compact ? "px-3 py-3" : inThread ? "py-2" : "border-b border-border-subtle px-6 py-3"}>
      <div id={ACTION_BOX_ID} tabIndex={-1} aria-label="Needs attention" role="group" className="flex flex-col gap-2 rounded-xl border border-state-human/40 bg-surface p-3.5">
        {body}
        {control.isError && (
          <Banner tone="blocked" title="Couldn't change the run">{control.error.message}</Banner>
        )}
      </div>
    </div>
  );
}

/** The compact run detail's reply composer, pinned under the log while the run waits for a reply. */
export function ReplyComposer({ run, lastSeq }: { run: Run; lastSeq: number }) {
  const { comment, body, setBody, sent, again, submit } = useReply(run, lastSeq);
  return (
    <form
      aria-label={`Reply to ${run.agent.name}`}
      onSubmit={(e) => {
        e.preventDefault();
        submit();
      }}
      className="flex flex-none flex-col gap-2 border-t border-border-subtle bg-bg px-3 pt-2.5 pb-[max(10px,env(safe-area-inset-bottom))]"
    >
      <p className="text-12 font-medium text-pill-human-fg">{run.agent.name} is waiting for your reply</p>
      {comment.isError && (
        <Banner tone="blocked" title="Couldn't send the reply">
          {comment.error.message}
        </Banner>
      )}
      {sent ? (
        <p role="status" className="flex items-center justify-between gap-3 text-13 text-fg-secondary">
          Sent. Resuming {run.agent.name}…
          <Button variant="outline" className="h-[44px]" onClick={again}>Reply again</Button>
        </p>
      ) : (
        <div className="flex items-end gap-2">
          <label className="sr-only" htmlFor="run-reply-compact">Reply to {run.agent.name}</label>
          <TextArea
            id="run-reply-compact"
            value={body}
            rows={1}
            placeholder={`Reply to ${run.agent.name}`}
            onChange={(e) => setBody(e.target.value)}
            className="max-h-32 min-h-[44px] flex-1 text-16"
          />
          <Button type="submit" variant="approve" className="h-[44px]" disabled={!body.trim() || comment.isPending}>
            {comment.isPending ? "Sending…" : "Send"}
          </Button>
        </div>
      )}
    </form>
  );
}
