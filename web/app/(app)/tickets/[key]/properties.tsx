"use client";

import { useState, type ComponentProps, type ReactNode } from "react";
import type { Bootstrap, Ticket } from "@/lib/api/client";
import { cx } from "@/lib/cx";
import { absoluteTime, ago, dueDate } from "@/lib/format";
import { Toggle } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { HumanAvatar, UnassignedAvatar } from "@/components/domain/avatars";
import { AgentOrPersonaAvatar } from "../_components/ticket-row";
import { PriorityGlyph, StatusGlyph } from "@/components/domain/glyphs";
import { Flag, LabelChip } from "@/components/domain/labels";
import { PRFeedbackStrip } from "@/components/domain/pr-feedback-strip";
import { useAddressTicketPRFeedback } from "@/lib/api/hooks";
import { needsDispatch } from "./run-parts";
import { PRIORITY_NAME, STATUS_NAME } from "@/components/domain/meta";
import { AgentPicker, EpicMenu, EstimatePicker, LabelPicker, PriorityMenu, StatusMenu, UserMenu } from "@/components/domain/pickers";
import { ESTIMATE_SCALE } from "@/lib/ticket-draft";
import type { SaveTicket } from "./ticket-save";

/**
 * Property row as a button (DESIGN.md §4): the whole row is the hit target.
 * Spreads props so Radix triggers (asChild) can attach handlers and refs.
 */
function PropButton({ label, children, className, ...rest }: { label: string; children: ReactNode } & ComponentProps<"button">) {
  return (
    <button
      type="button"
      className={cx("flex min-h-[34px] w-full items-center gap-2.5 rounded-md px-2 text-left hover:bg-hover", className)}
      {...rest}
    >
      <span className="w-[88px] flex-none text-13 text-fg-tertiary">{label}</span>
      <span className="flex min-w-0 flex-1 flex-wrap items-center gap-2 text-13 text-fg">{children}</span>
    </button>
  );
}

function Empty({ children }: { children: ReactNode }) {
  return <span className="text-fg-tertiary">{children}</span>;
}

/** Inline editor for short free-text and date properties. */
function InlineProp({
  label,
  value,
  display,
  type = "text",
  placeholder,
  onSave,
}: {
  label: string;
  value: string;
  display: ReactNode;
  type?: "text" | "date";
  placeholder: string;
  onSave: (v: string | null) => void;
}) {
  const [editing, setEditing] = useState(false);
  if (!editing) {
    return (
      <PropButton label={label} onClick={() => setEditing(true)}>
        {display}
      </PropButton>
    );
  }
  const commit = (v: string) => {
    setEditing(false);
    if (v !== value) onSave(v.trim() ? v.trim() : null);
  };
  return (
    <div className="flex min-h-[34px] items-center gap-2.5 px-2">
      <label htmlFor={`prop-${label}`} className="w-[88px] flex-none text-13 text-fg-tertiary">
        {label}
      </label>
      <input
        id={`prop-${label}`}
        type={type}
        autoFocus
        defaultValue={value}
        placeholder={placeholder}
        onBlur={(e) => commit(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") commit(e.currentTarget.value);
          if (e.key === "Escape") setEditing(false);
        }}
        className="h-7 min-w-0 flex-1 rounded-md border border-border-strong bg-surface px-2 text-13 text-fg outline-none focus:border-accent [color-scheme:inherit]"
      />
    </div>
  );
}

/** Who set the points and when; the rationale is in the Activity timeline. */
function estimatorLine(t: Ticket, boot: Bootstrap) {
  const by = t.estimated_by;
  if (!by) return null;
  const who = by.type === "agent" ? `@${boot.agents.find((a) => a.id === by.id)?.handle ?? by.name}` : by.name;
  return (
    <span className="text-12 text-fg-tertiary">
      by {who}
      {t.estimated_at && (
        <>
          {" · "}
          <time dateTime={t.estimated_at} title={absoluteTime(t.estimated_at)}>
            {ago(t.estimated_at)}
          </time>
        </>
      )}
      {t.estimate_rationale && " · rationale in Activity"}
    </span>
  );
}

