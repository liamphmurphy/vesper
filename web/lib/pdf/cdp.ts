// Offline headless Chromium renderer over raw Chrome DevTools Protocol (CDP).
// Uses Node 24's built-in WebSocket with zero external runtime dependencies.
//
// Security model:
// - The browser starts with --proxy-server=http://127.0.0.1:1 and CDP Fetch
//   interception enabled on every tab.
// - Document rendering disables JavaScript execution and only fulfills bundled
//   local fonts on https://vesper-fonts.local/* from a fixed filename allowlist;
//   every other URL (http, https, file, ws) is failed with BlockedByClient.
// - Page PNG previews rasterize the generated PDF bytes in a separate blank tab
//   using only the bundled pdfjs-dist files on https://vesper-pdfjs.local/*.
import { spawn, type ChildProcess } from "node:child_process";
import { existsSync, mkdtempSync, readdirSync, readFileSync, rmSync } from "node:fs";
import { homedir, tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

export const FONT_ORIGIN = "https://vesper-fonts.local";
const PDFJS_ORIGIN = "https://vesper-pdfjs.local";

export interface BundledFont {
  urlPath: string;
  relPath: string;
  family: string;
  weight: number;
  style: "normal" | "italic";
}

/** Static TTFs already shipped under web/public/fonts (copied to dist/fonts on build). */
export const BUNDLED_FONTS: readonly BundledFont[] = [
  { urlPath: "designs/Inter-Regular.ttf", relPath: "designs/Inter-Regular.ttf", family: "Inter", weight: 400, style: "normal" },
  { urlPath: "designs/Inter-Italic.ttf", relPath: "designs/Inter-Italic.ttf", family: "Inter", weight: 400, style: "italic" },
  { urlPath: "designs/Inter-Medium.ttf", relPath: "designs/Inter-Medium.ttf", family: "Inter", weight: 500, style: "normal" },
  { urlPath: "designs/Inter-MediumItalic.ttf", relPath: "designs/Inter-MediumItalic.ttf", family: "Inter", weight: 500, style: "italic" },
  { urlPath: "designs/Inter-SemiBold.ttf", relPath: "designs/Inter-SemiBold.ttf", family: "Inter", weight: 600, style: "normal" },
  { urlPath: "designs/Inter-SemiBoldItalic.ttf", relPath: "designs/Inter-SemiBoldItalic.ttf", family: "Inter", weight: 600, style: "italic" },
  { urlPath: "designs/Inter-Bold.ttf", relPath: "designs/Inter-Bold.ttf", family: "Inter", weight: 700, style: "normal" },
  { urlPath: "designs/Inter-BoldItalic.ttf", relPath: "designs/Inter-BoldItalic.ttf", family: "Inter", weight: 700, style: "italic" },
  { urlPath: "slides/LiberationSans-Regular.ttf", relPath: "slides/LiberationSans-Regular.ttf", family: "Liberation Sans", weight: 400, style: "normal" },
  { urlPath: "slides/LiberationSans-Italic.ttf", relPath: "slides/LiberationSans-Italic.ttf", family: "Liberation Sans", weight: 400, style: "italic" },
  { urlPath: "slides/LiberationSans-Bold.ttf", relPath: "slides/LiberationSans-Bold.ttf", family: "Liberation Sans", weight: 700, style: "normal" },
  { urlPath: "slides/LiberationSans-BoldItalic.ttf", relPath: "slides/LiberationSans-BoldItalic.ttf", family: "Liberation Sans", weight: 700, style: "italic" },
  { urlPath: "slides/LiberationSerif-Regular.ttf", relPath: "slides/LiberationSerif-Regular.ttf", family: "Liberation Serif", weight: 400, style: "normal" },
  { urlPath: "slides/LiberationSerif-Italic.ttf", relPath: "slides/LiberationSerif-Italic.ttf", family: "Liberation Serif", weight: 400, style: "italic" },
  { urlPath: "slides/LiberationSerif-Bold.ttf", relPath: "slides/LiberationSerif-Bold.ttf", family: "Liberation Serif", weight: 700, style: "normal" },
  { urlPath: "slides/LiberationSerif-BoldItalic.ttf", relPath: "slides/LiberationSerif-BoldItalic.ttf", family: "Liberation Serif", weight: 700, style: "italic" },
  { urlPath: "slides/LiberationMono-Regular.ttf", relPath: "slides/LiberationMono-Regular.ttf", family: "Liberation Mono", weight: 400, style: "normal" },
  { urlPath: "slides/LiberationMono-Italic.ttf", relPath: "slides/LiberationMono-Italic.ttf", family: "Liberation Mono", weight: 400, style: "italic" },
  { urlPath: "slides/LiberationMono-Bold.ttf", relPath: "slides/LiberationMono-Bold.ttf", family: "Liberation Mono", weight: 700, style: "normal" },
  { urlPath: "slides/LiberationMono-BoldItalic.ttf", relPath: "slides/LiberationMono-BoldItalic.ttf", family: "Liberation Mono", weight: 700, style: "italic" },
];

export class BrowserUnavailableError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "BrowserUnavailableError";
  }
}

