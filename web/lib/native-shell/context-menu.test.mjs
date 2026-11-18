import test from "node:test";
import assert from "node:assert/strict";
import { keepsSystemMenu, splitMenu } from "./context-menu.ts";

test("splitMenu keeps handlers out of the protocol items and indexes them by id", () => {
  const calls = [];
  const { items, handlers } = splitMenu([
    { id: "open", label: "Open", onSelect: () => calls.push("open") },
    { id: "move", label: "Move to", children: [{ id: "move:done", label: "Done", checked: true, onSelect: () => calls.push("done") }] },
  ]);
  assert.deepEqual(items, [
    { id: "open", label: "Open" },
    { id: "move", label: "Move to", children: [{ id: "move:done", label: "Done", checked: true }] },
  ]);
  handlers.get("open")();
  handlers.get("move:done")();
  assert.deepEqual(calls, ["open", "done"]);
  assert.equal(handlers.has("move"), false);
});

test("splitMenu drops separators at the ends, doubled ones and empty submenus", () => {
  const { items } = splitMenu([
    { id: "s0", separator: true },
    { id: "a", label: "A" },
    { id: "s1", separator: true },
    { id: "s2", separator: true },
    { id: "empty", label: "Empty", children: [] },
    { id: "b", label: "B" },
    { id: "s3", separator: true },
  ]);
  assert.deepEqual(items.map((i) => i.id), ["a", "s1", "b"]);
});

const at = (...matches) => ({ closest: (sel) => (matches.some((m) => sel.includes(m)) ? {} : null) });

test("keepsSystemMenu leaves fields, editable text and selections to the system menu", () => {
  const opts = { selectionInside: false, links: "system" };
  assert.equal(keepsSystemMenu(at("textarea"), opts), true);
  assert.equal(keepsSystemMenu(at('[contenteditable="true"]'), opts), true);
  assert.equal(keepsSystemMenu(at(), { ...opts, selectionInside: true }), true);
  assert.equal(keepsSystemMenu(at(), opts), false);
  assert.equal(keepsSystemMenu(null, opts), false);
});

test("keepsSystemMenu gives links to the system unless the caller's menu covers them", () => {
  assert.equal(keepsSystemMenu(at("a[href]"), { selectionInside: false, links: "system" }), true);
  assert.equal(keepsSystemMenu(at("a[href]"), { selectionInside: false, links: "menu" }), false);
});
