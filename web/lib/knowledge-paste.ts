import { Extension } from "@tiptap/core";
import { Plugin, PluginKey, Selection, TextSelection, type EditorState, type Transaction } from "@tiptap/pm/state";
import { Decoration, DecorationSet } from "@tiptap/pm/view";
import type { Embed, UploadedAsset } from "./api/knowledge-hooks";

/** Matches the server's 512 MB limit on POST /api/v1/knowledge/assets. */
export const KNOWLEDGE_ASSET_LIMIT = 512 * 1024 * 1024;

export type ClipboardLike = {
  files?: ArrayLike<File>;
  items?: ArrayLike<{ kind: string; type: string; getAsFile?: () => File | null }>;
  getData: (type: string) => string;
  types?: ArrayLike<string>;
};

export type ExtractedClipboardFile = { file: File; filename: string };

const MIME_EXT: Record<string, string> = {
  "image/png": "png",
  "image/jpeg": "jpg",
  "image/gif": "gif",
  "image/webp": "webp",
  "image/svg+xml": "svg",
  "image/bmp": "bmp",
  "image/tiff": "tiff",
  "image/avif": "avif",
  "image/heic": "heic",
  "application/pdf": "pdf",
  "audio/mpeg": "mp3",
  "audio/wav": "wav",
  "audio/wave": "wav",
  "audio/x-wav": "wav",
  "audio/ogg": "ogg",
  "audio/mp4": "m4a",
  "audio/x-m4a": "m4a",
  "audio/flac": "flac",
  "audio/webm": "webm",
  "video/mp4": "mp4",
  "video/webm": "webm",
  "video/quicktime": "mov",
  "application/zip": "zip",
  "application/x-zip-compressed": "zip",
};

function extensionForMime(type: string): string {
  const base = type.split(";")[0]?.trim().toLowerCase() ?? "";
  if (MIME_EXT[base]) return MIME_EXT[base];
  if (!base || base === "application/octet-stream" || base === "binary/octet-stream") return "";
  const sub = base.split("/")[1]?.split("+")[0] ?? "";
  const clean = sub.replace(/^x-/, "").replace(/[^a-z0-9]/g, "");
  return clean.length <= 10 ? clean : "";
}

/** Validates a clipboard file before uploading it to Knowledge assets. */
export function validateKnowledgeAssetFile(file: { name: string; size: number }): string | undefined {
  if (file.size === 0) return "file is empty";
  if (file.size > KNOWLEDGE_ASSET_LIMIT) return "over 512 MB";
  return undefined;
}

/** Keeps real filenames (such as dropped/copied PDFs or screenshots) and generates clean names for anonymous clipboard blobs. */
export function pastedKnowledgeFileName(file: { name: string; type: string }, n: number): string {
  const trimmed = (file.name ?? "").trim();
  const isGeneric = !trimmed || /^(?:blob|file|clipboard|image)$/i.test(trimmed) || /^image\.[a-z0-9+.-]+$/i.test(trimmed);
  if (!isGeneric) return trimmed;
  const base = (file.type ?? "").split(";")[0]?.trim().toLowerCase() ?? "";
  const ext = extensionForMime(base);
  const prefix = base.startsWith("image/")
    ? "pasted-image"
    : base.startsWith("video/")
      ? "pasted-video"
      : base.startsWith("audio/")
        ? "pasted-audio"
        : "pasted-file";
  return `${prefix}-${n}${ext ? `.${ext}` : ""}`;
}

function basenameOf(raw: string): string {
  if (raw.startsWith("file://")) {
    try {
      const pathname = decodeURIComponent(new URL(raw).pathname);
      return pathname.split("/").filter(Boolean).pop() ?? "";
    } catch {
      // Fall through to generic path splitting.
    }
  }
  return raw.replace(/\\/g, "/").split("/").filter(Boolean).pop() ?? "";
}

function plainMatchesFiles(plain: string, files: File[]): boolean {
  const names = new Set(files.map((f) => f.name.trim()).filter(Boolean));
  if (names.size === 0) return false;
  const lines = plain
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter(Boolean);
  if (lines.length === 0) return false;
  return lines.every((line) => names.has(line) || names.has(basenameOf(line)));
}

