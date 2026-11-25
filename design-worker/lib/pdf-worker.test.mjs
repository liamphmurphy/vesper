import test from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { BrowserUnavailableError, countPdfPagesFallback, findBrowser, FONT_ORIGIN } from "./pdf/cdp.ts";
import { buildDocumentHtml, handlePdf, parseDimensionInches, PDF_MAX_CONCURRENT, pdfDeps, resolvePageSize } from "./pdf/render.ts";

const TOKEN = "pdf-test-token";
process.env.DESIGN_WORKER_TOKEN = TOKEN;

const FAKE_PDF = Buffer.from("%PDF-1.4\n1 0 obj\n<< /Type /Page >>\nendobj\n2 0 obj\n<< /Type /Page >>\nendobj\n%%EOF\n");
const FAKE_PNG = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const call = (payload, token = TOKEN) =>
  handlePdf(
    new Request("http://x/internal/designs/pdf", {
      method: "POST",
      headers: token === null ? {} : { authorization: `Bearer ${token}` },
      body: typeof payload === "string" ? payload : JSON.stringify(payload),
    }),
  );

test("refuses missing or wrong bearer token", async () => {
  assert.equal((await call({ html: "<h1>Hi</h1>" }, null)).status, 401);
  assert.equal((await call({ html: "<h1>Hi</h1>" }, "wrong")).status, 401);
  delete process.env.DESIGN_WORKER_TOKEN;
  try {
    assert.equal((await call({ html: "<h1>Hi</h1>" }, "")).status, 401);
  } finally {
    process.env.DESIGN_WORKER_TOKEN = TOKEN;
  }
});

test("parseDimensionInches converts units and rejects out-of-range values", () => {
  assert.equal(parseDimensionInches("0.5in", "m", 0, 4), 0.5);
  assert.ok(Math.abs(parseDimensionInches("25.4mm", "m", 0, 4) - 1) < 1e-6);
  assert.ok(Math.abs(parseDimensionInches("2.54cm", "m", 0, 4) - 1) < 1e-6);
  assert.equal(parseDimensionInches("72pt", "m", 0, 4), 1);
  assert.equal(parseDimensionInches("96px", "m", 0, 4), 1);
  assert.equal(parseDimensionInches(0.75, "m", 0, 4), 0.75);
  assert.throws(() => parseDimensionInches("-1in", "m", 0, 4));
  assert.throws(() => parseDimensionInches("5in", "m", 0, 4));
  assert.throws(() => parseDimensionInches("10rem", "m", 0, 4));
});

test("resolvePageSize handles presets and custom sizes", () => {
  assert.deepEqual(resolvePageSize(undefined), { widthIn: 8.5, heightIn: 11, label: "Letter" });
  assert.deepEqual(resolvePageSize("A4"), { widthIn: 8.27, heightIn: 11.69, label: "A4" });
  assert.deepEqual(resolvePageSize({ width_in: 6, height_in: 9 }), { widthIn: 6, heightIn: 9, label: "6×9in" });
  assert.throws(() => resolvePageSize("folio"));
  assert.throws(() => resolvePageSize({ width_in: 1, height_in: 9 }));
});

test("buildDocumentHtml wraps fragments and injects bundled fonts without clobbering full docs", () => {
  const frag = buildDocumentHtml("<h1>Hello</h1>", "h1 { color: navy; }");
  assert.match(frag, /^<!doctype html>/i);
  assert.ok(frag.includes(`${FONT_ORIGIN}/designs/Inter-Regular.ttf`));
  assert.ok(frag.includes(`${FONT_ORIGIN}/slides/LiberationSerif-Regular.ttf`));
  assert.ok(frag.includes("h1 { color: navy; }"));
  assert.ok(frag.includes("<h1>Hello</h1>"));

  const full = buildDocumentHtml("<!doctype html><html><head><title>Doc</title><style>body{color:#111}</style></head><body><p>Body</p></body></html>", "p{margin:0}");
  const baseIdx = full.indexOf("data-vesper-pdf-base");
  const docStyleIdx = full.indexOf("body{color:#111}");
  const userIdx = full.indexOf("data-vesper-pdf-user");
  assert.ok(baseIdx > 0 && docStyleIdx > baseIdx && userIdx > docStyleIdx);
});

test("countPdfPagesFallback counts page objects without matching /Pages", () => {
  assert.equal(countPdfPagesFallback(FAKE_PDF), 2);
  assert.equal(countPdfPagesFallback(Buffer.from("%PDF-1.4\n<< /Type /Pages /Count 3 >>\n<< /Type /Page >>\n")), 1);
});

