import fs from "node:fs";
import path from "node:path";

export const DEFAULT_SERVER_URL = "http://localhost:8080";
export const DEFAULT_PLAYGROUND_PORTS = [8090, 8091, 8092, 8093, 8094] as const;

export interface DesktopConfig {
  serverUrl: string;
  localCheckoutPath?: string;
  playgroundPorts: number[];
}

export function defaultConfig(): DesktopConfig {
  return {
    serverUrl: DEFAULT_SERVER_URL,
    playgroundPorts: [...DEFAULT_PLAYGROUND_PORTS],
  };
}

/**
 * Validates and normalizes a user-supplied Vesper server URL.
 * Accepts http:// or https:// URLs (or bare host[:port] values, which default to http://).
 */
export function normalizeServerUrl(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) {
    throw new Error("Server URL cannot be empty.");
  }

  const hasScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:/.test(trimmed);
  const candidate = hasScheme ? trimmed : `http://${trimmed}`;

  let parsed: URL;
  try {
    parsed = new URL(candidate);
  } catch {
    throw new Error("Enter a valid http:// or https:// URL.");
  }

  if (parsed.protocol !== "http:" && parsed.protocol !== "https:") {
    throw new Error("Server URL must use http:// or https://.");
  }
  if (!parsed.hostname) {
    throw new Error("Server URL must include a hostname.");
  }

  const cleanPath = parsed.pathname.replace(/\/+$/, "");
  return cleanPath ? `${parsed.origin}${cleanPath}` : parsed.origin;
}

export function normalizePlaygroundPorts(ports: unknown): number[] {
  if (!Array.isArray(ports)) return [...DEFAULT_PLAYGROUND_PORTS];
  const valid = ports
    .map((p) => (typeof p === "number" ? p : Number(p)))
    .filter((p) => Number.isInteger(p) && p >= 1 && p <= 65535);
  return valid.length > 0 ? Array.from(new Set(valid)) : [...DEFAULT_PLAYGROUND_PORTS];
}

export function loadConfig(configPath: string): DesktopConfig {
  const defaults = defaultConfig();
  try {
    const raw = fs.readFileSync(configPath, "utf8");
    const parsed = JSON.parse(raw) as Partial<DesktopConfig> | null;
    if (!parsed || typeof parsed !== "object") return defaults;

    let serverUrl = defaults.serverUrl;
    if (typeof parsed.serverUrl === "string") {
      try {
        serverUrl = normalizeServerUrl(parsed.serverUrl);
      } catch {
        serverUrl = defaults.serverUrl;
      }
    }

    const localCheckoutPath =
      typeof parsed.localCheckoutPath === "string" && parsed.localCheckoutPath.trim()
        ? parsed.localCheckoutPath.trim()
        : undefined;

    return {
      serverUrl,
      localCheckoutPath,
      playgroundPorts: normalizePlaygroundPorts(parsed.playgroundPorts),
    };
  } catch {
    return defaults;
  }
}

export function saveConfig(configPath: string, config: DesktopConfig): void {
  const dir = path.dirname(configPath);
  fs.mkdirSync(dir, { recursive: true });
  const tmpPath = `${configPath}.tmp-${process.pid}`;
  const clean: DesktopConfig = {
    serverUrl: normalizeServerUrl(config.serverUrl),
    ...(config.localCheckoutPath?.trim() ? { localCheckoutPath: config.localCheckoutPath.trim() } : {}),
    playgroundPorts: normalizePlaygroundPorts(config.playgroundPorts),
  };
  fs.writeFileSync(tmpPath, `${JSON.stringify(clean, null, 2)}\n`, "utf8");
  fs.renameSync(tmpPath, configPath);
}
