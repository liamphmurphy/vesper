"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useState, type FormEvent } from "react";
import type { Schemas } from "@/lib/api/client";
import {
  exportMemories,
  useDeleteAllMemories,
  useDeleteMemory,
  useImportMemories,
  useMemories,
  useMemory,
  useUpdateMemory,
  type MemoryType,
} from "@/lib/api/hooks";
import { usePersonaLookup } from "@/lib/api/persona-memory-hooks";
import { IMPORT_PROMPT, MEMORY_TYPES, PERSONA_MEMORY_TYPES, memoriesMarkdown, parseMemoryImport, parseTags, typeLabel } from "@/lib/memory-ui";
import { cx } from "@/lib/cx";
import { Button, IconButton } from "@/components/ui/button";
import { CopyButton } from "@/components/ui/copy-button";
import { Icon } from "@/components/ui/icon";
import { Banner, Skeleton, TextArea, TextInput } from "@/components/ui/primitives";

type Memory = Schemas["Memory"];
const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

const shortDate = (iso: string) => new Date(iso).toLocaleDateString(undefined, { month: "short", day: "numeric", year: "numeric" });

/** Where an entry came from: its conversation (linked while it exists), or the raw source. */
function SourceText({ m }: { m: Memory }) {
  if (m.source_chat_id)
    return (
      <Link href={`/chat/${m.source_chat_id}`} className="text-accent hover:underline">
        from a conversation ↗
      </Link>
    );
  if (m.source.startsWith("chat ")) return <>from a deleted conversation</>;
  if (!m.source || m.source === "manual") return <>added by you</>;
  if (m.source === "import") return <>imported</>;
  return <>from {m.source}</>;
}

/** A persona's own memory (who it is, moments it shared), labelled with the persona's name and colour. */
function PersonaTag({ id }: { id: string }) {
  const p = usePersonaLookup().get(id);
  return (
    <span className="inline-flex items-center gap-1 text-fg-secondary" data-testid="memory-persona">
      <span aria-hidden className="size-2 rounded-full" style={{ background: p?.color ?? "currentColor" }} />
      {p ? `${p.name}’s own memory` : "A persona’s own memory"}
    </span>
  );
}

function Meta({ m }: { m: Memory }) {
  return (
    <p className="text-12 text-fg-tertiary">
      {m.space_id && (
        <>
          <span className="text-fg-secondary" data-testid="memory-space">{m.space_name ?? "A space"}’s memory</span>
          {" · "}
        </>
      )}
      {m.persona_id && (
        <>
          <PersonaTag id={m.persona_id} />
          {" · "}
        </>
      )}
      {typeLabel(m.type)} · <SourceText m={m} /> · saved {shortDate(m.created_at)}
      {m.updated_at !== m.created_at && ` · updated ${shortDate(m.updated_at)}`}
    </p>
  );
}

function Tags({ tags }: { tags: string[] }) {
  if (!tags.length) return null;
  return (
    <ul className="flex flex-wrap gap-1" aria-label="Tags">
      {tags.map((t) => (
        <li key={t} className="rounded-full bg-selected px-2 py-px text-11 text-fg-secondary">
          {t}
        </li>
      ))}
    </ul>
  );
}

const label = "text-13 font-medium text-fg-2";

