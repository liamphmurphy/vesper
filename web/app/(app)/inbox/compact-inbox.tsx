"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { useAddressTicketPRFeedback, useComment, useDecideApproval, useInbox, useRunLog, useTicket } from "@/lib/api/hooks";
import { useAddressPushPRFeedback } from "@/lib/api/code-review-hooks";
import { WorkPersonaAvatar } from "@/components/domain/work-persona-avatar";
import { useRememberedProject } from "@/components/shell/project-scope";
import { TopBar } from "@/components/shell/topbar";
import { Button, ButtonLink } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { EmptyState, Skeleton, TextArea } from "@/components/ui/primitives";
import { cx } from "@/lib/cx";
import { GROUPS, KIND, groupItems, isOpen, longWait, waited } from "@/lib/inbox";
import { withMention } from "@/lib/run-question";
import { AllClear, PILL } from "./inbox-screen";

// The compact Inbox (DESIGN.md §3 Responsive, frames "5 Inbox" and "6 Approval sheet"): a list
// of cards with the common action on each, and a sheet for an approval's detail. There is
// deliberately no swipe-to-approve: approvals are consequential and a swipe is easy to make by
// accident, so every decision is a tap on a labelled button.

type Item = Schemas["InboxItem"];

const kindsOf = (key: string) => GROUPS.find((g) => g.key === key)?.kinds ?? [];

/** Filter chips under the title, scrolling sideways when they don't fit. */
const FILTERS: ReadonlyArray<{ key: string; label: string; kinds?: readonly string[] }> = [
  { key: "all", label: "All" },
  { key: "approval", label: "Approvals", kinds: kindsOf("approval") },
  { key: "question", label: "Questions", kinds: kindsOf("question") },
  { key: "blocked", label: "Blocked", kinds: kindsOf("runs") },
  { key: "pr_feedback", label: "PR feedback", kinds: kindsOf("pr_feedback") },
  { key: "mockup", label: "Mockups", kinds: kindsOf("mockup") },
];

/** Card pill: failed runs read as Blocked on a card, as the filter calls them. */
function pill(kind: string) {
  const k = KIND[kind] ?? { label: kind, tone: "info" as const };
  return kind === "blocked" ? { ...k, label: "Blocked" } : k;
}

/** Touch-sized buttons: 44px tall (DESIGN.md §3). */
const TOUCH = "!h-[44px] justify-center px-4 text-14";

/** The ticket's (or chat run's) pending approval behind an approval item, and approve/deny on the same endpoint as desktop. */
function useApproval(item: Item, onSent: (id: string) => void) {
  const isTicket = !!item.ticket_key;
  const ticket = useTicket(item.ticket_key);
  const run = useRunLog(item.run_id ?? "", !isTicket && !!item.run_id);
  const source = isTicket ? ticket : run;
  const decide = useDecideApproval(item.ticket_key);
  const ap = (isTicket ? ticket.data?.approvals : run.data?.approvals)?.find((a) => `approval:${a.id}` === item.id);
  const live = isOpen(item) && !!ap && ap.state === "pending";
  const send = (decision: "approve" | "deny", after?: () => void) => {
    if (!live || decide.isPending) return;
    decide.mutate(
      { id: ap.id, decision },
      {
        onSuccess: () => {
          onSent(item.id);
          after?.();
        },
      },
    );
  };
  return { ticket: source, ap, live, send, pending: decide.isPending, error: decide.error };
}

function Failure({ error }: { error?: Error | null }) {
  return error ? (
    <p role="alert" className="text-12 text-pill-blocked-fg">
      {error.message}
    </p>
  ) : null;
}

function Decision({ item, onSent, after, className }: { item: Item; onSent: (id: string) => void; after?: () => void; className?: string }) {
  const { live, send, pending, error, ticket } = useApproval(item, onSent);
  const off = !live || pending;
  return (
    <div className={cx("flex flex-col gap-2", className)}>
      <div className="flex gap-2">
        <Button variant="approve-outline" className={cx(TOUCH, "flex-1")} disabled={off} onClick={() => send("deny", after)}>
          Deny
        </Button>
        <Button variant="approve" className={cx(TOUCH, "flex-1")} disabled={off} onClick={() => send("approve", after)}>
          Approve
        </Button>
      </div>
      <Failure error={error ?? ticket.error} />
    </div>
  );
}

