import test from "node:test";
import assert from "node:assert/strict";
import { jsPDF } from "jspdf";
import {
  clampPage,
  clampZoom,
  computePageScale,
  computeThumbnailMetrics,
  isEditableTarget,
  isPdfContentType,
  pdfDownloadUrl,
  resolvePdfKeyAction,
  resolveViewerHeightClass,
} from "./pdf-viewer.ts";

test("isPdfContentType matches application/pdf with or without parameters", () => {
  assert.equal(isPdfContentType("application/pdf"), true);
  assert.equal(isPdfContentType("APPLICATION/PDF; charset=utf-8"), true);
  assert.equal(isPdfContentType("image/png"), false);
  assert.equal(isPdfContentType(undefined), false);
});

test("pdfDownloadUrl appends download=true only to Library content URLs", () => {
  assert.equal(pdfDownloadUrl("/api/v1/library/123/content"), "/api/v1/library/123/content?download=true");
  assert.equal(pdfDownloadUrl("/api/v1/library/123/content?foo=bar"), "/api/v1/library/123/content?foo=bar&download=true");
  assert.equal(pdfDownloadUrl("/api/v1/library/123/content?download=true"), "/api/v1/library/123/content?download=true");
  assert.equal(pdfDownloadUrl("/api/v1/knowledge/assets/abc"), "/api/v1/knowledge/assets/abc");
});

test("clampPage and clampZoom enforce safe bounds", () => {
  assert.equal(clampPage(0, 5), 1);
  assert.equal(clampPage(9, 5), 5);
  assert.equal(clampPage(3.9, 5), 3);
  assert.equal(clampPage(NaN, 5), 1);
  assert.equal(clampPage(2, 0), 1);

  assert.equal(clampZoom(0.1), 0.5);
  assert.equal(clampZoom(4.5), 3);
  assert.equal(clampZoom(1.254), 1.25);
  assert.equal(clampZoom(NaN), 1);
});

test("resolveViewerHeightClass prefers explicit heightClass and normalizes legacy max-h-*", () => {
  assert.equal(resolveViewerHeightClass("h-[75vh]", "max-h-[60vh]"), "h-[75vh]");
  assert.equal(resolveViewerHeightClass(undefined, "max-h-[540px]"), "h-[540px]");
  assert.equal(resolveViewerHeightClass(undefined, undefined), "h-[60vh]");
});

test("computePageScale fits width, fits page, handles zero viewport, and respects compact", () => {
  const widthFit = computePageScale({
    pageWidth: 612,
    pageHeight: 792,
    viewportWidth: 644,
    viewportHeight: 500,
    zoom: 1,
    fitMode: "width",
    compact: false,
  });
  assert.ok(Math.abs(widthFit - 1) < 1e-6);

  const pageFit = computePageScale({
    pageWidth: 612,
    pageHeight: 792,
    viewportWidth: 1200,
    viewportHeight: 428,
    zoom: 1,
    fitMode: "page",
    compact: false,
  });
  // (428 - 32) / 792 = 0.5
  assert.ok(Math.abs(pageFit - 0.5) < 1e-6);

  const zeroViewport = computePageScale({
    pageWidth: 612,
    pageHeight: 792,
    viewportWidth: 0,
    viewportHeight: 0,
    zoom: 1.5,
    fitMode: "page",
    compact: false,
  });
  assert.ok(Math.abs(zeroViewport - ((680 - 32) / 612) * 1.5) < 1e-6);

  const compactScale = computePageScale({
    pageWidth: 300,
    pageHeight: 400,
    viewportWidth: 800,
    viewportHeight: 600,
    zoom: 2,
    fitMode: "width",
    compact: true,
  });
  assert.equal(compactScale, 1.5);
});

test("computeThumbnailMetrics sizes ~5 thumbnails into view across inline, modal, and fullscreen heights", () => {
  for (const paneHeight of [502, 600, 850]) {
    for (const [pageWidth, pageHeight] of [
      [612, 792], // portrait Letter
      [792, 612], // landscape Letter
    ]) {
      const m = computeThumbnailMetrics({ paneHeight, pageWidth, pageHeight });
      const fiveHeight = 5 * m.itemHeight + 4 * 6 + 12;
      const sixHeight = 6 * m.itemHeight + 5 * 6 + 12;
      assert.ok(fiveHeight <= paneHeight, `5 items (${fiveHeight}) should fit in ${paneHeight}`);
      assert.ok(
        sixHeight > paneHeight || m.thumbHeight === 140 || m.thumbWidth === 124,
        `6 items (${sixHeight}) should exceed ${paneHeight} unless capped (${m.thumbWidth}x${m.thumbHeight})`,
      );
      assert.ok(m.thumbWidth >= 44 && m.thumbWidth <= 124);
      assert.ok(m.paneWidth >= m.thumbWidth + 32);
    }
  }
});

test("isEditableTarget excludes contenteditable=false Knowledge islands", () => {
  assert.equal(isEditableTarget({ tagName: "INPUT" }), true);
  assert.equal(isEditableTarget({ tagName: "textarea" }), true);
  assert.equal(isEditableTarget({ tagName: "SELECT" }), true);
  assert.equal(isEditableTarget({ tagName: "DIV", getAttribute: (n) => (n === "role" ? "combobox" : null) }), true);
  assert.equal(isEditableTarget({ tagName: "DIV", isContentEditable: true }), true);
  assert.equal(isEditableTarget({ tagName: "DIV", isContentEditable: false }), false);
  assert.equal(isEditableTarget(null), false);
});