export interface PdfRenderOptions {
  html: string;
  paperWidthIn: number;
  paperHeightIn: number;
  landscape: boolean;
  marginTopIn: number;
  marginRightIn: number;
  marginBottomIn: number;
  marginLeftIn: number;
  printBackground: boolean;
  headerHtml?: string;
  footerHtml?: string;
  previewPages: number[];
}

export interface PdfPagePreview {
  page: number;
  png: Buffer;
  width: number;
  height: number;
}

export interface PdfRenderOutput {
  pdf: Buffer;
  pages: number;
  previews: PdfPagePreview[];
}

const fontBytesCache = new Map<string, Buffer>();
const pdfjsBytesCache = new Map<string, Buffer>();

function resolveFontsRoot(): string | null {
  const candidates: string[] = [];
  if (process.env.VESPER_FONTS_DIR) candidates.push(process.env.VESPER_FONTS_DIR);
  if (process.env.DESIGN_FONT_DIR) candidates.push(dirname(process.env.DESIGN_FONT_DIR));
  const here = dirname(fileURLToPath(import.meta.url));
  candidates.push(join(here, "..", "fonts"));
  candidates.push(join(process.cwd(), "fonts"));
  candidates.push(join(process.cwd(), "public", "fonts"));
  candidates.push(join(here, "..", "..", "public", "fonts"));
  for (const dir of candidates) {
    if (existsSync(join(dir, "designs", "Inter-Regular.ttf"))) return dir;
  }
  return null;
}

function loadBundledFont(urlPath: string): Buffer | null {
  const entry = BUNDLED_FONTS.find((f) => f.urlPath === urlPath);
  if (!entry) return null;
  const cached = fontBytesCache.get(urlPath);
  if (cached) return cached;
  const root = resolveFontsRoot();
  if (!root) return null;
  const full = join(root, entry.relPath);
  if (!existsSync(full)) return null;
  const buf = readFileSync(full);
  fontBytesCache.set(urlPath, buf);
  return buf;
}

function resolvePdfjsDir(): string | null {
  const candidates: string[] = [];
  if (process.env.VESPER_PDFJS_DIR) candidates.push(process.env.VESPER_PDFJS_DIR);
  const here = dirname(fileURLToPath(import.meta.url));
  candidates.push(join(here, "pdfjs"));
  candidates.push(join(process.cwd(), "design-worker", "pdfjs"));
  candidates.push(join(process.cwd(), "node_modules", "pdfjs-dist", "build"));
  candidates.push(join(here, "..", "..", "node_modules", "pdfjs-dist", "build"));
  for (const dir of candidates) {
    if (existsSync(join(dir, "pdf.min.mjs")) && existsSync(join(dir, "pdf.worker.min.mjs"))) return dir;
  }
  return null;
}

function loadPdfjsFile(name: "pdf.min.mjs" | "pdf.worker.min.mjs"): Buffer | null {
  const cached = pdfjsBytesCache.get(name);
  if (cached) return cached;
  const dir = resolvePdfjsDir();
  if (!dir) return null;
  const full = join(dir, name);
  if (!existsSync(full)) return null;
  const buf = readFileSync(full);
  pdfjsBytesCache.set(name, buf);
  return buf;
}

