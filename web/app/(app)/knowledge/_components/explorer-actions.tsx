"use client";

import { ContextMenu } from "radix-ui";
import { useMemo, useRef, useState, type ReactNode } from "react";
import { cx } from "@/lib/cx";
import { moveTargets, nameError, type TreeFolder, type TreeRow } from "@/lib/knowledge";
import { floatPanel } from "@/components/domain/pickers";
import { Button } from "@/components/ui/button";
import { Icon, type IconName } from "@/components/ui/icon";
import { Modal } from "./kit";

// The explorer's right-click menu and what it opens: inline rename, Move to…,
// New folder and the delete confirmation. Folders are path prefixes, so a
// folder action acts on every page under it.

export type ExplorerTarget =
  { kind: "page"; page: TreeRow } | { kind: "folder"; folder: TreeFolder };

export type MenuEntry =
  | { icon: IconName; label: string; onSelect: () => void; danger?: boolean }
  | "separator";

const itemCls =
  "flex h-8 cursor-default select-none items-center gap-2.5 rounded-md px-2 outline-none data-[highlighted]:bg-hover data-[disabled]:opacity-50";

/** Right-click on children opens this menu instead of the browser's. */
export function ExplorerMenu({
  entries,
  children,
  className,
}: {
  entries: MenuEntry[];
  children: ReactNode;
  className?: string;
}) {
  return (
    <ContextMenu.Root>
      <ContextMenu.Trigger asChild>
        <div className={className}>{children}</div>
      </ContextMenu.Trigger>
      <ContextMenu.Portal>
        {/* Focus stays where the chosen action puts it (the rename field, a dialog), not back on the row. */}
        <ContextMenu.Content
          collisionPadding={8}
          onCloseAutoFocus={(e) => e.preventDefault()}
          className={cx(floatPanel, "min-w-[200px]")}
        >
          {entries.map((e, i) =>
            e === "separator" ? (
              <ContextMenu.Separator
                key={`sep-${i}`}
                className="mx-1 my-1 h-px bg-border-subtle"
              />
            ) : (
              <ContextMenu.Item
                key={e.label}
                onSelect={e.onSelect}
                className={cx(itemCls, e.danger && "text-pill-blocked-fg")}
              >
                <Icon
                  name={e.icon}
                  size={14}
                  className={e.danger ? undefined : "text-fg-secondary"}
                />
                {e.label}
              </ContextMenu.Item>
            ),
          )}
        </ContextMenu.Content>
      </ContextMenu.Portal>
    </ContextMenu.Root>
  );
}

/**
 * A tree row turned into a text field, as Obsidian renames in place: Enter or
 * leaving the field saves, Escape cancels. A refused name keeps it open with
 * the reason.
 */
export function RenameField({
  initial,
  icon,
  indent,
  error,
  pending,
  onCommit,
  onCancel,
}: {
  initial: string;
  icon: IconName;
  indent: number;
  error?: string;
  pending: boolean;
  onCommit: (name: string) => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState(initial);
  const [local, setLocal] = useState<string>();
  // Enter then blur (as the field unmounts) would otherwise save twice.
  const done = useRef(false);
  const finish = (save: boolean) => {
    if (done.current || pending) return;
    const next = name.trim();
    if (!save || next === initial) {
      done.current = true;
      onCancel();
      return;
    }
    const bad = nameError(next);
    if (bad) {
      setLocal(bad);
      return;
    }
    onCommit(next);
  };
  const shown = local ?? error;
  return (
    <div style={{ paddingLeft: indent }} className="pr-1">
      <div className="flex h-[26px] items-center gap-1.5">
        <Icon name={icon} size={13} className="flex-none text-fg-tertiary" />
        <input
          autoFocus
          aria-label={`Rename ${initial}`}
          aria-invalid={!!shown}
          value={name}
          disabled={pending}
          onFocus={(e) => e.currentTarget.select()}
          onChange={(e) => {
            setName(e.target.value);
            setLocal(undefined);
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter") {
              e.preventDefault();
              finish(true);
            } else if (e.key === "Escape") {
              e.preventDefault();
              finish(false);
            }
          }}
          onBlur={() => finish(true)}
          className={cx(
            "h-[24px] min-w-0 flex-1 rounded border bg-surface px-1.5 text-13 text-fg outline-none",
            shown ? "border-state-blocked" : "border-accent",
          )}
        />
      </div>
      {shown && (
        <p className="py-1 pl-5 text-11 leading-snug text-pill-blocked-fg">
          {shown}
        </p>
      )}
    </div>
  );
}

