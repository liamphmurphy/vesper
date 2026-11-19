"use client";

import { useRecordVisit } from "@/components/shell/use-record-visit";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ContextMenu, Dialog } from "radix-ui";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { cx } from "@/lib/cx";
import { defaultLabel, parseWikiLinks } from "@/lib/wikilinks";
import { pageHref, restoreObsidianSyntax, visibleProperties, wordCount } from "@/lib/knowledge";
import { KnowledgeSyntax } from "@/lib/knowledge-editor";
import { KnowledgeCompletion } from "@/lib/knowledge-completion";
import { api, unwrap } from "@/lib/api/client";
import { fetchKnowledgeImages, usePage, usePages, useSavePage, useSavedQuery, type Embed, type Page } from "@/lib/api/knowledge-hooks";
import { useChat, useSendChatMessage } from "@/lib/api/hooks";
import { downloadFile } from "@/lib/api/docs-hooks";
import { floatPanel } from "@/components/domain/pickers";
import { Markdown } from "@/components/domain/markdown";
import { PdfViewer } from "@/components/domain/pdf-viewer";
import { isPdfContentType, pdfDownloadUrl } from "@/lib/pdf-viewer";
import { Icon } from "@/components/ui/icon";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { toast } from "@/lib/toast";
import { DocEditor, type DocEditorHandle, type SaveState } from "@/app/(app)/apps/docs/_components/doc-editor";
import { DeckScreen } from "@/app/(app)/apps/slides/_components/deck-screen";
import { DesignEditor } from "@/app/(app)/apps/designs/_components/design-editor";
import { StatusBar, Tag } from "./kit";
import { personaLook } from "@/app/(app)/chat/_components/persona";
import { ReviewBar, ReviewList, undecided } from "./page-review";
import { QueryTable } from "./query-table";
import { useKnowledgeTab } from "./shell";
import { useKnowledgeChat } from "./chat-context";
import { useNativeTitle } from "../../tickets/_components/native-title";
import { useNativeActions } from "@/lib/native-shell/use-native-actions";
import { knowledgePageActions } from "@/lib/native-shell/models/knowledge-page";
import { navAvatar, pageOrigin } from "@/lib/native-shell/models/common";

const SAVE_LABEL: Record<SaveState, string> = { saved: "Saved", unsaved: "Unsaved changes", saving: "Saving…", conflict: "Changed elsewhere", error: "Not saved" };
const item = "flex cursor-default select-none items-start gap-2.5 rounded-md px-2 py-2 outline-none data-[highlighted]:bg-hover data-[disabled]:opacity-50";

/** One Knowledge page: properties, the live-preview editor, persona changes to review, and the sidebar. */
export function PageScreen({ id }: { id: string }) {
  const q = usePage(id);
  const p = q.data;
  // A deck or design page registers as one, so the shell gives its editor the column and the companion.
  useKnowledgeTab(p ? { id: p.id, title: p.title, kind: p.kind === "deck" || p.kind === "design" ? p.kind : "page" } : undefined);
  useRecordVisit(p ? { id: `page-${p.id}`, title: p.title || "Untitled", meta: p.path ?? undefined, href: pageHref(p.id, p.title), kind: "Pages" } : undefined);
  if (q.error)
    return (
      <div className="p-8">
        <Banner tone="blocked" title="This page isn't available">
          It may have been deleted, or it&apos;s private to someone else.{" "}
          <Link href="/knowledge" className="underline">
            Back to Knowledge
          </Link>
        </Banner>
      </div>
    );
  if (!p)
    return (
      <div className="mx-auto w-full max-w-[680px] space-y-4 px-6 pt-16">
        <Skeleton className="h-9 w-1/2" />
        <Skeleton className="h-4 w-full" />
        <Skeleton className="h-4 w-5/6" />
      </div>
    );
  // A deck or design page is its editor, opened here (LAZYAGENTS-212); the canvas is its body.
  if (p.canvas_id && p.kind === "deck") return <DeckScreen key={p.id} id={p.canvas_id} />;
  if (p.canvas_id && p.kind === "design") return <DesignEditor key={p.id} id={p.canvas_id} />;
  return <Loaded key={p.id} page={p} />;
}

