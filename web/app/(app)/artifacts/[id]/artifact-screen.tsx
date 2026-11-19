"use client";

import Link from "next/link";
import { useRouter, useSearchParams } from "next/navigation";
import { useEffect, useState } from "react";
import { contentUrl, type Artifact } from "@/lib/api/client";
import { useArtifact, useArtifactVersionBody, useUpdateArtifact } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { fileKind, formatBytes } from "@/lib/files";
import { absoluteTime, timelineTime } from "@/lib/format";
import { Button, ButtonLink } from "@/components/ui/button";
import { Banner, EmptyState, Skeleton, TextArea } from "@/components/ui/primitives";
import { AgentAvatar } from "@/components/domain/avatars";
import { artifactTitle } from "@/components/domain/artifacts";
import { NewVersionDialog } from "@/components/domain/artifact-dialogs";
import { BacklinksPanel } from "@/components/domain/backlinks";
import { StatusGlyph } from "@/components/domain/glyphs";
import { DocTypeTag } from "@/components/domain/labels";
import { Markdown } from "@/components/domain/markdown";
import { PdfViewer } from "@/components/domain/pdf-viewer";
import { printHref } from "@/components/domain/print-mode";
import { isPdfContentType } from "@/lib/pdf-viewer";
import { ReviewChip } from "@/components/domain/mockup";
import { MockupEditor } from "./mockup-editor";
import { MockupReviewBanner, MockupViewer } from "./mockup-parts";
import { wikiHref } from "@/lib/wikilinks";
import { useStartChat } from "@/components/domain/start-chat";
import { toast } from "@/lib/toast";
import { buildArtifactActions } from "@/lib/native-shell/models/mockup-editor";
import { TopBar } from "@/components/shell/topbar";

function FileView({ a, versionId }: { a: Artifact; versionId: string }) {
  const v = a.versions.find((x) => x.id === versionId) ?? a.current_version;
  const c = v.content;
  const src = contentUrl(a.id, v.id);
  if (c.content_type.startsWith("image/")) {
    return (
      // user uploads, served by the API
      <img src={src} alt={a.title} className="max-h-[70vh] w-full rounded-xl border border-border bg-surface object-contain" />
    );
  }
  // Only MP4 is served inline (inlineSafe in the API); other video types download.
  if (c.content_type === "video/mp4") {
    return <video src={src} controls preload="metadata" className="max-h-[70vh] w-full rounded-xl border border-border bg-black" aria-label={a.title} />;
  }
  if (isPdfContentType(c.content_type)) {
    return <PdfViewer url={src} title={a.title} heightClass="h-[75vh]" downloadUrl={contentUrl(a.id, v.id, true)} />;
  }
  return (
    <EmptyState icon="artifacts" title={c.filename ?? a.title} actions={<ButtonLink href={contentUrl(a.id, v.id, true)} variant="outline" icon="download">Download</ButtonLink>}>
      {fileKind(c.content_type, c.filename)} · {formatBytes(c.size_bytes)}. This file type can&apos;t be previewed here.
    </EmptyState>
  );
}

function SummaryEditor({ a }: { a: Artifact }) {
  const update = useUpdateArtifact(a.id);
  const [draft, setDraft] = useState<string | null>(null);
  if (draft === null) {
    return (
      <button type="button" onClick={() => setDraft(a.summary)} className="-mx-1 rounded-md px-1 text-left text-14 leading-relaxed text-fg-secondary hover:bg-hover">
        {a.summary || <span className="text-fg-tertiary">Add a summary…</span>}
      </button>
    );
  }
  const save = () => {
    if (draft !== a.summary) update.mutate({ summary: draft });
    setDraft(null);
  };
  return (
    <div className="flex flex-col gap-2">
      <TextArea aria-label="Summary" autoFocus rows={3} value={draft} onChange={(e) => setDraft(e.target.value)} onKeyDown={(e) => {
        if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) save();
        if (e.key === "Escape") setDraft(null);
      }} />
      <div className="flex justify-end gap-2">
        <Button variant="ghost" onClick={() => setDraft(null)}>Cancel</Button>
        <Button variant="primary" onClick={save} hint="⌘↵">Save</Button>
      </div>
    </div>
  );
}

