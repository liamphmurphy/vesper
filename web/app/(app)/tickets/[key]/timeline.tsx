"use client";

import Link from "next/link";
import { useState, type ReactNode } from "react";
import type { ActivityEvent, Bootstrap, Priority, Run, TicketStatus } from "@/lib/api/client";
import { useComment } from "@/lib/api/hooks";
import { absoluteTime, dueDate, timelineTime } from "@/lib/format";
import { Button } from "@/components/ui/button";
import { TextArea } from "@/components/ui/primitives";
import { HumanAvatar, agentHue } from "@/components/domain/avatars";
import { WorkPersonaAvatar } from "@/components/domain/work-persona-avatar";
import { StatusGlyph } from "@/components/domain/glyphs";
import { Markdown } from "@/components/domain/markdown";
import { PRIORITY_NAME, STATUS_NAME } from "@/components/domain/meta";
import { PlanCard } from "./run-parts";

type Actor = ActivityEvent["actor"];
type P = Record<string, unknown>;
const str = (v: unknown) => (typeof v === "string" ? v : "");

export function ActorAvatar({ actor }: { actor: Actor }) {
  if (actor.type === "agent") {
    return (
      <WorkPersonaAvatar
        agent={{ id: actor.id ?? undefined, name: actor.name, color_index: actor.color_index ?? 0 }}
        size="stack"
      />
    );
  }
  if (actor.type === "system")
    return <span aria-hidden className="grid size-[22px] place-items-center rounded-full bg-selected text-10 text-fg-tertiary">⚙</span>;
  return <HumanAvatar name={actor.name} initials={actor.initials} color={actor.avatar_color} size={22} label={false} />;
}

const B = ({ children }: { children: ReactNode }) => <b className="font-medium text-fg">{children}</b>;

function Time({ iso }: { iso: string }) {
  return (
    <time dateTime={iso} title={absoluteTime(iso)} className="text-fg-tertiary">
      {" · "}
      {timelineTime(iso)}
    </time>
  );
}

function names(list: string[]) {
  return list.map((l, i) => (
    <span key={l}>
      {i > 0 && ", "}
      <B>{l}</B>
    </span>
  ));
}