function Loaded({ page: p }: { page: Page }) {
  const { ask, registerDraft, openPanel } = useKnowledgeChat();
  const router = useRouter();
  const save = useSavePage(p.id);
  const chat = useChat(p.chat_id ?? undefined).data;
  const running = chat?.state === "running";
  const persona = (chat?.speaker ?? chat?.persona)?.name ?? "Persona";
  const send = useSendChatMessage(p.chat_id ?? "");
  const [state, setState] = useState<{ s: SaveState; message?: string }>({ s: "saved" });
  const editor = useRef<DocEditorHandle>(null);
  const selected = useRef<string | undefined>(undefined);
  useEffect(() => registerDraft(p.id, () => {
    const md = editor.current?.getMarkdown();
    return md === undefined ? undefined : restoreObsidianSyntax(md);
  }), [p.id, registerDraft]);
  const query = useSavedQuery(p.id, !!p.properties.query);
  const pendingCount = undecided(p).length;

  // The editor speaks in version numbers; the API wants version ids.
  const idOf = useMemo(() => new Map(p.versions.map((v) => [v.seq, v.id])), [p.versions]);

  // Titles of pages that exist, so [[links]] to nothing yet read faded. The
  // editor reads them once, on mount, so it waits for them (or their failure).
  const titles = usePages({ limit: 200, include_agent: true });
  const known = useMemo(() => new Set((titles.data?.rows ?? []).flatMap((r) => [r.title.toLowerCase(), r.path.toLowerCase()])), [titles.data]);
  const previewData = useRef({ known, rows: titles.data?.rows, embeds: p.embeds });
  const refreshPreview = useRef(() => {});
  const [inlinePreviews, setInlinePreviews] = useState<Map<Node, { dom: HTMLElement; embed: Embed; key: number }>>(new Map());
  const previewKey = useRef(0);
  const extensions = useMemo(
    () => [
      // configure stores these callbacks; ProseMirror reads their refs after mount.
      // eslint-disable-next-line react-hooks/refs
      KnowledgeSyntax.configure({
        subscribe: (refresh) => {
          refreshPreview.current = refresh;
          return () => { refreshPreview.current = () => {}; };
        },
        isResolved: (t) => previewData.current.known.size === 0 || previewData.current.known.has(t.toLowerCase()) || /^[A-Z]+-\d+$/.test(t),
        title: (t) => previewData.current.rows?.find((r) => r.path.toLowerCase() === t.toLowerCase() || r.title.toLowerCase() === t.toLowerCase())?.title,
        preview: (raw) => {
          const e = previewData.current.embeds.find((e) => e.ref === raw);
          if (!e?.available) return undefined;
          return {
            key: JSON.stringify(e),
            mount: () => {
              const dom = document.createElement("span");
              dom.className = "kn-inline-preview";
              dom.contentEditable = "false";
              const key = ++previewKey.current;
              queueMicrotask(() => setInlinePreviews((prev) => new Map(prev).set(dom, { dom, embed: e, key })));
              return dom;
            },
            destroy: (dom) => {
              queueMicrotask(() => setInlinePreviews((prev) => {
                const next = new Map(prev);
                next.delete(dom);
                return next;
              }));
            },
            stopEvent: (event) => event.target instanceof Element && !!event.target.closest("[data-pdf-viewer], [data-pdf-embed]"),
          };
        },
        onOpen: (raw) => {
          const ref = parseWikiLinks(raw)[0]?.ref;
          if (!ref) return;
          void unwrap(api.GET("/knowledge/resolve", { params: { query: { ref: [ref] } } })).then(({ links }) => {
            const target = links[0]?.target;
            if (!target?.href || target.kind === "unresolved") {
              toast({ title: "This linked page isn’t available", tone: "error" });
              return;
            }
            const href = target.artifact_type === "note" && target.id
              ? pageHref(target.id, target.title) + (target.anchor ? `#${encodeURIComponent(target.anchor)}` : "")
              : target.href;
            router.push(href);
          }).catch((error: Error) => toast({ title: "Couldn’t open the linked page", description: error.message, tone: "error" }));
        },
      }),
      KnowledgeCompletion.configure({
        search: async (q, signal, image) => {
          if (image) {
            const result = await fetchKnowledgeImages(q, signal);
            return result.images.filter((i) => i.content_type.startsWith("image/"))
              .map((i) => ({ title: i.title, ref: i.ref, detail: i.content_type }));
          }
          const result = await unwrap(api.GET("/knowledge/suggest", { params: { query: { q, include_agent: true } }, signal }));
          return result.targets.filter((t) => t.kind === "artifact" && t.artifact_type === "note" && t.path && t.id)
            .map((t) => ({ title: t.title, ref: t.path!, detail: t.path! }));
        },
      }),
    ],
    [router],
  );
  useLayoutEffect(() => {
    previewData.current = { known, rows: titles.data?.rows, embeds: p.embeds };
    refreshPreview.current();
  }, [known, titles.data, p.embeds, extensions]);

  const onSave = async (body: string, baseSeq: number) => {
    const next = await save.mutateAsync({ body_md: restoreObsidianSyntax(body), base_version_id: idOf.get(baseSeq) });
    return next.seq;
  };
  const setProps = (properties: Page["properties"]) => save.mutate({ properties, base_version_id: p.version_id });
  const rename = (title: string) => title.trim() && title.trim() !== p.title && save.mutate({ title: title.trim() });

  const crumbs = (p.path ?? p.title).split("/");
  const body = p.body_md ?? "";
  const modeLabel = p.paused ? "Persona edits paused" : p.direct ? `${persona} edits directly` : `${persona} suggests changes`;
  const look = personaLook(chat?.speaker ?? chat?.persona);
  const copyLink = () => void navigator.clipboard?.writeText(`[[${p.path ?? p.title}]]`);

  // In the Mac app the header row's controls are window toolbar items and the page is the window's
  // (and so its tab's) title; the folder path sits above the title.
  useNativeTitle(p.title || "Untitled");
  useNativeActions(
    knowledgePageActions({
      audience: p.audience,
      setAudience: (audience) => save.mutate({ audience }),
      mode: { label: modeLabel, avatar: navAvatar(look.name, look.color, look.avatar_url, pageOrigin()), open: () => openPanel("history") },
      copyLink,
      exportMarkdown: () => exportMarkdown(p),
      print: () => window.print(),
      history: () => openPanel("history"),
    }),
  );

  return (
    <div className="flex min-h-0 flex-1">
      {[...inlinePreviews.values()].map(({ dom, embed, key }) => createPortal(<EmbedPreview embed={embed} />, dom, key))}
      <div className="flex min-w-0 flex-1 flex-col">
        <ReviewBar page={p} persona={persona} direct={p.direct} />
        <div className="min-h-0 flex-1 overflow-y-auto">
          <article className="mx-auto w-full max-w-[720px] px-8 pb-24 pt-8">
            {crumbs.length > 1 && (
              <nav aria-label="Folder" className="mb-2 truncate text-12 text-fg-tertiary">
                {crumbs.slice(0, -1).join("  /  ")}
              </nav>
            )}
            <TitleField key={p.title} title={p.title} onRename={rename} />
            <PropertiesBlock properties={p.properties} onChange={setProps} />
            {!!p.properties.query && (
              <div className="mb-8">
                {query.data ? <QueryTable table={query.data} /> : query.error ? <p className="text-12 text-state-blocked">{query.error.message}</p> : <Skeleton className="h-24 w-full" />}
              </div>
            )}
            <ReviewList page={p} direct={p.direct} />
            {state.s === "conflict" && (
              <div className="mb-4">
              <Banner tone="human" title="This page changed while you were editing">
                <button className="underline" onClick={() => void editor.current?.keepMine(p.seq)}>
                  Keep my version
                </button>{" "}
                or{" "}
                <button className="underline" onClick={() => editor.current?.takeTheirs(p.seq, body)}>
                  take the latest
                </button>
                .
              </Banner>
              </div>
            )}
            <ContextMenu.Root>
            <ContextMenu.Trigger asChild>
            <div className="kn-editor" onContextMenuCapture={(e) => {
              const selection = window.getSelection();
              selected.current = selection?.anchorNode && selection.focusNode && e.currentTarget.contains(selection.anchorNode) && e.currentTarget.contains(selection.focusNode)
                ? selection.toString() || undefined : undefined;
            }}>
              {titles.isPending ? (
                <Skeleton className="h-40 w-full" />
              ) : (
                <DocEditor
                ref={editor}
                body={body}
                seq={p.seq}
                locked={running || pendingCount > 0}
                persona={persona}
                highlights={[]}
                extensions={extensions}
                firstLine="Start writing. [[ links, # tags, ![[ embeds"
                onSave={onSave}
                onState={(s, message) => setState({ s, message })}
                onAsk={(instruction, after) => p.chat_id && send.mutate({ body: `On the Knowledge page [[${p.path ?? p.title}]], after “${after.slice(-120)}”: ${instruction}` })}
                onPick={() => {}}
              />
              )}
            </div>
            </ContextMenu.Trigger>
            <ContextMenu.Portal>
              <ContextMenu.Content collisionPadding={8} onCloseAutoFocus={(e) => e.preventDefault()} className={cx(floatPanel, "min-w-[180px]")}>
                <ContextMenu.Item className={item} onSelect={() => ask(p, selected.current)}>
                  <Icon name="msg" size={14} /> Ask a Persona
                </ContextMenu.Item>
                <ContextMenu.Item className={item} onSelect={() => { if (selected.current) void navigator.clipboard?.writeText(selected.current); }}>
                  Copy selection
                </ContextMenu.Item>
              </ContextMenu.Content>
            </ContextMenu.Portal>
            </ContextMenu.Root>
          </article>
        </div>
        <StatusBar
          left={pendingCount > 0 ? `${pendingCount} persona ${pendingCount === 1 ? "change" : "changes"} to review before editing` : running ? `${persona} is working on this page` : modeLabel}
          right={
            <>
              <span>{wordCount(body)} words</span>
              <span className={cx(state.s === "error" || state.s === "conflict" ? "text-state-blocked" : undefined)} title={state.message}>
                {SAVE_LABEL[state.s]}
              </span>
            </>
          }
        />
      </div>
    </div>
  );
}

