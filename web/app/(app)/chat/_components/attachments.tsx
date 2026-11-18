"use client";

import { useEffect, useRef, useState, type ClipboardEvent, type DragEvent } from "react";
import { Dialog } from "radix-ui";
import { chatAttachmentUrl, postForm, type Schemas } from "@/lib/api/client";
import { ATTACH_ACCEPT, attachmentBadge, attachmentProblem, MAX_ATTACHMENTS, pastedImageName } from "@/lib/attachments";
import { formatBytes } from "@/lib/files";
import { cx } from "@/lib/cx";
import { isImageType } from "@/lib/persona-ui";
import { Icon } from "@/components/ui/icon";
import { composerIconButton } from "./reply-tools";

type Attachment = Schemas["ChatAttachment"];
type Item = { key: number; name: string; size: number; status: "uploading" | "done" | "error"; id?: string; error?: string; preview?: string };

const chipClass = "inline-flex h-6 max-w-full items-center gap-1.5 rounded-md border px-2 text-12";

function Badge({ name }: { name: string }) {
  return <span className="flex-none rounded bg-selected px-1 font-mono text-10 font-semibold text-fg-secondary">{attachmentBadge(name)}</span>;
}

/**
 * Files for the next message: each one uploads as soon as it's chosen, dropped or
 * pasted and becomes a chip, or a thumbnail if it's an image. `ids` are the finished
 * uploads; `pending` blocks sending.
 */
export function useAttachments() {
  const [items, setItems] = useState<Item[]>([]);
  const next = useRef(0);
  // Keys counted toward the per-message limit: uploading or uploaded, not rejected or removed.
  const live = useRef(new Set<number>());
  const pasted = useRef(0);
  const previews = useRef(new Map<number, string>());
  const patch = (key: number, p: Partial<Item>) => setItems((xs) => xs.map((x) => (x.key === key ? { ...x, ...p } : x)));
  const dropPreview = (key: number) => {
    const url = previews.current.get(key);
    if (url) URL.revokeObjectURL(url);
    previews.current.delete(key);
  };

  useEffect(() => {
    const urls = previews.current;
    return () => {
      urls.forEach((url) => URL.revokeObjectURL(url));
      urls.clear();
    };
  }, []);

  function add(files: File[]) {
    for (const f of files) {
      const key = next.current++;
      const problem = attachmentProblem(f) ?? (live.current.size >= MAX_ATTACHMENTS ? `max ${MAX_ATTACHMENTS} per message` : undefined);
      if (problem) {
        setItems((xs) => [...xs, { key, name: f.name, size: f.size, status: "error", error: problem }]);
        continue;
      }
      live.current.add(key);
      const preview = isImageType(f.type) ? URL.createObjectURL(f) : undefined;
      if (preview) previews.current.set(key, preview);
      setItems((xs) => [...xs, { key, name: f.name, size: f.size, status: "uploading", preview }]);
      const form = new FormData();
      form.append("file", f);
      postForm<Attachment>("/chat-attachments", form).then(
        (a) => patch(key, { status: "done", id: a.id }),
        (e: unknown) => {
          live.current.delete(key);
          patch(key, { status: "error", error: e instanceof Error ? e.message : "upload failed" });
        },
      );
    }
  }
  function remove(key: number) {
    live.current.delete(key);
    dropPreview(key);
    setItems((xs) => xs.filter((x) => x.key !== key));
  }
  // Spreadsheets and rich text also put a picture of the copied text on the
  // clipboard, so anything with text stays an ordinary text paste.
  function onPaste(e: ClipboardEvent) {
    const images = [...e.clipboardData.files].filter((f) => isImageType(f.type));
    if (images.length === 0 || e.clipboardData.getData("text/plain").trim()) return;
    e.preventDefault();
    add(images.map((f) => new File([f], pastedImageName(f.type, ++pasted.current), { type: f.type })));
  }
  return {
    items,
    add,
    remove,
    onPaste,
    pending: items.some((x) => x.status === "uploading"),
    ids: items.flatMap((x) => (x.status === "done" && x.id ? [x.id] : [])),
    clear: () => {
      live.current.clear();
      [...previews.current.keys()].forEach(dropPreview);
      setItems([]);
    },
  };
}

export type Attachments = ReturnType<typeof useAttachments>;

