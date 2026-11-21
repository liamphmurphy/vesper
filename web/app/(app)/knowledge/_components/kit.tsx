"use client";

import { Dialog } from "radix-ui";
import { useSyncExternalStore, type ReactNode } from "react";
import { cx } from "@/lib/cx";
import { Icon, type IconName } from "@/components/ui/icon";
import type { Audience } from "@/lib/api/knowledge-hooks";

const noSubscribe = () => () => {};
let today: Date | undefined;
/**
 * Today, on the client only: the server render (prerendered, Cache
 * Components) has no "now", so it gets null and the date fills in on hydrate.
 * Kept to the minute so the snapshot is stable between renders.
 */
export function useToday(): Date | null {
  return useSyncExternalStore(
    noSubscribe,
    () => {
      const now = new Date();
      if (!today || now.getTime() - today.getTime() > 60_000) today = now;
      return today;
    },
    () => null,
  );
}

/** A centred modal over a scrim: the quick switcher, capture and the vault import. */
export function Modal({
  open,
  onOpenChange,
  title,
  children,
  className,
  hideTitle,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  title: string;
  children: ReactNode;
  className?: string;
  hideTitle?: boolean;
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby={undefined}
          className={cx(
            "fixed left-1/2 top-[12vh] z-50 flex max-h-[80vh] w-[min(640px,calc(100vw-32px))] -translate-x-1/2 flex-col overflow-hidden rounded-2xl border border-border-strong bg-surface-raised text-13 text-fg shadow-[var(--shadow-float)] outline-none",
            className,
          )}
        >
          <Dialog.Title className={hideTitle ? "sr-only" : "px-5 pt-4 type-heading"}>{title}</Dialog.Title>
          {children}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

export const AUDIENCE: Record<Audience, { label: string; icon: IconName; cls: string; detail: string }> = {
  private: { label: "Private", icon: "lock", cls: "bg-accent-soft text-accent", detail: "You and your personas. Never reaches ticket or epic runs." },
  shared: { label: "Shared", icon: "users", cls: "bg-pill-review-bg text-pill-review-fg", detail: "Also ticket and epic runs. Linked private pages stay private." },
  agent: { label: "Agent", icon: "agents", cls: "bg-pill-human-bg text-pill-human-fg", detail: "Agent memory and proposed patterns. Hidden from your views." },
};

export function AudienceChip({ audience, className }: { audience: Audience; className?: string }) {
  const a = AUDIENCE[audience];
  return (
    <span className={cx("inline-flex h-[26px] items-center gap-1.5 rounded-full px-2.5 text-12 font-semibold", a.cls, className)}>
      <Icon name={a.icon} size={13} />
      {a.label}
    </span>
  );
}

export function Tag({ children }: { children: ReactNode }) {
  return <span className="inline-flex h-5 items-center rounded-full bg-accent-soft px-2 text-11 font-medium text-accent">{children}</span>;
}

/** The thin bar under a Knowledge screen: what's going on at the left, counts at the right. */
export function StatusBar({ left, right }: { left?: ReactNode; right?: ReactNode }) {
  return (
    <div className="flex h-6 flex-none items-center gap-4 border-t border-border-subtle bg-panel px-4 text-11 text-fg-tertiary print:hidden">
      <span className="min-w-0 flex-1 truncate">{left}</span>
      <span className="flex flex-none items-center gap-4">{right}</span>
    </div>
  );
}

/** A small uppercase heading in a sidebar, with an optional count. */
export function SideHeading({ children, count, action }: { children: ReactNode; count?: number; action?: ReactNode }) {
  return (
    <div className="flex items-center gap-2 px-1 pb-2 pt-1">
      <span className="text-10 font-bold uppercase tracking-[0.06em] text-fg-tertiary">{children}</span>
      {count !== undefined && <span className="rounded-full bg-selected px-1.5 text-10 font-semibold text-fg-secondary">{count}</span>}
      <span className="flex-1" />
      {action}
    </div>
  );
}
