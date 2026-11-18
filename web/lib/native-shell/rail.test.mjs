import test from "node:test";
import assert from "node:assert/strict";
import { buildRailModel, createDockRailStore, dockRailAction, dockRailItems, railEffect } from "./models/rail.ts";
import { isPageMessage } from "./protocol.ts";

const tabs = [
  { id: "facts", label: "Facts", icon: "doc" },
  { id: "chat", label: "Chat", icon: "msg", busy: true, unread: true },
];
const review = { configured: true, requests: [], approved: 0, prefs: { direct: true, team: true }, counts: { direct: 0, team: 0 } };
const base = { dock: [], pathname: "/work", review, needsYou: 0, harnesses: [], devWorkspace: false, settingsNeedYou: false };

test("a dock's rail items: fold control, then a tab each, the open one active", () => {
  const items = dockRailItems(tabs, "chat", true);
  assert.deepEqual(items.map((i) => [i.id, i.active]), [["dock.toggle", true], ["dock.tab:facts", false], ["dock.tab:chat", true]]);
  assert.equal(items[0].label, "Collapse panel");
  assert.deepEqual(items[2].badge, { tone: "human" });
  assert.equal(items[2].status, "accent");
  assert.match(items[2].label, /working/);
  const folded = dockRailItems(tabs, "chat", false);
  assert.equal(folded[0].label, "Expand panel");
  assert.ok(folded.every((i) => !i.active));
  assert.deepEqual(dockRailItems([], undefined, true), []);
});

test("dock rail actions match the web buttons", () => {
  assert.deepEqual(dockRailAction("dock.toggle", tabs, "chat", true), { type: "collapse" });
  assert.deepEqual(dockRailAction("dock.toggle", tabs, "chat", false), { type: "open", tab: "chat" });
  assert.deepEqual(dockRailAction("dock.tab:facts", tabs, "chat", true), { type: "select", tab: "facts" });
  assert.deepEqual(dockRailAction("dock.tab:facts", tabs, "chat", false), { type: "open", tab: "facts" });
  assert.equal(dockRailAction("dock.tab:nope", tabs, "chat", true), null);
  assert.equal(dockRailAction("settings", tabs, "chat", true), null);
});

test("the foot: links, current page active, Settings carries the attention dot", () => {
  const m = buildRailModel({ ...base, pathname: "/settings/runner", settingsNeedYou: true, devWorkspace: true });
  assert.deepEqual(m.foot.map((i) => i.id), ["http", "dev", "customization", "settings"]);
  const settings = m.foot.at(-1);
  assert.equal(settings.active, true);
  assert.deepEqual(settings.badge, { tone: "human" });
  assert.ok(m.foot.slice(0, 3).every((i) => !i.active));
  assert.deepEqual(buildRailModel(base).foot.map((i) => i.id), ["http", "customization", "settings"]);
  const onHttp = buildRailModel({ ...base, pathname: "/http" }).foot[0];
  assert.equal(onHttp.active, true);
  assert.equal(onHttp.label, "Return to previous page");
});

test("Needs you carries its kind and a count badge", () => {
  const m = buildRailModel({ ...base, needsYou: 120 });
  const item = m.middle.find((i) => i.id === "needsYou");
  assert.equal(item.kind, "needsYou");
  assert.deepEqual(item.badge, { text: "99+", tone: "human" });
  assert.equal(buildRailModel(base).middle.find((i) => i.id === "needsYou").badge, undefined);
});

test("PR review requests: count badge and a menu of the PRs", () => {
  const requests = [{ id: "a", number: 7, title: "Fix the thing", repository: "o/r" }];
  const m = buildRailModel({ ...base, review: { ...review, requests, counts: { direct: 1, team: 0 } } });
  const pr = m.middle[0];
  assert.deepEqual(pr.badge, { text: "1", tone: "accent" });
  assert.equal(pr.menu[0].id, "pr:a");
  assert.ok(pr.menu.some((x) => x.id === "pr.refresh"));
  assert.equal(pr.menu.find((x) => x.id === "pr.direct").checked, true);
  const approved = buildRailModel({ ...base, review: { ...review, approved: 2 } }).middle[0];
  assert.deepEqual(approved.badge, { text: "2", tone: "done" });
  const unconfigured = buildRailModel({ ...base, review: { ...review, configured: false } }).middle[0];
  assert.equal(unconfigured.badge, undefined);
  assert.deepEqual(unconfigured.menu.map((x) => x.id), ["pr.setup"]);
});

test("harnesses: avatar, status tone and a usage menu", () => {
  const h = (state) => ({ harness: "codex", label: "Codex", initials: "CX", color: "#B09AEF", state, lines: ["42% allowance used"] });
  const [working] = buildRailModel({ ...base, harnesses: [h("working")] }).middle.slice(2);
  assert.equal(working.id, "harness:codex");
  assert.equal(working.status, "done");
  assert.deepEqual(working.avatar, { initials: "CX", color: "#B09AEF" });
  assert.ok(working.menu.at(-1).id === "usage");
  assert.equal(buildRailModel({ ...base, harnesses: [h("limited")] }).middle[2].status, "warning");
  assert.equal(buildRailModel({ ...base, harnesses: [h("idle")] }).middle[2].status, undefined);
  assert.equal(buildRailModel({ ...base, harnesses: null }).middle.length, 2);
});

test("rail.action resolves to the web's own actions", () => {
  const ctx = { reviewUrl: (id) => (id === "a" ? "https://github.com/o/r/pull/7" : undefined) };
  assert.deepEqual(railEffect("dock.tab:chat", undefined, ctx), { type: "dock", itemId: "dock.tab:chat" });
  assert.deepEqual(railEffect("http", undefined, ctx), { type: "toggle", path: "/http" });
  assert.deepEqual(railEffect("settings", undefined, ctx), { type: "navigate", path: "/settings" });
  assert.deepEqual(railEffect("pr", "pr:a", ctx), { type: "open", url: "https://github.com/o/r/pull/7" });
  assert.equal(railEffect("pr", "pr:zzz", ctx), null);
  assert.deepEqual(railEffect("pr", "pr.team", ctx), { type: "reviewPrefs", key: "team" });
  assert.deepEqual(railEffect("harness:codex", "usage", ctx), { type: "navigate", path: "/settings/runner" });
  assert.equal(railEffect("nope", undefined, ctx), null);
});

test("the rail is a valid page message", () => {
  assert.ok(isPageMessage({ v: 1, type: "rail", model: buildRailModel(base) }));
});

test("the dock store: the latest registration wins, clearing falls back", () => {
  const store = createDockRailStore();
  let changes = 0;
  store.subscribe(() => changes++);
  const a = Symbol("a"), b = Symbol("b");
  const seen = [];
  store.set(a, [{ id: "dock.toggle", label: "A" }], (id) => seen.push(["a", id]));
  store.set(b, [{ id: "dock.toggle", label: "B" }], (id) => seen.push(["b", id]));
  assert.equal(store.items()[0].label, "B");
  assert.ok(store.act("dock.toggle"));
  assert.deepEqual(seen, [["b", "dock.toggle"]]);
  const before = store.items();
  store.set(b, [{ id: "dock.toggle", label: "B" }], () => {});
  assert.equal(store.items(), before, "an equal model keeps the same snapshot");
  store.clear(b);
  assert.equal(store.items()[0].label, "A");
  store.clear(a);
  assert.deepEqual(store.items(), []);
  assert.equal(store.act("x"), false);
  assert.ok(changes >= 3);
});
