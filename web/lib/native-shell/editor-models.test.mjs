import test from "node:test";
import assert from "node:assert/strict";
import { splitActions } from "./actions.ts";
import { findNavItem } from "./nav-model.ts";
import { editorStatusActions, presenceLabel } from "./models/editor-header.ts";
import { buildDocActions, buildDocOutlineNav, outlineItems, parseHeadingId } from "./models/doc-editor.ts";
import { buildDeckActions, buildDeckNav, parseDeckCommand } from "./models/deck-editor.ts";
import { buildDesignActions, buildDesignNav, buildDesignTitleMenu, parseDesignCommand } from "./models/design-editor.ts";
import { buildCustomAppActions, buildCustomAppNav, parseViewId } from "./models/custom-app.ts";
import { buildArtifactActions, buildMockupEditActions } from "./models/mockup-editor.ts";

const ids = (items) => items.map((i) => i.id);

test("save state and presence lead the toolbar; a failed save can be retried", () => {
  const calls = [];
  const a = editorStatusActions({ save: { state: "saved", seq: 4 }, presence: { label: "Ada can edit" } });
  assert.deepEqual(a.map((x) => [x.id, x.label, x.placement, x.disabled]), [
    ["editor.save", "Saved · v4", "leading", true],
    ["editor.presence", "Ada can edit", "leading", true],
  ]);
  const failed = editorStatusActions({ save: { state: "error", seq: 4 }, retry: () => calls.push("retry") });
  assert.equal(failed[0].label, "Not saved · v4 · Retry");
  assert.equal(failed[0].accent, true);
  const { dispatch } = splitActions(failed);
  dispatch("editor.save");
  assert.deepEqual(calls, ["retry"]);
  // A conflict isn't retried from the toolbar: the page's banner decides.
  assert.equal(editorStatusActions({ save: { state: "conflict" }, retry: () => {} })[0].disabled, true);
  assert.equal(editorStatusActions({ review: { count: 3, label: "Review", run: () => calls.push("review") } })[0].label, "Review 3");
  assert.equal(presenceLabel("Ada", true, false), "Ada is editing…");
  assert.equal(presenceLabel("Ada", false, true), "Ada suggested changes");
  assert.equal(presenceLabel("Ada", false, false), "Ada can edit");
});

test("the doc outline nests headings by level", () => {
  const items = outlineItems([
    { level: 1, text: "Intro" },
    { level: 2, text: "Why" },
    { level: 3, text: "Deep" },
    { level: 2, text: "How" },
    { level: 1, text: "End" },
  ]);
  assert.deepEqual(items.map((i) => i.title), ["Intro", "End"]);
  assert.deepEqual(items[0].children.map((i) => i.title), ["Why", "How"]);
  assert.equal(items[0].children[0].children[0].id, "h:2");
  assert.equal(items[0].expanded, true);
  assert.equal(items[1].children, undefined);
  // A document that starts below its top level still lists every heading.
  assert.equal(outlineItems([{ level: 3, text: "a" }, { level: 2, text: "b" }]).length, 2);
  assert.equal(parseHeadingId("h:12"), 12);
  assert.equal(parseHeadingId("x:1"), null);
  const nav = buildDocOutlineNav({ outline: [] });
  assert.equal(nav.sections[0].emptyText, "No headings yet.");
  assert.equal(findNavItem(buildDocOutlineNav({ outline: [{ level: 1, text: "A" }] }), "h:0").title, "A");
});

test("the doc's Share menu runs the export it names", () => {
  const calls = [];
  const h = (n) => () => calls.push(n);
  const input = { canShare: true, pdf: h("pdf"), word: h("word"), markdown: h("md"), copy: h("copy"), saveToLibrary: h("lib"), promote: h("wiki"), save: { state: "saved", seq: 2 } };
  const { items, dispatch } = splitActions(buildDocActions(input));
  assert.deepEqual(ids(items), ["editor.save", "doc.share"]);
  for (const m of ["pdf", "word", "markdown", "copy", "library", "promote"]) dispatch("doc.share", m);
  assert.deepEqual(calls, ["pdf", "word", "md", "copy", "lib", "wiki"]);
  assert.deepEqual(ids(buildDocActions({ ...input, canShare: false })), ["editor.save"]);
  const busy = buildDocActions({ ...input, libraryPending: true })[1].menu.find((m) => m.id === "library");
  assert.equal(busy.disabled, true);
});

const slides = [
  { id: "a", title: "Welcome" },
  { id: "b", title: "Plan", hidden: true },
  { id: "c", title: "Untitled slide" },
];
const layouts = [{ id: "title", label: "Title" }, { id: "section", label: "Section" }];

