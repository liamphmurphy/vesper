import type { Schemas } from "@/lib/api/client";
import type { ComposerDrop } from "./playground-report";

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

export type TmuxPrefix = DevWorkspace["tmux_prefix"];

export function tmuxPrefixLabel(prefix: TmuxPrefix | undefined): string {
  switch (prefix) {
    case "C-a":
      return "Ctrl+a";
    case "C-Space":
      return "Ctrl+Space";
    case "C-s":
      return "Ctrl+s";
    default:
      return "Ctrl+b";
  }
}

export function devTerminalShortcutGroups(tmuxPrefix?: TmuxPrefix): TerminalShortcutGroup[] {
  const p = tmuxPrefixLabel(tmuxPrefix);
  return [
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
      title: `tmux (${p} prefix)`,
      items: [
        { keys: `${p} c`, description: "New shell window" },
        { keys: `${p} n / p`, description: "Next / previous window" },
        { keys: `${p} % / "`, description: "Split pane vertically / horizontally" },
        { keys: `${p} o`, description: "Cycle panes" },
        { keys: `${p} [`, description: "Scroll / copy mode (q to exit)" },
        { keys: `${p} d`, description: "Detach session (keeps running)" },
      ],
    },
    {
      title: "Browser & Fullscreen",
      items: [
        { keys: "Fullscreen", description: "Locks Esc, Ctrl+W/T/N to Neovim (Chromium)" },
        { keys: "Hold Esc (1.5s)", description: "Exit native fullscreen" },
        { keys: "Ctrl+K", description: "Sent to terminal while focused" },
        { keys: "Cmd+V / Ctrl+Shift+V", description: "Paste into terminal" },
        { keys: "Shift+drag", description: "Select text bypassing tmux mouse mode" },
      ],
    },
  ];
}

export const DEV_TERMINAL_SHORTCUT_GROUPS: TerminalShortcutGroup[] = devTerminalShortcutGroups("C-b");

export type TerminalBufferLine = { translateToString: (trimRight?: boolean) => string };
export type TerminalBufferLike = {
  length: number;
  getLine: (index: number) => TerminalBufferLine | undefined;
};

/** Reads up to the last maxLines non-trailing-empty lines from an xterm buffer. */
export function extractTerminalLines(buffer: TerminalBufferLike, maxLines = 120): string[] {
  let end = buffer.length - 1;
  while (end >= 0) {
    const line = buffer.getLine(end)?.translateToString(true) ?? "";
    if (line.length > 0) break;
    end--;
  }
  if (end < 0) return [];
  const start = Math.max(0, end - Math.max(1, maxLines) + 1);
  const out: string[] = [];
  for (let i = start; i <= end; i++) {
    out.push(buffer.getLine(i)?.translateToString(true) ?? "");
  }
  return out;
}

export function terminalSnapshotFilename(at: number): string {
  const stamp = new Date(at).toISOString().slice(0, 19).replace(/[-:]/g, "").replace("T", "-");
  return `dev-terminal-${stamp}.md`;
}

const fence = (s: string) => {
  const ticks = "`".repeat(Math.max(3, ...[...s.matchAll(/`+/g)].map((m) => m[0].length + 1)));
  return `${ticks}\n${s}\n${ticks}`;
};

export function formatTerminalSnapshot({
  lines,
  selection,
  cols,
  rows,
  at,
}: {
  lines: string[];
  selection?: string;
  cols: number;
  rows: number;
  at: number;
}): string {
  const out: string[] = [
    "# Dev terminal snapshot",
    "",
    `- Captured: ${new Date(at).toISOString()}`,
    `- Size: ${cols}x${rows}`,
    "",
  ];
  const trimmedSel = selection?.trim();
  if (trimmedSel) {
    out.push("## Selected text", "", fence(trimmedSel), "");
  }
  out.push(`## Visible terminal output (${lines.length} ${lines.length === 1 ? "line" : "lines"})`, "");
  if (lines.length === 0) {
    out.push("(empty)");
  } else {
    out.push(fence(lines.join("\n")));
  }
  return out.join("\n").trimEnd() + "\n";
}

export const COMPANION_OPEN_EVENT = "vesper:open-companion";
export const COMPANION_DROP_EVENT = "vesper:companion-drop";

let pendingCompanionDrop: ComposerDrop | null = null;

export function queueCompanionDrop(drop: ComposerDrop) {
  pendingCompanionDrop = drop;
  if (typeof window !== "undefined") {
    window.dispatchEvent(new Event(COMPANION_OPEN_EVENT));
    window.dispatchEvent(new Event(COMPANION_DROP_EVENT));
  }
}

export function peekCompanionDrop(): ComposerDrop | null {
  return pendingCompanionDrop;
}

export function clearCompanionDrop() {
  pendingCompanionDrop = null;
}
