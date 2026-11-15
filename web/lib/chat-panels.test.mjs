import assert from "node:assert/strict";
import test from "node:test";
import { activePanel, closePanel, closeThread, codeFullscreen, dockOpen, dockTab, dragCloses, exitCodeFullscreen, hideSheet, openCodeFullscreen, openPanels, openThread, openThreads, setDock, sheetHidden, switchPanel, threadOf, closeItem, itemOf, linkedItems, openItem } from "./chat-panels.ts";

const D = "01a1bbdd-4937-7baa-af62-b3726025d331";
const C = "01a1bbdd-4937-7baa-af62-b3726025d332";
const q = (s) => new URLSearchParams(s);

test("nothing is open by default", () => {
  assert.deepEqual(openPanels(q(""), [D]), []);
  assert.equal(activePanel(q(""), []), undefined);
});

test("opening: a design focus, a fullscreen canvas and the playground each open their panel", () => {
  assert.deepEqual(openPanels(q(`canvas=${D}`), [D]), ["design"]);
  // A focus on a canvas that isn't a design expands its card in the chat, not a panel.
  assert.deepEqual(openPanels(q(`canvas=${C}`), [D]), []);
  assert.deepEqual(openPanels(q("canvas=none"), [D]), []);
  assert.deepEqual(openPanels(q(`canvas=${C}&canvas_view=full`), [D]), ["canvas"]);
  // A fullscreen design shows as the canvas, not beside the chat.
  assert.deepEqual(openPanels(q(`canvas=${D}&canvas_view=full`), [D]), ["canvas"]);
  assert.deepEqual(openPanels(q("playground=open"), []), ["playground"]);
  assert.deepEqual(openPanels(q("playground=full"), []), ["playground"]);
  assert.deepEqual(openPanels(q(`canvas=${D}&playground=open`), [D]), ["design", "playground"]);
});

test("switchPanel opens the panel it switches to", () => {
  const pg = switchPanel(q(""), "playground");
  assert.deepEqual(openPanels(pg, []), ["playground"]);
  assert.equal(activePanel(pg, openPanels(pg, [])), "playground");
  // Already full: stays full.
  assert.equal(switchPanel(q("playground=full"), "playground").get("playground"), "full");

  const cv = switchPanel(q(`canvas=${C}`), "canvas");
  assert.equal(cv.get("canvas_view"), "full");
  assert.equal(cv.get("canvas"), C);

  const ds = switchPanel(q("canvas_view=full"), "design", { designId: D });
  assert.deepEqual(openPanels(ds, [D]), ["design"]);
  // No design to open: nothing changes.
  assert.equal(switchPanel(q("a=1"), "design").toString(), "a=1");
});

test("switching between open panels changes which one the sheet shows", () => {
  let s = q(`canvas=${D}&playground=open`);
  assert.equal(activePanel(s, openPanels(s, [D])), "playground");
  s = switchPanel(s, "design", { designId: D });
  assert.deepEqual(openPanels(s, [D]), ["design", "playground"]);
  assert.equal(activePanel(s, openPanels(s, [D])), "design");
  s = switchPanel(s, "playground");
  assert.equal(activePanel(s, openPanels(s, [D])), "playground");
  // Switching to the canvas puts the design fullscreen.
  s = switchPanel(s, "canvas");
  assert.deepEqual(openPanels(s, [D]), ["canvas", "playground"]);
  assert.equal(activePanel(s, openPanels(s, [D])), "canvas");
});

test("activePanel falls back to the frontmost open panel when the one picked is closed", () => {
  assert.equal(activePanel(q("panel=design"), ["playground"]), "playground");
  assert.equal(activePanel(q(""), ["design", "canvas", "playground"]), "canvas");
  assert.equal(activePanel(q(""), ["design"]), "design");
});

test("closePanel closes only that panel", () => {
  let s = q(`canvas=${D}&playground=open&playground_tab=logs&panel=playground`);
  s = closePanel(s, "playground");
  assert.equal(s.get("playground"), null);
  assert.equal(s.get("playground_tab"), null);
  assert.equal(s.get("panel"), null);
  assert.deepEqual(openPanels(s, [D]), ["design"]);
  s = closePanel(s, "design");
  assert.equal(s.get("canvas"), "none");
  assert.deepEqual(openPanels(s, [D]), []);

  const full = closePanel(q(`canvas=${C}&canvas_view=full&panel=design`), "canvas");
  assert.equal(full.get("canvas_view"), null);
  assert.equal(full.get("canvas"), C);
  // A pick of another panel survives.
  assert.equal(full.get("panel"), "design");
});

test("a drag down closes the sheet past a quarter of its height, or as a quick flick", () => {
  assert.equal(dragCloses(100, 1000, 800), false);
  assert.equal(dragCloses(200, 1000, 800), true);
  // At least 120px on a short sheet.
  assert.equal(dragCloses(100, 1000, 300), false);
  assert.equal(dragCloses(130, 1000, 300), true);
  assert.equal(dragCloses(60, 80, 800), true);
  assert.equal(dragCloses(30, 10, 800), false);
  assert.equal(dragCloses(-200, 10, 800), false);
});

test("the Comments count leaves out resolved threads", () => {
  assert.equal(openThreads(undefined), 0);
  assert.equal(openThreads([{ status: "open" }, { status: "draft" }, { status: "addressed" }, { status: "resolved" }, { status: "open", parent_id: "x" }]), 3);
});

