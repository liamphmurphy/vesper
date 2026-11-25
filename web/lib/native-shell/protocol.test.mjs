import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { isNativeCommand, isPageMessage } from "./protocol.ts";

const fixture = (name) => JSON.parse(readFileSync(new URL(`../../../protocol/native-bridge/${name}`, import.meta.url), "utf8"));

test("every page-message fixture passes isPageMessage", () => {
  const all = fixture("page-messages.json");
  assert.ok(all.length > 0);
  for (const m of all) assert.ok(isPageMessage(m), JSON.stringify(m).slice(0, 120));
});

test("every native-command fixture passes isNativeCommand", () => {
  const all = fixture("native-commands.json");
  assert.ok(all.length > 0);
  for (const c of all) assert.ok(isNativeCommand(c), JSON.stringify(c));
});

test("a wrong version or unknown type is rejected", () => {
  assert.equal(isPageMessage({ v: 2, type: "ready", path: "/" }), false);
  assert.equal(isPageMessage({ v: 1, type: "nope" }), false);
  assert.equal(isPageMessage(null), false);
  assert.equal(isPageMessage([]), false);
  assert.equal(isNativeCommand({ v: 2, type: "command", name: "newChat" }), false);
  assert.equal(isNativeCommand({ v: 1, type: "nope" }), false);
  assert.equal(isNativeCommand({ v: 1, type: "command", name: "reboot" }), false);
  assert.equal(isNativeCommand("navigate"), false);
});

test("navigate only accepts in-app paths", () => {
  assert.equal(isNativeCommand({ v: 1, type: "navigate", path: "/chat" }), true);
  for (const path of ["//evil", "//evil.com/x", "http://x", "https://x/y", "chat", "javascript:alert(1)", 3]) {
    assert.equal(isNativeCommand({ v: 1, type: "navigate", path }), false, String(path));
  }
});

test("appearance commands need a #RRGGBB accent and a known mode", () => {
  assert.equal(isNativeCommand({ v: 1, type: "appearance", accent: "#0A84FF", mode: "dark" }), true);
  assert.equal(
    isNativeCommand({ v: 1, type: "appearance", accent: "#0A84FF", mode: "dark", themePref: "system", settingsJson: '{"version":1}' }),
    true,
  );
  for (const bad of [
    { accent: "blue", mode: "dark" },
    { accent: "#0A84FF", mode: "auto" },
    { accent: "#0A84FF" },
    { accent: "#0A84FF80", mode: "light" },
    { accent: "#0A84FF", mode: "dark", themePref: "midnight" },
    { accent: "#0A84FF", mode: "dark", settingsJson: 42 },
  ]) {
    assert.equal(isNativeCommand({ v: 1, type: "appearance", ...bad }), false, JSON.stringify(bad));
  }
});

test("inspector and openInMain messages validate shape and in-app paths", () => {
  assert.equal(isPageMessage({ v: 1, type: "inspector", model: null }), true);
  assert.equal(isPageMessage({ v: 1, type: "inspector", model: { id: "x", open: true, activeTabId: "a", tabs: [] } }), true);
  assert.equal(isPageMessage({ v: 1, type: "inspector", model: "bad" }), false);

  assert.equal(isPageMessage({ v: 1, type: "openInMain", path: "/spaces/s1", newTab: true }), true);
  for (const path of ["//evil.com", "https://evil.com", "spaces/s1"]) {
    assert.equal(isPageMessage({ v: 1, type: "openInMain", path }), false, path);
  }
});