export function Properties({ t, boot, save, error }: { t: Ticket; boot: Bootstrap; save: SaveTicket; error: string | null }) {
  const epics = boot.epics.filter((e) => e.project_id === t.project.id);
  const reviewer = boot.users.find((u) => u.id === t.reviewer?.id);
  const agentName = (id: string | null) => boot.agents.find((a) => a.id === id)?.name ?? "Unassigned";
  const closed = t.status === "done" || t.status === "canceled";
  const scale: number[] = [...ESTIMATE_SCALE];
  if (t.estimate_points != null && !scale.includes(t.estimate_points)) scale.push(t.estimate_points);

  return (
    <div className="flex flex-col gap-px">
      <StatusMenu value={t.status} onChange={(status) => save({ status }, `Status → ${STATUS_NAME[status]}`)}>
        <PropButton label="Status">
          <StatusGlyph state={t.status} surface="var(--bg-panel)" label={false} />
          {STATUS_NAME[t.status]}
        </PropButton>
      </StatusMenu>
      <PriorityMenu value={t.priority} onChange={(priority) => save({ priority }, `Priority → ${PRIORITY_NAME[priority]}`)}>
        <PropButton label="Priority">
          <PriorityGlyph priority={t.priority} label={false} />
          {PRIORITY_NAME[t.priority]}
        </PropButton>
      </PriorityMenu>
      <AgentPicker agents={boot.agents.filter((a) => a.kind === "main")} value={t.assignee?.id ?? null} onChange={(id) => save({ assignee_agent_id: id }, `Persona → ${agentName(id)}`)}>
        <PropButton label="Persona">
          {t.assignee ? (
            <>
              <AgentOrPersonaAvatar agent={t.assignee} />
              {t.assignee.name}
              {needsDispatch(t) ? (
                <Flag tone="human">Not dispatched</Flag>
              ) : t.run?.state === "queued" ? (
                <Flag tone="neutral">Queued</Flag>
              ) : null}
            </>
          ) : (
            <>
              <UnassignedAvatar />
              <Empty>Unassigned</Empty>
            </>
          )}
        </PropButton>
      </AgentPicker>
      <UserMenu users={boot.users} value={t.reviewer?.id ?? null} onChange={(id) => save({ reviewer_user_id: id }, `Reviewer → ${boot.users.find((u) => u.id === id)?.name ?? "none"}`)}>
        <PropButton label="Reviewer">
          {t.reviewer ? (
            <>
              <HumanAvatar name={t.reviewer.name} initials={t.reviewer.initials} color={reviewer?.avatar_color} src={reviewer?.avatar_url} label={false} />
              {t.reviewer.name}
            </>
          ) : (
            <Empty>No reviewer</Empty>
          )}
        </PropButton>
      </UserMenu>
      <EpicMenu epics={epics} value={t.epic?.id ?? null} onChange={(id) => save({ epic_id: id }, `Epic → ${epics.find((e) => e.id === id)?.name ?? "none"}`)}>
        <PropButton label="Epic">
          {t.epic ? (
            <>
              <Icon name="epics" size={14} className="text-fg-tertiary" />
              {t.epic.name}
            </>
          ) : (
            <Empty>No epic</Empty>
          )}
        </PropButton>
      </EpicMenu>
      <div className="flex min-h-[34px] items-center gap-2.5 px-2">
        <span className="w-[88px] flex-none text-13 text-fg-tertiary">Space</span>
        <span className="flex items-center gap-2 text-13">
          <span aria-hidden className="size-2.5 rounded-[3px]" style={{ background: t.project.color }} />
          {t.project.name}
        </span>
      </div>
      <div className="flex min-h-[34px] items-center gap-2.5 px-2">
        <span className="w-[88px] flex-none text-13 text-fg-tertiary">Mockup</span>
        <span className="flex min-w-0 flex-1 flex-wrap items-center gap-2 text-13">
          {t.mockup_gate.from_epic ? (
            <span className="text-fg-secondary">Required by epic {t.epic?.name ?? ""}</span>
          ) : (
            <Toggle
              checked={t.requires_mockup}
              onChange={(v) => save({ requires_mockup: v }, v ? "Mockup → required" : "Mockup → not required")}
              label={t.requires_mockup ? "Required" : "Not required"}
            />
          )}
        </span>
      </div>
      <div className="flex min-h-[34px] items-start gap-2.5 px-2 py-1">
        <span aria-hidden className="w-[88px] flex-none pt-1.5 text-13 text-fg-tertiary">
          Estimate
        </span>
        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <div className="flex items-center gap-1.5">
            <EstimatePicker
              scale={scale}
              value={t.estimate_points}
              disabled={closed}
              onChange={(p) => save({ estimate_points: p }, `Estimate → ${p}`)}
            />
            {t.estimate_points != null && !closed && (
              <button type="button" onClick={() => save({ estimate_points: null }, "Estimate cleared")} className="rounded px-1 text-12 text-fg-tertiary hover:text-fg-secondary">
                Clear
              </button>
            )}
          </div>
          {t.estimate_points != null && estimatorLine(t, boot)}
          {closed && <span className="text-12 text-fg-tertiary">Closed tickets can’t be re-estimated.</span>}
          {t.estimate && <span className="text-12 text-fg-tertiary">Legacy note: {t.estimate}</span>}
        </div>
      </div>
      <InlineProp
        label="Due"
        type="date"
        value={t.due_date ?? ""}
        placeholder=""
        display={t.due_date ? dueDate(t.due_date) : <Empty>No due date</Empty>}
        onSave={(v) => save({ due_date: v }, v ? `Due → ${dueDate(v)}` : "Due date cleared")}
      />
      <LabelPicker labels={boot.labels} value={t.labels.map((l) => l.id)} onChange={(ids) => save({ label_ids: ids }, "Labels")}>
        <PropButton label="Labels" className="py-1.5">
          {t.labels.length ? t.labels.map((l) => <LabelChip key={l.id} name={l.name} color={l.color} />) : <Empty>Add labels</Empty>}
        </PropButton>
      </LabelPicker>
      {error && (
        <p role="alert" className="px-2 pt-2 text-12 text-pill-blocked-fg">
          {error}
        </p>
      )}
    </div>
  );
}

