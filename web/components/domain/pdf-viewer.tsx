"use client";

import { useCallback, useEffect, useRef, useState, type KeyboardEvent as ReactKeyboardEvent } from "react";
import workerUrl from "pdfjs-dist/legacy/build/pdf.worker.min.mjs?url";
import type { PDFDocumentProxy, RenderTask } from "pdfjs-dist";
import { Icon } from "@/components/ui/icon";
import { Skeleton } from "@/components/ui/primitives";
import { cx } from "@/lib/cx";
import {
  PDF_MAX_ZOOM,
  PDF_MIN_ZOOM,
  PDF_ZOOM_STEP,
  clampPage,
  clampZoom,
  computePageScale,
  computeThumbnailMetrics,
  isEditableTarget,
  pdfDownloadUrl,
  resolvePdfKeyAction,
  resolveViewerHeightClass,
  type PdfFitMode,
  type PdfKeyAction,
} from "@/lib/pdf-viewer";

let pdfjsPromise: Promise<typeof import("pdfjs-dist/legacy/build/pdf.mjs")> | null = null;

function loadPdfjs() {
  if (!pdfjsPromise) {
    pdfjsPromise = import("pdfjs-dist/legacy/build/pdf.mjs").then((mod) => {
      mod.GlobalWorkerOptions.workerSrc = workerUrl;
      return mod;
    });
  }
  return pdfjsPromise;
}

interface LoadedPdf {
  url: string;
  doc: PDFDocumentProxy | null;
  firstPageSize: { width: number; height: number };
  error: string | null;
}

type FullscreenEl = HTMLDivElement & {
  webkitRequestFullscreen?: () => Promise<void> | void;
};

type FullscreenDoc = Document & {
  webkitFullscreenElement?: Element | null;
  webkitExitFullscreen?: () => Promise<void> | void;
};

function currentFullscreenElement(): Element | null {
  const d = document as FullscreenDoc;
  return document.fullscreenElement ?? d.webkitFullscreenElement ?? null;
}

/**
 * Renders a same-origin PDF onto a HiDPI canvas via pdf.js (legacy build for
 * broad WebKit compatibility). Works even when the API serves PDFs with
 * Content-Disposition: attachment and CSP: default-src 'none'; sandbox.
 */