test("deck rows: numbered titles, selection, badges and a move menu that respects the ends", () => {
  const nav = buildDeckNav({ slides, currentId: "b", layouts, overflowing: new Set(["c"]), changed: new Set(["a"]), persona: "Ada", readOnly: false });
  const rows = nav.sections[0].items;
  assert.deepEqual(rows.map((r) => r.title), ["1. Welcome", "2. Plan", "3. Untitled slide"]);
  assert.equal(nav.selectedId, "slide:b");
  assert.equal(rows[1].trailing, "Hidden");
  assert.equal(rows[2].status, "warning");
  assert.deepEqual(rows[0].badge, { text: "Ada", tone: "human" });
  const menu = (r) => Object.fromEntries(r.contextMenu.filter((m) => !m.separator).map((m) => [m.id, !!m.disabled]));
  assert.deepEqual(menu(rows[0]), { up: true, down: false, top: true, bottom: false, duplicate: false, delete: false });
  assert.deepEqual(menu(rows[2]), { up: false, down: true, top: false, bottom: true, duplicate: false, delete: false });
  assert.equal(nav.sections[0].badge.text, "3");
  const add = nav.sections[0].actions[0];
  assert.deepEqual(add.menu.map((m) => m.id), ["add:same", "s1", "add:layout:title", "add:layout:section"]);
});

test("a read-only or single-slide deck can't be changed from the sidebar", () => {
  const ro = buildDeckNav({ slides, currentId: "a", layouts, persona: "Ada", readOnly: true });
  assert.equal(ro.sections[0].actions[0].disabled, true);
  assert.ok(ro.sections[0].items.every((r) => r.contextMenu.filter((m) => !m.separator).every((m) => m.disabled)));
  const one = buildDeckNav({ slides: [slides[0]], currentId: "a", layouts, persona: "Ada", readOnly: false });
  assert.equal(one.sections[0].items[0].contextMenu.find((m) => m.id === "delete").disabled, true);
});

test("deck commands become the thumbnail handlers' calls", () => {
  const p = (cmd) => parseDeckCommand(cmd, slides);
  assert.deepEqual(p({ type: "nav.activate", itemId: "slide:c" }), { type: "select", id: "c" });
  assert.deepEqual(p({ type: "nav.action", actionId: "add-slide", menuItemId: "add:same" }), { type: "add" });
  assert.deepEqual(p({ type: "nav.action", actionId: "add-slide", menuItemId: "add:layout:section" }), { type: "add", layout: "section" });
  const row = (menuItemId, id = "b") => p({ type: "nav.action", actionId: "row", itemId: `slide:${id}`, menuItemId });
  assert.deepEqual(row("up"), { type: "move", id: "b", to: 0 });
  assert.deepEqual(row("down"), { type: "move", id: "b", to: 2 });
  assert.deepEqual(row("top"), { type: "move", id: "b", to: 0 });
  assert.deepEqual(row("bottom"), { type: "move", id: "b", to: 2 });
  assert.equal(row("up", "a"), null);
  assert.equal(row("down", "c"), null);
  assert.deepEqual(row("duplicate"), { type: "duplicate", id: "b" });
  assert.deepEqual(row("delete"), { type: "remove", id: "b" });
  assert.equal(parseDeckCommand({ type: "nav.action", actionId: "row", itemId: "slide:a", menuItemId: "delete" }, [slides[0]]), null);
  assert.equal(row("nope"), null);
  assert.equal(p({ type: "nav.activate", itemId: "other" }), null);
  assert.equal(p({ type: "nav.toggle", itemId: "slide:a" }), null);
});

test("deck toolbar: Present and Share, Share off while an export builds", () => {
  const calls = [];
  const share = { pdf: () => calls.push("pdf"), pptx: () => calls.push("pptx"), pdfToLibrary: () => calls.push("pdf-lib"), pptxToLibrary: () => calls.push("pptx-lib"), busy: false };
  const { items, dispatch } = splitActions(buildDeckActions({ save: { state: "unsaved", seq: 1 }, canPresent: true, present: () => calls.push("present"), share }));
  assert.deepEqual(ids(items), ["editor.save", "deck.present", "deck.share"]);
  dispatch("deck.present");
  for (const m of ["pdf", "pptx", "pdf-library", "pptx-library"]) dispatch("deck.share", m);
  dispatch("deck.share", "export");
  assert.deepEqual(calls, ["present", "pdf", "pptx", "pdf-lib", "pptx-lib"]);
  assert.equal(buildDeckActions({ canPresent: false, present() {}, share: { ...share, busy: true } }).find((x) => x.id === "deck.share").disabled, true);
  assert.equal(buildDeckActions({ canPresent: false, present() {} }).find((x) => x.id === "deck.present").disabled, true);
  assert.equal(buildDeckActions({ canPresent: true, present() {} }).some((x) => x.id === "deck.share"), false);
});

