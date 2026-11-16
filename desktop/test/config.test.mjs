import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  DEFAULT_PLAYGROUND_PORTS,
  DEFAULT_SERVER_URL,
  loadConfig,
  loadSession,
  normalizeServerUrl,
  saveConfig,
  saveSession,
} from "../dist/config.js";

test("normalizeServerUrl normalizes http/https URLs and rejects unsafe schemes", () => {
  assert.equal(normalizeServerUrl("http://localhost:8080/"), "http://localhost:8080");
  assert.equal(normalizeServerUrl("  https://vesper.tailnet.ts.net///  "), "https://vesper.tailnet.ts.net");
  assert.equal(normalizeServerUrl("vesper.tailnet.ts.net:8443"), "http://vesper.tailnet.ts.net:8443");
  assert.equal(normalizeServerUrl("https://host.test/subpath/"), "https://host.test/subpath");

  assert.throws(() => normalizeServerUrl("   "));
  assert.throws(() => normalizeServerUrl("javascript:alert(1)"));
  assert.throws(() => normalizeServerUrl("file:///etc/passwd"));
  assert.throws(() => normalizeServerUrl("ftp://example.com"));
});

test("loadConfig and saveConfig round-trip cleanly with defaults fallback", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-cfg-"));
  const cfgPath = path.join(tmpDir, "nested", "config.json");

  const missing = loadConfig(cfgPath);
  assert.equal(missing.serverUrl, DEFAULT_SERVER_URL);
  assert.deepEqual(missing.playgroundPorts, [...DEFAULT_PLAYGROUND_PORTS]);

  saveConfig(cfgPath, {
    serverUrl: "https://vesper.tailnet.ts.net/",
    localCheckoutPath: "  /Users/liam/src/vesper  ",
    playgroundPorts: [8090, 8091],
  });

  const loaded = loadConfig(cfgPath);
  assert.equal(loaded.serverUrl, "https://vesper.tailnet.ts.net");
  assert.equal(loaded.localCheckoutPath, "/Users/liam/src/vesper");
  assert.deepEqual(loaded.playgroundPorts, [8090, 8091]);

  fs.writeFileSync(cfgPath, "{not valid json", "utf8");
  assert.equal(loadConfig(cfgPath).serverUrl, DEFAULT_SERVER_URL);

  fs.rmSync(tmpDir, { recursive: true, force: true });
});

test("loadSession and saveSession filter non-http URLs and clamp activeIndex", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-sess-"));
  const sessionPath = path.join(tmpDir, "session.json");

  assert.deepEqual(loadSession(sessionPath), { tabs: [], activeIndex: 0 });

  saveSession(sessionPath, {
    tabs: ["http://localhost:8080/chat/1", "http://localhost:8080/inbox"],
    activeIndex: 1,
    bounds: { x: 100, y: 120, width: 1280, height: 840, isMaximized: false },
  });
  assert.deepEqual(loadSession(sessionPath), {
    tabs: ["http://localhost:8080/chat/1", "http://localhost:8080/inbox"],
    activeIndex: 1,
    bounds: { x: 100, y: 120, width: 1280, height: 840, isMaximized: false },
  });

  fs.writeFileSync(
    sessionPath,
    JSON.stringify({
      tabs: ["file:///tmp/offline.html", "http://localhost:8080/tickets", "javascript:void(0)"],
      activeIndex: 9,
      bounds: { width: 100, height: 100 },
    }),
    "utf8",
  );
  const sanitized = loadSession(sessionPath);
  assert.deepEqual(sanitized, {
    tabs: ["http://localhost:8080/tickets"],
    activeIndex: 0,
    bounds: undefined,
  });

  fs.rmSync(tmpDir, { recursive: true, force: true });
});