/** Rename as a dialog, for the native sidebar where rows can't turn into a text field. */
export function RenameDialog({
  initial,
  error,
  pending,
  onCommit,
  onCancel,
}: {
  initial: string;
  error?: string;
  pending: boolean;
  onCommit: (name: string) => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState(initial);
  const bad = name.trim() !== initial && name ? nameError(name.trim()) : undefined;
  const save = () => {
    const next = name.trim();
    if (next === initial) return onCancel();
    if (!nameError(next)) onCommit(next);
  };
  return (
    <Modal open onOpenChange={(o) => !o && onCancel()} title={`Rename “${initial}”`} className="top-[24vh] w-[min(440px,calc(100vw-32px))]">
      <div className="px-5 pt-3">
        <input
          autoFocus
          aria-label={`Rename ${initial}`}
          value={name}
          disabled={pending}
          onFocus={(e) => e.currentTarget.select()}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && save()}
          className="h-8 w-full rounded-md border border-border-subtle bg-surface-sunken px-2.5 text-13 text-fg outline-none focus:border-accent"
        />
      </div>
      <div className="pt-2">
        <ErrorLine message={bad ?? error} />
      </div>
      <div className="flex justify-end gap-2 px-5 pb-4 pt-2">
        <Button variant="ghost" onClick={onCancel}>
          Cancel
        </Button>
        <Button variant="primary" disabled={pending || !name.trim() || !!nameError(name.trim())} onClick={save}>
          {pending ? "Renaming…" : "Rename"}
        </Button>
      </div>
    </Modal>
  );
}

function ErrorLine({ message }: { message?: string }) {
  return message ? (
    <p className="px-5 pb-1 text-12 text-pill-blocked-fg">{message}</p>
  ) : null;
}

/** Move to…: pick a folder, filtered as you type; a folder can't go inside itself. */
export function MoveDialog({
  target,
  folders,
  pending,
  error,
  onMove,
  onClose,
}: {
  target: ExplorerTarget;
  folders: string[];
  pending: boolean;
  error?: string;
  onMove: (folder: string) => void;
  onClose: () => void;
}) {
  const [filter, setFilter] = useState("");
  const path = target.kind === "page" ? target.page.path : target.folder.path;
  const label = target.kind === "page" ? target.page.title : target.folder.name;
  const options = useMemo(() => moveTargets(folders, path, target.kind === "folder", filter), [folders, path, target.kind, filter]);
  return (
    <Modal open onOpenChange={(o) => !o && onClose()} title={`Move “${label}”`}>
      <div className="px-5 pt-3">
        <input
          autoFocus
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter" && options.length > 0) onMove(options[0]);
          }}
          placeholder="Find a folder…"
          aria-label="Find a folder"
          className="h-8 w-full rounded-md border border-border-subtle bg-surface-sunken px-2.5 text-13 text-fg outline-none placeholder:text-fg-tertiary focus:border-accent"
        />
      </div>
      <ul
        role="listbox"
        aria-label="Folders"
        className="mx-3 my-2 max-h-[320px] overflow-y-auto"
      >
        {options.map((f) => (
          <li key={f || "/"}>
            <button
              type="button"
              disabled={pending}
              onClick={() => onMove(f)}
              className="flex h-8 w-full items-center gap-2 rounded-md px-2 text-left text-13 text-fg-2 hover:bg-hover disabled:opacity-50"
            >
              <Icon
                name="folder"
                size={14}
                className="flex-none text-fg-secondary"
              />
              <span className="truncate">{f || "Knowledge (top level)"}</span>
            </button>
          </li>
        ))}
        {options.length === 0 && (
          <li className="px-2 py-2 text-12 text-fg-tertiary">
            No folder matches.
          </li>
        )}
      </ul>
      <ErrorLine message={error} />
      <div className="flex justify-end gap-2 border-t border-border-subtle px-5 py-3">
        <Button variant="ghost" onClick={onClose}>
          Cancel
        </Button>
      </div>
    </Modal>
  );
}

