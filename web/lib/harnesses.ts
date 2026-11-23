// What the web app knows about each harness beyond what the server reports
// (GET /agents/{handle} lists its capabilities). Kept here so the editors that
// branch on a harness agree.

export const HARNESS_LABELS: Record<string, string> = { "claude-code": "Claude Code", codex: "Codex", antigravity: "Antigravity" };

/**
 * Whether a harness takes a reasoning effort. `agy --effort` depends on the
 * model and the Gemini API doesn't say which models accept it, so Antigravity
 * shows no effort control (the server offers none either: chatmodels.go).
 */
export function takesEffort(harness: string): boolean {
  return harness !== "antigravity";
}

/** Image engines supported by Vesper, in the order "Auto" prefers them (runs.ImageEngines). */
export const IMAGE_ENGINES = ["codex", "antigravity", "gemini"] as const;
export type ImageEngine = (typeof IMAGE_ENGINES)[number];

export function harnessLabel(harness: string): string {
  return HARNESS_LABELS[harness] ?? harness;
}

/** The ~/.gemini/config/mcp_config.json entry that attaches a session you run yourself to an agent (agy reads remote servers from `serverUrl`). */
export function antigravityMcpConfig(mcpUrl: string, token: string): string {
  return JSON.stringify({ mcpServers: { lazyagents: { serverUrl: mcpUrl, headers: { Authorization: `Bearer ${token}` } } } }, null, 2);
}