test("inspector and companion commands validate required fields", () => {
  assert.equal(isNativeCommand({ v: 1, type: "inspector.visibility", open: false }), true);
  assert.equal(isNativeCommand({ v: 1, type: "inspector.visibility", open: "yes" }), false);
  assert.equal(isNativeCommand({ v: 1, type: "inspector.selectTab", tabId: "chat" }), true);
  assert.equal(isNativeCommand({ v: 1, type: "inspector.selectTab" }), false);
  assert.equal(isNativeCommand({ v: 1, type: "inspector.action", tabId: "p", actionId: "go" }), true);
  assert.equal(isNativeCommand({ v: 1, type: "inspector.change", tabId: "p", fieldId: "f", value: "v" }), true);
  assert.equal(isNativeCommand({ v: 1, type: "inspector.toggle", tabId: "p", fieldId: "f", checked: true }), true);
  assert.equal(isNativeCommand({ v: 1, type: "companion.context", context: {} }), true);
  assert.equal(isNativeCommand({ v: 1, type: "companion.context", context: null }), false);
  assert.equal(isNativeCommand({ v: 1, type: "panel.context", context: { active: null, keepKeys: [] } }), true);
  assert.equal(
    isNativeCommand({
      v: 1,
      type: "panel.context",
      context: { active: { kind: "chat.code", key: "chat.code:c1", propsJson: "{}" }, keepKeys: ["chat.code:c1"] },
    }),
    true,
  );
  assert.equal(isNativeCommand({ v: 1, type: "panel.context", context: { keepKeys: [] } }), false);
  assert.equal(isNativeCommand({ v: 1, type: "panel.event", tabId: "code", event: "fullscreen" }), true);
  assert.equal(isNativeCommand({ v: 1, type: "panel.event", tabId: "code" }), false);
  assert.equal(isPageMessage({ v: 1, type: "panel.event", tabId: "playground", event: "close", payloadJson: "{}" }), true);
  assert.equal(isPageMessage({ v: 1, type: "panel.event", tabId: "playground" }), false);
});

test("prompt, toast, shortcuts, commandPalette, and quickLook messages validate fields", () => {
  assert.equal(isPageMessage({ v: 1, type: "prompt", requestId: "p1", title: "Rename", confirmLabel: "Save", maxLength: 100 }), true);
  assert.equal(isPageMessage({ v: 1, type: "prompt", requestId: "p1", title: "Rename", confirmLabel: "Save", maxLength: 0 }), false);
  assert.equal(isPageMessage({ v: 1, type: "toast.show", id: "t1", title: "Saved", tone: "success", durationMs: 3000 }), true);
  assert.equal(isPageMessage({ v: 1, type: "toast.show", id: "t1", title: "Saved", tone: "info", durationMs: 3000 }), false);
  assert.equal(isPageMessage({ v: 1, type: "toast.dismiss", id: "t1" }), true);
  assert.equal(isPageMessage({ v: 1, type: "showShortcuts" }), true);
  assert.equal(isPageMessage({ v: 1, type: "commandPalette.open", request: { path: "/spaces", scope: "all" } }), true);
  assert.equal(isPageMessage({ v: 1, type: "commandPalette.open", request: { path: "//evil" } }), false);
  assert.equal(isPageMessage({ v: 1, type: "commandPalette.close" }), true);
  assert.equal(isPageMessage({ v: 1, type: "quickLook", items: [{ url: "/api/v1/library/1/content", title: "File" }] }), true);
  assert.equal(isPageMessage({ v: 1, type: "quickLook", items: [] }), false);
  assert.equal(isPageMessage({ v: 1, type: "quickLook", items: [{ url: "javascript:alert(1)", title: "Bad" }] }), false);

  assert.equal(isNativeCommand({ v: 1, type: "reply", requestId: "p1", ok: true, value: "Renamed" }), true);
  assert.equal(isNativeCommand({ v: 1, type: "toast.event", id: "t1", event: "timeout" }), true);
  assert.equal(isNativeCommand({ v: 1, type: "toast.event", id: "t1", event: "bogus" }), false);
  assert.equal(isNativeCommand({ v: 1, type: "palette.open", request: { path: "/chat", scope: "all" } }), true);
  assert.equal(isNativeCommand({ v: 1, type: "palette.open", request: { path: "relative" } }), false);
});

test("sidebarHidden needs a boolean", () => {
  assert.equal(isPageMessage({ v: 1, type: "sidebarHidden", hidden: true }), true);
  assert.equal(isPageMessage({ v: 1, type: "sidebarHidden", hidden: "yes" }), false);
  assert.equal(isPageMessage({ v: 1, type: "sidebarHidden" }), false);
});

test("openCustomAppWindow validates non-reserved custom app slugs", () => {
  assert.equal(isPageMessage({ v: 1, type: "openCustomAppWindow", slug: "budget" }), true);
  assert.equal(isPageMessage({ v: 1, type: "openCustomAppWindow", slug: "finance-2026" }), true);
  for (const slug of ["", "docs", "slides", "designs", "new", "../etc", "Bad_Slug", 42]) {
    assert.equal(isPageMessage({ v: 1, type: "openCustomAppWindow", slug }), false, String(slug));
  }
});
