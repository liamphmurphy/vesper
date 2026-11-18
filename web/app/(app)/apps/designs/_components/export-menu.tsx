"use client";

import Link from "next/link";
import { Popover } from "radix-ui";
import { useCallback, useMemo, useRef, useState } from "react";
import { downloadFile } from "@/lib/api/docs-hooks";
import { useSaveDesignExport } from "@/lib/api/designs-hooks";
import { cx } from "@/lib/cx";
import { ExportError, base64, exportItems, exportPdf, exportSvg, fileName, frameFor, pngTooLarge, renderQuery, usedAssets, type ExportFormat, type ExportItem, type ExportScope, type Loaders } from "@/lib/designs/export";
import { labelOf } from "@/lib/designs/edit";
import { designAssetHref } from "@/lib/designs/render";
import type { Design } from "@/lib/designs/schema";
import { floatPanel } from "@/components/domain/pickers";
import { Button } from "@/components/ui/button";

export type DesignExportNotice = { tone: "ok" | "error" | "busy"; text: string; href?: string; cancellable?: boolean };
type File1 = { name: string; ext: ExportFormat; blob: Blob };

const FORMATS: { id: ExportFormat; label: string; detail: string }[] = [
  { id: "png", label: "PNG", detail: "An image, drawn by the same renderer as the editor" },
  { id: "svg", label: "SVG", detail: "Text stays text; Inter is embedded, so it opens offline" },
  { id: "pdf", label: "PDF", detail: "One page per frame, at the frame’s size" },
];
const MIME: Record<ExportFormat, string> = { png: "image/png", svg: "image/svg+xml", pdf: "application/pdf" };

const label = "text-11 font-medium uppercase tracking-wide text-fg-tertiary";
const choice = (on: boolean) => cx("flex cursor-pointer items-start gap-2 rounded-md px-2 py-1.5 text-13 text-fg", on ? "bg-selected" : "hover:bg-hover");

async function bytes(url: string, signal: AbortSignal, what: string): Promise<Response> {
  const r = await fetch(url, { credentials: "same-origin", signal });
  if (!r.ok && r.status !== 404) throw new ExportError(`couldn’t load ${what} (${r.status})`);
  return r;
}

/** Fonts from the app, and the design's images as data URIs (a missing one draws empty, as in the editor). */
async function browserLoaders(id: string, items: ExportItem[], signal: AbortSignal): Promise<Loaders> {
  const assets: Record<string, string> = {};
  await Promise.all(
    usedAssets(items).map(async (a) => {
      const r = await bytes(designAssetHref(id, a), signal, "an image");
      if (!r.ok) return;
      const type = (r.headers.get("content-type") ?? "image/png").split(";")[0];
      assets[a] = `data:${type};base64,${base64(new Uint8Array(await r.arrayBuffer()))}`;
    }),
  );
  return {
    assets,
    font: async (face, kind) => {
      const r = await bytes(`/fonts/designs/Inter-${face}.${kind}`, signal, "a font");
      if (!r.ok) throw new ExportError(`couldn’t load the Inter ${face} font`);
      return new Uint8Array(await r.arrayBuffer());
    },
  };
}

/** The server's message for a refused render, else its status. */
async function renderError(r: Response): Promise<string> {
  const b = (await r.json().catch(() => ({}))) as { message?: string };
  return b.message ?? `the renderer answered ${r.status}`;
}

/**
 * The Export menu (ADR-designs §3.10): the selection, a frame, the page or
 * every frame, as PNG (1×/2×/3×, from the server renderer), SVG or PDF,
 * downloaded or saved to the Library. `current` saves pending edits first and
 * returns the design as saved, so the export never misses the last change and
 * a PNG (drawn from the saved version) matches the others. Every file is
 * built in full before anything is downloaded or uploaded, so a failure
 * leaves nothing behind.
 */
/** What an export is: the web popover's choices, or the Mac app's menu entry picked directly. */
export type ExportChoice = { format: ExportFormat; scale: number; scope: ExportScope };

