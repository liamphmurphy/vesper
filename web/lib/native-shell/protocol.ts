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

export interface NavBadge {
  text: string;
  tone?: Tone;
}

export interface NavItem {
  id: string;
  title: string;
  subtitle?: string;
  icon?: IconRef;
  avatar?: Avatar;
  /** Right-aligned count or short label. */
  badge?: NavBadge;
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
  /**
   * A collapsible section's header folds it. The shell sends nav.toggle with `itemId` = the section
   * id and the new `expanded` state; the page may then publish a model whose `collapsed` matches.
   */
  collapsible?: boolean;
  collapsed?: boolean;
  /** A count or short label beside the section title (a trailing capsule), instead of baking it into the title. */
  badge?: NavBadge;
  /** Shown when items is empty. */
  emptyText?: string;
}

export interface NavAction {
  id: string;
  label: string;
  icon: IconRef;
  accent?: boolean;
  /** Drawn greyed out and sends nothing. */
  disabled?: boolean;
  /** When set, the button opens this menu instead of sending nav.action directly. */
  menu?: MenuItem[];
  /** Show the label as text next to the icon (e.g. "New Chat" on the first day's header). */
  showsLabel?: boolean;
}

export interface NavPicker {
  id: string;
  value: string;
  options: { value: string; label: string; icon?: IconRef }[];
}

/**
 * A pull-down in the header row with check marks (a filter such as Space or View). Choosing an
 * option sends nav.filter. `multiple` options toggle independently (`checked` in the command is the
 * new state); otherwise choosing one selects it (`checked: true`) and the page unchecks the rest.
 */
export interface NavFilterMenu {
  id: string;
  label: string;
  icon?: IconRef;
  options: { value: string; label: string; checked: boolean }[];
  multiple?: boolean;
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
  /** Pull-down filters beside the picker, each with check marks. */
  filters?: NavFilterMenu[];
  search?: NavSearch;
  sections: NavSection[];
  selectedId?: string | null;
}

export type AreaId = "chat" | "spaces" | "knowledge" | "library" | "apps";

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
  /** Show the label as text next to the icon or avatar (e.g. "Start playground", a repo name). */
  showsLabel?: boolean;
  /** A picture or initials instead of the icon (e.g. the chat's persona). */
  avatar?: Avatar;
  /** "leading": right after the title (or the tabs); "trailing" (default): before the shell's own items. */
  placement?: "leading" | "trailing";
}

/** One button in the right rail. */
export interface RailItem {
  id: string;
  label: string;
  icon?: IconRef;
  avatar?: Avatar;
  /** A count or a dot. */
  badge?: { text?: string; tone?: Tone };
  /** A status dot on the icon (e.g. the agent harness's health). */
  status?: Tone;
  /** Selected (an open dock tab, the current page's link). */
  active?: boolean;
  /**
   * "needsYou": the shell shows its own Needs-you popover (the inbox it already monitors) instead
   * of sending rail.action. Everything else sends rail.action, or opens `menu` when it has one.
   */
  kind?: "button" | "needsYou";
  menu?: MenuItem[];
  disabled?: boolean;
  /** An agent harness's animated character (the shell draws it in the button; an unknown harness keeps the avatar). */
  character?: RailCharacter;
  /** Usage rows the shell draws above `menu` in the item's popover. */
  usage?: RailUsage[];
}

export interface RailCharacter {
  /** "claude-code", "codex" or "antigravity"; any other name has no character. */
  harness: string;
  working: boolean;
  /** The small label under the character (the web rail's: the harness's name, "AG" for Antigravity). */
  name?: string;
}

/** One usage reading in a rail popover (the web's harness bubble). */
export interface RailUsage {
  id: string;
  title: string;
  /** The big number, e.g. "42%". */
  value?: string;
  /** Bar fill, 0...1; absent with `unavailable` (the bar shows as striped). */
  fraction?: number;
  tone?: "normal" | "warn" | "limited";
  unavailable?: boolean;
  /** The line under the bar: left text, optional right text. */
  meta?: [string, string?];
  sub?: string;
  /** Small print at the foot (when it was last checked). */
  footnote?: string;
}

/** The right rail, top to bottom: the page's dock controls, then status, then links. */
export interface RailModel {
  top: RailItem[];
  middle: RailItem[];
  foot: RailItem[];
}

// MARK: Native inspector

export interface CompanionContext {
  path?: string;
}

