// HTML/CSS -> PDF render endpoint for the Vesper design worker.
// Protected by the same DESIGN_WORKER_TOKEN bearer check as /internal/designs/*.
import { authorized, WorkerError } from "../designs/worker.ts";
import {
  BUNDLED_FONTS,
  BrowserUnavailableError,
  FONT_ORIGIN,
  renderHtmlToPdf,
  type PdfRenderOptions,
  type PdfRenderOutput,
} from "./cdp.ts";

export const PDF_MAX_CONCURRENT = 2;
export const PDF_TIMEOUT_MS = 30_000;
const MAX_REQUEST = 48 * 1024 * 1024;
const MAX_HTML_BYTES = 40 * 1024 * 1024;
const MAX_CSS_BYTES = 8 * 1024 * 1024;
const MAX_TEMPLATE_BYTES = 2 * 1024 * 1024;
const MAX_PDF_BYTES = 25 * 1024 * 1024;
const MAX_PREVIEW_PAGES = 4;

export const PAGE_PRESETS: Record<string, { widthIn: number; heightIn: number; label: string }> = {
  letter: { widthIn: 8.5, heightIn: 11, label: "Letter" },
  a4: { widthIn: 8.27, heightIn: 11.69, label: "A4" },
  legal: { widthIn: 8.5, heightIn: 14, label: "Legal" },
  tabloid: { widthIn: 11, heightIn: 17, label: "Tabloid" },
  a5: { widthIn: 5.83, heightIn: 8.27, label: "A5" },
  a3: { widthIn: 11.69, heightIn: 16.54, label: "A3" },
};

/** Replaceable in unit tests so tests don't require a Chrome binary. */
export const pdfDeps = {
  render: (opts: PdfRenderOptions, signal: AbortSignal): Promise<PdfRenderOutput> => renderHtmlToPdf(opts, signal),
};

const DIM_RE = /^\s*(\d+(?:\.\d+)?)\s*(in|mm|cm|pt|px)?\s*$/i;

/** Parses a CSS length (e.g. "0.6in", "15mm", "1.5cm", "48pt", "72px", or number in inches) into inches. */
export function parseDimensionInches(value: unknown, field: string, minIn: number, maxIn: number): number {
  let inches: number;
  if (typeof value === "number") {
    if (!Number.isFinite(value)) throw new WorkerError(400, `${field}: must be a finite number`);
    inches = value;
  } else if (typeof value === "string") {
    const m = value.match(DIM_RE);
    if (!m) throw new WorkerError(400, `${field}: use a length like "0.6in", "15mm", "1.5cm" or "48pt"`);
    const n = Number(m[1]);
    const unit = (m[2] ?? "in").toLowerCase();
    switch (unit) {
      case "in":
        inches = n;
        break;
      case "mm":
        inches = n / 25.4;
        break;
      case "cm":
        inches = n / 2.54;
        break;
      case "pt":
        inches = n / 72;
        break;
      case "px":
        inches = n / 96;
        break;
      default:
        throw new WorkerError(400, `${field}: unsupported unit ${unit}`);
    }
  } else {
    throw new WorkerError(400, `${field}: must be a length string or number of inches`);
  }
  if (!Number.isFinite(inches) || inches < minIn || inches > maxIn) {
    throw new WorkerError(400, `${field}: must be between ${minIn}in and ${maxIn}in`);
  }
  return inches;
}

export function resolvePageSize(input: unknown): { widthIn: number; heightIn: number; label: string } {
  if (input === undefined || input === null || input === "") return PAGE_PRESETS.letter;
  if (typeof input === "string") {
    const preset = PAGE_PRESETS[input.trim().toLowerCase()];
    if (!preset) {
      throw new WorkerError(400, `page_size: unknown preset "${input}" (use letter, a4, legal, tabloid, a5, a3 or {width_in, height_in})`);
    }
    return preset;
  }
  if (typeof input === "object" && !Array.isArray(input)) {
    const o = input as Record<string, unknown>;
    const widthIn = parseDimensionInches(o.width_in, "page_size.width_in", 2, 24);
    const heightIn = parseDimensionInches(o.height_in, "page_size.height_in", 2, 24);
    return { widthIn, heightIn, label: `${Number(widthIn.toFixed(2))}×${Number(heightIn.toFixed(2))}in` };
  }
  throw new WorkerError(400, "page_size: use a preset name or {width_in, height_in}");
}

