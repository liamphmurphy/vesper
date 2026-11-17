import type { InboxItemSummary } from "./notifications";
import { pausableRuns, type RunSummary } from "./runs";
import type { StackHealth } from "./stack-health";

/**
 * The menu bar (tray) menu as data (LAZYAGENTS-240), so its content is unit
 * tested and main.ts only maps it onto Electron's Menu.
 */

export type TrayAction =
  | { kind: "open" }
  | { kind: "open-href"; href: string }
  | { kind: "quick-capture" }
  | { kind: "pause-runs" }
  | { kind: "resume-runs" }
  | { kind: "restart-stack" }
  | { kind: "show-logs" }
  | { kind: "preferences" }
  | { kind: "quit" };

export type TrayMenuItem =
  | { type: "header"; label: string }
  | { type: "item"; label: string; action: TrayAction; enabled?: boolean; accelerator?: string }
  | { type: "separator" };

export interface TrayMenuInput {
  health: StackHealth;
  /** Whether this app runs the stack (Restart / Logs only make sense then). */
  localStack: boolean;
  items: readonly InboxItemSummary[];
  runs: readonly RunSummary[];
  /** Runs paused from the tray (or on sleep) that Resume would restart. */
  pausedByVesper: number;
  quickCapture?: { enabled: boolean; shortcut: string };
  maxPerSection?: number;
}

const LABEL_MAX = 48;

export function clipLabel(text: string, max = LABEL_MAX): string {
  const flat = (text ?? "").replace(/\s+/g, " ").trim();
  return flat.length > max ? `${flat.slice(0, max - 1).trimEnd()}…` : flat;
}

/** Open, unread Needs-you items, newest first. */
export function newestNeedsYou(items: readonly InboxItemSummary[]): InboxItemSummary[] {
  return items
    .filter((i) => i.needs_you && !i.resolved && !i.read)
    .slice()
    .sort((a, b) => Date.parse(b.created_at) - Date.parse(a.created_at));
}

function statusLine(health: StackHealth): string {
  switch (health.phase) {
    case "running":
      return "● Vesper is running";
    case "remote":
      return "● Connected";
    case "starting":
      return "○ Starting…";
    case "downloading":
      return health.progress && health.progress.total > 0
        ? `○ Downloading run image (${Math.floor((100 * health.progress.done) / health.progress.total)}%)`
        : "○ Downloading run image…";
    case "stopped":
      return "○ Stack stopped";
    default:
      return `⚠ ${health.title}`;
  }
}

/** Builds the tray menu from the latest inbox, runs and stack health. */
export function buildTrayMenu(input: TrayMenuInput): TrayMenuItem[] {
  const max = input.maxPerSection ?? 5;
  const out: TrayMenuItem[] = [{ type: "header", label: statusLine(input.health) }];
  if (input.health.phase === "error" || input.health.phase === "degraded") {
    out.push({ type: "header", label: clipLabel(input.health.nextStep || input.health.message, 60) });
  }
  out.push({ type: "separator" });

  const needs = newestNeedsYou(input.items);
  out.push({ type: "header", label: needs.length > 0 ? `Needs you (${needs.length})` : "Nothing needs you" });
  for (const item of needs.slice(0, max)) {
    const who = item.ticket_key ? `${item.ticket_key} · ` : "";
    out.push({ type: "item", label: clipLabel(`${who}${item.title}`), action: { kind: "open-href", href: item.href || "/inbox" } });
  }
  if (needs.length > max) {
    out.push({ type: "item", label: `Show all ${needs.length} in Inbox…`, action: { kind: "open-href", href: "/inbox" } });
  }

  const running = input.runs.filter((r) => r.purpose !== "chat");
  if (running.length > 0) {
    out.push({ type: "separator" });
    out.push({ type: "header", label: `Running (${running.length})` });
    for (const run of running.slice(0, max)) {
      const title = run.work_title || run.ticket_key || "Run";
      const who = run.agent?.name ? `${run.agent.name}: ` : "";
      const paused = run.state === "paused" ? " (paused)" : "";
      out.push({ type: "item", label: clipLabel(`${who}${title}${paused}`), action: { kind: "open-href", href: `/runs/${run.id}` } });
    }
    if (running.length > max) {
      out.push({ type: "item", label: `Show all ${running.length} runs…`, action: { kind: "open-href", href: "/runs" } });
    }
  }

  out.push({ type: "separator" });
  out.push({ type: "item", label: "Open Vesper", action: { kind: "open" } });
  if (input.quickCapture?.enabled) {
    out.push({ type: "item", label: "Quick Capture…", action: { kind: "quick-capture" }, accelerator: input.quickCapture.shortcut });
  }

  const pausable = pausableRuns(running).length;
  if (input.pausedByVesper > 0) {
    out.push({ type: "item", label: `Resume Runs (${input.pausedByVesper})`, action: { kind: "resume-runs" } });
  } else {
    out.push({ type: "item", label: pausable > 0 ? `Pause Runs (${pausable})` : "Pause Runs", action: { kind: "pause-runs" }, enabled: pausable > 0 });
  }

  if (input.localStack) {
    out.push({ type: "separator" });
    out.push({ type: "item", label: "Restart Stack", action: { kind: "restart-stack" }, enabled: input.health.phase !== "starting" });
    out.push({ type: "item", label: "Show Logs…", action: { kind: "show-logs" } });
  }

  out.push({ type: "separator" });
  out.push({ type: "item", label: "Settings…", action: { kind: "preferences" } });
  out.push({ type: "item", label: "Quit Vesper", action: { kind: "quit" } });
  return out;
}

/** Text beside the menu bar icon: the Needs-you count, or nothing. */
export function trayTitle(count: number, showCount: boolean): string {
  if (!showCount || !Number.isFinite(count) || count <= 0) return "";
  return count > 99 ? "99+" : String(Math.floor(count));
}

export function trayTooltip(health: StackHealth, count: number): string {
  const needs = count > 0 ? ` · ${count} need${count === 1 ? "s" : ""} you` : "";
  return `Vesper: ${health.title}${needs}`;
}

/**
 * What to do when the last window closes. "menuBar" needs the tray: without
 * it the app would be invisible, so it falls back to the Dock.
 */
export function lastWindowClosedAction(settings: {
  enabled: boolean;
  onLastWindowClose: "dock" | "menuBar" | "quit";
}): "stay" | "hide-dock" | "quit" {
  if (settings.onLastWindowClose === "quit") return "quit";
  if (settings.onLastWindowClose === "menuBar" && settings.enabled) return "hide-dock";
  return "stay";
}
