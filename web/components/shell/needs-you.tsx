"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { Popover } from "radix-ui";
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { useQueryClient } from "@tanstack/react-query";
import type { Schemas } from "@/lib/api/client";
import { useComment, useDecideApproval, useInbox, useReadInbox } from "@/lib/api/hooks";
import { AgentAvatar } from "@/components/domain/avatars";
import { DispatchDialog } from "@/components/domain/dispatch-dialog";
import { Button, ButtonLink } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { EmptyState, Kbd, Skeleton, TextArea } from "@/components/ui/primitives";
import { useEntrances, usePulse } from "@/components/ui/motion";
import { cx } from "@/lib/cx";
import { KIND, approvalId, isExternalHref, openHref, isOpen, nextSelection, step, trayAction, trayItems, waited, type TrayTab } from "@/lib/inbox";
import { withMention } from "@/lib/run-question";
import { isTyping } from "./shortcuts";

type Item = Schemas["InboxItem"];

/**
 * The Needs you pill and its tray (LAZYAGENTS-162): one queue of what waits on
 * the person, answerable from any page. It is an icon with a badge in the persistent
 * right rail, a tab in the compact bar, or an inline pill. The badge is the bootstrap's needs_you count (live over SSE).
 */
export function NeedsYou({ variant, count }: { variant: "pill" | "rail" | "tab"; count: number }) {
  const [open, setOpen] = useState(false);
  // Dispatch opens a dialog, which has to live outside the popover it closes.
  const [dispatchKey, setDispatchKey] = useState<string>();
  const pulse = usePulse<HTMLSpanElement>(count);
  const label = count > 0 ? `Needs you, ${count} waiting` : "Needs you, nothing waiting";
  const badge = count > 99 ? "99+" : count;

  const trigger =
    variant === "pill" ? (
      <button
        type="button"
        aria-label={label}
        aria-expanded={open}
        data-needs-you
        className={cx(
          "flex h-[28px] w-full items-center gap-2 rounded-lg px-2.5 text-12 font-semibold",
          count > 0 ? "bg-pill-human-bg text-pill-human-fg hover:brightness-110" : "text-fg-tertiary hover:bg-hover hover:text-fg",
          open && "ring-1 ring-state-human/50",
        )}
      >
        <span aria-hidden className={cx("size-1.5 flex-none rounded-full", count > 0 ? "bg-state-human" : "bg-fg-tertiary/50")} />
        <span className="flex-1 text-left">Needs you</span>
        {count > 0 && <span ref={pulse} aria-hidden className="font-bold tabular-nums">{badge}</span>}
      </button>
    ) : variant === "rail" ? (
      <button
        type="button"
        aria-label={label}
        aria-expanded={open}
        title="Needs you"
        data-needs-you
        className={cx(
          "relative grid size-[30px] place-items-center rounded-md",
          count > 0 ? "bg-pill-human-bg text-pill-human-fg" : "text-fg-tertiary hover:bg-hover hover:text-fg",
        )}
      >
        <Icon name="inbox" size={15} strokeWidth={1.6} />
        {count > 0 && (
          <span ref={pulse} aria-hidden className="absolute -right-1.5 -top-1.5 grid h-4 min-w-4 place-items-center rounded-full bg-state-human px-1 text-10 font-semibold leading-none text-approve-fg">
            {badge}
          </span>
        )}
      </button>
    ) : (
      <button
        type="button"
        aria-label={label}
        aria-expanded={open}
        data-needs-you
        className={cx("flex min-h-[44px] flex-1 flex-col items-center justify-center gap-0.5 text-11 font-medium", open || count > 0 ? "text-pill-human-fg" : "text-fg-tertiary")}
      >
        <span className={cx("relative grid h-7 w-12 place-items-center rounded-full", open && "bg-selected")}>
          <Icon name="inbox" size={18} strokeWidth={1.6} />
          {count > 0 && (
            <span ref={pulse} aria-hidden data-testid="tab-badge" className="absolute -right-1 -top-1 grid h-4 min-w-4 place-items-center rounded-full bg-state-human px-1 text-11 font-semibold leading-none text-approve-fg">
              {badge}
            </span>
          )}
        </span>
        Needs you
      </button>
    );

  return (
    <>
      <Popover.Root open={open} onOpenChange={setOpen}>
        <Popover.Trigger asChild>{trigger}</Popover.Trigger>
        <Popover.Portal>
          <Popover.Content
            side={variant === "tab" ? "top" : variant === "rail" ? "left" : "right"}
            align={variant === "tab" ? "center" : variant === "rail" ? "end" : "start"}
            sideOffset={variant === "tab" ? 6 : 12}
            collisionPadding={8}
            aria-label="Needs you"
            onOpenAutoFocus={(e) => e.preventDefault()}
            onEscapeKeyDown={(e) => {
              // Esc in the reply or reason box goes back to the list; Esc on the list closes.
              if (isTyping(document.activeElement)) {
                e.preventDefault();
                const box = document.activeElement as HTMLElement;
                const tray = box.closest("[data-tray]");
                box.blur();
                tray?.querySelector<HTMLElement>("[data-tray-row][aria-current]")?.focus();
              }
            }}
            className="motion-flyout z-50 flex max-h-[min(640px,calc(100dvh-24px))] w-[440px] max-w-[calc(100vw-16px)] flex-col overflow-hidden rounded-[14px] border border-border-float bg-surface-raised shadow-[var(--shadow-float)] outline-none"
          >
            <Tray
              onClose={() => setOpen(false)}
              onDispatch={(key) => {
                setOpen(false);
                setDispatchKey(key);
              }}
            />
          </Popover.Content>
        </Popover.Portal>
      </Popover.Root>
      {dispatchKey && <DispatchDialog keys={[dispatchKey]} open onOpenChange={(o) => !o && setDispatchKey(undefined)} />}
    </>
  );
}