function scanPlaywrightDir(base: string, platform: NodeJS.Platform): string | null {
  if (!existsSync(base)) return null;
  let dirs: string[];
  try {
    dirs = readdirSync(base)
      .filter((d) => d.startsWith("chromium_headless_shell-") || d.startsWith("chromium-"))
      .sort()
      .reverse();
  } catch {
    return null;
  }
  for (const d of dirs) {
    const root = join(base, d);
    const rels =
      platform === "darwin"
        ? [
            "chrome-mac-arm64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
            "chrome-mac-x64/Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing",
            "chrome-mac/Chromium.app/Contents/MacOS/Chromium",
            "chrome-headless-shell-mac-arm64/chrome-headless-shell",
            "chrome-headless-shell-mac-x64/chrome-headless-shell",
            "chrome-mac/headless_shell",
          ]
        : [
            "chrome-linux/chrome",
            "chrome-linux64/chrome",
            "chrome-headless-shell-linux64/chrome-headless-shell",
            "chrome-headless-shell-linux-arm64/chrome-headless-shell",
            "chrome-linux/headless_shell",
          ];
    for (const rel of rels) {
      const candidate = join(root, rel);
      if (existsSync(candidate)) return candidate;
    }
  }
  return null;
}

function findInPath(names: string[], pathEnv: string): string | null {
  for (const dir of pathEnv.split(":").filter(Boolean)) {
    for (const name of names) {
      const candidate = join(dir, name);
      if (existsSync(candidate)) return candidate;
    }
  }
  return null;
}

/** Finds an installed Chromium/Chrome binary without downloading anything. */
export function findBrowser(env: NodeJS.ProcessEnv = process.env, platform: NodeJS.Platform = process.platform): string | null {
  for (const key of ["VESPER_PDF_BROWSER", "PDF_BROWSER_BIN", "CHROME_BIN"] as const) {
    const v = env[key]?.trim();
    if (v && existsSync(v)) return v;
  }
  const home = env.HOME || homedir();
  const pwDirs = [
    env.PLAYWRIGHT_BROWSERS_PATH,
    join(home, "Library", "Caches", "ms-playwright"),
    join(home, ".cache", "ms-playwright"),
  ].filter((x): x is string => !!x);
  for (const dir of pwDirs) {
    const found = scanPlaywrightDir(dir, platform);
    if (found) return found;
  }
  if (platform === "darwin") {
    for (const p of [
      "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
      "/Applications/Chromium.app/Contents/MacOS/Chromium",
      "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
      "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
      "/Applications/Arc.app/Contents/MacOS/Arc",
      "/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary",
    ]) {
      if (existsSync(p)) return p;
    }
  }
  return findInPath(["chromium", "chromium-browser", "google-chrome", "google-chrome-stable", "microsoft-edge"], env.PATH ?? "");
}

/** Lightweight fallback page counter when pdfjs is unavailable. */
export function countPdfPagesFallback(pdf: Buffer): number {
  const s = pdf.toString("latin1");
  const matches = s.match(/\/Type\s*\/Page\b(?!s)/g);
  return Math.max(1, matches?.length ?? 1);
}

interface PendingCall {
  resolve: (v: Record<string, unknown>) => void;
  reject: (e: Error) => void;
}

class CdpClient {
  private ws: WebSocket;
  private nextId = 1;
  private pending = new Map<number, PendingCall>();
  private listeners = new Map<string, Set<(params: Record<string, unknown>, sessionId?: string) => void>>();
  private closed = false;

  private constructor(ws: WebSocket) {
    this.ws = ws;
    ws.addEventListener("message", (ev) => {
      let msg: { id?: number; method?: string; params?: Record<string, unknown>; result?: Record<string, unknown>; error?: { message?: string }; sessionId?: string };
      try {
        msg = JSON.parse(typeof ev.data === "string" ? ev.data : Buffer.from(ev.data as ArrayBuffer).toString("utf8"));
      } catch {
        return;
      }
      if (typeof msg.id === "number") {
        const p = this.pending.get(msg.id);
        if (!p) return;
        this.pending.delete(msg.id);
        if (msg.error) p.reject(new Error(msg.error.message ?? "CDP command failed"));
        else p.resolve(msg.result ?? {});
      } else if (msg.method) {
        const set = this.listeners.get(msg.method);
        if (set) {
          for (const fn of set) fn(msg.params ?? {}, msg.sessionId);
        }
      }
    });
    ws.addEventListener("close", () => this.failAll(new Error("browser DevTools socket closed")));
    ws.addEventListener("error", () => this.failAll(new Error("browser DevTools socket error")));
  }

