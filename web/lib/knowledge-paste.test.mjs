import test from "node:test";
import assert from "node:assert/strict";
import { getSchema } from "@tiptap/core";
import { AllSelection, EditorState, TextSelection } from "@tiptap/pm/state";
import { docExtensions, parseDoc, serializeDoc } from "./doc-markdown.ts";
import { restoreObsidianSyntax } from "./knowledge.ts";
import {
  KNOWLEDGE_ASSET_LIMIT,
  buildEmbedInsertTransaction,
  createKnowledgePastePlugin,
  extractClipboardFiles,
  pastedKnowledgeFileName,
  uploadedAssetToEmbed,
  validateKnowledgeAssetFile,
} from "./knowledge-paste.ts";

const schema = getSchema(docExtensions());

function makeClipboard({ files = [], items = [], text = "", html = "", svg = "" } = {}) {
  return {
    files,
    items,
    getData(type) {
      if (type === "text/plain") return text;
      if (type === "text/html") return html;
      if (type === "image/svg+xml") return svg;
      return "";
    },
  };
}

function stateFromMarkdown(md) {
  const doc = schema.nodeFromJSON(parseDoc(md));
  return EditorState.create({ doc, schema });
}

function toMarkdown(state) {
  return restoreObsidianSyntax(serializeDoc(state.doc.toJSON()));
}

function findTextPos(doc, needle) {
  let found = -1;
  doc.descendants((node, pos) => {
    if (found >= 0 || !node.isText || !node.text) return;
    const idx = node.text.indexOf(needle);
    if (idx >= 0) found = pos + idx;
  });
  return found;
}

test("pastedKnowledgeFileName names generic clipboard blobs by MIME type and keeps real filenames", () => {
  assert.equal(pastedKnowledgeFileName({ name: "image.png", type: "image/png" }, 1), "pasted-image-1.png");
  assert.equal(pastedKnowledgeFileName({ name: "image.jpg", type: "image/jpeg" }, 2), "pasted-image-2.jpg");
  assert.equal(pastedKnowledgeFileName({ name: "blob", type: "image/webp" }, 3), "pasted-image-3.webp");
  assert.equal(pastedKnowledgeFileName({ name: "", type: "application/pdf" }, 4), "pasted-file-4.pdf");
  assert.equal(pastedKnowledgeFileName({ name: "clipboard", type: "video/mp4" }, 5), "pasted-video-5.mp4");
  assert.equal(pastedKnowledgeFileName({ name: "file", type: "audio/mpeg" }, 6), "pasted-audio-6.mp3");
  assert.equal(pastedKnowledgeFileName({ name: "handbook.pdf", type: "application/pdf" }, 7), "handbook.pdf");
  assert.equal(
    pastedKnowledgeFileName({ name: "Screenshot 2026-11-20 at 1.23.45\u202fPM.png", type: "image/png" }, 8),
    "Screenshot 2026-11-20 at 1.23.45\u202fPM.png",
  );
});

