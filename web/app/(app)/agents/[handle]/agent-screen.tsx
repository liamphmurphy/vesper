"use client";

import { useSearchParams } from "next/navigation";
import { DropdownMenu } from "radix-ui";
import { useEffect, useMemo, useState } from "react";
import type { AgentDetail, Schemas } from "@/lib/api/client";
import { useAgent, useAgentOverviews, useBootstrap, useResolved, useSaveDefinition, useWikiTree } from "@/lib/api/hooks";
import { liveCounts, scopeRows } from "@/lib/agent-scopes";
import { cx } from "@/lib/cx";
import { ago, timelineTime } from "@/lib/format";
import { Button, ButtonLink } from "@/components/ui/button";
import { Tabs } from "@/components/ui/controls";
import { Banner, EmptyState, Skeleton } from "@/components/ui/primitives";
import { AgentAvatar } from "@/components/domain/avatars";
import { MonoChip, Pill, type PillTone } from "@/components/domain/labels";
import { floatPanel } from "@/components/domain/pickers";
import { useRememberedProject } from "@/components/shell/project-scope";
import { TopBar } from "@/components/shell/topbar";
import { DefinitionEditor, describeChanges, draftOf, type Draft } from "./definition-editor";
import { MemoryTab } from "./memory-tab";
import { OverrideDialog } from "./override-dialog";
import { ActivityTab, OverviewTab } from "./overview-tab";
import { ProjectPicker } from "./project-picker";
import { ReviewDialog } from "./review-dialog";
import { ScopesTab } from "./scopes-tab";
import { SkillsTab } from "./skills-tab";
import { TokensTab } from "./tokens-tab";
import { addLeaveGuard } from "@/lib/leave-guard";

const TABS = ["overview", "scopes", "skills", "memory", "activity", "settings", "tokens"] as const;
type Tab = (typeof TABS)[number];
/** Links from before the tabs were split keep working. */
const LEGACY: Record<string, Tab> = { definition: "settings", runs: "activity" };

/** A persona's work settings: its work record, opened from the persona in Settings. */
const AGENTS_HREF = "/settings?section=personas";
const AGENTS_CRUMBS = [{ label: "Settings", href: "/settings" }, { label: "Personas", href: AGENTS_HREF }];
/** The persona a work record belongs to has the record's id. */
const personaHref = (id: string) => `/settings?section=personas&persona=${encodeURIComponent(id)}`;

export function tabFrom(param: string | null): Tab {
  if (param && (TABS as readonly string[]).includes(param)) return param as Tab;
  return (param && LEGACY[param]) || "overview";
}

const STATUS: Record<AgentDetail["agent"]["status"], { tone: PillTone; label: string }> = {
  running: { tone: "done", label: "Running" },
  waiting: { tone: "human", label: "Waiting" },
  blocked: { tone: "blocked", label: "Blocked" },
  idle: { tone: "neutral", label: "Idle" },
};

