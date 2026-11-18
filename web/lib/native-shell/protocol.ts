// The protocol between the web UI and the native macOS shell (macos/), version 1.
//
// The page sends messages with window.webkit.messageHandlers.vesper.postMessage(msg); the shell
// sends commands by dispatching a "vesper-native" CustomEvent on window whose detail is a
// NativeCommand. Every message carries v: 1. The Swift mirror is
// macos/Sources/VesperCore/Bridge/Protocol.swift; both sides decode the fixtures in
// protocol/native-bridge/fixtures, so a field renamed on one side fails the other's tests.
//
// Kept free of React and DOM imports so `node --test` covers it directly.

export const PROTOCOL_VERSION = 1;

/** Names of the web's Icon set (components/ui/icon.tsx). The shell maps them to SF Symbols. */
export type IconRef = string;

export type Tone = "neutral" | "accent" | "done" | "human" | "blocked" | "warning" | "danger";

export interface MenuItem {
  id: string;
  label?: string;
  icon?: IconRef;
  /** A separator line; other fields are ignored. */
  separator?: boolean;
  destructive?: boolean;
  disabled?: boolean;
  checked?: boolean;
  /** Shown right-aligned, e.g. "⌘N". Display only. */
  shortcut?: string;
  children?: MenuItem[];
}

export interface Avatar {
  initials: string;
  /** CSS color, e.g. "#9B8CFF". */
  color?: string;
  imageUrl?: string;
}

export interface NavItem {
  id: string;
  title: string;
  subtitle?: string;
  icon?: IconRef;
  avatar?: Avatar;
  /** Right-aligned count or short label. */
  badge?: { text: string; tone?: Tone };
  /** A small status dot before the title. */
  status?: Tone;
  /** Short muted text on the right, e.g. "4m". */
  trailing?: string;
  /** In-app path this row opens; the shell sends nav.activate either way. */
  href?: string;
  children?: NavItem[];
  expanded?: boolean;
  disabled?: boolean;
  contextMenu?: MenuItem[];
}

export interface NavSection {
  id: string;
  title?: string;
  items: NavItem[];
  /** Buttons on the section header (e.g. a + for "New chat"). */
  actions?: NavAction[];
  collapsible?: boolean;
  collapsed?: boolean;
  /** Shown when items is empty. */
  emptyText?: string;
}

export interface NavAction {
  id: string;
  label: string;
  icon: IconRef;
  accent?: boolean;
  /** When set, the button opens this menu instead of sending nav.action directly. */
  menu?: MenuItem[];
}

export interface NavPicker {
  id: string;
  value: string;
  options: { value: string; label: string; icon?: IconRef }[];
}

export interface NavSearch {
  id: string;
  placeholder: string;
  value: string;
}

/** A screen's list in the native sidebar (what NavigatorPortal draws in the browser). */
export interface NavModel {
  /** Stable id of the screen's navigator, e.g. "chats", "runs", "knowledge". */
  id: string;
  title?: string;
  actions?: NavAction[];
  picker?: NavPicker;
  search?: NavSearch;
  sections: NavSection[];
  selectedId?: string | null;
}

export type AreaId = "chat" | "work" | "knowledge" | "library" | "apps";

export interface ShellArea {
  id: AreaId;
  label: string;
  icon: IconRef;
  href: string;
  /** Dot or count for the area (e.g. runs working). */
  badge?: { text?: string; tone?: Tone };
}

export interface ShellApp {
  id: string;
  label: string;
  icon: IconRef;
  href: string;
}

/** The fixed top of the native sidebar: the areas and the Apps entries. */
export interface ShellModel {
  areas: ShellArea[];
  apps: ShellApp[];
  currentArea: AreaId | null;
}

export interface ToolbarItem {
  id: string;
  label: string;
  icon?: IconRef;
  /** "button" sends toolbar.action; "menu" opens items; "toggle" shows on/off state. */
  kind: "button" | "menu" | "toggle";
  menu?: MenuItem[];
  on?: boolean;
  disabled?: boolean;
  accent?: boolean;
}

export type ApprovalScope = "run_approvals" | "push_requests" | "connector_approvals" | "secret_approvals";

/** Page → shell. */
export type PageMessage =
  | { v: 1; type: "ready"; path: string }
  | { v: 1; type: "route"; path: string; area: AreaId | null }
  | { v: 1; type: "title"; title: string; subtitle?: string }
  | { v: 1; type: "shell"; model: ShellModel }
  | { v: 1; type: "navigator"; model: NavModel | null }
  /** True while the page shows a screen's list in its own fallback column (not yet described). */
  | { v: 1; type: "navigatorFallback"; active: boolean }
  | { v: 1; type: "toolbar"; items: ToolbarItem[] }
  | { v: 1; type: "confirmApproval"; requestId: string; scope: ApprovalScope }
  | { v: 1; type: "openWorkspaceMenu"; requestId: string; folder: string }
  | { v: 1; type: "contextMenu"; requestId: string; items: MenuItem[]; x: number; y: number };

/** Shell → page. */
export type NativeCommand =
  | { v: 1; type: "navigate"; path: string }
  | { v: 1; type: "nav.activate"; navigatorId: string; itemId: string }
  | { v: 1; type: "nav.action"; navigatorId: string; actionId: string; itemId?: string; menuItemId?: string }
  | { v: 1; type: "nav.picker"; navigatorId: string; pickerId: string; value: string }
  | { v: 1; type: "nav.search"; navigatorId: string; searchId: string; value: string }
  | { v: 1; type: "nav.toggle"; navigatorId: string; itemId: string; expanded: boolean }
  | { v: 1; type: "toolbar.action"; itemId: string; menuItemId?: string }
  /** query only applies to openCommandMenu: the text to open the palette with (the toolbar search field). */
  | { v: 1; type: "command"; name: ShellCommandName; query?: string }
  | { v: 1; type: "reply"; requestId: string; ok: boolean; selectedId?: string | null; error?: string };

export type ShellCommandName =
  | "openCommandMenu"
  | "newChat"
  | "toggleCompanion"
  | "showShortcuts"
  | "find"
  | "focusContent";

export const SHELL_COMMANDS: readonly ShellCommandName[] = [
  "openCommandMenu",
  "newChat",
  "toggleCompanion",
  "showShortcuts",
  "find",
  "focusContent",
];

const PAGE_TYPES = new Set([
  "ready",
  "route",
  "title",
  "shell",
  "navigator",
  "navigatorFallback",
  "toolbar",
  "confirmApproval",
  "openWorkspaceMenu",
  "contextMenu",
]);
const COMMAND_TYPES = new Set(["navigate", "nav.activate", "nav.action", "nav.picker", "nav.search", "nav.toggle", "toolbar.action", "command", "reply"]);

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);

/** A shallow check that a value is a v1 page message of a known type. */
export function isPageMessage(v: unknown): v is PageMessage {
  return isObj(v) && v.v === PROTOCOL_VERSION && typeof v.type === "string" && PAGE_TYPES.has(v.type);
}

/** A shallow check that a value is a v1 native command of a known type. */
export function isNativeCommand(v: unknown): v is NativeCommand {
  if (!isObj(v) || v.v !== PROTOCOL_VERSION || typeof v.type !== "string" || !COMMAND_TYPES.has(v.type)) return false;
  if (v.type === "navigate") return typeof v.path === "string" && v.path.startsWith("/") && !v.path.startsWith("//");
  if (v.type === "command") return SHELL_COMMANDS.includes(v.name as ShellCommandName) && (v.query === undefined || typeof v.query === "string");
  return true;
}
