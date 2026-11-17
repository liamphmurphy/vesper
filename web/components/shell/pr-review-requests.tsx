"use client";

import Link from "next/link";
import { Popover } from "radix-ui";
import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { Schemas } from "@/lib/api/client";
import { useInbox, useReadInbox } from "@/lib/api/hooks";
import { useGitHubReviewRequests, useRefreshGitHubReviewRequests } from "@/lib/api/github-reviews-hooks";
import { Button } from "@/components/ui/button";
import { Toggle } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { Spinner } from "@/components/ui/loading";
import { usePulse } from "@/components/ui/motion";
import { EmptyState, Kbd, Skeleton } from "@/components/ui/primitives";
import { cx } from "@/lib/cx";
import {
  authorInitials,
  countReviewRequests,
  filterReviewRequests,
  loadReviewFilterPrefs,
  relativeAge,
  saveReviewFilterPrefs,
  type ReviewFilterPrefs,
} from "@/lib/github-reviews";
import { isOpen, nextSelection, step } from "@/lib/inbox";
import { isTyping } from "./shortcuts";

type ReviewItem = Schemas["GitHubReviewRequest"];

function prRowEl(id: string) {
  return document.querySelector<HTMLAnchorElement>(`[data-pr-row="${CSS.escape(id)}"]`);
}

/**
 * Right-rail GitHub PR review requests icon + popover feed.
 * Uses the workspace's git:pat token and lets you toggle Direct vs. Team requests.
 */
export function PrReviewRequests() {
  const [open, setOpen] = useState(false);
  const [prefs, setPrefs] = useState<ReviewFilterPrefs>({ direct: true, team: true });
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect -- reading browser-only storage after hydration
    setPrefs(loadReviewFilterPrefs(window.localStorage));
  }, []);

  const query = useGitHubReviewRequests();
  const refresh = useRefreshGitHubReviewRequests();
  const allItems = useMemo(() => query.data?.items ?? [], [query.data?.items]);
  const filtered = useMemo(() => filterReviewRequests(allItems, prefs), [allItems, prefs]);
  const counts = useMemo(() => countReviewRequests(allItems), [allItems]);

  // Approvals of PRs you authored arrive as inbox items (kind pr_approved); the unread ones are the green badge.
  const inbox = useInbox();
  const read = useReadInbox();
  const approved = useMemo(() => (inbox.data ?? []).filter((i) => i.kind === "pr_approved" && isOpen(i)), [inbox.data]);
  const approvedCount = approved.length;
  const approvedPulse = usePulse<HTMLSpanElement>(approvedCount);
  const clearApproved = () => Promise.all(approved.map((i) => read.mutateAsync(i.id)));

  const count = query.data?.configured ? filtered.length : 0;
  const pulse = usePulse<HTMLSpanElement>(count);
  const badge = count > 99 ? "99+" : count;
  const label = [
    "GitHub pull requests",
    count > 0 ? `${count} review ${count === 1 ? "request" : "requests"} waiting` : "",
    approvedCount > 0 ? `${approvedCount} of yours approved` : "",
  ]
    .filter(Boolean)
    .join(", ");

  const updatePrefs = useCallback((next: ReviewFilterPrefs) => {
    setPrefs(next);
    saveReviewFilterPrefs(window.localStorage, next);
  }, []);

  return (
    <Popover.Root open={open} onOpenChange={setOpen}>
      <Popover.Trigger asChild>
        <button
          type="button"
          aria-label={label}
          aria-expanded={open}
          title="GitHub review requests"
          data-pr-review-requests
          className={cx(
            "relative grid size-[30px] place-items-center rounded-md",
            open
              ? "bg-selected text-pill-review-fg ring-1 ring-state-review/50"
              : count > 0
                ? "bg-pill-review-bg text-pill-review-fg"
                : approvedCount > 0
                  ? "bg-pill-done-bg text-pill-done-fg"
                  : "text-fg-tertiary hover:bg-hover hover:text-fg",
          )}
        >
          <Icon name="pr" size={15} strokeWidth={1.6} />
          {count > 0 && (
            <span
              ref={pulse}
              aria-hidden
              className="absolute -right-1.5 -top-1.5 grid h-4 min-w-4 place-items-center rounded-full bg-state-review px-1 text-10 font-semibold leading-none text-on-accent"
            >
              {badge}
            </span>
          )}
          {approvedCount > 0 && (
            <span
              ref={approvedPulse}
              aria-hidden
              data-pr-approved-badge
              className="absolute -bottom-1.5 -right-1.5 grid h-4 min-w-4 place-items-center rounded-full bg-state-done px-1 text-10 font-semibold leading-none text-on-accent"
            >
              {approvedCount > 99 ? "99+" : approvedCount}
            </span>
          )}
        </button>
      </Popover.Trigger>
      <Popover.Portal>
        <Popover.Content
          side="left"
          align="end"
          sideOffset={12}
          collisionPadding={8}
          aria-label="GitHub review requests"
          onOpenAutoFocus={(e) => e.preventDefault()}
          className="motion-flyout z-50 flex max-h-[min(640px,calc(100dvh-24px))] w-[440px] max-w-[calc(100vw-16px)] flex-col overflow-hidden rounded-[14px] border border-border-float bg-surface-raised shadow-[var(--shadow-float)] outline-none"
        >
          <FeedTray
            data={query.data}
            isPending={query.isPending}
            isError={query.isError}
            errorMessage={query.error instanceof Error ? query.error.message : undefined}
            isRefreshing={refresh.isPending}
            items={filtered}
            counts={counts}
            prefs={prefs}
            onChangePrefs={updatePrefs}
            onRetry={() => void query.refetch()}
            onRefresh={() => refresh.mutate()}
            approved={approved}
            isClearing={read.isPending}
            onRead={(id) => read.mutate(id)}
            onClear={() => void clearApproved()}
            onClose={() => setOpen(false)}
          />
        </Popover.Content>
      </Popover.Portal>
    </Popover.Root>
  );
}

