import fs from "node:fs";
import path from "node:path";

export const DEFAULT_SERVER_URL = "http://localhost:8080";
export const DEFAULT_PLAYGROUND_PORTS = [8090, 8091, 8092, 8093, 8094] as const;

export interface DesktopConfig {
  serverUrl: string;
  localCheckoutPath?: string;
  playgroundPorts: number[];
}

export interface WindowBounds {
  x?: number;
  y?: number;
  width: number;
  height: number;
  isMaximized?: boolean;
}

export interface SessionState {
  tabs: string[];
  activeIndex: number;
  bounds?: WindowBounds;
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

  if (/^(javascript|data|vbscript|file|mailto|ftp):/i.test(trimmed)) {
    throw new Error("Server URL must use http:// or https://.");
  }

  const hasScheme = /^[a-zA-Z][a-zA-Z0-9+.-]*:\/\//.test(trimmed);
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

export function defaultSession(): SessionState {
  return { tabs: [], activeIndex: 0 };
}

export function loadSession(sessionPath: string): SessionState {
  try {
    const raw = fs.readFileSync(sessionPath, "utf8");
    const parsed = JSON.parse(raw) as Partial<SessionState> | null;
    if (!parsed || typeof parsed !== "object") return defaultSession();

    const tabs = Array.isArray(parsed.tabs)
      ? parsed.tabs.filter((t): t is string => {
          if (typeof t !== "string") return false;
          try {
            const u = new URL(t);
            return u.protocol === "http:" || u.protocol === "https:";
          } catch {
            return false;
          }
        })
      : [];

    const activeIndex =
      typeof parsed.activeIndex === "number" && Number.isInteger(parsed.activeIndex) && parsed.activeIndex >= 0
        ? Math.min(parsed.activeIndex, Math.max(0, tabs.length - 1))
        : 0;

    let bounds: WindowBounds | undefined;
    if (parsed.bounds && typeof parsed.bounds === "object") {
      const b = parsed.bounds;
      if (typeof b.width === "number" && b.width >= 400 && typeof b.height === "number" && b.height >= 300) {
        bounds = {
          width: Math.round(b.width),
          height: Math.round(b.height),
          ...(typeof b.x === "number" ? { x: Math.round(b.x) } : {}),
          ...(typeof b.y === "number" ? { y: Math.round(b.y) } : {}),
          ...(typeof b.isMaximized === "boolean" ? { isMaximized: b.isMaximized } : {}),
        };
      }
    }

    return { tabs, activeIndex, bounds };
  } catch {
    return defaultSession();
  }
}

export function saveSession(sessionPath: string, sessionState: SessionState): void {
  const dir = path.dirname(sessionPath);
  fs.mkdirSync(dir, { recursive: true });
  const tmpPath = `${sessionPath}.tmp-${process.pid}`;
  fs.writeFileSync(tmpPath, `${JSON.stringify(sessionState, null, 2)}\n`, "utf8");
  fs.renameSync(tmpPath, sessionPath);
}
