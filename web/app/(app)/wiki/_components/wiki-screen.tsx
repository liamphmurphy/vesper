"use client";

import { NavigatorPortal } from "@/components/shell/navigator-slot";
import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { ApiError, type Artifact } from "@/lib/api/client";
import {
  useCreateWikiPage,
  useImportWiki,
  useKnowledgeSearch,
  useSaveWikiPage,
  useWikiPage,
  useWikiSuggestions,
  useWikiTree,
} from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { absoluteTime, timelineTime } from "@/lib/format";
import { wikiHref } from "@/lib/wikilinks";
import { Button, ButtonLink } from "@/components/ui/button";
import { Banner, EmptyState, Field, Kbd, Skeleton, TextInput } from "@/components/ui/primitives";
import { DialogShell } from "@/components/domain/artifact-dialogs";
import { ApiActorAvatar } from "@/components/domain/avatars";
import { BacklinksPanel } from "@/components/domain/backlinks";
import { LinkEditor } from "@/components/domain/link-editor";
import { LocalGraph } from "@/components/domain/local-graph";
import { Markdown } from "@/components/domain/markdown";
import { TargetMark } from "@/components/domain/wikilink";
import { StartChatButton, useStartChat } from "@/components/domain/start-chat";
import type { NativeAction } from "@/lib/native-shell/actions";
import { TopBar, type Crumb } from "@/components/shell/topbar";
import { pageHeader, parseCompare } from "@/lib/wiki";
import { ADRIndex } from "./adr-index";
import { CitedBy, History, LinkedTickets, PanelSection, TagsSection } from "./page-rail";
import { useWikiNative, type WikiIndex } from "./page-tree";
import { PatternsFinder } from "./patterns-finder";
import { VersionDiff } from "./version-diff";
import { SuggestionCard } from "./suggestions";
import { PageHeader } from "@/components/ui/page-header";

function crumbsFor(path: string): Crumb[] {
  const segs = path.split("/");
  return [
    { label: "Wiki", href: "/wiki" },
    ...segs.slice(0, -1).map((s) => ({ label: s })),
    { label: segs[segs.length - 1] },
  ];
}

/** Tree on the left, the page (or home) in the middle. */
function WikiLayout({
  current,
  index,
  crumbs,
  actions,
  nativeActions,
  children,
}: {
  current: string;
  index?: WikiIndex;
  crumbs: Crumb[];
  actions?: ReactNode;
  nativeActions?: NativeAction[];
  children: ReactNode;
}) {
  const tree = useWikiTree();
  const wikiNative = useWikiNative(tree.data?.pages, current, index);
  return (
    <>
      <TopBar crumbs={crumbs} actions={actions} nativeActions={nativeActions} />
      <div className="flex flex-1 flex-wrap">
        <NavigatorPortal native={wikiNative} />
        {children}
      </div>
    </>
  );
}

// ------------------------------------------------------------ new page

