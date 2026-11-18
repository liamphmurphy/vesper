"use client";

import Link from "next/link";
import { Fragment, useEffect, type ReactNode } from "react";
import { cx } from "@/lib/cx";
import { useIsNativeShell } from "@/lib/native-shell/hooks";
import type { NativeAction } from "@/lib/native-shell/actions";
import { setTopBarTitle } from "@/lib/native-shell/title";
import { useNativeActions } from "@/lib/native-shell/use-native-actions";
import { HistoryNav } from "./history-nav";

export type Crumb = { label: ReactNode; href?: string; swatch?: string; mono?: boolean };

export function Breadcrumb({ items, hideCurrent }: { items: Crumb[]; hideCurrent?: boolean }) {
  // hideCurrent: the native shell shows the current crumb as the window's title, so only its parents draw.
  if (hideCurrent) {
    const parents = items.slice(0, -1);
    if (parents.length === 0) return null;
    return (
      <nav aria-label="Breadcrumb" className="flex flex-wrap items-center gap-2 text-13 text-fg-tertiary">
        {parents.map((c, i) => (
          <Fragment key={i}>
            {c.href ? (
              <Link href={c.href} className="flex items-center gap-2 text-fg-2 hover:text-fg">
                {c.swatch && <span aria-hidden className="size-2.5 rounded-[3px]" style={{ background: c.swatch }} />}
                {c.label}
              </Link>
            ) : (
              <span className="flex items-center gap-2">{c.label}</span>
            )}
            {i < parents.length - 1 && <span aria-hidden>/</span>}
          </Fragment>
        ))}
      </nav>
    );
  }
  return (
    <nav aria-label="Breadcrumb" className="flex flex-wrap items-center gap-2 text-13 text-fg-tertiary">
      {items.map((c, i) => {
        const last = i === items.length - 1;
        if (last) {
          return (
            <span key={i} aria-current="page" className={c.mono ? "font-mono text-13 text-fg" : "font-medium text-fg"}>
              {c.label}
            </span>
          );
        }
        const inner = (
          <>
            {c.swatch && <span aria-hidden className="size-2.5 rounded-[3px]" style={{ background: c.swatch }} />}
            {c.label}
          </>
        );
        return (
          <Fragment key={i}>
            {c.href ? (
              <Link href={c.href} className="flex items-center gap-2 text-fg-2 hover:text-fg">
                {inner}
              </Link>
            ) : (
              <span className="flex items-center gap-2">{inner}</span>
            )}
            <span aria-hidden>/</span>
          </Fragment>
        );
      })}
    </nav>
  );
}

/**
 * A pane's 44px bar: back and forward, then the breadcrumb (or, for a pane with tabs, its tab
 * strip), left; actions right (secondary first, primary last). Every page's top bar is this one, so
 * its height and the back button's place never change between screens.
 */
export function TopBar({ crumbs, tabs, actions, nativeActions, nativeTitle }: {
  crumbs?: Crumb[];
  tabs?: ReactNode;
  actions?: ReactNode;
  /**
   * The same actions as native toolbar items, each with the handler to run. In the Mac app they go
   * to the window's toolbar and `actions` is not drawn; a browser draws `actions` as always. Give
   * this only when it covers every action in `actions`.
   */
  nativeActions?: NativeAction[];
  /** The window's title and subtitle when the current crumb is not plain text. */
  nativeTitle?: { title: string; subtitle?: string };
}) {
  const native = useIsNativeShell();
  const inToolbar = useNativeActions(nativeActions);
  // In the native shell the current crumb is the window's title, so the bar sends it and doesn't draw it.
  const current = !tabs ? crumbs?.at(-1)?.label : undefined;
  const plain = typeof current === "string" || typeof current === "number" ? String(current) : null;
  const title = native && !tabs ? (nativeTitle?.title ?? plain) : null;
  const subtitle = native && !tabs ? nativeTitle?.subtitle : undefined;
  useEffect(() => {
    if (!title) return;
    const token = Symbol("topbar");
    setTopBarTitle(token, { title, ...(subtitle ? { subtitle } : {}) });
    return () => setTopBarTitle(token, null);
  }, [title, subtitle]);
  // Nothing left to draw: the title and the actions are in the window's toolbar, back/forward too.
  const shownActions = inToolbar ? undefined : actions;
  const hasParents = (crumbs?.length ?? 0) > 1;
  if (native && title && !tabs && !hasParents && !shownActions) return null;
  return (
    <header className={cx(
      "flex min-h-[44px] flex-none items-center justify-between gap-3 border-b border-border-subtle pl-3 pr-6 max-md:pl-6",
      // Tabs sit on the bar's bottom rule, so the bar gives them its full height.
      tabs ? "items-stretch" : "flex-wrap py-1.5",
    )}>
      <div className={cx("flex min-w-0 gap-2", tabs ? "flex-1" : "items-center")}>
        <HistoryNav className={tabs ? "self-center" : undefined} />
        {tabs ?? (crumbs && <Breadcrumb items={crumbs} hideCurrent={!!title} />)}
      </div>
      {shownActions && <div className="flex flex-wrap items-center gap-2">{shownActions}</div>}
    </header>
  );
}

/** Page body container: max 1180, padding 32/28 (DESIGN.md §3). */
export function Content({ children, wide }: { children: ReactNode; wide?: boolean }) {
  return (
    <div className={wide ? "w-full px-7 py-8" : "mx-auto w-full max-w-[var(--content-max)] px-7 py-8 max-sm:px-4"}>{children}</div>
  );
}
