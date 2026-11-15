"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { useBootstrap } from "@/lib/api/hooks";
import { useConnectors, useDeleteScheduledTask, useRunScheduledTask, useSaveScheduledTask, useScheduledTasks, type ScheduledTask, type ScheduledTaskInput } from "@/lib/api/connector-hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { useWorkflows } from "@/lib/api/workflow-hooks";
import { cx } from "@/lib/cx";
import { hoverReveal } from "@/lib/reveal";
import { useCompact } from "@/lib/viewport";
import { describeSchedule, moneyLabel, RUN_LABEL } from "@/lib/schedule-ui";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { Content, TopBar } from "@/components/shell/topbar";
import { Button, IconButton } from "@/components/ui/button";
import { Segmented, Toggle } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, Field, Skeleton, TextArea, TextInput } from "@/components/ui/primitives";
import { PersonaAvatar, personaLook } from "../chat/_components/persona";
import { confirmAction } from "@/components/ui/confirm";
import { PageHeader } from "@/components/ui/page-header";

const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");
const selectClass = "h-[30px] w-full rounded-md border border-border-strong bg-surface px-2 text-13 text-fg focus:border-accent focus:outline-none";
const DAY_LETTERS = [[1, "M"], [2, "T"], [3, "W"], [4, "T"], [5, "F"], [6, "S"], [0, "S"]] as const;
const PILL: Record<string, string> = {
  done: "bg-pill-done-bg text-pill-done-fg",
  human: "bg-pill-human-bg text-pill-human-fg",
  blocked: "bg-pill-blocked-bg text-pill-blocked-fg",
  neutral: "bg-pill-neutral-bg text-pill-neutral-fg",
};

const when = (iso: string) => new Date(iso).toLocaleString(undefined, { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });

function RunPill({ state }: { state: string }) {
  const r = RUN_LABEL[state];
  return <span className={cx("flex-none rounded-full px-2.5 py-0.5 text-11", PILL[r.tone])}>{r.label}</span>;
}

type Draft = ScheduledTaskInput & { weekdays: number[]; connector_ids: string[]; month_day: number; cron: string; instructions: string; max_minutes: number; max_cost_micros: number };

function blank(): Draft {
  return { name: "", kind: "prompt", instructions: "", connector_ids: [], frequency: "weekly", weekdays: [1], month_day: 1, at_time: "08:00", timezone: Intl.DateTimeFormat().resolvedOptions().timeZone, cron: "", enabled: true, max_minutes: 15, max_cost_micros: 1_000_000 };
}

function toDraft(t: ScheduledTask): Draft {
  return { revision: t.revision, name: t.name, kind: t.kind, instructions: t.instructions, workflow_id: t.workflow_id, persona_id: t.persona_id, project: t.project, connector_ids: t.connector_ids, frequency: t.frequency, weekdays: t.weekdays, month_day: t.month_day, at_time: t.at_time, timezone: t.timezone, cron: t.cron, enabled: t.enabled, max_minutes: t.max_minutes, max_cost_micros: t.max_cost_micros };
}

