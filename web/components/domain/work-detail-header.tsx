"use client";

import Link from "next/link";
import { Fragment, type ReactNode } from "react";
import { cx } from "@/lib/cx";

/** Shared centered editorial column across Work detail pages (Run, Ticket, Epic). */
export const WORK_COLUMN = "mx-auto w-full max-w-[820px] px-6 max-sm:px-4";

export type EyebrowItem = {
  label: ReactNode;
  href?: string;
  mono?: boolean;
  accent?: boolean;
};

/** Quiet breadcrumb eyebrow above a Work detail title. */
export function WorkEyebrow({ items }: { items: EyebrowItem[] }) {
  if (!items.length) return null;
  return (
    <nav aria-label="Context path" className="flex flex-wrap items-center gap-1.5 text-11 text-fg-tertiary">
      {items.map((item, i) => {
        const cls = cx(
          item.mono && "font-mono",
          item.href
            ? item.accent
              ? "text-accent hover:underline"
              : "text-fg-secondary hover:text-fg hover:underline"
            : undefined,
        );
        return (
          <Fragment key={i}>
            {i > 0 && <span aria-hidden className="text-fg-tertiary/60">/</span>}
            {item.href ? (
              <Link href={item.href} className={cls}>
                {item.label}
              </Link>
            ) : (
              <span className={cls}>{item.label}</span>
            )}
          </Fragment>
        );
      })}
    </nav>
  );
}

export type WorkViewTabItem = {
  key: string;
  label: string;
  count?: number;
};

/** Compact pill tab strip shared across Run, Ticket, and Epic detail views. */
export function WorkViewTabs({
  label,
  value,
  onChange,
  items,
  trailing,
  className,
}: {
  label: string;
  value: string;
  onChange: (key: string) => void;
  items: WorkViewTabItem[];
  trailing?: ReactNode;
  className?: string;
}) {
  return (
    <div className={cx("flex flex-wrap items-center gap-2 border-b border-border-subtle pb-2.5", className)}>
      <div role="tablist" aria-label={label} className="flex flex-wrap items-center gap-1">
        {items.map((item) => {
          const active = item.key === value;
          return (
            <button
              key={item.key}
              type="button"
              role="tab"
              aria-selected={active}
              onClick={() => onChange(item.key)}
              className={cx(
                "inline-flex h-7 items-center gap-1.5 rounded-md px-2.5 text-12 transition-colors",
                active
                  ? "bg-selected font-medium text-fg"
                  : "text-fg-secondary hover:bg-hover hover:text-fg",
              )}
            >
              <span>{item.label}</span>
              {item.count != null && (
                <span className={cx("font-mono text-11", active ? "text-fg-secondary" : "text-fg-tertiary")}>
                  {item.count}
                </span>
              )}
            </button>
          );
        })}
      </div>
      {trailing && (
        <div className="ml-auto flex items-center gap-2 font-mono text-11 text-fg-tertiary">
          {trailing}
        </div>
      )}
    </div>
  );
}

/**
 * Calm, document-first header shared across Run, Ticket, and Epic detail pages:
 * quiet eyebrow, display title, single scannable meta line + compact actions, and
 * optional inline view tabs. Heavy facts and telemetry live in the right companion dock.
 */
export function WorkDetailHeader({
  eyebrow,
  title,
  meta,
  actions,
  notice,
  tabs,
  className,
}: {
  eyebrow?: ReactNode;
  title: ReactNode;
  meta?: ReactNode;
  actions?: ReactNode;
  notice?: ReactNode;
  tabs?: ReactNode;
  className?: string;
}) {
  return (
    <header className={cx("flex flex-col gap-2.5", className)}>
      {eyebrow}
      <div className="flex flex-wrap items-start gap-3">
        <div className="min-w-0 flex-1">{title}</div>
        {actions && <div className="flex flex-none flex-wrap items-center gap-1.5">{actions}</div>}
      </div>
      {meta && (
        <div className="flex flex-wrap items-center gap-x-2 gap-y-1.5 text-12 text-fg-secondary">
          {meta}
        </div>
      )}
      {notice}
      {tabs && <div className="pt-1.5">{tabs}</div>}
    </header>
  );
}
