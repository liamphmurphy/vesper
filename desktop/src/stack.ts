import { execFile, spawn, type ChildProcess } from "node:child_process";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);

export interface SafeStorageLike {
  isEncryptionAvailable(): boolean;
  encryptString(plainText: string): Buffer;
  decryptString(encrypted: Buffer): string;
}

export interface SessionFetchResponse {
  ok: boolean;
  status: number;
  json(): Promise<unknown>;
  body?: { cancel?: () => Promise<void> | void } | null;
}

export type SessionFetchLike = (url: string, init?: RequestInit) => Promise<SessionFetchResponse>;

export interface BundledResources {
  vesperBin: string;
  postgresBinDir: string;
  kernelPath?: string;
  webDistDir?: string;
}

export function resolveBundledResources(baseDir: string): BundledResources | null {
  if (!baseDir) return null;
  const vesperBin = path.join(baseDir, "bin", "vesper");
  const postgresBin = path.join(baseDir, "postgres", "bin", "postgres");
  if (!fs.existsSync(vesperBin) || !fs.existsSync(postgresBin)) {
    return null;
  }
  const kernelCandidate = path.join(baseDir, "images", "vmlinux");
  const webCandidate = path.join(baseDir, "web");
  return {
    vesperBin,
    postgresBinDir: path.join(baseDir, "postgres", "bin"),
    ...(fs.existsSync(kernelCandidate) ? { kernelPath: kernelCandidate } : {}),
    ...(fs.existsSync(path.join(webCandidate, "server.js")) ? { webDistDir: webCandidate } : {}),
  };
}

export function ensureSecretsKey(userDataDir: string, storage: SafeStorageLike): string {
  const keyPath = path.join(userDataDir, "secrets-key.enc");
  if (!storage.isEncryptionAvailable()) {
    throw new Error("macOS Keychain safeStorage encryption is unavailable.");
  }
  if (fs.existsSync(keyPath)) {
    const enc = fs.readFileSync(keyPath);
    const decrypted = storage.decryptString(enc).trim();
    if (decrypted) return decrypted;
  }
  const generated = crypto.randomBytes(32).toString("base64");
  writeEncryptedSecretsKey(keyPath, storage, generated);
  return generated;
}

export function validateSecretsKeyFormat(plainKey: string): string {
  const trimmed = plainKey.trim();
  if (!/^[A-Za-z0-9+/=]+$/.test(trimmed) || trimmed.length % 4 !== 0) {
    throw new Error("SECRETS_KEY must be a 32-byte base64 string.");
  }
  const decoded = Buffer.from(trimmed, "base64");
  if (decoded.length !== 32) {
    throw new Error("SECRETS_KEY must be a 32-byte base64 string.");
  }
  return trimmed;
}

export function saveSecretsKey(userDataDir: string, storage: SafeStorageLike, plainKey: string): string {
  if (!storage.isEncryptionAvailable()) {
    throw new Error("macOS Keychain safeStorage encryption is unavailable.");
  }
  const validated = validateSecretsKeyFormat(plainKey);
  const keyPath = path.join(userDataDir, "secrets-key.enc");
  writeEncryptedSecretsKey(keyPath, storage, validated);
  return validated;
}

function writeEncryptedSecretsKey(keyPath: string, storage: SafeStorageLike, plainKey: string): void {
  const enc = storage.encryptString(plainKey);
  fs.mkdirSync(path.dirname(keyPath), { recursive: true });
  const tmpPath = `${keyPath}.tmp-${process.pid}`;
  fs.writeFileSync(tmpPath, enc, { mode: 0o600 });
  fs.renameSync(tmpPath, keyPath);
}

export interface BackupInspection {
  exportedAt: string;
  appVersion: string;
  schemaVersion: number;
  tableCount: number;
  totalRows: number;
  objectCount: number;
  secretsKeyFingerprint?: string;
  encryptedSecretRows: number;
  matchesCurrentKey: boolean;
}

function extractVesperCliError(err: unknown): string {
  const rec = err as { stdout?: string; stderr?: string; message?: string };
  const combined = `${rec?.stdout ?? ""}\n${rec?.stderr ?? ""}`;
  for (const line of combined.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed.startsWith("{")) continue;
    try {
      const parsed = JSON.parse(trimmed) as { err?: string; error?: string };
      if (parsed.err) return parsed.err;
      if (parsed.error) return parsed.error;
    } catch {
      // Ignore non-JSON log lines.
    }
  }
  const stderr = (rec?.stderr ?? "").trim();
  if (stderr) return stderr;
  return err instanceof Error ? err.message : String(err);
}

