"use client";

import Link from "next/link";
import { Dialog, DropdownMenu } from "radix-ui";
import { useRouter, useSearchParams } from "next/navigation";
import { isNativeShell } from "@/lib/native-shell/bridge";
import { buildKeepsakesNavModel, LIBRARY_SOURCE_PICKER, librarySourceHref, type LibrarySourceValue } from "@/lib/native-shell/models/library";
import { useState } from "react";
import { libraryItemUrl } from "@/lib/api/client";
import {
  useClearLibraryReference,
  useDeleteLibraryItem,
  useLibrary,
  useLibraryFilePreview,
  useRenameLibraryItem,
  useSetLibraryReference,
  useUploadLibraryItem,
  type LibraryItem,
  type LibraryItemKind,
} from "@/lib/api/library-hooks";
import { usePersonas } from "@/lib/api/persona-hooks";
import { cx } from "@/lib/cx";
import { formatBytes } from "@/lib/files";
import { clock } from "@/lib/chat-video";
import { audioFormat } from "@/lib/chat-audio";
import { timelineTime } from "@/lib/format";
import { checkLibraryUpload, referenceBadge, referenceCaption, referenceChoices } from "@/lib/library-ui";
import { floatPanel } from "@/components/domain/pickers";
import { AudioPlayer } from "@/components/domain/audio-player";
import { Waveform } from "@/components/domain/waveform";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, EmptyState, Skeleton } from "@/components/ui/primitives";
import { NavigatorPortal } from "@/components/shell/navigator-slot";
import { Content, TopBar } from "@/components/shell/topbar";
import { Tabs } from "@/components/ui/controls";
import { useCompact } from "@/lib/viewport";
import { Fridge } from "./fridge";
import { Links } from "./links";
import { ProjectDocs } from "./_components/project-docs";
import { LibrarySourceSwitch } from "./_components/source-switch";
import { confirmAction } from "@/components/ui/confirm";
import { Spinner } from "@/components/ui/loading";
import { PageHeader } from "@/components/ui/page-header";

/** Where an item came from: its persona and chat, while they still exist, or the person's own upload. */
function Source({ item }: { item: LibraryItem }) {
  if (item.source === "upload") return <span className="min-w-0 truncate text-12 text-fg-tertiary">Uploaded by you</span>;
  const chat = item.chat_id ? `/chat/${item.chat_id}` : undefined;
  return (
    <span className="min-w-0 truncate text-12 text-fg-tertiary">
      {item.persona_name ?? "Assistant"}
      {" · "}
      {chat ? (
        <Link href={chat} className="text-accent hover:underline">
          {item.chat_title || "Open chat"}
        </Link>
      ) : (
        "chat deleted"
      )}
    </span>
  );
}

/**
 * "Use as reference" (for the person or one of their personas) and "Clear
 * reference": new images of that persona or person keep this likeness.
 */
function ReferenceActions({ item }: { item: LibraryItem }) {
  const personas = usePersonas();
  const set = useSetLibraryReference();
  const clear = useClearLibraryReference();
  const choices = referenceChoices(item, personas.data?.personas ?? []);
  const busy = set.isPending || clear.isPending;
  const error = set.error ?? clear.error;
  return (
    <>
      {error && <span className="text-12 text-pill-blocked-fg">{error.message}</span>}
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <Button variant="secondary" icon="users" disabled={busy}>
            Use as reference
          </Button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content align="end" sideOffset={4} className={cx(floatPanel, "w-60")}>
            {choices.map((c) => (
              <DropdownMenu.Item
                key={c.key}
                onSelect={() => set.mutate({ itemId: item.id, role: c.role, personaId: c.personaId })}
                className="flex h-8 items-center truncate rounded-md px-2 outline-none data-[highlighted]:bg-hover"
              >
                {c.label}
              </DropdownMenu.Item>
            ))}
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
      {referenceBadge(item) && (
        <Button variant="ghost" disabled={busy} onClick={() => clear.mutate(item.id)}>
          Clear reference
        </Button>
      )}
    </>
  );
}

/** Marks a current reference image on its tile. */
function ReferenceBadge({ item }: { item: LibraryItem }) {
  const who = referenceBadge(item);
  if (!who) return null;
  return (
    <span
      data-testid="library-reference"
      title={`New images keep this likeness of ${who === "You" ? "you" : who}`}
      className="absolute left-2 top-2 max-w-[calc(100%-16px)] truncate rounded-md bg-surface-raised px-1.5 py-0.5 text-11 text-fg shadow-[var(--shadow-float)]"
    >
      {who} · reference
    </span>
  );
}