function visibleHtmlText(html: string): string {
  return html
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<(?:style|script)\b[^>]*>[\s\S]*?<\/(?:style|script)>/gi, "")
    .replace(/<[^>]*>/g, "")
    .replace(/&nbsp;|&#160;/gi, " ")
    .trim();
}

function decodeHtmlAttr(s: string): string {
  return s.replace(/&amp;/gi, "&").replace(/&quot;/gi, '"').replace(/&#39;/g, "'").replace(/&lt;/gi, "<").replace(/&gt;/gi, ">");
}

function extractHtmlImgSrcs(html: string): string[] {
  const out: string[] = [];
  for (const m of html.matchAll(/<img\b[^>]*\bsrc\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))/gi)) {
    const src = decodeHtmlAttr(m[1] ?? m[2] ?? m[3] ?? "").trim();
    if (src) out.push(src);
  }
  return out;
}

function plainMatchesSoleHtmlImgSrc(plain: string, html: string): boolean {
  if (!html || visibleHtmlText(html) !== "") return false;
  const srcs = extractHtmlImgSrcs(html);
  return srcs.length === 1 && srcs[0] === plain;
}

function decodeDataUriToFile(uri: string, nextIndex: () => number): ExtractedClipboardFile | null {
  if (!uri.slice(0, 5).toLowerCase().startsWith("data:")) return null;
  const comma = uri.indexOf(",");
  if (comma < 0) return null;
  const header = uri.slice(5, comma);
  const payload = uri.slice(comma + 1);
  const parts = header.split(";");
  const mime = parts[0]?.trim().toLowerCase() || "text/plain";
  if (mime.startsWith("text/")) return null;
  const isBase64 = parts.some((p) => p.trim().toLowerCase() === "base64");
  let bytes: Uint8Array<ArrayBuffer>;
  try {
    if (isBase64) {
      const bin = atob(payload.replace(/\s+/g, ""));
      bytes = new Uint8Array(new ArrayBuffer(bin.length));
      for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
    } else {
      const encoded = new TextEncoder().encode(decodeURIComponent(payload));
      const copy = new Uint8Array(new ArrayBuffer(encoded.byteLength));
      copy.set(encoded);
      bytes = copy;
    }
  } catch {
    return null;
  }
  if (bytes.length === 0) return null;
  const filename = pastedKnowledgeFileName({ name: "", type: mime }, nextIndex());
  return { file: new File([bytes], filename, { type: mime }), filename };
}

/**
 * Extracts non-text binary files/images from a paste event while letting text,
 * code, and spreadsheet/rich-text copies (which often carry a synthetic image)
 * fall through to the editor's normal text paste.
 */
export function extractClipboardFiles(data: ClipboardLike | null | undefined, nextIndex: () => number): ExtractedClipboardFile[] {
  if (!data) return [];
  let files = Array.from(data.files ?? []);
  if (files.length === 0 && data.items) {
    files = [];
    for (const item of Array.from(data.items)) {
      if (item.kind === "file") {
        const f = item.getAsFile?.();
        if (f) files.push(f);
      }
    }
  }
  const plain = data.getData("text/plain").trim();
  const html = data.getData("text/html").trim();

  if (files.length > 0) {
    if (
      plain !== "" &&
      !plainMatchesFiles(plain, files) &&
      !plainMatchesSoleHtmlImgSrc(plain, html) &&
      files.every((f) => f.type.startsWith("image/"))
    ) {
      return [];
    }
    return files.map((file) => ({ file, filename: pastedKnowledgeFileName(file, nextIndex()) }));
  }

  if (plain === "") {
    const svg = data.getData("image/svg+xml").trim();
    if (svg && /<svg[\s>]/i.test(svg)) {
      const filename = pastedKnowledgeFileName({ name: "", type: "image/svg+xml" }, nextIndex());
      return [{ file: new File([svg], filename, { type: "image/svg+xml" }), filename }];
    }
    if (html !== "" && visibleHtmlText(html) === "") {
      const out: ExtractedClipboardFile[] = [];
      for (const src of extractHtmlImgSrcs(html)) {
        if (!src.slice(0, 5).toLowerCase().startsWith("data:")) continue;
        const decoded = decodeDataUriToFile(src, nextIndex);
        if (decoded) out.push(decoded);
      }
      if (out.length > 0) return out;
    }
  }

  return [];
}