export type InspectorTabKind = "native" | "companion" | "panel" | "web";

export type InspectorWidth = "regular" | "wide" | "max";

export interface InspectorPanelSpec {
  /** Panel renderer key inside /inspector-panel, e.g. "chat.playground", "chat.code". */
  kind: string;
  /** Stable mount key so /inspector-panel keeps instances alive across tab switches. */
  key: string;
  /** JSON-encoded props passed opaquely through the Swift shell. */
  propsJson: string;
}

export interface InspectorPanelContext {
  active: InspectorPanelSpec | null;
  /** Keys of all currently open panel tabs across the window's tabs (keep mounted while present). */
  keepKeys: string[];
  path?: string;
}

export interface InspectorOption {
  value: string;
  label: string;
  icon?: IconRef;
  tone?: Tone;
}

export interface InspectorAction {
  id: string;
  label: string;
  icon?: IconRef;
  accent?: boolean;
  destructive?: boolean;
  active?: boolean;
  disabled?: boolean;
  menu?: MenuItem[];
}

export interface InspectorChip {
  id: string;
  text: string;
  color?: string;
  tone?: Tone;
  icon?: IconRef;
  href?: string;
  removable?: boolean;
}

export type InspectorStepState = "done" | "current" | "pending" | "failed" | "needs_human";

export interface InspectorStep {
  id: string;
  text: string;
  state: InspectorStepState;
  interactive?: boolean;
}

export interface InspectorBarPoint {
  label: string;
  value: number;
  secondary?: number;
}

export type InspectorItemKind =
  | "fact"
  | "picker"
  | "segmented"
  | "toggle"
  | "text"
  | "checklist"
  | "progress"
  | "chips"
  | "list"
  | "actions"
  | "note"
  | "chart";

export interface InspectorItem {
  id: string;
  kind: InspectorItemKind;
  label?: string;
  value?: string;
  detail?: string;
  placeholder?: string;
  icon?: IconRef;
  tone?: Tone;
  mono?: boolean;
  multiline?: boolean;
  inputType?: string;
  checked?: boolean;
  disabled?: boolean;
  fraction?: number;
  href?: string;
  url?: string;
  actionId?: string;
  badge?: NavBadge;
  options?: InspectorOption[];
  steps?: InspectorStep[];
  chips?: InspectorChip[];
  rows?: NavItem[];
  actions?: InspectorAction[];
  menu?: MenuItem[];
  points?: InspectorBarPoint[];
}

export interface InspectorSection {
  id: string;
  title?: string;
  aside?: string;
  collapsible?: boolean;
  collapsed?: boolean;
  badge?: NavBadge;
  emptyText?: string;
  items: InspectorItem[];
}

export interface InspectorTab {
  id: string;
  label: string;
  icon: IconRef;
  kind: InspectorTabKind;
  width?: InspectorWidth;
  busy?: boolean;
  unread?: boolean;
  badge?: NavBadge;
  headerActions?: InspectorAction[];
  sections?: InspectorSection[];
  emptyText?: string;
  panel?: InspectorPanelSpec;
}

export interface InspectorModel {
  id: string;
  open: boolean;
  activeTabId: string;
  tabs: InspectorTab[];
  companion?: CompanionContext;
}

export type ApprovalScope = "run_approvals" | "push_requests" | "connector_approvals" | "secret_approvals";

export type ColorMode = "dark" | "light";

export type ToastTone = "neutral" | "success" | "error";
export type ToastEventKind = "action" | "dismissed" | "timeout";

export type CommandPaletteScope = "all" | "page" | "knowledge" | "type";

export interface CommandPaletteRequest {
  path?: string;
  search?: string;
  scope?: CommandPaletteScope;
  scopeType?: string;
  scopeLabel?: string;
  includeAgent?: boolean;
  query?: string;
}

export interface QuickLookItem {
  url: string;
  title: string;
  filename?: string;
  contentType?: string;
}