export function bundledFontCss(): string {
  const faces = BUNDLED_FONTS.map(
    (f) =>
      `@font-face{font-family:${JSON.stringify(f.family)};src:url(${JSON.stringify(`${FONT_ORIGIN}/${f.urlPath}`)}) format("truetype");font-weight:${f.weight};font-style:${f.style};font-display:block;}`,
  ).join("\n");
  return `${faces}
*,*::before,*::after{box-sizing:border-box;}
html,body{-webkit-print-color-adjust:exact;print-color-adjust:exact;}
body{font-family:"Inter","Liberation Sans",system-ui,-apple-system,sans-serif;}`;
}

function escapeStyleClose(css: string): string {
  return css.replace(/<\/style/gi, "<\\/style");
}

/** Wraps an HTML fragment or enriches a full document with bundled fonts and optional user CSS. */
export function buildDocumentHtml(html: string, css?: string): string {
  const baseTag = `<style data-vesper-pdf-base>\n${bundledFontCss()}\n</style>`;
  const userTag = css?.trim() ? `\n<style data-vesper-pdf-user>\n${escapeStyleClose(css)}\n</style>` : "";
  const isFullDoc = /<!doctype\s+html|<html[\s>]/i.test(html);
  if (!isFullDoc) {
    return `<!doctype html>
<html>
<head>
<meta charset="utf-8">
${baseTag}${userTag}
</head>
<body>
${html}
</body>
</html>`;
  }
  // Place base fonts/reset right after <head> so document styles can override them,
  // and place explicit user `css` right before </head> so it overrides earlier styles.
  let out = html;
  if (/<head[\s>]/i.test(out)) {
    out = out.replace(/<head([^>]*)>/i, `<head$1>\n${baseTag}`);
  } else if (/<html[\s>]/i.test(out)) {
    out = out.replace(/<html([^>]*)>/i, `<html$1>\n<head><meta charset="utf-8">\n${baseTag}</head>`);
  } else {
    out = `${baseTag}\n${out}`;
  }
  if (userTag) {
    if (/<\/head>/i.test(out)) {
      out = out.replace(/<\/head>/i, `${userTag}\n</head>`);
    } else {
      out = `${out}${userTag}`;
    }
  }
  return out;
}

type Obj = Record<string, unknown>;

function parseMargins(input: unknown, hasHeader: boolean, hasFooter: boolean): { top: number; right: number; bottom: number; left: number } {
  const defSide = 0.6;
  const defTop = hasHeader ? 0.8 : defSide;
  const defBottom = hasFooter ? 0.8 : defSide;
  if (input === undefined || input === null) {
    return { top: defTop, right: defSide, bottom: defBottom, left: defSide };
  }
  if (typeof input === "string" || typeof input === "number") {
    const v = parseDimensionInches(input, "margins", 0, 4);
    return { top: v, right: v, bottom: v, left: v };
  }
  if (typeof input === "object" && !Array.isArray(input)) {
    const o = input as Obj;
    return {
      top: o.top === undefined ? defTop : parseDimensionInches(o.top, "margins.top", 0, 4),
      right: o.right === undefined ? defSide : parseDimensionInches(o.right, "margins.right", 0, 4),
      bottom: o.bottom === undefined ? defBottom : parseDimensionInches(o.bottom, "margins.bottom", 0, 4),
      left: o.left === undefined ? defSide : parseDimensionInches(o.left, "margins.left", 0, 4),
    };
  }
  throw new WorkerError(400, "margins: give a length like \"0.6in\" or {top, right, bottom, left}");
}

function parsePreviewPages(input: unknown): number[] {
  if (input === undefined || input === null) return [1, 2];
  if (!Array.isArray(input)) throw new WorkerError(400, "preview_pages: must be an array of 1-based page numbers");
  if (input.length > MAX_PREVIEW_PAGES) throw new WorkerError(400, `preview_pages: at most ${MAX_PREVIEW_PAGES} pages per render`);
  const out: number[] = [];
  for (const v of input) {
    if (typeof v !== "number" || !Number.isInteger(v) || v < 1 || v > 500) {
      throw new WorkerError(400, "preview_pages: each entry must be an integer between 1 and 500");
    }
    if (!out.includes(v)) out.push(v);
  }
  return out;
}

const json = (status: number, body: unknown) => Response.json(body, { status });

let running = 0;

