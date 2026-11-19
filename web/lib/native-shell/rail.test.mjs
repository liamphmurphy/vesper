import test from "node:test";
import assert from "node:assert/strict";
import { buildRailModel, createDockRailStore, dockRailAction, dockRailItems, harnessRailInputs, railEffect } from "./models/rail.ts";
import { isPageMessage } from "./protocol.ts";

const tabs = [
  { id: "facts", label: "Facts", icon: "doc" },
  { id: "chat", label: "Chat", icon: "msg", busy: true, unread: true },
];
const review = { configured: true, requests: [], approved: 0, prefs: { direct: true, team: true }, counts: { direct: 0, team: 0 } };
const base = { dock: [], pathname: "/work", review, needsYou: 0, harnesses: [], settingsNeedYou: false };

test("a dock's rail items: a tab each, the open one active, no fold control (the toolbar's)", () => {
  const items = dockRailItems(tabs, "chat", true);
  assert.deepEqual(items.map((i) => [i.id, i.active]), [["dock.tab:facts", false], ["dock.tab:chat", true]]);
  assert.deepEqual(items[1].badge, { tone: "human" });
  assert.equal(items[1].status, "accent");
  assert.match(items[1].label, /working/);
  const folded = dockRailItems(tabs, "chat", false);
  assert.ok(folded.every((i) => !i.active));
  assert.deepEqual(dockRailItems([], undefined, true), []);
});

test("dock rail actions match the web buttons", () => {
  assert.equal(dockRailAction("dock.toggle", tabs, "chat", true), null);
  assert.deepEqual(dockRailAction("dock.tab:facts", tabs, "chat", true), { type: "select", tab: "facts" });
  assert.deepEqual(dockRailAction("dock.tab:facts", tabs, "chat", false), { type: "open", tab: "facts" });
  assert.equal(dockRailAction("dock.tab:nope", tabs, "chat", true), null);
  assert.equal(dockRailAction("settings", tabs, "chat", true), null);
});

test("an action tab (Start playground) is never active and runs instead of opening", () => {
  const withStart = [{ id: "playground", label: "Start playground", icon: "playLeft", action: true }, ...tabs];
  const items = dockRailItems(withStart, "playground", true);
  assert.deepEqual(items.map((i) => [i.id, i.icon, i.active]), [["dock.tab:playground", "playLeft", false], ["dock.tab:facts", "doc", false], ["dock.tab:chat", "msg", false]]);
  assert.deepEqual(dockRailAction("dock.tab:playground", withStart, "chat", true), { type: "run", tab: "playground" });
  assert.deepEqual(dockRailAction("dock.tab:playground", withStart, "chat", false), { type: "run", tab: "playground" });
});

test("the foot holds only Settings; the current page is active and Settings carries the attention dot", () => {
  const m = buildRailModel({ ...base, pathname: "/settings/runner", settingsNeedYou: true });
  assert.deepEqual(m.foot.map((i) => i.id), ["settings"]);
  const settings = m.foot[0];
  assert.equal(settings.active, true);
  assert.deepEqual(settings.badge, { tone: "human" });
  assert.deepEqual(buildRailModel(base).foot.map((i) => i.id), ["settings"]);
  assert.equal(buildRailModel(base).foot[0].active, false);
  // HTTP Client and Dev workspace moved to the Apps menu, so being on them marks nothing in the rail.
  for (const pathname of ["/http", "/dev"]) assert.ok(buildRailModel({ ...base, pathname }).foot.every((i) => !i.active), pathname);
});

test("Needs you carries its kind and a count badge", () => {
  const m = buildRailModel({ ...base, needsYou: 120 });
  const item = m.middle.find((i) => i.id === "needsYou");
  assert.equal(item.kind, "needsYou");
  assert.deepEqual(item.badge, { text: "99+", tone: "human" });
  assert.equal(buildRailModel(base).middle.find((i) => i.id === "needsYou").badge, undefined);
});

test("PR review requests: count badge, PR menu, Clear all and per-PR Dismiss", () => {
  const requests = [{ id: "a", number: 7, title: "Fix the thing", repository: "o/r" }];
  const m = buildRailModel({ ...base, review: { ...review, requests, counts: { direct: 1, team: 0 } } });
  const pr = m.middle[0];
  assert.deepEqual(pr.badge, { text: "1", tone: "accent" });
  assert.equal(pr.menu[0].id, "pr:a");
  assert.ok(pr.menu.some((x) => x.id === "pr.refresh"));
  assert.ok(pr.menu.some((x) => x.id === "pr.clear"));
  const dismissGroup = pr.menu.find((x) => x.id === "pr.dismiss");
  assert.ok(dismissGroup);
  assert.deepEqual(dismissGroup.children.map((c) => c.id), ["pr.dismiss:a"]);
  assert.equal(pr.menu.find((x) => x.id === "pr.direct").checked, true);

  const cleared = buildRailModel({ ...base, review: { ...review, dismissed: 2 } }).middle[0];
  assert.equal(cleared.badge, undefined);
  assert.equal(cleared.menu.some((x) => x.id === "pr.clear"), false);
  assert.equal(cleared.menu.some((x) => x.id === "pr.dismiss"), false);
  assert.equal(cleared.menu.find((x) => x.id === "pr.restore").label, "Restore dismissed (2)");

  const approved = buildRailModel({ ...base, review: { ...review, approved: 2 } }).middle[0];
  assert.deepEqual(approved.badge, { text: "2", tone: "done" });
  const unconfigured = buildRailModel({ ...base, review: { ...review, configured: false } }).middle[0];
  assert.equal(unconfigured.badge, undefined);
  assert.deepEqual(unconfigured.menu.map((x) => x.id), ["pr.setup"]);
});

