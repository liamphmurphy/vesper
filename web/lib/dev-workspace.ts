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