test("extractClipboardFiles handles screenshots, copy-image, Finder files, SVG, data URIs, and ignores text/spreadsheet copies", () => {
  const extract = (opts) => {
    let seq = 0;
    return extractClipboardFiles(makeClipboard(opts), () => ++seq);
  };

  // Single and multiple screenshots with generic image names.
  const shot1 = new File([new Uint8Array([1, 2])], "image.png", { type: "image/png" });
  const shot2 = new File([new Uint8Array([3, 4])], "image.jpg", { type: "image/jpeg" });
  const shots = extract({ files: [shot1, shot2] });
  assert.deepEqual(
    shots.map((x) => x.filename),
    ["pasted-image-1.png", "pasted-image-2.jpg"],
  );

  // Browser "Copy Image": HTML <img> + empty text/plain, and Safari putting image URL in text/plain.
  const imgFile = new File([new Uint8Array([1, 2])], "photo.png", { type: "image/png" });
  const copyImg = extract({
    files: [imgFile],
    html: '<meta charset="utf-8"><img src="https://example.com/photo.png" alt="Photo">',
  });
  assert.deepEqual(
    copyImg.map((x) => x.filename),
    ["photo.png"],
  );
  const safariCopyImg = extract({
    files: [imgFile],
    text: "https://example.com/photo.png?a=1&b=2",
    html: '<img src="https://example.com/photo.png?a=1&amp;b=2">',
  });
  assert.deepEqual(
    safariCopyImg.map((x) => x.filename),
    ["photo.png"],
  );

  // Finder copies of non-image files and macOS screenshots with matching text/plain filenames or file:// URIs.
  const macShotName = "Screenshot 2026-11-20 at 1.23.45\u202fPM.png";
  const finderFiles = [
    new File([new Uint8Array([1])], "handbook.pdf", { type: "application/pdf" }),
    new File([new Uint8Array([2])], "clip.mp4", { type: "video/mp4" }),
    new File([new Uint8Array([3])], "voice.mp3", { type: "audio/mpeg" }),
    new File([new Uint8Array([4])], "archive.zip", { type: "application/zip" }),
    new File([new Uint8Array([5])], "diagram.svg", { type: "image/svg+xml" }),
    new File([new Uint8Array([6])], macShotName, { type: "image/png" }),
  ];
  const finderExtracted = extract({
    files: finderFiles,
    text: [
      "handbook.pdf",
      "file:///Users/liam/Movies/clip.mp4",
      "/Users/liam/Music/voice.mp3",
      "archive.zip",
      "diagram.svg",
      "file:///Users/liam/Desktop/Screenshot%202026-11-20%20at%201.23.45%E2%80%AFPM.png",
    ].join("\n"),
  });
  assert.deepEqual(
    finderExtracted.map((x) => x.filename),
    ["handbook.pdf", "clip.mp4", "voice.mp3", "archive.zip", "diagram.svg", macShotName],
  );

  // Spreadsheet / rich-text copy carrying a synthetic preview image falls through to text paste.
  const sheetPreview = new File([new Uint8Array([1])], "image.png", { type: "image/png" });
  assert.deepEqual(
    extract({ files: [sheetPreview], text: "A1\tB1", html: "<table><tr><td>A1</td><td>B1</td></tr></table>" }),
    [],
  );

  // Plain text paste with no files falls through.
  assert.deepEqual(extract({ text: "hello world" }), []);

  // Raw image/svg+xml string paste with empty text/plain produces an SVG file.
  const svgOut = extract({ svg: '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"></svg>' });
  assert.equal(svgOut.length, 1);
  assert.equal(svgOut[0].filename, "pasted-image-1.svg");
  assert.equal(svgOut[0].file.type, "image/svg+xml");

  // HTML-only <img src="data:image/png;base64,..."> produces a decoded PNG file.
  const pngB64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aD1sAAAAASUVORK5CYII=";
  const dataUriOut = extract({ html: `<!--StartFragment--><img src="data:image/png;base64,${pngB64}"><!--EndFragment-->` });
  assert.equal(dataUriOut.length, 1);
  assert.equal(dataUriOut[0].filename, "pasted-image-1.png");
  assert.equal(dataUriOut[0].file.type, "image/png");
  assert.ok(dataUriOut[0].file.size > 0);

  // HTML containing visible text alongside an <img> falls through to rich-text paste.
  assert.deepEqual(extract({ html: `<p>Caption</p><img src="data:image/png;base64,${pngB64}">` }), []);

  // Fallback to clipboardData.items when clipboardData.files is empty.
  const itemFile = new File([new Uint8Array([9, 8])], "image.png", { type: "image/png" });
  const fromItems = extract({ items: [{ kind: "file", type: "image/png", getAsFile: () => itemFile }] });
  assert.deepEqual(
    fromItems.map((x) => x.filename),
    ["pasted-image-1.png"],
  );
});

test("validateKnowledgeAssetFile checks emptiness and 512 MB cap", () => {
  assert.equal(validateKnowledgeAssetFile({ name: "empty.png", size: 0 }), "file is empty");
  assert.equal(validateKnowledgeAssetFile({ name: "huge.zip", size: KNOWLEDGE_ASSET_LIMIT + 1 }), "over 512 MB");
  assert.equal(validateKnowledgeAssetFile({ name: "ok.zip", size: KNOWLEDGE_ASSET_LIMIT }), undefined);
});