function TitleField({ title, onRename }: { title: string; onRename: (t: string) => void }) {
  // Keyed by the title, so a rename from elsewhere resets the field.
  const [value, setValue] = useState(title);
  return (
    <input
      value={value}
      onChange={(e) => setValue(e.target.value)}
      onBlur={() => onRename(value)}
      onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
      aria-label="Title"
      placeholder="Untitled"
      className="mb-5 w-full bg-transparent text-28 font-bold tracking-[-0.02em] text-fg outline-none placeholder:text-fg-tertiary"
    />
  );
}

/** Obsidian's properties: one row per key; tags as pills, links as links; add, change or remove one. */
function PropertiesBlock({ properties, onChange }: { properties: Page["properties"]; onChange: (p: Page["properties"]) => void }) {
  const rows = visibleProperties(properties);
  const [adding, setAdding] = useState(false);
  const [key, setKey] = useState("");
  const [value, setValue] = useState("");
  const add = () => {
    const k = key.trim();
    if (!k) return;
    const v = value.trim();
    const list = k === "tags" || k === "aliases" ? v.split(/[,\s]+/).filter(Boolean).map((t) => t.replace(/^#/, "")) : v;
    onChange({ ...properties, [k]: list });
    setKey("");
    setValue("");
    setAdding(false);
  };
  if (!rows.length && !adding)
    return (
      <button onClick={() => setAdding(true)} className="mb-6 flex items-center gap-1.5 text-12 text-fg-tertiary hover:text-fg-secondary">
        <Icon name="plus" size={12} /> Add property
      </button>
    );
  return (
    <section aria-label="Properties" className="mb-6 border-b border-border-subtle pb-4">
      <p className="mb-2 text-12 font-semibold text-fg-tertiary">Properties</p>
      <dl className="space-y-1">
        {rows.map(([k, v]) => (
          <div key={k} className="group grid grid-cols-[140px_1fr_20px] items-center gap-2 rounded-md py-1 hover:bg-hover/50">
            <dt className="flex items-center gap-2 text-13 text-fg-tertiary">
              <Icon name={k === "tags" ? "bookmark" : Array.isArray(v) ? "epics" : "edit"} size={13} />
              {k}
            </dt>
            <dd className="flex flex-wrap items-center gap-1.5 text-13 text-fg-2">
              {Array.isArray(v) ? v.map((x, i) => (k === "tags" ? <Tag key={i}>#{String(x)}</Tag> : <span key={i}>{String(x)}</span>)) : <PropValue v={v} />}
            </dd>
            <button
              aria-label={`Remove ${k}`}
              onClick={() => {
                const next = { ...properties };
                delete next[k];
                onChange(next);
              }}
              className="grid size-5 place-items-center rounded text-fg-tertiary opacity-0 hover:bg-hover group-hover:opacity-100"
            >
              <Icon name="x" size={11} />
            </button>
          </div>
        ))}
      </dl>
      {adding ? (
        <div className="mt-2 flex items-center gap-2">
          <input autoFocus value={key} onChange={(e) => setKey(e.target.value)} placeholder="property" aria-label="Property name" className="h-7 w-32 rounded-md border border-border-strong bg-surface-sunken px-2 text-12 text-fg outline-none focus:border-accent" />
          <input
            value={value}
            onChange={(e) => setValue(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && add()}
            placeholder={key === "tags" ? "campaign, saltmere" : "value"}
            aria-label="Property value"
            className="h-7 flex-1 rounded-md border border-border-strong bg-surface-sunken px-2 text-12 text-fg outline-none focus:border-accent"
          />
          <button onClick={add} className="text-12 font-medium text-accent">
            Add
          </button>
        </div>
      ) : (
        <button onClick={() => setAdding(true)} className="mt-1 flex items-center gap-1.5 text-12 text-fg-tertiary hover:text-fg-secondary">
          <Icon name="plus" size={12} /> Add property
        </button>
      )}
    </section>
  );
}

function PropValue({ v }: { v: unknown }) {
  const s = typeof v === "object" ? JSON.stringify(v) : String(v);
  const link = /^\[\[(.+)\]\]$/.exec(s);
  if (link) {
    const ref = parseWikiLinks(s)[0];
    return <span className="font-medium text-accent">{ref ? defaultLabel(ref) : link[1]}</span>;
  }
  if (/^https?:\/\//.test(s))
    return (
      <a href={s} target="_blank" rel="noreferrer" className="truncate text-accent underline">
        {s}
      </a>
    );
  return <span>{s}</span>;
}

/** A resolved ![[…]] preview, mounted at its position inside the editor. */
function EmbedPreview({ embed: e }: { embed: Embed }) {
  const [viewerOpen, setViewerOpen] = useState(false);
  const [page, setPage] = useState(1);

  if (e.url && (e.kind === "image" || e.content_type?.startsWith("image/"))) {
    // an attachment served by the API, sized by the page
    return <img src={e.url} alt={e.title ?? ""} className="max-h-[420px] max-w-full rounded-lg object-contain" />;
  }
  const isPdf = !!e.url && isPdfContentType(e.content_type);
  const downloadHref = isPdf && e.url ? pdfDownloadUrl(e.url) : undefined;
  return (
    <figure data-pdf-embed={isPdf ? "" : undefined} className="overflow-hidden rounded-xl border border-border bg-surface">
      <figcaption className="flex items-center gap-2 border-b border-border-subtle px-3 py-2 text-12 text-fg-tertiary">
        <Icon name={e.kind === "image" || e.content_type?.startsWith("image/") ? "library" : e.kind === "design" ? "designs" : isPdf ? "artifacts" : "link"} size={12} />
        <span className="truncate">{e.title ?? e.ref}</span>
        {isPdf && e.url ? (
          <span className="ml-auto flex flex-none items-center gap-3">
            <button type="button" onClick={() => setViewerOpen(true)} className="text-accent hover:underline">
              Open
            </button>
            <a href={downloadHref} download={e.title ?? "document.pdf"} className="text-fg-secondary hover:text-fg hover:underline">
              Download
            </a>
          </span>
        ) : e.url && e.kind !== "page" ? (
          <a href={e.url} target="_blank" rel="noreferrer" className="ml-auto text-accent hover:underline">
            Open
          </a>
        ) : null}
      </figcaption>
      {e.content_type?.startsWith("video/") ? (
        <video src={e.url} controls className="max-h-[420px] w-full" />
      ) : e.content_type?.startsWith("audio/") ? (
        <audio src={e.url} controls className="w-full p-3" />
      ) : isPdf && e.url ? (
        <>
          <div className="p-3" data-testid="knowledge-pdf-embed">
            <PdfViewer
              url={e.url}
              title={e.title ?? "PDF"}
              heightClass="h-[540px]"
              downloadUrl={downloadHref}
              page={page}
              onPageChange={setPage}
            />
          </div>
          <Dialog.Root open={viewerOpen} onOpenChange={setViewerOpen}>
            <Dialog.Portal>
              <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
              <Dialog.Content
                aria-describedby={undefined}
                className="motion-dialog fixed left-1/2 top-1/2 z-50 flex h-[90vh] w-[min(1180px,calc(100%-32px))] -translate-x-1/2 -translate-y-1/2 flex-col gap-3 rounded-xl border border-border-float bg-surface-raised p-4 shadow-[var(--shadow-float)] outline-none"
              >
                <div className="flex flex-wrap items-center gap-2">
                  <Dialog.Title className="min-w-0 flex-1 truncate text-14 font-semibold text-fg">
                    {e.title ?? "PDF"}
                  </Dialog.Title>
                  <a
                    href={downloadHref}
                    download={e.title ?? "document.pdf"}
                    className="inline-flex h-7 items-center gap-1.5 rounded-md border border-btn-secondary-border bg-btn-secondary px-2.5 text-12 text-fg hover:bg-hover"
                  >
                    <Icon name="download" size={14} />
                    Download
                  </a>
                  <Dialog.Close asChild>
                    <button type="button" aria-label="Close" className="text-fg-tertiary hover:text-fg">
                      <Icon name="x" size={15} />
                    </button>
                  </Dialog.Close>
                </div>
                {viewerOpen && (
                  <PdfViewer
                    url={e.url}
                    title={e.title ?? "PDF"}
                    heightClass="min-h-0 flex-1"
                    downloadUrl={downloadHref}
                    page={page}
                    onPageChange={setPage}
                  />
                )}
              </Dialog.Content>
            </Dialog.Portal>
          </Dialog.Root>
        </>
      ) : e.markdown ? (
        <div className="border-l-2 border-border-strong px-4 py-3 text-14">
          <Markdown>{e.markdown}</Markdown>
        </div>
      ) : null}
    </figure>
  );
}

/** The page as a Markdown file, its properties as front matter. */
function exportMarkdown(page: Page) {
  const front = Object.keys(page.properties).length ? `---\n${Object.entries(page.properties).map(([k, v]) => `${k}: ${JSON.stringify(v)}`).join("\n")}\n---\n\n` : "";
  downloadFile(page.title, "md", new Blob([front + (page.body_md ?? "")], { type: "text/markdown" }));
}
