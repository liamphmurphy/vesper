"use client";

import Link from "next/link";
import { createContext, type ReactNode } from "react";
import { useRunLog, useTicket } from "@/lib/api/hooks";
import { usePage } from "@/lib/api/knowledge-hooks";
import type { LinkedItem } from "@/lib/chat-panels";
import { pageHref } from "@/lib/knowledge";
import { runTitle } from "@/lib/run-list";
import { Icon, type IconName } from "@/components/ui/icon";
import { LoadingLines } from "@/components/ui/loading";
import { ChatMarkdown } from "./chat-markdown";

/**
 * Opens a linked item beside the chat. A context, so the memoized message bubbles (their sent
 * chips) can open one without re-rendering when the conversation's callbacks change. Unset in a
 * dock's chat, which has no dock of its own to open into: its chips stay plain.
 */
export const OpenLinkedItem = createContext<((item: LinkedItem) => void) | undefined>(undefined);

export const ITEM_ICON: Record<LinkedItem["kind"], IconName> = { ticket: "tickets", run: "play", page: "wiki" };

function Frame({ icon, kind, title, href, open, onClose, children }: { icon: IconName; kind: string; title: string; href: string; open: string; onClose: () => void; children: ReactNode }) {
  return (
    <section aria-label={`${kind}: ${title}`} data-testid="linked-item" className="flex min-h-0 flex-1 flex-col">
      <header className="flex flex-none items-center gap-2 border-b border-border-subtle px-4 py-2.5">
        <Icon name={icon} size={14} className="flex-none text-fg-tertiary" />
        <h2 className="min-w-0 flex-1 truncate text-14 font-semibold text-fg">{title}</h2>
        <Link href={href} className="flex-none text-12 font-medium text-accent hover:underline">{open} ↗</Link>
        <button type="button" aria-label={`Close ${title}`} onClick={onClose} className="grid size-6 flex-none place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg">
          <Icon name="x" size={12} />
        </button>
      </header>
      <div className="min-h-0 flex-1 overflow-y-auto px-4 py-3">{children}</div>
    </section>
  );
}

function Failed({ what }: { what: string }) {
  return <p role="alert" className="text-13 text-fg-secondary">Couldn’t load the {what}.</p>;
}

function TicketItem({ ticketKey, onClose }: { ticketKey: string; onClose: () => void }) {
  const q = useTicket(ticketKey);
  const t = q.data;
  const title = t ? `${t.key} · ${t.title}` : ticketKey;
  return (
    <Frame icon="tickets" kind="Ticket" title={title} href={`/tickets/${encodeURIComponent(ticketKey)}`} open="Open ticket" onClose={onClose}>
      {q.isError ? <Failed what="ticket" /> : !t ? <LoadingLines /> : (
        <div className="flex flex-col gap-3 text-13">
          <p className="text-12 text-fg-tertiary">{t.status.replace("_", " ")} · {t.priority}{t.assignee ? ` · ${t.assignee.name}` : ""}</p>
          {t.criteria.length > 0 && (
            <section aria-label="Acceptance criteria" className="flex flex-col gap-1">
              <h3 className="text-12 font-medium text-fg-tertiary">Acceptance criteria · {t.criteria.filter((c) => c.done).length}/{t.criteria.length}</h3>
              <ul className="flex flex-col gap-1">
                {t.criteria.map((c) => (
                  <li key={c.id} className="flex items-start gap-2">
                    <Icon name={c.done ? "check" : "dots"} size={12} className={c.done ? "mt-0.5 flex-none text-state-done" : "mt-0.5 flex-none text-fg-tertiary"} />
                    <span className={c.done ? "text-fg-secondary" : "text-fg"}>{c.text}</span>
                  </li>
                ))}
              </ul>
            </section>
          )}
          {t.description_md.trim() && <div className="type-chat text-fg-2"><ChatMarkdown>{t.description_md}</ChatMarkdown></div>}
        </div>
      )}
    </Frame>
  );
}