export function ArtifactScreen({ id }: { id: string }) {
  const { data: a, isError, error } = useArtifact(id);
  const search = useSearchParams();
  // ?version=<id> deep-links to one version (chat Sources use it).
  const [versionId, setVersionId] = useState<string | null>(search.get("version"));
  const [versioning, setVersioning] = useState(false);
  const viewing = a?.versions.find((v) => v.id === versionId) ?? a?.current_version;
  const old = useArtifactVersionBody(a, versionId);
  const isOld = !!a && !!viewing && viewing.id !== a.current_version.id;
  const router = useRouter();
  const isMockup = a?.type === "mockup";
  const editing = isMockup && search.get("edit") === "1";
  const setEditing = (on: boolean) => router.push(on ? `/artifacts/${id}?edit=1` : `/artifacts/${id}`);
  const chat = useStartChat({ attach: { kind: a?.type === "note" ? "page" : "artifact", id: id }, title: a ? artifactTitle(a) : "", project: a?.project?.key });

  // Wiki pages live at /wiki/<path>; this screen still serves their full
  // version history (?versions=1).
  useEffect(() => {
    if (a?.type === "note" && a.path && !search.get("versions")) router.replace(wikiHref(a.path));
  }, [a?.type, a?.path, search, router]);

  // Jump to #anchor once the body has rendered.
  useEffect(() => {
    if (!a || !window.location.hash) return;
    document.getElementById(decodeURIComponent(window.location.hash.slice(1)))?.scrollIntoView();
  }, [a]);

  if (isError) {
    const missing = "status" in error && error.status === 404;
    return (
      <>
        <TopBar crumbs={[{ label: "Library", href: "/library?source=projects" }, { label: "Not found" }]} />
        {missing ? (
          <EmptyState icon="artifacts" title="This artifact doesn't exist" actions={<ButtonLink href="/library?source=projects" variant="outline">Library</ButtonLink>}>
            It may have been removed, or the link is wrong.
          </EmptyState>
        ) : (
          <div className="p-6"><Banner tone="blocked" title="Couldn't load this artifact">{error.message}</Banner></div>
        )}
      </>
    );
  }

  const body = isOld ? old.data : a?.body_md;
  // The Mac app's toolbar takes these; there the page draws no buttons (and so no "no harness" note, which becomes the toast).
  const nativeActions =
    a && viewing && !editing
      ? buildArtifactActions({
          isMockup,
          canExportPdf: !isMockup && viewing.content.kind === "markdown",
          review: () => router.push(`/artifacts/${a.id}/review${isOld ? `?version=${viewing.id}` : ""}`),
          edit: () => setEditing(true),
          startChat: {
            disabled: chat.create.isPending,
            run: () =>
              chat.noHarness
                ? toast({ title: "No harness is available", description: "Add a secret in Settings to start a chat.", tone: "error", action: { label: "Settings", onClick: () => router.push("/settings#secrets") } })
                : chat.start(),
          },
          download: () => window.location.assign(contentUrl(a.id, viewing.id, true)),
          exportPdf: () => window.open(printHref(a.id, isOld ? viewing.id : null), "_blank"),
          newVersion: () => setVersioning(true),
        })
      : undefined;

  return (
    <>
      <TopBar
        nativeActions={nativeActions}
        nativeTitle={a && editing ? { title: artifactTitle(a), subtitle: "Editing" } : undefined}
        crumbs={
          a
            ? [
                ...(a.project ? [{ label: a.project.name, swatch: a.project.color }] : []),
                a.type === "note" && a.path
                  ? { label: "Wiki", href: wikiHref(a.path) }
                  : { label: "Library", href: "/library?source=projects" },
                editing ? { label: artifactTitle(a), href: `/artifacts/${a.id}` } : { label: artifactTitle(a) },
                ...(editing ? [{ label: "Edit" }] : []),
              ]
            : [{ label: "Library", href: "/library?source=projects" }, { label: "…" }]
        }
      />
      {!a || !viewing ? (
        <div aria-busy="true" className="mx-auto flex w-full max-w-[var(--reading-max)] flex-col gap-4 px-7 py-10">
          <Skeleton className="h-7 w-2/3" />
          <Skeleton className="h-3 w-full" />
          <Skeleton className="h-3 w-5/6" />
        </div>
      ) : editing ? (
        <MockupEditor key={a.id} a={a} onDone={() => setEditing(false)} />
      ) : (
        <div className="flex flex-1 flex-wrap">
          <article className="flex min-w-0 flex-[999_1_480px] justify-center px-7 py-8 max-sm:px-4">
            <div className="flex w-full max-w-[var(--reading-max)] flex-col gap-5">
              <div className="flex flex-col gap-2">
                <div className="flex items-center gap-2">
                  <DocTypeTag type={a.type} />
                  <span className="font-mono text-12 text-fg-tertiary">{viewing.label}</span>
                </div>
                <h1 className="type-display">{artifactTitle(a)}</h1>
                <SummaryEditor a={a} />
              </div>
              {isOld && (
                <Banner tone="human" title={`Viewing ${viewing.label}, not the current version`} actions={<Button variant="outline" onClick={() => setVersionId(null)}>Back to {a.current_version.label}</Button>}>
                  Agents always read the current version ({a.current_version.label}).
                </Banner>
              )}
              {isMockup && <MockupReviewBanner a={a} versionId={viewing.id} isOld={isOld} />}
              <div className="border-t border-border-subtle pt-5">
                {isMockup ? (
                  <MockupViewer title={a.title} source={body ?? undefined} />
                ) : viewing.content.kind === "file" ? (
                  <FileView a={a} versionId={viewing.id} />
                ) : body == null ? (
                  <Skeleton className="h-3 w-1/2" />
                ) : (
                  <Markdown anchors visualBlocks className="type-reading text-fg-2">{body}</Markdown>
                )}
              </div>
            </div>
          </article>

          <aside aria-label="Artifact details" className="flex flex-[1_1_300px] flex-col gap-6 border-l border-border-subtle bg-panel px-5 py-6 lg:max-w-[340px]">
            {!isMockup && a.outline.length > 0 && !isOld && (
              <section className="flex flex-col gap-1">
                <h2 className="text-13 text-fg-tertiary">Outline · citations</h2>
                <ol>
                  {a.outline.map((s) => (
                    <li key={s.id}>
                      <a href={`#${s.anchor}`} className="flex min-h-[26px] items-center gap-2 rounded-sm text-13 hover:bg-hover" style={{ paddingLeft: (s.level - 1) * 12 }}>
                        <span className={cx("flex-1 truncate", s.level === 1 && "font-medium")}>{s.heading}</span>
                        <span className={cx("font-mono text-12", s.citations ? "text-fg-secondary" : "text-fg-tertiary")} aria-label={`${s.citations} citations`}>
                          {s.citations || ""}
                        </span>
                      </a>
                    </li>
                  ))}
                </ol>
              </section>
            )}

            <section className="flex flex-col gap-2">
              <h2 className="text-13 text-fg-tertiary">Read by</h2>
              {a.read_by.length ? (
                <ul className="flex flex-col gap-1.5">
                  {a.read_by.map((r) => (
                    <li key={r.agent.id} className="flex items-center gap-2 text-13">
                      <AgentAvatar name={r.agent.name} colorIndex={r.agent.color_index} label={false} />
                      <span className="flex-1">{r.agent.name}</span>
                      <span className="font-mono text-12 text-fg-tertiary" title={`Last read ${absoluteTime(r.last_read_at)}`}>
                        {r.reads} reads
                      </span>
                    </li>
                  ))}
                </ul>
              ) : (
                <p className="text-12 text-fg-tertiary">No agent has read this yet.</p>
              )}
            </section>

            <section className="flex flex-col gap-2">
              <h2 className="text-13 text-fg-tertiary">Backlinks</h2>
              <BacklinksPanel kind="artifact" id={a.id} />
            </section>

            <section className="flex flex-col gap-1">
              <h2 className="text-13 text-fg-tertiary">Tickets</h2>
              {a.tickets.length ? (
                a.tickets.map((t) => (
                  <Link key={t.key} href={`/tickets/${t.key}`} className="flex h-7 items-center gap-2 rounded-sm text-13 hover:bg-hover">
                    <StatusGlyph state={t.status} size={12} surface="var(--bg-panel)" label={false} />
                    <span className="w-16 font-mono text-12 text-fg-tertiary">{t.key}</span>
                    <span className="flex-1 truncate">{t.title}</span>
                  </Link>
                ))
              ) : (
                <p className="text-12 text-fg-tertiary">Not attached to any ticket. Attach it from a ticket&apos;s Context artifacts.</p>
              )}
            </section>

            <section className="flex flex-col gap-1">
              <h2 className="text-13 text-fg-tertiary">History</h2>
              <ol className="flex flex-col">
                {a.versions.map((v) => {
                  const on = v.id === viewing.id;
                  return (
                    <li key={v.id}>
                      <button
                        type="button"
                        aria-current={on ? "true" : undefined}
                        onClick={() => setVersionId(v.id === a.current_version.id ? null : v.id)}
                        className={cx("flex w-full flex-col rounded-md px-2 py-1.5 text-left hover:bg-hover", on && "bg-selected")}
                      >
                        <span className="flex items-center gap-2 text-13">
                          <span className="font-mono text-12">{v.label}</span>
                          {v.id === a.current_version.id && <span className="text-11 text-pill-done-fg">current</span>}
                          {v.review && <ReviewChip state={v.review.state} />}
                          <span className="ml-auto text-12 text-fg-tertiary" title={absoluteTime(v.created_at)}>{timelineTime(v.created_at)}</span>
                        </span>
                        <span className="truncate text-12 text-fg-tertiary">
                          {v.created_by.name}
                          {v.note && ` · ${v.note}`}
                        </span>
                      </button>
                    </li>
                  );
                })}
              </ol>
            </section>
            {(a.type === "prd" || a.type === "spec") && a.project && <ButtonLink variant="secondary" href={`/plans?artifact=${a.id}&project=${a.project.key}`}>Generate tickets</ButtonLink>}
          </aside>
        </div>
      )}
      {versioning && a && <NewVersionDialog artifact={a} open onOpenChange={setVersioning} />}
    </>
  );
}