export async function handlePdf(req: Request): Promise<Response> {
  if (!authorized(req)) return json(401, { message: "unauthorized" });
  try {
    if (Number(req.headers.get("content-length") ?? 0) > MAX_REQUEST) throw new WorkerError(400, "request is too large");
    const rawText = await req.text();
    if (rawText.length > MAX_REQUEST) throw new WorkerError(400, "request is too large");
    let parsed: unknown;
    try {
      parsed = JSON.parse(rawText);
    } catch {
      throw new WorkerError(400, "request isn't valid JSON");
    }
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new WorkerError(400, "request must be a JSON object");
    }
    const o = parsed as Obj;
    if (typeof o.html !== "string" || o.html.trim() === "") throw new WorkerError(400, "html: is required");
    if (Buffer.byteLength(o.html, "utf8") > MAX_HTML_BYTES) throw new WorkerError(400, "html: is too large (max 40 MB)");
    if (o.css !== undefined && o.css !== null) {
      if (typeof o.css !== "string") throw new WorkerError(400, "css: must be a string");
      if (Buffer.byteLength(o.css, "utf8") > MAX_CSS_BYTES) throw new WorkerError(400, "css: is too large (max 8 MB)");
    }
    const orientationRaw = o.orientation === undefined || o.orientation === null || o.orientation === "" ? "portrait" : o.orientation;
    if (orientationRaw !== "portrait" && orientationRaw !== "landscape") {
      throw new WorkerError(400, "orientation: use portrait or landscape");
    }
    const landscape = orientationRaw === "landscape";
    const size = resolvePageSize(o.page_size);
    const headerHtml = o.header_html === undefined || o.header_html === null ? undefined : String(o.header_html);
    const footerHtml = o.footer_html === undefined || o.footer_html === null ? undefined : String(o.footer_html);
    if (o.header_html !== undefined && o.header_html !== null && typeof o.header_html !== "string") {
      throw new WorkerError(400, "header_html: must be a string");
    }
    if (o.footer_html !== undefined && o.footer_html !== null && typeof o.footer_html !== "string") {
      throw new WorkerError(400, "footer_html: must be a string");
    }
    if (headerHtml && Buffer.byteLength(headerHtml, "utf8") > MAX_TEMPLATE_BYTES) throw new WorkerError(400, "header_html: is too large");
    if (footerHtml && Buffer.byteLength(footerHtml, "utf8") > MAX_TEMPLATE_BYTES) throw new WorkerError(400, "footer_html: is too large");
    const margins = parseMargins(o.margins, Boolean(headerHtml), Boolean(footerHtml));
    const printBackground = o.print_background === undefined ? true : Boolean(o.print_background);
    if (o.print_background !== undefined && typeof o.print_background !== "boolean") {
      throw new WorkerError(400, "print_background: must be a boolean");
    }
    const previewPages = parsePreviewPages(o.preview_pages);
    const docHtml = buildDocumentHtml(o.html, typeof o.css === "string" ? o.css : undefined);

    if (running >= PDF_MAX_CONCURRENT) return json(503, { message: "the PDF renderer is busy; try again" });
    running++;
    const signal = AbortSignal.timeout(PDF_TIMEOUT_MS);
    try {
      const out = await new Promise<PdfRenderOutput>((resolve, reject) => {
        if (signal.aborted) return reject(new WorkerError(504, "PDF render timed out"));
        const onAbort = () => reject(new WorkerError(504, "PDF render timed out"));
        signal.addEventListener("abort", onAbort, { once: true });
        pdfDeps
          .render(
            {
              html: docHtml,
              paperWidthIn: size.widthIn,
              paperHeightIn: size.heightIn,
              landscape,
              marginTopIn: margins.top,
              marginRightIn: margins.right,
              marginBottomIn: margins.bottom,
              marginLeftIn: margins.left,
              printBackground,
              headerHtml,
              footerHtml,
              previewPages,
            },
            signal,
          )
          .then(
            (res) => {
              signal.removeEventListener("abort", onAbort);
              resolve(res);
            },
            (err) => {
              signal.removeEventListener("abort", onAbort);
              reject(err);
            },
          );
      });
      if (out.pdf.length === 0) throw new WorkerError(500, "PDF render produced an empty file");
      if (out.pdf.length > MAX_PDF_BYTES) throw new WorkerError(400, "rendered PDF is over the 25 MB limit");
      return json(200, {
        pdf_base64: out.pdf.toString("base64"),
        pages: out.pages,
        page_size: landscape ? `${size.label} landscape` : size.label,
        previews: out.previews.map((p) => ({
          page: p.page,
          width: p.width,
          height: p.height,
          png_base64: p.png.toString("base64"),
        })),
      });
    } finally {
      running--;
    }
  } catch (e) {
    if (e instanceof WorkerError) return json(e.status, { message: e.message });
    if (e instanceof BrowserUnavailableError) return json(503, { message: e.message });
    console.error("pdf worker:", e);
    return json(500, { message: "PDF render failed" });
  }
}