/** One sentence per verb (server/internal/tracker/activity.go). */
function sentence(e: ActivityEvent, agentColor: (id: string) => number | undefined): ReactNode {
  const p = e.payload as P;
  const agent = () => {
    const ci = agentColor(str(p.agent_id));
    return (
      <b className="font-medium" style={{ color: ci === undefined ? undefined : `var(--agent-${agentHue(ci)})` }}>
        {str(p.agent_name)}
      </b>
    );
  };
  switch (e.verb) {
    case "created":
      return "created the ticket";
    case "status_changed":
      return (
        <>
          moved this from {STATUS_NAME[p.from as TicketStatus] ?? str(p.from)} to{" "}
          <span className="inline-flex items-center gap-1.5 align-middle">
            <StatusGlyph state={p.to as TicketStatus} size={12} label={false} />
            <B>{STATUS_NAME[p.to as TicketStatus] ?? str(p.to)}</B>
          </span>
        </>
      );
    case "priority_changed":
      return (
        <>
          set priority to <B>{PRIORITY_NAME[p.to as Priority] ?? str(p.to)}</B>
        </>
      );
    case "title_changed":
      return <>renamed this from “{str(p.from)}”</>;
    case "description_edited":
      return "edited the description";
    case "assigned":
      return <>assigned this to {agent()}</>;
    case "unassigned":
      return <>unassigned {agent()}</>;
    case "reviewer_set":
      return (
        <>
          set <B>{str(p.user_name)}</B> as reviewer
        </>
      );
    case "reviewer_cleared":
      return "removed the reviewer";
    case "epic_changed":
      return p.epic_name ? (
        <>
          moved this to <B>{str(p.epic_name)}</B>
        </>
      ) : (
        "removed it from its epic"
      );
    case "labels_changed": {
      const added = (p.added as string[]) ?? [];
      const removed = (p.removed as string[]) ?? [];
      return (
        <>
          {added.length > 0 && <>added {names(added)}</>}
          {added.length > 0 && removed.length > 0 && " and "}
          {removed.length > 0 && <>removed {names(removed)}</>}
        </>
      );
    }
    case "estimate_changed":
      // Point estimates carry {to_points, rationale}; legacy notes carry {to}.
      if ("to_points" in p) {
        return p.to_points == null ? (
          "cleared the estimate"
        ) : (
          <>
            estimated <B>{String(p.to_points)} points</B>
            {p.rationale ? <span className="mt-1 block border-l-2 border-border pl-2.5 italic text-fg-secondary">“{str(p.rationale)}”</span> : null}
          </>
        );
      }
      return p.to ? (
        <>
          set the estimate to <B>{str(p.to)}</B>
        </>
      ) : (
        "cleared the estimate"
      );
    case "due_changed":
      return p.to ? (
        <>
          set the due date to <B>{dueDate(str(p.to))}</B>
        </>
      ) : (
        "cleared the due date"
      );
    case "criterion_added":
      return (
        <>
          added a criterion: <span className="text-fg-2">{str(p.text)}</span>
        </>
      );
    case "criterion_checked":
      return (
        <>
          checked off <span className="text-fg-2">{str(p.text)}</span>
        </>
      );
    case "criterion_unchecked":
      return (
        <>
          unchecked <span className="text-fg-2">{str(p.text)}</span>
        </>
      );
    case "criterion_removed":
      return (
        <>
          removed a criterion: <span className="text-fg-2 line-through">{str(p.text)}</span>
        </>
      );
    case "dependencies_changed":
      return <>updated dependencies: {Array.isArray(p.blocked_by) && p.blocked_by.length ? p.blocked_by.join(", ") : "no blockers"}</>;
    case "artifact_attached":
      return (
        <>
          {p.relation === "generated" ? "generated " : "attached "}
          <Link href={`/artifacts/${str(p.artifact_id)}`} className={p.relation === "generated" ? "font-medium text-doc-report hover:underline" : "font-medium text-fg hover:underline"}>
            {str(p.title)}
          </Link>
        </>
      );
    case "artifact_detached":
      return (
        <>
          removed <B>{str(p.title)}</B> from context
        </>
      );
    case "dispatched":
      return <>dispatched this to {agent()}</>;
    case "run_started":
      return p.mode === "unmanaged" ? "started working (unmanaged session)" : p.harness ? <>started working on <code className="inline">{str(p.harness)}</code></> : "started working";
    case "run_failed":
      return (
        <>
          stopped the run: <span className="whitespace-pre-line text-pill-blocked-fg">{str(p.reason)}</span>
        </>
      );
    case "pr_merged":
      return (
        <>
          saw <B>PR #{str(p.number)}</B> merge on GitHub
        </>
      );
    case "pr_closed":
      return (
        <>
          saw <B>PR #{str(p.number)}</B> closed without merging
        </>
      );
    case "plan_posted":
      return "posted an execution plan";
    case "tests_ran": {
      const failed = Number(p.failed ?? 0);
      return (
        <>
          ran the test suite{" "}
          <span className={failed ? "rounded-[5px] bg-pill-blocked-bg px-1.5 font-mono text-12 text-pill-blocked-fg" : "rounded-[5px] bg-pill-done-bg px-1.5 font-mono text-12 text-pill-done-fg"}>
            {Number(p.passed ?? 0)} passed
          </span>{" "}
          <span className="rounded-[5px] border border-track px-1.5 font-mono text-12 text-fg-tertiary">
            {failed} failed{p.duration_s ? ` · ${Math.round(Number(p.duration_s) / 60)}m ${Math.round(Number(p.duration_s) % 60)}s` : ""}
          </span>
        </>
      );
    }
    case "branch_set":
      return (
        <>
          created branch <code className="inline">{str(p.branch)}</code>
        </>
      );
    case "pr_opened":
      return (
        <>
          opened{" "}
          <a href={str(p.url)} target="_blank" rel="noreferrer noopener" className="font-medium text-pill-review-fg hover:underline">
            PR #{String(p.number)}
          </a>
          {p.draft ? " as a draft" : ""}
        </>
      );
    case "approval_requested":
      return (
        <>
          paused and requested approval for <code className="inline">{str(p.scope)}</code>: {str(p.summary)}
        </>
      );
    case "approval_approved":
      return (
        <>
          approved <code className="inline">{str(p.scope)}</code>
          {p.note ? <>: “{str(p.note)}”</> : null}
        </>
      );
    case "approval_denied":
      return (
        <>
          denied <code className="inline">{str(p.scope)}</code>
          {p.note ? <>: “{str(p.note)}”</> : null}
        </>
      );
    case "gated_action_ran":
      return p.ok ? (
        <>
          ran <code className="inline">{str(p.scope)}</code> through Vesper: <span className="text-pill-done-fg">{str(p.summary)}</span>
        </>
      ) : (
        <>
          ran <code className="inline">{str(p.scope)}</code> through Vesper: <span className="text-pill-blocked-fg">{str(p.summary)}</span>
          {p.error ? <span className="block font-mono text-12 text-fg-tertiary">{str(p.error)}</span> : null}
        </>
      );
    case "waiting_for_human":
      return (
        <>
          is waiting for a reply: <span className="text-pill-human-fg">{str(p.reason)}</span>
        </>
      );
    case "delegated":
      return (
        <>
          delegated to <span className="font-medium">{str(p.agent_name)}</span>: {str(p.task)}
        </>
      );
    case "run_paused":
      return "paused the run";
    case "run_resumed":
      return "resumed the run";
    case "run_cancelled":
      return p.reason ? <>stopped the run: {str(p.reason)}</> : "cancelled the run";
    case "run_completed":
      return p.outcome ? <>finished the run: {str(p.outcome)}</> : "finished the run";
    case "mockup_requirement_changed":
      return p.to ? "made an approved UI mockup required" : "no longer requires a UI mockup";
    case "mockup_review_requested":
      return (
        <>
          drafted mockup{" "}
          <Link href={`/artifacts/${str(p.artifact_id)}`} className="font-medium text-doc-mockup hover:underline">
            {str(p.title)}
          </Link>{" "}
          {str(p.version)} and is waiting for a review
        </>
      );
    case "mockup_approved":
    case "mockup_changes_requested": {
      const ok = e.verb === "mockup_approved";
      return (
        <>
          {ok ? "approved" : "requested changes to"} mockup{" "}
          <Link href={`/artifacts/${str(p.artifact_id)}`} className="font-medium text-doc-mockup hover:underline">
            {str(p.title)}
          </Link>{" "}
          {str(p.version)}
          {p.note ? <>: “{str(p.note)}”</> : null}
        </>
      );
    }
    default:
      return <span className="font-mono text-12">{e.verb}</span>;
  }
}