function Editor({ m, onDone, onDeleted }: { m: Memory; onDone: () => void; onDeleted: () => void }) {
  const update = useUpdateMemory();
  const del = useDeleteMemory();
  const [title, setTitle] = useState(m.title);
  const [summary, setSummary] = useState(m.summary);
  const [body, setBody] = useState(m.body);
  const [type, setType] = useState<string>(m.type);
  const [tags, setTags] = useState(m.tags.join(", "));
  const id = `memory-${m.id}`;

  function save(e: FormEvent) {
    e.preventDefault();
    if (!title.trim()) return;
    update
      .mutateAsync({ id: m.id, patch: { title: title.trim(), summary: summary.trim(), body, type: type as MemoryType, tags: parseTags(tags) } })
      .then(onDone, () => undefined);
  }
  const err = update.error ?? del.error;
  return (
    <form onSubmit={save} aria-label={`Edit ${m.title}`} className="flex flex-col gap-2 rounded-xl border border-accent bg-surface p-3">
      <label htmlFor={`${id}-title`} className={label}>Title</label>
      <TextInput id={`${id}-title`} value={title} maxLength={200} required autoFocus onChange={(e) => setTitle(e.target.value)} />
      <label htmlFor={`${id}-summary`} className={label}>Summary</label>
      <TextArea id={`${id}-summary`} rows={2} value={summary} maxLength={300} onChange={(e) => setSummary(e.target.value)} />
      <label htmlFor={`${id}-body`} className={label}>Details</label>
      <TextArea id={`${id}-body`} rows={3} value={body} maxLength={20000} onChange={(e) => setBody(e.target.value)} />
      <div className="flex gap-2">
        <div className="flex w-36 flex-none flex-col gap-1">
          <label htmlFor={`${id}-type`} className={label}>Type</label>
          <select
            id={`${id}-type`}
            value={type}
            onChange={(e) => setType(e.target.value)}
            className="h-[30px] rounded-md border border-border-strong bg-surface px-2 text-13 text-fg focus:border-accent focus:outline-none"
          >
            {(m.persona_id ? PERSONA_MEMORY_TYPES : MEMORY_TYPES).map((t) => (
              <option key={t} value={t}>
                {typeLabel(t)}
              </option>
            ))}
          </select>
        </div>
        <div className="flex min-w-0 flex-1 flex-col gap-1">
          <label htmlFor={`${id}-tags`} className={label}>Tags</label>
          <TextInput id={`${id}-tags`} value={tags} placeholder="comma, separated" onChange={(e) => setTags(e.target.value)} />
        </div>
      </div>
      <Meta m={m} />
      {err && (
        <p role="alert" className="text-12 text-pill-blocked-fg">
          {errorText(err)}
        </p>
      )}
      <div className="flex items-center gap-2">
        <Button type="submit" variant="primary" disabled={update.isPending || !title.trim()}>
          Save
        </Button>
        <Button variant="outline" onClick={onDone}>
          Cancel
        </Button>
        <span className="flex-1" />
        <Button variant="ghost" className="text-pill-blocked-fg" disabled={del.isPending} onClick={() => del.mutateAsync(m.id).then(onDeleted, () => undefined)}>
          Delete
        </Button>
      </div>
    </form>
  );
}

function Row({ m, editing, onEdit, onDone }: { m: Memory; editing: boolean; onEdit: () => void; onDone: () => void }) {
  const del = useDeleteMemory();
  if (editing) return <li className="col-span-full"><Editor m={m} onDone={onDone} onDeleted={onDone} /></li>;
  return (
    <li className="group flex min-w-0 gap-2 rounded-xl border border-border bg-surface p-3.5 hover:bg-hover" data-testid="memory-row">
      <button type="button" onClick={onEdit} className="flex min-w-0 flex-1 flex-col items-start gap-1 text-left">
        <span className="type-heading text-fg">{m.title}</span>
        {m.summary && <span className="text-12 text-fg-secondary">{m.summary}</span>}
        <Tags tags={m.tags} />
        <Meta m={m} />
      </button>
      <div className="flex flex-none flex-col gap-1">
        <IconButton icon="edit" label={`Edit ${m.title}`} onClick={onEdit} />
        <IconButton icon="trash" label={`Delete ${m.title}`} disabled={del.isPending} onClick={() => del.mutate(m.id)} />
      </div>
    </li>
  );
}

/** One page of 50; the last loaded page offers the next. Search returns only the top 50. */
function Page({
  q,
  type,
  whose,
  offset,
  hide,
  editing,
  setEditing,
  onMore,
  last,
}: {
  q: string;
  type?: MemoryType;
  whose: string;
  offset: number;
  hide?: string;
  editing?: string;
  setEditing: (id?: string) => void;
  onMore: () => void;
  last: boolean;
}) {
  const list = useMemories(q, type, offset, whose);
  if (list.isError)
    return (
      <div className="col-span-full">
        <Banner tone="blocked" title="Couldn’t load memories">{errorText(list.error)}</Banner>
      </div>
    );
  if (!list.data)
    return (
      <div aria-busy="true" className="contents">
        <Skeleton className="h-28" />
        <Skeleton className="h-28" />
      </div>
    );
  const rows = list.data.memories.filter((m) => m.id !== hide);
  return (
    <>
      {offset === 0 && rows.length === 0 && (
        <p className="col-span-full px-1 py-6 text-center text-13 text-fg-secondary">
          {q || type ? "No memories match." : whose ? "Nothing remembered here yet." : "Nothing remembered yet. The assistant saves useful things as you talk and tells you when it does."}
        </p>
      )}
      {/* Every page's cards share the one grid. */}
      <ul className="contents">
        {rows.map((m) => (
          <Row key={m.id} m={m} editing={editing === m.id} onEdit={() => setEditing(m.id)} onDone={() => setEditing(undefined)} />
        ))}
      </ul>
      {last && list.data.has_more && !q && (
        <Button variant="outline" className="col-span-full justify-self-center" onClick={onMore}>
          Load more
        </Button>
      )}
    </>
  );
}

function download(name: string, type: string, text: string) {
  const url = URL.createObjectURL(new Blob([text], { type }));
  const a = document.createElement("a");
  a.href = url;
  a.download = name;
  a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
}

