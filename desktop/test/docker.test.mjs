import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import { augmentedDockerEnv, isLocalhostUrl, isValidVesperCheckout } from "../dist/docker.js";

test("isLocalhostUrl identifies loopback targets and excludes remote hosts", () => {
  assert.equal(isLocalhostUrl("http://localhost:8080"), true);
  assert.equal(isLocalhostUrl("http://127.0.0.1:8080"), true);
  assert.equal(isLocalhostUrl("http://[::1]:8080"), true);
  assert.equal(isLocalhostUrl("http://vesper.localhost:8080"), true);
  assert.equal(isLocalhostUrl("https://vesper.tailnet.ts.net"), false);
  assert.equal(isLocalhostUrl("http://100.80.1.2:8080"), false);
  assert.equal(isLocalhostUrl("not-a-url"), false);
});

test("isValidVesperCheckout verifies directory containing compose file", () => {
  const tmpDir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-chk-"));
  assert.equal(isValidVesperCheckout(undefined), false);
  assert.equal(isValidVesperCheckout(tmpDir), false);

  fs.writeFileSync(path.join(tmpDir, "docker-compose.yml"), "services: {}\n", "utf8");
  assert.equal(isValidVesperCheckout(tmpDir), true);

  fs.rmSync(tmpDir, { recursive: true, force: true });
});

test("augmentedDockerEnv appends Homebrew and OrbStack paths without duplicating entries", () => {
  const env = augmentedDockerEnv({ PATH: "/usr/bin:/opt/homebrew/bin" });
  const parts = (env.PATH ?? "").split(path.delimiter);
  assert.equal(parts.filter((p) => p === "/opt/homebrew/bin").length, 1);
  assert.equal(parts.includes("/usr/local/bin"), true);
  assert.equal(parts.includes("/Applications/OrbStack.app/Contents/MacOS/xbin"), true);
});
