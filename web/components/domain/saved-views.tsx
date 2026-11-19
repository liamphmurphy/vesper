"use client";

import Link from "next/link";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { Dialog, DropdownMenu } from "radix-ui";
import { useEffect, useRef, useState, type FormEvent, type ReactNode } from "react";
import { cx } from "@/lib/cx";
import { ApiError } from "@/lib/api/client";
import { useCreateSavedView, useDeleteSavedView, useSavedViews, useUpdateSavedView, type SavedView } from "@/lib/api/hooks";
import { SUGGESTED_VIEWS, describeQuery, savedViewHref, viewQuery } from "@/lib/ticket-list";
import { Button, IconButton } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { floatPanel } from "./pickers";
import { hoverReveal } from "@/lib/reveal";
import { confirmAction } from "@/components/ui/confirm";
import { useNativeToolbar } from "@/lib/native-shell/use-native-toolbar";
import { type SavedViewRow, parseSavedViewCommand, parseSavedViewTitleAction, savedViewMenu } from "@/lib/native-shell/models/saved-views";
import type { NativeCommand, ToolbarItem } from "@/lib/native-shell/protocol";

const VIEW_NAME: Record<string, string> = { all: "All tickets", active: "Active", backlog: "Backlog", agent_owned: "Agent-owned", needs_human: "Needs human" };
export const describeView = (query: string) => describeQuery(query, { view: (v) => VIEW_NAME[v] ?? v });

const DUPLICATE = "You already have a view with that name";
const errorText = (e: Error | null) => (e instanceof ApiError && e.status === 409 ? DUPLICATE : e?.message);

const menuItem =
  "flex h-8 cursor-default select-none items-center gap-2.5 rounded-md px-2 outline-none data-[highlighted]:bg-hover";

function Bookmark({ on, className }: { on?: boolean; className?: string }) {
  return (
    <svg aria-hidden width="12" height="14" viewBox="0 0 12 14" className={cx("flex-none", className)} fill={on ? "currentColor" : "none"} stroke="currentColor" strokeWidth="1.3">
      <path d="M2 1.5h8v11L6 9.7l-4 2.8z" />
    </svg>
  );
}

/** Current /tickets view params, or empty when the list isn't open. */
function useCurrentQuery() {
  const pathname = usePathname();
  const search = useSearchParams();
  return pathname === "/tickets" ? viewQuery(new URLSearchParams(search.toString())) : "";
}

/**
 * Save view dialog: a name, what the view keeps, and suggested views that
 * fill the name and filters. Opens the new view on save.
 */
export function SaveViewDialog({ query, open, onOpenChange, onCreated }: { query: string; open: boolean; onOpenChange: (o: boolean) => void; onCreated?: (v: SavedView) => void }) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby="save-view-desc"
          className="motion-dialog fixed left-1/2 top-[14vh] z-50 w-[min(420px,calc(100%-32px))] -translate-x-1/2 rounded-xl border border-border-float bg-surface-raised p-4 shadow-[var(--shadow-float)] outline-none"
        >
          <SaveViewForm query={query} onSaved={() => onOpenChange(false)} onCreated={onCreated} />
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