/** Builds an optimistic inline embed from a completed asset upload so previews appear before autosave completes. */
export function uploadedAssetToEmbed(res: UploadedAsset, file: { type?: string }, fallbackName: string): Embed {
  const slash = res.ref.indexOf("/");
  const refName = slash >= 0 ? res.ref.slice(slash + 1) : "";
  return {
    ref: `![[${res.ref}]]`,
    kind: "file",
    title: res.filename || refName || fallbackName,
    url: res.url,
    content_type: res.content_type || file.type || "application/octet-stream",
    available: true,
  };
}

/**
 * Inserts `![[attachment:...]]` embeds into the document cleanly across empty/non-empty
 * paragraphs, headings, code blocks, lists, quotes, and table cells, without wrapping
 * them in active inline marks or leaving the caret trapped inside raw syntax.
 */
export function buildEmbedInsertTransaction(
  state: EditorState,
  from: number,
  to: number,
  refs: string[],
  preserveSelection: boolean,
): Transaction {
  const tr = state.tr;
  if (refs.length === 0) return tr;

  const max = tr.doc.content.size;
  const start = Math.max(0, Math.min(from, max));
  const end = Math.max(start, Math.min(to, max));
  if (start < end) {
    tr.delete(start, end);
  }

  const at = Math.min(start, tr.doc.content.size);
  const $at = tr.doc.resolve(at);
  const { schema } = state;
  const paragraph = schema.nodes.paragraph;
  const embedParas = refs.map((ref) => paragraph.create(null, schema.text(ref)));
  const embedSize = embedParas.reduce((sum, node) => sum + node.nodeSize, 0);

  let inTableCell = false;
  for (let d = $at.depth; d > 0; d--) {
    const name = $at.node(d).type.name;
    if (name === "tableCell" || name === "tableHeader") {
      inTableCell = true;
      break;
    }
  }

  if (inTableCell && $at.parent.isTextblock && !$at.parent.type.spec.code) {
    const beforeChar = $at.parentOffset > 0 ? $at.parent.textBetween($at.parentOffset - 1, $at.parentOffset, "", " ") : "";
    const afterChar = $at.parentOffset < $at.parent.content.size ? $at.parent.textBetween($at.parentOffset, $at.parentOffset + 1, "", " ") : "";
    const needLead = beforeChar !== "" && !/\s/.test(beforeChar);
    const needTrail = afterChar !== "" && !/\s/.test(afterChar);
    const inline = `${needLead ? " " : ""}${refs.join(" ")}${needTrail ? " " : ""}`;
    tr.insert(at, schema.text(inline));
    if (!preserveSelection) {
      tr.setSelection(TextSelection.create(tr.doc, at + inline.length));
      tr.setStoredMarks([]);
    }
    return tr;
  }

  if (!$at.parent.isTextblock) {
    const container = $at.parent;
    const nextIdx = $at.index();
    const nextSibling = nextIdx < container.childCount ? container.child(nextIdx) : null;
    const needEmptyAfter = !nextSibling || !nextSibling.isTextblock || nextSibling.type.spec.code;
    const nodes = needEmptyAfter ? [...embedParas, paragraph.create()] : embedParas;
    tr.insert(at, nodes);
    if (!preserveSelection) {
      const targetPos = Math.min(at + embedSize + 1, tr.doc.content.size);
      tr.setSelection(Selection.near(tr.doc.resolve(targetPos)));
      tr.setStoredMarks([]);
    }
    return tr;
  }

  const container = $at.node($at.depth - 1);
  const idx = $at.index($at.depth - 1);
  const nextSibling = idx + 1 < container.childCount ? container.child(idx + 1) : null;
  const needEmptyAfter = !nextSibling || !nextSibling.isTextblock || nextSibling.type.spec.code;

  if ($at.parent.type.spec.code || $at.parent.type.name === "heading") {
    const after = $at.after();
    const nodes = !preserveSelection && needEmptyAfter ? [...embedParas, paragraph.create()] : embedParas;
    tr.insert(after, nodes);
    if (!preserveSelection) {
      const targetPos = Math.min(after + embedSize + 1, tr.doc.content.size);
      tr.setSelection(Selection.near(tr.doc.resolve(targetPos)));
      tr.setStoredMarks([]);
    }
    return tr;
  }

  if ($at.parent.content.size === 0) {
    const before = $at.before();
    const after = $at.after();
    const nodes = needEmptyAfter ? [...embedParas, paragraph.create()] : embedParas;
    tr.replaceWith(before, after, nodes);
    if (!preserveSelection) {
      const targetPos = Math.min(before + embedSize + 1, tr.doc.content.size);
      tr.setSelection(Selection.near(tr.doc.resolve(targetPos)));
      tr.setStoredMarks([]);
    }
    return tr;
  }

  if ($at.parentOffset === 0) {
    const before = $at.before();
    tr.insert(before, embedParas);
    if (!preserveSelection) {
      const targetPos = Math.min(before + embedSize + 1, tr.doc.content.size);
      tr.setSelection(Selection.near(tr.doc.resolve(targetPos)));
      tr.setStoredMarks([]);
    }
    return tr;
  }

  if ($at.parentOffset === $at.parent.content.size) {
    const after = $at.after();
    const nodes = needEmptyAfter ? [...embedParas, paragraph.create()] : embedParas;
    tr.insert(after, nodes);
    if (!preserveSelection) {
      const targetPos = Math.min(after + embedSize + 1, tr.doc.content.size);
      tr.setSelection(Selection.near(tr.doc.resolve(targetPos)));
      tr.setStoredMarks([]);
    }
    return tr;
  }

  // Middle of a non-empty paragraph: split at caret and place embeds between the two halves.
  tr.split(at);
  const secondStart = tr.mapping.map(at, 1);
  const between = tr.doc.resolve(secondStart).before();
  tr.insert(between, embedParas);
  if (!preserveSelection) {
    const targetPos = Math.min(between + embedSize + 1, tr.doc.content.size);
    tr.setSelection(Selection.near(tr.doc.resolve(targetPos)));
    tr.setStoredMarks([]);
  }
  return tr;
}