/** "from a chat" when a persona made the change in a conversation (update_ticket, comment_ticket), linking back to it. */
function ViaChat({ e }: { e: ActivityEvent }) {
  const via = (e.payload as P).via as P | undefined;
  const chat = via && str(via.chat_id);
  if (!chat) return null;
  return (
    <>
      {" "}
      <Link href={`/chat/${chat}`} className="text-fg-tertiary hover:text-fg hover:underline">
        from a chat
      </Link>
    </>
  );
}

function CommentBody({ e }: { e: ActivityEvent }) {
  return (
    <div className="flex min-w-0 flex-col gap-1">
      <div className="text-13">
        <B>{e.actor.name}</B>
        <ViaChat e={e} />
        <Time iso={e.created_at} />
      </div>
      <Markdown className="type-reading text-fg-2">{str((e.payload as P).body_md)}</Markdown>
    </div>
  );
}

function Thread({ root, replies, ticketKey }: { root: ActivityEvent; replies: ActivityEvent[]; ticketKey: string }) {
  const [replying, setReplying] = useState(false);
  return (
    <div className="overflow-hidden rounded-xl border border-border bg-surface">
      <div className="px-4 py-3">
        <CommentBody e={root} />
      </div>
      {(replies.length > 0 || replying) && (
        <div className="flex flex-col gap-3 border-t border-border-subtle bg-surface-sunken px-4 py-3">
          {replies.map((r) => (
            <div key={r.id} className="flex gap-2.5">
              <ActorAvatar actor={r.actor} />
              <CommentBody e={r} />
            </div>
          ))}
          {replying && (
            <Composer
              ticketKey={ticketKey}
              parentId={str((root.payload as P).comment_id)}
              placeholder="Reply…"
              autoFocus
              onDone={() => setReplying(false)}
            />
          )}
        </div>
      )}
      {!replying && (
        <div className="border-t border-border-subtle px-2 py-1">
          <Button variant="ghost" className="h-7 text-12 text-fg-tertiary" onClick={() => setReplying(true)}>
            Reply
          </Button>
        </div>
      )}
    </div>
  );
}

