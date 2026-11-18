"use client";

import { useRecordVisit } from "@/components/shell/use-record-visit";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { ContextMenu, DropdownMenu } from "radix-ui";
import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { cx } from "@/lib/cx";
import { defaultLabel, parseWikiLinks } from "@/lib/wikilinks";
import { pageHref, restoreObsidianSyntax, visibleProperties, wordCount } from "@/lib/knowledge";
import { KnowledgeSyntax } from "@/lib/knowledge-editor";
import { KnowledgeCompletion } from "@/lib/knowledge-completion";
import { api, unwrap } from "@/lib/api/client";
import { fetchKnowledgeImages, usePage, usePages, useSavePage, useSavedQuery, type Audience, type Embed, type Page } from "@/lib/api/knowledge-hooks";
import { useChat, useSendChatMessage } from "@/lib/api/hooks";
import { downloadFile } from "@/lib/api/docs-hooks";
import { floatPanel } from "@/components/domain/pickers";
import { Markdown } from "@/components/domain/markdown";
import { Icon } from "@/components/ui/icon";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { toast } from "@/lib/toast";
import { DocEditor, type DocEditorHandle, type SaveState } from "@/app/(app)/apps/docs/_components/doc-editor";
import { DeckScreen } from "@/app/(app)/apps/slides/_components/deck-screen";
import { DesignEditor } from "@/app/(app)/apps/designs/_components/design-editor";
import { AUDIENCE, AudienceChip, StatusBar, Tag } from "./kit";
import { PersonaAvatar, personaLook } from "@/app/(app)/chat/_components/persona";
import { ReviewBar, ReviewList, undecided } from "./page-review";
import { QueryTable } from "./query-table";
import { useKnowledgeTab } from "./shell";
import { useKnowledgeChat } from "./chat-context";

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

  return (
    <div className="flex min-h-0 flex-1">
      {[...inlinePreviews.values()].map(({ dom, embed, key }) => createPortal(<EmbedPreview embed={embed} />, dom, key))}
      <div className="flex min-w-0 flex-1 flex-col">
        <header className="flex h-12 flex-none items-center gap-2 px-6">
          <nav aria-label="Folder" className="flex min-w-0 flex-1 items-center gap-1.5 text-12 text-fg-tertiary">
            {crumbs.map((c, i) => (
              <span key={i} className="flex min-w-0 items-center gap-1.5">
                {i > 0 && <span className="text-fg-tertiary/60">/</span>}
                <span className={cx("truncate", i === crumbs.length - 1 && "font-medium text-fg-2")}>{i === crumbs.length - 1 ? p.title : c}</span>
              </span>
            ))}
          </nav>
          <AudienceMenu audience={p.audience} onChange={(audience) => save.mutate({ audience })} />
          <button onClick={() => openPanel("history")} className="flex h-[26px] items-center gap-2 rounded-full border border-border bg-surface pl-1.5 pr-3 text-12 font-medium text-fg-secondary hover:border-border-strong">
            <PersonaAvatar persona={personaLook(chat?.speaker ?? chat?.persona)} size={16} />
            {modeLabel}
          </button>
          <button
            aria-label="Copy link"
            title="Copy [[link]]"
            onClick={() => void navigator.clipboard?.writeText(`[[${p.path ?? p.title}]]`)}
            className="grid size-7 place-items-center rounded-md text-fg-tertiary hover:bg-hover"
          >
            <Icon name="link" size={15} />
          </button>
          <MoreMenu page={p} onHistory={() => openPanel("history")} />
        </header>
        <ReviewBar page={p} persona={persona} direct={p.direct} />
        <div className="min-h-0 flex-1 overflow-y-auto">
          <article className="mx-auto w-full max-w-[720px] px-8 pb-24 pt-8">
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
  if (e.url && (e.kind === "image" || e.content_type?.startsWith("image/"))) {
    // an attachment served by the API, sized by the page
    return <img src={e.url} alt={e.title ?? ""} className="max-h-[420px] max-w-full rounded-lg object-contain" />;
  }
  return (
    <figure className="overflow-hidden rounded-xl border border-border bg-surface">
      <figcaption className="flex items-center gap-2 border-b border-border-subtle px-3 py-2 text-12 text-fg-tertiary">
        <Icon name={e.kind === "image" || e.content_type?.startsWith("image/") ? "library" : e.kind === "design" ? "designs" : "link"} size={12} />
        <span className="truncate">{e.title ?? e.ref}</span>
        {e.url && e.kind !== "page" && (
          <a href={e.url} target="_blank" rel="noreferrer" className="ml-auto text-accent hover:underline">
            Open
          </a>
        )}
      </figcaption>
      {e.content_type?.startsWith("video/") ? (
        <video src={e.url} controls className="max-h-[420px] w-full" />
      ) : e.content_type?.startsWith("audio/") ? (
        <audio src={e.url} controls className="w-full p-3" />
      ) : e.markdown ? (
        <div className="border-l-2 border-border-strong px-4 py-3 text-14">
          <Markdown>{e.markdown}</Markdown>
        </div>
      ) : null}
    </figure>
  );
}

