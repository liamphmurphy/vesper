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
  for (const bad of [{ accent: "blue", mode: "dark" }, { accent: "#0A84FF", mode: "auto" }, { accent: "#0A84FF" }, { accent: "#0A84FF80", mode: "light" }]) {
    assert.equal(isNativeCommand({ v: 1, type: "appearance", ...bad }), false, JSON.stringify(bad));
  }
});
