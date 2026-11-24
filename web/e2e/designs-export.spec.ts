import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { expect, test, type Browser } from "@playwright/test";
import pixelmatch from "pixelmatch";
import { PNG } from "pngjs";
import { exportItems, exportPdf, exportSvg, PT, type ExportItem, type Loaders } from "../lib/designs/export";
import { normalize } from "../lib/designs/schema";
import { handleRender } from "../lib/designs/worker";

// Export parity (LAZYAGENTS-150, ADR-designs §3.10 and §5.1): PNG, SVG and
// PDF exports of the acceptance design, each rasterised at 2x and diffed
// against the editor's rendering (<DesignSvg> in Chromium at 2x), committed
// in e2e/designs-export/. pixelmatch threshold 0.1, anti-aliased pixels
// excluded, at most 0.1 % of pixels differing.
//
// - PNG: the design worker (resvg), which GET /designs/{id}/render calls.
// - SVG: the exported file opened from disk in Chromium with the network off.
// - PDF: the exported file rasterised by pdf.js.
// The editor test compares the committed references with the live editor; it
// needs DESIGN_WORKER_TOKEN in this process and the app under test (the
// preview page is a 404 without it). With UPDATE_DESIGN_EXPORT_REFS=1 it
// rewrites the references instead, and every test writes its export's raster
// next to them for review.

const LIVE_TOKEN = process.env.DESIGN_WORKER_TOKEN;
const UPDATE = process.env.UPDATE_DESIGN_EXPORT_REFS === "1";

const fixtures = join(__dirname, "../../docs/design/fixtures");
const refs = join(__dirname, "designs-export");
const fonts = join(__dirname, "../public/fonts/designs");
const body = readFileSync(join(fixtures, "acceptance-design.json"), "utf8");
const design = normalize(body).design;
const assets = { a_landscape: `data:image/png;base64,${readFileSync(join(fixtures, "landscape.png")).toString("base64")}` };
const load: Loaders = { font: async (face, kind) => new Uint8Array(readFileSync(join(fonts, `Inter-${face}.${kind}`))), assets };
const MAX_DIFF_PCT = 0.1;
const NODES = ["n_pay", "n_state"];

const itemOf = (node: string): ExportItem => exportItems(design, "selection", { selected: [node] })[0];
const reference = (node: string) => PNG.sync.read(readFileSync(join(refs, `${node}.editor.png`)));

function compare(label: string, got: PNG, want: PNG, keep = UPDATE) {
  if (keep) {
    mkdirSync(refs, { recursive: true });
    writeFileSync(join(refs, `${label}.png`), PNG.sync.write(got));
  }
  expect([got.width, got.height], `${label} size`).toEqual([want.width, want.height]);
  const differing = pixelmatch(got.data, want.data, undefined, want.width, want.height, { threshold: 0.1, includeAA: false });
  const pct = (differing / (want.width * want.height)) * 100;
  console.log(`export parity ${label}: ${differing} of ${want.width * want.height} px differ (${pct.toFixed(4)} %)`);
  expect(pct, `${label} differing pixels (%)`).toBeLessThanOrEqual(MAX_DIFF_PCT);
}

async function editorShot(browser: Browser, baseURL: string, node: string, w: number, h: number): Promise<PNG> {
  const page = design.pages.find((p) => p.children.some((c) => c.id === node))!;
  const context = await browser.newContext({ deviceScaleFactor: 2, viewport: { width: 1600, height: 1000 } });
  const tab = await context.newPage();
  await tab.addInitScript((p) => ((window as unknown as { __preview: unknown }).__preview = p), { design, page: page.id, node, w, h, assets });
  await tab.goto(`${baseURL}/internal/designs/preview?token=${encodeURIComponent(LIVE_TOKEN!)}`);
  await tab.waitForFunction(() => (window as unknown as { __ready?: boolean }).__ready === true);
  const shot = PNG.sync.read(await tab.locator("#shot").screenshot());
  await context.close();
  return shot;
}

