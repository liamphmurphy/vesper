// Pure layout, thumbnail sizing, and keyboard navigation helpers for PdfViewer.
// Unit-tested in lib/pdf-viewer.test.mjs.

export const PDF_MIN_ZOOM = 0.5;
export const PDF_MAX_ZOOM = 3;
export const PDF_ZOOM_STEP = 0.25;

export type PdfFitMode = "width" | "page";

export type PdfKeyAction =
  | "prev-page"
  | "next-page"
  | "first-page"
  | "last-page"
  | "scroll-up"
  | "scroll-down"
  | "page-scroll-up"
  | "page-scroll-down"
  | "zoom-in"
  | "zoom-out"
  | "zoom-reset"
  | "toggle-fullscreen"
  | "exit-fullscreen";

/** Whether a MIME content-type header names PDF (ignoring optional parameters). */
export function isPdfContentType(contentType?: string | null): boolean {
  return (contentType ?? "").split(";")[0].trim().toLowerCase() === "application/pdf";
}

/**
 * Adds `?download=true` for Library content URLs that serve inline by default,
 * leaving Knowledge asset URLs (already Content-Disposition: attachment) alone.
 */
export function pdfDownloadUrl(url: string): string {
  const hashIdx = url.indexOf("#");
  const baseWithQuery = hashIdx >= 0 ? url.slice(0, hashIdx) : url;
  const hash = hashIdx >= 0 ? url.slice(hashIdx) : "";
  const qIdx = baseWithQuery.indexOf("?");
  const base = qIdx >= 0 ? baseWithQuery.slice(0, qIdx) : baseWithQuery;
  const query = qIdx >= 0 ? baseWithQuery.slice(qIdx + 1) : "";
  if (!/\/api\/v1\/library\/[^/]+\/content$/.test(base)) return url;
  const params = new URLSearchParams(query);
  if (params.has("download")) return url;
  params.set("download", "true");
  return `${base}?${params.toString()}${hash}`;
}

/**
 * The Mac app's native PDF viewer for a same-origin API file (`/pdf` is a native route there, and
 * nothing in a browser). Knowledge opens its PDF embeds with it in the Mac app.
 */
export function nativePdfHref(url: string, title: string): string {
  // %20 rather than URLSearchParams' "+": the Mac app's route parser reads "+" literally.
  return `/pdf?src=${encodeURIComponent(url)}&title=${encodeURIComponent(title)}`;
}

export function clampPage(page: number, numPages: number): number {
  if (numPages <= 0 || !Number.isFinite(page)) return 1;
  return Math.min(Math.max(1, Math.trunc(page)), numPages);
}

export function clampZoom(zoom: number): number {
  if (!Number.isFinite(zoom)) return 1;
  const rounded = Math.round(zoom * 100) / 100;
  return Math.min(PDF_MAX_ZOOM, Math.max(PDF_MIN_ZOOM, rounded));
}

/**
 * Resolves a fixed height class so the viewer's split body (left thumbnail strip
 * + scrollable main stage) stays bounded even when callers pass legacy `max-h-*`.
 */
export function resolveViewerHeightClass(heightClass?: string, maxHeightClass?: string): string {
  const explicit = heightClass?.trim();
  if (explicit) return explicit;
  const legacy = maxHeightClass?.trim();
  if (legacy) return legacy.replace(/(^|\s)max-h-/g, "$1h-");
  return "h-[60vh]";
}

export function computePageScale({
  pageWidth,
  pageHeight,
  viewportWidth,
  viewportHeight,
  zoom,
  fitMode,
  compact,
}: {
  pageWidth: number;
  pageHeight: number;
  viewportWidth: number;
  viewportHeight: number;
  zoom: number;
  fitMode: PdfFitMode;
  compact: boolean;
}): number {
  const safeW = Math.max(pageWidth, 1);
  const safeH = Math.max(pageHeight, 1);
  const padX = compact ? 16 : 32;
  const padY = compact ? 16 : 32;
  const measuredW = viewportWidth > 0 ? viewportWidth : compact ? 360 : 680;
  const availW = Math.max(200, measuredW - padX);
  const widthScale = availW / safeW;

  let baseScale = widthScale;
  if (fitMode === "page" && viewportHeight > 0) {
    const availH = Math.max(200, viewportHeight - padY);
    baseScale = Math.min(widthScale, availH / safeH);
  }

  const clampedBase = Math.min(compact ? 1.5 : 2.5, Math.max(0.2, baseScale));
  return clampedBase * (compact ? 1 : clampZoom(zoom));
}