export function useDesignExport({ id, title, design, pageId, selected, current }: { id: string; title: string; design?: Design; pageId?: string; selected: string[]; current: () => Promise<Design> }) {
  const save = useSaveDesignExport(id);
  const [open, setOpen] = useState(false);
  const [format, setFormat] = useState<ExportFormat>("png");
  const [scale, setScale] = useState(2);
  const [picked, setScope] = useState<ExportScope>();
  const [notice, setNotice] = useState<DesignExportNotice>();
  const abort = useRef<AbortController | null>(null);
  const busy = notice?.tone === "busy";

  // Only while the menu is open: the editor re-renders on every pan frame, and this needn't.
  const scopes = useMemo(() => {
    if (!design || !open) return [];
    const page = design.pages.find((p) => p.id === pageId) ?? design.pages[0];
    const at = { page: pageId, selected };
    const counts = Object.fromEntries((["selection", "frame", "page", "frames"] as const).map((scope) => [scope, exportItems(design, scope, at).length]));
    const sel = counts.selection;
    const frame = frameFor(design, pageId, selected);
    const frames = counts.frames;
    return [
      { id: "selection" as const, text: sel ? `Selection (${sel})` : "Selection", count: sel },
      { id: "frame" as const, text: frame ? `Frame: ${labelOf(frame.frame)}` : "Frame", count: counts.frame },
      { id: "page" as const, text: `Page: ${page?.name ?? ""}`, count: counts.page },
      { id: "frames" as const, text: `All frames (${frames})`, count: frames },
    ];
  }, [design, open, pageId, selected]);
  const scope: ExportScope = picked && scopes.find((s) => s.id === picked && s.count) ? picked : (scopes.find((s) => s.count)?.id ?? "page");
  const count = scopes.find((s) => s.id === scope)?.count ?? 0;
  // The Library takes one file per save, so nothing is ever half saved.
  const oneFile = format === "pdf" || count === 1;

  const say = (n: DesignExportNotice) => {
    setNotice(n);
    if (n.tone !== "busy") setTimeout(() => setNotice((x) => (x === n ? undefined : x)), n.tone === "error" ? 10000 : 6000);
  };

  async function build(signal: AbortSignal, { format, scale, scope }: ExportChoice): Promise<File1[]> {
    const d = await current();
    const items = exportItems(d, scope, { page: pageId, selected });
    if (!items.length) throw new ExportError("there’s nothing to export there");
    const pageName = d.pages.find((p) => p.id === pageId)?.name ?? d.pages[0]?.name ?? "";
    const named = (it: ExportItem) => fileName(title, it.name === title ? "" : it.name);
    const unique = (files: File1[]) => {
      const seen = new Map<string, number>();
      return files.map((f) => {
        const n = (seen.get(f.name) ?? 0) + 1;
        seen.set(f.name, n);
        return n > 1 ? { ...f, name: `${f.name} (${n})` } : f;
      });
    };
    if (format === "png") {
      for (const it of items) {
        const big = pngTooLarge(it, scale);
        if (big) throw new ExportError(big);
      }
      const files: File1[] = [];
      for (const [i, it] of items.entries()) {
        if (items.length > 1) setNotice({ tone: "busy", text: `Rendering PNG ${i + 1} of ${items.length}…` });
        const r = await fetch(`/api/v1/designs/${id}/render?${renderQuery(it, scale)}`, { credentials: "same-origin", signal });
        if (!r.ok) throw new ExportError(await renderError(r));
        files.push({ name: named(it), ext: "png", blob: await r.blob() });
      }
      return unique(files);
    }
    const load = await browserLoaders(id, items, signal);
    if (format === "svg") return unique(await Promise.all(items.map(async (it) => ({ name: named(it), ext: "svg" as const, blob: new Blob([await exportSvg(it, load)], { type: MIME.svg }) }))));
    const pdf = await exportPdf(items, load, signal);
    const name = items.length === 1 ? named(items[0]) : fileName(title, scope === "page" ? pageName : scope === "frames" ? "All frames" : "Selection");
    return [{ name, ext: "pdf", blob: new Blob([pdf as BlobPart], { type: MIME.pdf }) }];
  }

  async function run(to: "download" | "library", pick?: Partial<ExportChoice>) {
    const choice: ExportChoice = { format, scale, scope, ...pick };
    setOpen(false);
    const ctl = new AbortController();
    abort.current = ctl;
    const what = choice.format.toUpperCase();
    say({ tone: "busy", text: `Building ${what}…` });
    try {
      const files = await build(ctl.signal, choice);
      if (ctl.signal.aborted) return say({ tone: "ok", text: "Export cancelled" });
      if (to === "library") {
        if (files.length !== 1) throw new ExportError("the Library takes one file at a time: export one item, or a PDF");
        const [f] = files;
        say({ tone: "busy", text: "Saving to your Library…", cancellable: false });
        await save.mutateAsync(new File([f.blob], `${f.name}.${f.ext}`, { type: MIME[f.ext] }));
        say({ tone: "ok", text: `Saved “${f.name}.${f.ext}” to your Library`, href: "/library" });
      } else if (files.length === 1) {
        downloadFile(files[0].name, files[0].ext, files[0].blob);
        say({ tone: "ok", text: `Downloaded “${files[0].name}.${files[0].ext}”` });
      } else {
        say({ tone: "busy", text: "Preparing download…", cancellable: false });
        const { default: JSZip } = await import("jszip");
        const zip = new JSZip();
        for (const f of files) zip.file(`${f.name}.${f.ext}`, f.blob);
        const name = fileName(title, `${what} export`);
        downloadFile(name, "zip", await zip.generateAsync({ type: "blob" }));
        say({ tone: "ok", text: `Downloaded ${files.length} ${what} files in “${name}.zip”` });
      }
    } catch (e) {
      if (ctl.signal.aborted) return say({ tone: "ok", text: "Export cancelled" });
      const msg = e instanceof Error && e.message ? e.message : "try again";
      say({ tone: "error", text: to === "library" ? `Couldn’t save the ${what} to your Library: ${msg}. Nothing was saved.` : `${what} export failed: ${msg}` });
    } finally {
      if (abort.current === ctl) abort.current = null;
    }
  }

  const cancel = useCallback(() => abort.current?.abort(), []);
  return { save, open, setOpen, format, setFormat, scale, setScale, setScope, notice, busy, scopes, scope, count, oneFile, run, cancel };
}

