"use client";

import Link from "next/link";
import { useEffect, useRef, useState, type ReactNode, type RefObject } from "react";
import type { Schemas } from "@/lib/api/client";
import {
  useComment,
  useControlRunById,
  useDecideApproval,
  useReadInbox,
  useReviewMockup,
  useRunLog,
  useTicket,
} from "@/lib/api/hooks";
import { AgentAvatar } from "@/components/domain/avatars";
import { Button, ButtonLink } from "@/components/ui/button";
import { Kbd, Skeleton, TextArea } from "@/components/ui/primitives";
import { cx } from "@/lib/cx";
import { KIND, waited } from "@/lib/inbox";
import { withMention } from "@/lib/run-question";
import { DispatchBanner } from "../tickets/[key]/run-parts";

type Item = Schemas["InboxItem"];

/** Keyboard actions the selected pane offers; the list's key handler calls them. */
export type PaneActions = {
  approve?: () => void;
  deny?: () => void;
  /** r: focus the reply or note box. */
  focus?: () => void;
  done?: () => void;
};

type PaneProps = {
  item: Item;
  /** Called after each render with the keys this pane handles. */
  register: (actions: PaneActions) => void;
  /** The action was sent: the row shows "Sent" until the live update removes it. */
  onSent: (id: string) => void;
  /** Esc in a text box: back to the list. */
  onLeave: () => void;
};

function Section({ label, children }: { label: ReactNode; children: ReactNode }) {
  return (
    <div className="flex flex-col gap-2">
      <span className="text-12 font-medium text-fg-secondary">{label}</span>
      {children}
    </div>
  );
}

function Quote({ tone = "human", children }: { tone?: "human" | "blocked"; children: ReactNode }) {
  return (
    <div
      className="whitespace-pre-wrap break-words rounded-[10px] border border-border bg-surface px-4 py-3 text-14 leading-relaxed text-fg-2"
      style={{
        borderLeft: `3px solid var(${tone === "human" ? "--state-human" : "--state-blocked"})`,
      }}
    >
      {children}
    </div>
  );
}

function Hint({ children }: { children: ReactNode }) {
  return <p className="text-12 text-fg-tertiary">{children}</p>;
}

function Note({
  id,
  label,
  value,
  onChange,
  placeholder,
  onSubmit,
  onLeave,
  inputRef,
}: {
  id: string;
  label: ReactNode;
  value: string;
  onChange: (v: string) => void;
  placeholder: string;
  onSubmit?: () => void;
  onLeave: () => void;
  inputRef: RefObject<HTMLTextAreaElement | null>;
}) {
  return (
    <Section label={<label htmlFor={id}>{label}</label>}>
      <TextArea
        id={id}
        ref={inputRef}
        rows={3}
        value={value}
        placeholder={placeholder}
        onChange={(e) => onChange(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey) && onSubmit) {
            e.preventDefault();
            onSubmit();
          }
          if (e.key === "Escape") {
            e.preventDefault();
            e.currentTarget.blur();
            onLeave();
          }
        }}
      />
    </Section>
  );
}

function Actions({ children }: { children: ReactNode }) {
  return <div className="flex flex-wrap items-center justify-end gap-2 [&>:first-child]:mr-auto">{children}</div>;
}

function DoneButton({ onClick, disabled }: { onClick: () => void; disabled?: boolean }) {
  return (
    <Button variant="outline" onClick={onClick} disabled={disabled}>
      Mark done <Kbd>E</Kbd>
    </Button>
  );
}

function Failure({ error }: { error?: Error | null }) {
  return error ? (
    <p role="alert" className="text-12 text-pill-blocked-fg">
      {error.message}
    </p>
  ) : null;
}

const HEADLINE: Record<string, (agent: string) => string> = {
  approval: (a) => `${a} is waiting for your approval`,
  question: (a) => `${a} is asking you`,
  blocked: (a) => `${a}’s run failed`,
  stalled: (a) => `${a} has been quiet`,
  mockup: (a) => `${a} needs a mockup decision`,
  planning: (a) => `${a} drafted tickets`,
  review: () => "Ready for your review",
  dispatch: (a) => `${a} is waiting for dispatch`,
  mention: (a) => `${a} mentioned you`,
  suggestion: (a) => `${a} suggested a wiki edit`,
};