function Reply({ item, onSent }: { item: Item; onSent: (id: string) => void }) {
  const comment = useComment(item.ticket_key);
  const [body, setBody] = useState("");
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
  return (
    <form
      className="flex flex-col gap-2"
      onSubmit={(e) => {
        e.preventDefault();
        send();
      }}
    >
      <div className="flex items-end gap-2">
        <TextArea
          aria-label={handle ? `Reply to @${handle}` : "Reply"}
          rows={1}
          value={body}
          placeholder="Your answer"
          onChange={(e) => setBody(e.target.value)}
          // 16px so iOS doesn't zoom into the field.
          className="min-h-[44px] flex-1 resize-none !text-16"
        />
        <Button type="submit" variant="primary" className={TOUCH} disabled={!body.trim() || comment.isPending}>
          Send
        </Button>
      </div>
      <Failure error={comment.error} />
    </form>
  );
}

function PRFeedbackAction({ item, onSent }: { item: Item; onSent: (id: string) => void }) {
  const addressTicket = useAddressTicketPRFeedback(item.ticket_key);
  const addressPush = useAddressPushPRFeedback();
  const pushId = item.id.startsWith("pr_ci_failed:push:")
    ? item.id.slice("pr_ci_failed:push:".length)
    : item.id.startsWith("pr_review_comments:push:")
      ? item.id.slice("pr_review_comments:push:".length)
      : "";
  const isCI = item.kind === "pr_ci_failed";
  const mode = isCI ? "ci" : "review";
  const busy = addressTicket.isPending || addressPush.isPending;
  const trigger = () => {
    if (busy) return;
    if (item.ticket_key) addressTicket.mutate(mode, { onSuccess: () => onSent(item.id) });
    else if (pushId) addressPush.mutate({ id: pushId, mode }, { onSuccess: () => onSent(item.id) });
  };
  return (
    <div className="flex flex-col gap-2">
      <div className="flex gap-2">
        <ButtonLink href={item.href} variant="outline" className={cx(TOUCH, "flex-1")}>
          {item.ticket_key ? "Open ticket" : "Open chat"}
        </ButtonLink>
        {(item.ticket_key || pushId) && (
          <Button variant="primary" className={cx(TOUCH, "flex-1")} disabled={busy} onClick={trigger}>
            {busy ? "Sending…" : isCI ? "Fix CI" : "Address comments"}
          </Button>
        )}
      </div>
      <Failure error={addressTicket.error ?? addressPush.error} />
    </div>
  );
}

function Card({ item, sent, onSent, onOpen }: { item: Item; sent: boolean; onSent: (id: string) => void; onOpen: () => void }) {
  const kind = pill(item.kind);
  const approval = item.kind === "approval";
  const body = (
    <>
      <span className="flex min-w-0 items-center gap-2 text-13">
        {item.agent ? (
          <WorkPersonaAvatar agent={item.agent} size="md" />
        ) : (
          <span aria-hidden className="grid size-6 flex-none place-items-center rounded-md bg-track text-fg-tertiary">
            <Icon name="inbox" size={13} />
          </span>
        )}
        {item.agent && <span className="truncate font-medium text-fg-secondary">{item.agent.name}</span>}
        {(item.ticket_key || item.project) && (
          <span className="flex-none font-mono text-12 text-fg-tertiary">{item.ticket_key || item.project}</span>
        )}
        {sent ? (
          <span className="ml-auto flex-none text-12 font-medium text-accent">Sent</span>
        ) : (
          <span className={cx("ml-auto flex-none text-12", longWait(item.created_at) ? "text-pill-human-fg" : "text-fg-tertiary")}>
            {waited(item.created_at)}
          </span>
        )}
      </span>
      <span className="flex min-w-0 items-start gap-2">
        <span className={cx("mt-px flex-none rounded-[4px] px-1.5 py-px text-12 font-medium", PILL[kind.tone])}>{kind.label}</span>
        <span className="min-w-0 font-semibold leading-snug text-fg">{item.title}</span>
      </span>
      <span className="line-clamp-2 text-13 text-fg-tertiary">{item.summary}</span>
    </>
  );
  const tap = "flex w-full flex-col gap-2 text-left outline-none focus-visible:rounded-md focus-visible:ring-2 focus-visible:ring-accent";
  return (
    <li>
      <article aria-label={`${kind.label}: ${item.title}`} data-inbox-card={item.id} className="flex flex-col gap-3 rounded-xl border border-border bg-surface p-3.5">
        {approval ? (
          <button type="button" className={tap} onClick={onOpen} aria-haspopup="dialog">
            {body}
          </button>
        ) : (
          <Link href={item.href} className={tap}>
            {body}
          </Link>
        )}
        {approval && <Decision item={item} onSent={onSent} />}
        {item.kind === "question" && <Reply item={item} onSent={onSent} />}
        {(item.kind === "blocked" || item.kind === "stalled") && item.run_id && (
          <ButtonLink href={`/runs/${item.run_id}`} variant="outline" className={TOUCH}>
            Open run
          </ButtonLink>
        )}
        {(item.kind === "pr_ci_failed" || item.kind === "pr_review_comments") && <PRFeedbackAction item={item} onSent={onSent} />}
        {item.kind === "mockup" && (
          <ButtonLink href={item.href} variant="outline" className={TOUCH}>
            Open review
          </ButtonLink>
        )}
      </article>
    </li>
  );
}