function rowEl(id: string) {
  return document.querySelector<HTMLElement>(`[data-tray-row="${CSS.escape(id)}"]`);
}

/** Opens the open: approve, deny, reply. Each row registers its keyboard actions here. */
type RowKeys = { approve?: () => void; deny?: () => void; reply?: () => void };

function Tray({ onClose, onDispatch }: { onClose: () => void; onDispatch: (key: string) => void }) {
  const router = useRouter();
  const inbox = useInbox();
  const read = useReadInbox();
  const [tab, setTab] = useState<TrayTab>("needs");
  const [sel, setSel] = useState<{ id?: string; index: number }>({ index: 0 });
  const { needs, updates, unread } = useMemo(() => trayItems(inbox.data ?? []), [inbox.data]);
  const list = tab === "needs" ? needs : updates;
  const ids = list.map((i) => i.id);
  const current = nextSelection(ids, sel.id, sel.index);
  const at = current ? ids.indexOf(current) : 0;
  if (current !== sel.id || at !== sel.index) setSel({ id: current, index: at });
  const keys = useRef<Record<string, RowKeys>>({});
  const listRef = useRef<HTMLDivElement>(null);
  // Something new that needs you rises in; switching tabs replaces the list, which stays still.
  useEntrances(listRef);

  // The tray opens with the first row focused, so J/K, A and D work at once.
  const focused = useRef(false);
  // When the focused row leaves (approved, answered), focus falls to <body>: hand it to the row in its slot.
  useEffect(() => {
    if (!current) return;
    const lost = !document.activeElement || document.activeElement === document.body;
    if (focused.current && !lost) return;
    focused.current = true;
    rowEl(current)?.focus();
  }, [current]);

  const select = (id: string | undefined) => {
    setSel({ id, index: id ? ids.indexOf(id) : 0 });
    if (id) rowEl(id)?.focus();
  };
  const switchTab = (t: TrayTab) => {
    setTab(t);
    setSel({ index: 0 });
    focused.current = false;
  };
  const open = (item: Item) => {
    // Updates and mentions never resolve on their own: opening one from the tray is reading it.
    if (isOpen(item) && (!item.needs_you || item.kind === "mention")) read.mutate(item.id);
    onClose();
    openHref(item.href, router.push);
  };

  // On window, not the tray: focus can fall to <body> (a row or button leaves), and the keys still have to work.
  // The page's own keys (Inbox, app shell) stand down while a dialog, such as this popover, is open.
  const onKeyDown = (e: KeyboardEvent) => {
    if (e.metaKey || e.ctrlKey || e.altKey || isTyping(e.target)) return;
    if (document.querySelectorAll('[role="dialog"]').length > 1) return;
    const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
    const t = e.target;
    const onRow = t === document.body || (t instanceof HTMLElement && t.hasAttribute("data-tray-row"));
    // ←/→ switch tabs (the ARIA tabs pattern). Tab keeps moving focus, so every button and link in the tray is reachable.
    if (k === "ArrowLeft" || k === "ArrowRight") {
      if (!onRow && !(t instanceof HTMLElement && t.role === "tab")) return;
      e.preventDefault();
      const next = tab === "needs" ? "updates" : "needs";
      switchTab(next);
      if (t instanceof HTMLElement && t.role === "tab") requestAnimationFrame(() => document.getElementById(`tray-tab-${next}`)?.focus());
      return;
    }
    if (k === "j" || k === "k" || k === "ArrowDown" || k === "ArrowUp") {
      e.preventDefault();
      select(step(ids, current, k === "j" || k === "ArrowDown" ? 1 : -1));
      return;
    }
    const item = list.find((i) => i.id === current);
    if (!item) return;
    if (k === "Enter" && onRow) {
      e.preventDefault();
      open(item);
      return;
    }
    const run = { a: keys.current[item.id]?.approve, d: keys.current[item.id]?.deny, r: keys.current[item.id]?.reply }[k];
    if (run) {
      e.preventDefault();
      run();
    }
  };

  useEffect(() => {
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  });

  const markAll = async () => {
    await Promise.all(unread.map((id) => read.mutateAsync(id)));
  };

  const tabClass = (on: boolean) =>
    cx("flex h-7 items-center gap-1.5 rounded-md px-2.5 text-13 font-medium outline-none focus-visible:ring-1 focus-visible:ring-accent", on ? "bg-selected text-fg" : "text-fg-tertiary hover:text-fg");

  return (
    <div data-tray className="flex min-h-0 flex-1 flex-col">
      <div className="flex items-center gap-1 px-3 pb-2 pt-3">
        <div role="tablist" aria-label="Tray" className="flex items-center gap-1">
          <button type="button" role="tab" id="tray-tab-needs" aria-controls="tray-panel" aria-selected={tab === "needs"} tabIndex={tab === "needs" ? 0 : -1} onClick={() => switchTab("needs")} className={tabClass(tab === "needs")}>
            Needs you
            <span className={cx("font-mono text-12", needs.length ? "text-pill-human-fg" : "text-fg-tertiary")}>{needs.length}</span>
          </button>
          <button type="button" role="tab" id="tray-tab-updates" aria-controls="tray-panel" aria-selected={tab === "updates"} tabIndex={tab === "updates" ? 0 : -1} onClick={() => switchTab("updates")} className={tabClass(tab === "updates")}>
            Updates
            {unread.length > 0 && (
              <span data-testid="updates-dot" className="size-1.5 rounded-full bg-accent">
                <span className="sr-only">, unread</span>
              </span>
            )}
          </button>
        </div>
        {tab === "updates" && unread.length > 0 && (
          <button type="button" onClick={markAll} disabled={read.isPending} className="ml-auto rounded-md px-2 py-1 text-12 font-medium text-accent hover:bg-hover disabled:opacity-60">
            Mark all read
          </button>
        )}
      </div>
      <div ref={listRef} id="tray-panel" role="tabpanel" aria-label={tab === "needs" ? "Needs you" : "Updates"} className="min-h-0 flex-1 overflow-y-auto px-1.5 pb-1.5">
        {inbox.isPending ? (
          <div aria-busy="true" className="space-y-2 p-2">
            {[0, 1, 2].map((i) => (
              <Skeleton key={i} className="h-[52px]" />
            ))}
          </div>
        ) : inbox.isError ? (
          <div role="alert" className="flex items-center gap-3 p-4 text-13 text-pill-blocked-fg">
            Couldn’t load what needs you. <Button onClick={() => inbox.refetch()}>Retry</Button>
          </div>
        ) : list.length === 0 ? (
          tab === "needs"
            ? <EmptyState compact icon="check" title="Nothing needs you right now">Approvals, questions and reviews from your runs show up here.</EmptyState>
            : <EmptyState compact icon="inbox" title="No updates yet">Finished runs and replies show up here.</EmptyState>
        ) : (
          <ul className="flex flex-col gap-px">
            {list.map((item) => (
              <Row
                key={item.id}
                item={item}
                selected={item.id === current}
                onSelect={() => setSel({ id: item.id, index: ids.indexOf(item.id) })}
                onOpen={() => open(item)}
                onDispatch={onDispatch}
                register={(k) => {
                  keys.current[item.id] = k;
                }}
              />
            ))}
          </ul>
        )}
      </div>
      <div className="flex items-center gap-3 border-t border-border-subtle px-3.5 py-2 text-12 text-fg-tertiary">
        <span aria-hidden className="hidden items-center gap-2.5 min-[480px]:flex">
          <span><Kbd>J</Kbd> <Kbd>K</Kbd> move</span>
          <span><Kbd>A</Kbd> <Kbd>D</Kbd> decide</span>
          <span><Kbd>←</Kbd> <Kbd>→</Kbd> switch</span>
        </span>
        <Link href="/work#needs-you" onClick={onClose} className="ml-auto font-medium text-accent hover:underline">
          Open all →
        </Link>
      </div>
    </div>
  );
}