function FeedTray({
  data,
  isPending,
  isError,
  errorMessage,
  isRefreshing,
  items,
  counts,
  prefs,
  onChangePrefs,
  onRetry,
  onRefresh,
  approved,
  isClearing,
  onRead,
  onClear,
  onClose,
}: {
  approved: Schemas["InboxItem"][];
  isClearing: boolean;
  onRead: (id: string) => void;
  onClear: () => void;
  data: Schemas["GitHubReviewRequestsResponse"] | undefined;
  isPending: boolean;
  isError: boolean;
  errorMessage?: string;
  isRefreshing: boolean;
  items: ReviewItem[];
  counts: { direct: number; team: number };
  prefs: ReviewFilterPrefs;
  onChangePrefs: (next: ReviewFilterPrefs) => void;
  onRetry: () => void;
  onRefresh: () => void;
  onClose: () => void;
}) {
  const [sel, setSel] = useState<{ id?: string; index: number }>({ index: 0 });
  const ids = items.map((i) => i.id);
  const current = nextSelection(ids, sel.id, sel.index);
  const at = current ? ids.indexOf(current) : 0;
  if (current !== sel.id || at !== sel.index) setSel({ id: current, index: at });

  const focused = useRef(false);
  useEffect(() => {
    if (!current) return;
    const lost = !document.activeElement || document.activeElement === document.body;
    if (focused.current && !lost) return;
    focused.current = true;
    prRowEl(current)?.focus();
  }, [current]);

  const select = (id: string | undefined) => {
    setSel({ id, index: id ? ids.indexOf(id) : 0 });
    if (id) prRowEl(id)?.focus();
  };

  useEffect(() => {
    const onKeyDown = (e: KeyboardEvent) => {
      if (e.metaKey || e.ctrlKey || e.altKey || isTyping(e.target)) return;
      const k = e.key.length === 1 ? e.key.toLowerCase() : e.key;
      if (k === "j" || k === "k" || k === "ArrowDown" || k === "ArrowUp") {
        e.preventDefault();
        select(step(ids, current, k === "j" || k === "ArrowDown" ? 1 : -1));
        return;
      }
      if (k === "r") {
        e.preventDefault();
        onRefresh();
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  });

  const configured = data?.configured ?? true;
  const syncedText = data?.synced_at ? relativeAge(data.synced_at) : "";
  const bothOff = !prefs.direct && !prefs.team;

  return (
    <div data-pr-tray className="flex min-h-0 flex-1 flex-col">
      <div className="flex items-center gap-2 px-3.5 pb-2.5 pt-3">
        <Icon name="pr" size={15} className="text-pill-review-fg" />
        <span className="text-13 font-semibold text-fg">Review requests</span>
        {configured && (
          <span className="rounded-full bg-pill-review-bg px-1.5 py-0.5 font-mono text-11 font-semibold leading-none text-pill-review-fg">
            {items.length}
          </span>
        )}
        <div className="ml-auto flex items-center gap-2">
          {syncedText && <span className="text-11 text-fg-tertiary">Synced {syncedText}</span>}
          <button
            type="button"
            onClick={onRefresh}
            disabled={isRefreshing || !configured}
            aria-label="Refresh review requests"
            title="Refresh (R)"
            className="grid size-6 place-items-center rounded-md text-fg-secondary hover:bg-hover hover:text-fg disabled:opacity-40"
          >
            {isRefreshing ? (
              <Spinner size={12} />
            ) : (
              <svg
                aria-hidden
                viewBox="0 0 16 16"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.5"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="size-3.5"
              >
                <path d="M13 6.5A5.2 5.2 0 0 0 3.8 5L2.5 6.3M2.5 3v3.3h3.3" />
                <path d="M3 9.5A5.2 5.2 0 0 0 12.2 11l1.3-1.3M13.5 13V9.7h-3.3" />
              </svg>
            )}
          </button>
        </div>
      </div>

      <div className="flex items-center gap-4 border-y border-border-subtle bg-surface px-3.5 py-2">
        <Toggle
          checked={prefs.direct}
          onChange={(direct) => onChangePrefs({ ...prefs, direct })}
          label={
            <span className="flex items-center gap-1.5 text-12 font-medium text-fg">
              Direct
              <span className="rounded bg-pill-neutral-bg px-1.5 py-0.5 font-mono text-10.5 leading-none text-fg-2">
                {counts.direct}
              </span>
            </span>
          }
        />
        <Toggle
          checked={prefs.team}
          onChange={(team) => onChangePrefs({ ...prefs, team })}
          label={
            <span className="flex items-center gap-1.5 text-12 font-medium text-fg">
              Team
              <span className="rounded bg-pill-neutral-bg px-1.5 py-0.5 font-mono text-10.5 leading-none text-fg-2">
                {counts.team}
              </span>
            </span>
          }
        />
        <span className="ml-auto text-11 text-fg-tertiary">Badge counts active</span>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-1.5 py-1.5">
        {approved.length > 0 && (
          <section data-pr-approved aria-label="Approved pull requests" className="mb-1.5 border-b border-border-subtle pb-1.5">
            <div className="flex items-center gap-2 px-2.5 py-1">
              <Icon name="check" size={13} className="text-pill-done-fg" />
              <span className="text-12 font-semibold text-fg">Your PRs approved</span>
              <span className="rounded-full bg-pill-done-bg px-1.5 py-0.5 font-mono text-11 font-semibold leading-none text-pill-done-fg">
                {approved.length}
              </span>
              <button
                type="button"
                onClick={onClear}
                disabled={isClearing}
                className="ml-auto rounded-md px-2 py-1 text-12 font-medium text-accent hover:bg-hover disabled:opacity-60"
              >
                Clear
              </button>
            </div>
            <ul className="flex flex-col gap-px">
              {approved.map((item) => (
                <li key={item.id}>
                  <a
                    href={item.href}
                    target="_blank"
                    rel="noopener noreferrer"
                    onClick={() => {
                      onRead(item.id);
                      onClose();
                    }}
                    className="flex flex-col gap-0.5 rounded-[9px] px-2.5 py-1.5 outline-none hover:bg-hover focus-visible:ring-1 focus-visible:ring-accent/60"
                  >
                    <span className="truncate text-13 font-medium text-fg">{item.title}</span>
                    <span className="truncate text-11.5 text-fg-tertiary">
                      {item.summary} · {relativeAge(item.created_at)}
                    </span>
                  </a>
                </li>
              ))}
            </ul>
          </section>
        )}
        {isPending ? (
          <div aria-busy="true" className="space-y-2 p-2">
            {[0, 1, 2].map((i) => (
              <Skeleton key={i} className="h-[58px]" />
            ))}
          </div>
        ) : isError ? (
          <div role="alert" className="flex items-center justify-between gap-3 p-4 text-13 text-pill-blocked-fg">
            <span>{errorMessage || "Couldn’t load GitHub review requests."}</span>
            <Button onClick={onRetry}>Retry</Button>
          </div>
        ) : !configured ? (
          <EmptyState compact icon="github" title="GitHub isn’t connected">
            Add a <span className="font-mono">git:pat</span> token in{" "}
            <Link href="/settings" onClick={onClose} className="text-accent hover:underline">
              Settings
            </Link>{" "}
            to see PR review requests.
          </EmptyState>
        ) : bothOff ? (
          <EmptyState compact icon="pr" title="Both filters are off">
            Turn on Direct or Team above to see review requests.
          </EmptyState>
        ) : items.length === 0 ? (
          <EmptyState compact icon="check" title="No PRs waiting for your review">
            {prefs.direct && !prefs.team
              ? "No direct review requests right now."
              : !prefs.direct && prefs.team
                ? "No team review requests right now."
                : "You’re all caught up on GitHub."}
          </EmptyState>
        ) : (
          <ul className="flex flex-col gap-px">
            {items.map((item) => (
              <ReviewRow
                key={item.id}
                item={item}
                selected={item.id === current}
                onSelect={() => setSel({ id: item.id, index: ids.indexOf(item.id) })}
                onOpen={onClose}
              />
            ))}
          </ul>
        )}
      </div>

      <div className="flex items-center gap-3 border-t border-border-subtle px-3.5 py-2 text-12 text-fg-tertiary">
        <span aria-hidden className="hidden items-center gap-2.5 min-[480px]:flex">
          <span>
            <Kbd>J</Kbd> <Kbd>K</Kbd> move
          </span>
          <span>
            <Kbd>Enter</Kbd> open
          </span>
          <span>
            <Kbd>R</Kbd> refresh
          </span>
        </span>
        <a
          href="https://github.com/pulls/review-requested"
          target="_blank"
          rel="noopener noreferrer"
          onClick={onClose}
          className="ml-auto font-medium text-accent hover:underline"
        >
          Open on GitHub →
        </a>
      </div>
    </div>
  );
}

function ReviewRow({
  item,
  selected,
  onSelect,
  onOpen,
}: {
  item: ReviewItem;
  selected: boolean;
  onSelect: () => void;
  onOpen: () => void;
}) {
  const age = relativeAge(item.updated_at);
  return (
    <li>
      <a
        href={item.url}
        target="_blank"
        rel="noopener noreferrer"
        data-pr-row={item.id}
        aria-current={selected || undefined}
        onFocus={onSelect}
        onMouseEnter={onSelect}
        onClick={onOpen}
        className={cx(
          "group flex items-start gap-2.5 rounded-[9px] px-2.5 py-2 outline-none transition-colors",
          selected ? "bg-selected" : "hover:bg-hover",
        )}
      >
        {item.author_avatar_url ? (
          // eslint-disable-next-line @next/next/no-img-element -- external GitHub avatar URL
          <img
            src={item.author_avatar_url}
            alt=""
            className="mt-0.5 size-6 flex-none rounded-full border border-border-strong bg-surface object-cover"
          />
        ) : (
          <span
            aria-hidden
            className="mt-0.5 grid size-6 flex-none place-items-center rounded-full border border-border-strong bg-surface text-10 font-semibold text-fg-2"
          >
            {authorInitials(item.author_login)}
          </span>
        )}
        <div className="min-w-0 flex-1">
          <div className="flex items-start justify-between gap-2">
            <span className={cx("truncate text-13 font-medium", item.draft ? "text-fg-2" : "text-fg")}>
              {item.title}
            </span>
            <div className="flex flex-none items-center gap-1">
              {item.draft && (
                <span className="rounded px-1.5 py-0.5 text-10.5 font-medium leading-none bg-pill-neutral-bg text-fg-tertiary">
                  Draft
                </span>
              )}
              {item.direct && (
                <span className="rounded px-1.5 py-0.5 text-10.5 font-semibold leading-none bg-pill-review-bg text-pill-review-fg">
                  Direct
                </span>
              )}
              {item.team && (
                <span className="max-w-[110px] truncate rounded px-1.5 py-0.5 text-10.5 font-medium leading-none bg-pill-neutral-bg text-pill-neutral-fg">
                  {item.teams?.[0] ?? "Team"}
                </span>
              )}
            </div>
          </div>
          <div className="mt-0.5 flex items-center justify-between gap-2 text-11.5 text-fg-tertiary">
            <span className="truncate">
              <span className="font-mono text-fg-2">{item.repository} #{item.number}</span>
              {" · "}@{item.author_login}
              {age ? ` · ${age}` : ""}
            </span>
            <span className="flex-none font-mono text-11">
              <span className="text-pill-done-fg">+{item.additions}</span>{" "}
              <span className="text-pill-blocked-fg">-{item.deletions}</span>
            </span>
          </div>
        </div>
      </a>
    </li>
  );
}
