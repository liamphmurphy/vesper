import assert from "node:assert/strict";
import test from "node:test";
import { buildDockMenu, dockProgress, newChatHref, showHideAction } from "../dist/dock-model.js";
import { defaultNativeSettings, normalizeNativeSettings } from "../dist/settings.js";

const P1 = "6a1b2c3d-4e5f-4a6b-8c7d-9e0f1a2b3c4d";
const P2 = "0f9a3c1e-2b4d-4e6f-8a1b-3c5d7e9f1a2b";
const item = (id, over = {}) => ({
  id,
  kind: "approval",
  title: `Item ${id}`,
  href: `/runs/${id}`,
  created_at: "2026-11-17T10:00:00Z",
  resolved: false,
  read: false,
  needs_you: true,
  ...over,
});
const labels = (menu) => menu.map((m) => (m.type === "separator" ? "---" : m.label));

test("dock menu lists needs-you items, new chats per persona and capture", () => {
  const menu = buildDockMenu({
    items: [item("1", { ticket_key: "PAY-2" }), item("2", { read: true })],
    personas: [
      { id: P1, name: "Meow" },
      { id: P2, name: "Elminster" },
    ],
    screenshot: true,
  });
  assert.deepEqual(labels(menu), [
    "Needs you (1)",
    "PAY-2 · Item 1",
    "---",
    "New Chat",
    "New Chat with Meow",
    "New Chat with Elminster",
    "---",
    "Quick Capture…",
    "Screenshot to Chat…",
  ]);
  assert.deepEqual(menu.find((m) => m.label === "New Chat with Meow").action, { kind: "open-href", href: `/chat?new&persona=${P1}` });
  assert.deepEqual(menu.find((m) => m.label === "PAY-2 · Item 1").action, { kind: "open-href", href: "/runs/1" });
});

test("dock menu caps items and personas, drops bad persona ids, and hides empty sections", () => {
  const many = Array.from({ length: 8 }, (_, i) => item(String(i)));
  const personas = [
    { id: "not-a-uuid", name: "Bad" },
    { id: P1, name: "  " },
    ...Array.from({ length: 9 }, (_, i) => ({ id: P2.replace(/.$/, String(i)), name: `P${i}` })),
  ];
  const menu = buildDockMenu({ items: many, personas, screenshot: false, maxItems: 3, maxPersonas: 2 });
  const l = labels(menu);
  assert.equal(l.filter((x) => x.startsWith("Item ")).length, 3);
  assert.ok(l.includes("Show all 8 in Inbox…"));
  assert.deepEqual(l.filter((x) => x.startsWith("New Chat with")), ["New Chat with P0", "New Chat with P1"]);
  assert.ok(!l.includes("Screenshot to Chat…"));
  assert.equal(labels(buildDockMenu({ items: [], personas: [], screenshot: false }))[0], "New Chat", "no Needs-you header when nothing needs you");
});

test("newChatHref only puts a valid persona id in the link", () => {
  assert.equal(newChatHref(), "/chat?new");
  assert.equal(newChatHref(P1), `/chat?new&persona=${P1}`);
  assert.equal(newChatHref("x&next=//evil"), "/chat?new");
});

test("dockProgress follows the run image download only", () => {
  const base = { title: "", message: "", nextStep: "", actions: [] };
  assert.equal(dockProgress({ ...base, phase: "downloading", progress: { done: 1, total: 4 } }), 0.25);
  assert.equal(dockProgress({ ...base, phase: "downloading", progress: { done: 5, total: 4 } }), 1);
  assert.equal(dockProgress({ ...base, phase: "downloading", progress: { done: 1, total: 0 } }), -1, "unknown size: no bar");
  assert.equal(dockProgress({ ...base, phase: "running" }), -1);
});

test("showHideAction hides only when Vesper is in front with a window", () => {
  assert.equal(showHideAction({ appFocused: true, visibleWindows: 1 }), "hide");
  assert.equal(showHideAction({ appFocused: false, visibleWindows: 1 }), "show");
  assert.equal(showHideAction({ appFocused: true, visibleWindows: 0 }), "show");
});

test("show/hide and dock settings default safely", () => {
  const d = defaultNativeSettings();
  assert.deepEqual(d.showHide, { enabled: false, shortcut: "Alt+Shift+V" });
  assert.deepEqual(d.dock, { menu: true, progress: true });
  const n = normalizeNativeSettings({ showHide: { enabled: "yes", shortcut: " " }, dock: { menu: false, progress: 1 } });
  assert.deepEqual(n.showHide, { enabled: false, shortcut: "Alt+Shift+V" });
  assert.deepEqual(n.dock, { menu: false, progress: true });
});