export function Composer({
  ticketKey,
  parentId,
  placeholder = "Leave a comment…",
  autoFocus,
  onDone,
}: {
  ticketKey: string;
  parentId?: string;
  placeholder?: string;
  autoFocus?: boolean;
  onDone?: () => void;
}) {
  const [body, setBody] = useState("");
  const comment = useComment(ticketKey);
  const id = `composer-${parentId ?? "root"}`;
  const submit = () => {
    if (!body.trim() || comment.isPending) return;
    comment.mutate(
      { body_md: body, parent_comment_id: parentId },
      {
        onSuccess: () => {
          setBody("");
          onDone?.();
        },
      },
    );
  };
  return (
    <div className="overflow-hidden rounded-xl border border-border bg-surface focus-within:border-border-hover">
      <label className="sr-only" htmlFor={id}>
        {parentId ? "Reply" : "Comment"}
      </label>
      <TextArea
        id={id}
        value={body}
        autoFocus={autoFocus}
        rows={parentId ? 2 : 3}
        placeholder={placeholder}
        onChange={(e) => setBody(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
            e.preventDefault();
            submit();
          }
          if (e.key === "Escape" && onDone) onDone();
        }}
        className="resize-y rounded-none border-0 bg-transparent px-3.5 py-3 focus:border-0"
      />
      <div className="flex flex-wrap items-center justify-end gap-3 px-3 pb-2.5">
        {comment.isError && <span className="mr-auto text-12 text-pill-blocked-fg">{comment.error.message}</span>}
        <span className="text-12 text-fg-tertiary">
          <kbd className="font-mono">⌘↵</kbd> to send
        </span>
        {onDone && (
          <Button variant="ghost" onClick={onDone}>
            Cancel
          </Button>
        )}
        <Button variant="primary" onClick={submit} disabled={!body.trim() || comment.isPending}>
          {parentId ? "Reply" : "Comment"}
        </Button>
      </div>
    </div>
  );
}

/** Activity timeline (DESIGN.md §4): 1px rule at x=11, avatar + one sentence; comments as threads. */
export function Timeline({ events, ticketKey, boot, run }: { events: ActivityEvent[]; ticketKey: string; boot?: Bootstrap; run?: Run }) {
  // The live plan renders under the latest plan_posted event of the latest run.
  const planEvent = run ? [...events].reverse().find((e) => e.verb === "plan_posted" && str((e.payload as P).run_id) === run.id) : undefined;
  const agentColor = (id: string) => boot?.agents.find((a) => a.id === id)?.color_index;
  const replies = new Map<string, ActivityEvent[]>();
  for (const e of events) {
    const parent = str((e.payload as P).parent_comment_id);
    if (e.verb === "commented" && parent) replies.set(parent, [...(replies.get(parent) ?? []), e]);
  }
  const top = events.filter((e) => !(e.verb === "commented" && str((e.payload as P).parent_comment_id)));

  return (
    <ol className="relative flex flex-col gap-4 before:absolute before:bottom-2 before:left-[11px] before:top-2 before:w-px before:bg-border">
      {top.map((e) => (
        <li key={e.id} className="relative flex gap-3">
          <span className="relative z-10 h-fit flex-none rounded-full bg-bg py-0.5">
            <ActorAvatar actor={e.actor} />
          </span>
          {e.verb === "commented" ? (
            <div className="min-w-0 flex-1">
              <Thread root={e} replies={replies.get(str((e.payload as P).comment_id)) ?? []} ticketKey={ticketKey} />
            </div>
          ) : (
            <div className="min-w-0 flex-1 pt-0.5 text-13 text-fg-secondary">
              <p>
                <B>{e.actor.name}</B> {sentence(e, agentColor)}
                <ViaChat e={e} />
                <Time iso={e.created_at} />
              </p>
              {e === planEvent && run && run.plan.length > 0 && <PlanCard plan={run.plan} />}
            </div>
          )}
        </li>
      ))}
    </ol>
  );
}
