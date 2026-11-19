// Pure helpers for sandboxed Custom Apps: slug checks, srcDoc CSP wrapper, postMessage bridge parsing,
// and dock chat context formatting. Kept free of React/DOM imports so Node unit tests cover it directly.

import { CUSTOM_APP_CONTEXT_MARKER } from "./chat-context.ts";

export const RESERVED_CUSTOM_APP_SLUGS = new Set(["new", "api", "slides", "designs", "docs"]);

export const CUSTOM_APP_ICONS = [
  "dashboard",
  "dollar",
  "board",
  "graph",
  "bolt",
  "compass",
  "briefcase",
  "server",
  "clock",
  "tickets",
  "gamepad",
  "dice",
] as const;

export type CustomAppIcon = (typeof CUSTOM_APP_ICONS)[number];

export type CustomAppNavSpec = { id: string; label: string; icon?: string };

// Theme variables apps can use (key), read from the Vesper token that supplies each (value).
// Apps see the conventional --fg names; Vesper's tokens call text colors --text*. A key whose
// token is missing would reach apps empty and silently fall back to the app's own default.
export const THEME_VARS = {
  "--bg": "--bg",
  "--surface": "--surface",
  "--surface-raised": "--surface-raised",
  "--surface-sunken": "--surface-sunken",
  "--fg": "--text",
  "--fg-2": "--text-2",
  "--fg-secondary": "--text-secondary",
  "--fg-tertiary": "--text-tertiary",
  "--border": "--border",
  "--border-subtle": "--border-subtle",
  "--border-strong": "--border-strong",
  "--accent": "--accent",
  "--accent-soft": "--accent-soft",
  "--on-accent": "--text-on-accent",
  "--hover": "--hover",
  "--selected": "--selected",
  "--font-sans": "--font-sans",
  "--font-mono": "--font-mono",
} as const satisfies Record<string, string>;

// Resolves THEME_VARS against the host; getValue is getComputedStyle(...).getPropertyValue in the browser.
export function readThemeVarsFrom(getValue: (hostVar: string) => string): Record<string, string> {
  const vars: Record<string, string> = {};
  for (const [appVar, hostVar] of Object.entries(THEME_VARS)) {
    const val = getValue(hostVar).trim();
    if (val) vars[appVar] = val;
  }
  return vars;
}

const SLUG_RE = /^[a-z0-9][a-z0-9-]{0,47}$/;

export function resolveAppIcon(icon?: string): CustomAppIcon {
  if (icon && (CUSTOM_APP_ICONS as readonly string[]).includes(icon)) {
    return icon as CustomAppIcon;
  }
  return "dashboard";
}

export function slugifyAppName(name: string): string {
  const cleaned = name
    .toLowerCase()
    .trim()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48)
    .replace(/-+$/g, "");
  return cleaned;
}

export function validateCustomAppSlug(slug: string): string | null {
  const s = slug.trim();
  if (!SLUG_RE.test(s)) {
    return "Use 1–48 lowercase letters, digits, or hyphens starting with a letter or digit.";
  }
  if (RESERVED_CUSTOM_APP_SLUGS.has(s)) {
    return `"${s}" is a reserved Vesper route.`;
  }
  return null;
}

function escapeCloseTag(text: string, tagName: string): string {
  return text.replace(new RegExp(`</${tagName}`, "gi"), `<\\/${tagName}`);
}

export function formatThemeVarsCss(vars: Record<string, string> | undefined): string {
  if (!vars) return "";
  const lines: string[] = [];
  for (const [k, v] of Object.entries(vars)) {
    if (!k.startsWith("--") || typeof v !== "string") continue;
    const safeVal = v.replace(/[;{}\n\r]/g, " ").trim();
    if (safeVal) lines.push(`  ${k}: ${safeVal};`);
  }
  if (!lines.length) return "";
  return `:root {\n${lines.join("\n")}\n}`;
}