/** The PDF's pages rasterised by pdf.js at 2 px per design px. */
async function rasterPdf(pdf: Uint8Array): Promise<PNG[]> {
  const pdfjs = await import("pdfjs-dist/legacy/build/pdf.mjs");
  const { createCanvas } = await import("@napi-rs/canvas");
  const doc = await pdfjs.getDocument({ data: pdf, disableFontFace: true, verbosity: 0 }).promise;
  const out: PNG[] = [];
  for (let i = 1; i <= doc.numPages; i++) {
    const page = await doc.getPage(i);
    const vp = page.getViewport({ scale: 2 / PT });
    const canvas = createCanvas(Math.round(vp.width), Math.round(vp.height));
    await page.render({ canvas: canvas as unknown as HTMLCanvasElement, canvasContext: canvas.getContext("2d") as unknown as CanvasRenderingContext2D, viewport: vp }).promise;
    out.push(PNG.sync.read(canvas.toBuffer("image/png")));
  }
  await doc.loadingTask.destroy();
  return out;
}

test.describe("design export parity", () => {
  test("the committed references are the live editor's rendering", async ({ browser, baseURL }) => {
    test.skip(!LIVE_TOKEN, "set DESIGN_WORKER_TOKEN (also for the app under test)");
    for (const node of NODES) {
      const { box } = itemOf(node);
      const shot = await editorShot(browser, baseURL!, node, box.w, box.h);
      if (UPDATE) {
        mkdirSync(refs, { recursive: true });
        writeFileSync(join(refs, `${node}.editor.png`), PNG.sync.write(shot));
      }
      compare(`${node}.editor-live`, shot, reference(node), false);
    }
  });

  for (const node of NODES) {
    test(`${node}: PNG export matches the editor`, async () => {
      // The worker is called in-process, so any token works when the app isn't involved. Set
      // here, in the test worker: Playwright passes the runner's env (where the spec is also
      // loaded to list tests) on to its workers, and the live test must not see this one.
      process.env.DESIGN_WORKER_TOKEN ||= "designs-export-spec";
      const TOKEN = process.env.DESIGN_WORKER_TOKEN;
      const res = await handleRender(new Request("http://worker/render", { method: "POST", headers: { authorization: `Bearer ${TOKEN}` }, body: JSON.stringify({ body, node, scale: 2, assets }) }));
      expect(res.status).toBe(200);
      compare(`${node}.png-export`, PNG.sync.read(Buffer.from(await res.arrayBuffer())), reference(node));
    });

    test(`${node}: SVG export opens offline with text as text and matches the editor`, async ({ browser }) => {
      const item = itemOf(node);
      const svg = await exportSvg(item, load);
      expect(svg).toContain("<text");
      expect(svg).toMatch(/@font-face\{font-family:"Vesper Designs Inter";src:url\(data:font\/woff2;base64,/);
      // Nothing to fetch: the only URL is the SVG namespace.
      expect(svg.match(/https?:\/\/[^"')\s]+/g)?.filter((u) => u !== "http://www.w3.org/2000/svg") ?? []).toEqual([]);

      const file = join(mkdtempSync(join(tmpdir(), "designs-export-")), `${node}.svg`);
      writeFileSync(file, svg);
      const context = await browser.newContext({ deviceScaleFactor: 2, viewport: { width: Math.ceil(item.box.w), height: Math.ceil(item.box.h) }, offline: true });
      const requests: string[] = [];
      await context.route("**/*", (route) => {
        const url = route.request().url();
        if (url.startsWith("file:") || url.startsWith("data:")) return route.continue();
        requests.push(url);
        return route.abort();
      });
      const tab = await context.newPage();
      await tab.goto(pathToFileURL(file).href);
      await tab.evaluate(() => document.fonts.ready);
      // Text drawn in Inter, not a fallback: every used face loaded from the embedded data.
      const faces = await tab.evaluate(() => [...document.fonts].map((f) => `${f.family}:${f.weight}:${f.style}:${f.status}`));
      expect(faces.length).toBeGreaterThan(0);
      expect(faces.every((f) => f.endsWith(":loaded")), faces.join(", ")).toBe(true);
      const shot = PNG.sync.read(await tab.locator("svg").screenshot());
      await context.close();
      expect(requests).toEqual([]);
      compare(`${node}.svg-export`, shot, reference(node));
    });

    test(`${node}: PDF export matches the editor`, async () => {
      const [page] = await rasterPdf(await exportPdf([itemOf(node)], load));
      compare(`${node}.pdf-export`, page, reference(node));
    });
  }
});
