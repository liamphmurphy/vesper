"use client";

import type { Schemas } from "@/lib/api/client";
import { useChatModels, useUpdateRunnerSettings } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import {
  clearHarnessTierRule,
  isStaleTierModel,
  selectableSubagentModels,
  setHarnessTierModel,
  SUBAGENT_HARNESSES,
  type SubagentTierKey,
  type SubagentTierRulesMap,
} from "@/lib/subagent-tiers";
import { Toggle } from "@/components/ui/controls";

const TIERS: ReadonlyArray<{ key: SubagentTierKey; label: string }> = [
  { key: "deep", label: "Deep" },
  { key: "standard", label: "Standard" },
  { key: "fast", label: "Fast" },
];

/**
 * Workspace toggle for automatic subagent tier routing plus optional per-harness
 * model ladders (Deep / Standard / Fast). Off by default? No: routing starts
 * on in effort-only mode; toggling it off restores legacy pre-tier subagents.
 */
export function SubagentTierRulesSetting({
  enabled,
  rules,
}: {
  enabled: boolean;
  rules?: Schemas["RunnerStatus"]["subagent_tier_models"];
}) {
  const models = useChatModels();
  const update = useUpdateRunnerSettings();
  const currentRules: SubagentTierRulesMap = (rules ?? {}) as SubagentTierRulesMap;
  const groups = models.data;

  return (
    <div className="space-y-3">
      <div>
        <Toggle
          checked={enabled}
          disabled={update.isPending}
          onChange={(subagent_tier_routing) => update.mutate({ subagent_tier_routing })}
          label="Automatic subagent tier routing"
        />
        <span className="mt-1 block text-12 text-fg-tertiary">
          {enabled
            ? "Personas pick fast, standard, or deep per subagent. By default each subagent scales reasoning effort on the parent’s model; configure optional per-harness ladders below (e.g. Carbon → Neon → Hydrogen) to step across models, capped at the parent’s tier."
            : "Subagent tier routing is off: helpers inherit the parent’s model and effort unchanged, and explorers use their default fast model. Chat’s Auto model picker is unaffected."}
        </span>
      </div>

      {enabled && (
        <div className="space-y-2.5">
          {SUBAGENT_HARNESSES.map((h) => {
            const entry = currentRules[h.id] ?? {};
            const hasCustom = Boolean(entry.fast || entry.standard || entry.deep);
            const group = groups?.find((g) => g.harness === h.id);
            const rawModels = group?.models ?? [];
            const options = selectableSubagentModels(rawModels);
            const anyStale = TIERS.some((t) => isStaleTierModel(entry[t.key], rawModels));

            return (
              <div key={h.id} className="rounded-lg border border-border-subtle bg-surface-sunken/35 p-3">
                <div className="mb-2 flex flex-wrap items-center justify-between gap-2">
                  <div className="flex items-center gap-2">
                    <span className="text-13 font-medium text-fg">{h.label}</span>
                    <span
                      className={cx(
                        "rounded-full px-1.5 py-[1px] font-mono text-10 font-medium",
                        hasCustom ? "bg-accent-soft text-accent" : "bg-pill-neutral-bg text-pill-neutral-fg",
                      )}
                    >
                      {hasCustom ? "Custom ladder" : "Effort only"}
                    </span>
                  </div>
                  {hasCustom && (
                    <button
                      type="button"
                      disabled={update.isPending}
                      onClick={() => update.mutate({ subagent_tier_models: clearHarnessTierRule(currentRules, h.id) })}
                      className="text-12 text-fg-secondary transition-colors duration-(--motion-fast) hover:text-fg disabled:opacity-50"
                    >
                      Reset
                    </button>
                  )}
                </div>

                <div className="grid gap-2 sm:grid-cols-3">
                  {TIERS.map((t) => {
                    const val = entry[t.key] ?? "";
                    const stale = isStaleTierModel(val, rawModels);
                    const selectId = `subagent-tier-${h.id}-${t.key}`;
                    return (
                      <div key={t.key} className="flex flex-col gap-1">
                        <label htmlFor={selectId} className="text-11 text-fg-secondary">
                          {t.label}
                        </label>
                        <select
                          id={selectId}
                          aria-label={`${h.label} ${t.label} tier model`}
                          value={val}
                          disabled={update.isPending}
                          onChange={(e) =>
                            update.mutate({
                              subagent_tier_models: setHarnessTierModel(currentRules, h.id, t.key, e.target.value),
                            })
                          }
                          className="h-[30px] w-full rounded-md border border-border-strong bg-surface px-2 text-12 text-fg focus:border-accent focus:outline-none disabled:opacity-50"
                        >
                          <option value="">Parent model (effort only)</option>
                          {options.map((m) => (
                            <option key={m.id} value={m.id}>
                              {m.label || m.id}
                            </option>
                          ))}
                          {stale && <option value={val}>{val} (not in catalog)</option>}
                          {!group && val && <option value={val}>{val}</option>}
                        </select>
                      </div>
                    );
                  })}
                </div>

                {anyStale && (
                  <p className="mt-1.5 text-11 text-pill-human-fg">
                    Retired or unlisted models fall back safely to the parent model with scaled effort until updated.
                  </p>
                )}
                {(!group || (!group.available && rawModels.length === 0)) && (
                  <p className="mt-1.5 text-11 text-fg-tertiary">
                    {group?.checking
                      ? "Checking available models…"
                      : "Connect this harness in Secrets & Credentials to pick from its live model list."}
                  </p>
                )}
              </div>
            );
          })}
        </div>
      )}

      {update.isError && (
        <span role="alert" className="block text-12 text-pill-blocked-fg">
          Couldn’t save: {update.error.message}
        </span>
      )}
    </div>
  );
}
