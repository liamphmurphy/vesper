import type { Schemas } from "@/lib/api/client";

export type DevWorkspace = Schemas["DevWorkspace"];
export type DevWorkspaceRepo = DevWorkspace["repos"][number];
export type DevWorkspaceState = DevWorkspace["state"];

export function filterDevWorkspaceRepos(repos: readonly DevWorkspaceRepo[], query: string): DevWorkspaceRepo[] {
  const q = query.trim().toLowerCase();
  if (!q) return [...repos];
  return repos.filter((r) => r.repo_url.toLowerCase().includes(q) || r.directory.toLowerCase().includes(q));
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
