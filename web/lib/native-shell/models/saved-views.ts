// Saved ticket views (components/domain/saved-views.tsx) as a NavSection for the native sidebar,
// and as the menu of an open view's title. Pure: the screen feeds in the views and acts on the
// decoded command. Ids are the protocol between this file's builder and parser.
import type { MenuItem, NativeCommand, NavSection } from "../protocol.ts";

export const SAVED_VIEWS_SECTION = "saved-views";
export const SV_SAVE = "sv.save";
export const SV_RENAME = "sv.rename";
export const SV_SAVE_AS = "sv.save-as";
export const SV_COPY_LINK = "sv.copy-link";
export const SV_DELETE = "sv.delete";

const ROW = "sv:";
export const savedViewRowId = (id: string) => `${ROW}${id}`;

/** What a view's menu offers; the same for its sidebar row (context menu) and its open page (title menu). */
export function savedViewMenu(): MenuItem[] {
  return [
    { id: SV_RENAME, label: "Rename…", icon: "edit" },
    { id: SV_SAVE_AS, label: "Save as new view…", icon: "bookmark" },
    { id: SV_COPY_LINK, label: "Copy link", icon: "link" },
    { id: "sv.sep", separator: true },
    { id: SV_DELETE, label: "Delete view", icon: "trash", destructive: true },
  ];
}

export interface SavedViewRow {
  id: string;
  name: string;
  /** Where the row goes; absent when the screen opens a view itself (Work applies it to its own URL). */
  href?: string;
}

/** The "Saved views" section: a row per view (selected = the open one), a menu per row, and "Save view…" on the header. */
export function buildSavedViewsSection(views: readonly SavedViewRow[]): NavSection {
  return {
    id: SAVED_VIEWS_SECTION,
    title: "Saved views",
    items: views.map((v) => ({
      id: savedViewRowId(v.id),
      title: v.name,
      icon: "bookmark",
      ...(v.href ? { href: v.href } : {}),
      contextMenu: savedViewMenu(),
    })),
    actions: [{ id: SV_SAVE, label: "Save view…", icon: "plus" }],
    emptyText: "No saved views",
  };
}

export type SavedViewCommand =
  | { type: "open"; id: string }
  | { type: "save" }
  | { type: "rename" | "saveAs" | "copyLink" | "delete"; id: string };

const MENU: Record<string, "rename" | "saveAs" | "copyLink" | "delete"> = {
  [SV_RENAME]: "rename",
  [SV_SAVE_AS]: "saveAs",
  [SV_COPY_LINK]: "copyLink",
  [SV_DELETE]: "delete",
};

/** A row press, a row's context-menu choice, or the section's "Save view…"; null for anything else. */
export function parseSavedViewCommand(cmd: NativeCommand): SavedViewCommand | null {
  if (cmd.type === "nav.activate") return cmd.itemId.startsWith(ROW) ? { type: "open", id: cmd.itemId.slice(ROW.length) } : null;
  if (cmd.type !== "nav.action") return null;
  if (cmd.actionId === SV_SAVE && !cmd.itemId) return { type: "save" };
  const kind = MENU[cmd.actionId];
  return kind && cmd.itemId?.startsWith(ROW) ? { type: kind, id: cmd.itemId.slice(ROW.length) } : null;
}

/** What a choice in the title menu of an open view means. */
export const parseSavedViewTitleAction = (menuItemId: string): "rename" | "saveAs" | "copyLink" | "delete" | null => MENU[menuItemId] ?? null;

/** The keys Work's tickets view keeps in a saved view, URL param → the view's query param. */
const WORK_KEYS = ["status", "label", "q", "layout", "ready", "blocked", "unestimated"] as const;

/** A saved view's query from Work's own URL params (the Work screen names some params differently). */
export function workViewQuery(params: { has(k: string): boolean; get(k: string): string | null }): string {
  const q = new URLSearchParams();
  for (const key of WORK_KEYS) if (params.has(key)) q.set(key, params.get(key)!);
  if (params.has("filter_epic")) q.set("epic", params.get("filter_epic")!);
  if (params.has("agent")) q.set("assignee", params.get("agent")!);
  q.set("view", params.get("ticket_view") ?? "all");
  return q.toString();
}

/** The Work URL patch that opens a saved view: its filters in Work's param names, the rest cleared. */
export function workViewPatch(id: string, query: string): Record<string, string | null> {
  const patch: Record<string, string | null> = { saved: id };
  for (const key of ["status", "label", "q", "filter_epic", "agent", "ticket_view", "ready", "blocked", "unestimated"]) patch[key] = null;
  for (const [key, value] of new URLSearchParams(query)) {
    if (key === "view") patch.ticket_view = value;
    else if (key === "assignee") patch.agent = value;
    else if (key === "epic") patch.filter_epic = value;
    else if ((WORK_KEYS as readonly string[]).includes(key)) patch[key] = value;
  }
  return patch;
}
