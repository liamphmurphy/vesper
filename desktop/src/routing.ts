import { DEFAULT_PLAYGROUND_PORTS } from "./config";

export type NavigationKind = "vesper" | "playground" | "external" | "ignore";

function effectivePort(url: URL): number {
  if (url.port) return Number(url.port);
  return url.protocol === "https:" ? 443 : 80;
}

function sameHost(a: string, b: string): boolean {
  const norm = (h: string) => (h === "127.0.0.1" || h === "::1" || h === "[::1]" ? "localhost" : h.toLowerCase());
  return norm(a) === norm(b);
}

/**
 * Classifies a link or navigation URL relative to the configured Vesper server:
 * - "vesper": same origin as serverUrl -> stays in Electron / opens Vesper tab
 * - "playground": matching host on a configured Playground port (8090–8094) -> opens Electron tab
 * - "external": other http/https/mailto URLs -> open in default macOS browser
 * - "ignore": about:blank, javascript:, data:, etc.
 */
export function classifyNavigation(
  targetUrl: string,
  serverUrl: string,
  playgroundPorts: readonly number[] = DEFAULT_PLAYGROUND_PORTS,
): NavigationKind {
  if (!targetUrl) return "ignore";
  let target: URL;
  let server: URL;
  try {
    target = new URL(targetUrl);
    server = new URL(serverUrl);
  } catch {
    return "ignore";
  }

  if (target.protocol === "mailto:") {
    return "external";
  }
  if (target.protocol !== "http:" && target.protocol !== "https:") {
    return "ignore";
  }

  if (target.origin === server.origin) {
    return "vesper";
  }

  if (sameHost(target.hostname, server.hostname) && playgroundPorts.includes(effectivePort(target))) {
    return "playground";
  }

  return "external";
}

/**
 * Strips redundant trailing " · Vesper" or " - Vesper" suffixes so narrow macOS
 * window tabs remain readable while preserving "Vesper" itself when standalone.
 */
export function cleanTabTitle(rawTitle: string | null | undefined): string {
  const normalized = (rawTitle ?? "").replace(/\s+/g, " ").trim();
  if (!normalized || normalized === "Vesper") return "Vesper";
  const stripped = normalized.replace(/\s*(?:·|-|—)\s*Vesper$/i, "").trim();
  return stripped || "Vesper";
}

export class ClosedTabStack {
  private readonly stack: string[] = [];
  private readonly maxItems: number;

  constructor(maxItems = 25) {
    this.maxItems = maxItems;
  }

  push(url: string): void {
    const trimmed = url.trim();
    if (!trimmed || trimmed.startsWith("file://") || trimmed === "about:blank") return;
    if (this.stack[this.stack.length - 1] === trimmed) return;
    this.stack.push(trimmed);
    if (this.stack.length > this.maxItems) {
      this.stack.shift();
    }
  }

  pop(): string | undefined {
    return this.stack.pop();
  }

  get size(): number {
    return this.stack.length;
  }

  peek(): string | undefined {
    return this.stack[this.stack.length - 1];
  }
}