export interface ThumbnailMetrics {
  thumbWidth: number;
  thumbHeight: number;
  itemHeight: number;
  paneWidth: number;
}

/**
 * Sizes the left thumbnail strip so roughly `targetVisible` (default 5) page
 * thumbnails fit vertically without scrolling while preserving page aspect ratio.
 */
export function computeThumbnailMetrics({
  paneHeight,
  pageWidth,
  pageHeight,
  targetVisible = 5,
}: {
  paneHeight: number;
  pageWidth: number;
  pageHeight: number;
  targetVisible?: number;
}): ThumbnailMetrics {
  const listPadY = 12; // py-1.5
  const itemGap = 6; // gap-1.5
  const itemChromeY = 26; // p-1 (8) + border (2) + gap (4) + page caption (12)
  const effectiveHeight = paneHeight > 0 ? paneHeight : 500;
  const slotHeight = Math.floor((effectiveHeight - listPadY - itemGap * (targetVisible - 1)) / targetVisible);
  const maxCanvasH = Math.max(52, Math.min(140, slotHeight - itemChromeY));
  const maxCanvasW = 124;
  const ratio = Math.max(pageWidth, 1) / Math.max(pageHeight, 1);

  let thumbHeight = maxCanvasH;
  let thumbWidth = Math.round(thumbHeight * ratio);
  if (thumbWidth > maxCanvasW) {
    thumbWidth = maxCanvasW;
    thumbHeight = Math.max(40, Math.round(thumbWidth / ratio));
  }
  thumbWidth = Math.max(44, thumbWidth);

  return {
    thumbWidth,
    thumbHeight,
    itemHeight: thumbHeight + itemChromeY,
    paneWidth: Math.max(96, thumbWidth + 32),
  };
}

type EditableLike = {
  tagName?: unknown;
  isContentEditable?: unknown;
  getAttribute?: (name: string) => string | null;
};

/**
 * Checks whether keyboard events should stay with a text input rather than the PDF viewer.
 * Relies on `isContentEditable === true` (not ancestor selectors) so widgets mounted inside
 * a `contenteditable="false"` ProseMirror island in Knowledge still receive viewer keys.
 */
export function isEditableTarget(target: EventTarget | null): boolean {
  if (!target || typeof target !== "object") return false;
  const el = target as EditableLike;
  if (typeof el.tagName !== "string") return false;
  const tag = el.tagName.toUpperCase();
  if (tag === "INPUT" || tag === "TEXTAREA" || tag === "SELECT") return true;
  if (el.getAttribute?.("role") === "combobox") return true;
  return el.isContentEditable === true;
}

export function resolvePdfKeyAction(
  e: { key: string; ctrlKey?: boolean; metaKey?: boolean; altKey?: boolean; shiftKey?: boolean },
  state: { pageNum: number; numPages: number; fullscreen: boolean; canScrollUp: boolean; canScrollDown: boolean },
): PdfKeyAction | null {
  if (e.altKey || e.metaKey || e.ctrlKey) return null;
  if (e.key === "Escape") return state.fullscreen ? "exit-fullscreen" : null;
  if (state.numPages <= 0) return null;

  switch (e.key) {
    case "ArrowLeft":
      return "prev-page";
    case "ArrowRight":
      return "next-page";
    case "ArrowUp":
      return state.canScrollUp ? "scroll-up" : "prev-page";
    case "ArrowDown":
      return state.canScrollDown ? "scroll-down" : "next-page";
    case "PageUp":
      return state.canScrollUp ? "page-scroll-up" : "prev-page";
    case "PageDown":
      return state.canScrollDown ? "page-scroll-down" : "next-page";
    case " ":
      return e.shiftKey ? (state.canScrollUp ? "page-scroll-up" : "prev-page") : state.canScrollDown ? "page-scroll-down" : "next-page";
    case "Home":
      return "first-page";
    case "End":
      return "last-page";
    case "f":
    case "F":
      return "toggle-fullscreen";
    case "+":
    case "=":
      return "zoom-in";
    case "-":
    case "_":
      return "zoom-out";
    case "0":
      return "zoom-reset";
    default:
      return null;
  }
}
