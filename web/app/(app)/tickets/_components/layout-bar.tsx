"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import type { ReactNode } from "react";
import { cx } from "@/lib/cx";
import { useCompact } from "@/lib/viewport";
import { TICKETS_LAYOUTS, TICKETS_LAYOUT_LABEL, layoutSwitchHref, type TicketsLayout } from "@/lib/tickets-layout";
import { ButtonLink } from "@/components/ui/button";
import { ProjectPicker, useProjectPickerNative } from "@/components/shell/project-picker";
import { TopBar, type Crumb } from "@/components/shell/topbar";
import { useIsNativeShell } from "@/lib/native-shell/hooks";
import { useNativeToolbar } from "@/lib/native-shell/use-native-toolbar";
import { buildTicketsToolbar, parseTicketsToolbarAction } from "@/lib/native-shell/models/tickets-toolbar";
import { PROJECT_PICKER_ACTION } from "@/lib/native-shell/models/project-picker";
import type { ToolbarItem } from "@/lib/native-shell/protocol";
import { useNativeTitle } from "./native-title";

function LayoutSwitch({ layout, current, compact }: { layout: TicketsLayout; current: URLSearchParams; compact: boolean }) {
  return (
    <nav aria-label="Tickets layout" className={cx("flex rounded-lg border border-border-strong bg-surface-sunken p-0.5", compact && "w-full")}>
      {TICKETS_LAYOUTS.map((l) => (
        <Link
          key={l}
          href={layoutSwitchHref(l, current)}
          aria-current={l === layout ? "page" : undefined}
          className={cx(
            "flex items-center rounded-md px-3",
            compact ? "h-[32px] flex-1 justify-center text-13" : "h-[26px] text-13",
            l === layout ? "bg-selected font-medium text-fg shadow-[inset_0_0_0_1px_var(--border-strong)]" : "text-fg-secondary hover:text-fg",
          )}
        >
          {TICKETS_LAYOUT_LABEL[l]}
        </Link>
      ))}
    </nav>
  );
}

/** A layout's primary action: New ticket, or Open the space for an archived one. */
export type TicketsAction = { label: string; href: string; primary: boolean };

/**
 * Every Tickets layout's one top bar on wide screens: back and forward, the project as a pill in the
 * breadcrumb, then the rest of the crumbs; the layout's primary action and List · Board · Epics on
 * the right. The same bar on all three layouts, so switching layouts doesn't move the header.
 *
 * In the Mac app it draws no row: the last crumb is the window's title (with `subtitle`), the
 * project, the layout switch and the action are toolbar items, and `extra` (the screen's own
 * items, with `onExtra` for their presses) sit between the project and the layout switch.
 */
export function TicketsTopBar({ layout, crumbs = [{ label: "Tickets" }], action, subtitle, extra, onExtra }: {
  layout: TicketsLayout;
  crumbs?: Crumb[];
  action?: TicketsAction;
  subtitle?: string;
  extra?: ToolbarItem[];
  onExtra?: (itemId: string, menuItemId?: string) => void;
}) {
  const params = useSearchParams();
  const router = useRouter();
  const native = useIsNativeShell();
  const current = new URLSearchParams(params.toString());
  // The board shows one project at a time, so it doesn't offer All projects.
  const picker = useProjectPickerNative(layout !== "board");
  const last = crumbs.at(-1)?.label;
  useNativeTitle(typeof last === "string" ? last : "Tickets", subtitle);
  useNativeToolbar({
    items: buildTicketsToolbar({
      space: { label: picker.action.label, menu: picker.action.menu ?? [] },
      layout,
      action: action && { label: action.label, primary: action.primary },
      extra,
    }),
    onAction: (itemId, menuItemId) => {
      const a = parseTicketsToolbarAction(itemId, menuItemId);
      if (!a) return onExtra?.(itemId, menuItemId);
      if (a.type === "space") picker.handle({ v: 1, type: "nav.action", navigatorId: "", actionId: PROJECT_PICKER_ACTION, menuItemId: a.menuItemId });
      else if (a.type === "layout") router.push(layoutSwitchHref(a.layout, current));
      else if (action) router.push(action.href);
    },
  });
  if (native) return null;
  return (
    <TopBar
      crumbs={[{ label: <ProjectPicker crumb allowAll={layout !== "board"} /> }, ...crumbs]}
      actions={
        <>
          {action && (
            <ButtonLink href={action.href} variant={action.primary ? "primary" : "outline"} icon={action.primary ? "plus" : undefined} hint={action.primary ? "C" : undefined}>
              {action.label}
            </ButtonLink>
          )}
          <LayoutSwitch layout={layout} current={current} compact={false} />
        </>
      }
    />
  );
}

/**
 * Compact screens: the whole Tickets header (the screens drop their top bar): the title, the
 * project and a + button, then the layout switch. Wide screens use TicketsTopBar instead.
 */
export function TicketsLayoutBar({ layout }: { layout: TicketsLayout }) {
  const params = useSearchParams();
  const compact = useCompact();
  const current = new URLSearchParams(params.toString());
  if (compact) {
    const project = params.get("project");
    return (
      <header className="flex flex-col gap-2.5 border-b border-border-subtle px-4 pb-2.5 pt-3">
        <div className="flex items-center gap-2">
          <h1 className="flex-1 type-heading text-18">Tickets</h1>
          {/* The board shows one project at a time, so it doesn't offer All projects. */}
          <div className="flex min-w-0 max-w-[60%]">
            <ProjectPicker allowAll={layout !== "board"} />
          </div>
          <ButtonLink
            href={`/tickets/new${project ? `?project=${encodeURIComponent(project)}` : ""}`}
            variant="primary"
            icon="plus"
            aria-label="New ticket"
            className="size-[36px] flex-none justify-center px-0"
          />
        </div>
        <LayoutSwitch layout={layout} current={current} compact />
      </header>
    );
  }
  return null;
}

/** Compact screens: filter controls on one line that scrolls sideways instead of wrapping. */
export function ChipScroller({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div
      role="group"
      aria-label={label}
      data-testid="filter-chips"
      className="relative flex flex-nowrap items-center gap-2 overflow-x-auto overscroll-x-contain border-b border-border-subtle px-4 py-2 [scrollbar-width:none] [&>*]:flex-none"
    >
      {children}
    </div>
  );
}