function Row({
  item,
  selected,
  onSelect,
  onOpen,
  onDispatch,
  register,
}: {
  item: Item;
  selected: boolean;
  onSelect: () => void;
  onOpen: () => void;
  onDispatch: (key: string) => void;
  register: (k: RowKeys) => void;
}) {
  const kind = KIND[item.kind] ?? { label: item.kind, tone: "info" };
  const action = item.needs_you ? trayAction(item.kind, !!item.run_id) : undefined;
  const unread = !item.needs_you && isOpen(item);
  const meta = [item.ticket_key || item.project, item.agent?.name].filter(Boolean).join(" · ");
  return (
    <li
      data-tray-row={item.id}
      data-enter-key={item.id}
      aria-current={selected ? "true" : undefined}
      aria-label={`${kind.label}: ${item.title}`}
      tabIndex={selected ? 0 : -1}
      onFocus={(e) => e.target === e.currentTarget && onSelect()}
      onClick={(e) => {
        onSelect();
        // A click on the row itself (not a button or box in it) opens the item.
        if (!(e.target as HTMLElement).closest("button,a,textarea,input,form")) onOpen();
      }}
      className={cx(
        "relative flex cursor-pointer gap-2.5 rounded-[10px] px-2.5 py-2 outline-none",
        selected ? "bg-selected" : "hover:bg-row-hover",
        "focus-visible:ring-1 focus-visible:ring-accent/60",
      )}
    >
      {item.agent ? (
        <AgentAvatar name={item.agent.name} colorIndex={item.agent.color_index} label={false} size="md" />
      ) : (
        <span aria-hidden className="grid size-6 flex-none place-items-center rounded-md bg-track text-fg-tertiary">
          <Icon name={item.kind === "merged" || item.kind === "pr_approved" ? "check" : "inbox"} size={13} />
        </span>
      )}
      <div className="flex min-w-0 flex-1 flex-col gap-1">
        <span className="flex min-w-0 items-center gap-1.5 text-13">
          <span className={cx("flex-none text-12 font-medium", kind.tone === "blocked" ? "text-pill-blocked-fg" : item.needs_you ? "text-pill-human-fg" : "text-fg-tertiary")}>
            {kind.label}
          </span>
          <span className={cx("truncate", unread || item.needs_you ? "font-semibold text-fg" : "text-fg-secondary")}>{item.title}</span>
          {unread && <span aria-label="unread" className="size-1.5 flex-none rounded-full bg-accent" />}
        </span>
        <span className="truncate text-12 text-fg-tertiary">
          {meta && <span className="font-mono">{meta}</span>}
          {meta && " · "}
          {waited(item.created_at)}
          {item.summary && item.kind !== "approval" && <span className="text-fg-secondary"> · {item.summary}</span>}
        </span>
        {action?.type === "approve" && <ApproveActions item={item} register={register} />}
        {action?.type === "reply" && <ReplyActions item={item} register={register} />}
        {action?.type === "dispatch" && item.ticket_key && (
          <RowButtons>
            <Button variant="approve" onClick={() => onDispatch(item.ticket_key)}>
              Start
            </Button>
          </RowButtons>
        )}
        {action?.type === "open" && (
          <RowButtons>
            <ButtonLink href={item.href} variant="outline" onClick={onOpen} {...(isExternalHref(item.href) ? { target: "_blank", rel: "noopener noreferrer" } : {})}>
              {action.label}
            </ButtonLink>
          </RowButtons>
        )}
      </div>
    </li>
  );
}

