import assert from "node:assert/strict";
import test from "node:test";
import { isTouchIdScope, touchIdDecision, touchIdReason } from "../dist/biometrics.js";
import { loginItemSettingsFor, loginStatusMessage, shouldStartHidden } from "../dist/login.js";
import { batteryWarning, prunePausedSet, runsToPauseOnSleep, runsToResume, shouldConfirmQuit, wantsSleepBlocker } from "../dist/power.js";
import { defaultNativeSettings } from "../dist/settings.js";
import { compareVersions, isCheckDue, parseVersion, pickUpdate, versionTransition } from "../dist/updates.js";

const power = defaultNativeSettings().power;
const run = (id, over = {}) => ({ id, state: "running", purpose: "ticket", ...over });

test("the sleep blocker is held only while runs are working and the setting is on", () => {
  assert.equal(wantsSleepBlocker(power, [run("a")]), true);
  assert.equal(wantsSleepBlocker(power, [run("a", { state: "waiting", wait_reason: "approval" })]), false);
  assert.equal(wantsSleepBlocker(power, [run("a", { state: "paused" })]), false);
  assert.equal(wantsSleepBlocker(power, []), false);
  assert.equal(wantsSleepBlocker({ ...power, preventSleepWhileRunning: false }, [run("a")]), false);
});

test("pause-on-sleep pauses live non-chat runs and resumes only the ones Vesper paused", () => {
  const live = [run("a"), run("b", { purpose: "chat" }), run("c", { state: "waiting", wait_reason: "checks" })];
  assert.deepEqual(runsToPauseOnSleep(power, live), [], "keep policy pauses nothing");
  assert.deepEqual(runsToPauseOnSleep({ ...power, onSleep: "pause" }, live).map((r) => r.id), ["a"]);

  const paused = new Set(["a", "gone"]);
  const after = [run("a", { state: "paused" }), run("x", { state: "paused" })];
  assert.deepEqual(runsToResume(paused, after), ["a"], "a run the person paused by hand stays paused");
  prunePausedSet(paused, after);
  assert.deepEqual([...paused], ["a"]);
});

test("battery warning and quit confirmation", () => {
  assert.match(batteryWarning(power, true, [run("a"), run("b")]), /^2 runs are still working/);
  assert.equal(batteryWarning(power, false, [run("a")]), null);
  assert.equal(batteryWarning(power, true, [run("a", { state: "paused" })]), null);
  assert.equal(batteryWarning({ ...power, warnOnBattery: false }, true, [run("a")]), null);
  assert.equal(shouldConfirmQuit(power, true, true), true);
  assert.equal(shouldConfirmQuit(power, false, true), false);
  assert.equal(shouldConfirmQuit({ ...power, confirmQuitWithActiveRuns: false }, true, true), false);
});

test("launch at login: item settings, hidden start and status messages", () => {
  assert.deepEqual(loginItemSettingsFor({ openAtLogin: true, startHidden: true }), { openAtLogin: true, type: "mainAppService" });
  assert.deepEqual(loginItemSettingsFor({ openAtLogin: false, startHidden: true }), { openAtLogin: false, type: "mainAppService" });
  assert.equal(shouldStartHidden({ openAtLogin: true, startHidden: true }, true, true), true);
  assert.equal(shouldStartHidden({ openAtLogin: true, startHidden: true }, true, false), false, "a manual launch shows a window");
  assert.equal(shouldStartHidden({ openAtLogin: true, startHidden: true }, false, true), false, "never hidden without a tray");
  assert.equal(shouldStartHidden({ openAtLogin: true, startHidden: false }, true, true), false);
  assert.match(loginStatusMessage(true, "requires-approval"), /System Settings/);
  assert.equal(loginStatusMessage(true, "enabled"), null);
  assert.equal(loginStatusMessage(false, "requires-approval"), null);
});

test("Touch ID decision: opt-in, per scope, and skipped when the Mac can't prompt", () => {
  const on = { enabled: true, scopes: { run_approvals: true, push_requests: false, connector_approvals: true, secret_approvals: true } };
  assert.equal(touchIdDecision(on, "run_approvals", true), "prompt");
  assert.equal(touchIdDecision(on, "push_requests", true), "skip");
  assert.equal(touchIdDecision(on, "run_approvals", false), "skip", "no sensor falls back to the click flow");
  assert.equal(touchIdDecision({ ...on, enabled: false }, "run_approvals", true), "skip");
  assert.equal(touchIdDecision(on, "everything", true), "skip");
  assert.equal(isTouchIdScope("secret_approvals"), true);
  assert.equal(touchIdReason("push_requests"), "approve a push and pull request");
});

test("versions compare semver-style with pre-releases first", () => {
  assert.deepEqual(parseVersion("v1.2.3-beta.1"), { major: 1, minor: 2, patch: 3, pre: "beta.1" });
  assert.equal(parseVersion("1.2"), null);
  assert.equal(compareVersions("0.2.0", "0.1.9"), 1);
  assert.equal(compareVersions("0.1.0", "0.1.0"), 0);
  assert.equal(compareVersions("1.0.0-rc.1", "1.0.0"), -1);
  assert.equal(compareVersions("v1.10.0", "1.9.9"), 1);
});

test("pickUpdate accepts only newer, published releases on trusted https hosts", () => {
  const feed = "https://api.github.com/repos/liamphmurphy/vesper/releases/latest";
  const rel = { tag_name: "v0.2.0", html_url: "https://github.com/liamphmurphy/vesper/releases/tag/v0.2.0", name: "Vesper 0.2", draft: false, prerelease: false };
  assert.deepEqual(pickUpdate("0.1.0", feed, rel), { version: "0.2.0", url: rel.html_url, name: "Vesper 0.2" });
  assert.equal(pickUpdate("0.2.0", feed, rel), null, "not newer");
  assert.equal(pickUpdate("0.1.0", feed, { ...rel, prerelease: true }), null);
  assert.equal(pickUpdate("0.1.0", feed, { ...rel, draft: true }), null);
  assert.equal(pickUpdate("0.1.0", feed, { ...rel, html_url: "https://evil.example/download" }), null);
  assert.equal(pickUpdate("0.1.0", feed, { ...rel, html_url: "http://github.com/x" }), null);
  assert.equal(pickUpdate("0.1.0", feed, { ...rel, tag_name: "latest" }), null);
  assert.equal(pickUpdate("0.1.0", feed, null), null);
  const own = "https://updates.example.net/vesper/latest.json";
  assert.equal(pickUpdate("0.1.0", own, { ...rel, html_url: "https://updates.example.net/vesper/0.2.0" }).version, "0.2.0");
});

test("versionTransition detects first run, upgrade and downgrade; isCheckDue is daily", () => {
  assert.equal(versionTransition(undefined, "0.1.0"), "first-run");
  assert.equal(versionTransition("0.1.0", "0.1.0"), "same");
  assert.equal(versionTransition("0.1.0", "0.2.0"), "upgrade");
  assert.equal(versionTransition("0.3.0", "0.2.0"), "downgrade");
  const day = 24 * 60 * 60 * 1000;
  assert.equal(isCheckDue(undefined, 5 * day), true);
  assert.equal(isCheckDue(4.5 * day, 5 * day), false);
  assert.equal(isCheckDue(3 * day, 5 * day), true);
  assert.equal(isCheckDue(9 * day, 5 * day), true, "a clock that moved back re-checks");
});