/** Mounted with each open, so the name, query and save error start fresh. */
function SaveViewForm({ query, onSaved, onCreated }: { query: string; onSaved: () => void; onCreated?: (v: SavedView) => void }) {
  const create = useCreateSavedView();
  const router = useRouter();
  const search = useSearchParams();
  const [name, setName] = useState("");
  const [q, setQ] = useState(query);
  function submit(e: FormEvent) {
    e.preventDefault();
    if (!name.trim()) return;
    create.mutate(
      { name: name.trim(), query: q },
      {
        onSuccess: (v) => {
          onSaved();
          // A screen that keeps its own view state (Work) stays where it is.
          if (onCreated) onCreated(v);
          else router.push(savedViewHref(v, search.get("project")));
        },
      },
    );
  }
  return (
          <form onSubmit={submit} className="flex flex-col gap-3">
            <Dialog.Title className="type-heading">Save view</Dialog.Title>
            <label className="flex flex-col gap-1.5 text-12 text-fg-secondary">
              Name
              <input
                autoFocus
                value={name}
                maxLength={80}
                onChange={(e) => { setName(e.target.value); create.reset(); }}
                className="h-[30px] rounded-md border border-border-strong bg-surface px-2.5 text-13 text-fg outline-none focus:border-accent"
              />
            </label>
            <p id="save-view-desc" className="text-12 text-fg-tertiary">Saves: {describeView(q)}</p>
            <div className="flex flex-wrap items-center gap-1.5">
              <span className="text-12 text-fg-tertiary">Suggested</span>
              {SUGGESTED_VIEWS.map((s) => (
                <button
                  key={s.name}
                  type="button"
                  title={s.hint}
                  onClick={() => { setName(s.name); setQ(s.query); create.reset(); }}
                  className="h-[22px] rounded-full border border-border-strong px-2.5 text-12 text-fg-secondary hover:bg-hover"
                >
                  + {s.name}
                </button>
              ))}
            </div>
            {create.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{errorText(create.error)}</p>}
            <div className="flex justify-end gap-2">
              <Dialog.Close asChild>
                <Button variant="ghost">Cancel</Button>
              </Dialog.Close>
              <Button type="submit" variant="primary" disabled={!name.trim() || create.isPending}>
                Save view
              </Button>
            </div>
          </form>
  );
}

/** Deleting a view after the confirm; by default leaves the list's open view if it was this one. */
export function useDeleteSavedViewAction(onDeleted?: (view: SavedView) => void) {
  const del = useDeleteSavedView();
  const router = useRouter();
  const search = useSearchParams();
  return async (view: SavedView) => {
    if (!await confirmAction({ title: `Delete the view “${view.name}”?`, body: "Tickets aren't changed.", confirmLabel: "Delete view" })) return;
    del.mutate(view.id, {
      onSuccess: () => {
        if (onDeleted) return onDeleted(view);
        if (search.get("sv") === view.id) {
          const next = new URLSearchParams(search.toString());
          next.delete("sv");
          router.replace(`/tickets${next.size ? `?${next}` : ""}`);
        }
      },
    });
  };
}

const viewUrl = (view: SavedView, project: string | null) => new URL(savedViewHref(view, project), window.location.origin).toString();

