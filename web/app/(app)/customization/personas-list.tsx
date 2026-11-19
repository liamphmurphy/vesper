"use client";

import Link from "next/link";
import { useState } from "react";
import { useAgentOverviews } from "@/lib/api/hooks";
import type { Persona } from "@/lib/api/persona-hooks";
import { sortPersonas, WORK, type PersonaWork } from "@/lib/persona-ui";
import { cx } from "@/lib/cx";
import { Button } from "@/components/ui/button";
import { Segmented } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { EmptyState } from "@/components/ui/primitives";
import { AgentStatus } from "@/components/domain/overview";
import { useMarkAgentsReviewed } from "@/components/domain/setup";
import { PersonaAvatar, PersonaName } from "../chat/_components/persona";
import { DefaultBadge } from "./persona-profile";

export type PersonaFilter = "all" | "chat" | "tickets" | "helper";

const FILTERS: { value: PersonaFilter; label: string; keep: (p: Persona) => boolean }[] = [
  { value: "all", label: "All", keep: () => true },
  { value: "chat", label: "In chat", keep: (p) => p.in_chat_list !== false },
  { value: "tickets", label: "Takes tickets", keep: (p) => workOf(p) === "tickets" },
  { value: "helper", label: "Helps on runs", keep: (p) => workOf(p) === "helper" },
];

/** What a persona does besides chatting; "none" when the server didn't say. */
const workOf = (p: Persona): PersonaWork => (p.work ?? "none") as PersonaWork;

/** What the Does column says: the switches, as words. */
function does(p: Persona): string {
  const work = workOf(p);
  const parts = work === "none" ? ["Chat"] : [WORK.find((w) => w.value === work)?.label ?? ""];
  if (p.capabilities.code) parts.push("Codes");
  return parts.join(" · ");
}

/**
 * Every persona in one list (the design's frame A): who you talk with and who does the
 * work. A row opens the persona; "Now" is its live run (by ticket) or its work status.
 */
export function PersonasList({ personas, filter: initial = "all", onOpen, onNew, canAdd }: {
  personas: Persona[];
  filter?: PersonaFilter;
  onOpen: (id: string) => void;
  onNew: () => void;
  canAdd: boolean;
}) {
  const [filter, setFilter] = useState<PersonaFilter>(initial);
  // Opening the list ticks setup's "Review who does the work" step.
  useMarkAgentsReviewed();
  const overviews = useAgentOverviews();
  const live = new Map((overviews.data?.agents ?? []).map((o) => [o.agent.id, o.assignments[0]?.ticket.key]));
  const count = (f: PersonaFilter) => personas.filter(FILTERS.find((x) => x.value === f)!.keep).length;
  const rows = sortPersonas(personas.filter(FILTERS.find((x) => x.value === filter)!.keep));
  return (
    <section aria-label="Personas" className="flex flex-col gap-4">
      <header className="flex items-center gap-4">
        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <h1 className="truncate type-display text-fg">Personas</h1>
          <p className="text-14 text-fg-secondary">Who you talk with and who does the work</p>
        </div>
        {canAdd && (
          <Button variant="primary" onClick={onNew}>
            <Icon name="plus" size={14} /> New persona
          </Button>
        )}
      </header>
      <Segmented
        label="Show personas"
        value={filter}
        onChange={setFilter}
        options={FILTERS.map((f) => ({ value: f.value, label: `${f.label} ${count(f.value)}` }))}
      />
      {personas.length === 0 ? (
        <EmptyState icon="agents" title="No personas yet">
          The built-in Assistant is your default.
        </EmptyState>
      ) : rows.length === 0 ? (
        <EmptyState icon="agents" title="No personas here" />
      ) : (
        <table className="w-full table-fixed border-collapse text-13">
          <thead>
            <tr className="border-b border-border-subtle text-left text-11 uppercase tracking-wide text-fg-tertiary">
              <th className="w-[38%] py-2 font-medium">Persona</th>
              <th className="w-[26%] py-2 font-medium">Does</th>
              <th className="w-[18%] py-2 font-medium max-md:hidden">Runs on</th>
              <th className="w-[18%] py-2 font-medium">Now</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((p) => {
              const ticket = live.get(p.id);
              const working = workOf(p) !== "none";
              return (
                <tr key={p.id} data-testid="persona-list-row" className="cursor-pointer border-b border-border-subtle hover:bg-hover" onClick={() => onOpen(p.id)}>
                  <td className="py-2 pr-2">
                    <button type="button" onClick={(e) => { e.stopPropagation(); onOpen(p.id); }} className="flex min-w-0 items-center gap-2.5 text-left">
                      <PersonaAvatar persona={p} size={28} />
                      <span className="flex min-w-0 flex-col">
                        <span className="flex items-center gap-1.5">
                          <PersonaName persona={p} className="truncate font-medium" />
                          {p.is_default && <DefaultBadge small />}
                        </span>
                        <span className="truncate text-11 text-fg-tertiary">
                          {p.handle && working ? `@${p.handle}` : ""}
                          {p.in_chat_list === false ? `${p.handle && working ? " · " : ""}not in chat list` : ""}
                        </span>
                      </span>
                    </button>
                  </td>
                  <td className={cx("truncate py-2 pr-2", workOf(p) === "tickets" ? "text-accent" : workOf(p) === "helper" ? "text-pill-review-fg" : "text-fg-secondary")}>{does(p)}</td>
                  <td className="truncate py-2 pr-2 font-mono text-12 text-fg-secondary max-md:hidden">{working ? p.work_model : ""}</td>
                  <td className="py-2">
                    {ticket ? (
                      <Link href={`/tickets/${ticket}`} onClick={(e) => e.stopPropagation()} className="font-mono text-12 text-pill-done-fg hover:underline">
                        ● {ticket}
                      </Link>
                    ) : working && p.work_status ? (
                      <AgentStatus status={p.work_status} />
                    ) : (
                      <span className="text-12 text-fg-tertiary">—</span>
                    )}
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
      <p className="text-12 text-fg-tertiary">
        A persona that takes tickets can be assigned and started; one that helps on runs is handed parts of other personas&rsquo; work. Open one to change what it does.
      </p>
    </section>
  );
}