test("harnesses: avatar, status tone and a usage menu", () => {
  const h = (state) => ({ harness: "codex", label: "Codex", initials: "CX", color: "#B09AEF", name: "Codex", state, usage: { id: "usage", title: "Codex", value: "42%", fraction: 0.42, tone: "normal", meta: ["Session allowance used", "Idle"], sub: "5h" } });
  const [working] = buildRailModel({ ...base, harnesses: [h("working")] }).middle.slice(2);
  assert.equal(working.id, "harness:codex");
  assert.equal(working.status, "done");
  assert.deepEqual(working.avatar, { initials: "CX", color: "#B09AEF" });
  assert.ok(working.menu.at(-1).id === "usage");
  assert.deepEqual(working.character, { harness: "codex", working: true, name: "Codex" });
  assert.equal(working.usage[0].fraction, 0.42);
  assert.equal(buildRailModel({ ...base, harnesses: [h("idle")] }).middle[2].character.working, false);
  assert.equal(buildRailModel({ ...base, harnesses: [h("limited")] }).middle[2].character.working, false);
  assert.equal(buildRailModel({ ...base, harnesses: [h("limited")] }).middle[2].status, "warning");
  assert.equal(buildRailModel({ ...base, harnesses: [h("idle")] }).middle[2].status, undefined);
  assert.equal(buildRailModel({ ...base, harnesses: null }).middle.length, 2);
});

test("rail.action resolves to the web's own actions", () => {
  const ctx = { reviewUrl: (id) => (id === "a" ? "https://github.com/o/r/pull/7" : undefined) };
  assert.deepEqual(railEffect("dock.tab:chat", undefined, ctx), { type: "dock", itemId: "dock.tab:chat" });
  // The retired Customization, HTTP Client and Dev workspace buttons resolve to nothing.
  assert.equal(railEffect("customization", undefined, ctx), null);
  assert.equal(railEffect("http", undefined, ctx), null);
  assert.equal(railEffect("dev", undefined, ctx), null);
  assert.deepEqual(railEffect("settings", undefined, ctx), { type: "navigate", path: "/settings" });
  assert.deepEqual(railEffect("pr", "pr:a", ctx), { type: "open", url: "https://github.com/o/r/pull/7" });
  assert.equal(railEffect("pr", "pr:zzz", ctx), null);
  assert.deepEqual(railEffect("pr", "pr.dismiss:a", ctx), { type: "dismissReview", id: "a" });
  assert.equal(railEffect("pr", "pr.dismiss:", ctx), null);
  assert.deepEqual(railEffect("pr", "pr.clear", ctx), { type: "clearReviews" });
  assert.deepEqual(railEffect("pr", "pr.restore", ctx), { type: "restoreReviews" });
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
  store.set(a, [{ id: "dock.tab:chat", label: "A" }], (id) => seen.push(["a", id]));
  store.set(b, [{ id: "dock.tab:chat", label: "B" }], (id) => seen.push(["b", id]));
  assert.equal(store.items()[0].label, "B");
  assert.ok(store.act("dock.tab:chat"));
  assert.deepEqual(seen, [["b", "dock.tab:chat"]]);
  const before = store.items();
  store.set(b, [{ id: "dock.tab:chat", label: "B" }], () => {});
  assert.equal(store.items(), before, "an equal model keeps the same snapshot");
  store.clear(b);
  assert.equal(store.items()[0].label, "A");
  store.clear(a);
  assert.deepEqual(store.items(), []);
  assert.equal(store.act("x"), false);
  assert.ok(changes >= 3);
});

test("harnessRailInputs maps idle, working, limited, antigravity, and fallback harnesses", () => {
  const inputs = harnessRailInputs([
    {
      harness: "claude-code",
      label: "Claude",
      connected: true,
      running: 2,
      usage_available: true,
      usage_checked_at: new Date().toISOString(),
      windows: [{ id: "s", kind: "session", label: "5h", used_percent: 45 }],
    },
    {
      harness: "codex",
      label: "Codex",
      connected: true,
      running: 0,
      limited_until: "2026-11-19T23:00:00Z",
      usage_available: true,
      windows: [{ id: "s", kind: "session", label: "5h", used_percent: 100 }],
    },
    {
      harness: "antigravity",
      label: "Antigravity",
      connected: true,
      running: 0,
      usage_available: false,
      windows: [],
    },
    {
      harness: "custom-cli",
      label: "Custom",
      connected: true,
      running: 0,
      usage_available: false,
      usage_checking: true,
      windows: [],
    },
  ]);

  assert.equal(inputs[0].initials, "CC");
  assert.equal(inputs[0].state, "working");
  assert.equal(inputs[0].usage.value, "45%");
  assert.equal(inputs[0].usage.fraction, 0.45);
  assert.deepEqual(inputs[0].usage.meta, ["5h allowance used", "2 working"]);

  assert.equal(inputs[1].initials, "CX");
  assert.equal(inputs[1].state, "limited");
  assert.equal(inputs[1].usage.tone, "limited");
  assert.deepEqual(inputs[1].usage.meta, ["5h allowance used", "Limited"]);

  assert.equal(inputs[2].name, "AG");
  assert.equal(inputs[2].usage.value, "—");
  assert.equal(inputs[2].usage.unavailable, true);
  assert.deepEqual(inputs[2].usage.meta, ["Allowance not reported", "Idle"]);

  assert.equal(inputs[3].initials, "CU");
  assert.equal(inputs[3].color, "#8A8F98");
  assert.equal(inputs[3].usage.value, "…");
  assert.deepEqual(inputs[3].usage.meta, ["Checking usage…", "Idle"]);
});
