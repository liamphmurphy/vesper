import type { InboxItemSummary } from "./notifications";
import type { StackHealth } from "./stack-health";
import { clipLabel, newestNeedsYou, type TrayMenuItem } from "./tray-model";

/**
 * The Dock icon's right-click menu and progress bar, as data (unit tested;
 * native.ts maps it onto app.dock.setMenu and setProgressBar). macOS adds
 * the window list, Options and Quit itself.
 */

export interface PersonaSummary {
  id: string;
  name: string;
}

export interface DockMenuInput {
  items: readonly InboxItemSummary[];
  personas: readonly PersonaSummary[];
  /** Offer Screenshot to Chat (macOS only). */
  screenshot: boolean;
  maxItems?: number;
  maxPersonas?: number;
}

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** The web app's "new chat" page, with a persona when it's a valid id (chat-screen.tsx reads ?new&persona=). */
export function newChatHref(personaId?: string): string {
  return personaId && UUID_RE.test(personaId) ? `/chat?new&persona=${personaId}` : "/chat?new";
}

export function buildDockMenu(input: DockMenuInput): TrayMenuItem[] {
  const maxItems = input.maxItems ?? 5;
  const maxPersonas = input.maxPersonas ?? 6;
  const out: TrayMenuItem[] = [];

  const needs = newestNeedsYou(input.items);
  if (needs.length > 0) {
    out.push({ type: "header", label: `Needs you (${needs.length})` });
    for (const item of needs.slice(0, maxItems)) {
      const who = item.ticket_key ? `${item.ticket_key} · ` : "";
      out.push({ type: "item", label: clipLabel(`${who}${item.title}`), action: { kind: "open-href", href: item.href || "/inbox" } });
    }
    if (needs.length > maxItems) out.push({ type: "item", label: `Show all ${needs.length} in Inbox…`, action: { kind: "open-href", href: "/inbox" } });
    out.push({ type: "separator" });
  }

  out.push({ type: "item", label: "New Chat", action: { kind: "open-href", href: newChatHref() } });
  const personas = input.personas.filter((p) => UUID_RE.test(p.id) && p.name.trim()).slice(0, maxPersonas);
  for (const p of personas) {
    out.push({ type: "item", label: clipLabel(`New Chat with ${p.name.trim()}`), action: { kind: "open-href", href: newChatHref(p.id) } });
  }
  out.push({ type: "separator" });
  out.push({ type: "item", label: "Quick Capture…", action: { kind: "quick-capture" } });
  if (input.screenshot) out.push({ type: "item", label: "Screenshot to Chat…", action: { kind: "screenshot" } });
  return out;
}

/** Dock progress: the run image download's fraction, or -1 for none. */
export function dockProgress(health: StackHealth): number {
  const p = health.phase === "downloading" ? health.progress : undefined;
  if (!p || !(p.total > 0)) return -1;
  return Math.min(1, Math.max(0, p.done / p.total));
}

/**
 * What the Show/Hide shortcut does: hide Vesper when it's the active app
 * with a window showing, otherwise bring it forward (opening a window if
 * none exists).
 */
export function showHideAction(state: { appFocused: boolean; visibleWindows: number }): "show" | "hide" {
  return state.appFocused && state.visibleWindows > 0 ? "hide" : "show";
}
