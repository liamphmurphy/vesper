"use client";

import Link from "next/link";
import { useMemo, useState } from "react";
import { useBootstrap } from "@/lib/api/hooks";
import { useConnectors, useDeleteScheduledTask, useRunScheduledTask, useSaveScheduledTask, useScheduledTasks, type ScheduledTask, type ScheduledTaskInput } from "@/lib/api/connector-hooks";
import { useCustomApps } from "@/lib/api/custom-app-hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { useWorkflows } from "@/lib/api/workflow-hooks";
import { resolveAppIcon } from "@/lib/custom-app-bridge";
import { cx } from "@/lib/cx";
import { hoverReveal } from "@/lib/reveal";
import { useCompact } from "@/lib/viewport";
import { buildScheduledNavModel, SCHEDULED_FILTER_PICKER, SCHEDULED_NEW_ACTION } from "@/lib/native-shell/models/scheduled";
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
  return { revision: t.revision, name: t.name, kind: t.kind, instructions: t.instructions, workflow_id: t.workflow_id, persona_id: t.persona_id, project: t.project, connector_ids: t.connector_ids, custom_app_slug: t.custom_app_slug, custom_app_tool: t.custom_app_tool, custom_app_args: t.custom_app_args, frequency: t.frequency, weekdays: t.weekdays, month_day: t.month_day, at_time: t.at_time, timezone: t.timezone, cron: t.cron, enabled: t.enabled, max_minutes: t.max_minutes, max_cost_micros: t.max_cost_micros };
}