/** Code section: branch and PR (set by agents in Phase 4, synced from GitHub in Phase 5). */
export function CodeSection({ t }: { t: Ticket }) {
  const addressFeedback = useAddressTicketPRFeedback(t.key);
  if (!t.branch && !t.pr) return null;
  const prState = t.pr ? t.pr.state[0].toUpperCase() + t.pr.state.slice(1) : "";
  const liveRun = !!t.run && !["completed", "failed", "cancelled", "waiting"].includes(t.run.state);
  return (
    <section className="flex flex-col gap-3 px-2">
      <h2 className="text-13 text-fg-tertiary">Code</h2>
      {t.branch && (
        <div className="flex items-center gap-2.5 font-mono text-12 text-fg-2">
          <Icon name="branch" size={14} className="text-fg-tertiary" />
          <span className="truncate">{t.branch}</span>
        </div>
      )}
      {t.pr && (
        <div className="flex items-center gap-2.5 text-13">
          <Icon name="pr" size={14} className="text-fg-tertiary" />
          {t.pr.url ? (
            <a href={t.pr.url} target="_blank" rel="noreferrer noopener" className="hover:underline">
              #{t.pr.number} · {prState}
            </a>
          ) : (
            <span>
              #{t.pr.number} · {prState}
            </span>
          )}
          {t.pr.additions != null && (
            <span className="ml-auto font-mono text-12">
              <span className="text-pill-done-fg">+{t.pr.additions}</span>{" "}
              <span className="text-pill-blocked-fg">−{t.pr.deletions ?? 0}</span>
            </span>
          )}
        </div>
      )}
      {t.pr?.closed_unmerged && <Flag tone="blocked">PR closed without merging</Flag>}
      {t.pr && (
        <PRFeedbackStrip
          feedback={t.pr.feedback}
          prState={t.pr.state}
          busy={addressFeedback.isPending}
          activeMode={addressFeedback.variables}
          disabled={liveRun || t.status === "done" || t.status === "canceled"}
          error={addressFeedback.error?.message}
          onAddress={(mode) => addressFeedback.mutate(mode)}
        />
      )}
      {t.pr?.synced_at && (
        <span className="text-12 text-fg-tertiary" title={absoluteTime(t.pr.synced_at)}>
          Synced from GitHub {ago(t.pr.synced_at)}
        </span>
      )}
    </section>
  );
}