/** Downloads every memory as JSON or Markdown; `err` is the last failure, for the caller to show. */
export function useMemoryExport() {
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);
  async function run(format: "json" | "md") {
    setBusy(true);
    setErr(null);
    try {
      const data = await exportMemories();
      const day = data.exported_at.slice(0, 10);
      if (format === "json") download(`memory-${day}.json`, "application/json", JSON.stringify(data, null, 2));
      else download(`memory-${day}.md`, "text/markdown", memoriesMarkdown(data.memories, data.exported_at));
    } catch (e) {
      setErr(errorText(e));
    } finally {
      setBusy(false);
    }
  }
  return { busy, err, run };
}

export function ExportMenu() {
  const { busy, err, run } = useMemoryExport();
  return (
    <details className="relative">
      <summary className="inline-flex h-[30px] cursor-pointer list-none items-center gap-1.5 rounded-md border border-btn-secondary-border bg-btn-secondary px-3 text-13 text-fg hover:bg-hover">
        <Icon name="download" size={14} />
        Export
        <Icon name="chev" size={12} />
      </summary>
      <div className="absolute right-0 z-10 mt-1 flex w-44 flex-col rounded-md border border-border-strong bg-surface p-1 shadow-lg">
        <button type="button" disabled={busy} className="rounded px-2 py-1.5 text-left text-13 hover:bg-hover" onClick={() => run("json")}>
          JSON (all entries)
        </button>
        <button type="button" disabled={busy} className="rounded px-2 py-1.5 text-left text-13 hover:bg-hover" onClick={() => run("md")}>
          Markdown (all entries)
        </button>
        {err && <p role="alert" className="px-2 py-1 text-12 text-pill-blocked-fg">{err}</p>}
      </div>
    </details>
  );
}

/** Import view: copy a prompt for another assistant, paste its reply, preview, then save. */
export function ImportView({ onClose }: { onClose: () => void }) {
  const imp = useImportMemories();
  const [text, setText] = useState("");
  const parsed = useMemo(() => parseMemoryImport(text), [text]);
  const result = imp.data;
  const n = parsed.entries.length;
  if (result)
    return (
      <div className="flex flex-col gap-3" data-testid="memory-import-result">
        <p className="text-13 text-fg">
          Added {result.created}, updated {result.updated}
        </p>
        {result.failed.length > 0 && (
          <div className="flex flex-col gap-1">
            <p className="text-12 text-pill-blocked-fg">{result.failed.length} couldn’t be saved:</p>
            <ul className="flex flex-col gap-0.5 text-12 text-fg-secondary">
              {result.failed.map((f) => (
                <li key={f.index}>
                  {f.title} — {f.error}
                </li>
              ))}
            </ul>
          </div>
        )}
        <Button variant="primary" className="self-start" onClick={onClose}>
          Done
        </Button>
      </div>
    );
  return (
    <section aria-label="Import memories" className="flex flex-col gap-3">
      <p className="text-13 text-fg-secondary">
        Bring over what another assistant already knows about you. Nothing is saved until you confirm.
      </p>
      <div className="flex flex-col gap-1.5">
        <div className="flex items-center gap-2">
          <p className="flex-1 text-13 text-fg">1. Copy this prompt into ChatGPT, Claude or another assistant</p>
          <CopyButton text={IMPORT_PROMPT} label="Copy prompt" />
        </div>
        <pre
          tabIndex={0}
          aria-label="Prompt to copy"
          className="max-h-40 overflow-y-auto whitespace-pre-wrap rounded-md border border-border bg-surface p-2 font-mono text-11 text-fg-secondary"
        >
          {IMPORT_PROMPT}
        </pre>
      </div>
      <div className="flex flex-col gap-1.5">
        <label htmlFor="memory-import-text" className="text-13 text-fg">
          2. Paste its reply
        </label>
        <TextArea id="memory-import-text" rows={6} value={text} placeholder="Paste the whole reply, including the code block" onChange={(e) => setText(e.target.value)} />
      </div>
      <div aria-live="polite" className="flex flex-col gap-1">
        {parsed.error && (
          <p role="alert" className="text-12 text-pill-blocked-fg">
            {parsed.error}
          </p>
        )}
        {!parsed.error && text.trim() && (
          <>
            <p className="text-13 text-fg">Found {n} {n === 1 ? "memory" : "memories"}</p>
            {parsed.skipped > 0 && <p className="text-12 text-fg-tertiary">{parsed.skipped} skipped (retired or missing a title).</p>}
            {n > 0 && (
              <ul aria-label="Memories found" className="flex max-h-40 flex-col gap-0.5 overflow-y-auto text-12 text-fg-secondary">
                {parsed.entries.map((e, i) => (
                  <li key={i}>
                    {e.title} <span className="text-fg-tertiary">· {typeLabel(e.type)}</span>
                  </li>
                ))}
              </ul>
            )}
          </>
        )}
      </div>
      {imp.isError && (
        <p role="alert" className="text-12 text-pill-blocked-fg">
          {errorText(imp.error)}
        </p>
      )}
      <div className="flex items-center gap-2">
        <Button variant="primary" disabled={n === 0 || imp.isPending} onClick={() => imp.mutateAsync({ memories: parsed.entries }).then(() => undefined, () => undefined)}>
          Import {n} {n === 1 ? "memory" : "memories"}
        </Button>
        <Button variant="outline" onClick={onClose}>
          Cancel
        </Button>
      </div>
    </section>
  );
}

