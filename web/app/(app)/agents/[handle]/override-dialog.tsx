"use client";

import { Dialog } from "radix-ui";
import { useState } from "react";
import type { AgentDetail, AgentOverride, Harness, ScopeMode } from "@/lib/api/client";
import { useChatModels, useSetOverride } from "@/lib/api/hooks";
import { MODE_LABEL, MODE_RANK } from "@/lib/enforcement";
import { Button, IconButton } from "@/components/ui/button";
import { Segmented } from "@/components/ui/controls";
import { Field, TextArea, TextInput } from "@/components/ui/primitives";

type ScopeChoice = ScopeMode | "inherit";
type AgentService = NonNullable<AgentOverride["services"]>[number];

const SERVICES_EXAMPLE = `[{"name": "postgres", "image": "postgres:17-alpine", "user": "postgres",
  "env": {"POSTGRES_PASSWORD": "test", "PGDATA": "/var/lib/postgresql/data/pgdata"},
  "tmpfs": ["/var/lib/postgresql/data", "/var/run/postgresql"],
  "healthcheck": ["CMD", "pg_isready", "-U", "postgres"],
  "expose": {"TEST_DATABASE_URL": "postgres://postgres:test@postgres:5432/postgres?sslmode=disable"}}]`;

function parseServices(text: string): { ok: true; value: AgentService[] } | { ok: false; error: string } {
  if (!text.trim()) return { ok: true, value: [] };
  try {
    const v: unknown = JSON.parse(text);
    if (!Array.isArray(v) || !v.every((s) => s && typeof s === "object" && typeof s.name === "string" && typeof s.image === "string")) {
      return { ok: false, error: "Test services must be a JSON array of objects, each with a name and an image." };
    }
    return { ok: true, value: v as AgentService[] };
  } catch {
    return { ok: false, error: "Test services aren't valid JSON." };
  }
}

/**
 * Edit one project's override. Scope choices only offer modes at or above
 * the agent's (projects can only tighten, docs/dev/plan.md §6.1); the server enforces
 * the same rule when resolving.
 */