export async function inspectBackupArchive(opts: {
  vesperBin: string;
  archivePath: string;
  currentSecretsKey?: string;
}): Promise<BackupInspection> {
  try {
    const { stdout } = await execFileAsync(opts.vesperBin, ["app-import", "-inspect", opts.archivePath], {
      env: {
        ...process.env,
        SECRETS_KEY: opts.currentSecretsKey?.trim() ?? "",
      },
      timeout: 30000,
      maxBuffer: 4 * 1024 * 1024,
    });
    return JSON.parse(stdout) as BackupInspection;
  } catch (err) {
    throw new Error(extractVesperCliError(err));
  }
}

export async function runAppImportArchive(opts: {
  resources: BundledResources;
  userDataDir: string;
  archivePath: string;
  secretsKey?: string;
  dropSecrets?: boolean;
}): Promise<void> {
  const args = ["app-import", "-data-dir", opts.userDataDir];
  if (opts.dropSecrets) {
    args.push("-drop-secrets");
  }
  args.push(opts.archivePath);

  const env: NodeJS.ProcessEnv = {
    ...process.env,
    VESPER_POSTGRES_BIN_DIR: opts.resources.postgresBinDir,
    SECRETS_KEY: opts.dropSecrets ? "" : (opts.secretsKey?.trim() ?? ""),
  };
  delete env.VESPER_NO_SIGNIN;

  try {
    await execFileAsync(opts.resources.vesperBin, args, {
      env,
      timeout: 15 * 60 * 1000,
      maxBuffer: 16 * 1024 * 1024,
    });
  } catch (err) {
    throw new Error(extractVesperCliError(err));
  }
}

export interface LocalStackOptions {
  resources: BundledResources;
  userDataDir: string;
  secretsKey: string;
  port?: number;
  nodeBin?: string;
  nodeRunAsNode?: boolean;
  onLog?: (line: string) => void;
  /** Called when the process exits without stop() having been called (a crash). */
  onUnexpectedExit?: (exit: StackExit) => void;
  /**
   * Where to download agent-base.erofs on first launch when it isn't on this
   * Mac: this build's GitHub release asset. VESPER_ROOTFS_URL in the
   * environment still wins.
   */
  rootfsUrl?: string;
}

export interface StackExit {
  code: number | null;
  signal: string | null;
  stderrTail: string;
}

/** The environment `vesper app` runs with. */
export function buildStackEnv(opts: LocalStackOptions, addr: string, base: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const env: NodeJS.ProcessEnv = {
    ...base,
    SECRETS_KEY: opts.secretsKey,
    VESPER_APP_DATA_DIR: opts.userDataDir,
    VESPER_APP_ADDR: addr,
    VESPER_POSTGRES_BIN_DIR: opts.resources.postgresBinDir,
    ...(opts.resources.kernelPath ? { VESPER_KERNEL_PATH: opts.resources.kernelPath } : {}),
    ...(opts.resources.webDistDir ? { VESPER_WEB_DIST_DIR: opts.resources.webDistDir } : {}),
    ...(opts.nodeBin ? { VESPER_NODE_BIN: opts.nodeBin } : {}),
    ...(opts.nodeRunAsNode ? { VESPER_NODE_RUN_AS_NODE: "1" } : {}),
    ...(opts.rootfsUrl && !base.VESPER_ROOTFS_URL?.trim() ? { VESPER_ROOTFS_URL: opts.rootfsUrl } : {}),
  };
  delete env.VESPER_NO_SIGNIN;
  return env;
}

export class LocalVesperStack {
  private readonly opts: LocalStackOptions;
  private proc: ChildProcess | null = null;
  private stopping = false;
  private readyUrlValue = "";
  private exitPromise: Promise<void> | null = null;
  private stderrTail = "";
  private lastExitValue: StackExit | null = null;

  constructor(opts: LocalStackOptions) {
    this.opts = opts;
  }

  isRunning(): boolean {
    return this.proc !== null && this.proc.exitCode === null;
  }

  readyUrl(): string {
    return this.readyUrlValue;
  }

  /** How the process last ended, or null if it hasn't since the last start. */
  lastExit(): StackExit | null {
    return this.lastExitValue;
  }