export function PdfViewer({
  url,
  title,
  compact = false,
  heightClass,
  maxHeightClass = "max-h-[60vh]",
  downloadUrl,
  showThumbnails = true,
  page: controlledPage,
  onPageChange,
  onPagesLoaded,
}: {
  url: string;
  title: string;
  compact?: boolean;
  heightClass?: string;
  maxHeightClass?: string;
  downloadUrl?: string;
  showThumbnails?: boolean;
  page?: number;
  onPageChange?: (page: number) => void;
  onPagesLoaded?: (pages: number) => void;
}) {
  const rootRef = useRef<HTMLDivElement>(null);
  const stageRef = useRef<HTMLDivElement>(null);
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const activeRenderRef = useRef<{ task: RenderTask; done: Promise<void> } | null>(null);
  const onPagesLoadedRef = useRef(onPagesLoaded);
  const onPageChangeRef = useRef(onPageChange);

  useEffect(() => {
    onPagesLoadedRef.current = onPagesLoaded;
    onPageChangeRef.current = onPageChange;
  });

  const [loaded, setLoaded] = useState<LoadedPdf | null>(null);
  const [pageState, setPageState] = useState<{ url: string; page: number }>({ url, page: 1 });
  const [zoom, setZoom] = useState(1);
  const [fitOverride, setFitOverride] = useState<PdfFitMode | null>(null);
  const [thumbsOpen, setThumbsOpen] = useState(true);
  const [nativeFullscreen, setNativeFullscreen] = useState(false);
  const [fallbackFullscreen, setFallbackFullscreen] = useState(false);
  const [renderError, setRenderError] = useState<string | null>(null);
  const [renderedPage, setRenderedPage] = useState<{ url: string; page: number } | null>(null);
  const [stageSize, setStageSize] = useState({ width: 0, height: 0 });

  const fullscreen = nativeFullscreen || fallbackFullscreen;
  const effectiveFitMode: PdfFitMode = fitOverride ?? (fullscreen ? "page" : "width");

  const loading = loaded?.url !== url;
  const doc = loading ? null : loaded.doc;
  const numPages = doc?.numPages ?? 0;
  const rawPage = controlledPage !== undefined ? controlledPage : pageState.url === url ? pageState.page : 1;
  const pageNum = numPages > 0 ? clampPage(rawPage, numPages) : 1;
  const error = loading ? null : loaded.error ?? renderError;
  const firstPageSize = loading ? { width: 612, height: 792 } : loaded.firstPageSize;

  const goToPage = useCallback(
    (next: number) => {
      const target = numPages > 0 ? clampPage(next, numPages) : Math.max(1, Math.trunc(next));
      if (controlledPage === undefined) {
        setPageState({ url, page: target });
      }
      onPageChangeRef.current?.(target);
    },
    [controlledPage, numPages, url],
  );

  // Fetch PDF bytes and load document once per URL.
  useEffect(() => {
    const ac = new AbortController();
    let activeDoc: PDFDocumentProxy | null = null;
    let loadingTask: { destroy: () => Promise<void> } | null = null;

    (async () => {
      try {
        const res = await fetch(url, { credentials: "same-origin", signal: ac.signal });
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const buf = await res.arrayBuffer();
        if (ac.signal.aborted) return;
        const pdfjs = await loadPdfjs();
        const task = pdfjs.getDocument({
          data: new Uint8Array(buf),
          verbosity: 0,
          useSystemFonts: true,
        });
        loadingTask = task;
        activeDoc = await task.promise;
        if (ac.signal.aborted) {
          await activeDoc.destroy();
          return;
        }
        let pageSize = { width: 612, height: 792 };
        try {
          const p1 = await activeDoc.getPage(1);
          const vp1 = p1.getViewport({ scale: 1 });
          pageSize = { width: Math.max(1, vp1.width), height: Math.max(1, vp1.height) };
        } catch {
          // keep Letter aspect ratio fallback
        }
        if (ac.signal.aborted) {
          await activeDoc.destroy();
          return;
        }
        setRenderError(null);
        setLoaded({ url, doc: activeDoc, firstPageSize: pageSize, error: null });
        onPagesLoadedRef.current?.(activeDoc.numPages);
      } catch (e) {
        if (ac.signal.aborted) return;
        setLoaded({
          url,
          doc: null,
          firstPageSize: { width: 612, height: 792 },
          error: e instanceof Error ? e.message : "Couldn't load PDF",
        });
      }
    })();

    return () => {
      ac.abort();
      if (activeDoc) void activeDoc.destroy();
      else void loadingTask?.destroy().catch(() => {});
    };
  }, [url]);

  // Keep stage dimensions current across container resizes, thumbnail toggles, and fullscreen.
  useEffect(() => {
    const el = stageRef.current;
    if (!el) return;
    let raf = 0;
    const measure = () => {
      const nextW = el.clientWidth;
      const nextH = el.clientHeight;
      setStageSize((prev) => (prev.width === nextW && prev.height === nextH ? prev : { width: nextW, height: nextH }));
    };
    raf = requestAnimationFrame(measure);
    const ro = new ResizeObserver(() => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(measure);
    });
    ro.observe(el);
    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  }, [doc, compact]);

  // Reset stage scroll to the top when switching pages.
  const prevPageRef = useRef<{ url: string; page: number }>({ url, page: pageNum });
  useEffect(() => {
    if (prevPageRef.current.url !== url || prevPageRef.current.page !== pageNum) {
      prevPageRef.current = { url, page: pageNum };
      stageRef.current?.scrollTo({ top: 0 });
    }
  }, [url, pageNum]);

  // Render the active page onto the main HiDPI canvas, strictly serializing across cancellations.
  useEffect(() => {
    if (!doc || !canvasRef.current) return;
    let cancelled = false;
    let currentTask: RenderTask | null = null;

    (async () => {
      const prev = activeRenderRef.current;
      if (prev) {
        try {
          prev.task.cancel();
        } catch {
          // ignore cancellation errors
        }
        await prev.done.catch(() => {});
      }
      if (cancelled || !canvasRef.current) return;

      try {
        const page = await doc.getPage(pageNum);
        if (cancelled || !canvasRef.current) return;

        const stage = stageRef.current;
        const vw = stageSize.width || stage?.clientWidth || 0;
        const vh = stageSize.height || stage?.clientHeight || 0;
        const base = page.getViewport({ scale: 1 });
        const scale = computePageScale({
          pageWidth: base.width,
          pageHeight: base.height,
          viewportWidth: vw,
          viewportHeight: vh,
          zoom,
          fitMode: effectiveFitMode,
          compact,
        });
        const dpr = Math.min(window.devicePixelRatio || 1, 2);
        const viewport = page.getViewport({ scale });
        const canvas = canvasRef.current;
        canvas.width = Math.max(1, Math.round(viewport.width * dpr));
        canvas.height = Math.max(1, Math.round(viewport.height * dpr));
        canvas.style.width = `${Math.round(viewport.width)}px`;
        canvas.style.height = `${Math.round(viewport.height)}px`;

        const task = page.render({
          canvas,
          viewport,
          transform: dpr !== 1 ? [dpr, 0, 0, dpr, 0, 0] : undefined,
          background: "#ffffff",
        });
        currentTask = task;
        const done = task.promise.then(
          () => undefined,
          () => undefined,
        );
        activeRenderRef.current = { task, done };

        await task.promise;
        if (activeRenderRef.current?.task === task) activeRenderRef.current = null;
        if (!cancelled) {
          setRenderError(null);
          setRenderedPage({ url, page: pageNum });
        }
      } catch (e) {
        if (currentTask && activeRenderRef.current?.task === currentTask) {
          activeRenderRef.current = null;
        }
        if (cancelled) return;
        if (e instanceof Error && e.name === "RenderingCancelledException") return;
        setRenderError(e instanceof Error ? e.message : "Couldn't render PDF page");
      }
    })();

    return () => {
      cancelled = true;
      try {
        currentTask?.cancel();
      } catch {
        // ignore cancellation errors
      }
    };
  }, [doc, url, pageNum, zoom, compact, effectiveFitMode, stageSize.width, stageSize.height]);

  // Sync native browser/WebKit fullscreen transitions.
  useEffect(() => {
    const onFullscreenChange = () => {
      const active = !!rootRef.current && currentFullscreenElement() === rootRef.current;
      setNativeFullscreen(active);
      setFitOverride(null);
      if (active) {
        rootRef.current?.focus({ preventScroll: true });
      }
    };
    document.addEventListener("fullscreenchange", onFullscreenChange);
    document.addEventListener("webkitfullscreenchange", onFullscreenChange);
    return () => {
      document.removeEventListener("fullscreenchange", onFullscreenChange);
      document.removeEventListener("webkitfullscreenchange", onFullscreenChange);
    };
  }, []);

  const enterFullscreen = useCallback(async () => {
    const el = rootRef.current as FullscreenEl | null;
    if (!el) return;
    setFitOverride(null);
    try {
      if (el.requestFullscreen) {
        await el.requestFullscreen({ navigationUI: "hide" });
        el.focus({ preventScroll: true });
        return;
      }
      if (el.webkitRequestFullscreen) {
        await el.webkitRequestFullscreen();
        el.focus({ preventScroll: true });
        return;
      }
    } catch {
      try {
        if (el.requestFullscreen) {
          await el.requestFullscreen();
          el.focus({ preventScroll: true });
          return;
        }
      } catch {
        // fall back to fixed-viewport fullscreen when native fullscreen is unavailable
      }
    }
    setFallbackFullscreen(true);
    requestAnimationFrame(() => el.focus({ preventScroll: true }));
  }, []);

  const exitFullscreen = useCallback(async () => {
    setFallbackFullscreen(false);
    setFitOverride(null);
    const d = document as FullscreenDoc;
    if (document.fullscreenElement) {
      try {
        await document.exitFullscreen();
      } catch {
        // already exited
      }
    } else if (d.webkitFullscreenElement && d.webkitExitFullscreen) {
      try {
        await d.webkitExitFullscreen();
      } catch {
        // already exited
      }
    }
  }, []);

  const toggleFullscreen = useCallback(() => {
    if (fullscreen) void exitFullscreen();
    else void enterFullscreen();
  }, [fullscreen, enterFullscreen, exitFullscreen]);

  const performKeyAction = useCallback(
    (action: PdfKeyAction) => {
      const stage = stageRef.current;
      switch (action) {
        case "prev-page":
          goToPage(pageNum - 1);
          break;
        case "next-page":
          goToPage(pageNum + 1);
          break;
        case "first-page":
          goToPage(1);
          break;
        case "last-page":
          goToPage(numPages);
          break;
        case "scroll-up":
          if (stage) stage.scrollTop -= 80;
          break;
        case "scroll-down":
          if (stage) stage.scrollTop += 80;
          break;
        case "page-scroll-up":
          if (stage) stage.scrollTop -= Math.max(120, Math.round(stage.clientHeight * 0.85));
          break;
        case "page-scroll-down":
          if (stage) stage.scrollTop += Math.max(120, Math.round(stage.clientHeight * 0.85));
          break;
        case "zoom-in":
          setZoom((z) => clampZoom(z + PDF_ZOOM_STEP));
          break;
        case "zoom-out":
          setZoom((z) => clampZoom(z - PDF_ZOOM_STEP));
          break;
        case "zoom-reset":
          setZoom(1);
          break;
        case "toggle-fullscreen":
          toggleFullscreen();
          break;
        case "exit-fullscreen":
          void exitFullscreen();
          break;
      }
    },
    [exitFullscreen, goToPage, numPages, pageNum, toggleFullscreen],
  );

  const handleKeyboardEvent = useCallback(
    (e: Pick<KeyboardEvent, "key" | "ctrlKey" | "metaKey" | "altKey" | "shiftKey" | "target" | "preventDefault" | "stopPropagation">): boolean => {
      if (isEditableTarget(e.target)) return false;
      if (e.key === " " && e.target instanceof Element && e.target.closest("button, a")) return false;
      const stage = stageRef.current;
      const canScrollUp = !!stage && stage.scrollTop > 2;
      const canScrollDown = !!stage && stage.scrollTop + stage.clientHeight < stage.scrollHeight - 2;
      const action = resolvePdfKeyAction(e, { pageNum, numPages, fullscreen, canScrollUp, canScrollDown });
      if (!action) return false;
      e.preventDefault();
      e.stopPropagation();
      performKeyAction(action);
      return true;
    },
    [fullscreen, numPages, pageNum, performKeyAction],
  );

  // Capture keyboard navigation globally while fullscreen so focus never gets trapped outside rootRef.
  useEffect(() => {
    if (!fullscreen || compact) return;
    const onWindowKey = (e: KeyboardEvent) => {
      if (e.defaultPrevented) return;
      handleKeyboardEvent(e);
    };
    window.addEventListener("keydown", onWindowKey, { capture: true });
    return () => window.removeEventListener("keydown", onWindowKey, { capture: true });
  }, [compact, fullscreen, handleKeyboardEvent]);

  const onRootKeyDown = (e: ReactKeyboardEvent<HTMLDivElement>) => {
    if (compact || fullscreen) return;
    handleKeyboardEvent(e);
  };

  if (loading) {
    return <Skeleton className={cx("w-full rounded-lg", compact ? "h-44" : "h-64")} />;
  }
  if (error) {
    return (
      <div className="flex items-center justify-between gap-3 rounded-lg border border-border-subtle bg-surface-sunken px-3 py-2.5 text-12 text-fg-secondary">
        <span>Couldn&apos;t preview PDF ({error}).</span>
        <a href={downloadUrl ?? pdfDownloadUrl(url)} download className="text-accent hover:underline">
          Download
        </a>
      </div>
    );
  }

  if (compact) {
    return (
      <div ref={rootRef} data-pdf-viewer="" className="flex flex-col overflow-hidden rounded-lg bg-surface-sunken">
        <div ref={stageRef} className="flex max-h-[240px] items-start justify-center overflow-hidden p-2">
          <canvas
            ref={canvasRef}
            role="img"
            aria-label={`${title} — page ${pageNum}`}
            data-rendered-page={renderedPage?.url === url ? renderedPage.page : undefined}
            className="block shrink-0 rounded-sm bg-white shadow-sm"
          />
        </div>
      </div>
    );
  }

  const resolvedHeight = resolveViewerHeightClass(heightClass, maxHeightClass);
  const keepViewerFocusOnDisabled = (becomesDisabled: boolean) => {
    if (becomesDisabled) rootRef.current?.focus({ preventScroll: true });
  };

  return (
    <div
      ref={rootRef}
      tabIndex={0}
      role="region"
      aria-label={`${title} PDF viewer`}
      data-pdf-viewer=""
      data-fullscreen={fullscreen ? "true" : "false"}
      onKeyDown={onRootKeyDown}
      className={cx(
        "flex min-h-0 flex-col overflow-hidden outline-none focus-visible:ring-1 focus-visible:ring-accent",
        nativeFullscreen
          ? "size-full bg-bg text-fg"
          : fallbackFullscreen
            ? "fixed inset-0 z-[100] h-dvh w-screen bg-bg text-fg"
            : cx("rounded-lg border border-border-subtle bg-surface", resolvedHeight),
      )}
    >
      {numPages > 0 && (
        <div className="flex flex-none select-none flex-wrap items-center justify-between gap-2 border-b border-border-subtle bg-surface-sunken px-2.5 py-1.5 text-12 text-fg-secondary">
          <div className="flex items-center gap-1.5">
            {showThumbnails && (
              <button
                type="button"
                aria-label={thumbsOpen ? "Hide thumbnails" : "Show thumbnails"}
                aria-pressed={thumbsOpen}
                title={thumbsOpen ? "Hide thumbnails" : "Show thumbnails"}
                onClick={() => setThumbsOpen((v) => !v)}
                className={cx(
                  "grid size-6 place-items-center rounded border border-border hover:bg-hover",
                  thumbsOpen ? "bg-selected text-fg" : "bg-surface text-fg-secondary",
                )}
              >
                <Icon name="sidebar" size={12} />
              </button>
            )}
            <button
              type="button"
              aria-label="Previous page"
              disabled={pageNum <= 1}
              onClick={() => {
                keepViewerFocusOnDisabled(pageNum - 1 <= 1);
                goToPage(pageNum - 1);
              }}
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
              onClick={() => {
                keepViewerFocusOnDisabled(pageNum + 1 >= numPages);
                goToPage(pageNum + 1);
              }}
              className="grid size-6 place-items-center rounded border border-border bg-surface text-fg hover:bg-hover disabled:opacity-40"
            >
              <Icon name="chevr" size={12} />
            </button>
          </div>
          <div className="flex items-center gap-1">
            <button
              type="button"
              aria-label="Zoom out"
              disabled={zoom <= PDF_MIN_ZOOM}
              onClick={() => {
                const next = clampZoom(zoom - PDF_ZOOM_STEP);
                keepViewerFocusOnDisabled(next <= PDF_MIN_ZOOM);
                setZoom(next);
              }}
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
              disabled={zoom >= PDF_MAX_ZOOM}
              onClick={() => {
                const next = clampZoom(zoom + PDF_ZOOM_STEP);
                keepViewerFocusOnDisabled(next >= PDF_MAX_ZOOM);
                setZoom(next);
              }}
              className="h-6 rounded border border-border bg-surface px-2 text-12 text-fg hover:bg-hover disabled:opacity-40"
            >
              +
            </button>
            <button
              type="button"
              aria-label={effectiveFitMode === "page" ? "Fit width" : "Fit page"}
              title={effectiveFitMode === "page" ? "Fit width" : "Fit page"}
              onClick={() => setFitOverride(effectiveFitMode === "page" ? "width" : "page")}
              className="h-6 rounded border border-border bg-surface px-2 text-11 text-fg-secondary hover:bg-hover"
            >
              {effectiveFitMode === "page" ? "Fit width" : "Fit page"}
            </button>
            {downloadUrl && (
              <a
                href={downloadUrl}
                download
                aria-label={`Download ${title}`}
                title="Download"
                className="grid size-6 place-items-center rounded border border-border bg-surface text-fg hover:bg-hover"
              >
                <Icon name="download" size={12} />
              </a>
            )}
            <button
              type="button"
              data-testid="pdf-fullscreen-toggle"
              aria-label={fullscreen ? "Exit fullscreen" : "Fullscreen"}
              title={fullscreen ? "Exit fullscreen (Esc)" : "Fullscreen (F)"}
              onClick={toggleFullscreen}
              className="grid size-6 place-items-center rounded border border-border bg-surface text-fg hover:bg-hover"
            >
              <Icon name={fullscreen ? "shrink" : "expand"} size={12} />
            </button>
          </div>
        </div>
      )}

      <div className="flex min-h-0 flex-1 overflow-hidden">
        {showThumbnails && thumbsOpen && doc && numPages > 0 && (
          <PdfThumbnailStrip
            key={url}
            doc={doc}
            pageNum={pageNum}
            firstPageSize={firstPageSize}
            onSelect={goToPage}
          />
        )}
        <div
          ref={stageRef}
          onClick={() => rootRef.current?.focus({ preventScroll: true })}
          className="min-w-0 flex-1 overflow-auto bg-surface-sunken p-4"
        >
          <div className="mx-auto w-fit">
            <canvas
              ref={canvasRef}
              role="img"
              aria-label={`${title} — page ${pageNum}`}
              data-rendered-page={renderedPage?.url === url ? renderedPage.page : undefined}
              className="block shrink-0 rounded-sm bg-white shadow-sm"
            />
          </div>
        </div>
      </div>
    </div>
  );
}

