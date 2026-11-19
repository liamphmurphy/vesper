"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import type { ArtifactSummary, ArtifactType } from "@/lib/api/client";
import { useArtifacts } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { shortAgo } from "@/lib/format";
import { useCompact } from "@/lib/viewport";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { Button } from "@/components/ui/button";
import { Tabs } from "@/components/ui/controls";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, Skeleton } from "@/components/ui/primitives";
import { AgentAvatar, HumanAvatar } from "@/components/domain/avatars";
import { artifactMeta, artifactTitle } from "@/components/domain/artifacts";
import { NewMockupDialog, UploadDialog } from "@/components/domain/artifact-dialogs";
import { DocTypeTag } from "@/components/domain/labels";
import { ReviewChip } from "@/components/domain/mockup";
import { TopBar } from "@/components/shell/topbar";
import { ProjectScopeState, useProjectScope } from "@/components/shell/project-scope";
import { ProjectPicker, useProjectPickerNative } from "@/components/shell/project-picker";
import { buildProjectDocsNavModel, LIBRARY_SEARCH, LIBRARY_SOURCE_PICKER, librarySourceHref, type LibrarySourceValue } from "@/lib/native-shell/models/library";
import { LibrarySourceSwitch } from "./source-switch";
import { ArtifactPreview } from "./preview";
import { PageHeader } from "@/components/ui/page-header";

const TABS: Array<{ key: "all" | ArtifactType; label: string }> = [
  { key: "all", label: "All" },
  { key: "prd", label: "PRDs" },
  { key: "spec", label: "Specs" },
  { key: "adr", label: "ADRs" },
  { key: "report", label: "Agent reports" },
  { key: "design", label: "Designs" },
  { key: "mockup", label: "Mockups" },
  { key: "note", label: "Wiki pages" },
];

function Author({ a }: { a: ArtifactSummary }) {
  return (
    <span className="flex min-w-0 items-center gap-2">
      {a.author.type === "agent" ? (
        <AgentAvatar name={a.author.name} colorIndex={a.author.color_index ?? 0} label={false} />
      ) : (
        <HumanAvatar name={a.author.name} initials={a.author.initials} color={a.author.avatar_color} label={false} />
      )}
      <span className="truncate">{a.author.name}</span>
    </span>
  );
}

function TableSkeleton() {
  return (
    <div aria-busy="true" aria-label="Loading artifacts" className="flex flex-col">
      {[0.55, 0.4, 0.5, 0.35, 0.45].map((w, i) => (
        <div key={i} className="flex h-[58px] items-center gap-3 border-t border-border-row px-4">
          <Skeleton className="h-4 w-12" />
          <Skeleton className="h-3" style={{ width: `${w * 60}%` }} />
        </div>
      ))}
    </div>
  );
}

