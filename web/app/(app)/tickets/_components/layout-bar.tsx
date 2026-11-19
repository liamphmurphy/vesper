"use client";

import { useRouter, useSearchParams } from "next/navigation";
import type { ReactNode } from "react";
import { layoutSwitchHref, type TicketsLayout } from "@/lib/tickets-layout";
import { useProjectPickerNative } from "@/components/shell/project-picker";
import { type Crumb } from "@/components/shell/topbar";
import { useNativeToolbar } from "@/lib/native-shell/use-native-toolbar";
import { buildTicketsToolbar, parseTicketsToolbarAction } from "@/lib/native-shell/models/tickets-toolbar";
import { PROJECT_PICKER_ACTION } from "@/lib/native-shell/models/project-picker";
import type { ToolbarItem } from "@/lib/native-shell/protocol";
import { useNativeTitle } from "./native-title";

/** A layout's primary action: New ticket, or Open the space for an archived one. */
export type TicketsAction = { label: string; href: string; primary: boolean };

/**
 * Registers every Tickets layout's native window title, project picker, layout switch, and
 * layout-specific toolbar actions with the Mac shell.
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
