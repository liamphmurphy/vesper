/**
 * vesper:// deep links.
 *
 * Only these shapes are accepted; everything else is rejected without navigating:
 *   vesper://run/<uuid>        → /runs/<uuid>
 *   vesper://ticket/<KEY-123>  → /tickets/<KEY-123>
 *   vesper://epic/<uuid>       → /epics/<uuid>
 *   vesper://page/<uuid>       → /knowledge/<uuid>
 *   vesper://chat/<uuid>       → /chat/<uuid>
 *   vesper://inbox             → /inbox
 *   vesper://capture           → opens the quick-capture window (no navigation)
 *
 * Query strings, fragments, credentials, ports and extra path segments are
 * refused, so nothing from a link reaches a URL or request beyond a validated
 * id from the table above.
 */

export const VESPER_SCHEME = "vesper";

export type DeepLinkTarget =
  | { kind: "navigate"; path: string }
  | { kind: "capture" };

export type DeepLinkResult = { ok: true; target: DeepLinkTarget } | { ok: false; reason: string };

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const TICKET_KEY_RE = /^[A-Z][A-Z0-9_]{0,31}-[1-9][0-9]{0,8}$/;
const MAX_LINK_LENGTH = 200;

const ID_ROUTES: Record<string, { prefix: string; re: RegExp }> = {
  run: { prefix: "/runs/", re: UUID_RE },
  ticket: { prefix: "/tickets/", re: TICKET_KEY_RE },
  epic: { prefix: "/epics/", re: UUID_RE },
  page: { prefix: "/knowledge/", re: UUID_RE },
  chat: { prefix: "/chat/", re: UUID_RE },
};

export function parseVesperLink(raw: unknown): DeepLinkResult {
  if (typeof raw !== "string") return { ok: false, reason: "not a string" };
  if (raw.length > MAX_LINK_LENGTH) return { ok: false, reason: "too long" };
  // Control characters, whitespace and backslashes have no place in a valid link.
  if (/[\s\\\u0000-\u001f\u007f]/.test(raw)) return { ok: false, reason: "invalid characters" };

  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return { ok: false, reason: "malformed" };
  }
  if (url.protocol !== `${VESPER_SCHEME}:`) return { ok: false, reason: "wrong scheme" };
  if (url.username || url.password || url.port) return { ok: false, reason: "credentials or port" };
  if (url.search || url.hash || raw.includes("?") || raw.includes("#")) return { ok: false, reason: "query or fragment" };

  // vesper://ticket/ABC-1 parses with host "ticket"; vesper:ticket/ABC-1 has no host.
  const host = url.hostname.toLowerCase();
  const segments = url.pathname.split("/").filter((s) => s.length > 0);
  if (!host) return { ok: false, reason: "missing target" };

  if (host === "inbox" && segments.length === 0) return { ok: true, target: { kind: "navigate", path: "/inbox" } };
  if (host === "capture" && segments.length === 0) return { ok: true, target: { kind: "capture" } };

  const route = ID_ROUTES[host];
  if (!route) return { ok: false, reason: `unknown target "${host}"` };
  if (segments.length !== 1) return { ok: false, reason: "expected exactly one id" };

  let id: string;
  try {
    id = decodeURIComponent(segments[0]);
  } catch {
    return { ok: false, reason: "bad encoding" };
  }
  if (!route.re.test(id)) return { ok: false, reason: `invalid ${host} id` };
  return { ok: true, target: { kind: "navigate", path: `${route.prefix}${id}` } };
}

/**
 * The reverse: turns an in-app href (as the inbox returns them) into a vesper://
 * link when it is one of the supported shapes, or null otherwise. Used so
 * notifications route through the same validated path as external links.
 */
export function hrefToVesperLink(href: string): string | null {
  if (typeof href !== "string" || !href.startsWith("/") || href.startsWith("//")) return null;
  const clean = href.split(/[?#]/)[0];
  if (clean === "/inbox") return `${VESPER_SCHEME}://inbox`;
  for (const [host, route] of Object.entries(ID_ROUTES)) {
    if (!clean.startsWith(route.prefix)) continue;
    const id = clean.slice(route.prefix.length);
    if (route.re.test(id)) return `${VESPER_SCHEME}://${host}/${id}`;
  }
  return null;
}

/** Pulls a vesper:// link out of argv (cold start via `open vesper://…` on some launchers). */
export function findVesperLinkInArgv(argv: readonly string[]): string | null {
  for (const arg of argv) {
    if (typeof arg === "string" && arg.toLowerCase().startsWith(`${VESPER_SCHEME}://`)) return arg;
  }
  return null;
}