const EAGER_THUMBS = [1, 2, 3, 4, 5, 6, 7];

function PdfThumbnailStrip({
  doc,
  pageNum,
  firstPageSize,
  onSelect,
}: {
  doc: PDFDocumentProxy;
  pageNum: number;
  firstPageSize: { width: number; height: number };
  onSelect: (page: number) => void;
}) {
  const navRef = useRef<HTMLElement>(null);
  const buttonsRef = useRef<Map<number, HTMLButtonElement>>(new Map());
  const canvasesRef = useRef<Map<number, HTMLCanvasElement>>(new Map());
  const renderedKeysRef = useRef<Map<number, string>>(new Map());
  const queueRef = useRef<Promise<void>>(Promise.resolve());

  const [paneHeight, setPaneHeight] = useState(500);
  const [requestedPages, setRequestedPages] = useState<Set<number>>(() => new Set(EAGER_THUMBS));

  // Measure the thumbnail pane height so ~5 thumbnails fit comfortably without scrolling.
  useEffect(() => {
    const el = navRef.current;
    if (!el) return;
    let raf = 0;
    const measure = () => {
      const h = el.clientHeight;
      if (h > 0) setPaneHeight((prev) => (prev === h ? prev : h));
    };
    raf = requestAnimationFrame(measure);
    const ro = new ResizeObserver(() => {
      cancelAnimationFrame(raf);
      raf = requestAnimationFrame(measure);
    });
    ro.observe(el);
    return () => {
      cancelAnimationFrame(raf);
      ro.disconnect();
    };
  }, []);

  const metrics = computeThumbnailMetrics({
    paneHeight,
    pageWidth: firstPageSize.width,
    pageHeight: firstPageSize.height,
    targetVisible: 5,
  });

  // Lazily mark scrolled-into-view thumbnails for rendering.
  useEffect(() => {
    const root = navRef.current;
    if (!root || typeof IntersectionObserver === "undefined") return;
    const observer = new IntersectionObserver(
      (entries) => {
        const newlyVisible: number[] = [];
        for (const entry of entries) {
          if (!entry.isIntersecting) continue;
          const p = Number(entry.target.getAttribute("data-page"));
          if (Number.isInteger(p) && p >= 1) newlyVisible.push(p);
        }
        if (newlyVisible.length === 0) return;
        setRequestedPages((prev) => {
          if (newlyVisible.every((p) => prev.has(p))) return prev;
          const next = new Set(prev);
          for (const p of newlyVisible) next.add(p);
          return next;
        });
      },
      { root, rootMargin: "200px 0px", threshold: 0.01 },
    );
    for (const btn of buttonsRef.current.values()) {
      observer.observe(btn);
    }
    return () => observer.disconnect();
  }, [doc.numPages]);

  // Render queued thumbnails one at a time via the shared serialized queue.
  useEffect(() => {
    let cancelled = false;
    let activeTask: RenderTask | null = null;
    const sizeKey = `${metrics.thumbWidth}x${metrics.thumbHeight}`;

    const candidates = new Set<number>(requestedPages);
    for (const adj of [pageNum - 1, pageNum, pageNum + 1]) {
      if (adj >= 1 && adj <= doc.numPages) candidates.add(adj);
    }
    const ordered = [...candidates]
      .filter((n) => n >= 1 && n <= doc.numPages && renderedKeysRef.current.get(n) !== sizeKey)
      .sort((a, b) => Math.abs(a - pageNum) - Math.abs(b - pageNum) || a - b);

    if (ordered.length === 0) return;

    const prevDone = queueRef.current;
    let release!: () => void;
    queueRef.current = new Promise<void>((res) => {
      release = res;
    });

    (async () => {
      try {
        await prevDone;
        const dpr = Math.min(window.devicePixelRatio || 1, 2);
        for (const n of ordered) {
          if (cancelled) return;
          const canvas = canvasesRef.current.get(n);
          if (!canvas) continue;
          try {
            const page = await doc.getPage(n);
            if (cancelled) return;
            const base = page.getViewport({ scale: 1 });
            const scale = Math.min(
              metrics.thumbWidth / Math.max(base.width, 1),
              metrics.thumbHeight / Math.max(base.height, 1),
            );
            const viewport = page.getViewport({ scale });
            canvas.width = Math.max(1, Math.round(viewport.width * dpr));
            canvas.height = Math.max(1, Math.round(viewport.height * dpr));
            canvas.style.width = `${Math.round(viewport.width)}px`;
            canvas.style.height = `${Math.round(viewport.height)}px`;

            const task = page.render({
              canvas,
              viewport,
              transform: dpr !== 1 ? [dpr, 0, 0, dpr, 0, 0] : undefined,
              background: "#ffffff",
            });
            activeTask = task;
            await task.promise;
            activeTask = null;
            if (!cancelled) {
              renderedKeysRef.current.set(n, sizeKey);
              canvas.setAttribute("data-thumb-rendered", "true");
            }
          } catch (e) {
            activeTask = null;
            if (cancelled) return;
            if (e instanceof Error && e.name === "RenderingCancelledException") return;
          }
        }
      } finally {
        release();
      }
    })();

    return () => {
      cancelled = true;
      try {
        activeTask?.cancel();
      } catch {
        // ignore cancellation errors
      }
    };
  }, [doc, requestedPages, pageNum, metrics.thumbWidth, metrics.thumbHeight]);

  // Keep the active thumbnail visible inside this pane only (never scrolling the outer page).
  useEffect(() => {
    const nav = navRef.current;
    const btn = buttonsRef.current.get(pageNum);
    if (!nav || !btn) return;
    const navRect = nav.getBoundingClientRect();
    const btnRect = btn.getBoundingClientRect();
    if (btnRect.top < navRect.top + 4) {
      nav.scrollTop -= navRect.top + 4 - btnRect.top;
    } else if (btnRect.bottom > navRect.bottom - 4) {
      nav.scrollTop += btnRect.bottom - (navRect.bottom - 4);
    }
  }, [pageNum]);

  return (
    <nav
      ref={navRef}
      aria-label="Page thumbnails"
      data-testid="pdf-thumbnails"
      style={{ width: metrics.paneWidth }}
      className="flex h-full flex-none select-none flex-col gap-1.5 overflow-y-auto border-r border-border-subtle bg-surface px-2 py-1.5"
    >
      {Array.from({ length: doc.numPages }, (_, idx) => {
        const n = idx + 1;
        const active = n === pageNum;
        return (
          <button
            key={n}
            ref={(el) => {
              if (el) buttonsRef.current.set(n, el);
              else buttonsRef.current.delete(n);
            }}
            type="button"
            data-testid="pdf-thumbnail"
            data-page={n}
            aria-label={`Page ${n}`}
            aria-current={active ? "page" : undefined}
            onClick={() => onSelect(n)}
            className={cx(
              "flex flex-none flex-col items-center rounded-md border p-1 outline-none transition-colors focus-visible:ring-2 focus-visible:ring-accent",
              active ? "border-accent bg-accent-soft/50 ring-1 ring-accent" : "border-transparent hover:border-border-strong hover:bg-hover",
            )}
          >
            <span
              style={{ width: metrics.thumbWidth, height: metrics.thumbHeight }}
              className="grid place-items-center overflow-hidden rounded-[2px] border border-border-subtle bg-white"
            >
              <canvas
                ref={(el) => {
                  if (el) canvasesRef.current.set(n, el);
                  else canvasesRef.current.delete(n);
                }}
                aria-hidden="true"
                className="block"
              />
            </span>
            <span className={cx("mt-1 font-mono text-10 leading-3", active ? "font-semibold text-accent" : "text-fg-tertiary")}>
              {n}
            </span>
          </button>
        );
      })}
    </nav>
  );
}