function AudienceMenu({ audience, onChange }: { audience: Audience; onChange: (a: "private" | "shared") => void }) {
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger aria-label={`Who can see this page: ${AUDIENCE[audience].label}`} className="rounded-full outline-none focus-visible:ring-2 focus-visible:ring-accent">
        <AudienceChip audience={audience} />
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="end" sideOffset={6} className={cx(floatPanel, "w-[300px] p-2")}>
          <DropdownMenu.Label className="px-2 pb-2 pt-1 text-13 font-semibold">Who can see this page</DropdownMenu.Label>
          {(Object.keys(AUDIENCE) as Audience[]).map((a) => (
            <DropdownMenu.Item key={a} disabled={a === "agent"} onSelect={() => a !== "agent" && a !== audience && onChange(a)} className={cx(item, a === audience && "bg-selected")}>
              <span className={cx("grid size-7 flex-none place-items-center rounded-lg", AUDIENCE[a].cls)}>
                <Icon name={AUDIENCE[a].icon} size={15} />
              </span>
              <span className="min-w-0 flex-1">
                <span className="block font-semibold">{AUDIENCE[a].label}</span>
                <span className="block text-12 text-fg-tertiary">{AUDIENCE[a].detail}</span>
              </span>
              {a === audience && <Icon name="check" size={14} className="text-accent" />}
            </DropdownMenu.Item>
          ))}
          <p className="px-2 pt-2 text-11 text-fg-tertiary">Only you can change this. Agents can&apos;t.</p>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

function MoreMenu({ page, onHistory }: { page: Page; onHistory: () => void }) {
  const exportMd = () => {
    const front = Object.keys(page.properties).length ? `---\n${Object.entries(page.properties).map(([k, v]) => `${k}: ${JSON.stringify(v)}`).join("\n")}\n---\n\n` : "";
    downloadFile(page.title, "md", new Blob([front + (page.body_md ?? "")], { type: "text/markdown" }));
  };
  const row = "flex h-8 cursor-default select-none items-center gap-2.5 rounded-md px-2 outline-none data-[highlighted]:bg-hover";
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger aria-label="More" className="grid size-7 place-items-center rounded-md text-fg-tertiary outline-none hover:bg-hover">
        <Icon name="dots" size={15} />
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="end" sideOffset={6} className={cx(floatPanel, "min-w-[200px]")}>
          <DropdownMenu.Item className={row} onSelect={exportMd}>
            <Icon name="download" size={14} /> Export Markdown
          </DropdownMenu.Item>
          <DropdownMenu.Item className={row} onSelect={() => window.print()}>
            <Icon name="printer" size={14} /> Print or save as PDF
          </DropdownMenu.Item>
          <DropdownMenu.Item className={row} onSelect={onHistory}>
            <Icon name="history" size={14} /> Version history
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}