/** Long previews get a full-screen view; short ones read fine in the sheet. */
const longPreview = (s: string) => s.length > 320 || s.split("\n").length > 8;

function Section({ label, children }: { label: string; children: ReactNode }) {
  return (
    <section aria-label={label} className="flex flex-col gap-1.5">
      <h3 className="text-12 font-medium text-fg-secondary">{label}</h3>
      {children}
    </section>
  );
}

/** An approval's detail, over the list: action, risk and preview, with Deny and Approve pinned to the bottom. */
function ApprovalSheet({ item, onSent, onClose }: { item: Item; onSent: (id: string) => void; onClose: () => void }) {
  const { ticket, ap } = useApproval(item, onSent);
  const [full, setFull] = useState(false);
  const close = useRef<HTMLButtonElement>(null);
  useEffect(() => close.current?.focus(), []);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape") return;
      e.preventDefault();
      if (full) setFull(false);
      else onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [full, onClose]);
  const preview = ap?.action_preview ?? "";
  return (
    <div className="fixed inset-0 z-40 flex flex-col justify-end">
      <div aria-hidden className="absolute inset-0 bg-black/50" onClick={onClose} />
      <div
        role="dialog"
        aria-modal="true"
        aria-label="Approval"
        className="relative flex max-h-[90dvh] flex-col rounded-t-2xl border-t border-border bg-panel"
      >
        <div className="flex items-center gap-2 px-4 pt-3">
          {item.agent && <WorkPersonaAvatar agent={item.agent} size="md" />}
          <span className="min-w-0 flex-1 truncate text-13 text-fg-secondary">
            {item.agent?.name ?? "An agent"} {item.ticket_key && <span className="font-mono text-12 text-fg-tertiary">· {item.ticket_key}</span>}
          </span>
          <button ref={close} type="button" aria-label="Close" onClick={onClose} className="grid size-[44px] place-items-center rounded-md text-fg-tertiary hover:bg-hover">
            <Icon name="x" size={18} />
          </button>
        </div>
        <div className="flex min-h-0 flex-1 flex-col gap-4 overflow-y-auto px-4 pb-4">
          <h2 className="type-heading text-fg">{item.title}</h2>
          {ticket.isPending ? (
            <Skeleton className="h-32" />
          ) : ticket.isError ? (
            <Failure error={ticket.error} />
          ) : (
            <>
              <Section label="Action">
                <p className="text-14 text-fg-2">
                  {ap?.scope && <span className="font-mono text-12 text-fg-tertiary">{ap.scope}</span>}{" "}
                  {ap?.action_summary ?? item.summary}
                </p>
              </Section>
              {ap?.risk_summary && (
                <Section label="Risk summary">
                  <p className="text-14 text-fg-2">{ap.risk_summary}</p>
                </Section>
              )}
              {preview && (
                <Section label="Preview">
                  <pre data-testid="approval-preview" className="max-h-56 overflow-auto whitespace-pre rounded-md bg-surface-sunken p-2.5 font-mono text-12 leading-relaxed text-fg-2">
                    {preview}
                  </pre>
                  {longPreview(preview) && (
                    <Button variant="ghost" className="!h-[44px] self-start" onClick={() => setFull(true)}>
                      <Icon name="expand" size={14} /> Full screen
                    </Button>
                  )}
                </Section>
              )}
              {ap && ap.state !== "pending" && <p className="text-12 text-fg-tertiary">This request was {ap.state}.</p>}
            </>
          )}
        </div>
        <Decision item={item} onSent={onSent} after={onClose} className="border-t border-border-subtle px-4 pt-3 pb-[max(12px,env(safe-area-inset-bottom))]" />
      </div>
      {full && (
        <div role="dialog" aria-modal="true" aria-label="Preview" className="fixed inset-0 z-50 flex flex-col bg-panel pt-safe">
          <div className="flex items-center border-b border-border-subtle px-4 py-1">
            <span className="flex-1 text-14 font-medium text-fg">Preview</span>
            <button type="button" aria-label="Close preview" onClick={() => setFull(false)} className="grid size-[44px] place-items-center rounded-md text-fg-tertiary hover:bg-hover">
              <Icon name="x" size={18} />
            </button>
          </div>
          <pre className="min-h-0 flex-1 overflow-auto whitespace-pre p-4 pb-safe font-mono text-12 leading-relaxed text-fg-2">{preview}</pre>
        </div>
      )}
    </div>
  );
}