export function NewPageDialog({ open, onOpenChange, folder = "" }: { open: boolean; onOpenChange: (o: boolean) => void; folder?: string }) {
  const router = useRouter();
  const create = useCreateWikiPage();
  const [path, setPath] = useState(folder ? `${folder}/` : "");
  const submit = () =>
    create.mutate({ path, body_md: "" }, { onSuccess: (a) => (onOpenChange(false), router.push(`${wikiHref(a.path ?? path)}?edit=1`)) });
  return (
    <DialogShell
      open={open}
      onOpenChange={onOpenChange}
      title="New page"
      footer={
        <>
          <Button variant="ghost" onClick={() => onOpenChange(false)}>
            Cancel
          </Button>
          <Button variant="primary" disabled={!path.trim() || create.isPending} onClick={submit}>
            Create page
          </Button>
        </>
      }
    >
      <Field
        label="Path"
        htmlFor="wiki-path"
        hint="Folders are separated by /. The last part is the title. Link to it from anywhere with [[title]]."
      >
        <TextInput
          id="wiki-path"
          autoFocus
          value={path}
          placeholder="Payments/Ledger/Rollback runbook"
          onChange={(e) => setPath(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && path.trim() && submit()}
        />
      </Field>
      {create.isError && <p className="text-12 text-pill-blocked-fg">{create.error.message}</p>}
    </DialogShell>
  );
}

// ------------------------------------------------------------ home

function ImportButton() {
  const ref = useRef<HTMLInputElement>(null);
  const imp = useImportWiki();
  return (
    <>
      <input
        ref={ref}
        type="file"
        accept=".zip,application/zip"
        className="hidden"
        aria-hidden
        tabIndex={-1}
        onChange={(e) => {
          const f = e.target.files?.[0];
          if (f) imp.mutate(f);
          e.target.value = "";
        }}
      />
      <Button variant="outline" icon="upload" disabled={imp.isPending} onClick={() => ref.current?.click()}>
        Import vault
      </Button>
      {imp.isSuccess && (
        <span role="status" className="text-12 text-fg-secondary">
          Imported: {imp.data.created} new, {imp.data.updated} updated, {imp.data.unchanged} unchanged
          {imp.data.skipped.length > 0 && `, ${imp.data.skipped.length} skipped`}
        </span>
      )}
      {imp.isError && (
        <span role="alert" className="text-12 text-pill-blocked-fg">
          {imp.error.message}
        </span>
      )}
    </>
  );
}

function WikiSearch() {
  const [q, setQ] = useState("");
  const hits = useKnowledgeSearch(q);
  return (
    <section className="flex flex-col gap-2">
      <TextInput
        aria-label="Search the wiki"
        placeholder="Search pages, documents and tickets…"
        value={q}
        onChange={(e) => setQ(e.target.value)}
      />
      {q.trim().length > 1 && (
        <ul className="flex flex-col rounded-xl border border-border bg-surface">
          {(hits.data ?? []).map((h) => (
            <li key={`${h.target.kind}:${h.target.id}`} className="border-b border-border-subtle last:border-0">
              <Link href={h.target.href ?? "#"} className="flex flex-col gap-0.5 px-3.5 py-2.5 hover:bg-row-hover">
                <span className="flex items-center gap-2 text-13 font-medium">
                  <TargetMark t={h.target} />
                  {h.target.display_id && <span className="font-mono text-12 text-fg-tertiary">{h.target.display_id}</span>}
                  <span className="truncate">{h.target.path ?? h.target.title}</span>
                </span>
                <span className="line-clamp-2 text-12 text-fg-secondary">
                  {h.snippet.split(/(«[^»]*»)/).map((part, i) =>
                    part.startsWith("«") ? (
                      <mark key={i} className="rounded-xs bg-pill-human-bg px-0.5 text-fg">
                        {part.slice(1, -1)}
                      </mark>
                    ) : (
                      part
                    ),
                  )}
                </span>
              </Link>
            </li>
          ))}
          {hits.data?.length === 0 && <li className="px-3.5 py-3 text-12 text-fg-tertiary">Nothing matches.</li>}
        </ul>
      )}
    </section>
  );
}

/** The Pattern index (?index=patterns) and ADR index (?index=adrs). */
function WikiIndexView({ index }: { index: WikiIndex }) {
  const [creating, setCreating] = useState(false);
  const label = index === "patterns" ? "Pattern index" : "ADR index";
  return (
    <WikiLayout
      current=""
      index={index}
      crumbs={[{ label: "Wiki", href: "/wiki" }, { label: index === "patterns" ? "Patterns" : "Architecture" }, { label }]}
      nativeActions={[{ id: "wiki.new", label: "New page", kind: "button", icon: "plus", showsLabel: true, accent: true, run: () => setCreating(true) }]}
      actions={
        <Button variant="primary" icon="plus" onClick={() => setCreating(true)}>
          New page
        </Button>
      }
    >
      <div className="flex min-w-0 flex-[999_1_480px] justify-center px-7 py-8 max-sm:px-4">
        <div className="flex w-full max-w-[var(--reading-max)] flex-col gap-7">{index === "patterns" ? <PatternsFinder index /> : <ADRIndex />}</div>
      </div>
      {creating && <NewPageDialog open onOpenChange={setCreating} folder={index === "patterns" ? "Patterns" : "Architecture"} />}
    </WikiLayout>
  );
}

/** The Export vault link, followed from the window's toolbar. */
function downloadVault() {
  const a = document.createElement("a");
  a.href = "/api/v1/wiki/export";
  a.download = "";
  a.click();
}

function WikiHome() {
  const tree = useWikiTree();
  const sugg = useWikiSuggestions();
  const [creating, setCreating] = useState(false);
  const pages = (tree.data?.pages ?? []).filter((p) => p.published);
  const recent = [...pages].sort((a, b) => b.updated_at.localeCompare(a.updated_at)).slice(0, 8);
  const agents = [...new Set(pages.filter((p) => p.path.startsWith("agents/")).map((p) => p.path.split("/")[1]))];
  return (
    <WikiLayout
      current=""
      crumbs={[{ label: "Wiki" }]}
      nativeActions={[
        { id: "wiki.export", label: "Export vault", kind: "button", icon: "download", showsLabel: true, run: downloadVault },
        { id: "wiki.new", label: "New page", kind: "button", icon: "plus", showsLabel: true, accent: true, run: () => setCreating(true) },
      ]}
      actions={
        <>
          <ButtonLink href="/api/v1/wiki/export" variant="outline" icon="download" prefetch={false}>
            Export vault
          </ButtonLink>
          <Button variant="primary" icon="plus" onClick={() => setCreating(true)}>
            New page
          </Button>
        </>
      }
    >
      <div className="flex min-w-0 flex-[999_1_480px] justify-center px-7 py-8 max-sm:px-4">
        <div className="flex w-full max-w-[var(--reading-max)] flex-col gap-7">
          <PageHeader
            title="Wiki"
            description={<>
              Runbooks, decisions and the context that never fit in a PRD, plus what agents learn while working. Link anything with{" "}
              <code className="inline">[[…]]</code>: pages, documents like <code className="inline">[[ADR-012]]</code>, tickets, epics and{" "}
              <code className="inline">[[@agents]]</code>.
            </>}
          />
          <WikiSearch />
          <PatternsFinder />

          {(sugg.data?.length ?? 0) > 0 && (
            <section className="flex flex-col gap-2.5">
              <h2 className="type-heading">Suggested by agents</h2>
              {sugg.data!.map((s) => (
                <SuggestionCard key={s.id} s={s} showPage />
              ))}
            </section>
          )}

          <section className="flex flex-col gap-2">
            <h2 className="type-heading">Recently updated</h2>
            {!tree.data ? (
              <Skeleton className="h-24 w-full" />
            ) : recent.length ? (
              <ul className="flex flex-col rounded-xl border border-border bg-surface">
                {recent.map((p) => (
                  <li key={p.id} className="border-b border-border-subtle last:border-0">
                    <Link href={wikiHref(p.path)} className="flex h-11 items-center gap-3 px-3.5 hover:bg-row-hover">
                      <ApiActorAvatar actor={p.author} />
                      <span className="flex min-w-0 flex-1 flex-col leading-tight">
                        <span className="truncate font-medium">{p.title}</span>
                        <span className="truncate text-12 text-fg-tertiary">{p.path}</span>
                      </span>
                      <span className="text-12 text-fg-tertiary" title={absoluteTime(p.updated_at)}>
                        {timelineTime(p.updated_at)}
                      </span>
                    </Link>
                  </li>
                ))}
              </ul>
            ) : (
              <EmptyState
                icon="wiki"
                title="No pages yet"
                actions={
                  <Button variant="primary" icon="plus" onClick={() => setCreating(true)}>
                    New page
                  </Button>
                }
              >
                Start with a runbook or a glossary. Agents add their own notes under Agent memory as they work.
              </EmptyState>
            )}
          </section>

          {agents.length > 0 && (
            <section className="flex flex-col gap-2">
              <h2 className="type-heading">Agent memory</h2>
              <p className="text-13 text-fg-secondary">
                Each agent keeps notes under <code className="inline">agents/&lt;handle&gt;/</code>. A run starts with the agent&apos;s Memory page and
                the notes linked to its ticket.
              </p>
              <div className="flex flex-wrap gap-2">
                {agents.map((h) => (
                  <ButtonLink key={h} href={wikiHref(`agents/${h}/Memory`)} variant="outline">
                    @{h}
                  </ButtonLink>
                ))}
              </div>
            </section>
          )}

          <section className="flex flex-wrap items-center gap-2 border-t border-border-subtle pt-5">
            <ImportButton />
            <span className="text-12 text-fg-tertiary">A zip of .md files, e.g. an Obsidian vault. Pages at the same path are replaced.</span>
          </section>
        </div>
      </div>
      {creating && <NewPageDialog open onOpenChange={setCreating} />}
    </WikiLayout>
  );
}

// ------------------------------------------------------------ page

function PageEditor({ page, onDone }: { page: Artifact; onDone: (newPath?: string) => void }) {
  const save = useSaveWikiPage(page.id);
  const [body, setBody] = useState(page.body_md ?? "");
  const [path, setPath] = useState(page.path ?? "");
  const dirty = body !== (page.body_md ?? "") || path !== page.path;
  const submit = () => {
    if (!dirty) return onDone();
    save.mutate(
      {
        body_md: body !== page.body_md ? body : undefined,
        path: path !== page.path ? path : undefined,
        base_version_id: page.current_version.id,
      },
      { onSuccess: (a) => onDone(a.path !== page.path ? a.path : undefined) },
    );
  };
  const conflict = save.error instanceof ApiError && save.error.status === 409;
  return (
    <form
      className="flex flex-col gap-3"
      onSubmit={(e) => {
        e.preventDefault();
        submit();
      }}
      onKeyDown={(e) => {
        if ((e.metaKey || e.ctrlKey) && e.key === "s") {
          e.preventDefault();
          submit();
        }
        if (e.key === "Escape" && !e.defaultPrevented) onDone();
      }}
    >
      <Field label="Path" htmlFor="page-path" hint="Moving a page keeps its links: the old path still resolves.">
        <TextInput id="page-path" value={path} onChange={(e) => setPath(e.target.value)} />
      </Field>
      <LinkEditor
        aria-label="Page content"
        autoFocus
        rows={22}
        value={body}
        onChange={setBody}
        placeholder={"# Title\n\nType [[ to link a page, ADR-012, a ticket like PAY-214, an epic or @agent."}
      />
      {save.isError && (
        <Banner
          tone="blocked"
          title={conflict ? "Someone saved this page while you were editing" : "Couldn't save"}
          actions={conflict ? <Button variant="outline" onClick={() => onDone()}>Discard my changes</Button> : undefined}
        >
          {conflict ? "Copy your changes, reload the page, and apply them again." : save.error.message}
        </Banner>
      )}
      <div className="flex items-center justify-between gap-2">
        <span className="text-12 text-fg-tertiary">
          Saving makes a new version silently. <Kbd>[[</Kbd> links
        </span>
        <div className="flex gap-2">
          <Button variant="ghost" onClick={() => onDone()}>
            Cancel
          </Button>
          <Button variant="primary" type="submit" hint="⌘S" disabled={save.isPending}>
            Save
          </Button>
        </div>
      </div>
    </form>
  );
}

/**
 * The page title is shown above the body, so a leading "# Title" heading
 * that repeats it is hidden. The line is blanked, not removed, so heading
 * anchors keep their source lines.
 */
function withoutTitle(md: string, title: string) {
  const m = /^\s*# +(.+?)\s*#*\s*$/m.exec(md.split("\n").find((l) => l.trim() !== "") ?? "");
  if (!m || m[1].trim().toLowerCase() !== title.toLowerCase()) return md;
  const i = md.indexOf(m[0].trim());
  return md.slice(0, i) + md.slice(i + m[0].trim().length);
}

function PageView({ path }: { path: string }) {
  const router = useRouter();
  const search = useSearchParams();
  const { data: page, error, isError } = useWikiPage(path);
  const sugg = useWikiSuggestions(page?.id);
  const [editing, setEditing] = useState(search.get("edit") === "1");
  const [creating, setCreating] = useState(false);
  const create = useCreateWikiPage();

  // Canonical URL: a renamed page's old path, or different casing.
  useEffect(() => {
    if (page?.path && page.path !== path && page.path.toLowerCase() !== path.toLowerCase()) router.replace(wikiHref(page.path));
  }, [page?.path, path, router]);

  // E edits, outside inputs.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement;
      if (editing || !page || e.metaKey || e.ctrlKey || e.altKey || t.closest("input, textarea, [contenteditable]")) return;
      if (e.key === "e") {
        e.preventDefault();
        setEditing(true);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [editing, page]);

  const missing = isError && error instanceof ApiError && error.status === 404;
  const compare = parseCompare(search.get("compare"));
  const startChat = useStartChat({ attach: { kind: "page", id: page?.id ?? "" }, title: page?.title ?? "", project: page?.project?.key });
  const header = pageHeader(page?.body_md ?? "");
  const folder = path.includes("/") ? path.slice(0, path.lastIndexOf("/")) : "";

  return (
    <WikiLayout
      current={page?.path ?? path}
      crumbs={crumbsFor(page?.path ?? path)}
      nativeActions={[
        { id: "wiki.new", label: "New page", kind: "button", icon: "plus", showsLabel: true, run: () => setCreating(true) },
        ...(page && !editing
          ? [
              { id: "wiki.chat", label: "Start chat", kind: "button" as const, icon: "msg", showsLabel: true, disabled: startChat.disabled, run: startChat.start },
              { id: "wiki.edit", label: "Edit", kind: "button" as const, icon: "edit", showsLabel: true, accent: true, run: () => setEditing(true) },
            ]
          : []),
      ]}
      actions={
        <>
          <Button variant="outline" icon="plus" onClick={() => setCreating(true)}>
            New page
          </Button>
          {page && !editing && (
            <StartChatButton attach={{ kind: "page", id: page.id }} title={page.title} project={page.project?.key} />
          )}
          {page && !editing && (
            <Button variant="secondary" icon="edit" hint="E" onClick={() => setEditing(true)}>
              Edit
            </Button>
          )}
        </>
      }
    >
      <article className="flex min-w-0 flex-[999_1_480px] justify-center px-7 py-8 max-sm:px-4">
        <div className="flex w-full max-w-[var(--reading-max)] flex-col gap-5">
          {missing ? (
            <EmptyState
              icon="wiki"
              title={`“${path.split("/").pop()}” doesn't exist yet`}
              actions={
                <Button
                  variant="primary"
                  icon="plus"
                  disabled={create.isPending}
                  onClick={() => create.mutate({ path, body_md: "" }, { onSuccess: () => setEditing(true) })}
                >
                  Create this page
                </Button>
              }
            >
              Links to it show as dashed ghosts until someone writes it.
            </EmptyState>
          ) : isError ? (
            <Banner tone="blocked" title="Couldn't load this page">
              {error.message}
            </Banner>
          ) : !page ? (
            <div aria-busy="true" className="flex flex-col gap-4">
              <Skeleton className="h-7 w-2/3" />
              <Skeleton className="h-3 w-full" />
              <Skeleton className="h-3 w-5/6" />
            </div>
          ) : (
            <>
              <div className="flex flex-col gap-2">
                {folder && <span className="text-12 text-fg-tertiary">{folder}</span>}
                <h1 className="type-display">{page.title}</h1>
                <span className="flex flex-wrap items-center gap-2 text-12 text-fg-tertiary">
                  <ApiActorAvatar actor={page.current_version.created_by} />
                  {page.current_version.created_by.name} · {page.current_version.label} ·{" "}
                  <span title={absoluteTime(page.updated_at)}>{timelineTime(page.updated_at)}</span>
                </span>
              </div>
              {(sugg.data ?? []).map((s) => (
                <SuggestionCard key={s.id} s={s} />
              ))}
              <div className="border-t border-border-subtle pt-5">
                {compare && !editing ? (
                  <VersionDiff page={page} from={compare[0]} to={compare[1]} />
                ) : editing ? (
                  <PageEditor
                    key={page.current_version.id}
                    page={page}
                    onDone={(moved) => {
                      setEditing(false);
                      if (moved) router.replace(wikiHref(moved));
                      else if (search.get("edit")) router.replace(wikiHref(page.path ?? path));
                    }}
                  />
                ) : header.body.trim() ? (
                  <Markdown anchors className="type-reading text-fg-2">
                    {withoutTitle(header.body, page.title)}
                  </Markdown>
                ) : (
                  <p className="text-14 text-fg-tertiary">
                    This page is empty.{" "}
                    <button type="button" className="text-accent hover:underline" onClick={() => setEditing(true)}>
                      Write it
                    </button>
                  </p>
                )}
              </div>
            </>
          )}
        </div>
      </article>

      {page && (
        <aside aria-label="Page details" className="flex flex-[1_1_280px] flex-col gap-6 border-l border-border-subtle bg-panel px-5 py-6 lg:max-w-[340px]">
          <TagsSection topic={header.topic} tags={header.tags} />
          <PanelSection title="Backlinks">
            <BacklinksPanel kind="artifact" id={page.id} />
          </PanelSection>
          <LinkedTickets page={page} />
          <CitedBy id={page.id} />
          <History page={page} />
          {page.outline.length > 1 && (
            <PanelSection title="Outline">
              <ol>
                {page.outline.map((s) => (
                  <li key={s.id}>
                    <a
                      href={`#${s.anchor}`}
                      className="flex min-h-[26px] items-center gap-2 rounded-sm text-13 hover:bg-hover"
                      style={{ paddingLeft: (s.level - 1) * 12 }}
                      title={s.citations > 0 ? `Cited ${s.citations} times` : undefined}
                    >
                      <span className={cx("flex-1 truncate", s.level === 1 && "font-medium")}>{s.heading}</span>
                      {s.citations > 0 && <span className="font-mono text-12 text-fg-secondary">{s.citations}</span>}
                    </a>
                  </li>
                ))}
              </ol>
            </PanelSection>
          )}
          <PanelSection title="Local graph" icon="graph">
            <LocalGraph kind="artifact" id={page.id} />
          </PanelSection>
        </aside>
      )}
      {creating && <NewPageDialog open onOpenChange={setCreating} folder={folder} />}
    </WikiLayout>
  );
}

function WikiRoot() {
  const index = useSearchParams().get("index");
  return index === "patterns" || index === "adrs" ? <WikiIndexView index={index} /> : <WikiHome />;
}

export function WikiScreen({ path }: { path: string }) {
  return path ? <PageView key={path.toLowerCase()} path={path} /> : <WikiRoot />;
}
