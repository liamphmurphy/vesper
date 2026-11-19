"use client";

import Link from "next/link";
import { workSettingsHref } from "@/lib/spaces";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { DropdownMenu } from "radix-ui";
import { useBootstrap } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { currentProject, pickerHref } from "@/lib/project-scope";
import { Icon } from "@/components/ui/icon";
import { floatPanel } from "@/components/domain/pickers";
import { rememberProject, useRememberedProject } from "./project-scope";
import { PROJECT_PICKER_ACTION, PROJECT_PICKER_OPEN, projectPickerAction } from "@/lib/native-shell/models/project-picker";
import type { NativeCommand } from "@/lib/native-shell/protocol";

const menuItem =
  "flex h-8 cursor-default select-none items-center gap-2.5 rounded-md px-2 outline-none data-[highlighted]:bg-hover";

/** The picker for the native sidebar: a header action with a menu, and what a chosen menu item does. */
export function useProjectPickerNative(allowAll = true) {
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  const remembered = useRememberedProject();
  const projects = useBootstrap().data?.projects ?? [];
  const active = projects.filter((p) => !p.archived);
  const current = currentProject(pathname, search, remembered, projects);
  const action = projectPickerAction({ projects: active, current, allowAll });
  /** Handles nav.action commands for the picker; returns whether it was one. */
  const handle = (cmd: NativeCommand): boolean => {
    if (cmd.type !== "nav.action" || cmd.actionId !== PROJECT_PICKER_ACTION || !cmd.menuItemId) return false;
    if (cmd.menuItemId === PROJECT_PICKER_OPEN) {
      router.push(workSettingsHref(current));
      return true;
    }
    const key = cmd.menuItemId.replace(/^space:/, "") || null;
    const href = pickerHref(pathname, new URLSearchParams(search.toString()), key);
    if (!href || !key) rememberProject(key);
    if (href) router.push(href);
    return true;
  };
  return { action, handle };
}

/**
 * The project a page shows, in its header: projects are context, not a
 * place, so each page that lists one project's work picks it here.
 * allowAll: offer "All spaces" (pages that list every project's work).
 */
export function ProjectPicker({ allowAll = true }: { allowAll?: boolean }) {
  const router = useRouter();
  const pathname = usePathname();
  const search = useSearchParams();
  const remembered = useRememberedProject();
  const projects = useBootstrap().data?.projects ?? [];
  const active = projects.filter((p) => !p.archived);
  const current = currentProject(pathname, search, remembered, projects);
  function pick(value: string) {
    const key = value || null;
    const href = pickerHref(pathname, new URLSearchParams(search.toString()), key);
    // A chosen project is remembered when its route opens (useProjectScope);
    // remembering first would also fire the chooser page's own redirect.
    // "All spaces" must be forgotten before navigating, or the bare route
    // would redirect back to the old project.
    if (!href || !key) rememberProject(key);
    if (href) router.push(href);
  }
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          aria-label={`Switch space, current: ${current?.name ?? "All spaces"}`}
          className="flex h-[30px] max-w-[240px] items-center gap-2 rounded-md border border-border-strong bg-surface px-2.5 text-left hover:bg-hover data-[state=open]:border-accent"
        >
          {current ? (
            <span aria-hidden className="size-2.5 flex-none rounded-[3px]" style={{ background: current.color }} />
          ) : (
            <Icon name="folder" size={12} className="flex-none text-fg-tertiary" />
          )}
          <span className="truncate text-13 font-medium">{current?.name ?? "All spaces"}</span>
          <svg aria-hidden width="12" height="12" viewBox="0 0 12 12" fill="none" stroke="currentColor" strokeWidth="1.5" className="flex-none text-fg-tertiary">
            <path d="m3 4.5 3-3 3 3M3 7.5l3 3 3-3" />
          </svg>
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "w-[260px]")}>
          <DropdownMenu.RadioGroup value={current?.key ?? ""} onValueChange={pick}>
            {allowAll && (
              <>
                <DropdownMenu.RadioItem value="" className={menuItem}>
                  <Icon name="folder" size={12} className="text-fg-secondary" />
                  <span className="flex-1">All spaces</span>
                  <DropdownMenu.ItemIndicator><Icon name="check" size={14} className="text-accent" /></DropdownMenu.ItemIndicator>
                </DropdownMenu.RadioItem>
                <DropdownMenu.Separator className="my-1 h-px bg-border-strong" />
              </>
            )}
            {active.map((p) => (
              <DropdownMenu.RadioItem key={p.key} value={p.key} className={menuItem}>
                <span aria-hidden className="size-2.5 flex-none rounded-[3px]" style={{ background: p.color }} />
                <span className="flex-1 truncate">{p.name}</span>
                <span className="font-mono text-12 text-fg-tertiary">{p.key}</span>
                <span className="grid w-3.5 place-items-center">
                  <DropdownMenu.ItemIndicator><Icon name="check" size={14} className="text-accent" /></DropdownMenu.ItemIndicator>
                </span>
              </DropdownMenu.RadioItem>
            ))}
          </DropdownMenu.RadioGroup>
          <DropdownMenu.Separator className="my-1 h-px bg-border-strong" />
          <DropdownMenu.Item asChild className={menuItem}>
            <Link href={workSettingsHref(current)}>
              <Icon name={current ? "gear" : "plus"} size={12} className="text-fg-secondary" />
              {current ? `Open ${current.name}` : "New space"}
            </Link>
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}
