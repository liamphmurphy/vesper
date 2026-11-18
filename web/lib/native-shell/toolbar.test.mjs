import test, { beforeEach } from "node:test";
import assert from "node:assert/strict";
import { resetDedupe } from "./bridge.ts";
import { menuIds, setToolbarItems } from "./toolbar.ts";
import { setTitleMenu, setTopBarTitle } from "./title.ts";

let posted;
beforeEach(() => {
  posted = [];
  const win = new EventTarget();
  win.__VESPER_NATIVE__ = { v: 1, platform: "macos" };
  win.webkit = { messageHandlers: { vesper: { postMessage: (m) => posted.push(m) } } };
  globalThis.window = win;
  globalThis.document = { title: "Plan · Vesper" };
  resetDedupe();
});

const item = (id) => ({ id, label: id, kind: "button" });

test("sources merge in order and each clears only its own items", () => {
  const a = Symbol("a");
  const b = Symbol("b");
  setToolbarItems(a, [item("one")]);
  setToolbarItems(b, [item("two")]);
  assert.deepEqual(posted.at(-1).items.map((i) => i.id), ["one", "two"]);
  setToolbarItems(a, null);
  assert.deepEqual(posted.at(-1).items.map((i) => i.id), ["two"]);
  setToolbarItems(b, null);
  assert.deepEqual(posted.at(-1).items, []);
});

test("an unchanged toolbar is not posted twice", () => {
  const a = Symbol("a");
  setToolbarItems(a, [item("one")]);
  setToolbarItems(a, [item("one")]);
  assert.equal(posted.length, 1);
  setToolbarItems(a, null);
});

test("the title message carries the menu, next to the one title", () => {
  const t = Symbol("t");
  setTitleMenu(t, [{ id: "rename", label: "Rename…" }]);
  assert.deepEqual(posted.at(-1), { v: 1, type: "title", title: "Plan", menu: [{ id: "rename", label: "Rename…" }] });
  const bar = Symbol("bar");
  setTopBarTitle(bar, { title: "Crumb" });
  assert.equal(posted.at(-1).title, "Crumb");
  assert.equal(posted.at(-1).menu.length, 1);
  setTitleMenu(t, null);
  setTopBarTitle(bar, null);
  assert.deepEqual(posted.at(-1), { v: 1, type: "title", title: "Plan" });
});

test("menuIds walks submenus and skips separators", () => {
  const ids = menuIds([{ id: "a", label: "A" }, { id: "s", separator: true }, { id: "b", children: [{ id: "c" }] }]);
  assert.deepEqual([...ids].sort(), ["a", "b", "c"]);
});