  static connect(wsUrl: string, signal?: AbortSignal): Promise<CdpClient> {
    return new Promise((resolve, reject) => {
      if (signal?.aborted) return reject(new Error("aborted"));
      const ws = new WebSocket(wsUrl);
      const onAbort = () => {
        ws.close();
        reject(new Error("aborted"));
      };
      signal?.addEventListener("abort", onAbort, { once: true });
      ws.addEventListener("open", () => {
        signal?.removeEventListener("abort", onAbort);
        resolve(new CdpClient(ws));
      }, { once: true });
      ws.addEventListener("error", () => {
        signal?.removeEventListener("abort", onAbort);
        reject(new Error("failed to connect to browser DevTools socket"));
      }, { once: true });
    });
  }

  private failAll(err: Error) {
    if (this.closed) return;
    this.closed = true;
    for (const p of this.pending.values()) p.reject(err);
    this.pending.clear();
  }

  isOpen(): boolean {
    return !this.closed && this.ws.readyState === WebSocket.OPEN;
  }

  send(method: string, params: Record<string, unknown> = {}, sessionId?: string, signal?: AbortSignal): Promise<Record<string, unknown>> {
    if (!this.isOpen()) return Promise.reject(new Error("browser DevTools socket closed"));
    if (signal?.aborted) return Promise.reject(new Error("aborted"));
    const id = this.nextId++;
    return new Promise((resolve, reject) => {
      const onAbort = () => {
        this.pending.delete(id);
        reject(new Error("aborted"));
      };
      signal?.addEventListener("abort", onAbort, { once: true });
      this.pending.set(id, {
        resolve: (v) => {
          signal?.removeEventListener("abort", onAbort);
          resolve(v);
        },
        reject: (e) => {
          signal?.removeEventListener("abort", onAbort);
          reject(e);
        },
      });
      const payload: Record<string, unknown> = { id, method, params };
      if (sessionId) payload.sessionId = sessionId;
      this.ws.send(JSON.stringify(payload));
    });
  }

  on(method: string, fn: (params: Record<string, unknown>, sessionId?: string) => void): () => void {
    let set = this.listeners.get(method);
    if (!set) {
      set = new Set();
      this.listeners.set(method, set);
    }
    set.add(fn);
    return () => set.delete(fn);
  }

  close() {
    this.failAll(new Error("browser closed"));
    try {
      this.ws.close();
    } catch {
      // ignore
    }
  }
}

interface PooledBrowser {
  proc: ChildProcess;
  cdp: CdpClient;
  userDataDir: string;
}

let pooled: PooledBrowser | null = null;
let launching: Promise<PooledBrowser> | null = null;
let activeUses = 0;
let idleTimer: ReturnType<typeof setTimeout> | null = null;
const IDLE_SHUTDOWN_MS = 60_000;

function cleanupBrowser(b: PooledBrowser | null) {
  if (!b) return;
  b.cdp.close();
  try {
    b.proc.kill("SIGKILL");
  } catch {
    // ignore
  }
  try {
    rmSync(b.userDataDir, { recursive: true, force: true });
  } catch {
    // ignore
  }
}

/** Closes any idle headless browser cleanly (called on worker shutdown). */
export function closePdfBrowser() {
  if (idleTimer) {
    clearTimeout(idleTimer);
    idleTimer = null;
  }
  const cur = pooled;
  pooled = null;
  cleanupBrowser(cur);
}

process.once("exit", () => closePdfBrowser());