/** The dialog a Library tile opens: the item's header with Download and Remove, over the item itself. */
function ItemDialog({ item, open, onOpenChange, trigger, extra, children }: { item: LibraryItem; open?: boolean; onOpenChange?: (open: boolean) => void; trigger: React.ReactNode; extra?: React.ReactNode; children: React.ReactNode }) {
  const del = useDeleteLibraryItem();
  const noun = item.kind === "diagram" ? "diagram" : item.kind === "video" ? "video" : item.kind === "audio" ? "audio file" : item.kind === "file" ? "file" : item.kind === "export" ? "export" : "image";
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Trigger asChild>{trigger}</Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby={undefined}
          className="motion-dialog fixed left-1/2 top-1/2 z-50 flex max-h-[92vh] w-[min(1100px,calc(100%-32px))] -translate-x-1/2 -translate-y-1/2 flex-col gap-3 rounded-xl border border-border-float bg-surface-raised p-4 shadow-[var(--shadow-float)] outline-none"
        >
          <div className="flex flex-wrap items-center gap-2">
            <div className="flex min-w-0 flex-1 flex-col">
              <Dialog.Title className="truncate text-13 text-fg">{item.title}</Dialog.Title>
              <span className="truncate text-12 text-fg-tertiary">
                {item.filename} · {formatBytes(item.size_bytes)}
                {item.duration_ms ? ` · ${clock(item.duration_ms)}` : ""} · {timelineTime(item.created_at)}
                {referenceCaption(item) && ` · ${referenceCaption(item)}`}
              </span>
            </div>
            {extra}
            <a
              href={libraryItemUrl(item.id, true)}
              download={item.filename}
              className="inline-flex h-7 items-center gap-1.5 rounded-md border border-btn-secondary-border bg-btn-secondary px-2.5 text-12 text-fg hover:bg-hover"
            >
              <Icon name="download" size={14} />
              Download
            </a>
            <Button
              variant="ghost"
              icon="trash"
              disabled={del.isPending}
              onClick={async () => {
                const body = item.source === "upload" ? undefined : "It stays in its chat while that chat exists.";
                if (await confirmAction({ title: `Remove this ${noun} from your Library?`, body, confirmLabel: "Remove" })) del.mutate(item.id);
              }}
            >
              Remove
            </Button>
            <Dialog.Close asChild>
              <button type="button" aria-label="Close" className="text-fg-tertiary hover:text-fg">
                <Icon name="x" size={15} />
              </button>
            </Dialog.Close>
          </div>
          {children}
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

/**
 * A video: its poster with the length and a Video tag; hovering plays a muted
 * preview, and a click opens the player. The one a chat's "Open in Library"
 * names starts open.
 */
function VideoTile({ item, initiallyOpen }: { item: LibraryItem; initiallyOpen: boolean }) {
  const [open, setOpen] = useState(initiallyOpen);
  const [hover, setHover] = useState(false);
  const url = libraryItemUrl(item.id);
  const poster = item.has_poster ? `/api/v1/library/${item.id}/poster` : undefined;
  return (
    <li className="flex min-w-0 flex-col gap-1.5" data-testid="library-item" data-kind="video">
      <ItemDialog
        item={item}
        open={open}
        onOpenChange={setOpen}
        extra={item.chat_id && <Link href={`/chat/${item.chat_id}`} className="text-12 text-accent hover:underline">Open chat</Link>}
        trigger={
          <button
            type="button"
            aria-label={`Play ${item.title}`}
            onMouseEnter={() => setHover(true)}
            onMouseLeave={() => setHover(false)}
            onFocus={() => setHover(true)}
            onBlur={() => setHover(false)}
            className="relative aspect-video overflow-hidden rounded-lg border border-border bg-[#000] outline-none focus-visible:ring-2 focus-visible:ring-accent"
          >
            {hover ? (
              <video src={url} poster={poster} muted autoPlay loop playsInline preload="metadata" className="size-full object-cover" />
            ) : poster ? (
              <img src={poster} alt="" loading="lazy" className="size-full object-cover" />
            ) : (
              <span className="grid size-full place-items-center text-fg-tertiary"><Icon name="film" size={22} /></span>
            )}
            <span className="absolute bottom-1.5 left-1.5 flex items-center gap-1 rounded bg-[rgb(0_0_0/0.7)] px-1.5 py-px text-10 text-[#fff]"><Icon name="play" size={8} />Video</span>
            {item.duration_ms ? <span className="absolute bottom-1.5 right-1.5 rounded bg-[rgb(0_0_0/0.7)] px-1.5 py-px font-mono text-11 text-[#fff]">{clock(item.duration_ms)}</span> : null}
          </button>
        }
      >
        <video src={url} poster={poster} controls autoPlay playsInline className="min-h-0 max-h-[80vh] w-full bg-[#000]" />
      </ItemDialog>
      <span className="truncate text-13 text-fg">{item.title}</span>
      <Source item={item} />
    </li>
  );
}

/** The audio player's title field: rename in place. */
function RenameField({ item }: { item: LibraryItem }) {
  const rename = useRenameLibraryItem();
  const [title, setTitle] = useState(item.title);
  const changed = title.trim() !== "" && title.trim() !== item.title;
  return (
    <form
      className="flex items-center gap-2"
      onSubmit={(e) => {
        e.preventDefault();
        if (changed) rename.mutate({ itemId: item.id, title: title.trim() });
      }}
    >
      <input
        value={title}
        maxLength={300}
        aria-label="Title"
        onChange={(e) => setTitle(e.target.value)}
        className="h-8 min-w-0 flex-1 rounded-md border border-border bg-surface px-2 text-13 text-fg outline-none focus-visible:ring-2 focus-visible:ring-accent"
      />
      <Button type="submit" variant="secondary" disabled={!changed || rename.isPending}>{rename.isPending ? "Saving…" : "Rename"}</Button>
      {rename.error && <span className="text-12 text-pill-blocked-fg">{rename.error.message}</span>}
    </form>
  );
}

/**
 * Audio: its waveform with the length and an Audio tag, and a click opens the player (waveform
 * scrubbing, speed, loop, download, rename). The one a chat's "Open in Library" names starts open.
 */
function AudioTile({ item, initiallyOpen }: { item: LibraryItem; initiallyOpen: boolean }) {
  const [open, setOpen] = useState(initiallyOpen);
  // A click on the tile plays at once; arriving from a chat's "Open in Library" waits for Play.
  const [autoPlay, setAutoPlay] = useState(false);
  return (
    <li className="flex min-w-0 flex-col gap-1.5" data-testid="library-item" data-kind="audio">
      <ItemDialog
        item={item}
        open={open}
        onOpenChange={(o) => {
          setOpen(o);
          setAutoPlay(o);
        }}
        extra={item.chat_id && <Link href={`/chat/${item.chat_id}`} className="text-12 text-accent hover:underline">Open chat</Link>}
        trigger={
          <button
            type="button"
            aria-label={`Play ${item.title}`}
            className="relative flex aspect-video flex-col justify-end overflow-hidden rounded-lg border border-border bg-accent-soft px-3 pb-2 pt-3 outline-none focus-visible:ring-2 focus-visible:ring-accent"
          >
            <Waveform peaks={item.peaks} bars={32} className="h-full min-h-0 flex-1" />
            <span className="mt-1.5 flex items-center justify-between text-11 text-fg-secondary">
              <span className="flex items-center gap-1 rounded bg-surface px-1.5 py-px"><Icon name="audio" size={9} />Audio</span>
              {item.duration_ms ? <span className="font-mono">{clock(item.duration_ms)}</span> : <span>{audioFormat(item.content_type, item.filename)}</span>}
            </span>
          </button>
        }
      >
        <div className="flex flex-col gap-4 pb-1" data-testid="audio-dialog">
          <AudioPlayer src={libraryItemUrl(item.id)} peaks={item.peaks} durationMs={item.duration_ms} large autoPlay={autoPlay} />
          <RenameField item={item} />
          <dl className="grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 text-12 text-fg-secondary">
            <dt className="text-fg-tertiary">Format</dt>
            <dd>{audioFormat(item.content_type, item.filename)}</dd>
            {item.method && (
              <>
                <dt className="text-fg-tertiary">Made with</dt>
                <dd data-testid="audio-made-with">{item.method}</dd>
              </>
            )}
          </dl>
        </div>
      </ItemDialog>
      <span className="truncate text-13 text-fg">{item.title}</span>
      <Source item={item} />
    </li>
  );
}

/** "PY", "ZIP", "CSV": a file's type as the badge on its tile. */
function typeBadge(item: LibraryItem): string {
  const ext = item.filename.includes(".") ? item.filename.split(".").pop()! : "";
  return (ext || "FILE").slice(0, 4).toUpperCase();
}

/** Where an export's app lives, to link back to the source. */
const SOURCE_APP = { slides: { label: "Slides", href: "/apps/slides" }, designs: { label: "Designs", href: "/apps/designs" }, docs: { label: "Docs", href: "/apps/docs" } } as const;

/** "Source: Slides › Q4 deck (edited since)": whether the export is still what its source says. */
function ExportSourceLine({ item }: { item: LibraryItem }) {
  const src = item.export_source;
  if (!src) return null;
  const app = SOURCE_APP[src.kind];
  const tone = src.status === "changed" ? "text-[#C77700]" : src.status === "deleted" ? "text-pill-blocked-fg" : "text-fg-tertiary";
  const note = src.status === "changed" ? "edited since" : src.status === "deleted" ? "source deleted" : "up to date";
  return (
    <span className={cx("min-w-0 truncate text-12", tone)} data-testid="export-source" data-status={src.status}>
      Source:{" "}
      {src.status === "deleted" ? (
        <>{app.label}</>
      ) : (
        <Link href={`${app.href}/${src.id}`} className="hover:underline">{app.label} › {src.title}</Link>
      )}
      {` (${note})`}
    </span>
  );
}

/** The one line under a tile's name: "112 lines · 4 KB". */
function fileMeta(item: LibraryItem): string {
  return [item.detail, formatBytes(item.size_bytes)].filter(Boolean).join(" · ");
}

/** What a file's dialog shows of it: text as text, a table's first rows, a zip's names. Never rendered as a page. */
function FilePreviewPane({ item, open }: { item: LibraryItem; open: boolean }) {
  const q = useLibraryFilePreview(item.id, open);
  if (q.isPending) return <Skeleton className="h-48 w-full rounded-lg" />;
  if (q.isError) return <p className="text-12 text-pill-blocked-fg" role="alert">Couldn’t read a preview: {q.error.message}</p>;
  const p = q.data;
  const more = p.truncated ? <p className="mt-2 text-12 text-fg-tertiary">Showing the start of the file. Download it for the rest.</p> : null;
  if (p.kind === "text")
    return (
      <div data-testid="file-preview" data-kind="text">
        <pre className="max-h-[50vh] overflow-auto rounded-lg border border-border-subtle bg-surface-sunken p-3 font-mono text-12 leading-[1.5] text-fg">{(p.lines ?? []).join("\n")}</pre>
        {more}
      </div>
    );
  if (p.kind === "table")
    return (
      <div data-testid="file-preview" data-kind="table">
        <div className="max-h-[50vh] overflow-auto rounded-lg border border-border-subtle">
          <table className="w-full border-collapse text-left text-12">
            <tbody>
              {(p.rows ?? []).map((row, i) => (
                <tr key={i} className={cx("border-b border-border-subtle last:border-0", i === 0 && "bg-surface-sunken font-medium")}>
                  {row.map((cell, j) => <td key={j} className="max-w-[260px] truncate px-2.5 py-1.5 text-fg">{cell}</td>)}
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        {more}
      </div>
    );
  if (p.kind === "zip")
    return (
      <div data-testid="file-preview" data-kind="zip">
        <ul className="max-h-[50vh] overflow-auto rounded-lg border border-border-subtle text-12">
          {(p.entries ?? []).map((e) => (
            <li key={e.name} className="flex items-center gap-3 border-b border-border-subtle px-2.5 py-1.5 last:border-0">
              <span className="min-w-0 flex-1 truncate font-mono text-fg">{e.name}</span>
              <span className="flex-none text-fg-tertiary">{formatBytes(e.size)}</span>
            </li>
          ))}
        </ul>
        {p.truncated && <p className="mt-2 text-12 text-fg-tertiary">Showing {p.entries?.length} of {p.total} files. Nothing is unpacked.</p>}
      </div>
    );
  return <p className="text-14 text-fg-secondary" data-testid="file-preview" data-kind="none">No preview for this type of file. Download it to open it.</p>;
}

/** A file: a type badge, its name, a summary line and the source. A click opens a read-only preview with Download, Rename and Remove. */
function FileTile({ item, initiallyOpen }: { item: LibraryItem; initiallyOpen: boolean }) {
  const [open, setOpen] = useState(initiallyOpen);
  return (
    <li className="flex min-w-0 flex-col gap-1.5" data-testid="library-item" data-kind="file">
      <ItemDialog
        item={item}
        open={open}
        onOpenChange={setOpen}
        extra={item.chat_id && <Link href={`/chat/${item.chat_id}`} className="text-12 text-accent hover:underline">Open chat</Link>}
        trigger={
          <button type="button" aria-label={`Open ${item.title}`} className="flex aspect-[2/1] flex-col justify-between rounded-lg border border-border bg-surface-sunken p-3 text-left outline-none focus-visible:ring-2 focus-visible:ring-accent">
            <span className="text-26 font-bold leading-none text-accent">{typeBadge(item)}</span>
            <span className="truncate text-12 text-fg-secondary">{fileMeta(item)}</span>
          </button>
        }
      >
        <div className="flex flex-col gap-3 pb-1">
          <RenameField item={item} />
          <FilePreviewPane item={item} open={open} />
        </div>
      </ItemDialog>
      <span className="truncate text-13 text-fg" title={item.filename}>{item.title}</span>
      <Source item={item} />
    </li>
  );
}

/** An export: a frozen copy of what Slides, Designs or Docs made, with a line saying whether its source has changed since. */
function ExportTile({ item, initiallyOpen }: { item: LibraryItem; initiallyOpen: boolean }) {
  const [open, setOpen] = useState(initiallyOpen);
  const app = item.export_source ? SOURCE_APP[item.export_source.kind].label : "";
  return (
    <li className="flex min-w-0 flex-col gap-1.5 rounded-xl border border-border bg-surface-sunken p-3" data-testid="library-item" data-kind="export">
      <span className="text-12 font-semibold text-accent">{typeBadge(item)}{app && ` · from ${app}`}</span>
      <ItemDialog
        item={item}
        open={open}
        onOpenChange={setOpen}
        trigger={<button type="button" aria-label={`Open ${item.title}`} className="min-w-0 truncate text-left text-15 font-semibold text-fg outline-none hover:underline focus-visible:ring-2 focus-visible:ring-accent">{item.title}</button>}
      >
        <div className="flex flex-col gap-3 pb-1">
          <RenameField item={item} />
          <p className="text-14 text-fg-secondary">A copy as it was when you exported it. {fileMeta(item)}</p>
          <ExportSourceLine item={item} />
        </div>
      </ItemDialog>
      <span className="truncate text-12 text-fg-secondary">{fileMeta(item)} · exported {timelineTime(item.created_at)}</span>
      <ExportSourceLine item={item} />
    </li>
  );
}

/** One tile; a click opens the full item with Download, Remove and, for an image, the reference actions. */
function ItemTile({ item, openItem }: { item: LibraryItem; openItem?: string | null }) {
  const del = useDeleteLibraryItem();
  const url = libraryItemUrl(item.id);
  if (item.kind === "video") return <VideoTile item={item} initiallyOpen={openItem === item.id} />;
  if (item.kind === "audio") return <AudioTile item={item} initiallyOpen={openItem === item.id} />;
  if (item.kind === "file") return <FileTile item={item} initiallyOpen={openItem === item.id} />;
  if (item.kind === "export") return <ExportTile item={item} initiallyOpen={openItem === item.id} />;
  if (item.kind === "document") {
    return (
      <li className="flex min-w-0 flex-col gap-1.5 rounded-lg border border-border bg-surface p-3" data-testid="library-item">
        <p className="truncate text-13 font-medium text-fg" title={item.title}>{item.title}</p>
        <div className="flex items-center gap-3 text-13">
          <a className="text-accent hover:underline" href={url} target="_blank" rel="noreferrer">Open</a>
          <button type="button" className="text-fg-secondary hover:text-fg" disabled={del.isPending} onClick={() => del.mutate(item.id)}>Remove</button>
        </div>
      </li>
    );
  }
  const diagram = item.kind === "diagram";
  return (
    <li className="flex min-w-0 flex-col gap-1.5" data-testid="library-item">
      <ItemDialog
        item={item}
        extra={!diagram && <ReferenceActions item={item} />}
        trigger={
          <button
            type="button"
            aria-label={`Open ${item.title}`}
            className="relative aspect-square overflow-hidden rounded-lg border border-border bg-selected outline-none focus-visible:ring-2 focus-visible:ring-accent"
          >
            {/* A same-origin, private URL: next/image would only add a proxy hop. */}
            <img src={url} alt={item.title} loading="lazy" className={cx("size-full", diagram ? "bg-white object-contain p-2" : "object-cover")} />
            <ReferenceBadge item={item} />
          </button>
        }
      >
        <img src={url} alt={item.title} className={cx("min-h-0 max-h-[80vh] w-full object-contain", diagram && "bg-white")} />
      </ItemDialog>
      <span className="truncate text-13 text-fg">{item.title}</span>
      <Source item={item} />
    </li>
  );
}

/** Adds a file of the person's own: an image (e.g. a photo to use as their reference), audio, or any other file. */
/** Picking and uploading a file; the input is drawn once by `UploadInput`, the buttons only call `pick`. */
function useLibraryUpload() {
  const [input, setInput] = useState<HTMLInputElement | null>(null);
  const upload = useUploadLibraryItem();
  const [error, setError] = useState<string | null>(null);
  function take(files: FileList | null) {
    const f = files?.[0];
    if (!f) return;
    const bad = checkLibraryUpload(f);
    if (bad) return setError(bad);
    setError(null);
    upload.mutate(f, { onError: (e) => setError(e.message || "Couldn’t upload the file.") });
  }
  return { setInput, take, pending: upload.isPending, error, pick: () => input?.click() };
}

function UploadInput({ up: { setInput, take } }: { up: ReturnType<typeof useLibraryUpload> }) {
  return (
    <input
      ref={setInput}
      type="file"
      hidden
      aria-label="File to upload"
      onChange={(e) => {
        take(e.target.files);
        e.target.value = "";
      }}
    />
  );
}

function UploadButton({ up }: { up: ReturnType<typeof useLibraryUpload> }) {
  return (
    <div className="flex shrink-0 items-center gap-2">
      {up.error && <span className="text-12 text-pill-blocked-fg">{up.error}</span>}
      <Button variant="secondary" icon="upload" disabled={up.pending} onClick={up.pick}>
        {up.pending ? "Uploading…" : "Upload"}
      </Button>
    </div>
  );
}

const grid = "grid grid-cols-[repeat(auto-fill,minmax(180px,1fr))] gap-4";

/** One kind's items, a page at a time. */
function Items({ kind, openItem }: { kind: LibraryItemKind; openItem?: string | null }) {
  const lib = useLibrary(kind);
  const items = lib.data?.pages.flatMap((p) => p.items) ?? [];
  if (lib.isError) {
    return (
      <Banner tone="blocked" title="Couldn't load your Library" actions={<Button onClick={() => lib.refetch()}>Retry</Button>}>
        {lib.error.message}
      </Banner>
    );
  }
  if (lib.isPending) {
    return (
      <ul aria-busy="true" aria-label="Loading your Library" className={grid}>
        {[0, 1, 2, 3, 4].map((i) => (
          <li key={i} className="flex flex-col gap-1.5">
            <Skeleton className="aspect-square w-full rounded-lg" />
            <Skeleton className="h-3 w-2/3" />
          </li>
        ))}
      </ul>
    );
  }
  if (items.length === 0) {
    return (
      <EmptyState icon="library" title="Nothing here yet">
        {kind === "document"
          ? "Workflows with an Add to library step save their results here."
          : kind === "video"
          ? "When a persona that can code renders a video in a chat, it\u2019s added here once it\u2019s finished."
          : kind === "file"
          ? "No files yet. When a persona that can code hands you a file (a script, a zip, a spreadsheet), it\u2019s kept here. You can also upload one."
          : kind === "export"
          ? "No exports yet. Export a deck, design or document and choose Save to Library to keep the copy here."
          : kind === "audio"
          ? "When a persona that can code renders audio in a chat, it\u2019s added here once it\u2019s finished. You can also upload an MP3, WAV, OGG or M4A file, like a voice memo."
          : kind === "diagram"
          ? "When a persona draws an SVG diagram in a chat, choose Save to Library on it to keep it here."
          : "When a persona that can generate images makes one in a chat, it\u2019s added here. You can also upload your own, like a photo of yourself to use as your reference."}
      </EmptyState>
    );
  }
  return (
    <>
      <ul className={grid}>
        {items.map((it) => (
          <ItemTile key={it.id} item={it} openItem={openItem} />
        ))}
      </ul>
      {lib.hasNextPage && (
        <div className="flex justify-center">
          <Button onClick={() => lib.fetchNextPage()} disabled={lib.isFetchingNextPage}>
            {lib.isFetchingNextPage && <Spinner />}Show more
          </Button>
        </div>
      )}
    </>
  );
}

const KINDS: Record<string, LibraryItemKind> = { images: "image", videos: "video", audio: "audio", files: "file", exports: "export", diagrams: "diagram", documents: "document" };

/** ?source=projects: what agents wrote on tickets; otherwise your keepsakes. */
export function LibraryScreen() {
  return useSearchParams().get("source") === "projects" ? <ProjectDocs /> : <Keepsakes />;
}

const KEEPSAKE_TABS = [
  { key: "images", label: "Images" },
  { key: "videos", label: "Videos" },
  { key: "audio", label: "Audio" },
  { key: "files", label: "Files" },
  { key: "exports", label: "Exports" },
  { key: "diagrams", label: "Diagrams" },
  { key: "documents", label: "Documents" },
  { key: "links", label: "Links" },
  { key: "fridge", label: "Fridge" },
] as const;

function Keepsakes() {
  // A chat's "Open in Library" lands on the item: ?tab=videos&item=<id>.
  const compact = useCompact();
  const up = useLibraryUpload();
  const params = useSearchParams();
  const router = useRouter();
  const [tab, setTab] = useState(() => params.get("tab") ?? "images");
  const openItem = params.get("item");
  return (
    <>
      {!compact && (
        <NavigatorPortal
          native={{
            model: buildKeepsakesNavModel({ tabs: KEEPSAKE_TABS, tab }),
            onCommand: (cmd) => {
              if (cmd.type === "nav.activate") setTab(cmd.itemId);
              else if (cmd.type === "nav.picker" && cmd.pickerId === LIBRARY_SOURCE_PICKER) router.push(librarySourceHref(cmd.value as LibrarySourceValue));
            },
          }}
        >
          <nav aria-label="Library" className="flex min-h-0 flex-1 flex-col gap-3 px-2.5 pt-4 pb-3">
            <div className="px-1">
              <LibrarySourceSwitch source="yours" />
            </div>
            <div role="tablist" aria-label="Library" aria-orientation="vertical" className="flex min-h-0 flex-1 flex-col gap-0.5 overflow-y-auto">
              {KEEPSAKE_TABS.map((item) => {
                const active = tab === item.key;
                return (
                  <button
                    key={item.key}
                    type="button"
                    role="tab"
                    aria-selected={active}
                    onClick={() => setTab(item.key)}
                    className={cx(
                      "flex h-8 items-center rounded-md px-2.5 text-left text-13 transition-colors",
                      active ? "bg-selected font-medium text-fg" : "text-fg-secondary hover:bg-hover hover:text-fg",
                    )}
                  >
                    {item.label}
                  </button>
                );
              })}
            </div>
          </nav>
        </NavigatorPortal>
      )}
      <TopBar crumbs={[{ label: "Library" }]} />
      <Content>
        <div className="flex flex-col gap-5">
          <PageHeader
            title="Library"
            description="Private keepsakes from your chats: generated media, saved files, exports, diagrams, references, and links."
            actions={<UploadButton up={up} />}
            nativeActions={[{ id: "library.upload", label: up.pending ? "Uploading…" : "Upload", kind: "button", icon: "upload", showsLabel: true, disabled: up.pending, run: up.pick }]}
          >
            {compact && <LibrarySourceSwitch source="yours" />}
          </PageHeader>
          <UploadInput up={up} />
          {up.error && isNativeShell() && <p role="alert" className="text-12 text-pill-blocked-fg">{up.error}</p>}
          {compact && <Tabs label="Library" value={tab} onChange={setTab} items={[...KEEPSAKE_TABS]} />}
          {tab === "fridge" ? <Fridge /> : tab === "links" ? <Links /> : <Items kind={KINDS[tab] ?? "image"} openItem={openItem} />}
        </div>
      </Content>
    </>
  );
}