test("uploadedAssetToEmbed uses server metadata and falls back cleanly", () => {
  assert.deepEqual(
    uploadedAssetToEmbed(
      {
        id: "id-1",
        ref: "attachment:id-1/map.png",
        url: "/api/v1/knowledge/assets/id-1",
        filename: "map.png",
        content_type: "image/png",
      },
      { type: "application/octet-stream" },
      "fallback.png",
    ),
    {
      ref: "![[attachment:id-1/map.png]]",
      kind: "file",
      title: "map.png",
      url: "/api/v1/knowledge/assets/id-1",
      content_type: "image/png",
      available: true,
    },
  );
  assert.deepEqual(
    uploadedAssetToEmbed(
      {
        id: "id-2",
        ref: "attachment:id-2/notes.pdf",
        url: "/api/v1/knowledge/assets/id-2",
      },
      { type: "application/pdf" },
      "fallback.pdf",
    ),
    {
      ref: "![[attachment:id-2/notes.pdf]]",
      kind: "file",
      title: "notes.pdf",
      url: "/api/v1/knowledge/assets/id-2",
      content_type: "application/pdf",
      available: true,
    },
  );
});

test("buildEmbedInsertTransaction inserts cleanly into empty and non-empty paragraphs", () => {
  const ref = "![[attachment:1/shot.png]]";

  // Empty document -> embed paragraph + trailing empty paragraph, cursor in trailing paragraph.
  let state = stateFromMarkdown("");
  state = state.apply(buildEmbedInsertTransaction(state, state.selection.from, state.selection.to, [ref], false));
  assert.equal(toMarkdown(state), `${ref}\n\n`);
  assert.equal(state.doc.childCount, 2);
  assert.equal(state.selection.$from.parentOffset, 0);
  assert.equal(state.selection.$from.index(0), 1);

  // Empty middle paragraph -> embed in place, cursor moves to next paragraph.
  state = stateFromMarkdown("Before.\n\n\n\nAfter.");
  const secondParaPos = 1 + "Before.".length + 2; // inside empty paragraph if present
  // Ensure 3-paragraph doc with empty middle paragraph explicitly:
  const docWithEmptyMid = schema.node("doc", null, [
    schema.node("paragraph", null, schema.text("Before.")),
    schema.node("paragraph"),
    schema.node("paragraph", null, schema.text("After.")),
  ]);
  state = EditorState.create({ doc: docWithEmptyMid, schema });
  const midStart = 1 + "Before.".length + 1 + 1;
  state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, midStart)));
  assert.equal(state.selection.$from.parent.content.size, 0);
  void secondParaPos;
  state = state.apply(buildEmbedInsertTransaction(state, state.selection.from, state.selection.to, [ref], false));
  assert.equal(toMarkdown(state), `Before.\n\n${ref}\n\nAfter.`);
  assert.equal(state.selection.$from.parent.textContent, "After.");
  assert.equal(state.selection.$from.parentOffset, 0);

  // End of non-empty paragraph.
  state = stateFromMarkdown("Before.");
  state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, 1 + "Before.".length)));
  state = state.apply(buildEmbedInsertTransaction(state, state.selection.from, state.selection.to, [ref], false));
  assert.equal(toMarkdown(state), `Before.\n\n${ref}\n\n`);
  assert.equal(state.selection.$from.parent.textContent, "");

  // Start of non-empty paragraph.
  state = stateFromMarkdown("After.");
  state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, 1)));
  state = state.apply(buildEmbedInsertTransaction(state, state.selection.from, state.selection.to, [ref], false));
  assert.equal(toMarkdown(state), `${ref}\n\nAfter.`);
  assert.equal(state.selection.$from.parent.textContent, "After.");
  assert.equal(state.selection.$from.parentOffset, 0);

  // Middle of non-empty paragraph.
  state = stateFromMarkdown("HelloWorld");
  const mid = findTextPos(state.doc, "World");
  state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, mid)));
  state = state.apply(buildEmbedInsertTransaction(state, state.selection.from, state.selection.to, [ref], false));
  assert.equal(toMarkdown(state), `Hello\n\n${ref}\n\nWorld`);
  assert.equal(state.selection.$from.parent.textContent, "World");
  assert.equal(state.selection.$from.parentOffset, 0);

  // Selection replacement and multiple files.
  state = stateFromMarkdown("Keep [drop me] tail.");
  const dropFrom = findTextPos(state.doc, "[drop me]");
  const dropTo = dropFrom + "[drop me]".length;
  state = state.apply(
    buildEmbedInsertTransaction(
      state,
      dropFrom,
      dropTo,
      ["![[attachment:1/a.png]]", "![[attachment:2/b.pdf]]"],
      false,
    ),
  );
  assert.equal(toMarkdown(state), "Keep \n\n![[attachment:1/a.png]]\n\n![[attachment:2/b.pdf]]\n\n tail.");
  assert.equal(state.selection.$from.parent.textContent, " tail.");

  // AllSelection replacement.
  state = stateFromMarkdown("First.\n\nSecond.");
  state = state.apply(state.tr.setSelection(new AllSelection(state.doc)));
  state = state.apply(buildEmbedInsertTransaction(state, state.selection.from, state.selection.to, [ref], false));
  assert.equal(toMarkdown(state), `${ref}\n\n`);
});