export function buildCustomAppSrcDoc(args: {
  slug: string;
  seq: number;
  bundleJs: string;
  bundleCss?: string;
  themeVars?: Record<string, string>;
}): string {
  const css = escapeCloseTag(args.bundleCss ?? "", "style");
  const js = escapeCloseTag(args.bundleJs, "script");
  const varsCss = formatThemeVarsCss(args.themeVars);
  const metaJson = JSON.stringify({ slug: args.slug, seq: args.seq }).replace(/</g, "\\u003c");

  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:;" />
<style>
${varsCss}
*, *::before, *::after { box-sizing: border-box; }
html, body, #root { min-height: 100%; }
body {
  margin: 0;
  background: var(--bg, #141413);
  color: var(--fg, #ecebe7);
  font-family: var(--font-sans, system-ui, -apple-system, sans-serif);
  font-size: 14px;
  line-height: 1.45;
  -webkit-font-smoothing: antialiased;
}
button, input, select, textarea { font: inherit; color: inherit; }
</style>
<style>${css}</style>
<script>
(function () {
  window.__VESPER_APP__ = ${metaJson};
  function sendErr(err) {
    var msg = err && (err.message || (err.reason && (err.reason.message || String(err.reason)))) || String(err || "Unknown error");
    window.parent.postMessage({ channel: "vesper:custom-app", id: "", type: "app-error", payload: { message: String(msg) } }, "*");
  }
  window.addEventListener("error", function (e) { sendErr(e.error || e.message); });
  window.addEventListener("unhandledrejection", function (e) { sendErr(e.reason); });
  window.addEventListener("message", function (e) {
    var m = e && e.data;
    if (!m || typeof m !== "object" || m.type !== "vesper:theme" || !m.vars || typeof m.vars !== "object") return;
    var root = document.documentElement;
    for (var k in m.vars) {
      if (Object.prototype.hasOwnProperty.call(m.vars, k) && k.indexOf("--") === 0 && typeof m.vars[k] === "string") {
        root.style.setProperty(k, m.vars[k]);
      }
    }
  });
})();
</script>
</head>
<body>
<div id="root"></div>
<script type="module">
${js}
</script>
</body>
</html>`;
}

const MAX_BRIDGE_URL_CHARS = 4000;
const YT_VIDEO_ID_RE = /^[A-Za-z0-9_-]{11}$/;
const YT_HOSTS = new Set([
  "youtube.com",
  "www.youtube.com",
  "m.youtube.com",
  "music.youtube.com",
  "youtube-nocookie.com",
  "www.youtube-nocookie.com",
  "youtu.be",
  "www.youtu.be",
]);
const TWITCH_HOSTS = new Set(["twitch.tv", "www.twitch.tv", "m.twitch.tv", "clips.twitch.tv"]);
const TWITCH_RESERVED_PATHS = new Set([
  "directory",
  "videos",
  "downloads",
  "jobs",
  "p",
  "settings",
  "subscriptions",
  "wallet",
  "inventory",
  "drops",
  "search",
  "turbo",
  "login",
  "signup",
  "friends",
  "messages",
  "moderator",
  "popout",
  "embed",
  "u",
]);
const TWITCH_CHANNEL_RE = /^[a-zA-Z0-9_]{2,25}$/;
const TWITCH_VOD_RE = /^\d{4,16}$/;
const TWITCH_CLIP_RE = /^[A-Za-z0-9_-]{4,120}$/;

function parseUrlWithProtocols(raw: unknown, allowedProtocols: ReadonlySet<string>): string | null {
  if (typeof raw !== "string") return null;
  const trimmed = raw.trim();
  if (!trimmed || trimmed.length > MAX_BRIDGE_URL_CHARS) return null;
  try {
    const u = new URL(trimmed);
    if (!allowedProtocols.has(u.protocol) || !u.hostname || u.username || u.password) return null;
    return u.toString();
  } catch {
    return null;
  }
}

export function parseSafeExternalUrl(raw: unknown): string | null {
  return parseUrlWithProtocols(raw, new Set(["https:", "http:"]));
}

export function parseSafeHttpsUrl(raw: unknown): string | null {
  return parseUrlWithProtocols(raw, new Set(["https:"]));
}

function parseTimestampSeconds(raw: string | null): number | null {
  if (!raw) return null;
  const s = raw.trim();
  if (!s) return null;
  if (/^\d+s?$/.test(s)) return parseInt(s, 10);
  const m = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/.exec(s);
  if (!m) return null;
  const total = Number(m[1] ?? 0) * 3600 + Number(m[2] ?? 0) * 60 + Number(m[3] ?? 0);
  return total > 0 ? total : null;
}

export type VideoEmbed = {
  provider: "youtube" | "twitch";
  embedUrl: string;
  externalUrl: string;
  titleFallback: string;
};

export function resolveVideoEmbed(rawUrl: string, parentHost?: string): VideoEmbed | null {
  const safe = parseSafeExternalUrl(rawUrl);
  if (!safe) return null;
  const u = new URL(safe);
  const host = u.hostname.toLowerCase();
  const segments = u.pathname.split("/").filter(Boolean);

  if (YT_HOSTS.has(host)) {
    let id = "";
    if (host.endsWith("youtu.be")) {
      id = segments[0] ?? "";
    } else if (u.pathname === "/watch") {
      id = u.searchParams.get("v") ?? "";
    } else if (segments.length >= 2 && ["shorts", "live", "embed"].includes(segments[0])) {
      id = segments[1];
    }
    if (!YT_VIDEO_ID_RE.test(id)) return null;
    const start = parseTimestampSeconds(u.searchParams.get("t") ?? u.searchParams.get("start"));
    return {
      provider: "youtube",
      embedUrl: `https://www.youtube-nocookie.com/embed/${id}?autoplay=1&rel=0${start && start > 0 ? `&start=${start}` : ""}`,
      externalUrl: `https://www.youtube.com/watch?v=${id}${start && start > 0 ? `&t=${start}s` : ""}`,
      titleFallback: "YouTube video",
    };
  }

  if (TWITCH_HOSTS.has(host)) {
    const parent = parentHost && /^[a-z0-9.-]+$/i.test(parentHost) ? parentHost : "localhost";
    if (host === "clips.twitch.tv") {
      const slug = segments[0] ?? "";
      if (!TWITCH_CLIP_RE.test(slug)) return null;
      return {
        provider: "twitch",
        embedUrl: `https://clips.twitch.tv/embed?clip=${encodeURIComponent(slug)}&parent=${encodeURIComponent(parent)}&autoplay=true`,
        externalUrl: u.toString(),
        titleFallback: "Twitch clip",
      };
    }
    if (segments.length === 3 && segments[1] === "clip" && TWITCH_CHANNEL_RE.test(segments[0]) && TWITCH_CLIP_RE.test(segments[2])) {
      const slug = segments[2];
      return {
        provider: "twitch",
        embedUrl: `https://clips.twitch.tv/embed?clip=${encodeURIComponent(slug)}&parent=${encodeURIComponent(parent)}&autoplay=true`,
        externalUrl: u.toString(),
        titleFallback: "Twitch clip",
      };
    }
    if (segments.length === 2 && segments[0] === "videos" && TWITCH_VOD_RE.test(segments[1])) {
      const vodId = segments[1];
      return {
        provider: "twitch",
        embedUrl: `https://player.twitch.tv/?video=${vodId}&parent=${encodeURIComponent(parent)}&autoplay=true`,
        externalUrl: `https://www.twitch.tv/videos/${vodId}`,
        titleFallback: "Twitch video",
      };
    }
    if (segments.length === 1 && TWITCH_CHANNEL_RE.test(segments[0]) && !TWITCH_RESERVED_PATHS.has(segments[0].toLowerCase())) {
      const channel = segments[0].toLowerCase();
      return {
        provider: "twitch",
        embedUrl: `https://player.twitch.tv/?channel=${encodeURIComponent(channel)}&parent=${encodeURIComponent(parent)}&autoplay=true`,
        externalUrl: `https://www.twitch.tv/${encodeURIComponent(channel)}`,
        titleFallback: `${segments[0]} on Twitch`,
      };
    }
  }

  return null;
}

