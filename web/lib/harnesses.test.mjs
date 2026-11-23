import test from "node:test";
import assert from "node:assert/strict";
import { HARNESS_LABELS, IMAGE_ENGINES, harnessLabel, takesEffort } from "./harnesses.ts";

test("only Antigravity hides the effort control", () => {
  assert.equal(takesEffort("claude-code"), true);
  assert.equal(takesEffort("codex"), true);
  assert.equal(takesEffort("antigravity"), false);
});

test("every harness the server knows has a label, and an unknown one reads as itself", () => {
  assert.deepEqual(Object.keys(HARNESS_LABELS).sort(), ["antigravity", "claude-code", "codex"]);
  assert.equal(harnessLabel("antigravity"), "Antigravity");
  assert.equal(harnessLabel("opencode"), "opencode");
});

test("Codex, Antigravity, then Gemini API is the Auto order for images", () => {
  assert.deepEqual([...IMAGE_ENGINES], ["codex", "antigravity", "gemini"]);
});

test("the Antigravity attach snippet is the documented mcp_config.json shape", async () => {
  const { antigravityMcpConfig } = await import("./harnesses.ts");
  const cfg = JSON.parse(antigravityMcpConfig("https://v.example/mcp", "vsp_x"));
  assert.deepEqual(cfg, { mcpServers: { lazyagents: { serverUrl: "https://v.example/mcp", headers: { Authorization: "Bearer vsp_x" } } } });
});
