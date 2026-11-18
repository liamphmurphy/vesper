import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { loadConfig, saveConfig } from "../dist/config.js";
import {
  applyNativeSettingsPatch,
  DEFAULT_UPDATE_FEED_URL,
  defaultNativeSettings,
  isValidClockTime,
  normalizeNativeSettings,
  NOTIFICATION_KINDS,
} from "../dist/settings.js";

test("defaults keep pre-existing behaviour and leave outward-reaching features off", () => {
  const d = defaultNativeSettings();
  assert.equal(d.tray.enabled, true);
  assert.equal(d.tray.onLastWindowClose, "dock", "closing the last window keeps today's Dock behaviour");
  assert.equal(d.login.openAtLogin, false);
  assert.equal(d.quickCapture.enabled, false);
  assert.equal(d.touchId.enabled, false);
  assert.equal(d.updates.checkEnabled, false);
  assert.equal(d.power.onSleep, "keep");
  assert.equal(d.power.confirmQuitWithActiveRuns, true);
  for (const kind of NOTIFICATION_KINDS) assert.equal(d.notifications.kinds[kind], true, kind);
});

test("normalizeNativeSettings repairs hostile or partial input field by field", () => {
  const n = normalizeNativeSettings({
    tray: { enabled: "yes", onLastWindowClose: "menuBar" },
    notifications: { kinds: { approval: false, bogus: false }, quietHours: { enabled: true, start: "25:00", end: "07:30" } },
    quickCapture: { shortcut: "   " },
    power: { onSleep: "hibernate" },
    stack: { minFreeDiskGb: -5 },
    updates: { feedUrl: "http://evil.example/latest" },
    __proto__: { polluted: true },
  });
  assert.equal(n.tray.enabled, true, "non-boolean falls back to default");
  assert.equal(n.tray.onLastWindowClose, "menuBar");
  assert.equal(normalizeNativeSettings({ tray: { onLastWindowClose: "vanish" } }).tray.onLastWindowClose, "dock");
  assert.equal(n.notifications.kinds.approval, false);
  assert.equal("bogus" in n.notifications.kinds, false);
  assert.equal(n.notifications.quietHours.enabled, true);
  assert.equal(n.notifications.quietHours.start, "22:00");
  assert.equal(n.notifications.quietHours.end, "07:30");
  assert.equal(n.quickCapture.shortcut, "Alt+Shift+Space");
  assert.equal(n.power.onSleep, "keep");
  assert.equal(n.stack.minFreeDiskGb, 10);
  assert.equal(n.updates.feedUrl, DEFAULT_UPDATE_FEED_URL, "plain http off loopback is refused");
  assert.equal({}.polluted, undefined);
});

test("applyNativeSettingsPatch merges a partial patch over current settings", () => {
  const current = normalizeNativeSettings({ power: { onSleep: "pause" }, notifications: { kinds: { merged: false } } });
  const next = applyNativeSettingsPatch(current, { notifications: { kinds: { question: false } }, login: { openAtLogin: true } });
  assert.equal(next.power.onSleep, "pause", "untouched sections are kept");
  assert.equal(next.notifications.kinds.merged, false, "untouched kinds are kept");
  assert.equal(next.notifications.kinds.question, false);
  assert.equal(next.login.openAtLogin, true);
  const bad = applyNativeSettingsPatch(next, { power: { onSleep: 42 } });
  assert.equal(bad.power.onSleep, "pause", "an invalid patch value keeps the current value, not the default");
});

test("isValidClockTime accepts HH:MM only", () => {
  assert.ok(isValidClockTime("00:00"));
  assert.ok(isValidClockTime("23:59"));
  assert.ok(!isValidClockTime("24:00"));
  assert.ok(!isValidClockTime("7:00"));
  assert.ok(!isValidClockTime(700));
});

test("native settings round-trip through config.json, and old configs get defaults", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-native-"));
  const cfgPath = path.join(dir, "config.json");
  fs.writeFileSync(cfgPath, JSON.stringify({ serverUrl: "http://localhost:8080", playgroundPorts: [8090] }));
  const legacy = loadConfig(cfgPath);
  assert.deepEqual(legacy.native, defaultNativeSettings());

  legacy.native.tray.onLastWindowClose = "menuBar";
  legacy.native.quickCapture = { enabled: true, shortcut: "CommandOrControl+Shift+K" };
  saveConfig(cfgPath, legacy);
  const again = loadConfig(cfgPath);
  assert.equal(again.native.tray.onLastWindowClose, "menuBar");
  assert.equal(again.native.quickCapture.shortcut, "CommandOrControl+Shift+K");
  fs.rmSync(dir, { recursive: true, force: true });
});

test("stack.runnerSlots defaults to 2, keeps 1-32, and falls back otherwise", () => {
  assert.equal(defaultNativeSettings().stack.runnerSlots, 2);
  for (const ok of [1, 32, 8]) assert.equal(normalizeNativeSettings({ stack: { runnerSlots: ok } }).stack.runnerSlots, ok);
  for (const bad of [0, 33, 2.5, "abc", null]) assert.equal(normalizeNativeSettings({ stack: { runnerSlots: bad } }).stack.runnerSlots, 2, String(bad));
  const next = applyNativeSettingsPatch(normalizeNativeSettings({}), { stack: { runnerSlots: 6 } });
  assert.equal(next.stack.runnerSlots, 6);
  assert.equal(next.stack.minFreeDiskGb, 10, "other stack settings are kept");
});
