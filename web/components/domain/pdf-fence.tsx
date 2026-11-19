"use client";

import Link from "next/link";
import { Dialog } from "radix-ui";
import { useState } from "react";
import { libraryItemUrl } from "@/lib/api/client";
import { useLibraryItem } from "@/lib/api/library-hooks";
import { parsePdfFence } from "@/lib/chat-pdf";
import { formatBytes } from "@/lib/files";
import { Icon } from "@/components/ui/icon";
import { LoadingText } from "@/components/ui/loading";
import { CodeFence } from "./code-fence";
import { PdfViewer } from "./pdf-viewer";

/** A ```pdf fence in chat: page-1 preview card with full PDF viewer dialog, Download and Library link. */
export function PdfFence({ code, info }: { code: string; info?: string }) {
  const id = parsePdfFence(code);
  const q = useLibraryItem(id ?? undefined);
  const [open, setOpen] = useState(false);

  if (!id || q.isError) return <CodeFence code={code} info={info} />;
  const item = q.data;
  if (item && item.content_type !== "application/pdf") return <CodeFence code={code} info={info} />;

  const url = libraryItemUrl(id);
  const downloadUrl = libraryItemUrl(id, true);
  const meta = item ? [item.detail, formatBytes(item.size_bytes)].filter(Boolean).join(" · ") : null;

  return (
    <div data-testid="pdf-card" className="flex w-[380px] max-w-full flex-col overflow-hidden rounded-xl border border-border bg-surface">
      {item ? (
        <button
          type="button"
          onClick={() => setOpen(true)}
          aria-label={`Preview ${item.title}`}
          className="group relative block w-full cursor-pointer border-b border-border-subtle bg-surface-sunken p-2 text-left transition-colors hover:bg-hover focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-accent"
        >
          <PdfViewer url={url} title={item.title} compact />
          <span className="pointer-events-none absolute right-3 top-3 rounded-md bg-surface-raised/90 px-2 py-0.5 text-11 font-medium text-fg shadow-sm opacity-0 transition-opacity group-hover:opacity-100">
            Preview
          </span>
        </button>
      ) : null}

      <div className="flex items-center gap-3 px-3 py-2.5">
        <span className="grid size-8 flex-none place-items-center rounded-lg bg-accent-soft text-11 font-bold tracking-wide text-accent">
          PDF
        </span>
        <div className="flex min-w-0 flex-1 flex-col">
          <span className="truncate text-14 font-semibold text-fg" title={item?.filename}>
            {item ? item.title : <LoadingText />}
          </span>
          <span className="truncate text-12 text-fg-secondary">{meta ?? "Loading PDF…"}</span>
        </div>
        {item ? (
          <div className="flex flex-none items-center gap-1.5">
            <button
              type="button"
              onClick={() => setOpen(true)}
              className="inline-flex h-7 items-center gap-1 rounded-md border border-border bg-surface px-2 text-12 text-fg hover:bg-hover"
            >
              <Icon name="expand" size={12} />
              Open
            </button>
            <a
              href={downloadUrl}
              download={item.filename}
              aria-label={`Download ${item.filename}`}
              className="inline-flex h-7 items-center gap-1 rounded-md border border-btn-secondary-border bg-btn-secondary px-2 text-12 text-fg hover:bg-hover"
            >
              <Icon name="download" size={12} />
            </a>
          </div>
        ) : null}
      </div>

      {item ? (
        <Dialog.Root open={open} onOpenChange={setOpen}>
          <Dialog.Portal>
            <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
            <Dialog.Content
              aria-describedby={undefined}
              className="motion-dialog fixed left-1/2 top-1/2 z-50 flex max-h-[92vh] w-[min(1000px,calc(100%-32px))] -translate-x-1/2 -translate-y-1/2 flex-col gap-3 rounded-xl border border-border-float bg-surface-raised p-4 shadow-[var(--shadow-float)] outline-none"
            >
              <div className="flex flex-wrap items-center gap-2">
                <div className="flex min-w-0 flex-1 flex-col">
                  <Dialog.Title className="truncate text-14 font-semibold text-fg">{item.title}</Dialog.Title>
                  <span className="truncate text-12 text-fg-tertiary">
                    {item.filename}
                    {meta ? ` · ${meta}` : ""}
                  </span>
                </div>
                <Link
                  href={`/library?tab=files&item=${item.id}`}
                  className="text-12 text-accent hover:underline"
                >
                  Open in Library
                </Link>
                <a
                  href={downloadUrl}
                  download={item.filename}
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
              <PdfViewer url={url} title={item.title} heightClass="h-[75vh]" />
            </Dialog.Content>
          </Dialog.Portal>
        </Dialog.Root>
      ) : null}
    </div>
  );
}