function RowButtons({ children }: { children: ReactNode }) {
  return <div className="flex flex-wrap items-center gap-1.5 pt-0.5 [&_a]:h-7 [&_button]:h-7">{children}</div>;
}

function Failure({ error }: { error?: Error | null }) {
  return error ? (
    <p role="alert" className="text-12 text-pill-blocked-fg">
      {error.message}
    </p>
  ) : null;
}

/** Approve, or Deny… with an optional reason: the run card's /approvals/{id}/{decision}. */
function ApproveActions({ item, register }: { item: Item; register: (k: RowKeys) => void }) {
  const qc = useQueryClient();
  const decide = useDecideApproval(item.ticket_key);
  const [denying, setDenying] = useState(false);
  const [reason, setReason] = useState("");
  const reasonRef = useRef<HTMLTextAreaElement>(null);
  const id = approvalId(item.id);
  const send = (decision: "approve" | "deny") => {
    if (!id || decide.isPending || decide.isSuccess) return;
    decide.mutate(
      { id, decision, note: decision === "deny" ? reason.trim() || undefined : undefined },
      {
        onSuccess: () => {
          void qc.invalidateQueries({ queryKey: ["inbox"] });
          void qc.invalidateQueries({ queryKey: ["bootstrap"] });
        },
      },
    );
  };
  const startDeny = () => {
    setDenying(true);
    requestAnimationFrame(() => reasonRef.current?.focus());
  };
  useEffect(() => {
    register({ approve: () => send("approve"), deny: startDeny });
  });
  if (decide.isSuccess) {
    return <span className="text-12 font-medium text-accent">{decide.variables?.decision === "deny" ? "Denied" : "Approved"}</span>;
  }
  return (
    <>
      <span className="truncate text-12 text-fg-secondary">{item.summary}</span>
      {denying ? (
        <form
          className="flex flex-col gap-1.5 pt-0.5"
          onSubmit={(e) => {
            e.preventDefault();
            send("deny");
          }}
        >
          <TextArea
            ref={reasonRef}
            rows={2}
            aria-label={`Reason for denying, sent to ${item.agent?.name ?? "the agent"} (optional)`}
            placeholder="Why not? (optional, sent to the agent)"
            value={reason}
            onChange={(e) => setReason(e.target.value)}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                send("deny");
              }
            }}
            className="text-13"
          />
          <RowButtons>
            <Button type="submit" variant="approve-outline" disabled={decide.isPending}>
              Deny
            </Button>
            <Button variant="ghost" onClick={() => setDenying(false)}>
              Cancel
            </Button>
          </RowButtons>
        </form>
      ) : (
        <RowButtons>
          <Button variant="approve" disabled={decide.isPending} onClick={() => send("approve")}>
            Approve
          </Button>
          <Button variant="approve-outline" disabled={decide.isPending} onClick={startDeny}>
            Deny…
          </Button>
        </RowButtons>
      )}
      <Failure error={decide.error} />
    </>
  );
}