/** Page → shell. */
export type PageMessage =
  | { v: 1; type: "ready"; path: string }
  | { v: 1; type: "route"; path: string; area: AreaId | null }
  /** menu: the title's own menu (rename, archive…), shown on a chevron next to the title. */
  | { v: 1; type: "title"; title: string; subtitle?: string; menu?: MenuItem[] }
  /** The right rail; null: the page has none (the shell hides its rail). */
  | { v: 1; type: "rail"; model: RailModel | null }
  /** The native inspector model; null: the page has no inspector. */
  | { v: 1; type: "inspector"; model: InspectorModel | null }
  /** Forwards an interactive event from /inspector-panel back to the main page's active dock tab. */
  | { v: 1; type: "panel.event"; tabId: string; event: string; payloadJson?: string }
  /** Asks the shell to open an in-app path in the main content pane (or a new tab). */
  | { v: 1; type: "openInMain"; path: string; newTab?: boolean }
  | { v: 1; type: "shell"; model: ShellModel }
  | { v: 1; type: "navigator"; model: NavModel | null }
  /** True while the page shows a screen's list in its own fallback column (not yet described). */
  | { v: 1; type: "navigatorFallback"; active: boolean }
  /** True while a screen wants the whole window, e.g. a video in theater mode: the shell folds its sidebar, then restores it. */
  | { v: 1; type: "sidebarHidden"; hidden: boolean }
  | { v: 1; type: "toolbar"; items: ToolbarItem[] }
  /**
   * The page's effective color mode, whenever it changes; the shell matches each window's appearance to it.
   * background: the palette's page colour ("#RRGGBB"), which the shell shows past the page's edges
   * (overscroll) and behind a tab that hasn't painted yet.
   * tokens: the palette's resolved colours by CSS variable name without "--" ("text", "accent"…,
   * "#RRGGBB" or "#RRGGBBAA" only), and textSize the Settings text size, so native screens draw
   * with exactly what the page does.
   */
  | { v: 1; type: "appearance"; mode: ColorMode; background?: string; tokens?: Record<string, string>; textSize?: string }
  | { v: 1; type: "confirmApproval"; requestId: string; scope: ApprovalScope }
  | { v: 1; type: "openWorkspaceMenu"; requestId: string; folder: string }
  | { v: 1; type: "contextMenu"; requestId: string; items: MenuItem[]; x: number; y: number }
  /** An "Are you sure?" as a sheet on the window; the reply's ok is true only for the confirm button. */
  | { v: 1; type: "confirm"; requestId: string; title: string; body?: string; confirmLabel: string; cancelLabel?: string; destructive?: boolean }
  /** A single-line text input sheet on the window; the reply's ok is true on save, with `value`. */
  | {
      v: 1;
      type: "prompt";
      requestId: string;
      title: string;
      body?: string;
      label?: string;
      value?: string;
      placeholder?: string;
      confirmLabel: string;
      cancelLabel?: string;
      maxLength?: number;
    }
  | {
      v: 1;
      type: "toast.show";
      id: string;
      title: string;
      description?: string;
      tone: ToastTone;
      actionLabel?: string;
      durationMs: number;
    }
  | { v: 1; type: "toast.dismiss"; id: string }
  | { v: 1; type: "showShortcuts" }
  | { v: 1; type: "commandPalette.open"; request?: CommandPaletteRequest }
  | { v: 1; type: "commandPalette.close" }
  | { v: 1; type: "quickLook"; items: QuickLookItem[]; index?: number }
  | { v: 1; type: "openCustomAppWindow"; slug: string };

