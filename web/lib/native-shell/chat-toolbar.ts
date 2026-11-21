// The chat page's header as native toolbar items and a title menu: who you're talking to, the
// space, the repository and the title's own menu. The playground is on the right rail
// (chat-panel-host's usePlaygroundStart). Pure: the screen feeds in what
// the web header reads and acts on the decoded action. Ids are the protocol between this file's
// builders and parsers; nothing else depends on their text.

import { avatar } from "./chats-model.ts";
import type { MenuItem, ToolbarItem } from "./protocol.ts";

const SEP: MenuItem = { id: "sep", separator: true };

export const ASSISTANT_MARK = "/assistant-mark.svg";

export interface ChatToolbarInput {
  /** Where relative picture urls are served from. */
  origin?: string;
  archived: boolean;
  /** Everyone in the chat, host first; more than one is a group chat. */
  participants: { id?: string; name: string; color: string; avatar_url?: string }[];
  /** The personas offered for this chat (inChatList), and whether picking one switches this conversation. */
  personas: { id: string; name: string }[];
  currentPersonaId?: string;
  fresh: boolean;
  personaDisabled: boolean;
  space: { current?: { id: string; name: string }; spaces: { id: string; name: string }[]; locked: boolean };
  /** Present for a persona that can code. */
  repo?: { value?: string; pending?: string; choices: { url: string; name: string }[]; shortName: (url: string) => string; same: (a: string, b: string) => boolean; disabled: boolean };
  canvasCount: number;
  runsActive: number;
}

export type ChatAction =
  | { type: "persona"; id: string }
  | { type: "managePersonas" }
  | { type: "space"; id: string }
  | { type: "repo"; url: string }
  | { type: "searchRepos" }
  | { type: "canvas" }
  | { type: "runs" }
  | { type: "restore" };

const PERSONA = "chat.persona";
const SPACE = "chat.space";
const REPO = "chat.repo";

export function buildChatToolbar(i: ChatToolbarInput): ToolbarItem[] {
  const items: ToolbarItem[] = [];
  const host = i.participants[0] ?? { name: "Assistant", color: "" };
  const group = i.participants.length > 1;
  const look = (p: { name: string; color: string; avatar_url?: string }) =>
    avatar(p.name, p.color, p.avatar_url ?? (p.name === "Assistant" ? ASSISTANT_MARK : undefined), i.origin);

  if (group) {
    items.push({
      id: PERSONA, label: i.participants.map((p) => p.name).join(", "), kind: "menu", showsLabel: true, placement: "leading",
      avatar: look(host),
      menu: [{ id: "participants", label: "In this chat", disabled: true }, ...i.participants.map((p, n) => ({ id: `participant:${n}`, label: p.name, disabled: true }))],
    });
  } else if (!i.personas.length) {
    items.push({ id: PERSONA, label: `Persona: ${host.name}`, kind: "button", showsLabel: true, placement: "leading", avatar: look(host), disabled: true });
  } else {
    items.push({
      id: PERSONA, label: host.name, kind: "menu", showsLabel: true, placement: "leading", avatar: look(host), disabled: i.personaDisabled,
      menu: [
        { id: "persona.header", label: i.fresh ? "Persona for this conversation" : "New chat with", disabled: true },
        ...i.personas.map((p) => ({ id: `persona:${p.id}`, label: p.name, checked: p.id === i.currentPersonaId })),
        SEP,
        { id: "persona.manage", label: "Manage personas…" },
      ],
    });
  }

  const sp = i.space;
  items.push({
    id: SPACE, label: sp.current ? sp.current.name : "Space", kind: "menu", showsLabel: true, placement: "leading",
    icon: sp.current ? "briefcase" : "plus", disabled: sp.locked,
    menu: [
      ...sp.spaces.map((s) => ({ id: `space:${s.id}`, label: s.name, checked: s.id === sp.current?.id })),
      ...(sp.spaces.length ? [SEP] : []),
      { id: "space:", label: "No space", checked: !sp.current },
    ],
  });

  const r = i.repo;
  if (r) {
    const queued = r.pending ? ` → ${r.shortName(r.pending)} (next turn)` : "";
    items.push({
      id: REPO, label: `${r.value ? r.shortName(r.value) : "Repository"}${queued}`, kind: "menu", showsLabel: true, placement: "leading",
      icon: "branch", disabled: r.disabled,
      menu: [
        ...r.choices.map((c) => ({ id: `repo:${c.url}`, label: c.name, checked: !!r.value && r.same(r.value, c.url) })),
        ...(r.choices.length ? [SEP] : []),
        { id: "repo.search", label: "Search repos…", icon: "search" },
      ],
    });
  }

  if (i.runsActive > 0) {
    items.push({ id: "chat.runs", label: `${i.runsActive} ${i.runsActive === 1 ? "run" : "runs"} active`, kind: "button", icon: "activity", showsLabel: true, accent: true });
  }
  if (i.canvasCount > 0) items.push({ id: "chat.canvas", label: `Canvas ${i.canvasCount}`, kind: "button", icon: "compare", showsLabel: true });
  if (i.archived) items.push({ id: "chat.restore", label: "Restore", kind: "button", icon: "refresh", showsLabel: true });
  return items;
}