function RunItem({ id, onClose }: { id: string; onClose: () => void }) {
  const q = useRunLog(id);
  const run = q.data?.run;
  const title = run ? runTitle(run) : "Run";
  return (
    <Frame icon="play" kind="Run" title={title} href={`/runs/${id}`} open="Open run" onClose={onClose}>
      {q.isError ? <Failed what="run" /> : !run ? <LoadingLines /> : (
        <div className="flex flex-col gap-3 text-13">
          <p className="text-12 text-fg-tertiary">{[run.agent.name, run.ticket_key, run.state.replace("_", " ")].filter(Boolean).join(" · ")}</p>
          {run.plan.length > 0 && (
            <ol aria-label="Plan" className="flex flex-col gap-1">
              {run.plan.map((s) => (
                <li key={s.position} data-step-state={s.state} className="flex items-start gap-2">
                  <Icon name={s.state === "done" ? "check" : s.state === "current" ? "play" : s.state === "failed" ? "alert" : "dots"} size={12} className="mt-0.5 flex-none text-fg-tertiary" />
                  <span className={s.state === "current" ? "font-medium text-fg" : "text-fg-secondary"}>{s.text}</span>
                </li>
              ))}
            </ol>
          )}
          {run.outcome && <p className="text-fg-2">{run.outcome}</p>}
        </div>
      )}
    </Frame>
  );
}

function PageItem({ id, onClose }: { id: string; onClose: () => void }) {
  const q = usePage(id);
  const p = q.data;
  const title = p?.title || "Page";
  return (
    <Frame icon="wiki" kind="Page" title={title} href={pageHref(id, p?.title)} open="Open in Knowledge" onClose={onClose}>
      {q.isError ? <Failed what="page" /> : !p ? <LoadingLines /> : (
        <div className="flex flex-col gap-2">
          {p.path && <p className="text-12 text-fg-tertiary">{p.path}</p>}
          <div className="type-chat text-fg-2"><ChatMarkdown>{p.body_md ?? ""}</ChatMarkdown></div>
        </div>
      )}
    </Frame>
  );
}

/** A linked ticket, run or page, read-only beside the chat; its Open link goes to the full page, and the rail's Back returns. */
export function ItemPanel({ item, onClose }: { item: LinkedItem; onClose: () => void }) {
  if (item.kind === "ticket") return <TicketItem ticketKey={item.key} onClose={onClose} />;
  if (item.kind === "run") return <RunItem id={item.id} onClose={onClose} />;
  return <PageItem id={item.id} onClose={onClose} />;
}

/**
 * The row under the chat's header naming what the conversation links to (the tickets and pages its
 * messages carried, its runs); each opens beside the chat, and the dock's Open link goes to the page.
 */
export function LinkedRow({ items, label, onOpen, dense = false }: { items: LinkedItem[]; label: (item: LinkedItem) => string; onOpen: (item: LinkedItem) => void; dense?: boolean }) {
  if (items.length === 0) return null;
  return (
    <nav aria-label="Linked items" data-testid="linked-row" className={cx("flex flex-none items-center gap-1.5 overflow-x-auto border-b border-border-subtle", dense ? "px-3 py-1" : "px-6 py-1.5")}>
      <span className="flex-none text-12 text-fg-tertiary">Linked</span>
      {items.map((item) => (
        <button key={itemKey(item)} type="button" onClick={() => onOpen(item)} title={`Open ${label(item)} beside the chat`}
          className="inline-flex h-6 max-w-[220px] flex-none items-center gap-1.5 rounded-full border border-border bg-surface px-2 text-12 text-fg-secondary hover:bg-hover hover:text-fg">
          <Icon name={ITEM_ICON[item.kind]} size={12} className="flex-none text-fg-tertiary" />
          <span className="truncate">{label(item)}</span>
        </button>
      ))}
    </nav>
  );
}

const itemKey = (i: LinkedItem) => (i.kind === "ticket" ? `ticket:${i.key}` : `${i.kind}:${i.id}`);
