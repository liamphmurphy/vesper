"use client";

import type { Harness } from "@/lib/api/client";
import { useBootstrap, useChatModels } from "@/lib/api/hooks";
import { useUpdatePersona, type Persona } from "@/lib/api/persona-hooks";
import { isConflict, type PersonaWork } from "@/lib/persona-ui";
import { newChatSelection } from "@/lib/welcome";
import { ModelEffortPicker, modelEfforts, type Effort, type Selection } from "../chat/_components/model-picker";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

const fieldTrigger =
  "flex h-[32px] max-w-full items-center gap-2 rounded-md border border-border-strong bg-surface px-2.5 text-13 text-fg hover:bg-hover disabled:cursor-not-allowed disabled:opacity-50";

/**
 * Default harness, model, and reasoning effort for a persona. Pulls from the live
 * /chat-models catalog (same picker as the chat composer) and keeps work definitions
 * in sync when the persona does work.
 */
export function PersonaModelSection({ p }: { p: Persona }) {
  const models = useChatModels();
  const boot = useBootstrap();
  const update = useUpdatePersona();
  const work = (p.work ?? "none") as PersonaWork;
  const groups = models.data;
  const isAuto = !p.default_harness || !p.default_model;
  const guess = newChatSelection(groups, boot.data?.agents ?? []);
  const value: Selection = isAuto
    ? { harness: guess?.harness ?? "claude-code", model: guess?.model ?? "", auto: true }
    : { harness: p.default_harness as Harness, model: p.default_model! };

  const offered = value.model ? modelEfforts(groups, value) : { efforts: [] };
  const rawEffort = p.default_effort as Effort | undefined;
  const effort = rawEffort && (!groups || offered.efforts.includes(rawEffort)) ? rawEffort : undefined;

  function pickModel(s: Selection) {
    if (s.auto) {
      update.mutate({
        id: p.id,
        patch: {
          revision: p.revision,
          default_harness: "",
          default_model: "auto",
          ...(p.default_effort ? { default_effort: "default" } : {}),
        },
      });
      return;
    }
    const nextEfforts = modelEfforts(groups, s).efforts;
    const clearEffort = !!p.default_effort && !nextEfforts.includes(p.default_effort as Effort);
    update.mutate({
      id: p.id,
      patch: {
        revision: p.revision,
        default_harness: s.harness,
        default_model: s.model,
        ...(clearEffort ? { default_effort: "default" } : {}),
      },
    });
  }

  function pickEffort(e: Effort | undefined) {
    update.mutate({
      id: p.id,
      patch: {
        revision: p.revision,
        default_effort: e ?? "default",
      },
    });
  }

  return (
    <section aria-label="Default model" data-testid="persona-model" className="flex flex-col gap-3 rounded-xl border border-border bg-surface p-4">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-col gap-0.5">
          <h3 className="type-heading">Default model</h3>
          <p className="text-12 text-fg-secondary">
            {work !== "none"
              ? `Used for new chats and work items (tickets and helper runs) with ${p.name}.`
              : `Used for new chats with ${p.name}, and its starting model if you turn work on.`}
          </p>
        </div>
        <ModelEffortPicker
          groups={groups}
          value={value}
          onChange={pickModel}
          efforts={offered.efforts}
          effort={effort}
          onEffort={pickEffort}
          disabled={update.isPending}
          allowAuto
          showHarness
          side="bottom"
          align="end"
          ariaLabel={`Default model and effort for ${p.name}`}
          triggerClassName={fieldTrigger}
        />
      </div>
      {update.isError && (
        <p role="alert" className="text-12 text-pill-blocked-fg">
          {isConflict(update.error) ? `${p.name} changed somewhere else. Reload and try again.` : errorText(update.error)}
        </p>
      )}
    </section>
  );
}