/** What a toolbar press or menu choice from buildChatToolbar means; null for anything else. */
export function parseChatAction(itemId: string, menuItemId?: string): ChatAction | null {
  switch (itemId) {
    case PERSONA:
      if (menuItemId === "persona.manage") return { type: "managePersonas" };
      return menuItemId?.startsWith("persona:") ? { type: "persona", id: menuItemId.slice("persona:".length) } : null;
    case SPACE:
      return menuItemId?.startsWith("space:") ? { type: "space", id: menuItemId.slice("space:".length) } : null;
    case REPO:
      if (menuItemId === "repo.search") return { type: "searchRepos" };
      return menuItemId?.startsWith("repo:") ? { type: "repo", url: menuItemId.slice("repo:".length) } : null;
    case "chat.canvas":
      return { type: "canvas" };
    case "chat.runs":
      return { type: "runs" };
    case "chat.restore":
      return { type: "restore" };
    default:
      return null;
  }
}

export interface ChatTitleMenuInput {
  archived: boolean;
  workspacePath?: string;
  /** The shell can open the folder in an app (the desktop bridge). */
  canOpenWorkspace: boolean;
  /** Secrets this chat used, with the web menu's one-line summary. */
  secrets?: { label: string };
  commitEmail?: string;
  /** Context compaction controls; omitted in compact legacy callers. */
  compact?: { disabled: boolean; pending?: boolean; contextTokens?: number };
  /** Per-chat auto-compaction threshold controls. */
  autoCompact?: { value: number | null; disabled: boolean };
  /** Everyone in a group chat; fewer than two adds nothing. */
  participants: string[];
}

export const AUTO_COMPACT_PRESETS: { value: number | null; id: string; label: string }[] = [
  { value: null, id: "auto-compact:default", label: "Default" },
  { value: 0, id: "auto-compact:0", label: "Off" },
  { value: 100000, id: "auto-compact:100000", label: "100k tokens" },
  { value: 150000, id: "auto-compact:150000", label: "150k tokens" },
  { value: 200000, id: "auto-compact:200000", label: "200k tokens" },
];

export function formatAutoCompactLabel(tokens?: number | null): string {
  if (tokens === undefined || tokens === null) return "Default";
  if (tokens === 0) return "Off";
  return `${Math.round(tokens / 1000)}k`;
}

export function formatContextTokens(tokens?: number): string {
  if (!tokens || tokens <= 0) return "";
  if (tokens < 1000) return `${tokens} ctx`;
  return `${Math.round(tokens / 1000)}k ctx`;
}

export type TitleAction =
  | "rename"
  | "compact"
  | { type: "autoCompact"; tokens: number | null }
  | "copyWorkspace"
  | "openWorkspace"
  | "secrets"
  | "commitEmail";

const TITLE_IDS: Record<string, Exclude<TitleAction, { type: "autoCompact" }>> = {
  rename: "rename",
  compact: "compact",
  "workspace.copy": "copyWorkspace",
  "workspace.open": "openWorkspace",
  secrets: "secrets",
  "commit-email": "commitEmail",
};

/** The chat title's menu: what the web's title dropdown offers, minus the space (it has its own item). */
export function buildChatTitleMenu(i: ChatTitleMenuInput): MenuItem[] {
  const menu: MenuItem[] = [{ id: "rename", label: "Rename…", icon: "edit", disabled: i.archived }];
  if (i.compact || i.autoCompact) {
    menu.push(SEP);
    if (i.compact) {
      const ctx = formatContextTokens(i.compact.contextTokens);
      const label = i.compact.pending ? "Compact context (pending)" : ctx ? `Compact context (${ctx})` : "Compact context";
      menu.push({ id: "compact", label, icon: "shrink", disabled: i.compact.disabled });
    }
    if (i.autoCompact) {
      const cur = i.autoCompact.value;
      menu.push({
        id: "auto-compact",
        label: `Auto-compact: ${formatAutoCompactLabel(cur)}`,
        icon: "sliders",
        disabled: i.autoCompact.disabled,
        children: AUTO_COMPACT_PRESETS.map((p) => ({
          id: p.id,
          label: p.label,
          checked: (cur ?? null) === p.value,
        })),
      });
    }
  }
  const rest: MenuItem[] = [];
  if (i.workspacePath) {
    rest.push({ id: "workspace.copy", label: "Copy workspace folder path", icon: "folder" });
    if (i.canOpenWorkspace) rest.push({ id: "workspace.open", label: "Open workspace folder in…", icon: "expand" });
  }
  if (i.secrets) rest.push({ id: "secrets", label: `Secrets: ${i.secrets.label}…`, icon: "key" });
  if (i.commitEmail) rest.push({ id: "commit-email", label: `Commit email: ${i.commitEmail}`, icon: "at" });
  if (rest.length) menu.push(SEP, ...rest);
  if (i.participants.length > 1) {
    menu.push(SEP, { id: "participants", label: "Participants", disabled: true }, ...i.participants.map((n, k) => ({ id: `participant:${k}`, label: n, disabled: true })));
  }
  return menu;
}

export function parseTitleAction(menuItemId: string): TitleAction | null {
  if (menuItemId.startsWith("auto-compact:")) {
    const raw = menuItemId.slice("auto-compact:".length);
    if (raw === "default") return { type: "autoCompact", tokens: null };
    const n = Number(raw);
    return Number.isInteger(n) && n >= 0 ? { type: "autoCompact", tokens: n } : null;
  }
  return TITLE_IDS[menuItemId] ?? null;
}
