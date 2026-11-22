import test from "node:test";
import assert from "node:assert/strict";
import {
  clearHarnessTierRule,
  isStaleTierModel,
  selectableSubagentModels,
  setHarnessTierModel,
} from "./subagent-tiers.ts";

test("selectableSubagentModels filters orchestrators and preserves non-orchestrators", () => {
  const models = [
    { id: "gemini-4-carbon", label: "Gemini 4 Carbon" },
    { id: "gemini-pro-orchestrator", label: "Orchestrator (Carbon)" },
    { id: "gemini-4-neon", label: "Gemini 4 Neon" },
    { id: "gemini-pro-orchestrator-neon", label: "Orchestrator (Neon)" },
    { id: "gemini-4-hydrogen", label: "Gemini 4 Hydrogen" },
  ];
  assert.deepEqual(
    selectableSubagentModels(models).map((m) => m.id),
    ["gemini-4-carbon", "gemini-4-neon", "gemini-4-hydrogen"],
  );
  assert.deepEqual(selectableSubagentModels(undefined), []);
});

test("isStaleTierModel flags retired models only once a live catalog is loaded", () => {
  const live = [{ id: "gemini-4-carbon" }, { id: "gemini-4-neon" }, { id: "gemini-4-hydrogen" }];
  assert.equal(isStaleTierModel("gemini-4-neon", live), false);
  assert.equal(isStaleTierModel("GEMINI-4-NEON", live), false);
  assert.equal(isStaleTierModel("gemini-3.8-flash", live), true);
  assert.equal(isStaleTierModel("", live), false);
  assert.equal(isStaleTierModel(undefined, live), false);
  // Empty / unloaded catalog must never falsely report stale.
  assert.equal(isStaleTierModel("gemini-3.8-flash", []), false);
  assert.equal(isStaleTierModel("gemini-3.8-flash", undefined), false);
});

test("setHarnessTierModel and clearHarnessTierRule maintain clean immutable maps", () => {
  let rules = setHarnessTierModel({}, "antigravity", "deep", " gemini-4-carbon ");
  rules = setHarnessTierModel(rules, "antigravity", "standard", "gemini-4-neon");
  rules = setHarnessTierModel(rules, "antigravity", "fast", "gemini-4-hydrogen");
  assert.deepEqual(rules, {
    antigravity: {
      deep: "gemini-4-carbon",
      standard: "gemini-4-neon",
      fast: "gemini-4-hydrogen",
    },
  });

  // Clearing individual tiers cleans out empty strings; clearing the last drops the harness entry.
  rules = setHarnessTierModel(rules, "claude-code", "fast", "haiku");
  rules = setHarnessTierModel(rules, "claude-code", "fast", "");
  assert.equal("claude-code" in rules, false);
  assert.equal(rules.antigravity.deep, "gemini-4-carbon");

  const cleared = clearHarnessTierRule(rules, "antigravity");
  assert.deepEqual(cleared, {});
});