async function launchBrowser(signal?: AbortSignal): Promise<PooledBrowser> {
  const bin = findBrowser();
  if (!bin) {
    throw new BrowserUnavailableError("PDF renderer unavailable: no Chromium or Chrome browser found (install Chrome/Chromium or set VESPER_PDF_BROWSER)");
  }
  const userDataDir = mkdtempSync(join(tmpdir(), "vesper-pdf-"));
  const headlessFlag = bin.includes("headless_shell") ? "--headless" : "--headless=new";
  const args = [
    headlessFlag,
    "--disable-gpu",
    "--disable-dev-shm-usage",
    "--disable-extensions",
    "--disable-background-networking",
    "--disable-sync",
    "--disable-default-apps",
    "--metrics-recording-only",
    "--no-first-run",
    "--mute-audio",
    "--proxy-server=http://127.0.0.1:1",
    "--remote-debugging-port=0",
    `--user-data-dir=${userDataDir}`,
  ];
  if (process.platform === "linux") args.push("--no-sandbox");
  args.push("about:blank");

  const proc = spawn(bin, args, { stdio: ["ignore", "pipe", "pipe"] });
  let stderr = "";
  const wsUrl = await new Promise<string>((resolve, reject) => {
    let settled = false;
    const finish = (err: Error | null, url?: string) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
      if (err) reject(err);
      else resolve(url!);
    };
    const onAbort = () => finish(new Error("aborted while launching browser"));
    signal?.addEventListener("abort", onAbort, { once: true });
    const timer = setTimeout(() => finish(new Error("timed out waiting for headless browser")), 10_000);
    proc.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
      const m = stderr.match(/DevTools listening on (ws:\/\/[^\s]+)/);
      if (m) finish(null, m[1]);
    });
    proc.once("error", (err) => finish(err));
    proc.once("exit", (code) => finish(new Error(`browser exited (${code ?? "signal"}): ${stderr.slice(-300)}`)));
  }).catch((err) => {
    try {
      proc.kill("SIGKILL");
    } catch {
      // ignore
    }
    rmSync(userDataDir, { recursive: true, force: true });
    throw err;
  });

  try {
    const cdp = await CdpClient.connect(wsUrl, signal);
    const b: PooledBrowser = { proc, cdp, userDataDir };
    proc.once("exit", () => {
      if (pooled === b) pooled = null;
      cleanupBrowser(b);
    });
    return b;
  } catch (err) {
    try {
      proc.kill("SIGKILL");
    } catch {
      // ignore
    }
    rmSync(userDataDir, { recursive: true, force: true });
    throw err;
  }
}

async function acquireBrowser(signal?: AbortSignal): Promise<PooledBrowser> {
  if (idleTimer) {
    clearTimeout(idleTimer);
    idleTimer = null;
  }
  if (pooled && pooled.cdp.isOpen()) {
    activeUses++;
    return pooled;
  }
  if (pooled) {
    cleanupBrowser(pooled);
    pooled = null;
  }
  if (!launching) {
    launching = launchBrowser(signal).finally(() => {
      launching = null;
    });
  }
  const b = await launching;
  pooled = b;
  activeUses++;
  return b;
}

function releaseBrowser() {
  activeUses = Math.max(0, activeUses - 1);
  if (activeUses === 0 && pooled && !idleTimer) {
    idleTimer = setTimeout(() => {
      idleTimer = null;
      if (activeUses === 0) closePdfBrowser();
    }, IDLE_SHUTDOWN_MS);
    idleTimer.unref?.();
  }
}