/** A folder only exists while it holds a page, so a new one starts with an empty page. */
export function NewFolderDialog({
  parent,
  pending,
  error,
  onCreate,
  onClose,
}: {
  parent: string;
  pending: boolean;
  error?: string;
  onCreate: (name: string) => void;
  onClose: () => void;
}) {
  const [name, setName] = useState("");
  const bad = name ? nameError(name) : undefined;
  const create = () => {
    if (!nameError(name)) onCreate(name.trim());
  };
  return (
    <Modal
      open
      onOpenChange={(o) => !o && onClose()}
      title="New folder"
      className="top-[24vh] w-[min(440px,calc(100vw-32px))]"
    >
      <div className="px-5 pt-1 text-12 text-fg-tertiary">
        {parent ? `In ${parent}. ` : ""}It starts with an empty page, since a
        folder holds pages.
      </div>
      <div className="px-5 pt-3">
        <input
          autoFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && create()}
          placeholder="Folder name"
          aria-label="Folder name"
          className="h-8 w-full rounded-md border border-border-subtle bg-surface-sunken px-2.5 text-13 text-fg outline-none placeholder:text-fg-tertiary focus:border-accent"
        />
      </div>
      <div className="pt-2">
        <ErrorLine message={bad ?? error} />
      </div>
      <div className="flex justify-end gap-2 px-5 pb-4 pt-2">
        <Button variant="ghost" onClick={onClose}>
          Cancel
        </Button>
        <Button
          variant="primary"
          disabled={!!nameError(name) || pending}
          onClick={create}
        >
          {pending ? "Creating…" : "Create folder"}
        </Button>
      </div>
    </Modal>
  );
}

/** Deleting can't be undone, so it always asks, and says how much goes. */
export function DeleteDialog({
  target,
  pending,
  error,
  onDelete,
  onClose,
}: {
  target: ExplorerTarget;
  pending: boolean;
  error?: string;
  onDelete: () => void;
  onClose: () => void;
}) {
  const folder = target.kind === "folder";
  const name = folder ? target.folder.name : target.page.title;
  const count = folder ? target.folder.count : 1;
  return (
    <Modal
      open
      onOpenChange={(o) => !o && onClose()}
      title={folder ? `Delete the folder “${name}”?` : `Delete “${name}”?`}
      className="top-[24vh] w-[min(440px,calc(100vw-32px))]"
    >
      <p className="px-5 pt-2 text-13 leading-relaxed text-fg-secondary">
        {folder
          ? `This deletes the ${count === 1 ? "page" : `${count} pages`} in it, with their history.`
          : "This deletes the page and its history."}{" "}
        It can’t be undone. Links to {folder && count !== 1 ? "them" : "it"}{" "}
        stay in your notes as unresolved links.
      </p>
      <div className="pt-2">
        <ErrorLine message={error} />
      </div>
      <div className="flex justify-end gap-2 px-5 pb-4 pt-3">
        <Button variant="ghost" onClick={onClose} autoFocus>
          Cancel
        </Button>
        <Button
          variant="primary"
          className="bg-state-blocked text-[#fff]"
          disabled={pending}
          onClick={onDelete}
        >
          {pending
            ? "Deleting…"
            : folder
              ? `Delete ${count === 1 ? "folder" : `${count} pages`}`
              : "Delete page"}
        </Button>
      </div>
    </Modal>
  );
}
