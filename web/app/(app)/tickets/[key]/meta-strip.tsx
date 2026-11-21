"use client";

import { useState, type ReactNode } from "react";
import type { Bootstrap, Ticket } from "@/lib/api/client";
import { Icon } from "@/components/ui/icon";
import { Sheet, SheetOptions } from "@/components/ui/sheet";
import { UnassignedAvatar } from "@/components/domain/avatars";
import { WorkPersonaAvatar } from "@/components/domain/work-persona-avatar";
import { PriorityGlyph, StatusGlyph } from "@/components/domain/glyphs";
import { PRIORITY_NAME, PRIORITY_ORDER, STATUS_NAME, STATUS_ORDER } from "@/components/domain/meta";
import { pickerName } from "@/components/domain/pickers";
import type { SaveTicket } from "./ticket-save";

type Field = "status" | "agent" | "priority" | "epic";
const TITLE: Record<Field, string> = { status: "Status", agent: "Persona", priority: "Priority", epic: "Epic" };

function Chip({ label, value, onOpen, children }: { label: string; value: string | null; onOpen: () => void; children: ReactNode }) {
  return (
    <button
      type="button"
      aria-haspopup="dialog"
      aria-label={pickerName(label, value)}
      onClick={onOpen}
      className="inline-flex h-[36px] max-w-full flex-none items-center gap-1.5 rounded-full border border-border-strong bg-surface px-3 text-13 text-fg-2 active:bg-hover"
    >
      {children}
    </button>
  );
}

/**
 * Compact ticket detail (DESIGN.md §3 Responsive): status, agent, priority and epic as a strip of
 * chips under the title. Each opens its picker as a bottom sheet; choosing saves and closes it.
 */
export function MetaStrip({ t, boot, save }: { t: Ticket; boot: Bootstrap; save: SaveTicket }) {
  // The field outlives the sheet's open state, so the sheet keeps its content while it slides away.
  const [field, setField] = useState<Field>("status");
  const [shown, setShown] = useState(false);
  const setOpen = (f: Field) => { setField(f); setShown(true); };
  const agents = boot.agents.filter((a) => a.kind === "main");
  const epics = boot.epics.filter((e) => e.project_id === t.project.id);
  const close = () => setShown(false);
  return (
    <>
      <div role="group" aria-label="Properties" className="flex flex-wrap gap-2">
        <Chip label="Status" value={STATUS_NAME[t.status]} onOpen={() => setOpen("status")}>
          <StatusGlyph state={t.status} size={12} label={false} />
          {STATUS_NAME[t.status]}
        </Chip>
        <Chip label="Persona" value={t.assignee?.name ?? null} onOpen={() => setOpen("agent")}>
          {t.assignee ? <WorkPersonaAvatar agent={t.assignee} size="sm" /> : <UnassignedAvatar size={16} />}
          <span className="truncate">{t.assignee?.name ?? "Unassigned"}</span>
        </Chip>
        <Chip label="Priority" value={PRIORITY_NAME[t.priority]} onOpen={() => setOpen("priority")}>
          <PriorityGlyph priority={t.priority} label={false} />
          {PRIORITY_NAME[t.priority]}
        </Chip>
        <Chip label="Epic" value={t.epic?.name ?? null} onOpen={() => setOpen("epic")}>
          <Icon name="epics" size={13} className="flex-none text-fg-tertiary" />
          <span className="truncate">{t.epic?.name ?? "No epic"}</span>
        </Chip>
      </div>
      <Sheet open={shown} onOpenChange={(o) => !o && close()} title={TITLE[field]}>
        {field === "status" && (
          <SheetOptions
            label="Status"
            value={t.status}
            options={STATUS_ORDER.map((s) => ({ value: s, label: STATUS_NAME[s], icon: <StatusGlyph state={s} surface="var(--surface-raised)" label={false} /> }))}
            onPick={(status) => {
              close();
              if (status !== t.status) save({ status }, `Status → ${STATUS_NAME[status]}`);
            }}
          />
        )}
        {field === "agent" && (
          <>
            <SheetOptions
              label="Personas"
              value={t.assignee?.id ?? ""}
              options={[
                ...agents.map((a) => ({ value: a.id, label: a.name, detail: `${a.model} · ${a.specialty}`, icon: <WorkPersonaAvatar agent={a} size="md" /> })),
                { value: "", label: "Unassigned", icon: <UnassignedAvatar size={24} /> },
              ]}
              onPick={(id) => {
                close();
                if (id !== (t.assignee?.id ?? "")) save({ assignee_agent_id: id || null }, `Persona → ${agents.find((a) => a.id === id)?.name ?? "Unassigned"}`);
              }}
            />
            <p className="px-3 pt-2 text-12 text-fg-tertiary">Personas that take tickets. Assigning queues the ticket; a person starts the run.</p>
          </>
        )}
        {field === "priority" && (
          <SheetOptions
            label="Priority"
            value={t.priority}
            options={PRIORITY_ORDER.map((p) => ({ value: p, label: PRIORITY_NAME[p], icon: <PriorityGlyph priority={p} label={false} /> }))}
            onPick={(priority) => {
              close();
              if (priority !== t.priority) save({ priority }, `Priority → ${PRIORITY_NAME[priority]}`);
            }}
          />
        )}
        {field === "epic" && (
          <SheetOptions
            label="Epics"
            value={t.epic?.id ?? ""}
            options={[
              ...epics.map((e) => ({ value: e.id, label: e.name, icon: <Icon name="epics" size={14} className="text-fg-tertiary" /> })),
              { value: "", label: "No epic", icon: <Icon name="epics" size={14} className="text-fg-tertiary opacity-40" /> },
            ]}
            onPick={(id) => {
              close();
              if (id !== (t.epic?.id ?? "")) save({ epic_id: id || null }, `Epic → ${epics.find((e) => e.id === id)?.name ?? "none"}`);
            }}
          />
        )}
      </Sheet>
    </>
  );
}
