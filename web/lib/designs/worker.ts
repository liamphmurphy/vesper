// The Designs render worker (ADR-designs §2.2): the Go API posts a design body
// here and gets a PNG or settled node boxes back. Both routes go through
// `authorized` first; with no DESIGN_WORKER_TOKEN set every call is refused.
import { createHash, timingSafeEqual } from "node:crypto";
import { join } from "node:path";
import { renderAsync } from "@resvg/resvg-js";
import { makeLayout, type Box, type LaidPage } from "./layout.ts";
import { inspect, InspectError, type InspectTarget } from "./inspect.ts";
import { DesignError, normalize, type Design, type DesignNode, type Page } from "./schema.ts";
import { toSvg } from "./svg.ts";
import { newId } from "./edit.ts";
import { importFlowchart, MermaidError } from "./mermaid.ts";
import { importSvg, SvgImportError } from "./svgimport.ts";

export const MAX_EDGE = 4096;
export const MAX_CONCURRENT = 4;
export const TIMEOUT_MS = 10_000;
const MAX_REQUEST = 48 * 1024 * 1024;
const FONT_FILES = ["Regular", "Italic", "Medium", "MediumItalic", "SemiBold", "SemiBoldItalic", "Bold", "BoldItalic"].map((n) => `Inter-${n}.ttf`);

