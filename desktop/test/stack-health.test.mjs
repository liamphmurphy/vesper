import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  classifyStackError,
  darwinMajor,
  deriveStackHealth,
  formatBytes,
  readLogTail,
  shouldAutoRestart,
  trayIconState,
} from "../dist/stack-health.js";

const GB = 1024 ** 3;
const base = {
  mode: "local",
  platform: "darwin",
  arch: "arm64",
  darwinMajor: 24,
  starting: false,
  processRunning: true,
  freeDiskBytes: 200 * GB,
  minFreeDiskGb: 10,
  image: { state: "ready" },
  runnerOnline: true,
};

test("a healthy local stack is running", () => {
  const h = deriveStackHealth(base);
  assert.equal(h.phase, "running");
  assert.equal(trayIconState(h.phase), "running");
});

test("each named failure state has a specific title and next step", () => {
  const cases = [
    [{ arch: "x64" }, "Virtualization unavailable", /Apple Silicon/],
    [{ darwinMajor: 23 }, "Virtualization unavailable", /macOS 15/],
    [{ processRunning: false, startError: "Error Domain=VZErrorDomain Code=2" }, "Virtualization unavailable", /vz\.entitlements/],
    [{ processRunning: false, startError: "embedded postgres: initdb failed" }, "Database didn't start", /logs/],
    [{ processRunning: false, startError: "listen 127.0.0.1:8080: bind: address already in use" }, "Port in use", /Quit the other program/],
    [{ processRunning: false, startError: "write: no space left on device" }, "Disk full", /Free up disk space/],
    [{ processRunning: false, startError: "macOS Keychain safeStorage encryption is unavailable." }, "Keychain key unavailable", /keychain/i],
    [{ processRunning: false, startError: "Timed out waiting for vesper app to start." }, "Stack is slow to start", /Restart/],
    [{ processRunning: false, exit: { code: 2, signal: null, stderrTail: "panic: boom" } }, "Stack stopped", /Restart/],
    [{ processRunning: false, exit: { code: 2, signal: null, stderrTail: "" }, freeDiskBytes: 1 * GB }, "Disk almost full", /Free up/],
    [{ image: { state: "error", error: "agent-base.erofs not found locally and VESPER_ROOTFS_URL is not set" } }, "Run image unavailable", /build-images\.sh/],
    [{ image: { state: "error", error: "download rootfs: HTTP 503" } }, "Run image unavailable", /connection/],
    [{ freeDiskBytes: 3 * GB }, "Disk almost full", /Free up/],
    [{ runnerOnline: false }, "Runner offline", /Restart/],
  ];
  for (const [over, title, step] of cases) {
    const h = deriveStackHealth({ ...base, ...over });
    assert.equal(h.title, title, JSON.stringify(over));
    assert.match(h.nextStep, step, JSON.stringify(over));
    assert.ok(["error", "degraded"].includes(h.phase), JSON.stringify(over));
    assert.equal(trayIconState(h.phase), "error");
  }
});

test("first run: starting, then downloading the run image with progress", () => {
  assert.equal(deriveStackHealth({ ...base, starting: true, processRunning: false }).phase, "starting");
  const h = deriveStackHealth({ ...base, image: { state: "downloading", downloadedBytes: GB, totalBytes: 4 * GB } });
  assert.equal(h.phase, "downloading");
  assert.deepEqual(h.progress, { done: GB, total: 4 * GB });
  assert.match(h.message, /1\.0 GB of 4\.0 GB/);
  assert.equal(trayIconState(h.phase), "starting");
});

test("remote and external servers report reachability only", () => {
  assert.equal(deriveStackHealth({ ...base, mode: "remote", reachable: true }).phase, "remote");
  const down = deriveStackHealth({ ...base, mode: "remote", reachable: false, arch: "x64" });
  assert.equal(down.title, "Server unreachable", "platform checks don't apply to a remote server");
  assert.deepEqual(down.actions, ["retry", "settings"]);
});

test("classifyStackError falls back to a generic crash", () => {
  assert.equal(classifyStackError("").title, "Stack stopped");
});

test("shouldAutoRestart allows three restarts per ten minutes", () => {
  const now = 1_000_000_000;
  assert.equal(shouldAutoRestart([], now), true);
  assert.equal(shouldAutoRestart([now - 1000, now - 2000], now), true);
  assert.equal(shouldAutoRestart([now - 1000, now - 2000, now - 3000], now), false);
  assert.equal(shouldAutoRestart([now - 11 * 60_000, now - 12 * 60_000, now - 13 * 60_000], now), true);
});

test("darwinMajor, formatBytes and readLogTail", () => {
  assert.equal(darwinMajor("24.1.0"), 24);
  assert.equal(darwinMajor("garbage"), undefined);
  assert.equal(formatBytes(1536 * 1024 * 1024), "1.5 GB");
  assert.equal(formatBytes(5 * 1024 * 1024), "5 MB");
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-log-"));
  const file = path.join(dir, "vesper-app.log");
  assert.equal(readLogTail(file), "");
  fs.writeFileSync(file, "line one\nline two\nline three\n");
  assert.equal(readLogTail(file), "line one\nline two\nline three\n");
  assert.equal(readLogTail(file, 15), "line three\n", "starts at a line boundary");
  fs.rmSync(dir, { recursive: true, force: true });
});