export function OverrideDialog({
  detail,
  project,
  onOpenChange,
}: {
  detail: AgentDetail;
  project: { key: string; name: string; color: string };
  onOpenChange: (o: boolean) => void;
}) {
  const existing = detail.overrides.find((o) => o.project.key === project.key)?.override ?? {};
  const save = useSetOverride(detail.agent.handle);
  const spec = detail.spec;

  const [harness, setHarness] = useState<Harness | "inherit">(existing.harness ?? "inherit");
  const models = useChatModels();
  const activeHarness = harness === "inherit" ? spec.harness : harness;
  const catalogModels = models.data?.find((g) => g.harness === activeHarness)?.models ?? [];
  const [model, setModel] = useState(existing.model ?? "");
  const [append, setAppend] = useState(existing.instructions_append ?? "");
  const [scopes, setScopes] = useState<Record<string, ScopeChoice>>(() => {
    const out: Record<string, ScopeChoice> = {};
    for (const s of Object.keys(spec.scopes)) out[s] = existing.scopes?.[s] ?? "inherit";
    for (const [s, m] of Object.entries(existing.scopes ?? {})) out[s] = m;
    return out;
  });
  const [wildcard, setWildcard] = useState("");
  const [setup, setSetup] = useState((existing.setup ?? []).join("\n"));
  // Test services are a JSON array; the server validates each one.
  const [servicesText, setServicesText] = useState(existing.services?.length ? JSON.stringify(existing.services, null, 2) : "");
  const services = parseServices(servicesText);
  const [servers, setServers] = useState(existing.mcp_servers_add ?? []);
  const [server, setServer] = useState({ name: "", url: "" });
  const [runtime, setRuntime] = useState(existing.budget?.max_runtime ?? "");
  const [turns, setTurns] = useState(existing.budget?.max_turns ? String(existing.budget.max_turns) : "");

  const [skillsAdd, setSkillsAdd] = useState(existing.skills_add ?? []);
  const [skillsRemove, setSkillsRemove] = useState((existing.skills_remove ?? []).join("\n"));
  const [skill, setSkill] = useState({ name: "", description: "", body: "" });
  const removals = skillsRemove.split(/[,\s]+/).filter(Boolean);
  const skillNameValid = (name: string) => /^[a-z0-9][a-z0-9-]{0,63}$/.test(name);
  const removalsValid = removals.every(skillNameValid) && new Set(removals).size === removals.length;
  // The server caps a skill body at 64 KiB in bytes, not characters.
  const skillBodyTooLong = new TextEncoder().encode(skill.body.trim()).length > 65536;
  const skillDraftPending = !!(skill.name.trim() || skill.description.trim() || skill.body.trim());
  const canAddSkill = skillNameValid(skill.name.trim()) && !!skill.description.trim() && !!skill.body.trim() && !skillBodyTooLong && !skillsAdd.some((s) => s.name === skill.name.trim()) && skillsAdd.length < 30;

  function build(): AgentOverride {
    const sc: Record<string, ScopeMode> = {};
    for (const [s, m] of Object.entries(scopes)) if (m !== "inherit") sc[s] = m;
    return {
      skills_add: skillsAdd,
      skills_remove: removals,
      harness: harness === "inherit" ? undefined : harness,
      model: model.trim() || undefined,
      instructions_append: append.trim() || undefined,
      scopes: Object.keys(sc).length ? sc : undefined,
      mcp_servers_add: servers.length ? servers : undefined,
      setup: setup.split("\n").map((l) => l.trim()).filter(Boolean),
      services: services.ok && services.value.length ? services.value : undefined,
      budget: { max_runtime: runtime.trim() || undefined, max_turns: turns ? Number(turns) : undefined },
    };
  }

  const submit = (o: AgentOverride) => save.mutate({ project: project.key, override: o }, { onSuccess: () => onOpenChange(false) });

  return (
    <Dialog.Root open onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby={undefined}
          className="motion-dialog fixed left-1/2 top-[6vh] z-50 flex max-h-[88vh] w-[min(720px,calc(100%-32px))] -translate-x-1/2 flex-col overflow-hidden rounded-2xl border border-border-float bg-surface-raised shadow-[var(--shadow-float)] outline-none"
        >
          <div className="flex items-center gap-2 px-[18px] pt-3.5">
            <span aria-hidden className="size-2.5 rounded-[3px]" style={{ background: project.color }} />
            <Dialog.Title className="type-heading">
              {detail.agent.name} in {project.name}
            </Dialog.Title>
            <Dialog.Close asChild>
              <IconButton icon="x" label="Close" className="ml-auto" />
            </Dialog.Close>
          </div>
          <div className="flex flex-col gap-4 overflow-y-auto px-[18px] pb-4 pt-3">
            <p className="text-13 text-fg-tertiary">Overrides merge over the work definition for runs in this space. Permissions can only get stricter.</p>
            <Field label="Harness" htmlFor="ov-h">
              <Segmented
                label="Harness"
                value={harness}
                onChange={setHarness}
                options={[{ value: "inherit" as const, label: `Definition's (${spec.harness})` }, ...detail.harnesses.map((h) => ({ value: h.name, label: h.label }))]}
              />
            </Field>
            <div className="grid grid-cols-[repeat(auto-fit,minmax(180px,1fr))] gap-3">
              <Field label="Model" htmlFor="ov-model">
                <TextInput id="ov-model" mono list="ov-models" placeholder={spec.model} value={model} onChange={(e) => setModel(e.target.value)} />
                <datalist id="ov-models">
                  {catalogModels.map((m) => (
                    <option key={m.id} value={m.id} label={m.label} />
                  ))}
                </datalist>
              </Field>
              <Field label="Max runtime" htmlFor="ov-rt" hint="Only lowers the definition's guard">
                <TextInput id="ov-rt" mono placeholder={spec.budget.max_runtime ?? "none"} value={runtime} onChange={(e) => setRuntime(e.target.value)} />
              </Field>
              <Field label="Max turns" htmlFor="ov-turns">
                <TextInput id="ov-turns" mono type="number" min={0} placeholder={String(spec.budget.max_turns ?? "none")} value={turns} onChange={(e) => setTurns(e.target.value)} />
              </Field>
            </div>
            <Field label="Append to instructions" htmlFor="ov-append">
              <TextArea id="ov-append" mono rows={3} value={append} onChange={(e) => setAppend(e.target.value)} placeholder="e.g. Follow ADR-012 for partitioning." />
            </Field>

            <div className="flex flex-col gap-2">
              <span className="text-13 font-medium text-fg-2">Permissions</span>
              {Object.keys(scopes)
                .sort()
                .map((s) => {
                  const agentMode = spec.scopes[s];
                  const options: Array<{ value: ScopeChoice; label: string }> = [
                    { value: "inherit", label: agentMode ? `Inherit (${MODE_LABEL[agentMode]})` : "Inherit (Denied)" },
                    ...(["requires_approval", "denied"] as const)
                      .filter((m) => !agentMode || MODE_RANK[m] > MODE_RANK[agentMode])
                      .map((m) => ({ value: m, label: MODE_LABEL[m] })),
                  ];
                  return (
                    <div key={s} className="flex flex-wrap items-center gap-3">
                      <span className="w-40 font-mono text-12">{s}</span>
                      <Segmented small label={`${s} in ${project.name}`} value={scopes[s]} options={options} onChange={(m) => setScopes({ ...scopes, [s]: m })} />
                    </div>
                  );
                })}
              <form
                className="flex gap-2"
                onSubmit={(e) => {
                  e.preventDefault();
                  const w = wildcard.trim().toLowerCase();
                  if (/^[a-z][a-z0-9-]*:([a-z0-9][a-z0-9-]*|\*)$/.test(w)) {
                    setScopes({ ...scopes, [w]: "denied" });
                    setWildcard("");
                  }
                }}
              >
                <TextInput mono aria-label="Deny another scope" placeholder="Deny a scope, e.g. prod:*" className="w-60" value={wildcard} onChange={(e) => setWildcard(e.target.value)} />
                <Button type="submit" variant="outline">Deny</Button>
              </form>
            </div>

            <div className="flex flex-col gap-2">
              <span className="text-13 font-medium text-fg-2">Extra MCP servers</span>
              {servers.map((m, i) => (
                <div key={m.name} className="flex items-center gap-2 font-mono text-12">
                  <span>{m.name}</span>
                  <span className="truncate text-fg-tertiary">{m.url}</span>
                  <IconButton icon="trash" label={`Remove ${m.name}`} size={24} className="ml-auto" onClick={() => setServers(servers.filter((_, j) => j !== i))} />
                </div>
              ))}
              <form
                className="flex flex-wrap gap-2"
                onSubmit={(e) => {
                  e.preventDefault();
                  if (server.name.trim() && server.url.trim()) {
                    setServers([...servers, { name: server.name.trim(), url: server.url.trim() }]);
                    setServer({ name: "", url: "" });
                  }
                }}
              >
                <TextInput mono aria-label="Server name" placeholder="name" className="w-36" value={server.name} onChange={(e) => setServer({ ...server, name: e.target.value })} />
                <TextInput mono aria-label="Server URL" placeholder="https://…/mcp" className="min-w-[180px] flex-1" value={server.url} onChange={(e) => setServer({ ...server, url: e.target.value })} />
                <Button type="submit" variant="outline" icon="plus">Add</Button>
              </form>
            </div>
            <section aria-labelledby="ov-skills-title" className="flex flex-col gap-3">
              <h3 id="ov-skills-title" className="font-medium">Space skills</h3>
              <p className="text-12 text-fg-tertiary">Removals apply first, then additions. Unknown removals do nothing. To replace a default skill, remove its name and add the replacement. Future agent updates still flow through.</p>
              <Field label="Remove agent skills" htmlFor="ov-skills-remove" hint="Skill names separated by spaces, commas or new lines. Leave empty to keep all defaults.">
                <TextArea id="ov-skills-remove" mono rows={2} value={skillsRemove} aria-invalid={!removalsValid} onChange={(e) => setSkillsRemove(e.target.value)} />
              </Field>
              {!removalsValid && <p role="alert" className="text-12 text-pill-blocked-fg">Use unique skill names: lowercase letters, digits or hyphens, up to 64 characters.</p>}
              {!skillsAdd.length && <p className="text-12 text-fg-tertiary">No space skills added. The agent’s remaining defaults are used.</p>}
              <ul className="space-y-2">{skillsAdd.map((s, i) => <li key={s.name} className="flex items-center gap-2 text-14"><span className="font-mono">{s.name}</span><span className="flex-1 text-fg-secondary">{s.description}</span><IconButton icon="trash" label={`Remove added skill ${s.name}`} onClick={() => setSkillsAdd(skillsAdd.filter((_, j) => i !== j))} /></li>)}</ul>
              <Field label="Added skill name" htmlFor="ov-skill-name"><TextInput id="ov-skill-name" mono maxLength={64} value={skill.name} onChange={(e) => setSkill({ ...skill, name: e.target.value })} /></Field>
              <Field label="When to use this skill" htmlFor="ov-skill-description"><TextInput id="ov-skill-description" maxLength={1024} value={skill.description} onChange={(e) => setSkill({ ...skill, description: e.target.value })} /></Field>
              <Field label="Skill instructions" htmlFor="ov-skill-body"><TextArea id="ov-skill-body" mono rows={4} maxLength={65536} value={skill.body} onChange={(e) => setSkill({ ...skill, body: e.target.value })} /></Field>
              {skillBodyTooLong && <p role="alert" className="text-12 text-pill-blocked-fg">Skill instructions are over 64 KiB. Shorten them before adding.</p>}
              <p className="text-12 text-fg-tertiary">Up to 30 added skills. The resolved result keeps agent skills first and caps the total at 30. Add the draft skill or clear it before saving.</p>
              {(skill.name || skill.description || skill.body) && <Button variant="ghost" onClick={() => setSkill({ name: "", description: "", body: "" })}>Clear skill draft</Button>}
              <Button variant="outline" disabled={!canAddSkill} onClick={() => { setSkillsAdd([...skillsAdd, { name: skill.name.trim(), description: skill.description.trim(), body: skill.body.trim() }]); setSkill({ name: "", description: "", body: "" }); }}>Add space skill</Button>
            </section>
            <Field label="Setup commands" htmlFor="ov-setup" hint="One per line. Run in the workspace after cloning (Phase 5).">
              <TextArea id="ov-setup" mono rows={2} value={setup} onChange={(e) => setSetup(e.target.value)} placeholder="make deps" />
            </Field>
            <Field
              label="Test services"
              htmlFor="ov-services"
              hint="JSON array. Each turn gets these containers on a network of its own, sandboxed like the turn, and loses them when it ends."
            >
              <TextArea id="ov-services" mono rows={4} value={servicesText} aria-invalid={!services.ok} onChange={(e) => setServicesText(e.target.value)} placeholder={SERVICES_EXAMPLE} />
            </Field>
            {!services.ok && <p role="alert" className="text-12 text-pill-blocked-fg">{services.error}</p>}
          </div>
          <div className="flex flex-wrap items-center justify-end gap-3 border-t border-track bg-surface-sunken px-[18px] py-3">
            {save.isError && (
              <span role="alert" className="mr-auto text-12 text-pill-blocked-fg">
                {save.error.message}
              </span>
            )}
            {detail.overrides.some((o) => o.project.key === project.key) && (
              <Button variant="ghost" className="mr-auto text-pill-blocked-fg" onClick={() => submit({})}>
                Remove override
              </Button>
            )}
            <Dialog.Close asChild>
              <Button variant="ghost">Cancel</Button>
            </Dialog.Close>
            <Button variant="primary" disabled={save.isPending || !removalsValid || skillDraftPending || !services.ok} onClick={() => submit(build())}>
              Save override
            </Button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
