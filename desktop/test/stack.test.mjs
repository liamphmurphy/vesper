import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import test from "node:test";
import {
  buildStackEnv,
  ensureAuthenticatedSession,
  ensureSecretsKey,
  hasActiveRuns,
  inspectBackupArchive,
  resolveBundledResources,
  runAppImportArchive,
  saveSecretsKey,
  validateSecretsKeyFormat,
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
  fs.writeFileSync(path.join(dir, "web", "index.html"), "", "utf8");

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

test("validateSecretsKeyFormat and saveSecretsKey validate and persist 32-byte keys", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-save-key-"));
  const fakeStorage = {
    isEncryptionAvailable: () => true,
    encryptString: (s) => Buffer.from(`enc:${s}`, "utf8"),
    decryptString: (b) => b.toString("utf8").replace(/^enc:/, ""),
  };

  assert.throws(() => validateSecretsKeyFormat("not-valid-base64"), /32-byte base64/);
  assert.throws(() => validateSecretsKeyFormat("dG9vLXNob3J0"), /32-byte base64/);

  const rawKey = Buffer.alloc(32, 7).toString("base64");
  const saved = saveSecretsKey(dir, fakeStorage, `  ${rawKey}  `);
  assert.equal(saved, rawKey);
  assert.equal(ensureSecretsKey(dir, fakeStorage), rawKey);

  fs.rmSync(dir, { recursive: true, force: true });
});

test("inspectBackupArchive and runAppImportArchive invoke vesper app-import cleanly", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "vesper-import-"));
  const fakeBin = path.join(dir, "vesper");
  const pgBinDir = path.join(dir, "postgres", "bin");
  fs.mkdirSync(pgBinDir, { recursive: true });
  fs.writeFileSync(path.join(pgBinDir, "postgres"), "", "utf8");

  const logFile = path.join(dir, "cli.log");
  fs.writeFileSync(
    fakeBin,
    `#!/bin/sh
if [ "$1" = "app-import" ] && [ "$2" = "-inspect" ]; then
  echo '{"exportedAt":"2026-11-16T20:00:00Z","appVersion":"dev","schemaVersion":155,"tableCount":10,"totalRows":42,"objectCount":3,"encryptedSecretRows":0,"matchesCurrentKey":false}'
  exit 0
fi
if [ "$1" = "app-import" ]; then
  if [ "$VESPER_NO_SIGNIN" != "" ]; then
    exit 99
  fi
  printf '%s|%s|%s\n' "$*" "$SECRETS_KEY" "$VESPER_POSTGRES_BIN_DIR" > "${logFile}"
  if [ "$SECRETS_KEY" = "fail-key" ]; then
    echo '{"level":"ERROR","msg":"exit","err":"the provided SECRETS_KEY does not match this backup archive"}'
    exit 1
  fi
  exit 0
fi
exit 1
`,
    { mode: 0o755 },
  );

  const insp = await inspectBackupArchive({
    vesperBin: fakeBin,
    archivePath: "/tmp/example.zip",
  });
  assert.equal(insp.tableCount, 10);
  assert.equal(insp.totalRows, 42);
  assert.equal(insp.objectCount, 3);

  const resources = { vesperBin: fakeBin, postgresBinDir: pgBinDir };
  await runAppImportArchive({
    resources,
    userDataDir: path.join(dir, "data"),
    archivePath: "/tmp/example.zip",
    secretsKey: "test-key",
    dropSecrets: false,
  });
  assert.equal(
    fs.readFileSync(logFile, "utf8").trim(),
    `app-import -data-dir ${path.join(dir, "data")} /tmp/example.zip|test-key|${pgBinDir}`,
  );

  await runAppImportArchive({
    resources,
    userDataDir: path.join(dir, "data"),
    archivePath: "/tmp/example.zip",
    secretsKey: "ignored-when-dropped",
    dropSecrets: true,
  });
  assert.equal(
    fs.readFileSync(logFile, "utf8").trim(),
    `app-import -data-dir ${path.join(dir, "data")} -drop-secrets /tmp/example.zip||${pgBinDir}`,
  );

  await assert.rejects(
    () =>
      runAppImportArchive({
        resources,
        userDataDir: path.join(dir, "data"),
        archivePath: "/tmp/example.zip",
        secretsKey: "fail-key",
      }),
    /does not match this backup archive/,
  );

  fs.rmSync(dir, { recursive: true, force: true });
});

test("buildStackEnv sets RUNNER_MAX_CONCURRENT from runnerSlots unless the environment already does", () => {
  const opts = {
    resources: { vesperBin: "/x/vesper", postgresBinDir: "/x/pg" },
    userDataDir: "/data",
    secretsKey: "k",
    runnerSlots: 6,
  };
  assert.equal(buildStackEnv(opts, "127.0.0.1:8080", {}).RUNNER_MAX_CONCURRENT, "6");
  const unset = buildStackEnv({ ...opts, runnerSlots: undefined }, "127.0.0.1:8080", {});
  assert.equal("RUNNER_MAX_CONCURRENT" in unset, false);
  assert.equal(buildStackEnv(opts, "127.0.0.1:8080", { RUNNER_MAX_CONCURRENT: "9" }).RUNNER_MAX_CONCURRENT, "9");
  assert.equal(buildStackEnv(opts, "127.0.0.1:8080", { RUNNER_MAX_CONCURRENT: "  " }).RUNNER_MAX_CONCURRENT, "6");
});