function ResolvedPanel({ detail, projects, project, onProject }: { detail: AgentDetail; projects: Schemas["Project"][]; project?: string; onProject: (key: string) => void }) {
  const r = useResolved(detail.agent.handle, project);
  const fromProject = (f: string) => r.data?.provenance[f] === "project" && <MonoChip variant="outline">space</MonoChip>;
  const extraLines = r.data ? r.data.instructions.trim().split("\n").length - detail.spec.instructions.trim().split("\n").length : 0;

  return (
    <section className="flex min-w-0 flex-col gap-2 rounded-xl border border-border bg-surface p-4">
      <div className="flex items-center gap-2">
        <h2 className="text-13 font-semibold">Resolved for</h2>
        <ProjectPicker label="Resolved for" projects={projects} value={project} onChange={onProject} className="min-w-0 flex-1" />
      </div>
      {!r.data ? (
        <Skeleton className="h-24" />
      ) : (
        <dl className="grid grid-cols-[84px_minmax(0,1fr)] items-center gap-x-3 gap-y-2 text-13">
          <dt className="text-fg-tertiary">Harness</dt>
          <dd className="flex items-center gap-1.5"><MonoChip>{r.data.harness}</MonoChip>{fromProject("harness")}</dd>
          <dt className="text-fg-tertiary">Model</dt>
          <dd className="flex items-center gap-1.5"><MonoChip>{r.data.model}</MonoChip>{fromProject("model")}</dd>
          <dt className="text-fg-tertiary">Instructions</dt>
          <dd className="flex items-center gap-1.5">
            {r.data.provenance.instructions ? `Brief + ${extraLines} line${extraLines === 1 ? "" : "s"}` : "Work brief"}
            {fromProject("instructions")}
          </dd>
          <dt className="text-fg-tertiary">MCP</dt>
          <dd className="flex min-w-0 items-center gap-1.5">
            <span className="truncate font-mono text-12">{["lazyagents", ...r.data.mcp_servers.map((m) => m.name)].join(", ")}</span>
            {fromProject("mcp_servers")}
          </dd>
          <dt className="text-fg-tertiary">Approval</dt>
          <dd className="flex flex-wrap gap-1">
            {r.data.scopes.filter((s) => s.mode === "requires_approval").map((s) => (
              <span key={s.scope} className="rounded-[5px] bg-pill-human-bg px-1.5 py-0.5 font-mono text-11 text-pill-human-fg">{s.scope}</span>
            ))}
          </dd>
          <dt className="text-fg-tertiary">Denied</dt>
          <dd className="flex flex-wrap gap-1">
            {r.data.scopes.filter((s) => s.mode === "denied").map((s) => (
              <span key={s.scope} className="rounded-[5px] bg-pill-blocked-bg px-1.5 py-0.5 font-mono text-11 text-pill-blocked-fg">
                {s.scope}
                {s.source === "project" && " ·p"}
              </span>
            ))}
          </dd>
        </dl>
      )}
      <p className="text-12 text-fg-tertiary">Each run stores a snapshot of this, so editing {detail.agent.name} never changes a run in progress.</p>
    </section>
  );
}

function OverridesPanel({ detail, onEdit }: { detail: AgentDetail; onEdit: (key: string) => void }) {
  const boot = useBootstrap();
  const without = (boot.data?.projects ?? []).filter((p) => !detail.overrides.some((o) => o.project.key === p.key));
  return (
    <section className="flex flex-col gap-1">
      <div className="flex items-center justify-between px-1">
        <h2 className="text-13 text-fg-tertiary">Space overrides</h2>
        {without.length > 0 && (
          <DropdownMenu.Root>
            <DropdownMenu.Trigger asChild>
              <Button variant="ghost" icon="plus" className="h-7 px-2 text-12 text-fg-secondary">Add</Button>
            </DropdownMenu.Trigger>
            <DropdownMenu.Portal>
              <DropdownMenu.Content align="end" sideOffset={4} className={cx(floatPanel, "w-56")}>
                {without.map((p) => (
                  <DropdownMenu.Item key={p.key} onSelect={() => onEdit(p.key)} className="flex h-8 items-center gap-2.5 rounded-md px-2 outline-none data-[highlighted]:bg-hover">
                    <span aria-hidden className="size-2.5 rounded-[3px]" style={{ background: p.color }} />
                    {p.name}
                  </DropdownMenu.Item>
                ))}
              </DropdownMenu.Content>
            </DropdownMenu.Portal>
          </DropdownMenu.Root>
        )}
      </div>
      {detail.overrides.map((o) => (
        <button key={o.project.key} type="button" onClick={() => onEdit(o.project.key)} className="flex flex-col gap-0.5 rounded-lg px-3 py-2 text-left hover:bg-hover">
          <span className="flex items-center gap-2 text-13 font-medium">
            <span aria-hidden className="size-2.5 rounded-[3px]" style={{ background: o.project.color }} />
            {o.project.name}
            <span className="ml-auto font-mono text-11 font-normal text-fg-tertiary">
              {o.changes.length} change{o.changes.length === 1 ? "" : "s"}
            </span>
          </span>
          {o.changes.map((c) => (
            <span key={c} className="truncate pl-[18px] text-12 text-fg-secondary">{c}</span>
          ))}
        </button>
      ))}
      {without.slice(0, 2).map((p) => (
        <div key={p.key} className="flex flex-col gap-0.5 px-3 py-2">
          <span className="flex items-center gap-2 text-13">
            <span aria-hidden className="size-2.5 rounded-[3px]" style={{ background: p.color }} />
            {p.name}
            <span className="ml-auto text-fg-tertiary">–</span>
          </span>
          <span className="pl-[18px] text-12 text-fg-tertiary">Uses the work definition as is</span>
        </div>
      ))}
    </section>
  );
}