export type BridgeMessage =
  | { channel: "vesper:custom-app"; id: string; type: "sql"; payload: { query: string; params: unknown[] } }
  | { channel: "vesper:custom-app"; id: string; type: "api"; payload: { method: string; path: string; body?: unknown } }
  | { channel: "vesper:custom-app"; id: string; type: "mcp"; payload: { connector: string; tool: string; arguments: Record<string, unknown> } }
  | { channel: "vesper:custom-app"; id: ""; type: "set-nav"; payload: { items: CustomAppNavSpec[]; activeId?: string } }
  | { channel: "vesper:custom-app"; id: ""; type: "ask-dock"; payload: { prompt: string } }
  | { channel: "vesper:custom-app"; id: ""; type: "open-url"; payload: { url: string } }
  | { channel: "vesper:custom-app"; id: ""; type: "play-video"; payload: { url: string; title?: string } }
  | { channel: "vesper:custom-app"; id: ""; type: "app-error"; payload: { message: string } };

export function parseBridgeMessage(raw: unknown): BridgeMessage | null {
  if (!raw || typeof raw !== "object") return null;
  const m = raw as Record<string, unknown>;
  if (m.channel !== "vesper:custom-app" || typeof m.type !== "string") return null;
  const payload = m.payload && typeof m.payload === "object" ? (m.payload as Record<string, unknown>) : {};
  const id = typeof m.id === "string" ? m.id : "";

  switch (m.type) {
    case "sql": {
      if (!id || typeof payload.query !== "string") return null;
      const params = Array.isArray(payload.params) ? payload.params : [];
      return { channel: "vesper:custom-app", id, type: "sql", payload: { query: payload.query, params } };
    }
    case "api": {
      if (!id || typeof payload.path !== "string") return null;
      const method = typeof payload.method === "string" && payload.method ? payload.method.toUpperCase() : "GET";
      return { channel: "vesper:custom-app", id, type: "api", payload: { method, path: payload.path, body: payload.body } };
    }
    case "mcp": {
      if (!id || typeof payload.connector !== "string" || typeof payload.tool !== "string") return null;
      const args =
        payload.arguments && typeof payload.arguments === "object" && !Array.isArray(payload.arguments)
          ? (payload.arguments as Record<string, unknown>)
          : {};
      return {
        channel: "vesper:custom-app",
        id,
        type: "mcp",
        payload: { connector: payload.connector, tool: payload.tool, arguments: args },
      };
    }
    case "set-nav": {
      const rawItems = Array.isArray(payload.items) ? payload.items : [];
      const items: CustomAppNavSpec[] = rawItems
        .filter((x): x is Record<string, unknown> => !!x && typeof x === "object")
        .map((x) => ({
          id: typeof x.id === "string" ? x.id : "",
          label: typeof x.label === "string" ? x.label : "",
          ...(typeof x.icon === "string" && x.icon ? { icon: x.icon } : {}),
        }))
        .filter((x) => x.id && x.label);
      const activeId = typeof payload.activeId === "string" && payload.activeId ? payload.activeId : undefined;
      return { channel: "vesper:custom-app", id: "", type: "set-nav", payload: { items, activeId } };
    }
    case "ask-dock": {
      if (typeof payload.prompt !== "string" || !payload.prompt.trim()) return null;
      return { channel: "vesper:custom-app", id: "", type: "ask-dock", payload: { prompt: payload.prompt.trim() } };
    }
    case "open-url": {
      const url = parseSafeExternalUrl(payload.url);
      if (!url) return null;
      return { channel: "vesper:custom-app", id: "", type: "open-url", payload: { url } };
    }
    case "play-video": {
      const url = parseSafeExternalUrl(payload.url);
      if (!url) return null;
      const title = typeof payload.title === "string" ? payload.title.trim().slice(0, 200) : "";
      return {
        channel: "vesper:custom-app",
        id: "",
        type: "play-video",
        payload: { url, ...(title ? { title } : {}) },
      };
    }
    case "app-error": {
      if (typeof payload.message !== "string" || !payload.message.trim()) return null;
      return { channel: "vesper:custom-app", id: "", type: "app-error", payload: { message: payload.message } };
    }
    default:
      return null;
  }
}

export function withCustomAppContext(
  body: string,
  ctx: { slug: string; name: string; seq: number; activeNav?: string; error?: string },
): string {
  const parts = [`Viewing Custom App "${ctx.name}" (/apps/${ctx.slug}, version v${ctx.seq}).`];
  if (ctx.activeNav) parts.push(`Active nav view: ${ctx.activeNav}.`);
  if (ctx.error) parts.push(`Latest runtime error in sandbox: ${ctx.error}`);
  const suffix = `${CUSTOM_APP_CONTEXT_MARKER}${parts.join("\n")}`;
  return body.endsWith(suffix) ? body : `${body}${suffix}`;
}