/** The Inbox reply: a comment that mentions the agent, which resumes the waiting run. */
function ReplyActions({ item, register }: { item: Item; register: (k: RowKeys) => void }) {
  const qc = useQueryClient();
  const comment = useComment(item.ticket_key);
  const [body, setBody] = useState("");
  const ref = useRef<HTMLTextAreaElement>(null);
  const handle = item.agent?.handle ?? "";
  useEffect(() => {
    register({ reply: () => ref.current?.focus() });
  });
  const send = () => {
    if (!body.trim() || comment.isPending) return;
    comment.mutate(
      { body_md: handle ? withMention(body, handle) : body.trim() },
      {
        onSuccess: () => {
          setBody("");
          void qc.invalidateQueries({ queryKey: ["inbox"] });
          void qc.invalidateQueries({ queryKey: ["bootstrap"] });
        },
      },
    );
  };
  if (comment.isSuccess) return <span className="text-12 font-medium text-accent">Sent</span>;
  return (
    <form
      className="flex items-end gap-1.5 pt-0.5"
      onSubmit={(e) => {
        e.preventDefault();
        send();
      }}
    >
      <TextArea
        ref={ref}
        rows={1}
        aria-label={`Reply to ${item.agent?.name ?? "the agent"}`}
        placeholder="Reply…"
        value={body}
        onChange={(e) => setBody(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && !e.shiftKey) {
            e.preventDefault();
            send();
          }
        }}
        className="min-h-8 flex-1 resize-none py-1.5 text-13"
      />
      <Button type="submit" variant="primary" className="h-8" disabled={!body.trim() || comment.isPending}>
        Send
      </Button>
      <Failure error={comment.error} />
    </form>
  );
}