test("buildEmbedInsertTransaction escapes code blocks, headings, and inline marks, and stays inline in tables", () => {
  const ref = "![[attachment:1/shot.png]]";

  // Inside codeBlock -> inserted in paragraph AFTER code block.
  let state = stateFromMarkdown("```ts\nconst x = 1;\n```");
  const codePos = findTextPos(state.doc, "const");
  state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, codePos)));
  state = state.apply(buildEmbedInsertTransaction(state, codePos, codePos, [ref], false));
  assert.equal(toMarkdown(state), `\`\`\`ts\nconst x = 1;\n\`\`\`\n\n${ref}\n\n`);
  assert.equal(state.doc.child(1).type.name, "paragraph");
  assert.equal(state.selection.$from.parent.type.name, "paragraph");
  assert.equal(state.selection.$from.parent.textContent, "");

  // Inside heading -> inserted in paragraph AFTER heading.
  state = stateFromMarkdown("# Heading\n\nBody");
  const hPos = findTextPos(state.doc, "Heading") + 3;
  state = state.apply(buildEmbedInsertTransaction(state, hPos, hPos, [ref], false));
  assert.equal(toMarkdown(state), `# Heading\n\n${ref}\n\nBody`);
  assert.equal(state.selection.$from.parent.textContent, "Body");

  // Inside inline code / bold mark -> embed paragraph has NO marks.
  state = stateFromMarkdown("Use `code` and **bold**.");
  const markPos = findTextPos(state.doc, "code") + 2;
  state = state.apply(buildEmbedInsertTransaction(state, markPos, markPos, [ref], false));
  const embedPara = state.doc.child(1);
  assert.equal(embedPara.textContent, ref);
  assert.equal(embedPara.firstChild.marks.length, 0);

  // Inside tableCell -> inserted inline without splitting table cell.
  state = stateFromMarkdown("| Col A | Col B |\n| --- | --- |\n| cell | next |");
  const cellPos = findTextPos(state.doc, "cell") + "cell".length;
  state = state.apply(buildEmbedInsertTransaction(state, cellPos, cellPos, [ref], false));
  const md = toMarkdown(state);
  assert.match(md, /\| cell !\[\[attachment:1\/shot\.png\]\]\s*\| next\s*\|/);

  // preserveSelection = true keeps user's moved selection intact.
  state = stateFromMarkdown("First.\n\nSecond.");
  const firstEnd = findTextPos(state.doc, "First.") + "First.".length;
  const secondMid = findTextPos(state.doc, "Second.") + 3;
  state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, secondMid)));
  state = state.apply(buildEmbedInsertTransaction(state, firstEnd, firstEnd, [ref], true));
  assert.equal(toMarkdown(state), `First.\n\n${ref}\n\nSecond.`);
  const afterMid = findTextPos(state.doc, "Second.") + 3;
  assert.equal(state.selection.from, afterMid);
});

function createPluginHarness(opts, initialMd = "Before.") {
  const plugin = createKnowledgePastePlugin(opts);
  const doc = schema.nodeFromJSON(parseDoc(initialMd));
  let state = EditorState.create({ doc, schema, plugins: [plugin] });
  const endPos = Math.max(1, state.doc.content.size - 1);
  state = state.apply(state.tr.setSelection(TextSelection.create(state.doc, endPos)));
  let dispatches = 0;
  const view = {
    get state() {
      return state;
    },
    editable: true,
    isDestroyed: false,
    dispatch(tr) {
      dispatches++;
      state = state.apply(tr);
    },
  };
  let pluginView = plugin.spec.view(view);
  return {
    view,
    getState: () => state,
    getDispatches: () => dispatches,
    decorations: () => plugin.props.decorations(state).find(),
    reconfigure() {
      pluginView.destroy?.();
      pluginView = plugin.spec.view(view);
    },
    destroy() {
      view.isDestroyed = true;
      pluginView.destroy?.();
    },
    paste(clipboardData) {
      let prevented = false;
      const handled = plugin.props.handlePaste(view, {
        clipboardData,
        preventDefault() {
          prevented = true;
        },
      });
      return { handled, prevented };
    },
  };
}

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

