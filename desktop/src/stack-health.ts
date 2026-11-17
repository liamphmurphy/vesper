import fs from "node:fs";

/**
 * Health of the embedded `vesper app` stack (LAZYAGENTS-246), derived from
 * what the desktop can observe: the platform, the child process, its start
 * error or exit, free disk space, GET /api/v1/system/vm-image and
 * GET /api/v1/runner. Pure, so every state has a unit test.
 */

export type StackPhase = "remote" | "starting" | "downloading" | "running" | "degraded" | "error" | "stopped";

export type StackAction = "restart" | "logs" | "retry" | "settings" | "storage";

export interface RootfsStatus {
  state: "checking" | "downloading" | "ready" | "error";
  downloadedBytes?: number;
  totalBytes?: number;
  error?: string;
}

export interface StackHealthInput {
  /** local: bundled `vesper app`; remote: a server URL off this Mac; external: localhost served by something else (dev/Docker). */
  mode: "local" | "remote" | "external";
  platform: string;
  arch: string;
  /** Darwin kernel major (os.release()), e.g. 24 for macOS 15. */
  darwinMajor?: number;
  starting: boolean;
  processRunning: boolean;
  startError?: string;
  exit?: { code: number | null; signal: string | null; stderrTail?: string };
  freeDiskBytes?: number;
  minFreeDiskGb: number;
  image?: RootfsStatus;
  runnerOnline?: boolean;
  reachable?: boolean;
}

export interface StackHealth {
  phase: StackPhase;
  title: string;
  message: string;
  nextStep: string;
  actions: StackAction[];
  progress?: { done: number; total: number };
}

/** macOS 15 (Darwin 24) on Apple Silicon is the microVM runner's floor (docs/dev/microvm-architecture.md, Scope). */
export const MIN_DARWIN_MAJOR = 24;
const GB = 1024 ** 3;

export function darwinMajor(release: string): number | undefined {
  const n = Number.parseInt(release.split(".")[0] ?? "", 10);
  return Number.isFinite(n) ? n : undefined;
}

export function formatBytes(n: number): string {
  if (!Number.isFinite(n) || n < 0) return "?";
  if (n >= GB) return `${(n / GB).toFixed(1)} GB`;
  if (n >= 1024 ** 2) return `${Math.round(n / 1024 ** 2)} MB`;
  return `${Math.round(n / 1024)} KB`;
}

interface Classified {
  title: string;
  message: string;
  nextStep: string;
}

/** Turns a start error or crash output into a named failure with a next step. */
export function classifyStackError(text: string): Classified {
  const t = text || "";
  if (/virtualization|VZErrorDomain|com\.apple\.security\.virtualization|hypervisor/i.test(t)) {
    return {
      title: "Virtualization unavailable",
      message: "macOS refused to start a virtual machine for runs.",
      nextStep:
        "Vesper needs Apple Silicon with macOS 15 or later. A self-built app must sign bin/vesper with deploy/microvm/vz.entitlements (make desktop-dmg does this).",
    };
  }
  if (/ENOSPC|no space left/i.test(t)) {
    return {
      title: "Disk full",
      message: "The data directory ran out of space.",
      nextStep: "Free up disk space, then restart the stack.",
    };
  }
  if (/address already in use|EADDRINUSE|bind: /i.test(t)) {
    return {
      title: "Port in use",
      message: "Another program is using Vesper's local port.",
      nextStep: "Quit the other program (or another Vesper), then restart the stack.",
    };
  }
  if (/SECRETS_KEY|safeStorage|Keychain/i.test(t)) {
    return {
      title: "Keychain key unavailable",
      message: "Vesper couldn't read its secrets key from the macOS Keychain.",
      nextStep: "Unlock the login keychain and allow Vesper access when macOS asks, then restart the stack.",
    };
  }
  if (/embedded postgres|postgres|initdb|pg_ctl/i.test(t)) {
    return {
      title: "Database didn't start",
      message: "The bundled Postgres failed to start.",
      nextStep: "Open the logs to see why. If another Vesper is running, quit it first.",
    };
  }
  if (/Timed out waiting/i.test(t)) {
    return {
      title: "Stack is slow to start",
      message: "vesper app didn't report ready within 30 seconds.",
      nextStep: "Restart the stack; if it keeps timing out, open the logs.",
    };
  }
  return {
    title: "Stack stopped",
    message: "The local Vesper stack exited unexpectedly.",
    nextStep: "Restart the stack. If it keeps stopping, open the logs.",
  };
}