function DeleteAll({ total }: { total?: number }) {
  const wipe = useDeleteAllMemories();
  const [asking, setAsking] = useState(false);
  if (!total && !asking) return null;
  if (!asking)
    return (
      <Button variant="ghost" className="text-pill-blocked-fg" onClick={() => setAsking(true)}>
        Delete everything…
      </Button>
    );
  return (
    <div role="group" aria-label="Confirm delete everything" className="flex flex-wrap items-center gap-2 rounded-md border border-border-strong p-2">
      <span className="flex-1 text-12 text-fg">Forget all {total} memories? This can’t be undone.</span>
      <Button
        variant="primary"
        className="bg-state-blocked"
        disabled={wipe.isPending}
        onClick={() => wipe.mutateAsync().then(() => setAsking(false), () => undefined)}
      >
        Delete everything
      </Button>
      <Button variant="outline" onClick={() => setAsking(false)}>
        Cancel
      </Button>
      {wipe.isError && <p role="alert" className="basis-full text-12 text-pill-blocked-fg">{errorText(wipe.error)}</p>}
    </div>
  );
}

/** "View" from a notice: that entry, open for editing, above the list. */
function Focused({ id, onDone }: { id: string; onDone: () => void }) {
  const m = useMemory(id);
  if (m.isError)
    return (
      <p className="rounded-xl border border-border p-3 text-13 text-fg-secondary">
        That memory is no longer saved.
      </p>
    );
  if (!m.data) return <Skeleton className="h-40" />;
  return <Editor key={m.data.id} m={m.data} onDone={onDone} onDeleted={onDone} />;
}

/** The memory manager: a rail for whose memory it is, then search, filter, edit, delete and export every entry as cards. */
const FOCUS_DONE = "/customization";

/** One person's or persona's memories: search, type filter and the cards. Delete everything only applies to the whole list. */
export function MemorySection({ whose, heading, focus }: { whose: string; heading: string; focus?: string }) {
  const router = useRouter();
  const [text, setText] = useState("");
  const [q, setQ] = useState("");
  const [type, setType] = useState<MemoryType | undefined>(undefined);
  const [pages, setPages] = useState(1);
  const [editing, setEditing] = useState<string | undefined>(undefined);
  const count = useMemories();
  // Debounce search typing; a new search or filter starts from the first page.
  useEffect(() => {
    const t = setTimeout(() => {
      setQ(text.trim());
      setPages(1);
    }, 250);
    return () => clearTimeout(t);
  }, [text]);
  return (
    <div className="flex min-w-0 flex-col gap-3">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <h2 className="type-title text-fg">{heading}</h2>
        <div className="w-60 max-sm:w-full">
          <TextInput type="search" aria-label="Search memories" placeholder="Search memories" value={text} onChange={(e) => setText(e.target.value)} />
        </div>
      </div>
      <div role="group" aria-label="Filter by type" className="flex flex-wrap gap-1">
        {[undefined, ...PERSONA_MEMORY_TYPES].map((t) => (
          <button
            key={t ?? "all"}
            type="button"
            aria-pressed={type === t}
            onClick={() => {
              setType(t);
              setPages(1);
            }}
            className={cx("rounded-md px-2.5 py-1 text-12", type === t ? "bg-selected text-fg" : "text-fg-secondary hover:bg-hover")}
          >
            {t ? typeLabel(t) : "All"}
          </button>
        ))}
      </div>
      {focus && <Focused key={focus} id={focus} onDone={() => router.replace(FOCUS_DONE, { scroll: false })} />}
      <div className="grid grid-cols-[repeat(auto-fill,minmax(240px,1fr))] gap-3">
        {Array.from({ length: pages }, (_, i) => (
          <Page
            key={i}
            q={q}
            type={type}
            whose={whose}
            offset={i * 50}
            hide={focus}
            editing={editing}
            setEditing={setEditing}
            last={i === pages - 1}
            onMore={() => setPages((n) => n + 1)}
          />
        ))}
      </div>
      <div className="mt-4 flex flex-col items-start gap-2 border-t border-border-subtle pt-3">
        {!whose && <DeleteAll total={count.data?.total} />}
        <p className="text-12 text-fg-tertiary">Private to you. Never shared with the team wiki. Secrets and tokens are never saved.</p>
      </div>
    </div>
  );
}