/** Library's "From projects": what agents read before they work and the reports they leave, from GET /artifacts. */
export function ProjectDocs() {
  const compact = useCompact();
  const params = useSearchParams();
  const router = useRouter();
  const type = (params.get("type") as ArtifactType | null) ?? undefined;
  const q = params.get("q") ?? "";
  const project = params.get("project") ?? undefined;
  const selected = params.get("id");
  const [search, setSearch] = useState(q);
  const [upload, setUpload] = useState<{ files: File[] } | null>(null);
  const [dragging, setDragging] = useState(false);
  const [mockup, setMockup] = useState(false);

  // ?project= or the remembered project; "All spaces" lists every artifact.
  const scope = useProjectScope("optional");
  const list = useArtifacts({ type, q: q || undefined, project });

  function setParams(changes: Record<string, string | null>) {
    const next = new URLSearchParams(params);
    for (const [k, v] of Object.entries(changes)) {
      if (v) next.set(k, v);
      else next.delete(k);
    }
    next.set("source", "projects");
    router.replace(`/library?${next}`, { scroll: false });
  }

  useEffect(() => {
    if (search === q) return;
    const id = setTimeout(() => setParams({ q: search || null }), 250);
    return () => clearTimeout(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [search]);

  const counts = list.data?.counts;
  const tabHref = (k: string) => {
    const next = new URLSearchParams(params);
    if (k === "all") next.delete("type");
    else next.set("type", k);
    next.delete("id");
    next.set("source", "projects");
    return `/library?${next}`;
  };
  const artifacts = list.data?.artifacts ?? [];
  const picker = useProjectPickerNative();

  return (
    <>
      <NavigatorPortal
        native={{
          model: buildProjectDocsNavModel({
            tabs: TABS.map((t) => ({ key: t.key, label: t.label, href: tabHref(t.key) })),
            type: type ?? "all",
            counts,
            search,
            projectAction: picker.action,
          }),
          onCommand: (cmd) => {
            if (picker.handle(cmd)) return;
            if (cmd.type === "nav.search" && cmd.searchId === LIBRARY_SEARCH) setSearch(cmd.value);
            else if (cmd.type === "nav.picker" && cmd.pickerId === LIBRARY_SOURCE_PICKER) router.push(librarySourceHref(cmd.value as LibrarySourceValue));
          },
        }}
      />
      <TopBar
        crumbs={[{ label: "Library", href: "/library" }, { label: "From spaces" }]}
        nativeActions={[
          { id: "docs.mockup", label: "New mockup", kind: "button", icon: "plus", showsLabel: true, run: () => setMockup(true) },
          { id: "docs.upload", label: "Upload", kind: "button", icon: "upload", showsLabel: true, accent: true, run: () => setUpload({ files: [] }) },
        ]}
      />
      <div className="flex flex-1 flex-wrap">
        <div className="flex min-w-0 flex-[999_1_560px] flex-col gap-5 px-7 py-8 max-sm:px-4">
          <PageHeader title="Library" description="Shared with the workspace: context agents read before they work, and the reports they leave behind.">
            {compact && <LibrarySourceSwitch source="projects" />}
            {compact && <ProjectPicker />}
          </PageHeader>

          {compact && (
            <div className="flex flex-wrap items-center gap-3">
              <label className="flex h-[34px] min-w-[220px] flex-1 items-center gap-2 rounded-md border border-border-strong bg-surface px-3 text-fg-tertiary focus-within:border-accent">
                <Icon name="search" size={14} />
                <span className="sr-only">Search artifacts</span>
                <input
                  value={search}
                  onChange={(e) => setSearch(e.target.value)}
                  placeholder="Search titles and contents"
                  className="flex-1 bg-transparent text-13 text-fg outline-none placeholder:text-fg-tertiary"
                />
              </label>
              <Tabs
                label="Artifact types"
                value={type ?? "all"}
                items={TABS.map((t) => ({ key: t.key, label: t.label, count: counts?.[t.key], href: tabHref(t.key) }))}
              />
            </div>
          )}

          <button
            type="button"
            onClick={() => setUpload({ files: [] })}
            onDragOver={(e) => {
              e.preventDefault();
              setDragging(true);
            }}
            onDragLeave={() => setDragging(false)}
            onDrop={(e) => {
              e.preventDefault();
              setDragging(false);
              const files = [...e.dataTransfer.files];
              if (files.length) setUpload({ files });
            }}
            className={cx(
              "flex items-center gap-3.5 rounded-xl border border-dashed px-4 py-3.5 text-left",
              dragging ? "border-accent bg-accent-soft" : "border-border-strong hover:bg-hover",
            )}
          >
            <span className="grid size-8 place-items-center rounded-md border border-border-strong bg-selected text-fg-secondary">
              <Icon name="upload" size={15} />
            </span>
            <span className="flex flex-col">
              <span className="font-medium">Drop PRDs, specs or ADRs here</span>
              <span className="text-13 text-fg-tertiary">
                Markdown, PDF or images. Markdown is split into sections so agents can cite them.
              </span>
            </span>
          </button>

          {scope.status !== "ready" ? (
            <ProjectScopeState base="/library" scope={scope} />
          ) : list.isError ? (
            <Banner tone="blocked" title="Couldn't load artifacts">
              {list.error.message}
            </Banner>
          ) : (
            <div className="overflow-x-auto rounded-xl border border-border bg-surface">
              <table className="w-full min-w-[720px] border-collapse text-13">
                <thead>
                  <tr className="text-left text-13 text-fg-tertiary">
                    <th className="px-4 py-3 font-normal">Name</th>
                    <th className="w-[150px] px-3 py-3 font-normal">Author</th>
                    <th className="w-[170px] px-3 py-3 font-normal">Project</th>
                    <th className="w-[70px] px-3 py-3 font-normal">Tickets</th>
                    <th className="w-[90px] px-4 py-3 text-right font-normal">Updated</th>
                  </tr>
                </thead>
                <tbody>
                  {list.isPending ? (
                    <tr>
                      <td colSpan={5}>
                        <TableSkeleton />
                      </td>
                    </tr>
                  ) : artifacts.length === 0 ? (
                    <tr>
                      <td colSpan={5}>
                        <EmptyState
                          icon="artifacts"
                          title={q ? "No artifacts match" : "No artifacts yet"}
                          actions={!q && <Button variant="outline" icon="upload" onClick={() => setUpload({ files: [] })}>Upload</Button>}
                        >
                          {q ? "Search covers titles, summaries and document text." : "Upload a PRD, spec or ADR so agents can read it before they work."}
                        </EmptyState>
                      </td>
                    </tr>
                  ) : (
                    artifacts.map((a) => {
                      const on = a.id === selected;
                      return (
                        <tr key={a.id} className={cx("relative border-t border-border-row", on ? "bg-accent/8" : "hover:bg-row-hover")}>
                          <td className="px-4 py-2.5">
                            <div className="flex items-center gap-3">
                              <DocTypeTag type={a.type} className="w-[56px] text-center" />
                              <span className="flex min-w-0 flex-col">
                                {/* Stretched button: the whole row selects the artifact. */}
                                <button
                                  type="button"
                                  aria-pressed={on}
                                  onClick={() => setParams({ id: on ? null : a.id })}
                                  className="truncate text-left font-medium after:absolute after:inset-0"
                                >
                                  {artifactTitle(a)}
                                </button>
                                <span className="flex items-center gap-2 text-12 text-fg-tertiary">
                                  {a.path ?? artifactMeta(a)}
                                  {a.review_state && <ReviewChip state={a.review_state} />}
                                </span>
                              </span>
                            </div>
                          </td>
                          <td className="px-3">
                            <Author a={a} />
                          </td>
                          <td className="px-3">
                            {a.project ? (
                              <span className="flex items-center gap-2 text-fg-secondary">
                                <span aria-hidden className="size-2.5 flex-none rounded-[3px]" style={{ background: a.project.color }} />
                                <span className="truncate">{a.project.name}</span>
                              </span>
                            ) : (
                              <span className="text-fg-tertiary">Workspace</span>
                            )}
                          </td>
                          <td className="px-3 font-mono text-12 text-fg-secondary">{a.ticket_count || "–"}</td>
                          <td className="px-4 text-right text-12 text-fg-tertiary" title={new Date(a.updated_at).toLocaleString()}>
                            {shortAgo(a.updated_at)}
                          </td>
                        </tr>
                      );
                    })
                  )}
                </tbody>
              </table>
            </div>
          )}
        </div>

        {selected && (
          <aside aria-label="Artifact preview" className="flex-[1_1_340px] border-l border-border-subtle bg-panel lg:max-w-[360px]">
            <ArtifactPreview id={selected} onClose={() => setParams({ id: null })} />
          </aside>
        )}
      </div>

      {mockup && <NewMockupDialog open defaultProject={project} onOpenChange={(o) => !o && setMockup(false)} />}
      {upload && (
        <UploadDialog
          open
          initialFiles={upload.files}
          defaultProject={project}
          onOpenChange={(o) => !o && setUpload(null)}
          onCreated={(a) => setParams({ id: a.id, type: null, q: null })}
        />
      )}
    </>
  );
}
