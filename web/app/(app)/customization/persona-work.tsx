"use client";

import { useUpdatePersona, type Persona } from "@/lib/api/persona-hooks";
import { isConflict, WORK, type PersonaWork } from "@/lib/persona-ui";
import { ButtonLink } from "@/components/ui/button";
import { Segmented, Toggle } from "@/components/ui/controls";
import { MonoChip } from "@/components/domain/labels";
import { AgentStatus } from "@/components/domain/overview";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

/**
 * What a persona does besides chatting (the design's Work tab): chat only or takes tickets,
 * and whether it's offered in the chat switcher. A persona that works keeps its harness,
 * model, work brief, permissions and limits on its work page.
 */
export function PersonaWorkSection({ p }: { p: Persona }) {
  const update = useUpdatePersona();
  const work = (p.work ?? "none") as PersonaWork;
  const hint = WORK.find((w) => w.value === work)?.hint;
  const set = (patch: { work?: PersonaWork; in_chat_list?: boolean }) => update.mutate({ id: p.id, patch: { revision: p.revision, ...patch } });
  return (
    <section aria-label="Work" data-testid="persona-work" className="flex flex-col gap-3 rounded-xl border border-border bg-surface p-4">
      <div className="flex flex-wrap items-center gap-3">
        <h3 className="type-heading flex-1">What {p.name} does</h3>
        <Toggle checked={p.in_chat_list !== false} disabled={update.isPending} onChange={(v) => set({ in_chat_list: v })} label="Show in chat list" />
      </div>
      <Segmented
        label={`What ${p.name} does`}
        value={work}
        onChange={(v) => v !== work && set({ work: v })}
        options={WORK.map((w) => ({ value: w.value, label: w.label }))}
      />
      <p className="text-12 text-fg-secondary">{hint}</p>
      {work !== "none" && (
        <div className="flex flex-wrap items-center gap-2 border-t border-border-subtle pt-3">
          {p.handle && <span className="font-mono text-12 text-fg-secondary">@{p.handle}</span>}
          {p.work_model && <MonoChip>{p.work_model}</MonoChip>}
          {p.work_status && <AgentStatus status={p.work_status} />}
          <span className="flex-1" />
          {p.handle && (
            <ButtonLink href={`/agents/${p.handle}?tab=settings`} variant="outline">
              Work settings
            </ButtonLink>
          )}
        </div>
      )}
      {work !== "none" && (
        <p className="text-12 text-fg-tertiary">
          Work settings hold its work brief, permissions, fallbacks and limits. Its voice and default model above reach its runs too.
        </p>
      )}
      {update.isError && (
        <p role="alert" className="text-12 text-pill-blocked-fg">
          {isConflict(update.error) && !(update.error instanceof Error && /ticket|run/.test(update.error.message))
            ? `${p.name} changed somewhere else. Reload and try again.`
            : errorText(update.error)}
        </p>
      )}
    </section>
  );
}