function installOfflineFetchGate(
  cdp: CdpClient,
  sessionId: string,
  allowPdfjs: boolean,
): () => void {
  return cdp.on("Fetch.requestPaused", (params, sid) => {
    if (sid !== sessionId) return;
    const requestId = params.requestId as string;
    const url = (params.request as { url?: string } | undefined)?.url ?? "";
    const fulfill = (body: Buffer, contentType: string) => {
      void cdp
        .send(
          "Fetch.fulfillRequest",
          {
            requestId,
            responseCode: 200,
            responseHeaders: [
              { name: "Content-Type", value: contentType },
              { name: "Access-Control-Allow-Origin", value: "*" },
              { name: "Cache-Control", value: "public, max-age=3600" },
            ],
            body: body.toString("base64"),
          },
          sessionId,
        )
        .catch(() => {});
    };

    if (url.startsWith(`${FONT_ORIGIN}/`)) {
      const font = loadBundledFont(url.slice(FONT_ORIGIN.length + 1));
      if (font) {
        fulfill(font, "font/ttf");
        return;
      }
    }
    if (allowPdfjs && url.startsWith(`${PDFJS_ORIGIN}/`)) {
      const name = url.slice(PDFJS_ORIGIN.length + 1);
      if (name === "pdf.min.mjs" || name === "pdf.worker.min.mjs") {
        const js = loadPdfjsFile(name);
        if (js) {
          fulfill(js, "text/javascript; charset=utf-8");
          return;
        }
      }
    }
    void cdp.send("Fetch.failRequest", { requestId, errorReason: "BlockedByClient" }, sessionId).catch(() => {});
  });
}

async function rasterizePreviewPages(
  cdp: CdpClient,
  browserContextId: string,
  pdf: Buffer,
  previewPages: number[],
  signal?: AbortSignal,
): Promise<{ pages: number; previews: PdfPagePreview[] }> {
  if (!loadPdfjsFile("pdf.min.mjs") || !loadPdfjsFile("pdf.worker.min.mjs")) {
    return { pages: countPdfPagesFallback(pdf), previews: [] };
  }
  const { targetId } = (await cdp.send("Target.createTarget", { url: "about:blank", browserContextId }, undefined, signal)) as { targetId: string };
  const { sessionId } = (await cdp.send("Target.attachToTarget", { targetId, flatten: true }, undefined, signal)) as { sessionId: string };
  const offFetch = installOfflineFetchGate(cdp, sessionId, true);
  try {
    await cdp.send("Page.enable", {}, sessionId, signal);
    await cdp.send("Fetch.enable", { patterns: [{ urlPattern: "*" }] }, sessionId, signal);

    const expr = `(async () => {
      const pdfjs = await import(${JSON.stringify(`${PDFJS_ORIGIN}/pdf.min.mjs`)});
      pdfjs.GlobalWorkerOptions.workerSrc = ${JSON.stringify(`${PDFJS_ORIGIN}/pdf.worker.min.mjs`)};
      const raw = atob(${JSON.stringify(pdf.toString("base64"))});
      const bytes = new Uint8Array(raw.length);
      for (let i = 0; i < raw.length; i++) bytes[i] = raw.charCodeAt(i);
      const doc = await pdfjs.getDocument({ data: bytes, verbosity: 0 }).promise;
      const total = doc.numPages;
      const wanted = ${JSON.stringify(previewPages)}.filter((n) => Number.isInteger(n) && n >= 1 && n <= total);
      const seen = new Set();
      const previews = [];
      for (const n of wanted) {
        if (seen.has(n)) continue;
        seen.add(n);
        const page = await doc.getPage(n);
        const base = page.getViewport({ scale: 1 });
        const scale = Math.min(2, 900 / Math.max(base.width, 1));
        const vp = page.getViewport({ scale });
        const canvas = document.createElement("canvas");
        canvas.width = Math.max(1, Math.round(vp.width));
        canvas.height = Math.max(1, Math.round(vp.height));
        const ctx = canvas.getContext("2d");
        ctx.fillStyle = "#ffffff";
        ctx.fillRect(0, 0, canvas.width, canvas.height);
        await page.render({ canvas, canvasContext: ctx, viewport: vp }).promise;
        const dataUrl = canvas.toDataURL("image/png");
        previews.push({ page: n, width: canvas.width, height: canvas.height, png_base64: dataUrl.slice("data:image/png;base64,".length) });
      }
      await doc.destroy();
      return { pages: total, previews };
    })()`;

    const evalRes = (await cdp.send(
      "Runtime.evaluate",
      { expression: expr, awaitPromise: true, returnByValue: true },
      sessionId,
      signal,
    )) as { result?: { value?: { pages: number; previews: { page: number; width: number; height: number; png_base64: string }[] } }; exceptionDetails?: { text?: string } };
    if (evalRes.exceptionDetails || !evalRes.result?.value) {
      return { pages: countPdfPagesFallback(pdf), previews: [] };
    }
    const val = evalRes.result.value;
    return {
      pages: Math.max(1, val.pages),
      previews: val.previews.map((p) => ({
        page: p.page,
        width: p.width,
        height: p.height,
        png: Buffer.from(p.png_base64, "base64"),
      })),
    };
  } finally {
    offFetch();
    void cdp.send("Target.closeTarget", { targetId }).catch(() => {});
  }
}