/** Shell → page. */
export type NativeCommand =
  | { v: 1; type: "navigate"; path: string }
  /** newTab: the row was ⌘-clicked; open its href in a new tab rather than here. */
  | { v: 1; type: "nav.activate"; navigatorId: string; itemId: string; newTab?: boolean }
  | { v: 1; type: "nav.action"; navigatorId: string; actionId: string; itemId?: string; menuItemId?: string }
  | { v: 1; type: "nav.picker"; navigatorId: string; pickerId: string; value: string }
  | { v: 1; type: "nav.filter"; navigatorId: string; filterId: string; value: string; checked: boolean }
  | { v: 1; type: "nav.search"; navigatorId: string; searchId: string; value: string }
  | { v: 1; type: "nav.toggle"; navigatorId: string; itemId: string; expanded: boolean }
  | { v: 1; type: "toolbar.action"; itemId: string; menuItemId?: string }
  | { v: 1; type: "title.action"; menuItemId: string }
  | { v: 1; type: "rail.action"; itemId: string; menuItemId?: string }
  | { v: 1; type: "inspector.visibility"; open: boolean }
  | { v: 1; type: "inspector.selectTab"; tabId: string }
  | { v: 1; type: "inspector.action"; tabId: string; actionId: string; itemId?: string; menuItemId?: string }
  | { v: 1; type: "inspector.change"; tabId: string; fieldId: string; value: string }
  | { v: 1; type: "inspector.toggle"; tabId: string; fieldId: string; checked: boolean }
  | { v: 1; type: "companion.context"; context: CompanionContext }
  | { v: 1; type: "panel.context"; context: InspectorPanelContext }
  | { v: 1; type: "panel.event"; tabId: string; event: string; payloadJson?: string }
  /** macOS's accent colour ("#RRGGBB") and effective appearance (plus optional synced native Appearance); sent when the page is ready and whenever either changes. */
  | { v: 1; type: "appearance"; accent: string; mode: ColorMode; themePref?: "system" | "dark" | "light"; settingsJson?: string }
  /** query only applies to openCommandMenu: the text to open the palette with (the toolbar search field). */
  | { v: 1; type: "command"; name: ShellCommandName; query?: string }
  | { v: 1; type: "reply"; requestId: string; ok: boolean; selectedId?: string | null; value?: string | null; error?: string }
  | { v: 1; type: "toast.event"; id: string; event: ToastEventKind }
  | { v: 1; type: "palette.open"; request: CommandPaletteRequest };

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
  "rail",
  "inspector",
  "panel.event",
  "openInMain",
  "shell",
  "navigator",
  "navigatorFallback",
  "sidebarHidden",
  "toolbar",
  "appearance",
  "confirmApproval",
  "openWorkspaceMenu",
  "contextMenu",
  "confirm",
  "prompt",
  "toast.show",
  "toast.dismiss",
  "showShortcuts",
  "commandPalette.open",
  "commandPalette.close",
  "quickLook",
  "openCustomAppWindow",
]);
const COMMAND_TYPES = new Set([
  "navigate",
  "nav.activate",
  "nav.action",
  "nav.picker",
  "nav.filter",
  "nav.search",
  "nav.toggle",
  "toolbar.action",
  "title.action",
  "rail.action",
  "inspector.visibility",
  "inspector.selectTab",
  "inspector.action",
  "inspector.change",
  "inspector.toggle",
  "companion.context",
  "panel.context",
  "panel.event",
  "command",
  "reply",
  "appearance",
  "toast.event",
  "palette.open",
]);

const RESERVED_CUSTOM_APP_SLUGS = new Set(["new", "api", "slides", "designs", "docs"]);
const isValidCustomAppSlug = (s: unknown): s is string =>
  typeof s === "string" && /^[a-z0-9][a-z0-9-]{0,47}$/.test(s) && !RESERVED_CUSTOM_APP_SLUGS.has(s);

const isObj = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
const isInAppPath = (p: unknown): p is string => typeof p === "string" && p.startsWith("/") && !p.startsWith("//");
const isSafeUrlRef = (u: unknown): u is string => isInAppPath(u) || (typeof u === "string" && /^https?:\/\/\S+$/i.test(u));
const isOptStr = (v: unknown): boolean => v === undefined || typeof v === "string";

function isPaletteRequest(v: unknown): v is CommandPaletteRequest {
  if (!isObj(v)) return false;
  if (v.path !== undefined && !isInAppPath(v.path)) return false;
  if (!isOptStr(v.search) || !isOptStr(v.scopeType) || !isOptStr(v.scopeLabel) || !isOptStr(v.query)) return false;
  if (v.scope !== undefined && v.scope !== "all" && v.scope !== "page" && v.scope !== "knowledge" && v.scope !== "type") return false;
  if (v.includeAgent !== undefined && typeof v.includeAgent !== "boolean") return false;
  return true;
}