test("resolvePdfKeyAction handles navigation, scroll-before-turn, zoom, fullscreen, and modifiers", () => {
  const base = { pageNum: 2, numPages: 8, fullscreen: false, canScrollUp: false, canScrollDown: false };
  assert.equal(resolvePdfKeyAction({ key: "ArrowLeft" }, base), "prev-page");
  assert.equal(resolvePdfKeyAction({ key: "ArrowRight" }, base), "next-page");
  assert.equal(resolvePdfKeyAction({ key: "Home" }, base), "first-page");
  assert.equal(resolvePdfKeyAction({ key: "End" }, base), "last-page");
  assert.equal(resolvePdfKeyAction({ key: "f" }, base), "toggle-fullscreen");
  assert.equal(resolvePdfKeyAction({ key: "+" }, base), "zoom-in");
  assert.equal(resolvePdfKeyAction({ key: "-" }, base), "zoom-out");
  assert.equal(resolvePdfKeyAction({ key: "0" }, base), "zoom-reset");
  assert.equal(resolvePdfKeyAction({ key: "Escape" }, base), null);
  assert.equal(resolvePdfKeyAction({ key: "Escape" }, { ...base, fullscreen: true }), "exit-fullscreen");

  // Scrolls within the page before turning when overflowed.
  assert.equal(resolvePdfKeyAction({ key: "ArrowDown" }, { ...base, canScrollDown: true }), "scroll-down");
  assert.equal(resolvePdfKeyAction({ key: "ArrowUp" }, { ...base, canScrollUp: true }), "scroll-up");
  assert.equal(resolvePdfKeyAction({ key: "PageDown" }, { ...base, canScrollDown: true }), "page-scroll-down");
  assert.equal(resolvePdfKeyAction({ key: "PageUp" }, { ...base, canScrollUp: true }), "page-scroll-up");
  assert.equal(resolvePdfKeyAction({ key: " " }, { ...base, canScrollDown: true }), "page-scroll-down");
  assert.equal(resolvePdfKeyAction({ key: " ", shiftKey: true }, { ...base, canScrollUp: false }), "prev-page");
  assert.equal(resolvePdfKeyAction({ key: "PageDown" }, base), "next-page");

  // Never steals browser/app modified shortcuts.
  assert.equal(resolvePdfKeyAction({ key: "ArrowLeft", metaKey: true }, base), null);
  assert.equal(resolvePdfKeyAction({ key: "0", ctrlKey: true }, base), null);
  assert.equal(resolvePdfKeyAction({ key: "f", altKey: true }, base), null);
});

function createMockCanvas(width, height) {
  const calls = [];
  const ctx = new Proxy(
    { canvas: null },
    {
      get(target, prop) {
        if (prop in target) return target[prop];
        if (prop === "getTransform") return () => ({ a: 1, b: 0, c: 0, d: 1, e: 0, f: 0 });
        return (...args) => {
          calls.push([String(prop), ...args]);
        };
      },
      set(target, prop, value) {
        target[prop] = value;
        calls.push([`set:${String(prop)}`, value]);
        return true;
      },
    },
  );
  const canvas = {
    width,
    height,
    getContext(type, opts) {
      calls.push(["getContext", type, opts]);
      return ctx;
    },
  };
  ctx.canvas = canvas;
  return { canvas, calls };
}

test("pdfjs-dist/legacy renders non-white PDF content and serializes cancelled renders safely", async () => {
  const pdf = new jsPDF();
  for (let i = 1; i <= 6; i++) {
    if (i > 1) pdf.addPage();
    pdf.setFillColor(40 * i, 60, 180);
    pdf.rect(24, 32, 120, 48, "F");
    pdf.setTextColor(17, 24, 39);
    pdf.text(`Page ${i}`, 24, 24);
  }
  const data = new Uint8Array(pdf.output("arraybuffer"));

  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  const doc = await pdfjs.getDocument({ data, verbosity: 0, disableFontFace: true }).promise;
  try {
    assert.equal(doc.numPages, 6);
    const page1 = await doc.getPage(1);
    const vp1 = page1.getViewport({ scale: 1 });
    const dpr = 2;
    const { canvas, calls } = createMockCanvas(Math.round(vp1.width * dpr), Math.round(vp1.height * dpr));

    await page1.render({ canvas, viewport: vp1, transform: [dpr, 0, 0, dpr, 0, 0], background: "#ffffff" }).promise;
    const drewNonWhiteFill = calls.some(([op, arg]) => op === "set:fillStyle" && typeof arg === "string" && arg.toLowerCase() !== "#ffffff");
    const drewText = calls.some(([op]) => op === "fillText");
    assert.equal(drewNonWhiteFill, true, "expected non-white fillStyle draw operations");
    assert.equal(drewText, true, "expected fillText draw operations");

    // Cancelling an active render and awaiting its completion before starting the next render
    // on the same canvas must never throw pdf.js's "Cannot use the same canvas" error.
    const page2 = await doc.getPage(2);
    const vp2 = page2.getViewport({ scale: 1 });
    const firstTask = page2.render({ canvas, viewport: vp2, transform: [dpr, 0, 0, dpr, 0, 0], background: "#ffffff" });
    firstTask.cancel();
    await firstTask.promise.catch(() => {});
    await page2.render({ canvas, viewport: vp2, transform: [dpr, 0, 0, dpr, 0, 0], background: "#ffffff" }).promise;
  } finally {
    await doc.destroy();
  }
});