/** Renders HTML+CSS to PDF bytes and optional page PNG previews in an offline Chromium context. */
export async function renderHtmlToPdf(opts: PdfRenderOptions, signal?: AbortSignal): Promise<PdfRenderOutput> {
  const b = await acquireBrowser(signal);
  try {
    const { browserContextId } = (await b.cdp.send("Target.createBrowserContext", { disposeOnDetach: true }, undefined, signal)) as { browserContextId: string };
    try {
      const { targetId } = (await b.cdp.send("Target.createTarget", { url: "about:blank", browserContextId }, undefined, signal)) as { targetId: string };
      const { sessionId } = (await b.cdp.send("Target.attachToTarget", { targetId, flatten: true }, undefined, signal)) as { sessionId: string };
      const offFetch = installOfflineFetchGate(b.cdp, sessionId, false);
      let pdf: Buffer;
      try {
        await b.cdp.send("Page.enable", {}, sessionId, signal);
        await b.cdp.send("Fetch.enable", { patterns: [{ urlPattern: "*" }] }, sessionId, signal);
        await b.cdp.send("Emulation.setScriptExecutionDisabled", { value: true }, sessionId, signal);

        const tree = (await b.cdp.send("Page.getFrameTree", {}, sessionId, signal)) as { frameTree: { frame: { id: string } } };
        const frameId = tree.frameTree.frame.id;

        const loaded = new Promise<void>((resolve) => {
          const off = b.cdp.on("Page.loadEventFired", (_p, sid) => {
            if (sid !== sessionId) return;
            off();
            resolve();
          });
          setTimeout(() => {
            off();
            resolve();
          }, 3000);
        });
        await b.cdp.send("Page.setDocumentContent", { frameId, html: opts.html }, sessionId, signal);
        await loaded;
        // Wait for bundled @font-face webfonts and inlined images to finish decoding before printing.
        await b.cdp
          .send(
            "Runtime.evaluate",
            {
              expression: `Promise.all([
                document.fonts ? document.fonts.ready : Promise.resolve(),
                ...Array.from(document.images, (img) => (typeof img.decode === "function" ? img.decode().catch(() => {}) : Promise.resolve()))
              ]).then(() => true)`,
              awaitPromise: true,
            },
            sessionId,
            signal,
          )
          .catch(() => {});

        const hasHeaderFooter = Boolean(opts.headerHtml || opts.footerHtml);
        const printRes = (await b.cdp.send(
          "Page.printToPDF",
          {
            landscape: opts.landscape,
            displayHeaderFooter: hasHeaderFooter,
            headerTemplate: opts.headerHtml ?? "<span></span>",
            footerTemplate: opts.footerHtml ?? "<span></span>",
            printBackground: opts.printBackground,
            paperWidth: opts.paperWidthIn,
            paperHeight: opts.paperHeightIn,
            marginTop: opts.marginTopIn,
            marginBottom: opts.marginBottomIn,
            marginLeft: opts.marginLeftIn,
            marginRight: opts.marginRightIn,
            preferCSSPageSize: true,
          },
          sessionId,
          signal,
        )) as { data?: string };
        if (!printRes.data) throw new Error("Chromium returned empty PDF data");
        pdf = Buffer.from(printRes.data, "base64");
      } finally {
        offFetch();
        void b.cdp.send("Target.closeTarget", { targetId }).catch(() => {});
      }

      const { pages, previews } = await rasterizePreviewPages(b.cdp, browserContextId, pdf, opts.previewPages, signal);
      return { pdf, pages, previews };
    } finally {
      void b.cdp.send("Target.disposeBrowserContext", { browserContextId }).catch(() => {});
    }
  } finally {
    releaseBrowser();
  }
}