test("KnowledgePaste inserts embed after mount plugin reconfiguration (TipTap registerPlugin)", async () => {
  const errors = [];
  const d = deferred();
  const h = createPluginHarness({
    upload: () => d.promise,
    onError: (title, desc) => errors.push({ title, desc }),
  });

  // TipTap <EditorContent /> mounts and calls registerPlugin(mobileEnterPlugin),
  // which destroys and synchronously recreates every plugin view.
  h.reconfigure();

  const file = new File([new Uint8Array([1, 2, 3])], "image.png", { type: "image/png" });
  const { handled, prevented } = h.paste(makeClipboard({ files: [file] }));
  assert.equal(handled, true);
  assert.equal(prevented, true);
  assert.equal(h.decorations().length, 1);

  d.resolve({
    ref: "![[attachment:asset-1/pasted-image-1.png]]",
    kind: "file",
    title: "pasted-image-1.png",
    url: "/api/v1/knowledge/assets/asset-1",
    content_type: "image/png",
    available: true,
  });
  await new Promise((r) => setTimeout(r, 0));

  assert.deepEqual(errors, []);
  assert.equal(h.decorations().length, 0);
  assert.equal(toMarkdown(h.getState()), "Before.\n\n![[attachment:asset-1/pasted-image-1.png]]\n\n");
});

test("KnowledgePaste keeps in-flight upload alive across mid-upload plugin reconfiguration", async () => {
  const errors = [];
  const d = deferred();
  let capturedSignal;
  const h = createPluginHarness({
    upload: (_file, _name, signal) => {
      capturedSignal = signal;
      return d.promise;
    },
    onError: (title, desc) => errors.push({ title, desc }),
  });

  const file = new File([new Uint8Array([1, 2, 3])], "image.png", { type: "image/png" });
  h.paste(makeClipboard({ files: [file] }));
  assert.equal(h.decorations().length, 1);

  // Reconfiguring plugins mid-upload must not abort the request or drop completion.
  h.reconfigure();
  await Promise.resolve();
  assert.equal(capturedSignal.aborted, false);

  d.resolve({
    ref: "![[attachment:asset-2/pasted-image-1.png]]",
    kind: "file",
    title: "pasted-image-1.png",
    url: "/api/v1/knowledge/assets/asset-2",
    content_type: "image/png",
    available: true,
  });
  await new Promise((r) => setTimeout(r, 0));

  assert.deepEqual(errors, []);
  assert.equal(h.decorations().length, 0);
  assert.equal(toMarkdown(h.getState()), "Before.\n\n![[attachment:asset-2/pasted-image-1.png]]\n\n");
});

test("KnowledgePaste aborts in-flight uploads and ignores completion on real editor teardown", async () => {
  const d = deferred();
  let capturedSignal;
  const h = createPluginHarness({
    upload: (_file, _name, signal) => {
      capturedSignal = signal;
      return d.promise;
    },
    onError: () => {},
  });

  const file = new File([new Uint8Array([1, 2, 3])], "image.png", { type: "image/png" });
  h.paste(makeClipboard({ files: [file] }));
  const dispatchesBeforeTeardown = h.getDispatches();

  h.destroy();
  await Promise.resolve();
  assert.equal(capturedSignal.aborted, true);

  d.resolve({
    ref: "![[attachment:asset-3/pasted-image-1.png]]",
    kind: "file",
    title: "pasted-image-1.png",
    url: "/api/v1/knowledge/assets/asset-3",
    content_type: "image/png",
    available: true,
  });
  await new Promise((r) => setTimeout(r, 0));

  assert.equal(h.getDispatches(), dispatchesBeforeTeardown);
});

test("KnowledgePaste removes uploading placeholder and reports error when upload fails", async () => {
  const errors = [];
  const d = deferred();
  const h = createPluginHarness({
    upload: () => d.promise,
    onError: (title, desc) => errors.push({ title, desc }),
  });

  const file = new File([new Uint8Array([1, 2, 3])], "image.png", { type: "image/png" });
  h.paste(makeClipboard({ files: [file] }));
  assert.equal(h.decorations().length, 1);

  d.reject(new Error("storage unavailable"));
  await new Promise((r) => setTimeout(r, 0));

  assert.equal(h.decorations().length, 0);
  assert.deepEqual(errors, [{ title: "Couldn’t upload pasted-image-1.png", desc: "storage unavailable" }]);
  assert.equal(toMarkdown(h.getState()), "Before.");
});