export function CompactInbox() {
  const remembered = useRememberedProject();
  const project = remembered ?? "";
  const inbox = useInbox(project || undefined, remembered !== undefined);
  const all = useMemo(() => inbox.data ?? [], [inbox.data]);
  const [filter, setFilter] = useState("all");
  const [sent, setSent] = useState<ReadonlySet<string>>(new Set());
  const [sheet, setSheet] = useState<string>();
  const open = useMemo(() => groupItems(all, "open", "oldest").flatMap((g) => g.items), [all]);
  const kinds = FILTERS.find((f) => f.key === filter)?.kinds;
  const shown = kinds ? open.filter((i) => kinds.includes(i.kind)) : open;
  const sheetItem = all.find((i) => i.id === sheet);
  const markSent = (id: string) => setSent((s) => new Set(s).add(id));

  return (
    <>
      <TopBar crumbs={[{ label: "Inbox" }]} />
      <section aria-label="Inbox" className="flex min-w-0 flex-1 flex-col">
        <div role="group" aria-label="Filter" className="flex gap-2 overflow-x-auto px-4 py-2.5 [scrollbar-width:none]">
          {FILTERS.map((f) => {
            const n = f.kinds ? open.filter((i) => f.kinds!.includes(i.kind)).length : open.length;
            return (
              <button
                key={f.key}
                type="button"
                aria-pressed={filter === f.key}
                onClick={() => setFilter(f.key)}
                className={cx(
                  "flex h-[36px] flex-none items-center gap-1.5 rounded-full border px-3.5 text-13",
                  filter === f.key ? "border-transparent bg-selected font-medium text-fg" : "border-border-strong text-fg-secondary",
                )}
              >
                {f.label} <span className="font-mono text-12 text-fg-tertiary">{n}</span>
              </button>
            );
          })}
        </div>
        {inbox.isPending ? (
          <div aria-busy="true" className="space-y-3 px-4 py-2">
            {[0, 1, 2].map((i) => (
              <Skeleton key={i} className="h-28 rounded-xl" />
            ))}
          </div>
        ) : inbox.isError ? (
          <div role="alert" className="flex items-center gap-3 p-4 text-pill-blocked-fg">
            Couldn’t load your inbox. <Button onClick={() => inbox.refetch()}>Retry</Button>
          </div>
        ) : open.length === 0 ? (
          <AllClear project={project} done={0} onShowDone={() => {}} />
        ) : shown.length === 0 ? (
          <EmptyState icon="inbox" title="Nothing here right now">Switch filters to see the rest of your inbox.</EmptyState>
        ) : (
          <ul className="flex flex-col gap-3 px-4 pt-1 pb-4">
            {shown.map((i) => (
              <Card key={i.id} item={i} sent={sent.has(i.id)} onSent={markSent} onOpen={() => setSheet(i.id)} />
            ))}
          </ul>
        )}
      </section>
      {sheetItem && <ApprovalSheet key={sheetItem.id} item={sheetItem} onSent={markSent} onClose={() => setSheet(undefined)} />}
    </>
  );
}
