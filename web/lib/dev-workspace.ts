import type { Schemas } from "@/lib/api/client";

export type DevWorkspace = Schemas["DevWorkspace"];
export type DevWorkspaceState = DevWorkspace["state"];

export function devWorkspaceSocketUrl(
  loc: { protocol: string; hostname: string },
  port: number,
  cols: number,
  rows: number,
): string {
  const host = loc.hostname.includes(":") && !loc.hostname.startsWith("[") ? `[${loc.hostname}]` : loc.hostname;
  const wsProto = loc.protocol.toLowerCase() === "https:" ? "wss:" : "ws:";
  return `${wsProto}//${host}:${port}/ws?cols=${Math.max(1, Math.floor(cols))}&rows=${Math.max(1, Math.floor(rows))}`;
}

export function devWorkspaceStatusTone(state: DevWorkspaceState): "done" | "human" | "blocked" | "neutral" {
  switch (state) {
    case "ready":
      return "done";
    case "starting":
      return "human";
    case "error":
      return "blocked";
    default:
      return "neutral";
  }
}

export function devWorkspaceStatusLabel(ws: Pick<DevWorkspace, "enabled" | "state" | "step">): string {
  if (!ws.enabled && ws.state === "stopped") return "Stopped (not configured)";
  if (ws.state === "starting") return ws.step ? `Starting · ${ws.step}` : "Starting…";
  if (ws.state === "ready") return "Ready";
  if (ws.state === "error") return "Error";
  return "Stopped";
}

export const FULLSCREEN_LOCK_KEYS = ["Escape", "KeyW", "KeyT", "KeyN"] as const;

export function fullscreenExitHint(native: boolean, keyboardLocked: boolean): string {
  if (native && keyboardLocked) return "Hold Esc to exit";
  if (native) return "Esc or Exit";
  return "Exit";
}

export type TerminalShortcutGroup = {
  title: string;
  items: { keys: string; description: string }[];
};

export const DEV_TERMINAL_SHORTCUT_GROUPS: TerminalShortcutGroup[] = [
  {
    title: "LazyVim & Neovim",
    items: [
      { keys: "Space", description: "Leader menu (which-key)" },
      { keys: "Space f f", description: "Find files across /workspace" },
      { keys: "Space /", description: "Live grep (ripgrep)" },
      { keys: "Space e", description: "Toggle file explorer" },
      { keys: "Space g g", description: "Open lazygit" },
      { keys: "Space f t", description: "Toggle floating terminal" },
      { keys: "Ctrl+h / j / k / l", description: "Move between editor splits" },
      { keys: "Ctrl+w", description: "Window management prefix" },
    ],
  },
  {
    title: "tmux (Ctrl+b prefix)",
    items: [
      { keys: "Ctrl+b c", description: "New shell window" },
      { keys: "Ctrl+b n / p", description: "Next / previous window" },
      { keys: "Ctrl+b % / \"", description: "Split pane vertically / horizontally" },
      { keys: "Ctrl+b o", description: "Cycle panes" },
      { keys: "Ctrl+b [", description: "Scroll / copy mode (q to exit)" },
      { keys: "Ctrl+b d", description: "Detach session (keeps running)" },
    ],
  },
  {
    title: "Browser & Fullscreen",
    items: [
      { keys: "Fullscreen", description: "Locks Esc, Ctrl+W/T/N to Neovim (Chromium)" },
      { keys: "Hold Esc (1.5s)", description: "Exit native fullscreen" },
      { keys: "Ctrl+K", description: "Sent to terminal while focused" },
    ],
  },
];