/** A shallow check that a value is a v1 page message of a known type. */
export function isPageMessage(v: unknown): v is PageMessage {
  if (!isObj(v) || v.v !== PROTOCOL_VERSION || typeof v.type !== "string" || !PAGE_TYPES.has(v.type)) return false;
  if (v.type === "inspector") return v.model === null || isObj(v.model);
  if (v.type === "sidebarHidden") return typeof v.hidden === "boolean";
  if (v.type === "panel.event") {
    return typeof v.tabId === "string" && typeof v.event === "string" && (v.payloadJson === undefined || typeof v.payloadJson === "string");
  }
  if (v.type === "openInMain") return isInAppPath(v.path) && (v.newTab === undefined || typeof v.newTab === "boolean");
  if (v.type === "prompt") {
    return (
      typeof v.requestId === "string" &&
      typeof v.title === "string" &&
      typeof v.confirmLabel === "string" &&
      isOptStr(v.body) &&
      isOptStr(v.label) &&
      isOptStr(v.value) &&
      isOptStr(v.placeholder) &&
      isOptStr(v.cancelLabel) &&
      (v.maxLength === undefined || (typeof v.maxLength === "number" && Number.isInteger(v.maxLength) && v.maxLength > 0))
    );
  }
  if (v.type === "toast.show") {
    return (
      typeof v.id === "string" &&
      typeof v.title === "string" &&
      isOptStr(v.description) &&
      (v.tone === "neutral" || v.tone === "success" || v.tone === "error") &&
      isOptStr(v.actionLabel) &&
      typeof v.durationMs === "number" &&
      Number.isFinite(v.durationMs) &&
      v.durationMs > 0
    );
  }
  if (v.type === "toast.dismiss") return typeof v.id === "string";
  if (v.type === "commandPalette.open") return v.request === undefined || isPaletteRequest(v.request);
  if (v.type === "quickLook") {
    return (
      Array.isArray(v.items) &&
      v.items.length > 0 &&
      v.items.every(
        (it) => isObj(it) && isSafeUrlRef(it.url) && typeof it.title === "string" && isOptStr(it.filename) && isOptStr(it.contentType),
      ) &&
      (v.index === undefined || (typeof v.index === "number" && Number.isInteger(v.index) && v.index >= 0))
    );
  }
  if (v.type === "openCustomAppWindow") return isValidCustomAppSlug(v.slug);
  return true;
}

/** A shallow check that a value is a v1 native command of a known type. */
export function isNativeCommand(v: unknown): v is NativeCommand {
  if (!isObj(v) || v.v !== PROTOCOL_VERSION || typeof v.type !== "string" || !COMMAND_TYPES.has(v.type)) return false;
  if (v.type === "navigate") return isInAppPath(v.path);
  if (v.type === "appearance") {
    return (
      typeof v.accent === "string" &&
      /^#[\da-f]{6}$/i.test(v.accent) &&
      (v.mode === "dark" || v.mode === "light") &&
      (v.themePref === undefined || v.themePref === "system" || v.themePref === "dark" || v.themePref === "light") &&
      (v.settingsJson === undefined || typeof v.settingsJson === "string")
    );
  }
  if (v.type === "command") return SHELL_COMMANDS.includes(v.name as ShellCommandName) && (v.query === undefined || typeof v.query === "string");
  if (v.type === "inspector.visibility") return typeof v.open === "boolean";
  if (v.type === "inspector.selectTab") return typeof v.tabId === "string";
  if (v.type === "inspector.action") return typeof v.tabId === "string" && typeof v.actionId === "string";
  if (v.type === "inspector.change") return typeof v.tabId === "string" && typeof v.fieldId === "string" && typeof v.value === "string";
  if (v.type === "inspector.toggle") return typeof v.tabId === "string" && typeof v.fieldId === "string" && typeof v.checked === "boolean";
  if (v.type === "companion.context") return isObj(v.context);
  if (v.type === "panel.context") {
    if (!isObj(v.context) || !Array.isArray(v.context.keepKeys) || !v.context.keepKeys.every((k) => typeof k === "string")) return false;
    if (v.context.path !== undefined && typeof v.context.path !== "string") return false;
    if (v.context.active === null) return true;
    return isObj(v.context.active) && typeof v.context.active.kind === "string" && typeof v.context.active.key === "string" && typeof v.context.active.propsJson === "string";
  }
  if (v.type === "panel.event") {
    return typeof v.tabId === "string" && typeof v.event === "string" && (v.payloadJson === undefined || typeof v.payloadJson === "string");
  }
  if (v.type === "reply") {
    return (
      typeof v.requestId === "string" &&
      typeof v.ok === "boolean" &&
      (v.selectedId === undefined || v.selectedId === null || typeof v.selectedId === "string") &&
      (v.value === undefined || v.value === null || typeof v.value === "string") &&
      isOptStr(v.error)
    );
  }
  if (v.type === "toast.event") {
    return typeof v.id === "string" && (v.event === "action" || v.event === "dismissed" || v.event === "timeout");
  }
  if (v.type === "palette.open") return isPaletteRequest(v.request);
  return true;
}