  async start(): Promise<string> {
    if (this.isRunning() && this.readyUrlValue) {
      return this.readyUrlValue;
    }
    this.stopping = false;
    this.stderrTail = "";
    this.lastExitValue = null;
    this.readyUrlValue = "";

    const logsDir = path.join(this.opts.userDataDir, "logs");
    fs.mkdirSync(logsDir, { recursive: true });
    const logStream = fs.createWriteStream(path.join(logsDir, "vesper-app.log"), { flags: "a" });

    const port = this.opts.port ?? 8080;
    const addr = `127.0.0.1:${port}`;
    const env = buildStackEnv(this.opts, addr);

    const child = spawn(this.opts.resources.vesperBin, ["app", "-data-dir", this.opts.userDataDir, "-addr", addr], {
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });
    this.proc = child;
    this.exitPromise = new Promise((resolve) => {
      child.once("exit", (code, signal) => {
        logStream.end();
        this.proc = null;
        this.lastExitValue = { code, signal, stderrTail: this.stderrTail };
        if (!this.stopping && this.readyUrlValue) {
          // Only after a successful start; a failed start rejects start() instead.
          this.opts.onUnexpectedExit?.(this.lastExitValue);
        }
        resolve();
      });
    });

    const emitLog = (chunk: Buffer) => {
      const text = chunk.toString("utf8");
      logStream.write(text);
      if (this.opts.onLog) {
        this.opts.onLog(text);
      }
    };

    const ready = await new Promise<string>((resolve, reject) => {
      let stdoutBuf = "";
      let stderrTail = "";
      const timer = setTimeout(() => {
        reject(new Error(`Timed out waiting for vesper app to start.\n${stderrTail}`));
      }, 30000);

      child.stdout?.on("data", (buf: Buffer) => {
        emitLog(buf);
        stdoutBuf += buf.toString("utf8");
        const match = /^VESPER_READY_URL=(http:\/\/\S+)$/m.exec(stdoutBuf);
        if (match) {
          clearTimeout(timer);
          resolve(match[1]);
        }
      });

      child.stderr?.on("data", (buf: Buffer) => {
        emitLog(buf);
        stderrTail = (stderrTail + buf.toString("utf8")).slice(-4096);
        this.stderrTail = stderrTail;
      });

      child.once("error", (err) => {
        clearTimeout(timer);
        reject(err);
      });

      child.once("exit", (code, signal) => {
        clearTimeout(timer);
        if (!this.stopping) {
          reject(new Error(`vesper app exited unexpectedly (${code ?? signal}): ${stderrTail.trim()}`));
        }
      });
    });

    this.readyUrlValue = ready;
    return ready;
  }

  async stop(): Promise<void> {
    this.stopping = true;
    const child = this.proc;
    if (!child || child.exitCode !== null) {
      return;
    }
    child.kill("SIGTERM");
    await Promise.race([
      this.exitPromise ?? Promise.resolve(),
      new Promise<void>((resolve) => setTimeout(resolve, 10000)),
    ]);
    if (this.proc && this.proc.exitCode === null) {
      this.proc.kill("SIGKILL");
      await Promise.race([
        this.exitPromise ?? Promise.resolve(),
        new Promise<void>((resolve) => setTimeout(resolve, 2000)),
      ]);
    }
  }
}

export async function ensureAuthenticatedSession(opts: {
  serverUrl: string;
  vesperBin: string;
  runtimeJsonPath: string;
  fetch: SessionFetchLike;
}): Promise<{ signedIn: boolean; minted: boolean }> {
  const res = await opts.fetch(`${opts.serverUrl}/api/v1/inbox`, {
    method: "GET",
    signal: AbortSignal.timeout(4000),
  });
  void res.body?.cancel?.();
  if (res.status !== 401) {
    return { signedIn: res.ok, minted: false };
  }

  const raw = fs.readFileSync(opts.runtimeJsonPath, "utf8");
  const parsed = JSON.parse(raw) as { databaseUrl?: string };
  if (!parsed.databaseUrl) {
    throw new Error(`Missing databaseUrl in ${opts.runtimeJsonPath}`);
  }

  const { stdout } = await execFileAsync(opts.vesperBin, ["sign-in-link", "-code"], {
    env: {
      ...process.env,
      DATABASE_URL: parsed.databaseUrl,
    },
    timeout: 10000,
  });
  const code = stdout.trim();
  if (!code) {
    throw new Error("vesper sign-in-link returned an empty code");
  }

  const redeem = await opts.fetch(`${opts.serverUrl}/api/v1/sign-in?code=${encodeURIComponent(code)}`, {
    method: "GET",
    redirect: "manual",
    signal: AbortSignal.timeout(5000),
  });
  void redeem.body?.cancel?.();
  return { signedIn: true, minted: true };
}

export async function hasActiveRuns(serverUrl: string, fetchFn: SessionFetchLike): Promise<boolean> {
  try {
    const res = await fetchFn(`${serverUrl}/api/v1/runs?state=running`, {
      method: "GET",
      signal: AbortSignal.timeout(1500),
    });
    if (!res.ok) {
      void res.body?.cancel?.();
      return false;
    }
    const data = (await res.json()) as { runs?: unknown[] };
    return Array.isArray(data?.runs) && data.runs.length > 0;
  } catch {
    return false;
  }
}