/** ⋯ menu for a saved view: Rename, Save as new view…, Copy link, Delete view. */
export function SavedViewMenu({
  view,
  onRename,
  onSaveAs,
  children,
}: {
  view: SavedView;
  onRename: () => void;
  onSaveAs: () => void;
  children: ReactNode;
}) {
  const remove = useDeleteSavedViewAction();
  const search = useSearchParams();
  const project = search.get("project");
  // Rename mounts an autofocused input, so it starts once the menu has closed,
  // instead of focus returning to the trigger and blurring (closing) it.
  const renaming = useRef(false);
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>{children}</DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content
          align="end"
          sideOffset={6}
          className={cx(floatPanel, "w-[210px]")}
          onCloseAutoFocus={(e) => {
            if (!renaming.current) return;
            renaming.current = false;
            e.preventDefault();
            onRename();
          }}
        >
          <DropdownMenu.Item className={menuItem} onSelect={() => { renaming.current = true; }}>
            Rename
            <span className="ml-auto text-11 text-fg-tertiary">F2</span>
          </DropdownMenu.Item>
          <DropdownMenu.Item className={menuItem} onSelect={onSaveAs}>Save as new view…</DropdownMenu.Item>
          <DropdownMenu.Item
            className={menuItem}
            onSelect={() => void navigator.clipboard?.writeText(viewUrl(view, project))}
          >
            Copy link
          </DropdownMenu.Item>
          <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />
          <DropdownMenu.Item
            className={cx(menuItem, "text-pill-blocked-fg")}
            onSelect={() => void remove(view)}
          >
            Delete view
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** Inline rename: Enter saves, Esc cancels; a duplicate name shows the 409. */
function RenameInput({ view, onDone }: { view: SavedView; onDone: () => void }) {
  const update = useUpdateSavedView();
  const [name, setName] = useState(view.name);
  function save() {
    const next = name.trim();
    if (!next || next === view.name) return onDone();
    update.mutate({ id: view.id, name: next }, { onSuccess: onDone });
  }
  return (
    <div className="flex flex-col gap-0.5">
      <input
        autoFocus
        aria-label={`Rename ${view.name}`}
        value={name}
        maxLength={80}
        onFocus={(e) => e.currentTarget.select()}
        onChange={(e) => { setName(e.target.value); update.reset(); }}
        onKeyDown={(e) => {
          if (e.key === "Enter") { e.preventDefault(); save(); }
          if (e.key === "Escape") { e.preventDefault(); e.stopPropagation(); onDone(); }
        }}
        onBlur={() => !update.isPending && !update.isError && onDone()}
        className="h-[26px] rounded-[5px] border border-accent bg-surface px-2 text-13 text-fg outline-none"
      />
      {update.isError && <span role="alert" className="px-1 text-12 text-pill-blocked-fg">{errorText(update.error)}</span>}
    </div>
  );
}

/**
 * What the saved views' UI is doing: the view being renamed, and the query a Save view dialog is
 * open for. A screen that describes its views to the native sidebar holds this, since the sidebar
 * (not SavedViewTabs) is what mounts in the Mac app.
 */
export function useSavedViewsUi() {
  const [renaming, setRenaming] = useState<string | null>(null);
  const [saving, setSaving] = useState<string | null>(null);
  return { renaming, setRenaming, saving, setSaving };
}
export type SavedViewsUi = ReturnType<typeof useSavedViewsUi>;

/** Saved views after the list's built-in views, with + Save view. */
export function SavedViewTabs({ project, vertical = false, ui }: { project?: string; vertical?: boolean; ui?: SavedViewsUi }) {
  const views = useSavedViews();
  const pathname = usePathname();
  const search = useSearchParams();
  const current = useCurrentQuery();
  const own = useSavedViewsUi();
  const { renaming, setRenaming, saving, setSaving } = ui ?? own;
  const active = pathname === "/tickets" ? search.get("sv") : null;
  return (
    <div
      role="group"
      aria-label="Saved views"
      className={vertical ? "mt-2 flex flex-col gap-0.5" : "flex flex-wrap items-center gap-1 border-l border-border-strong pl-2"}
    >
      {vertical && <p className="px-2 pb-1 pt-2 text-10 font-semibold uppercase tracking-[0.06em] text-fg-tertiary">Saved views</p>}
      {(views.data ?? []).map((v) =>
        renaming === v.id ? (
          <RenameInput key={v.id} view={v} onDone={() => setRenaming(null)} />
        ) : (
          <div
            key={v.id}
            className={cx(
              "group/view flex items-center rounded-md pr-0.5",
              vertical ? "h-[26px] justify-between" : "h-7",
              active === v.id ? (vertical ? "bg-selected" : "bg-selected") : "hover:bg-hover",
            )}
          >
            <Link
              href={savedViewHref(v, project)}
              aria-current={active === v.id ? "page" : undefined}
              onKeyDown={(e) => { if (e.key === "F2") { e.preventDefault(); setRenaming(v.id); } }}
              className={cx(
                "flex min-w-0 items-center gap-1.5 pl-2 pr-1",
                vertical ? "flex-1 text-12" : "max-w-[180px] text-13",
                active === v.id ? "font-medium text-fg" : "text-fg-secondary hover:text-fg",
              )}
            >
              <Bookmark on={active === v.id} className={active === v.id ? "text-accent" : "text-fg-tertiary"} />
              <span className="truncate">{v.name}</span>
            </Link>
            <SavedViewMenu view={v} onRename={() => setRenaming(v.id)} onSaveAs={() => setSaving(v.query)}>
              <IconButton icon="dots" label={`${v.name} view actions`} size={22} className={cx(hoverReveal("view"), "focus-visible:opacity-100 data-[state=open]:opacity-100")} />
            </SavedViewMenu>
          </div>
        ),
      )}
      <button
        type="button"
        onClick={() => setSaving(current)}
        className={cx(
          "flex items-center gap-1.5 px-2 text-left text-12 text-fg-tertiary hover:bg-hover hover:text-fg",
          vertical ? "h-[26px] w-full rounded-md" : "h-7 rounded-md",
        )}
      >
        <Icon name="plus" size={12} />
        Save view
      </button>
      <SaveViewDialog query={saving ?? ""} open={saving !== null} onOpenChange={(o) => !o && setSaving(null)} />
    </div>
  );
}

/** Rename as a dialog, for the native shell where a row can't turn into a text field. A duplicate name shows the 409. */
export function RenameViewDialog({ view, onClose }: { view?: SavedView; onClose: () => void }) {
  return (
    <Dialog.Root open={!!view} onOpenChange={(o) => !o && onClose()}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content aria-describedby={undefined} className="motion-dialog fixed left-1/2 top-[16vh] z-50 w-[min(420px,calc(100%-32px))] -translate-x-1/2 rounded-xl border border-border-float bg-surface-raised p-4 shadow-[var(--shadow-float)] outline-none">
          {view && <RenameViewForm key={view.id} view={view} onDone={onClose} />}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function RenameViewForm({ view, onDone }: { view: SavedView; onDone: () => void }) {
  const update = useUpdateSavedView();
  const [name, setName] = useState(view.name);
  function submit(e: FormEvent) {
    e.preventDefault();
    const next = name.trim();
    if (!next || next === view.name) return onDone();
    update.mutate({ id: view.id, name: next }, { onSuccess: onDone });
  }
  return (
    <form onSubmit={submit} className="flex flex-col gap-3">
      <Dialog.Title className="type-heading">Rename view</Dialog.Title>
      <input
        autoFocus
        aria-label={`Rename ${view.name}`}
        value={name}
        maxLength={80}
        onFocus={(e) => e.currentTarget.select()}
        onChange={(e) => { setName(e.target.value); update.reset(); }}
        className="h-[30px] rounded-md border border-border-strong bg-surface px-2.5 text-13 text-fg outline-none focus:border-accent"
      />
      {update.isError && <p role="alert" className="text-12 text-pill-blocked-fg">{errorText(update.error)}</p>}
      <div className="flex justify-end gap-2">
        <Dialog.Close asChild><Button variant="ghost" type="button">Cancel</Button></Dialog.Close>
        <Button type="submit" variant="primary" disabled={!name.trim() || update.isPending}>Rename</Button>
      </div>
    </form>
  );
}

/**
 * The dialogs a native-sidebar screen opens from its saved views (SavedViewTabs draws its own in a
 * browser). `onCreated` is for a screen that opens a new view itself instead of going to /tickets.
 */
export function SavedViewNativeDialogs({ ui, onCreated }: { ui: SavedViewsUi; onCreated?: (v: SavedView) => void }) {
  const views = useSavedViews();
  return (
    <>
      <RenameViewDialog view={ui.renaming ? views.data?.find((v) => v.id === ui.renaming) : undefined} onClose={() => ui.setRenaming(null)} />
      <SaveViewDialog query={ui.saving ?? ""} open={ui.saving !== null} onOpenChange={(o) => !o && ui.setSaving(null)} onCreated={onCreated} />
    </>
  );
}

/**
 * The saved views as rows for a native sidebar section (buildSavedViewsSection: a menu per row,
 * "Save view…" on the header) and the handler for its commands; `handle` returns whether the command was one of theirs.
 * `open` opens a row for a screen whose rows carry no href; `current` is the query "Save view…" saves.
 */
export function useSavedViewsNav({ ui, current, project, open, onDeleted }: {
  ui: SavedViewsUi;
  current: string;
  project?: string | null;
  open?: (v: SavedView) => void;
  onDeleted?: (v: SavedView) => void;
}): { rows: SavedViewRow[]; handle: (cmd: NativeCommand) => boolean } {
  const list = useSavedViews().data ?? [];
  const remove = useDeleteSavedViewAction(onDeleted);
  const rows = list.map((v) => ({ id: v.id, name: v.name, ...(open ? {} : { href: savedViewHref(v, project ?? null) }) }));
  const handle = (cmd: NativeCommand) => {
    const c = parseSavedViewCommand(cmd);
    if (!c) return false;
    if (c.type === "save") return ui.setSaving(current), true;
    const view = list.find((v) => v.id === c.id);
    if (!view) return true;
    if (c.type === "open") open?.(view);
    else if (c.type === "rename") ui.setRenaming(view.id);
    else if (c.type === "saveAs") ui.setSaving(view.query);
    else if (c.type === "copyLink") void navigator.clipboard?.writeText(viewUrl(view, project ?? null));
    else void remove(view);
    return true;
  };
  return { rows, handle };
}

/** The line under an open view's title: what it keeps, and what it was saved as once edited. */
export function savedViewSubtitle(view: SavedView, search: URLSearchParams): string {
  const now = viewQuery(search);
  const saved = viewQuery(view.query);
  return now === saved ? describeView(now) : `Edited · ${describeView(now)} · saved as ${describeView(saved)}`;
}

/**
 * Header for an open saved view: its name, an Edited badge when the list's
 * params differ, Discard / Save changes, and the ⋯ menu.
 */
export function SavedViewHeader({ view }: { view: SavedView }) {
  const router = useRouter();
  const search = useSearchParams();
  const update = useUpdateSavedView();
  const [renaming, setRenaming] = useState(false);
  const [saving, setSaving] = useState(false);
  const now = viewQuery(new URLSearchParams(search.toString()));
  const saved = viewQuery(view.query);
  useEffect(() => {
    function onKey(e: KeyboardEvent) {
      if (e.key !== "F2" || e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey || document.querySelector('[role="dialog"], [role="menu"]')) return;
      const el = e.target;
      if (el instanceof HTMLElement && (el.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(el.tagName))) return;
      e.preventDefault();
      setRenaming(true);
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
  const edited = now !== saved;
  const remove = useDeleteSavedViewAction();
  const project = search.get("project");
  const items: ToolbarItem[] = edited
    ? [
        { id: "sv.discard", label: "Discard", kind: "button", icon: "refresh", showsLabel: true },
        { id: "sv.save-changes", label: "Save changes", kind: "button", icon: "check", showsLabel: true, disabled: update.isPending },
      ]
    : [];
  useNativeToolbar({
    items,
    onAction: (id) => {
      if (id === "sv.discard") router.replace(savedViewHref(view, project));
      else if (id === "sv.save-changes") update.mutate({ id: view.id, query: now });
    },
    titleMenu: savedViewMenu(),
    onTitleAction: (id) => {
      const a = parseSavedViewTitleAction(id);
      if (a === "rename") setRenaming(true);
      else if (a === "saveAs") setSaving(true);
      else if (a === "copyLink") void navigator.clipboard?.writeText(viewUrl(view, project));
      else if (a === "delete") void remove(view);
    },
  });
  return (
    <>
      <RenameViewDialog view={renaming ? view : undefined} onClose={() => setRenaming(false)} />
      <SaveViewDialog query={now} open={saving} onOpenChange={setSaving} />
      {update.isError && <span role="alert" className="px-6 py-1 text-12 text-pill-blocked-fg">{errorText(update.error)}</span>}
    </>
  );
}
