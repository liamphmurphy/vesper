"use client";

import type { ReactNode } from "react";
import { cx } from "@/lib/cx";
import type { NativeAction } from "@/lib/native-shell/actions";
import { useNativeActions } from "@/lib/native-shell/use-native-actions";

/**
 * The top of every index screen (DESIGN.md §3): a display title, one line or two saying what the
 * screen is for, the screen's primary actions on the right, and an optional row under it for
 * tabs, switches and pickers. Detail screens (a ticket, a run, a page) keep their own headers.
 */
export function PageHeader({ title, description, actions, nativeActions, children, className }: {
  title: ReactNode;
  description?: ReactNode;
  actions?: ReactNode;
  /** `actions` as native toolbar items, each with its handler; in the Mac app they go to the window's toolbar and `actions` is not drawn. Give only when it covers every action. */
  nativeActions?: NativeAction[];
  /** The row under the title: tab nav, source switches, project pickers. */
  children?: ReactNode;
  className?: string;
}) {
  const inToolbar = useNativeActions(nativeActions);
  return (
    <header className={cx("flex flex-col gap-3", className)}>
      <div className="flex flex-wrap items-start justify-between gap-x-4 gap-y-3">
        <div className="min-w-0 flex-1 space-y-1">
          <h1 className="type-display text-fg">{title}</h1>
          {description && <p className="max-w-[720px] text-14 text-fg-secondary">{description}</p>}
        </div>
        {actions && !inToolbar && <div className="flex flex-none flex-wrap items-center gap-2">{actions}</div>}
      </div>
      {children && <div className="flex flex-wrap items-center gap-3">{children}</div>}
    </header>
  );
}
