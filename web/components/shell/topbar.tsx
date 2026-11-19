"use client";

import Link from "next/link";
import { Fragment, useEffect, type ReactNode } from "react";
import type { NativeAction } from "@/lib/native-shell/actions";
import { setTopBarTitle } from "@/lib/native-shell/title";
import { useNativeActions } from "@/lib/native-shell/use-native-actions";

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
 * Publishes the window title and native toolbar actions to the Mac shell. Only renders a compact
 * parent-breadcrumb strip when a screen has parent crumbs above the current page.
 */
export function TopBar({ crumbs, nativeActions, nativeTitle }: {
  crumbs?: Crumb[];
  nativeActions?: NativeAction[];
  /** The window's title and subtitle when the current crumb is not plain text. */
  nativeTitle?: { title: string; subtitle?: string };
}) {
  useNativeActions(nativeActions);
  const current = crumbs?.at(-1)?.label;
  const plain = typeof current === "string" || typeof current === "number" ? String(current) : null;
  const title = nativeTitle?.title ?? plain;
  const subtitle = nativeTitle?.subtitle;
  useEffect(() => {
    if (!title) return;
    const token = Symbol("topbar");
    setTopBarTitle(token, { title, ...(subtitle ? { subtitle } : {}) });
    return () => setTopBarTitle(token, null);
  }, [title, subtitle]);
  if ((crumbs?.length ?? 0) <= 1) return null;
  return (
    <header className="flex min-h-[44px] flex-none flex-wrap items-center gap-3 border-b border-border-subtle py-1.5 pl-3 pr-6 max-md:pl-6">
      <Breadcrumb items={crumbs!} hideCurrent={!!title} />
    </header>
  );
}

/** Page body container: max 1180, padding 32/28 (DESIGN.md §3). */
export function Content({ children, wide }: { children: ReactNode; wide?: boolean }) {
  return (
    <div className={wide ? "w-full px-7 py-8" : "mx-auto w-full max-w-[var(--content-max)] px-7 py-8 max-sm:px-4"}>{children}</div>
  );
}