export function deriveStackHealth(input: StackHealthInput): StackHealth {
  if (input.mode === "remote" || input.mode === "external") {
    const where = input.mode === "remote" ? "the remote server" : "the local server";
    return input.reachable === false
      ? {
          phase: "error",
          title: "Server unreachable",
          message: `Vesper can't reach ${where}.`,
          nextStep: "Check the server, or change the Server URL in Settings.",
          actions: ["retry", "settings"],
        }
      : { phase: "remote", title: "Connected", message: `Using ${where}.`, nextStep: "", actions: ["settings"] };
  }

  if (input.platform !== "darwin" || input.arch !== "arm64" || (input.darwinMajor !== undefined && input.darwinMajor < MIN_DARWIN_MAJOR)) {
    return {
      phase: "error",
      title: "Virtualization unavailable",
      message: "This Mac can't run Vesper's microVMs.",
      nextStep: "The built-in stack needs Apple Silicon with macOS 15 or later. You can still connect to a remote Vesper in Settings.",
      actions: ["settings"],
    };
  }

  const lowDisk = input.freeDiskBytes !== undefined && input.freeDiskBytes < input.minFreeDiskGb * GB;

  if (input.startError || (input.exit && !input.processRunning && !input.starting)) {
    const c = classifyStackError(`${input.startError ?? ""}\n${input.exit?.stderrTail ?? ""}`);
    const lowDiskOverride = lowDisk && c.title === "Stack stopped";
    return {
      phase: "error",
      title: lowDiskOverride ? "Disk almost full" : c.title,
      message: lowDiskOverride ? `Only ${formatBytes(input.freeDiskBytes!)} free in the data directory.` : c.message,
      nextStep: lowDiskOverride ? "Free up disk space, then restart the stack." : c.nextStep,
      actions: lowDiskOverride ? ["restart", "storage", "logs"] : ["restart", "logs"],
    };
  }

  if (input.starting) {
    return { phase: "starting", title: "Starting Vesper…", message: "Starting the database, server and runner.", nextStep: "", actions: ["logs"] };
  }

  if (!input.processRunning) {
    return { phase: "stopped", title: "Stack stopped", message: "The local Vesper stack isn't running.", nextStep: "Start it again.", actions: ["restart", "logs"] };
  }

  if (input.image?.state === "downloading") {
    const done = input.image.downloadedBytes ?? 0;
    const total = input.image.totalBytes ?? 0;
    return {
      phase: "downloading",
      title: "Downloading the run image",
      message:
        total > 0
          ? `${formatBytes(done)} of ${formatBytes(total)}. Runs start once it's done.`
          : `${formatBytes(done)} so far. Runs start once it's done.`,
      nextStep: "This happens once, on first launch.",
      actions: ["logs"],
      progress: { done, total },
    };
  }

  if (input.image?.state === "error") {
    return {
      phase: "degraded",
      title: "Run image unavailable",
      message: `Chats and runs can't start: ${input.image.error || "the agent image couldn't be prepared"}.`,
      nextStep: /VESPER_ROOTFS_URL/.test(input.image.error ?? "")
        ? "Build it with deploy/microvm/build-images.sh, or set VESPER_ROOTFS_URL, then restart the stack."
        : "Check your connection and disk space, then restart the stack.",
      actions: ["restart", "logs"],
    };
  }

  if (lowDisk) {
    return {
      phase: "degraded",
      title: "Disk almost full",
      message: `Only ${formatBytes(input.freeDiskBytes!)} free in the data directory (warning below ${input.minFreeDiskGb} GB).`,
      nextStep: "Free up disk space before starting more runs.",
      actions: ["storage", "logs"],
    };
  }

  if (input.runnerOnline === false) {
    return {
      phase: "degraded",
      title: "Runner offline",
      message: "The server is up but its runner isn't, so runs won't start.",
      nextStep: "Restart the stack. If it stays offline, open the logs.",
      actions: ["restart", "logs"],
    };
  }

  return { phase: "running", title: "Vesper is running", message: "", nextStep: "", actions: ["logs"] };
}

/** Tray icon state for a stack phase. */
export function trayIconState(phase: StackPhase): "running" | "starting" | "error" {
  if (phase === "running" || phase === "remote") return "running";
  if (phase === "starting" || phase === "downloading" || phase === "stopped") return "starting";
  return "error";
}

/** Auto-restart guard: at most `max` restarts within `windowMs`. */
export function shouldAutoRestart(restartTimes: readonly number[], now: number, max = 3, windowMs = 10 * 60_000): boolean {
  return restartTimes.filter((t) => now - t < windowMs).length < max;
}

/** The last `maxBytes` of a log file, starting at a line boundary. Empty when missing. */
export function readLogTail(filePath: string, maxBytes = 64 * 1024): string {
  let fd: number | undefined;
  try {
    const size = fs.statSync(filePath).size;
    const start = Math.max(0, size - maxBytes);
    const buf = Buffer.alloc(size - start);
    fd = fs.openSync(filePath, "r");
    fs.readSync(fd, buf, 0, buf.length, start);
    const text = buf.toString("utf8");
    if (start === 0) return text;
    const nl = text.indexOf("\n");
    return nl >= 0 ? text.slice(nl + 1) : text;
  } catch {
    return "";
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

export function freeDiskBytes(dir: string): number | undefined {
  try {
    const s = fs.statfsSync(dir);
    return Number(s.bavail) * Number(s.bsize);
  } catch {
    return undefined;
  }
}
