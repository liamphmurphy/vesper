"use client";

import { useEffect, useRef, useState } from "react";
import workerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";
import type { PDFDocumentProxy } from "pdfjs-dist";
import { Icon } from "@/components/ui/icon";
import { Skeleton } from "@/components/ui/primitives";
import { cx } from "@/lib/cx";

let pdfjsPromise: Promise<typeof import("pdfjs-dist")> | null = null;

function loadPdfjs() {
  if (!pdfjsPromise) {
    pdfjsPromise = import("pdfjs-dist").then((mod) => {
      mod.GlobalWorkerOptions.workerSrc = workerUrl;
      return mod;
    });
  }
  return pdfjsPromise;
}

interface LoadedPdf {
  url: string;
  doc: PDFDocumentProxy | null;
  error: string | null;
}

/**
 * Renders a same-origin PDF onto a HiDPI canvas via pdf.js.
 * Works even when the API serves PDFs with Content-Disposition: attachment and
 * CSP: default-src 'none'; sandbox (no iframe or plugin needed).
 */
export function PdfViewer({
  url,
  title,
  compact = false,
  maxHeightClass = "max-h-[60vh]",
  onPagesLoaded,
}: {
  url: string;
  title: string;
  compact?: boolean;
  maxHeightClass?: string;
  onPagesLoaded?: (pages: number) => void;
}) {
  const containerRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const [loaded, setLoaded] = useState<LoadedPdf | null>(null);
  const [pageState, setPageState] = useState<{ url: string; page: number }>({ url, page: 1 });
  const [zoom, setZoom] = useState(1);
  const [renderError, setRenderError] = useState<string | null>(null);

  const loading = loaded?.url !== url;
  const doc = loading ? null : loaded.doc;
  const numPages = doc?.numPages ?? 0;
  const pageNum = pageState.url === url ? Math.min(Math.max(1, pageState.page), Math.max(1, numPages)) : 1;
  const error = loading ? null : loaded.error ?? renderError;

  useEffect(() => {
    const ac = new AbortController();
    let activeDoc: PDFDocumentProxy | null = null;

    (async () => {
      try {
        const res = await fetch(url, { credentials: "same-origin", signal: ac.signal });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const buf = await res.arrayBuffer();
        if (ac.signal.aborted) return;
        const pdfjs = await loadPdfjs();
        const task = pdfjs.getDocument({ data: new Uint8Array(buf), verbosity: 0 });
        activeDoc = await task.promise;
        if (ac.signal.aborted) {
          await activeDoc.destroy();
          return;
        }
        setRenderError(null);
        setLoaded({ url, doc: activeDoc, error: null });
        onPagesLoaded?.(activeDoc.numPages);
      } catch (e) {
        if (ac.signal.aborted) return;
        setLoaded({ url, doc: null, error: e instanceof Error ? e.message : "Couldn't load PDF" });
      }
    })();

    return () => {
      ac.abort();
      if (activeDoc) void activeDoc.destroy();
    };
  }, [url, onPagesLoaded]);

  useEffect(() => {
    if (!doc || !canvasRef.current) return;
    let cancelled = false;
    let renderTask: { cancel: () => void; promise: Promise<void> } | null = null;

    (async () => {
      try {
        const page = await doc.getPage(pageNum);
        if (cancelled || !canvasRef.current) return;
        const base = page.getViewport({ scale: 1 });
        const availW = Math.max(240, (containerRef.current?.clientWidth ?? (compact ? 360 : 720)) - (compact ? 16 : 32));
        const fitScale = Math.min(compact ? 1.5 : 2, availW / Math.max(base.width, 1));
        const scale = fitScale * (compact ? 1 : zoom);
        const dpr = Math.min(window.devicePixelRatio || 1, 2);
        const vp = page.getViewport({ scale: scale * dpr });
        const canvas = canvasRef.current;
        canvas.width = Math.max(1, Math.round(vp.width));
        canvas.height = Math.max(1, Math.round(vp.height));
        canvas.style.width = `${Math.round(vp.width / dpr)}px`;
        canvas.style.height = `${Math.round(vp.height / dpr)}px`;
        const ctx = canvas.getContext("2d");
        if (!ctx) return;
        ctx.fillStyle = "#ffffff";
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        renderTask = page.render({ canvas, canvasContext: ctx, viewport: vp });
        await renderTask.promise;
        if (!cancelled) setRenderError(null);
      } catch (e) {
        if (cancelled) return;
        if (e instanceof Error && e.name === "RenderingCancelledException") return;
        setRenderError(e instanceof Error ? e.message : "Couldn't render PDF page");
      }
    })();

    return () => {
      cancelled = true;
      try {
        renderTask?.cancel();
      } catch {
        // ignore cancellation errors
      }
    };
  }, [doc, pageNum, zoom, compact]);

  if (loading) {
    return <Skeleton className={cx("w-full rounded-lg", compact ? "h-44" : "h-64")} />;
  }
  if (error) {
    return (
      <div className="flex items-center justify-between gap-3 rounded-lg border border-border-subtle bg-surface-sunken px-3 py-2.5 text-12 text-fg-secondary">
        <span>Couldn&apos;t preview PDF ({error}).</span>
        <a href={url} download className="text-accent hover:underline">
          Download
        </a>
      </div>
    );
  }

  return (
    <div ref={containerRef} className="flex flex-col gap-2">
      {!compact && numPages > 0 && (
        <div className="flex flex-wrap items-center justify-between gap-2 rounded-lg border border-border-subtle bg-surface-sunken px-2.5 py-1.5 text-12 text-fg-secondary">
          <div className="flex items-center gap-1.5">
            <button
              type="button"
              aria-label="Previous page"
              disabled={pageNum <= 1}
              onClick={() => setPageState({ url, page: Math.max(1, pageNum - 1) })}
              className="grid size-6 place-items-center rounded border border-border bg-surface text-fg hover:bg-hover disabled:opacity-40"
            >
              <Icon name="chevr" size={12} className="rotate-180" />
            </button>
            <span className="px-1 font-mono text-12 text-fg" data-testid="pdf-page-indicator">
              {pageNum} / {numPages}
            </span>
            <button
              type="button"
              aria-label="Next page"
              disabled={pageNum >= numPages}
              onClick={() => setPageState({ url, page: Math.min(numPages, pageNum + 1) })}
              className="grid size-6 place-items-center rounded border border-border bg-surface text-fg hover:bg-hover disabled:opacity-40"
            >
              <Icon name="chevr" size={12} />
            </button>
          </div>
          <div className="flex items-center gap-1">
            <button
              type="button"
              aria-label="Zoom out"
              disabled={zoom <= 0.75}
              onClick={() => setZoom((z) => Math.max(0.75, Math.round((z - 0.25) * 100) / 100))}
              className="h-6 rounded border border-border bg-surface px-2 text-12 text-fg hover:bg-hover disabled:opacity-40"
            >
              −
            </button>
            <button
              type="button"
              aria-label="Reset zoom"
              onClick={() => setZoom(1)}
              className="h-6 rounded border border-border bg-surface px-2 font-mono text-11 text-fg-secondary hover:bg-hover"
            >
              {Math.round(zoom * 100)}%
            </button>
            <button
              type="button"
              aria-label="Zoom in"
              disabled={zoom >= 2}
              onClick={() => setZoom((z) => Math.min(2, Math.round((z + 0.25) * 100) / 100))}
              className="h-6 rounded border border-border bg-surface px-2 text-12 text-fg hover:bg-hover disabled:opacity-40"
            >
              +
            </button>
          </div>
        </div>
      )}
      <div
        className={cx(
          "flex justify-center overflow-auto rounded-lg border border-border-subtle bg-surface-sunken",
          compact ? "max-h-[240px] items-start overflow-hidden p-2" : cx("p-4", maxHeightClass),
        )}
      >
        <canvas
          ref={canvasRef}
          role="img"
          aria-label={`${title} — page ${pageNum}`}
          className="rounded-sm bg-white shadow-sm"
        />
      </div>
    </div>
  );
}