export type DesignExport = ReturnType<typeof useDesignExport>;

/** Export as a popover over `x`; `trigger` renames its button, e.g. the editor header's Share ▾. */
export function ExportMenu({ x, design, trigger }: { x: DesignExport; design?: Design; trigger?: string }) {
  const { save, open, setOpen, format, setFormat, scale, setScale, setScope, notice, busy, scopes, scope, count, oneFile, run, cancel } = x;

  return (
    <div className="flex items-center gap-2">
      {notice && (
        <span role={notice.tone === "error" ? "alert" : "status"} data-testid="design-export-notice" className={cx("max-w-[420px] truncate text-12", notice.tone === "error" ? "text-pill-blocked-fg" : "text-fg-secondary")} title={notice.text}>
          {notice.text}
          {notice.tone === "busy" && notice.cancellable !== false && (
            <button type="button" className="ml-2 text-accent hover:underline" onClick={cancel}>
              Cancel
            </button>
          )}
          {notice.href && (
            <>
              {" · "}
              <Link href={notice.href} className="text-accent hover:underline">Open</Link>
            </>
          )}
        </span>
      )}
      <Popover.Root open={open} onOpenChange={setOpen}>
        <Popover.Trigger asChild>
          {trigger ? (
            <Button variant="primary" disabled={!design || busy}>
              {trigger} <span aria-hidden>▾</span>
            </Button>
          ) : (
            <Button variant="secondary" icon="download" disabled={!design || busy}>
              Export
            </Button>
          )}
        </Popover.Trigger>
        <Popover.Portal>
          <Popover.Content align="end" sideOffset={6} aria-label="Export" className={cx(floatPanel, "z-50 flex w-[320px] flex-col gap-3 p-3")}>
            {trigger && <span className="text-13 font-semibold text-fg">Export</span>}
            <fieldset className="flex flex-col gap-0.5">
              <legend className={label}>What</legend>
              {scopes.map((s) => (
                <label key={s.id} className={cx(choice(scope === s.id), !s.count && "cursor-not-allowed opacity-50")}>
                  <input type="radio" name="export-scope" className="mt-0.5" checked={scope === s.id} disabled={!s.count} onChange={() => setScope(s.id)} />
                  <span className="truncate">{s.text}</span>
                </label>
              ))}
            </fieldset>
            <fieldset className="flex flex-col gap-0.5">
              <legend className={label}>Format</legend>
              {FORMATS.map((f) => (
                <label key={f.id} className={choice(format === f.id)}>
                  <input type="radio" name="export-format" className="mt-0.5" checked={format === f.id} onChange={() => setFormat(f.id)} />
                  <span className="flex flex-col">
                    {f.label}
                    <span className="text-11 text-fg-tertiary">{f.detail}</span>
                  </span>
                </label>
              ))}
            </fieldset>
            {format === "png" && (
              <div className="flex items-center gap-2" role="radiogroup" aria-label="Scale">
                <span className={label}>Scale</span>
                {[1, 2, 3].map((s) => (
                  <button key={s} type="button" role="radio" aria-checked={scale === s} onClick={() => setScale(s)} className={cx("rounded-md border px-2 py-0.5 text-13", scale === s ? "border-accent bg-selected text-fg" : "border-border text-fg-secondary hover:bg-hover")}>
                    {s}×
                  </button>
                ))}
              </div>
            )}
            <div className="flex flex-col gap-1.5 border-t border-border-subtle pt-3">
              <div className="flex gap-2">
                <Button variant="primary" className="flex-1" disabled={!count} onClick={() => void run("download")}>
                  Download{count > 1 && format !== "pdf" ? ` ${count} files` : ""}
                </Button>
                <Button variant="secondary" className="flex-1" disabled={!count || !oneFile || save.isPending} onClick={() => void run("library")}>
                  Save to Library
                </Button>
              </div>
              {!!count && !oneFile && <span className="text-11 text-fg-tertiary">The Library takes one file at a time: pick one item, or PDF.</span>}
            </div>
          </Popover.Content>
        </Popover.Portal>
      </Popover.Root>
    </div>
  );
}
