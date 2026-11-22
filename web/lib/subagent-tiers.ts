export const SUBAGENT_HARNESSES = [
  { id: "claude-code", label: "Claude Code" },
  { id: "codex", label: "Codex" },
  { id: "antigravity", label: "Antigravity" },
] as const;

export type SubagentHarnessId = (typeof SUBAGENT_HARNESSES)[number]["id"];
export type SubagentTierKey = "fast" | "standard" | "deep";
export type SubagentTierModels = { fast?: string; standard?: string; deep?: string };
export type SubagentTierRulesMap = Record<string, SubagentTierModels>;

type CatalogModelLike = { id: string; label?: string };

const ORCHESTRATOR_RE = /\borchestrator\b/i;

/** Filters out orchestrator wrapper entries when choosing subagent target models. */
export function selectableSubagentModels<M extends CatalogModelLike>(models: readonly M[] | undefined): M[] {
  if (!models?.length) return [];
  return models.filter((m) => !ORCHESTRATOR_RE.test(`${m.id} ${m.label ?? ""}`));
}

/** True when a configured model ID is no longer present in a loaded non-empty live catalog. */
export function isStaleTierModel(modelId: string | undefined, catalogModels: readonly CatalogModelLike[] | undefined): boolean {
  const needle = modelId?.trim().toLowerCase();
  if (!needle || !catalogModels?.length) return false;
  return !catalogModels.some((m) => m.id.trim().toLowerCase() === needle);
}

function cleanEntry(entry: SubagentTierModels | undefined): SubagentTierModels | undefined {
  if (!entry) return undefined;
  const out: SubagentTierModels = {};
  if (entry.fast?.trim()) out.fast = entry.fast.trim();
  if (entry.standard?.trim()) out.standard = entry.standard.trim();
  if (entry.deep?.trim()) out.deep = entry.deep.trim();
  return out.fast || out.standard || out.deep ? out : undefined;
}

/** Returns an updated rules map with empty strings trimmed and empty harness entries removed. */
export function setHarnessTierModel(
  rules: SubagentTierRulesMap | undefined,
  harness: string,
  tier: SubagentTierKey,
  modelId: string,
): SubagentTierRulesMap {
  const next: SubagentTierRulesMap = {};
  for (const [h, entry] of Object.entries(rules ?? {})) {
    if (h === harness) continue;
    const cleaned = cleanEntry(entry);
    if (cleaned) next[h] = cleaned;
  }
  const merged = cleanEntry({ ...(rules?.[harness] ?? {}), [tier]: modelId });
  if (merged) next[harness] = merged;
  return next;
}

/** Returns an updated rules map with the given harness rule removed. */
export function clearHarnessTierRule(rules: SubagentTierRulesMap | undefined, harness: string): SubagentTierRulesMap {
  const next: SubagentTierRulesMap = {};
  for (const [h, entry] of Object.entries(rules ?? {})) {
    if (h === harness) continue;
    const cleaned = cleanEntry(entry);
    if (cleaned) next[h] = cleaned;
  }
  return next;
}