export function DetailPane(props: PaneProps) {
  const { item } = props;
  const agent = item.agent;
  const kind = KIND[item.kind] ?? { label: item.kind, tone: "info" };
  const ticketHref = item.ticket_key ? `/tickets/${item.ticket_key}` : item.href;
  return (
    <aside
      aria-label={`${kind.label} details`}
      className="flex min-w-0 flex-[1_1_380px] flex-col gap-5 overflow-y-auto border-l border-border bg-panel p-6"
    >
      <div className="flex items-center gap-2">
        <span className="min-w-0 flex-1 truncate text-10 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">
          {[kind.label, item.ticket_key, item.project || "Workspace"].filter(Boolean).join(" · ")}
        </span>
        <Link href={ticketHref} className="flex-none text-12 text-accent hover:underline">
          {item.ticket_key ? "Open ticket ↗" : "Open ↗"}
        </Link>
      </div>
      <div className="flex items-center gap-3">
        {agent && <AgentAvatar name={agent.name} colorIndex={agent.color_index} size="md" label={false} />}
        <div className="flex min-w-0 flex-col gap-0.5">
          <h2
            className={cx(
              "type-heading",
              kind.tone === "blocked" ? "text-pill-blocked-fg" : kind.tone === "human" ? "text-pill-human-fg" : "text-fg",
            )}
          >
            {(HEADLINE[item.kind] ?? (() => item.title))(agent?.name ?? "An agent")}
          </h2>
          <span className="text-12 text-fg-tertiary">
            {item.kind === "stalled" ? "No activity for " : item.resolved || item.read ? "Changed " : "Waiting "}
            {waited(item.created_at)} · {item.title}
          </span>
        </div>
      </div>
      {item.kind === "approval" ? (
        <ApprovalPane {...props} />
      ) : item.kind === "question" ? (
        <QuestionPane {...props} />
      ) : item.kind === "blocked" || item.kind === "stalled" ? (
        <RunPane {...props} />
      ) : item.kind === "mockup" ? (
        <MockupPane {...props} />
      ) : (
        <InfoPane {...props} />
      )}
    </aside>
  );
}

function useDone(item: Item, onSent: (id: string) => void) {
  const read = useReadInbox();
  const open = !item.resolved && !item.read;
  return {
    read,
    open,
    done: () => {
      if (!open || read.isPending) return;
      read.mutate(item.id, { onSuccess: () => onSent(item.id) });
    },
  };
}

function ApprovalPane({ item, register, onSent, onLeave }: PaneProps) {
  const isTicket = !!item.ticket_key;
  const ticket = useTicket(item.ticket_key);
  const run = useRunLog(item.run_id ?? "", !isTicket && !!item.run_id);
  const decide = useDecideApproval(item.ticket_key);
  const { done, open, read } = useDone(item, onSent);
  const [note, setNote] = useState("");
  const noteRef = useRef<HTMLTextAreaElement>(null);
  const ap = (isTicket ? ticket.data?.approvals : run.data?.approvals)?.find((a) => `approval:${a.id}` === item.id);
  const live = open && !!ap && ap.state === "pending";
  const send = (decision: "approve" | "deny") => {
    if (!live || decide.isPending) return;
    decide.mutate({ id: ap.id, decision, note: note.trim() || undefined }, { onSuccess: () => onSent(item.id) });
  };
  useEffect(() => {
    register({ approve: () => send("approve"), deny: () => send("deny"), focus: () => noteRef.current?.focus(), done });
  });
  const source = isTicket ? ticket : run;
  if (source.isPending) return <Skeleton className="h-40" />;
  if (source.isError) return <Failure error={source.error} />;
  return (
    <>
      <Section label="Exact action">
        <div className="flex flex-col gap-1.5 rounded-[10px] border border-border bg-surface px-4 py-3 text-13 text-fg-2">
          <span>
            <span className="font-mono text-12 text-fg-tertiary">{ap?.scope}</span> {ap?.action_summary ?? item.summary}
          </span>
          {ap?.action_preview && (
            <pre className="max-h-56 overflow-auto rounded-md bg-surface-sunken p-2.5 font-mono text-12 leading-relaxed">{ap.action_preview}</pre>
          )}
        </div>
      </Section>
      {ap?.risk_summary && (
        <Section label={`Risk summary from ${ap.agent.name}`}>
          <p className="text-13 text-fg-2">{ap.risk_summary}</p>
        </Section>
      )}
      {live ? (
        <>
          <Note
            id="inbox-note"
            label={`Note to ${ap.agent.name} (optional)`}
            value={note}
            onChange={setNote}
            placeholder="Added to the resumed turn, e.g. “run it after 18:00”."
            onSubmit={() => send("approve")}
            onLeave={onLeave}
            inputRef={noteRef}
          />
          <Actions>
            <DoneButton onClick={done} disabled={read.isPending} />
            <Button variant="approve-outline" disabled={decide.isPending} onClick={() => send("deny")}>
              Deny <Kbd>D</Kbd>
            </Button>
            <Button variant="approve" disabled={decide.isPending} onClick={() => send("approve")}>
              Approve &amp; continue <Kbd className="border-transparent text-inherit">A</Kbd>
            </Button>
          </Actions>
          <Hint>
            {ap.chat_id ? `Approving lets ${ap.agent.name} run this tool right away.` : `Approving resumes ${ap.agent.name} with your note.`}
          </Hint>
        </>
      ) : (
        <Hint>{ap && ap.state !== "pending" ? `This request was ${ap.state}.` : "This item is done."}</Hint>
      )}
      <Failure error={decide.error ?? read.error} />
    </>
  );
}