export class WorkerError extends Error {
  status: number;
  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

/** Replaceable in tests (to hold a render open). */
export const deps = {
  rasterize: async (svg: string, width: number, signal: AbortSignal): Promise<{ png: Buffer; width: number; height: number }> => {
    const dir = process.env.DESIGN_FONT_DIR ?? join(process.cwd(), "public", "fonts", "designs");
    const img = await renderAsync(
      svg,
      {
        font: { fontFiles: FONT_FILES.map((f) => join(dir, f)), loadSystemFonts: false, defaultFontFamily: "Inter" },
        fitTo: { mode: "width", value: width },
        shapeRendering: 2,
        textRendering: 2,
        imageRendering: 0,
      },
      signal,
    );
    return { png: img.asPng(), width: img.width, height: img.height };
  },
};

const digest = (s: string) => createHash("sha256").update(s).digest();

/** Bearer token check in constant time; false when the token isn't configured. */
export function tokenOk(given: string, token = process.env.DESIGN_WORKER_TOKEN): boolean {
  if (!token || !given) return false;
  return timingSafeEqual(digest(given), digest(token));
}

export function authorized(req: Request, token = process.env.DESIGN_WORKER_TOKEN): boolean {
  const h = req.headers.get("authorization") ?? "";
  return tokenOk(h.startsWith("Bearer ") ? h.slice(7) : "", token);
}

const json = (status: number, body: unknown) => Response.json(body, { status });
const fail = (e: unknown) => {
  if (e instanceof WorkerError) return json(e.status, { message: e.message });
  if (e instanceof DesignError || e instanceof InspectError) return json(400, { message: e.message });
  console.error("design worker:", e);
  return json(500, { message: "render failed" });
};

type Obj = Record<string, unknown>;
async function readBody(req: Request): Promise<Obj> {
  if (Number(req.headers.get("content-length") ?? 0) > MAX_REQUEST) throw new WorkerError(400, "request is too large");
  const text = await req.text();
  if (text.length > MAX_REQUEST) throw new WorkerError(400, "request is too large");
  let v: unknown;
  try {
    v = JSON.parse(text);
  } catch {
    throw new WorkerError(400, "request isn't valid JSON");
  }
  if (typeof v !== "object" || v === null || Array.isArray(v)) throw new WorkerError(400, "request must be a JSON object");
  if (typeof (v as Obj).body !== "string") throw new WorkerError(400, "body: must be the design JSON as a string");
  return v as Obj;
}
const optId = (v: unknown, prefix: string, name: string) => {
  if (v === undefined || v === null) return undefined;
  if (typeof v !== "string" || !v.startsWith(prefix)) throw new WorkerError(400, `${name}: must be an id starting with ${prefix}`);
  return v;
};

const walk = (nodes: DesignNode[], f: (n: DesignNode) => void) => {
  for (const n of nodes) {
    f(n);
    if ("children" in n && Array.isArray(n.children)) walk(n.children, f);
  }
};

const ASSET = /^data:image\/(png|jpeg);base64,[A-Za-z0-9+/]+=*$/;

let running = 0;

async function render(req: Obj, slot: Slot): Promise<Response> {
  const nodeId = optId(req.node, "n_", "node");
  const pageId = optId(req.page, "p_", "page");
  if (nodeId && pageId) throw new WorkerError(400, "give node or page, not both");
  const scale = req.scale === undefined ? 1 : req.scale;
  if (typeof scale !== "number" || !(scale >= 1 && scale <= 3)) throw new WorkerError(400, "scale: must be a number from 1 to 3");
  const assets: Record<string, string> = {};
  if (req.assets !== undefined) {
    if (typeof req.assets !== "object" || req.assets === null || Array.isArray(req.assets)) throw new WorkerError(400, "assets: must be an object");
    for (const [k, v] of Object.entries(req.assets)) {
      if (typeof v !== "string" || !ASSET.test(v)) throw new WorkerError(400, `assets.${k}: must be a base64 PNG or JPEG data URI`);
      assets[k] = v;
    }
  }
  const design = normalize(req.body as string).design;
  const lay = makeLayout(design);

  let page: Page | undefined;
  if (nodeId) {
    page = design.pages.find((p) => {
      let hit = false;
      walk(p.children, (n) => void (hit ||= n.id === nodeId));
      return hit;
    });
    if (!page) throw new WorkerError(400, `node: ${nodeId} isn't in the design`);
  } else if (pageId) {
    page = design.pages.find((p) => p.id === pageId);
    if (!page) throw new WorkerError(400, `page: ${pageId} isn't in the design`);
  } else {
    page = design.pages[0];
    if (!page) throw new WorkerError(400, "the design has no pages");
  }
  const laid = lay.layoutPage(page);

  let box: Box;
  let ops;
  if (nodeId) {
    // A nested node is drawn as its region of the top-level node it sits in.
    const top = page.children.find((t) => {
      let hit = false;
      walk([t], (n) => void (hit ||= n.id === nodeId));
      return hit;
    })!;
    const lt = laid.nodes.find((n) => n.id === top.id);
    const b = top.id === nodeId ? lt?.box : laid.boxes.get(nodeId);
    if (!lt || !b) throw new WorkerError(400, `node: ${nodeId} isn't drawn`);
    box = b;
    ops = lt.ops;
  } else {
    box = laid.box;
    ops = [...laid.nodes.flatMap((n) => n.ops), ...laid.connectors];
  }
  if (!(box.w > 0 && box.h > 0)) throw new WorkerError(400, nodeId ? `node: ${nodeId} has no size` : "the page is empty");
  const width = Math.max(1, Math.round(box.w * scale));
  const height = Math.max(1, Math.round(box.h * scale));
  if (Math.max(width, height) > MAX_EDGE) throw new WorkerError(400, `the image would be ${width}×${height} px; the longest edge is at most ${MAX_EDGE}`);

  {
    const svg = toSvg(ops, { box, background: laid.background, assets });
    const signal = AbortSignal.timeout(TIMEOUT_MS);
    let out;
    try {
      const raster = deps.rasterize(svg, width, signal);
      // The slot is held until the native render itself ends, even after a 504.
      slot.hold(raster);
      out = await Promise.race([
        raster,
        new Promise<never>((_, rej) => {
          const late = () => rej(new WorkerError(504, "the render took too long"));
          if (signal.aborted) late();
          else signal.addEventListener("abort", late, { once: true });
        }),
      ]);
    } catch (e) {
      if (e instanceof WorkerError) throw e;
      if (signal.aborted) throw new WorkerError(504, "the render took too long");
      throw e;
    }
    return new Response(new Uint8Array(out.png), {
      status: 200,
      headers: { "content-type": "image/png", "x-design-width": String(out.width), "x-design-height": String(out.height), "cache-control": "no-store" },
    });
  }
}

/**
 * One of the MAX_CONCURRENT worker slots, taken before a request's body is
 * parsed (layout is CPU work too). release() frees it unless hold() handed it
 * to a render still running natively, which frees it when it settles.
 */
type Slot = { hold: (p: Promise<unknown>) => void; release: () => void };
function takeSlot(): Slot {
  if (running >= MAX_CONCURRENT) throw new WorkerError(503, "the renderer is busy; try again shortly");
  running++;
  let held = false;
  let freed = false;
  const free = () => {
    if (!freed) {
      freed = true;
      running--;
    }
  };
  return {
    hold: (p) => {
      held = true;
      p.then(free, free);
    },
    release: () => {
      if (!held) free();
    },
  };
}

const r2 = (n: number) => Math.round(n * 100) / 100;
export function layoutBoxes(design: Design, pageId?: string): { pages: { id: string; boxes: Record<string, Box> }[] } {
  const lay = makeLayout(design);
  const pages = pageId ? design.pages.filter((p) => p.id === pageId) : design.pages;
  if (pageId && !pages.length) throw new WorkerError(400, `page: ${pageId} isn't in the design`);
  return {
    pages: pages.map((p) => {
      const laid: LaidPage = lay.layoutPage(p);
      const boxes: Record<string, Box> = {};
      walk(p.children, (n) => {
        const b = laid.boxes.get(n.id);
        if (b) boxes[n.id] = { x: r2(b.x), y: r2(b.y), w: r2(b.w), h: r2(b.h) };
      });
      return { id: p.id, boxes };
    }),
  };
}

const unauthorized = () => json(401, { message: "unauthorized" });

export async function handleRender(req: Request): Promise<Response> {
  if (!authorized(req)) return unauthorized();
  let slot: Slot | undefined;
  try {
    slot = takeSlot();
    return await render(await readBody(req), slot);
  } catch (e) {
    return fail(e);
  } finally {
    slot?.release();
  }
}

export async function handleLayout(req: Request): Promise<Response> {
  if (!authorized(req)) return unauthorized();
  let slot: Slot | undefined;
  try {
    slot = takeSlot();
    const b = await readBody(req);
    const pageId = optId(b.page, "p_", "page");
    return json(200, layoutBoxes(normalize(b.body as string).design, pageId));
  } catch (e) {
    return fail(e);
  } finally {
    slot?.release();
  }
}

/** Inspect output (inspect.ts) for one node: {body, node, target: css|tailwind|react}. */
export async function handleInspect(req: Request): Promise<Response> {
  if (!authorized(req)) return unauthorized();
  let slot: Slot | undefined;
  try {
    slot = takeSlot();
    const b = await readBody(req);
    const nodeId = optId(b.node, "n_", "node");
    if (!nodeId) throw new WorkerError(400, "node: required");
    return json(200, inspect(normalize(b.body as string).design, nodeId, (b.target ?? "react") as InspectTarget));
  } catch (e) {
    return fail(e);
  } finally {
    slot?.release();
  }
}

/** Where an import goes when no position is given: right of what's on the page. */
export const IMPORT_GAP = 160;

/**
 * design_import (ADR-designs §3.9): Mermaid or SVG text becomes one node
 * (a section or a group) for `page`, at (x, y) or right of the page's
 * content. The result is checked against the schema with the node in place,
 * so the Go API can apply it (or propose it) as an add_node op as is. Text it
 * can't import is refused with a message naming the problem; nothing changes.
 */
export async function importNode(req: Obj, ids: () => string = () => newId("n")): Promise<{ node: DesignNode; warnings: string[] }> {
  const pageId = optId(req.page, "p_", "page");
  if (!pageId) throw new WorkerError(400, "page: give the page to import into");
  const hasM = typeof req.mermaid === "string", hasS = typeof req.svg === "string";
  if (hasM === hasS) throw new WorkerError(400, "give mermaid or svg text, not both or neither");
  for (const k of ["x", "y"] as const) if (req[k] !== undefined && !(typeof req[k] === "number" && Number.isFinite(req[k]) && Math.abs(req[k] as number) <= 1e6)) throw new WorkerError(400, `${k}: must be a number`);
  const design = normalize(req.body as string).design;
  const page = design.pages.find((p) => p.id === pageId);
  if (!page) throw new WorkerError(400, `page: ${pageId} isn't in the design`);
  let x = req.x as number | undefined, y = req.y as number | undefined;
  if (x === undefined || y === undefined) {
    const box = makeLayout(design).layoutPage(page).box;
    x ??= box.w || box.h ? Math.round(box.x + box.w + IMPORT_GAP) : 0;
    y ??= box.w || box.h ? Math.round(box.y) : 0;
  }
  let out: { node: DesignNode; warnings: string[] };
  try {
    if (hasM) {
      const r = await importFlowchart(req.mermaid as string, { design, ids, x, y });
      out = { node: r.section, warnings: r.warnings };
    } else out = importSvg(req.svg as string, { ids, x, y });
  } catch (e) {
    if (e instanceof MermaidError) throw new WorkerError(400, `mermaid: ${e.message}`);
    if (e instanceof SvgImportError) throw new WorkerError(400, `svg: ${e.message}`);
    throw e;
  }
  try {
    normalize({ ...design, pages: design.pages.map((p) => (p.id === pageId ? { ...p, children: [...p.children, out.node] } : p)) });
  } catch (e) {
    if (e instanceof DesignError) throw new WorkerError(400, `the import doesn't fit this design: ${e.message}`);
    throw e;
  }
  return out;
}

export async function handleImport(req: Request): Promise<Response> {
  if (!authorized(req)) return unauthorized();
  let slot: Slot | undefined;
  try {
    slot = takeSlot();
    return json(200, await importNode(await readBody(req)));
  } catch (e) {
    return fail(e);
  } finally {
    slot?.release();
  }
}
