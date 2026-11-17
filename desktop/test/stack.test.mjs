import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  ensureAuthenticatedSession,
  ensureSecretsKey,
  hasActiveRuns,
  resolveBundledResources,
} from "../dist/stack.js";

test("ensureSecretsKey generates, encrypts, and reuses key across restarts", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-key-"));
  const fakeStorage = {
    isEncryptionAvailable: () => true,
    encryptString: (s) => Buffer.from(`enc:${s}`, "utf8"),
    decryptString: (b) => {
      const text = b.toString("utf8");
      if (!text.startsWith("enc:")) throw new Error("bad cipher");
      return text.slice(4);
    },
  };

  const first = ensureSecretsKey(dir, fakeStorage);
  assert.equal(Buffer.from(first, "base64").length, 32);

  const encFile = path.join(dir, "secrets-key.enc");
  assert.equal(fs.existsSync(encFile), true);
  assert.ok(fs.readFileSync(encFile, "utf8").startsWith("enc:"));

  const second = ensureSecretsKey(dir, fakeStorage);
  assert.equal(second, first);

  fs.rmSync(dir, { recursive: true, force: true });
});

test("resolveBundledResources detects staged binary, postgres, kernel, and web standalone", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-res-"));
  assert.equal(resolveBundledResources(dir), null);

  fs.mkdirSync(path.join(dir, "bin"), { recursive: true });
  fs.mkdirSync(path.join(dir, "postgres", "bin"), { recursive: true });
  fs.mkdirSync(path.join(dir, "images"), { recursive: true });
  fs.mkdirSync(path.join(dir, "web"), { recursive: true });
  fs.writeFileSync(path.join(dir, "bin", "vesper"), "", "utf8");
  fs.writeFileSync(path.join(dir, "postgres", "bin", "postgres"), "", "utf8");
  fs.writeFileSync(path.join(dir, "images", "vmlinux"), "", "utf8");
  fs.writeFileSync(path.join(dir, "web", "server.js"), "", "utf8");

  const resolved = resolveBundledResources(dir);
  assert.ok(resolved);
  assert.equal(resolved.vesperBin, path.join(dir, "bin", "vesper"));
  assert.equal(resolved.postgresBinDir, path.join(dir, "postgres", "bin"));
  assert.equal(resolved.kernelPath, path.join(dir, "images", "vmlinux"));
  assert.equal(resolved.webDistDir, path.join(dir, "web"));

  fs.rmSync(dir, { recursive: true, force: true });
});

test("ensureAuthenticatedSession mints and redeems one-time code when 401", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-auth-"));
  const fakeBin = path.join(dir, "vesper");
  fs.writeFileSync(
    fakeBin,
    `#!/bin/sh
if [ "$1" = "sign-in-link" ] && [ "$2" = "-code" ]; then
  echo "one-time-code-xyz"
  exit 0
fi
exit 1
`,
    { mode: 0o755 },
  );
  const rtPath = path.join(dir, "runtime.json");
  fs.writeFileSync(rtPath, JSON.stringify({ databaseUrl: "postgres://vesper@/vesper?host=/tmp/sock" }), "utf8");

  const calls = [];
  const res = await ensureAuthenticatedSession({
    serverUrl: "http://localhost:8080",
    vesperBin: fakeBin,
    runtimeJsonPath: rtPath,
    fetch: async (url) => {
      calls.push(url);
      if (url.endsWith("/api/v1/inbox")) {
        return { ok: false, status: 401, json: async () => ({}) };
      }
      if (url.includes("/api/v1/sign-in?code=one-time-code-xyz")) {
        return { ok: false, status: 303, json: async () => ({}) };
      }
      throw new Error(`unexpected fetch: ${url}`);
    },
  });

  assert.deepEqual(res, { signedIn: true, minted: true });
  assert.deepEqual(calls, [
    "http://localhost:8080/api/v1/inbox",
    "http://localhost:8080/api/v1/sign-in?code=one-time-code-xyz",
  ]);

  fs.rmSync(dir, { recursive: true, force: true });
});

test("hasActiveRuns inspects running runs JSON safely", async () => {
  const running = await hasActiveRuns("http://localhost:8080", async () => ({
    ok: true,
    status: 200,
    json: async () => ({ runs: [{ id: "r1" }] }),
  }));
  assert.equal(running, true);

  const idle = await hasActiveRuns("http://localhost:8080", async () => ({
    ok: true,
    status: 200,
    json: async () => ({ runs: [] }),
  }));
  assert.equal(idle, false);
});