export function AgentScreen({ handle }: { handle: string }) {
  const { data: detail, isError, error } = useAgent(handle);
  const tab = tabFrom(useSearchParams().get("tab"));
  const boot = useBootstrap();
  const projects = useMemo(() => boot.data?.projects.filter((p) => !p.archived) ?? [], [boot.data]);
  const remembered = useRememberedProject();
  const [picked, setPicked] = useState<string>();
  // Follows the project you're in; switch to compare.
  const project =
    picked ??
    (projects.some((p) => p.key === remembered) ? remembered! : undefined) ??
    detail?.overrides[0]?.project.key ??
    projects[0]?.key;
  const overviews = useAgentOverviews();
  const overview = overviews.data?.agents.find((a) => a.agent.handle === handle);
  const wiki = useWikiTree();
  const save = useSaveDefinition(handle);
  const [draft, setDraft] = useState<Draft | null>(null);
  const [editing, setEditing] = useState<string | null>(null);
  const [reviewing, setReviewing] = useState(false);
  const base = useMemo(() => (detail ? draftOf(detail) : null), [detail]);
  const current = draft ?? base;
  const dirty = !!draft && !!base && JSON.stringify(draft) !== JSON.stringify(base);
  const changes = dirty && base && draft ? describeChanges(base, draft).split("; ").length : 0;

  function review() {
    // Already reviewing: resetting the mutation would drop its error and its onSuccess.
    if (!dirty || reviewing) return;
    save.reset();
    setReviewing(true);
  }

  // ⌘S opens the review; saving happens there (DESIGN.md §6).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s" && detail && !editing) {
        e.preventDefault();
        review();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  // Warn before leaving with unsaved changes.
  useEffect(() => {
    if (!dirty) return;
    const onBeforeUnload = (e: BeforeUnloadEvent) => e.preventDefault();
    return addLeaveGuard(onBeforeUnload);
  }, [dirty]);

  if (isError) {
    const missing = "status" in error && error.status === 404;
    return (
      <>
        <TopBar crumbs={[...AGENTS_CRUMBS, { label: `@${handle}` }]} />
        {missing ? (
          <EmptyState icon="agents" title={`No persona @${handle} works on tickets or runs`} actions={<ButtonLink href={AGENTS_HREF} variant="outline">All personas</ButtonLink>} />
        ) : (
          <div className="p-6"><Banner tone="blocked" title="Couldn't load this persona's work">{error.message}</Banner></div>
        )}
      </>
    );
  }

  const editingProject = editing ? boot.data?.projects.find((p) => p.key === editing) : undefined;
  const status = STATUS[boot.data?.agents.find((a) => a.handle === handle)?.status ?? detail?.agent.status ?? "idle"];

  return (
    <>
      <TopBar
        crumbs={[...AGENTS_CRUMBS, detail ? { label: detail.agent.name, href: personaHref(detail.agent.id) } : { label: `@${handle}` }, { label: "Work" }]}
        nativeTitle={{ title: detail ? `${detail.agent.name} · Work` : "Work", subtitle: dirty ? `${changes} unsaved change${changes === 1 ? "" : "s"}` : undefined }}
        nativeActions={detail ? [
          ...(dirty ? [{ id: "agent.discard", label: "Discard", kind: "button" as const, showsLabel: true, run: () => setDraft(null) }] : []),
          { id: "agent.review", label: "Review changes", kind: "button" as const, accent: true, showsLabel: true, disabled: !dirty, run: review },
        ] : undefined}
      />
      {!detail || !current ? (
        <div aria-busy="true" className="flex flex-col gap-4 px-7 py-8">
          <Skeleton className="h-10 w-72" />
          <Skeleton className="h-64" />
        </div>
      ) : (
        <>
          <div className="flex flex-wrap items-center justify-between gap-4 border-b border-border-subtle px-7 py-5">
            <div className="flex items-center gap-3.5">
              <AgentAvatar name={current.name || detail.agent.name} colorIndex={current.color_index} size="lg" label={false} />
              <div className="flex flex-col gap-0.5">
                <div className="flex items-center gap-2.5">
                  <h1 className="type-display">{detail.agent.name}</h1>
                  <Pill tone={status.tone}>{status.label}</Pill>
                </div>
                <span className="text-13 text-fg-secondary">
                  {detail.agent.kind === "sub" ? "Helps on runs" : detail.agent.kind === "assistant" ? "Personal Assistant (managed by Vesper)" : "Takes tickets"}
                  {detail.agent.role && ` · ${detail.agent.role}`} · definition <b className="font-mono font-medium text-fg">v{detail.definition.version}</b>
                  {detail.definition.created_by && ` saved by ${detail.definition.created_by.name}`} {ago(detail.definition.created_at)}
                </span>
              </div>
            </div>
            <Tabs
              label="Work sections"
              value={tab}
              items={[
                { key: "overview", label: "Overview", href: `/agents/${handle}?tab=overview` },
                { key: "scopes", label: "Scopes", count: scopeRows(detail.catalog.map((c) => c.scope), current.spec.scopes, detail.overrides.find((o) => o.project.key === project)?.override.scopes).length, href: `/agents/${handle}?tab=scopes` },
                { key: "skills", label: "Skills", count: current.spec.skills?.length ?? 0, href: `/agents/${handle}?tab=skills` },
                { key: "memory", label: "Memory", count: wiki.data?.pages.filter((p) => p.path.startsWith(`agents/${handle}/`)).length, href: `/agents/${handle}?tab=memory` },
                { key: "activity", label: "Activity", href: `/agents/${handle}?tab=activity` },
                { key: "settings", label: "Settings", href: `/agents/${handle}?tab=settings` },
                { key: "tokens", label: "Tokens", href: `/agents/${handle}?tab=tokens` },
              ]}
            />
          </div>
          <div className="flex flex-1 flex-wrap">
            <div className="min-w-0 flex-[999_1_560px] px-7 py-6 max-sm:px-4">
              <div className="mx-auto max-w-[760px]">
                {tab === "overview" ? (
                  <OverviewTab detail={detail} draft={current} onChange={setDraft} project={projects.find((p) => p.key === project)} onPreview={review} />
                ) : tab === "scopes" ? (
                  <ScopesTab detail={detail} draft={current} onChange={setDraft} projects={projects} project={project} onProject={setPicked} />
                ) : tab === "skills" ? (
                  <SkillsTab detail={detail} draft={current} onChange={setDraft} projects={projects} project={project} onProject={setPicked} />
                ) : tab === "memory" ? (
                  <MemoryTab handle={handle} memory={current.spec.memory} />
                ) : tab === "activity" ? (
                  <ActivityTab handle={handle} />
                ) : tab === "tokens" ? (
                  <TokensTab detail={detail} />
                ) : (
                  <DefinitionEditor detail={detail} draft={current} onChange={setDraft} />
                )}
              </div>
            </div>
            <aside aria-label="Overrides and versions" className="flex min-w-0 flex-[1_1_300px] flex-col gap-5 border-l border-border-subtle bg-panel px-4 py-6 lg:max-w-[340px]">
              <div id="overrides">
                <OverridesPanel detail={detail} onEdit={setEditing} />
              </div>
              <ResolvedPanel detail={detail} projects={projects} project={project} onProject={setPicked} />
              <section className="flex flex-col gap-1">
                <h2 className="px-1 text-13 text-fg-tertiary">Versions</h2>
                <ol>
                  {detail.versions.map((v) => (
                    <li key={v.id} className="flex items-baseline gap-3 px-1 py-1.5 text-13">
                      <span className="w-6 font-mono text-12 text-fg-secondary">v{v.version}</span>
                      <span className="flex-1 truncate" title={v.note}>{v.note || "—"}</span>
                      <span className="text-12 text-fg-tertiary">{timelineTime(v.created_at)}</span>
                    </li>
                  ))}
                </ol>
              </section>
            </aside>
          </div>
        </>
      )}
      {reviewing && detail && base && draft && dirty && (
        <ReviewDialog
          detail={detail}
          base={base}
          draft={draft}
          liveRuns={overview ? liveCounts(overview).live : 0}
          pending={save.isPending}
          error={save.isError ? save.error.message : undefined}
          onClose={() => setReviewing(false)}
          onSave={(note) =>
            save.mutate(
              { ...draft, note },
              {
                onSuccess: () => {
                  setDraft(null);
                  setReviewing(false);
                },
              },
            )
          }
        />
      )}
      {editing && detail && editingProject && <OverrideDialog detail={detail} project={editingProject} onOpenChange={(o) => !o && setEditing(null)} />}
    </>
  );
}