/** Prompts and workflows that run on their own; results and approvals show up in Needs you. */
export function ScheduledScreen() {
  const compact = useCompact();
  const tasks = useScheduledTasks();
  const personas = usePersonas();
  const save = useSaveScheduledTask();
  const runNow = useRunScheduledTask();
  const [filter, setFilter] = useState<"all" | "active" | "paused">("all");
  const [open, setOpen] = useState<string | "new" | null>(null);
  const localTz = useMemo(() => Intl.DateTimeFormat().resolvedOptions().timeZone, []);
  const all = tasks.data?.tasks ?? [];
  const rows = all.filter((t) => filter === "all" || t.enabled === (filter === "active"));
  const selected = all.find((t) => t.id === open);
  const count = (on: boolean) => all.filter((t) => t.enabled === on).length;
  const setEnabled = (t: ScheduledTask, enabled: boolean) => save.mutate({ id: t.id, body: { ...toDraft(t), enabled } });
  const listError = save.error ?? runNow.error;
  const filterOptions = [
    { value: "all" as const, label: "All", n: all.length },
    { value: "active" as const, label: "Active", n: count(true) },
    { value: "paused" as const, label: "Paused", n: count(false) },
  ];
  return (
    <section aria-label="Scheduled tasks">
      {!compact && (
        <NavigatorPortal>
          <nav aria-label="Scheduled tasks" className="flex min-h-0 flex-1 flex-col gap-3 px-2.5 pt-4 pb-3">
            <div className="flex items-center justify-between px-1.5">
              <h2 className="text-16 font-semibold text-fg">Scheduled</h2>
              <IconButton icon="plus" label="Create scheduled task" size={26} onClick={() => setOpen("new")} />
            </div>
            <div role="tablist" aria-label="Filter scheduled tasks" className="flex gap-0.5 rounded-md bg-surface-sunken p-0.5">
              {filterOptions.map((o) => {
                const on = filter === o.value;
                return (
                  <button
                    key={o.value}
                    type="button"
                    role="tab"
                    aria-selected={on}
                    onClick={() => setFilter(o.value)}
                    className={cx(
                      "flex-1 rounded-[5px] px-2 py-1 text-12 transition-colors",
                      on ? "bg-surface font-medium text-fg" : "text-fg-secondary hover:text-fg",
                    )}
                  >
                    {o.label} <span className="text-11 text-fg-tertiary">{o.n}</span>
                  </button>
                );
              })}
            </div>
            <div className="min-h-0 flex-1 space-y-0.5 overflow-y-auto">
              {rows.map((t) => {
                const active = t.id === open;
                return (
                  <button
                    key={t.id}
                    type="button"
                    aria-current={active ? "true" : undefined}
                    onClick={() => setOpen(t.id)}
                    className={cx(
                      "flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left transition-colors",
                      active ? "bg-selected text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg",
                    )}
                  >
                    <span className={cx("size-1.5 flex-none rounded-full", t.enabled ? "bg-state-done" : "bg-state-backlog")} />
                    <span className="min-w-0 flex-1">
                      <span className="block truncate text-13 font-medium">{t.name}</span>
                      <span className="block truncate text-11 text-fg-tertiary">{describeSchedule(t)}</span>
                    </span>
                  </button>
                );
              })}
            </div>
          </nav>
        </NavigatorPortal>
      )}
      <TopBar crumbs={[{ label: "Scheduled" }]} />
      <Content>
        <div className="flex gap-6 max-xl:flex-col">
          <div className="flex min-w-0 flex-1 flex-col gap-6">
            <PageHeader
              title="Scheduled tasks"
              description="Prompts and workflows that run on their own. Results and approvals show up in Needs you."
              actions={<Button variant="primary" icon="plus" onClick={() => setOpen("new")}>New task</Button>}
            />
            {compact && (
              <Segmented label="Show tasks" value={filter} onChange={setFilter} small options={[{ value: "all", label: `All ${all.length}` }, { value: "active", label: `Active ${count(true)}` }, { value: "paused", label: `Paused ${count(false)}` }]} />
            )}
            {listError && <p role="alert" className="text-13 text-pill-blocked-fg">{errorText(listError)}</p>}
            {tasks.isError ? (
              <Banner tone="blocked" title="Couldn’t load tasks">{errorText(tasks.error)}</Banner>
            ) : !tasks.data ? (
              <Skeleton className="h-48" />
            ) : rows.length === 0 ? (
              <EmptyState icon="clock" title={all.length ? "No tasks here" : "No scheduled tasks yet"}>{all.length ? "Nothing matches this filter." : "Run a prompt or workflow every morning, weekday, or week. Results and approvals show up in Needs you."}</EmptyState>
            ) : (
              <ul className="overflow-hidden rounded-xl border border-border bg-surface">
                {rows.map((t) => {
                  const persona = personas.data?.personas.find((p) => p.id === t.persona_id);
                  const last = t.runs[0];
                  const busy = runNow.isPending || last?.state === "running" || last?.state === "waiting";
                  return (
                    <li key={t.id} data-testid="scheduled-row" className={cx("group flex items-center gap-3 border-b border-border-row px-[18px] py-3.5 last:border-b-0", t.id === open && "bg-selected")}>
                      <button type="button" onClick={() => setOpen(t.id)} className="flex min-w-0 flex-1 items-center gap-3 text-left">
                        {t.kind === "workflow" ? <span className="grid size-8 flex-none place-items-center rounded-md border border-border-strong bg-selected text-fg-secondary"><Icon name="graph" size={14} /></span> : <PersonaAvatar persona={personaLook(persona)} size={32} />}
                        <span className="min-w-0 flex-1">
                          <span className={cx("block truncate text-14 font-semibold", t.enabled ? "text-fg" : "text-fg-secondary")}>{t.name}</span>
                          <span className="block truncate text-13 text-fg-secondary">{[t.kind === "workflow" ? "Workflow" : (persona?.name ?? "Default persona"), t.project, describeSchedule(t)].filter(Boolean).join(" · ")}</span>
                        </span>
                        <span className="w-52 flex-none text-right max-sm:hidden">
                          <span className="block text-12 text-fg-tertiary">Next run</span>
                          <span className="flex items-center justify-end gap-1.5 text-13 text-fg-2">
                            <span className="whitespace-nowrap">{t.enabled && t.next_run_at ? when(t.next_run_at) : "Paused"}</span>
                            {t.enabled && t.timezone && t.timezone !== localTz && (
                              <span className="rounded bg-selected px-1.5 py-px font-mono text-10 text-fg-tertiary" title={`Schedule timezone: ${t.timezone}`}>
                                {t.timezone}
                              </span>
                            )}
                          </span>
                        </span>
                      </button>
                      <span className="w-20 flex-none text-right">{last && <RunPill state={last.state} />}</span>
                      <IconButton
                        icon="play"
                        size={26}
                        label={`Run ${t.name} now`}
                        disabled={busy}
                        onClick={() => runNow.mutate(t.id)}
                        className={cx(hoverReveal(), "focus-visible:opacity-100")}
                      />
                      <Toggle label={`Enable ${t.name}`} srOnlyLabel checked={t.enabled} disabled={save.isPending} onChange={(v) => setEnabled(t, v)} />
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
          {open && (open === "new" || selected) && <Editor key={open === "new" ? "new" : `${selected!.id}:${selected!.revision}`} task={selected} onClose={() => setOpen(null)} onCreated={setOpen} />}
        </div>
      </Content>
    </section>
  );
}

function Editor({ task, onClose, onCreated }: { task?: ScheduledTask; onClose: () => void; onCreated: (id: string) => void }) {
  const boot = useBootstrap();
  const personas = usePersonas();
  const workflows = useWorkflows();
  const connectors = useConnectors();
  const save = useSaveScheduledTask();
  const run = useRunScheduledTask();
  const remove = useDeleteScheduledTask();
  const [draft, setDraft] = useState<Draft>(() => (task ? toDraft(task) : blank()));
  const [limits, setLimits] = useState(false);
  const set = (patch: Partial<Draft>) => setDraft((d) => ({ ...d, ...patch }));
  const persona = draft.persona_id ?? personas.data?.default_persona_id;
  const available = (connectors.data?.connectors ?? []).filter((c) => persona && c.persona_ids.includes(persona));
  const published = (workflows.data?.workflows ?? []).filter((w) => w.published_version);
  const toggleDay = (d: number) => set({ weekdays: draft.weekdays.includes(d) ? draft.weekdays.filter((x) => x !== d) : [...draft.weekdays, d] });
  const toggleConnector = (id: string) => set({ connector_ids: draft.connector_ids.includes(id) ? draft.connector_ids.filter((x) => x !== id) : [...draft.connector_ids, id] });
  const submit = () => save.mutate({ id: task?.id, body: draft }, { onSuccess: (t) => { if (!task) onCreated(t.id); } });
  const error = save.error ?? run.error ?? remove.error;
  return (
    <aside aria-label="Task editor" data-testid="scheduled-editor" className="flex w-[520px] flex-none flex-col gap-4 rounded-xl border border-border bg-panel p-5 max-xl:w-full">
      <div className="flex items-center gap-2">
        <h2 className="min-w-0 flex-1 truncate type-title">{task ? task.name : "New task"}</h2>
        {task && <Button variant="outline" icon="play" disabled={run.isPending || task.runs[0]?.state === "running" || task.runs[0]?.state === "waiting"} onClick={() => run.mutate(task.id)}>Run now</Button>}
        <IconButton icon="x" label="Close editor" onClick={onClose} />
      </div>
      <Field label="Name" htmlFor="task-name"><TextInput id="task-name" value={draft.name} maxLength={120} onChange={(e) => set({ name: e.target.value })} /></Field>
      <Field label="What runs"><Segmented label="What runs" value={draft.kind} onChange={(kind) => set({ kind })} options={[{ value: "prompt", label: "Prompt" }, { value: "workflow", label: "Workflow" }]} /></Field>
      {draft.kind === "prompt" ? (
        <Field label="Instructions" htmlFor="task-instructions"><TextArea id="task-instructions" rows={4} value={draft.instructions} onChange={(e) => set({ instructions: e.target.value })} /></Field>
      ) : (
        <Field label="Workflow" htmlFor="task-workflow">
          <select id="task-workflow" className={selectClass} value={draft.workflow_id ?? ""} onChange={(e) => set({ workflow_id: e.target.value || undefined })}>
            <option value="">Choose a published workflow</option>
            {published.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select>
        </Field>
      )}
      <div className="grid grid-cols-2 gap-3">
        <Field label="Run as" htmlFor="task-persona">
          <select id="task-persona" className={selectClass} value={draft.persona_id ?? ""} onChange={(e) => set({ persona_id: e.target.value || undefined, connector_ids: [] })}>
            <option value="">Default persona</option>
            {personas.data?.personas.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        </Field>
        <Field label="Default space" htmlFor="task-project">
          <select id="task-project" className={selectClass} value={draft.project ?? ""} onChange={(e) => set({ project: e.target.value || undefined })}>
            <option value="">No default</option>
            {boot.data?.projects.filter((p) => !p.archived).map((p) => <option key={p.key} value={p.key}>{p.name}</option>)}
          </select>
        </Field>
      </div>
      <Field label="Schedule">
        <div className="flex flex-col gap-2.5">
          <Segmented label="Frequency" value={draft.frequency} onChange={(frequency) => set({ frequency })} options={[{ value: "daily", label: "Daily" }, { value: "weekly", label: "Weekly" }, { value: "monthly", label: "Monthly" }, { value: "cron", label: "Cron" }]} />
          {draft.frequency === "weekly" && (
            <div role="group" aria-label="Days" className="flex gap-1.5">
              {DAY_LETTERS.map(([d, letter]) => (
                <button key={d} type="button" aria-pressed={draft.weekdays.includes(d)} aria-label={["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"][d]} onClick={() => toggleDay(d)} className={cx("size-8 rounded-full border text-12", draft.weekdays.includes(d) ? "border-accent bg-accent font-semibold text-on-accent" : "border-border-strong bg-surface text-fg-secondary hover:bg-hover")}>{letter}</button>
              ))}
            </div>
          )}
          {draft.frequency === "cron" ? (
            <TextInput mono aria-label="Cron expression" placeholder="0 9 * * 1-5" value={draft.cron} onChange={(e) => set({ cron: e.target.value })} />
          ) : (
            <div className="flex items-center gap-2">
              {draft.frequency === "monthly" && <TextInput type="number" aria-label="Day of the month" min={1} max={31} className="w-20" value={draft.month_day} onChange={(e) => set({ month_day: Number(e.target.value) })} />}
              <TextInput type="time" aria-label="Time" className="w-32" value={draft.at_time} onChange={(e) => set({ at_time: e.target.value })} />
            </div>
          )}
          <TextInput aria-label="Time zone" value={draft.timezone} onChange={(e) => set({ timezone: e.target.value })} />
          {task?.upcoming.length ? <p className="text-12 text-fg-tertiary">Next: {task.upcoming.map(when).join(" and ")}</p> : null}
        </div>
      </Field>
      {draft.kind === "prompt" && (
        <Field label="Connectors for this task">
          {available.length ? (
            <div className="flex flex-wrap gap-2">
              {available.map((c) => {
                const on = draft.connector_ids.includes(c.id);
                return <button key={c.id} type="button" aria-pressed={on} onClick={() => toggleConnector(c.id)} className={cx("rounded-full border px-3 py-1 text-12", on ? "border-accent bg-accent-soft text-fg" : "border-border-strong bg-surface text-fg-secondary hover:bg-hover")}>{c.name}</button>;
              })}
            </div>
          ) : (
            <p className="text-12 text-fg-tertiary">This persona has no connectors. <Link className="text-accent hover:underline" href="/customization?who=connectors">Manage connectors</Link></p>
          )}
        </Field>
      )}
      <div className="flex flex-col gap-2 rounded-xl border border-border bg-surface px-[18px] py-3.5">
        <div className="flex items-start justify-between gap-3">
          <div>
            <p className="text-13 text-fg-2">Approvals and attention items show up in Needs you.</p>
            <p className="text-12 text-fg-tertiary">Stops after {draft.max_minutes} minutes or {moneyLabel(draft.max_cost_micros)}, whichever comes first.</p>
          </div>
          <button type="button" className="flex-none text-12 text-accent hover:underline" aria-expanded={limits} onClick={() => setLimits((v) => !v)}>Edit limits</button>
        </div>
        {limits && (
          <div className="grid grid-cols-2 gap-3">
            <Field label="Minutes" htmlFor="task-minutes"><TextInput id="task-minutes" type="number" min={1} max={240} value={draft.max_minutes} onChange={(e) => set({ max_minutes: Number(e.target.value) })} /></Field>
            <Field label="Cost limit ($)" htmlFor="task-cost"><TextInput id="task-cost" type="number" min={0.01} step={0.01} value={draft.max_cost_micros / 1_000_000} onChange={(e) => set({ max_cost_micros: Math.round(Number(e.target.value) * 1_000_000) })} /></Field>
          </div>
        )}
      </div>
      {task && task.runs.length > 0 && (
        <section className="flex flex-col gap-2">
          <h3 className="type-heading">Recent runs</h3>
          <ul className="overflow-hidden rounded-xl border border-border bg-surface">
            {task.runs.map((r) => (
              <li key={r.id} data-testid="scheduled-run" className="flex items-center gap-3 border-b border-border-row px-3 py-2 last:border-b-0">
                <RunPill state={r.state} />
                <span className="flex-1 truncate text-13 text-fg-2">{when(r.started_at)}{r.trigger === "catchup" && " (catch-up)"}</span>
                <span className="max-w-40 truncate text-12 text-fg-tertiary" title={r.error}>{r.error || (r.cost_micros ? moneyLabel(r.cost_micros) : "")}</span>
                {r.href && <Link className="text-12 text-accent hover:underline" href={r.href}>Open</Link>}
              </li>
            ))}
          </ul>
        </section>
      )}
      {error && <p role="alert" className="text-13 text-pill-blocked-fg">{errorText(error)}</p>}
      <div className="flex items-center justify-between border-t border-border-subtle pt-3">
        {task ? <button type="button" className="text-13 text-pill-blocked-fg hover:underline" onClick={async () => { if (await confirmAction({ title: `Delete ${task.name}?`, body: "It won't run again.", confirmLabel: "Delete task" })) remove.mutate(task.id, { onSuccess: onClose }); }}>Delete task</button> : <span />}
        <div className="flex gap-2">
          <Button variant="outline" onClick={onClose}>Cancel</Button>
          <Button variant="primary" disabled={save.isPending || !draft.name.trim()} onClick={submit}>Save</Button>
        </div>
      </div>
    </aside>
  );
}