function QuestionPane({ item, register, onSent, onLeave }: PaneProps) {
  const comment = useComment(item.ticket_key);
  const { done, read } = useDone(item, onSent);
  const [body, setBody] = useState("");
  const replyRef = useRef<HTMLTextAreaElement>(null);
  const handle = item.agent?.handle ?? "";
  const send = () => {
    if (!body.trim() || comment.isPending) return;
    comment.mutate(
      { body_md: handle ? withMention(body, handle) : body.trim() },
      {
        onSuccess: () => {
          setBody("");
          onSent(item.id);
        },
      },
    );
  };
  useEffect(() => {
    register({ focus: () => replyRef.current?.focus(), done });
  });
  return (
    <>
      <Section label="Question">
        <Quote>{item.summary}</Quote>
      </Section>
      <Note
        id="inbox-reply"
        label={
          <>
            Reply to <span className="font-mono">@{handle}</span>
          </>
        }
        value={body}
        onChange={setBody}
        placeholder="Your answer"
        onSubmit={send}
        onLeave={onLeave}
        inputRef={replyRef}
      />
      <Hint>
        Posts a comment that mentions @{handle} on {item.ticket_key}. The run resumes with your reply.
      </Hint>
      <Actions>
        <DoneButton onClick={done} disabled={read.isPending} />
        {item.run_id && (
          <ButtonLink href={`/runs/${item.run_id}`} variant="outline">
            Open run
          </ButtonLink>
        )}
        <Button variant="primary" disabled={!body.trim() || comment.isPending} onClick={send}>
          Send reply <Kbd className="border-transparent text-inherit">⌘↵</Kbd>
        </Button>
      </Actions>
      <Failure error={comment.error ?? read.error} />
    </>
  );
}

function RunPane({ item, register, onSent }: PaneProps) {
  const control = useControlRunById(item.run_id ?? "");
  const { done, read } = useDone(item, onSent);
  const [confirm, setConfirm] = useState(false);
  const stalled = item.kind === "stalled";
  useEffect(() => {
    register({ done });
  });
  const act = (action: "retry" | "cancel") =>
    control.mutate(action, {
      onSuccess: () => {
        setConfirm(false);
        onSent(item.id);
      },
    });
  return (
    <>
      {stalled ? (
        <Section label="Last activity">
          <Quote tone="blocked">No events for {waited(item.created_at)}.</Quote>
          <Hint>
            A running run counts as stalled after 30 minutes without an event; one long, quiet command can look the
            same, so check the run log first. Cancel stops the harness and keeps the branch, so Retry can pick up from
            there.
          </Hint>
        </Section>
      ) : (
        <Section label="Error">
          <Quote tone="blocked">{item.summary}</Quote>
          <Hint>Retry starts a new run for the same agent and branch.</Hint>
        </Section>
      )}
      {confirm ? (
        <div role="group" aria-label="Confirm cancel" className="flex flex-wrap items-center gap-2 rounded-[10px] border border-border bg-surface px-3 py-2.5 text-13">
          <span className="mr-auto text-fg-2">Stop {item.agent?.name ?? "this"}’s run?</span>
          <Button variant="outline" onClick={() => setConfirm(false)}>
            Keep running
          </Button>
          <Button variant="outline" className="text-pill-blocked-fg" disabled={control.isPending} onClick={() => act("cancel")}>
            Stop run
          </Button>
        </div>
      ) : (
        <Actions>
          <DoneButton onClick={done} disabled={read.isPending} />
          {item.run_id && (
            <ButtonLink href={`/runs/${item.run_id}`} variant="outline">
              Open run log
            </ButtonLink>
          )}
          {item.run_id &&
            (stalled ? (
              <Button variant="outline" className="text-pill-blocked-fg" onClick={() => setConfirm(true)}>
                Cancel run
              </Button>
            ) : (
              <Button variant="primary" disabled={control.isPending} onClick={() => act("retry")}>
                Retry run
              </Button>
            ))}
        </Actions>
      )}
      <Hint>{stalled ? "The item leaves Inbox after the run stops." : "The item leaves Inbox once the new run starts."}</Hint>
      <Failure error={control.error ?? read.error} />
    </>
  );
}

