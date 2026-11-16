import { execFile, spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

export type DockerRuntime = "orbstack" | "docker" | "none";

export interface DockerStatus {
  available: boolean;
  runtime: DockerRuntime;
  detail?: string;
}

export function isLocalhostUrl(serverUrl: string): boolean {
  try {
    const parsed = new URL(serverUrl);
    const host = parsed.hostname.toLowerCase();
    return host === "localhost" || host === "127.0.0.1" || host === "::1" || host === "[::1]" || host.endsWith(".localhost");
  } catch {
    return false;
  }
}

export function isValidVesperCheckout(dirPath: string | undefined): boolean {
  if (!dirPath) return false;
  const trimmed = dirPath.trim();
  if (!trimmed) return false;
  try {
    const stat = fs.statSync(trimmed);
    if (!stat.isDirectory()) return false;
    return (
      fs.existsSync(path.join(trimmed, "docker-compose.yml")) ||
      fs.existsSync(path.join(trimmed, "compose.yml"))
    );
  } catch {
    return false;
  }
}

/**
 * macOS GUI apps launched from Finder/Dock do not inherit the interactive shell's PATH.
 * Include Homebrew, OrbStack, and Docker Desktop binary directories so `docker` resolves.
 */
export function augmentedDockerEnv(baseEnv: NodeJS.ProcessEnv = process.env): NodeJS.ProcessEnv {
  const home = os.homedir();
  const extraDirs = [
    "/opt/homebrew/bin",
    "/usr/local/bin",
    path.join(home, ".orbstack", "bin"),
    "/Applications/OrbStack.app/Contents/MacOS/xbin",
    "/Applications/Docker.app/Contents/Resources/bin",
  ];
  const currentPath = baseEnv.PATH ?? "";
  const existing = currentPath.split(path.delimiter).filter(Boolean);
  const merged = [...existing];
  for (const dir of extraDirs) {
    if (!merged.includes(dir)) merged.push(dir);
  }
  return {
    ...baseEnv,
    PATH: merged.join(path.delimiter),
  };
}

export function checkDockerAvailability(env: NodeJS.ProcessEnv = augmentedDockerEnv()): Promise<DockerStatus> {
  return new Promise((resolve) => {
    execFile(
      "docker",
      ["info", "--format", "{{.Name}} {{.OperatingSystem}}"],
      { env, timeout: 4000 },
      (error, stdout, stderr) => {
        if (error) {
          resolve({
            available: false,
            runtime: "none",
            detail: (stderr || error.message || "Docker is unavailable").trim(),
          });
          return;
        }
        const info = `${stdout} ${stderr}`.toLowerCase();
        const isOrbStack = info.includes("orbstack") || (env.DOCKER_HOST ?? "").toLowerCase().includes("orbstack");
        resolve({
          available: true,
          runtime: isOrbStack ? "orbstack" : "docker",
          detail: stdout.trim() || undefined,
        });
      },
    );
  });
}

export function startLocalComposeStack(
  checkoutPath: string,
  onLog: (chunk: string) => void,
  env: NodeJS.ProcessEnv = augmentedDockerEnv(),
): Promise<{ ok: boolean; error?: string }> {
  if (!isValidVesperCheckout(checkoutPath)) {
    return Promise.resolve({
      ok: false,
      error: "Selected folder does not contain docker-compose.yml.",
    });
  }

  return new Promise((resolve) => {
    const child = spawn("docker", ["compose", "up", "-d"], {
      cwd: checkoutPath,
      env,
      stdio: ["ignore", "pipe", "pipe"],
    });

    child.stdout.on("data", (buf: Buffer) => onLog(buf.toString("utf8")));
    child.stderr.on("data", (buf: Buffer) => onLog(buf.toString("utf8")));

    child.on("error", (err) => {
      resolve({ ok: false, error: err.message });
    });

    child.on("close", (code) => {
      if (code === 0) {
        resolve({ ok: true });
      } else {
        resolve({ ok: false, error: `docker compose up -d exited with code ${code ?? "unknown"}` });
      }
    });
  });
}