const layer = (id, label, o = {}) => ({ id, label, type: "frame", visible: true, locked: false, togglable: true, children: [], ...o });
const design = (o = {}) => ({
  title: "Landing",
  pages: [{ id: "p1", name: "Page 1" }, { id: "p2", name: "Page 2" }],
  currentPageId: "p1",
  // Paint order: the last child is on top.
  layers: [layer("bg", "Background"), layer("card", "Card", { children: [layer("t", "Title", { type: "text" }), layer("c", "Link", { type: "connector", togglable: false })] })],
  selected: [],
  open: new Set(),
  readOnly: false,
  ...o,
});

test("design nav: pages, then layers topmost first with nested children and expanded state", () => {
  const nav = buildDesignNav(design({ open: new Set(["card"]), selected: ["t", "bg"] }));
  assert.deepEqual(nav.sections.map((s) => s.id), ["pages", "layers"]);
  assert.deepEqual(nav.sections[0].items.map((p) => p.title), ["Page 1", "Page 2"]);
  const layers = nav.sections[1].items;
  assert.deepEqual(layers.map((l) => l.title), ["Card", "Background"]);
  assert.equal(layers[0].expanded, true);
  assert.deepEqual(layers[0].children.map((l) => l.id), ["layer:c", "layer:t"]);
  assert.equal(layers[1].children, undefined);
  assert.equal(nav.selectedId, "layer:t");
  assert.equal(buildDesignNav(design()).selectedId, "page:p1");
  assert.equal(buildDesignNav(design()).sections[1].items[0].expanded, false);
});

test("design rows: connectors have no hide or lock; state shows in the menu and row", () => {
  const nav = buildDesignNav(design({ layers: [layer("a", "A", { visible: false, locked: true }), layer("k", "K", { type: "connector", togglable: false })] }));
  const [k, a] = nav.sections[1].items;
  assert.deepEqual(a.contextMenu.map((m) => m.label), ["Rename…", "Show", "Unlock"]);
  assert.equal(a.trailing, "Locked");
  assert.equal(a.subtitle, "Hidden");
  assert.deepEqual(k.contextMenu.map((m) => m.id), ["rename"]);
  const ro = buildDesignNav(design({ readOnly: true }));
  assert.equal(ro.sections[0].actions[0].disabled, true);
  assert.ok(ro.sections[1].items[0].contextMenu.every((m) => m.disabled));
  // The last page can't be deleted.
  const one = buildDesignNav(design({ pages: [{ id: "p1", name: "Only" }] }));
  assert.equal(one.sections[0].items[0].contextMenu.find((m) => m.id === "delete").disabled, true);
});

test("design commands", () => {
  assert.deepEqual(parseDesignCommand({ type: "nav.activate", itemId: "page:p2" }), { type: "page", id: "p2" });
  assert.deepEqual(parseDesignCommand({ type: "nav.activate", itemId: "layer:x" }), { type: "select", id: "x" });
  assert.deepEqual(parseDesignCommand({ type: "nav.toggle", itemId: "layer:x", expanded: true }), { type: "toggle", id: "x", expanded: true });
  assert.deepEqual(parseDesignCommand({ type: "nav.action", actionId: "add-page" }), { type: "addPage" });
  const row = (itemId, menuItemId) => parseDesignCommand({ type: "nav.action", actionId: "row", itemId, menuItemId });
  assert.deepEqual(row("page:p1", "rename"), { type: "renamePage", id: "p1" });
  assert.deepEqual(row("page:p1", "delete"), { type: "removePage", id: "p1" });
  assert.deepEqual(row("layer:x", "rename"), { type: "renameLayer", id: "x" });
  assert.deepEqual(row("layer:x", "toggle-visible"), { type: "toggleVisible", id: "x" });
  assert.deepEqual(row("layer:x", "toggle-lock"), { type: "toggleLock", id: "x" });
  assert.equal(row("layer:x", "nope"), null);
  assert.equal(row("elsewhere", "rename"), null);
  assert.equal(parseDesignCommand({ type: "nav.toggle", itemId: "page:p1", expanded: true }), null);
});