/** Prompts, workflows, and app tools that run on their own; results and approvals show up in Needs you. */
export function ScheduledScreen() {
  const compact = useCompact();
  const tasks = useScheduledTasks();
  const personas = usePersonas();
  const customApps = useCustomApps();
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
  return (
    <section aria-label="Scheduled tasks">
      <NavigatorPortal
        native={{
          model: buildScheduledNavModel({ all: all.map((t) => ({ id: t.id, name: t.name, enabled: t.enabled, schedule: describeSchedule(t) })), filter, open }),
          onCommand: (cmd) => {
            if (cmd.type === "nav.action" && cmd.actionId === SCHEDULED_NEW_ACTION) setOpen("new");
            else if (cmd.type === "nav.activate") setOpen(cmd.itemId);
            else if (cmd.type === "nav.picker" && cmd.pickerId === SCHEDULED_FILTER_PICKER) setFilter(cmd.value as typeof filter);
          },
        }}
      />
      <TopBar crumbs={[{ label: "Scheduled" }]} />
      <Content>
        <div className="flex gap-6 max-xl:flex-col">
          <div className="flex min-w-0 flex-1 flex-col gap-6">
            <PageHeader
              title="Scheduled tasks"
              description="Prompts, workflows, and app tools that run on their own. Results and approvals show up in Needs you."
              nativeActions={[{ id: "scheduled.new", label: "New task", kind: "button", icon: "plus", showsLabel: true, accent: true, run: () => setOpen("new") }]}
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
              <EmptyState icon="clock" title={all.length ? "No tasks here" : "No scheduled tasks yet"}>{all.length ? "Nothing matches this filter." : "Run a prompt, workflow, or app tool every morning, weekday, or week. Results and approvals show up in Needs you."}</EmptyState>
            ) : (
              <ul className="overflow-hidden rounded-xl border border-border bg-surface">
                {rows.map((t) => {
                  const persona = personas.data?.personas.find((p) => p.id === t.persona_id);
                  const app = t.kind === "custom_app" ? (customApps.data?.apps ?? []).find((a) => a.slug === t.custom_app_slug) : undefined;
                  const last = t.runs[0];
                  const busy = runNow.isPending || last?.state === "running" || last?.state === "waiting";
                  const subtitle =
                    t.kind === "custom_app"
                      ? [app?.name ?? t.custom_app_slug ?? "Custom app", t.custom_app_tool, describeSchedule(t)].filter(Boolean).join(" · ")
                      : [t.kind === "workflow" ? "Workflow" : (persona?.name ?? "Default persona"), t.project, describeSchedule(t)].filter(Boolean).join(" · ");
                  return (
                    <li key={t.id} data-testid="scheduled-row" className={cx("group flex items-center gap-3 border-b border-border-row px-[18px] py-3.5 last:border-b-0", t.id === open && "bg-selected")}>
                      <button type="button" onClick={() => setOpen(t.id)} className="flex min-w-0 flex-1 items-center gap-3 text-left">
                        {t.kind === "workflow" ? (
                          <span className="grid size-8 flex-none place-items-center rounded-md border border-border-strong bg-selected text-fg-secondary"><Icon name="graph" size={14} /></span>
                        ) : t.kind === "custom_app" ? (
                          <span className="grid size-8 flex-none place-items-center rounded-md border border-border-strong bg-selected text-fg-secondary"><Icon name={resolveAppIcon(app?.icon ?? "server")} size={14} /></span>
                        ) : (
                          <PersonaAvatar persona={personaLook(persona)} size={32} />
                        )}
                        <span className="min-w-0 flex-1">
                          <span className={cx("block truncate text-14 font-semibold", t.enabled ? "text-fg" : "text-fg-secondary")}>{t.name}</span>
                          <span className="block truncate text-13 text-fg-secondary">{subtitle}</span>
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
  const customApps = useCustomApps();
  const save = useSaveScheduledTask();
  const run = useRunScheduledTask();
  const remove = useDeleteScheduledTask();
  const [draft, setDraft] = useState<Draft>(() => (task ? toDraft(task) : blank()));
  const [argsText, setArgsText] = useState(() =>
    task?.custom_app_args && Object.keys(task.custom_app_args).length > 0 ? JSON.stringify(task.custom_app_args, null, 2) : "",
  );
  const [limits, setLimits] = useState(false);
  const set = (patch: Partial<Draft>) => setDraft((d) => ({ ...d, ...patch }));
  const persona = draft.persona_id ?? personas.data?.default_persona_id;
  const available = (connectors.data?.connectors ?? []).filter((c) => persona && c.persona_ids.includes(persona));
  const published = (workflows.data?.workflows ?? []).filter((w) => w.published_version);
  const mcpApps = useMemo(
    () => (customApps.data?.apps ?? []).filter((a) => a.has_mcp_server && (a.mcp_tools?.length ?? 0) > 0),
    [customApps.data?.apps],
  );
  const selectedApp = mcpApps.find((a) => a.slug === draft.custom_app_slug);
  const selectedTools = selectedApp?.mcp_tools ?? [];
  const selectedTool = selectedTools.find((t) => t.name === draft.custom_app_tool);
  const parsedArgs = useMemo(() => {
    const trimmed = argsText.trim();
    if (!trimmed) return { value: undefined as Record<string, unknown> | undefined, error: null as string | null };
    try {
      const parsed: unknown = JSON.parse(trimmed);
      if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
        return { value: undefined, error: "Arguments must be a JSON object." };
      }
      return { value: parsed as Record<string, unknown>, error: null };
    } catch {
      return { value: undefined, error: "Enter valid JSON." };
    }
  }, [argsText]);
  const toggleDay = (d: number) => set({ weekdays: draft.weekdays.includes(d) ? draft.weekdays.filter((x) => x !== d) : [...draft.weekdays, d] });
  const toggleConnector = (id: string) => set({ connector_ids: draft.connector_ids.includes(id) ? draft.connector_ids.filter((x) => x !== id) : [...draft.connector_ids, id] });
  const submit = () => {
    const body = draft.kind === "custom_app" ? { ...draft, custom_app_args: parsedArgs.value ?? {} } : draft;
    save.mutate({ id: task?.id, body }, { onSuccess: (t) => { if (!task) onCreated(t.id); } });
  };
  const error = save.error ?? run.error ?? remove.error;
  const canSave =
    !save.isPending &&
    !!draft.name.trim() &&
    (draft.kind !== "custom_app" || (!!draft.custom_app_slug && !!draft.custom_app_tool && !parsedArgs.error));
  return (
    <aside aria-label="Task editor" data-testid="scheduled-editor" className="flex w-[520px] flex-none flex-col gap-4 rounded-xl border border-border bg-panel p-5 max-xl:w-full">
      <div className="flex items-center gap-2">
        <h2 className="min-w-0 flex-1 truncate type-title">{task ? task.name : "New task"}</h2>
        {task && <Button variant="outline" icon="play" disabled={run.isPending || task.runs[0]?.state === "running" || task.runs[0]?.state === "waiting"} onClick={() => run.mutate(task.id)}>Run now</Button>}
        <IconButton icon="x" label="Close editor" onClick={onClose} />
      </div>
      <Field label="Name" htmlFor="task-name"><TextInput id="task-name" value={draft.name} maxLength={120} onChange={(e) => set({ name: e.target.value })} /></Field>
      <Field label="What runs">
        <Segmented
          label="What runs"
          value={draft.kind}
          onChange={(kind) => {
            if (kind === "custom_app" && !draft.custom_app_slug && mcpApps.length > 0) {
              set({ kind, custom_app_slug: mcpApps[0].slug, custom_app_tool: mcpApps[0].mcp_tools?.[0]?.name ?? "" });
            } else {
              set({ kind });
            }
          }}
          options={[{ value: "prompt", label: "Prompt" }, { value: "workflow", label: "Workflow" }, { value: "custom_app", label: "App tool" }]}
        />
      </Field>
      {draft.kind === "prompt" ? (
        <Field label="Instructions" htmlFor="task-instructions"><TextArea id="task-instructions" rows={4} value={draft.instructions} onChange={(e) => set({ instructions: e.target.value })} /></Field>
      ) : draft.kind === "workflow" ? (
        <Field label="Workflow" htmlFor="task-workflow">
          <select id="task-workflow" className={selectClass} value={draft.workflow_id ?? ""} onChange={(e) => set({ workflow_id: e.target.value || undefined })}>
            <option value="">Choose a published workflow</option>
            {published.map((w) => <option key={w.id} value={w.id}>{w.name}</option>)}
          </select>
        </Field>
      ) : (
        <div className="flex flex-col gap-3">
          {mcpApps.length === 0 ? (
            <p className="text-12 text-fg-tertiary">No Custom Apps with MCP tools yet. Add a <span className="font-mono">server.ts</span> to a Custom App first.</p>
          ) : (
            <>
              <div className="grid grid-cols-2 gap-3">
                <Field label="Custom App" htmlFor="task-custom-app">
                  <select
                    id="task-custom-app"
                    className={selectClass}
                    value={draft.custom_app_slug ?? ""}
                    onChange={(e) => {
                      const nextSlug = e.target.value;
                      const nextApp = mcpApps.find((a) => a.slug === nextSlug);
                      set({ custom_app_slug: nextSlug || undefined, custom_app_tool: nextApp?.mcp_tools?.[0]?.name ?? "" });
                    }}
                  >
                    <option value="">Choose an app</option>
                    {mcpApps.map((a) => <option key={a.slug} value={a.slug}>{a.name}</option>)}
                  </select>
                </Field>
                <Field label="Tool" htmlFor="task-custom-app-tool">
                  <select
                    id="task-custom-app-tool"
                    className={selectClass}
                    value={draft.custom_app_tool ?? ""}
                    disabled={!selectedApp}
                    onChange={(e) => set({ custom_app_tool: e.target.value || undefined })}
                  >
                    <option value="">Choose a tool</option>
                    {selectedTools.map((t) => <option key={t.name} value={t.name}>{t.name}</option>)}
                  </select>
                </Field>
              </div>
              {selectedTool?.description && <p className="text-12 text-fg-tertiary">{selectedTool.description}</p>}
              <Field label="Arguments (optional JSON)" htmlFor="task-custom-app-args">
                <TextArea id="task-custom-app-args" mono rows={3} placeholder="{}" value={argsText} onChange={(e) => setArgsText(e.target.value)} />
                {parsedArgs.error && <p className="text-12 text-pill-blocked-fg">{parsedArgs.error}</p>}
              </Field>
            </>
          )}
        </div>
      )}
      {draft.kind !== "custom_app" && (
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
      )}
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
            <p className="text-12 text-fg-tertiary">This persona has no connectors. <Link className="text-accent hover:underline" href="/settings?section=connectors">Manage connectors</Link></p>
          )}
        </Field>
      )}
      <div className="flex flex-col gap-2 rounded-xl border border-border bg-surface px-[18px] py-3.5">
        <div className="flex items-start justify-between gap-3">
          <div>
            <p className="text-13 text-fg-2">
              {draft.kind === "custom_app"
                ? "Runs your app’s MCP tool directly without an LLM turn. Failures show up in Needs you; allow required capabilities in the app’s Permissions tab."
                : "Approvals and attention items show up in Needs you."}
            </p>
            <p className="text-12 text-fg-tertiary">
              {draft.kind === "custom_app"
                ? `Stops after ${draft.max_minutes} minutes.`
                : `Stops after ${draft.max_minutes} minutes or ${moneyLabel(draft.max_cost_micros)}, whichever comes first.`}
            </p>
          </div>
          <button type="button" className="flex-none text-12 text-accent hover:underline" aria-expanded={limits} onClick={() => setLimits((v) => !v)}>Edit limits</button>
        </div>
        {limits && (
          <div className={cx("grid gap-3", draft.kind === "custom_app" ? "grid-cols-1" : "grid-cols-2")}>
            <Field label="Minutes" htmlFor="task-minutes"><TextInput id="task-minutes" type="number" min={1} max={240} value={draft.max_minutes} onChange={(e) => set({ max_minutes: Number(e.target.value) })} /></Field>
            {draft.kind !== "custom_app" && (
              <Field label="Cost limit ($)" htmlFor="task-cost"><TextInput id="task-cost" type="number" min={0.01} step={0.01} value={draft.max_cost_micros / 1_000_000} onChange={(e) => set({ max_cost_micros: Math.round(Number(e.target.value) * 1_000_000) })} /></Field>
            )}
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
          <Button variant="primary" disabled={!canSave} onClick={submit}>Save</Button>
        </div>
      </div>
    </aside>
  );
}