test("a dismissed sheet stays dismissed until a switch shows it again", () => {
  const hidden = hideSheet(q(`playground=open&panel=playground`));
  assert.equal(sheetHidden(hidden), true);
  // The panels stay open behind it.
  assert.deepEqual(openPanels(hidden, []), ["playground"]);
  const shown = switchPanel(hidden, "playground");
  assert.equal(sheetHidden(shown), false);
  assert.equal(shown.get("playground"), "open");
});

test("a maximised canvas is still the open canvas panel", () => {
  assert.deepEqual(openPanels(q(`canvas=${C}&canvas_view=max`), [D]), ["canvas"]);
  assert.equal(closePanel(q(`canvas=${C}&canvas_view=max`), "canvas").get("canvas_view"), null);
});

test("dock: Activity is the tab when nothing is open, and the dock starts on its rail", () => {
  assert.equal(dockTab(q(""), []), "activity");
  assert.equal(dockOpen(q(""), []), false);
  assert.equal(dockOpen(q("panel=activity"), []), true);
});

test("dock: an open panel opens the dock on it, unless the person collapsed it", () => {
  const open = openPanels(q(`canvas=${D}`), [D]);
  assert.equal(dockTab(q(`canvas=${D}`), open), "design");
  assert.equal(dockOpen(q(`canvas=${D}`), open), true);
  assert.equal(dockOpen(q(`canvas=${D}&dock=0`), open), false);
  // A picked panel that has since closed falls back to the frontmost open one.
  assert.equal(dockTab(q(`canvas=${D}&panel=playground`), open), "design");
  assert.equal(dockTab(q(`canvas=${D}&panel=activity`), open), "activity");
});

test("dock: setDock writes the tab and open state, keeping the panels", () => {
  const next = setDock(q(`canvas=${D}&playground=open`), { tab: "activity", open: false });
  assert.equal(next.get("panel"), "activity");
  assert.equal(next.get("dock"), "0");
  assert.deepEqual(openPanels(next, [D]), ["design", "playground"]);
  assert.equal(dockTab(next, openPanels(next, [D])), "activity");
  assert.equal(dockOpen(next, []), false);
  assert.equal(dockOpen(setDock(next, { tab: "design", open: true }), []), true);
});

test("dock: a thread opens the dock on its tab, keeps the panels, and closing it falls back", () => {
  const M = "99999999-9999-4999-8999-999999999999";
  const next = openThread(q(`canvas=${D}`), M);
  assert.equal(threadOf(next), M);
  assert.equal(dockTab(next, openPanels(next, [D])), "thread");
  assert.equal(dockOpen(next, []), true);
  // Without a message there is no thread to show.
  assert.equal(dockTab(q("panel=thread"), []), "activity");
  const closed = closeThread(next);
  assert.equal(threadOf(closed), undefined);
  assert.equal(dockTab(closed, openPanels(closed, [D])), "design");
});

const RUN = "11111111-1111-4111-8111-111111111111";
const PAGE = "55555555-5555-4555-8555-555555555555";

test("a linked item opens beside the chat in the dock, survives in the URL, and closes back to the other tabs", () => {
  const q = openItem(new URLSearchParams("canvas=none"), { kind: "ticket", key: "WEB-42" });
  assert.equal(q.get("item"), "ticket:WEB-42");
  assert.deepEqual(itemOf(q), { kind: "ticket", key: "WEB-42" });
  assert.equal(dockTab(q, []), "item");
  assert.equal(dockOpen(q, []), true);
  const closed = closeItem(q);
  assert.equal(itemOf(closed), undefined);
  assert.equal(dockTab(closed, []), "activity");
  assert.deepEqual(itemOf(openItem(new URLSearchParams(), { kind: "run", id: RUN })), { kind: "run", id: RUN });
});

test("only well-formed items open", () => {
  for (const bad of ["ticket:web-1", "run:nope", "page:", "canvas:" + RUN, "WEB-1"]) assert.equal(itemOf(new URLSearchParams({ item: bad })), undefined, bad);
});

test("a chat's linked items: its context tickets and pages, newest first, then its runs, each once", () => {
  const refs = [{ kind: "ticket", key: "WEB-1" }, { kind: "page", id: PAGE }, { kind: "artifact", id: "a" }, { kind: "ticket", key: "WEB-1" }, { kind: "ticket", key: "WEB-2" }];
  assert.deepEqual(linkedItems(refs, [{ run_id: RUN }, { run_id: RUN }]), [
    { kind: "ticket", key: "WEB-2" },
    { kind: "ticket", key: "WEB-1" },
    { kind: "page", id: PAGE },
    { kind: "run", id: RUN },
  ]);
});

test("the Code panel opens and closes with its own param", () => {
  const q = switchPanel(new URLSearchParams("dock=1"), "code");
  assert.equal(q.get("code"), "open");
  assert.deepEqual(openPanels(q, []), ["code"]);
  assert.equal(activePanel(q, ["code"]), "code");
  const closed = closePanel(q, "code");
  assert.equal(closed.get("code"), null);
  assert.deepEqual(openPanels(closed, []), []);
});

test("code=full opens fullscreen, preserves full on switchPanel, and restores docked open on exit", () => {
  const open = new URLSearchParams("code=open&panel=code&dock=1");
  assert.equal(codeFullscreen(open), false);

  const full = openCodeFullscreen(open);
  assert.equal(full.get("code"), "full");
  assert.equal(full.get("panel"), "code");
  assert.equal(codeFullscreen(full), true);
  assert.deepEqual(openPanels(full, []), ["code"]);
  assert.equal(switchPanel(full, "code").get("code"), "full");

  const exited = exitCodeFullscreen(full);
  assert.equal(exited.get("code"), "open");
  assert.equal(codeFullscreen(exited), false);
  assert.deepEqual(openPanels(exited, []), ["code"]);
});