/** The paperclip: opens the file picker. */
export function AttachButton({ onFiles, disabled, compact }: { onFiles: (f: File[]) => void; disabled?: boolean; compact?: boolean }) {
  const input = useRef<HTMLInputElement>(null);
  return (
    <>
      <input
        ref={input}
        type="file"
        multiple
        hidden
        accept={ATTACH_ACCEPT}
        data-testid="attach-input"
        onChange={(e) => {
          onFiles([...(e.target.files ?? [])]);
          e.target.value = "";
        }}
      />
      <button
        type="button"
        aria-label="Attach or drop files"
        title="Attach or drop files"
        disabled={disabled}
        onClick={() => input.current?.click()}
        className={compact ? composerIconButton : "inline-flex h-8 items-center gap-1.5 rounded-md px-2 text-13 text-fg-secondary hover:bg-hover hover:text-fg disabled:opacity-50"}
      >
        <svg aria-hidden viewBox="0 0 16 16" width={16} height={16} fill="none" stroke="currentColor" strokeWidth={1.5} strokeLinecap="round" strokeLinejoin="round">
          <path d="m13 7.5-4.8 4.8a3 3 0 0 1-4.2-4.2l5-5a2 2 0 0 1 2.8 2.8L6.8 10.9a1 1 0 0 1-1.4-1.4L9.7 5.2" />
        </svg>
        {!compact && "Attach"}
      </button>
    </>
  );
}

/** An image waiting to be sent, shown as itself rather than as a named chip. */
function ImagePreview({ item, onRemove }: { item: Item; onRemove: () => void }) {
  return (
    <li data-testid="attachment-chip" data-status={item.status} title={item.name} className="relative size-14 overflow-hidden rounded-md border border-border bg-surface">
      {/* A local blob: URL, which next/image can't optimize. */}
      <img src={item.preview} alt={item.name} data-testid="attachment-preview" className="size-full object-cover" />
      <button
        type="button"
        aria-label={`Remove ${item.name}`}
        onClick={onRemove}
        className="absolute right-0.5 top-0.5 grid size-4 place-items-center rounded-full border border-border bg-surface-raised text-fg-secondary hover:text-fg"
      >
        <Icon name="x" size={10} />
      </button>
      {item.status === "uploading" && (
        <>
          <span className="sr-only">Uploading…</span>
          <span aria-hidden className="absolute inset-x-0 bottom-0 h-0.5 animate-pulse bg-accent" />
        </>
      )}
    </li>
  );
}

/** Chips above the composer: uploading, ready, or rejected (red, with why). Images show a thumbnail. */
export function AttachmentChips({ attachments }: { attachments: Attachments }) {
  if (attachments.items.length === 0) return null;
  return (
    <ul aria-label="Attachments" className="flex flex-wrap items-end gap-1.5" data-testid="attachment-chips">
      {attachments.items.map((x) => x.preview && x.status !== "error" ? (
        <ImagePreview key={x.key} item={x} onRemove={() => attachments.remove(x.key)} />
      ) : (
        <li
          key={x.key}
          data-testid="attachment-chip"
          data-status={x.status}
          className={cx(
            chipClass,
            "relative overflow-hidden",
            x.status === "error" ? "border-pill-blocked-fg/40 bg-surface text-pill-blocked-fg" : "border-border bg-surface text-fg-secondary",
          )}
        >
          {x.status === "error" ? (
            <span role="alert" className="truncate">
              {x.name} · {x.error}
            </span>
          ) : (
            <>
              <Badge name={x.name} />
              <span className="truncate text-fg">{x.name}</span>
              <span className="flex-none text-fg-tertiary">{x.status === "uploading" ? "Uploading…" : formatBytes(x.size)}</span>
            </>
          )}
          <button type="button" aria-label={`Remove ${x.name}`} onClick={() => attachments.remove(x.key)} className="flex-none text-fg-tertiary hover:text-fg">
            <Icon name="x" size={12} />
          </button>
          {x.status === "uploading" && <span aria-hidden className="absolute inset-x-0 bottom-0 h-0.5 animate-pulse bg-accent" />}
        </li>
      ))}
    </ul>
  );
}

/** Non-image files on a message, each a link to its download. */
function FileChips({ attachments, align }: { attachments: Attachment[]; align: "start" | "end" }) {
  return (
    <ul aria-label="Attachments" className={cx("flex flex-wrap gap-1", align === "end" && "justify-end")} data-testid="sent-attachments">
      {attachments.map((a) => (
        <li key={a.id} data-testid="sent-attachment">
          <a
            href={chatAttachmentUrl(a.id)}
            target="_blank"
            rel="noopener noreferrer"
            className={cx(chipClass, "border-border bg-surface text-fg-secondary hover:bg-hover")}
          >
            <Badge name={a.filename} />
            <span className="truncate text-fg">{a.filename}</span>
            <span className="flex-none text-fg-tertiary">{formatBytes(a.size_bytes)}</span>
          </a>
        </li>
      ))}
    </ul>
  );
}