function MockupPane({ item, register, onSent, onLeave }: PaneProps) {
  const review = useReviewMockup(item.artifact_id ?? "");
  const { done, open, read } = useDone(item, onSent);
  const [note, setNote] = useState("");
  const noteRef = useRef<HTMLTextAreaElement>(null);
  const versionId = item.id.slice("mockup:".length);
  const decide = (decision: "approved" | "changes_requested") => {
    if (!open || !item.artifact_id || review.isPending) return;
    if (decision === "changes_requested" && !note.trim()) {
      noteRef.current?.focus();
      return;
    }
    review.mutate({ versionId, decision, note: note.trim() || undefined }, { onSuccess: () => onSent(item.id) });
  };
  useEffect(() => {
    register({ approve: () => decide("approved"), focus: () => noteRef.current?.focus(), done });
  });
  return (
    <>
      <Quote>{item.summary}</Quote>
      {item.ticket_key && <Hint>Implementation of {item.ticket_key} is paused until a person approves this version.</Hint>}
      {open ? (
        <>
          <Note
            id="inbox-note"
            label="Note (required for Request changes)"
            value={note}
            onChange={setNote}
            placeholder="What should change?"
            onSubmit={() => decide(note.trim() ? "changes_requested" : "approved")}
            onLeave={onLeave}
            inputRef={noteRef}
          />
          <Actions>
            <DoneButton onClick={done} disabled={read.isPending} />
            <Button variant="outline" disabled={review.isPending} onClick={() => decide("changes_requested")}>
              Request changes
            </Button>
            <ButtonLink href={item.href} variant="outline">
              Open review ↗
            </ButtonLink>
            <Button variant="approve" disabled={review.isPending} onClick={() => decide("approved")}>
              Approve <Kbd className="border-transparent text-inherit">A</Kbd>
            </Button>
          </Actions>
          <Hint>Pinned comments and version compare live in the review.</Hint>
        </>
      ) : (
        <ButtonLink href={item.href} variant="outline" className="self-start">
          Open review ↗
        </ButtonLink>
      )}
      <Failure error={review.error ?? read.error} />
    </>
  );
}

const OPEN_LABEL: Record<string, string> = {
  workflow_gate: "Review ↗",
  scheduled: "Open result ↗",
  connector_approval: "Review ↗",
  planning: "Review drafts ↗",
  suggestion: "Review wiki edit ↗",
  review: "Open ticket ↗",
  dispatch: "Open ticket ↗",
  mention: "Open ticket ↗",
};

/** Proposals, reviews, dispatch, mentions and wiki edits: summary, Mark done and a deep link. */
function InfoPane({ item, register, onSent }: PaneProps) {
  const { done, open, read } = useDone(item, onSent);
  const ticket = useTicket(item.kind === "dispatch" ? item.ticket_key : "");
  useEffect(() => {
    register({ done });
  });
  return (
    <>
      <Section label={item.kind === "planning" ? "Goal" : "Summary"}>
        <p className="whitespace-pre-wrap break-words text-13 text-fg-2">{item.kind === "planning" ? item.title : item.summary}</p>
      </Section>
      {item.kind === "planning" && <Hint>{item.summary}. Edit, link and accept drafts on the plan screen.</Hint>}
      {ticket.data && <DispatchBanner t={ticket.data} />}
      <Actions>
        {open ? <DoneButton onClick={done} disabled={read.isPending} /> : <span />}
        <ButtonLink href={item.href} variant="primary">
          {OPEN_LABEL[item.kind] ?? "Open ↗"}
        </ButtonLink>
      </Actions>
      <Failure error={read.error} />
    </>
  );
}