test("findBrowser prefers explicit env override and scans Playwright cache", () => {
  const dir = mkdtempSync(join(tmpdir(), "vesper-browser-test-"));
  try {
    const fakeBin = join(dir, "fake-chrome");
    writeFileSync(fakeBin, "");
    assert.equal(findBrowser({ VESPER_PDF_BROWSER: fakeBin, HOME: dir, PATH: "" }, "linux"), fakeBin);

    const pwDir = join(dir, "pw");
    const pwBin = join(pwDir, "chromium-1200", "chrome-linux", "chrome");
    mkdirSync(join(pwDir, "chromium-1200", "chrome-linux"), { recursive: true });
    writeFileSync(pwBin, "");
    assert.equal(findBrowser({ PLAYWRIGHT_BROWSERS_PATH: pwDir, HOME: dir, PATH: "" }, "linux"), pwBin);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("handlePdf validates inputs and returns pdf_base64, page count and previews", async () => {
  const real = pdfDeps.render;
  let captured = null;
  pdfDeps.render = async (opts) => {
    captured = opts;
    return { pdf: FAKE_PDF, pages: 2, previews: [{ page: 1, png: FAKE_PNG, width: 850, height: 1100 }] };
  };
  try {
    for (const bad of [
      "not json",
      {},
      { html: "   " },
      { html: "<p>a</p>", orientation: "diagonal" },
      { html: "<p>a</p>", page_size: "unknown" },
      { html: "<p>a</p>", margins: "9in" },
      { html: "<p>a</p>", preview_pages: [1, 2, 3, 4, 5] },
      { html: "<p>a</p>", preview_pages: [0] },
      { html: "<p>a</p>", print_background: "yes" },
    ]) {
      const r = await call(bad);
      assert.equal(r.status, 400, JSON.stringify(bad));
      assert.equal(typeof (await r.json()).message, "string");
    }

    const ok = await call({
      html: "<h1>Quarterly Review</h1>",
      css: "h1 { font-size: 24pt; }",
      page_size: "a4",
      orientation: "landscape",
      margins: { top: "20mm", left: "15mm" },
      footer_html: "<div style='font-size:9px'><span class='pageNumber'></span></div>",
      preview_pages: [1],
    });
    assert.equal(ok.status, 200);
    const out = await ok.json();
    assert.equal(out.pages, 2);
    assert.equal(out.page_size, "A4 landscape");
    assert.equal(Buffer.from(out.pdf_base64, "base64").toString("latin1"), FAKE_PDF.toString("latin1"));
    assert.equal(out.previews.length, 1);
    assert.equal(out.previews[0].page, 1);
    assert.equal(out.previews[0].width, 850);
    assert.ok(captured);
    assert.equal(captured.landscape, true);
    assert.equal(captured.paperWidthIn, 8.27);
    assert.ok(Math.abs(captured.marginTopIn - 20 / 25.4) < 1e-6);
    assert.equal(captured.marginBottomIn, 0.8);
    assert.deepEqual(captured.previewPages, [1]);
  } finally {
    pdfDeps.render = real;
  }
});

test("handlePdf enforces concurrency (503), timeout (504) and missing browser (503)", async () => {
  const real = pdfDeps.render;
  let release;
  const gate = new Promise((r) => (release = r));
  pdfDeps.render = async () => {
    await gate;
    return { pdf: FAKE_PDF, pages: 1, previews: [] };
  };
  try {
    const held = Array.from({ length: PDF_MAX_CONCURRENT }, () => call({ html: "<p>a</p>" }));
    await new Promise((r) => setTimeout(r, 20));
    const busy = await call({ html: "<p>a</p>" });
    assert.equal(busy.status, 503);
    release();
    for (const r of await Promise.all(held)) assert.equal(r.status, 200);

    pdfDeps.render = async () => {
      throw new BrowserUnavailableError("no Chrome found");
    };
    const missing = await call({ html: "<p>a</p>" });
    assert.equal(missing.status, 503);
    assert.match((await missing.json()).message, /no Chrome found/);

    const realTimeout = AbortSignal.timeout;
    AbortSignal.timeout = () => AbortSignal.abort();
    pdfDeps.render = () => new Promise(() => {});
    try {
      const slow = await call({ html: "<p>a</p>" });
      assert.equal(slow.status, 504);
    } finally {
      AbortSignal.timeout = realTimeout;
    }
  } finally {
    pdfDeps.render = real;
  }
});

test("handlePdf accepts large inlined data: URI images (JPEG, PNG, WebP) above legacy 8 MB limit", async () => {
  const real = pdfDeps.render;
  let captured = null;
  pdfDeps.render = async (opts) => {
    captured = opts;
    return { pdf: FAKE_PDF, pages: 1, previews: [{ page: 1, png: FAKE_PNG, width: 850, height: 1100 }] };
  };
  try {
    const bigWebp = "data:image/webp;base64," + "A".repeat(9 * 1024 * 1024);
    const html = `<img src="${bigWebp}"><img src="data:image/jpeg;base64,/9j/4AAQ"><img src="data:image/png;base64,iVBORw0KGgo=">`;
    const ok = await call({ html, preview_pages: [1] });
    assert.equal(ok.status, 200);
    assert.ok(captured);
    assert.ok(captured.html.includes("data:image/webp;base64,"));
    assert.ok(captured.html.includes("data:image/jpeg;base64,"));
    assert.ok(captured.html.includes("data:image/png;base64,"));
  } finally {
    pdfDeps.render = real;
  }
});