/** An image as a thumbnail; a click opens the full image with a Download action. */
function ImageThumb({ a, compact }: { a: Attachment; compact?: boolean }) {
  const url = chatAttachmentUrl(a.id);
  return (
    <Dialog.Root>
      <Dialog.Trigger asChild>
        <button type="button" aria-label={`Open ${a.filename}`} data-testid="image-attachment" className="cursor-zoom-in rounded-lg outline-none focus-visible:ring-2 focus-visible:ring-accent">
          {/* A same-origin, private URL: next/image would only add a proxy hop. */}
          <img
            src={url}
            alt={a.filename}
            loading="lazy"
            className={cx(
              "w-auto rounded-lg border border-border object-contain",
              compact ? "max-h-48 max-w-[min(320px,100%)]" : "max-h-80 max-w-[min(480px,100%)]",
            )}
          />
        </button>
      </Dialog.Trigger>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby={undefined}
          className="motion-dialog fixed left-1/2 top-1/2 z-50 flex max-h-[92vh] w-[min(1100px,calc(100%-32px))] -translate-x-1/2 -translate-y-1/2 flex-col gap-3 rounded-xl border border-border-float bg-surface-raised p-4 shadow-[var(--shadow-float)] outline-none"
        >
          <div className="flex items-center gap-2">
            <Dialog.Title className="min-w-0 flex-1 truncate text-13 text-fg">{a.filename}</Dialog.Title>
            <a
              href={url}
              download={a.filename}
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
          <img src={url} alt={a.filename} className="min-h-0 max-h-[80vh] w-full object-contain" />
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

/** Images inline (click to preview and download), anything else as a download chip. */
function MessageAttachments({ attachments, align, label, testId }: { attachments?: Attachment[]; align: "start" | "end"; label: string; testId: string }) {
  if (!attachments?.length) return null;
  const images = attachments.filter((a) => isImageType(a.content_type));
  const files = attachments.filter((a) => !isImageType(a.content_type));
  return (
    <div className={cx("flex max-w-full flex-col gap-2", align === "end" ? "items-end" : "items-start")} data-testid={testId}>
      {images.length > 0 && (
        <ul aria-label={label} className={cx("flex flex-wrap gap-2", align === "end" && "justify-end")}>
          {images.map((a) => (
            <li key={a.id}>
              <ImageThumb a={a} compact={align === "end"} />
            </li>
          ))}
        </ul>
      )}
      {files.length > 0 && <FileChips attachments={files} align={align} />}
    </div>
  );
}

/** Files on the person's own message: attached or pasted images inline, the rest as chips. */
export function SentAttachments({ attachments }: { attachments?: Attachment[] }) {
  return <MessageAttachments attachments={attachments} align="end" label="Attached images" testId="message-attachments" />;
}

/** Files on an assistant reply: generated images inline, anything else as a download chip. */
export function ReplyAttachments({ attachments }: { attachments?: Attachment[] }) {
  return <MessageAttachments attachments={attachments} align="start" label="Generated images" testId="reply-attachments" />;
}

/**
 * Drag and drop over an area: spread `props` on its (relative) container and
 * render <DropOverlay over={over} /> inside it. Enter/leave are counted so the
 * overlay doesn't flicker as the pointer crosses child elements.
 */
export function useFileDrop(onFiles: (f: File[]) => void, enabled = true) {
  const [over, setOver] = useState(false);
  const depth = useRef(0);
  const files = (e: DragEvent) => enabled && e.dataTransfer.types.includes("Files");
  const props = {
    onDragEnter: (e: DragEvent) => {
      if (!files(e)) return;
      e.preventDefault();
      depth.current++;
      setOver(true);
    },
    onDragOver: (e: DragEvent) => {
      if (files(e)) e.preventDefault();
    },
    onDragLeave: (e: DragEvent) => {
      if (!files(e)) return;
      depth.current = Math.max(0, depth.current - 1);
      if (depth.current === 0) setOver(false);
    },
    onDrop: (e: DragEvent) => {
      if (!files(e)) return;
      e.preventDefault();
      depth.current = 0;
      setOver(false);
      onFiles([...e.dataTransfer.files]);
    },
  };
  return { over: over && enabled, props };
}

export function DropOverlay({ over }: { over: boolean }) {
  if (!over) return null;
  return (
    <div
      data-testid="drop-overlay"
      className="pointer-events-none absolute inset-0 z-20 grid place-items-center bg-bg/80 p-4 backdrop-blur-[1px]"
    >
      <div className="flex max-w-[420px] flex-col items-center gap-1 rounded-xl border-2 border-dashed border-accent bg-accent/10 px-10 py-8 text-center">
        <p className="text-15 font-semibold text-fg">Drop files to attach</p>
        <p className="text-13 text-fg-secondary">PDF, images, text, Markdown, CSV, zip · up to 25 MB each</p>
        <p className="text-12 text-fg-tertiary">Files become chips in the composer before you send</p>
      </div>
    </div>
  );
}