export type KnowledgePasteOptions = {
  upload: (file: File, filename: string, signal: AbortSignal) => Promise<Embed>;
  onError: (title: string, description?: string) => void;
};

type PasteMeta = { add: Decoration[] } | { remove: number };

const pluginKey = new PluginKey<DecorationSet>("knowledgePaste");

function isAbortError(err: unknown): boolean {
  return (err instanceof DOMException || err instanceof Error) && err.name === "AbortError";
}

export function createKnowledgePastePlugin(opts: KnowledgePasteOptions): Plugin<DecorationSet> {
  let batchSeq = 0;
  let pasteSeq = 0;
  let mounted = false;
  const activeControllers = new Set<AbortController>();

  return new Plugin<DecorationSet>({
    key: pluginKey,
    state: {
      init: () => DecorationSet.empty,
      apply: (tr, old) => {
        let set = old.map(tr.mapping, tr.doc);
        const meta = tr.getMeta(pluginKey) as PasteMeta | undefined;
        if (!meta) return set;
        if ("add" in meta) {
          set = set.add(tr.doc, meta.add);
        } else {
          const victim = set.find(undefined, undefined, (spec) => spec.id === meta.remove);
          if (victim.length > 0) set = set.remove(victim);
        }
        return set;
      },
    },
    view(editorView) {
      mounted = true;
      return {
        destroy() {
          mounted = false;
          // EditorView.updatePluginViews destroys and synchronously recreates plugin views
          // when TipTap registers/unregisters a plugin (e.g. mobileEnter on mount).
          // Defer aborting in-flight uploads to a microtask so only real teardown aborts them.
          queueMicrotask(() => {
            if (mounted && !editorView.isDestroyed) return;
            for (const c of activeControllers) c.abort();
            activeControllers.clear();
          });
        },
      };
    },
    props: {
      decorations(state) {
        return pluginKey.getState(state);
      },
      handlePaste(view, event) {
        if (!view.editable) return false;
        const candidates = extractClipboardFiles(event.clipboardData, () => ++pasteSeq);
        if (candidates.length === 0) return false;

        event.preventDefault();

        const valid: ExtractedClipboardFile[] = [];
        for (const c of candidates) {
          const problem = validateKnowledgeAssetFile({ name: c.filename, size: c.file.size });
          if (problem) {
            opts.onError(`Couldn’t paste ${c.filename}`, problem);
          } else {
            valid.push(c);
          }
        }
        if (valid.length === 0) return true;

        const id = ++batchSeq;
        const controller = new AbortController();
        activeControllers.add(controller);

        const { from, to, empty } = view.state.selection;
        const label = valid.length === 1 ? valid[0].filename : `${valid.length} files`;
        const added: Decoration[] = [];
        if (!empty) {
          added.push(Decoration.inline(from, to, { class: "kn-paste-replacing" }, { id, role: "range" }));
        }
        added.push(
          Decoration.widget(
            to,
            () => {
              const el = document.createElement("span");
              el.className = "kn-paste-uploading";
              el.contentEditable = "false";
              el.setAttribute("data-testid", "knowledge-paste-uploading");
              el.setAttribute("role", "status");
              el.textContent = `Uploading ${label}…`;
              return el;
            },
            { id, role: "widget", side: 1, ignoreSelection: true },
          ),
        );
        view.dispatch(view.state.tr.setMeta(pluginKey, { add: added }));

        void Promise.allSettled(valid.map((c) => opts.upload(c.file, c.filename, controller.signal))).then((results) => {
          activeControllers.delete(controller);
          if (!mounted || view.isDestroyed || controller.signal.aborted) return;

          const uploaded: Embed[] = [];
          results.forEach((result, i) => {
            if (result.status === "fulfilled") {
              uploaded.push(result.value);
            } else if (!isAbortError(result.reason)) {
              const message = result.reason instanceof Error ? result.reason.message : undefined;
              opts.onError(`Couldn’t upload ${valid[i].filename}`, message);
            }
          });

          const decos = pluginKey.getState(view.state)?.find(undefined, undefined, (spec) => spec.id === id) ?? [];
          if (decos.length === 0) return;

          const rangeDeco = decos.find((d) => d.spec.role === "range");
          const widgetDeco = decos.find((d) => d.spec.role === "widget") ?? decos[0];
          const insertFrom = rangeDeco ? rangeDeco.from : widgetDeco.from;
          const insertTo = rangeDeco ? rangeDeco.to : widgetDeco.from;

          if (uploaded.length === 0) {
            view.dispatch(view.state.tr.setMeta(pluginKey, { remove: id }));
            return;
          }
          if (!view.editable) {
            view.dispatch(view.state.tr.setMeta(pluginKey, { remove: id }));
            opts.onError("Couldn’t insert pasted file", "This page is locked while changes are in progress.");
            return;
          }

          try {
            const sel = view.state.selection;
            const cursorAtPlaceholder =
              (sel.from === insertFrom && sel.to === insertTo) || (sel.empty && sel.from === insertTo);
            const tr = buildEmbedInsertTransaction(
              view.state,
              insertFrom,
              insertTo,
              uploaded.map((e) => e.ref),
              !cursorAtPlaceholder,
            );
            tr.setMeta(pluginKey, { remove: id });
            view.dispatch(tr);
          } catch (err) {
            if (!view.isDestroyed) {
              view.dispatch(view.state.tr.setMeta(pluginKey, { remove: id }));
            }
            opts.onError("Couldn’t insert pasted file", err instanceof Error ? err.message : undefined);
          }
        });

        return true;
      },
    },
  });
}

export const KnowledgePaste = Extension.create<KnowledgePasteOptions>({
  name: "knowledgePaste",
  addOptions() {
    return {
      upload: async () => {
        throw new Error("KnowledgePaste upload handler not configured");
      },
      onError: () => {},
    };
  },
  addProseMirrorPlugins() {
    return [createKnowledgePastePlugin(this.options)];
  },
});
