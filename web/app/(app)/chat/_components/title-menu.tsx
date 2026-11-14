"use client";

import { DropdownMenu, Tooltip } from "radix-ui";
import { useRef, useState, type FormEvent, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { useUpdateChat } from "@/lib/api/hooks";
import { chatTitle } from "@/lib/chat-ui";
import { cx } from "@/lib/cx";
import { floatPanel } from "@/components/domain/pickers";
import { Icon, type IconName } from "@/components/ui/icon";
import { TextInput } from "@/components/ui/primitives";
import { SpaceRadioItems, useChatSpace } from "./chat-space";
import { PersonaAvatar, PersonaName, type PersonaLook } from "./persona";
import { SecretsList, useChatSecrets } from "./secrets";

type Chat = Schemas["ChatSession"];

const item = "flex h-8 cursor-default select-none items-center gap-2.5 rounded-md px-2 text-13 outline-none data-[highlighted]:bg-hover data-[state=open]:bg-hover data-[disabled]:opacity-50";
const value = "max-w-[55%] truncate text-12 text-fg-tertiary";
const sep = "my-1 h-px bg-border-strong";
const iconButton = "grid size-7 flex-none place-items-center rounded-md text-fg-secondary hover:bg-hover hover:text-fg";

/**
 * The desktop chat header's title: ▾ opens the chat's settings (rename, default project, workspace
 * folder, secrets, commit email, who's in a group chat), and small icons beside it say what's not
 * the default (archived, temporary, a folder, a chosen address, secrets in use) without opening it.
 */
export function ChatTitleMenu({ chat: c, participants, running, commitEmail, onCommitEmail, compact = false }: {
  chat: Chat;
  /** Everyone in a group chat; one persona hides the Participants section. */
  participants: PersonaLook[];
  running: boolean;
  /** The chosen commit address, when the repository has more than one to pick from. */
  commitEmail?: string;
  /** Opens (or closes) the commit-email picker above the composer. */
  onCommitEmail: () => void;
  /** Tighter spacing and 13px heading so the title stays readable in a 360px dock. */
  compact?: boolean;
}) {
  const update = useUpdateChat();
  const space = useChatSpace(c, running);
  const secrets = useChatSecrets(c.id);
  const [editing, setEditing] = useState(false);
  const [title, setTitle] = useState(c.title);
  // Rename focuses the title box once the menu has closed, rather than the menu handing focus back to ▾.
  const afterClose = useRef<(() => void) | null>(null);
  const label = chatTitle(c);
  const group = participants.length > 1;

  function save(e: FormEvent) {
    e.preventDefault();
    const t = title.trim();
    if (!t || t === c.title) return setEditing(false);
    update.mutateAsync({ id: c.id, patch: { revision: c.revision, title: t } }).then(() => setEditing(false), () => undefined);
  }

  if (editing) {
    return (
      <form onSubmit={save} className="flex min-w-0 flex-1 items-center gap-1">
        <TextInput aria-label="Conversation title" className="!h-8 min-w-0 max-w-[420px] flex-1" value={title} placeholder="New conversation" autoFocus onChange={(e) => setTitle(e.target.value)} onKeyDown={(e) => e.key === "Escape" && setEditing(false)} />
        <button type="submit" aria-label="Save title" className={iconButton} disabled={update.isPending}>
          <Icon name="check" size={16} />
        </button>
        <button type="button" aria-label="Cancel rename" className={iconButton} onClick={() => setEditing(false)}>
          <Icon name="x" size={16} />
        </button>
        {update.isError && <span role="alert" className="truncate text-12 text-pill-blocked-fg">Couldn’t rename. Try again.</span>}
      </form>
    );
  }

  return (
    <div className="flex min-w-0 max-w-full items-center gap-1.5">
      <DropdownMenu.Root>
        {/* The heading holds the button (not the other way round) so it stays a heading named by the title. */}
        <h1 className={cx("min-w-0 font-semibold", compact ? "text-13" : "text-14")}>
          <DropdownMenu.Trigger asChild>
            <button
              type="button"
              data-testid="chat-title-menu"
              title="Chat settings"
              className={cx("flex min-w-0 max-w-full items-center rounded-md hover:bg-hover data-[state=open]:bg-hover", compact ? "gap-0.5 px-1 py-0.5" : "gap-1 px-1.5 py-1")}
            >
              <span className="min-w-0 truncate">{label}</span>
              <Icon name="chev" size={12} className="flex-none text-fg-tertiary" />
            </button>
          </DropdownMenu.Trigger>
        </h1>
        <DropdownMenu.Portal>
          <DropdownMenu.Content
            align="start"
            sideOffset={4}
            className={cx(floatPanel, "w-[300px]")}
            onCloseAutoFocus={(e) => {
              const run = afterClose.current;
              afterClose.current = null;
              if (!run) return;
              e.preventDefault();
              run();
            }}
          >
            <DropdownMenu.Item
              className={item}
              disabled={c.archived}
              onSelect={() => {
                afterClose.current = () => {
                  setTitle(c.title);
                  setEditing(true);
                };
              }}
            >
              <Icon name="edit" size={14} />
              <span className="flex-1">Rename…</span>
            </DropdownMenu.Item>
            <DropdownMenu.Separator className={sep} />
            {/* Which space the chat is in (LAZYAGENTS-213): its context, and where its tickets go. */}
            <DropdownMenu.Sub>
              <DropdownMenu.SubTrigger className={item} disabled={space.locked} data-testid="chat-space-menu" aria-label={space.current ? `In ${space.current.name}` : "Put this chat in a space"}>
                <Icon name="briefcase" size={14} />
                <span className="flex-1">Space</span>
                <span className={value}>{space.current?.name ?? "None"}</span>
                <Icon name="chevr" size={12} className="text-fg-tertiary" />
              </DropdownMenu.SubTrigger>
              <DropdownMenu.Portal>
                <DropdownMenu.SubContent sideOffset={6} className={cx(floatPanel, "w-[260px]")}>
                  <SpaceRadioItems chat={c} spaces={space.spaces} onPick={space.pick} />
                </DropdownMenu.SubContent>
              </DropdownMenu.Portal>
            </DropdownMenu.Sub>
            {c.workspace_path && (
              <DropdownMenu.Item
                className={item}
                data-testid="workspace-folder"
                title={`Checkout on this machine:\n${c.workspace_path}`}
                aria-label={`Copy folder path ${c.workspace_path}`}
                onSelect={() => void navigator.clipboard?.writeText(c.workspace_path ?? "")}
              >
                <Icon name="folder" size={14} />
                <span className="flex-none">Workspace folder</span>
                <span className="min-w-0 flex-1 truncate text-right font-mono text-12 text-fg-tertiary" dir="rtl">
                  {/* rtl keeps the run's own folder visible when the path truncates */}
                  <bdi>{c.workspace_path}</bdi>
                </span>
              </DropdownMenu.Item>
            )}
            {secrets.any && (
              <DropdownMenu.Sub>
                <DropdownMenu.SubTrigger className={item} data-testid="secrets-chip">
                  <Icon name="key" size={14} className={secrets.live ? "text-pill-human-fg" : undefined} />
                  <span className="flex-1">Secrets</span>
                  <span className={cx(value, secrets.live && "text-pill-human-fg")}>{secrets.label}</span>
                  <Icon name="chevr" size={12} className="text-fg-tertiary" />
                </DropdownMenu.SubTrigger>
                <DropdownMenu.Portal>
                  <DropdownMenu.SubContent sideOffset={6} className={cx(floatPanel, "w-[280px]")}>
                    <SecretsList chatId={c.id} secrets={secrets} />
                  </DropdownMenu.SubContent>
                </DropdownMenu.Portal>
              </DropdownMenu.Sub>
            )}
            {commitEmail && (
              <DropdownMenu.Item className={item} data-testid="commit-email-chip" title={`Commits are authored as ${commitEmail}. Click to change.`} onSelect={onCommitEmail}>
                <Icon name="at" size={14} />
                <span className="flex-none">Commit email</span>
                <span className={cx(value, "flex-1 text-right font-mono")}>{commitEmail}</span>
              </DropdownMenu.Item>
            )}
            {group && (
              <>
                <DropdownMenu.Separator className={sep} />
                <DropdownMenu.Label className="px-2 pb-1 pt-1.5 text-12 font-medium text-fg-tertiary">Participants</DropdownMenu.Label>
                <div data-testid="chat-participants" className="flex flex-col">
                  {participants.map((p) => (
                    <div key={p.id ?? p.name} className="flex h-8 items-center gap-2.5 px-2 text-13">
                      <PersonaAvatar persona={p} size={18} />
                      <PersonaName persona={p} />
                    </div>
                  ))}
                </div>
              </>
            )}
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
      <span className="flex flex-none items-center gap-1 text-fg-tertiary" data-testid="chat-title-status">
        {c.archived && <StatusIcon icon="lock" label="Archived: read-only until restored" />}
        {c.temporary && <StatusIcon icon="clock" label="Temporary chat: no memory, no past chats, and it's deleted after a day without messages" />}
        {c.workspace_path && <StatusIcon icon="folder" label={`Workspace folder: ${c.workspace_path}`} />}
        {commitEmail && <StatusIcon icon="at" label={`Commits are authored as ${commitEmail}`} />}
        {secrets.any && <StatusIcon icon="key" label={secrets.live ? `Secret ${secrets.label}` : `Secrets: ${secrets.label}`} className="text-pill-human-fg" />}
      </span>
    </div>
  );
}

/** A small icon beside the title for something non-default, its meaning in a tooltip (and to screen readers). */
function StatusIcon({ icon, label, className }: { icon: IconName; label: string; className?: string }): ReactNode {
  return (
    // The Tooltip.Provider is in Conversation.
    <Tooltip.Root>
      <Tooltip.Trigger asChild>
        <span role="img" aria-label={label} tabIndex={0} className={cx("grid size-5 place-items-center rounded-sm outline-none focus-visible:outline focus-visible:outline-accent", className)}>
          <Icon name={icon} size={13} />
        </span>
      </Tooltip.Trigger>
      <Tooltip.Portal>
        <Tooltip.Content side="bottom" sideOffset={6} className={cx(floatPanel, "max-w-[280px] px-2.5 py-1.5 text-12")}>
          {label}
        </Tooltip.Content>
      </Tooltip.Portal>
    </Tooltip.Root>
  );
}