test("design toolbar: Present, a Share menu with scope, download and library entries, and the Review pill", () => {
  const calls = [];
  const share = {
    scopes: [{ id: "selection", label: "Selection", disabled: true }, { id: "page", label: "Page: One" }],
    scope: "page",
    busy: false,
    pick: (s) => calls.push(`pick:${s}`),
    download: (f, n) => calls.push(`dl:${f}:${n}`),
    toLibrary: (f, n) => calls.push(`lib:${f}:${n}`),
  };
  const actions = buildDesignActions({ save: { state: "saved", seq: 3 }, review: { count: 2, label: "Review", run: () => calls.push("review") }, canPresent: true, present: () => calls.push("present"), share });
  const { items, dispatch } = splitActions(actions);
  assert.deepEqual(ids(items), ["editor.save", "editor.review", "design.present", "design.share"]);
  dispatch("editor.review");
  dispatch("design.present");
  dispatch("design.share", "scope:page");
  dispatch("design.share", "scope:selection");
  dispatch("design.share", "download:png2");
  dispatch("design.share", "library:pdf");
  assert.deepEqual(calls, ["review", "present", "pick:page", "dl:png:2", "lib:pdf:1"]);
  const what = items.find((i) => i.id === "design.share").menu[0].children;
  assert.deepEqual(what.map((m) => [m.id, m.checked, !!m.disabled]), [["scope:selection", false, true], ["scope:page", true, false]]);
  const t = splitActions([{ id: "title", label: "", kind: "menu", menu: buildDesignTitleMenu({ duplicating: true, rename: () => calls.push("rename"), duplicate: () => calls.push("dup") }) }]);
  t.dispatch("title", "rename");
  t.dispatch("title", "duplicate");
  assert.deepEqual(calls.slice(-1), ["rename"]);
});

test("custom app: views as rows, reload and permissions as buttons", () => {
  const nav = buildCustomAppNav({ title: "CRM", items: [{ id: "home", label: "Home", icon: "dashboard" }, { id: "x", label: "Reports" }], currentId: "x" });
  assert.deepEqual(nav.sections[0].items, [{ id: "view:home", title: "Home", icon: "dashboard" }, { id: "view:x", title: "Reports" }]);
  assert.equal(nav.selectedId, "view:x");
  assert.equal(buildCustomAppNav({ items: [] }).selectedId, null);
  assert.equal(parseViewId("view:home"), "home");
  assert.equal(parseViewId("home"), null);
  const calls = [];
  const { dispatch, items } = splitActions(buildCustomAppActions({ reload: () => calls.push("r"), permissions: () => calls.push("p") }));
  dispatch("app.reload");
  dispatch("app.permissions");
  assert.deepEqual(calls, ["r", "p"]);
  assert.equal(items[0].showsLabel, undefined);
});

test("artifact page toolbar: Review and Edit only for mockups; PDF only for markdown", () => {
  const base = { review() {}, edit() {}, startChat: { disabled: false, run() {} }, download() {}, exportPdf() {}, newVersion() {} };
  assert.deepEqual(ids(buildArtifactActions({ ...base, isMockup: true, canExportPdf: false })), ["artifact.review", "artifact.edit", "artifact.chat", "artifact.download", "artifact.version"]);
  assert.deepEqual(ids(buildArtifactActions({ ...base, isMockup: false, canExportPdf: true })), ["artifact.chat", "artifact.download", "artifact.pdf", "artifact.version"]);
  assert.equal(buildArtifactActions({ ...base, startChat: { disabled: true, run() {} }, isMockup: false, canExportPdf: false })[0].disabled, true);
});

test("mockup editor toolbar: the mode menu checks the current mode; saving needs a change", () => {
  const calls = [];
  const modes = [{ value: "visual", label: "Visual" }, { value: "source", label: "Source" }, { value: "split", label: "Split" }];
  const input = { mode: "source", modes, setMode: (m) => calls.push(m), canSave: false, cancel: () => calls.push("cancel"), saveVersion: () => calls.push("save"), saveAndApprove: () => calls.push("approve") };
  const { items, dispatch } = splitActions(buildMockupEditActions(input));
  assert.equal(items[0].label, "Editor: Source");
  assert.deepEqual(items[0].menu.map((m) => m.checked), [false, true, false]);
  dispatch("mockup.mode", "mode:split");
  dispatch("mockup.cancel");
  dispatch("mockup.save");
  dispatch("mockup.approve");
  assert.deepEqual(calls, ["split", "cancel"]);
  const ok = splitActions(buildMockupEditActions({ ...input, canSave: true }));
  ok.dispatch("mockup.save");
  ok.dispatch("mockup.approve");
  assert.deepEqual(calls.slice(-2), ["save", "approve"]);
});
