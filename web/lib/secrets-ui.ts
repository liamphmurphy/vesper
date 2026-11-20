/**
 * API secrets: the rules the Customization page and chat cards share. Pure so
 * they're unit-tested. A value never comes back from the API; jwtExpiry only
 * reads one the person is typing, in their own browser.
 */

export type Placement = "bearer" | "header" | "query" | "basic";
export type Policy = "allow" | "ask" | "off";

export const PLACEMENTS: ReadonlyArray<{ value: Placement; label: string }> = [
  { value: "bearer", label: "Bearer token" },
  { value: "header", label: "Custom header" },
  { value: "query", label: "Query param" },
  { value: "basic", label: "Basic auth" },
];

export const POLICIES: ReadonlyArray<{ value: Policy; label: string }> = [
  { value: "allow", label: "Allow" },
  { value: "ask", label: "Ask" },
  { value: "off", label: "Off" },
];

/** What the request carries, with the handle where the value goes. */
export function sentAs(placement: Placement, key: string, handle: string): string {
  const ph = `‹${handle || "secret"}›`;
  switch (placement) {
    case "bearer":
      return `Authorization: Bearer ${ph}`;
    case "header":
      return `${key || "X-Api-Key"}: ${ph}`;
    case "query":
      return `?${key || "api_key"}=${ph}`;
    case "basic":
      return `Authorization: Basic ${ph}`;
  }
}

/** Where a value goes, in words: "Authorization: Bearer", "X-Api-Key header". Matches the server's SentAs. */
export function placementLabel(placement: Placement, key: string): string {
  switch (placement) {
    case "bearer":
      return "Authorization: Bearer";
    case "header":
      return `${key} header`;
    case "query":
      return `${key} query parameter`;
    case "basic":
      return "Basic auth";
  }
}

/** The handle the server derives from a name; shown before saving. It may get a -2 if taken. */
export function handleFor(name: string): string {
  let h = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  if (/^[0-9]/.test(h)) h = `s-${h}`;
  if (h.length > 36) h = h.slice(0, 36).replace(/-+$/, "");
  return h;
}

/** A hostname from what was typed or pasted (a URL works too), or null. Matches the server's rules. */
export function hostOf(raw: string): string | null {
  let h = raw.trim().toLowerCase();
  const scheme = h.indexOf("://");
  if (scheme >= 0) h = h.slice(scheme + 3);
  h = h.split(/[/?#]/)[0];
  h = h.slice(h.lastIndexOf("@") + 1);
  if (h.startsWith("[")) h = h.slice(1, h.indexOf("]"));
  else if ((h.match(/:/g) ?? []).length === 1) h = h.slice(0, h.indexOf(":"));
  h = h.replace(/\.$/, "");
  const label = "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?";
  if (new RegExp(`^(${label}\\.)*${label}$`).test(h) || /^\d{1,3}(\.\d{1,3}){3}$/.test(h) || h.includes(":")) return h || null;
  return null;
}

/** The exp claim of a value shaped like a JWT, without checking its signature. */
export function jwtExpiry(value: string): Date | null {
  const parts = value.trim().split(".");
  if (parts.length !== 3) return null;
  try {
    const b64 = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const claims = JSON.parse(atob(b64 + "===".slice((b64.length + 3) % 4)));
    return typeof claims.exp === "number" && claims.exp > 0 ? new Date(claims.exp * 1000) : null;
  } catch {
    return null;
  }
}

const DAY = 86_400_000;

/** The list pill: nothing without an expiry, else how long it has left. */
export function expiryPill(expiresAt: string | undefined, now = Date.now()): { label: string; tone: "done" | "human" | "blocked" } | null {
  if (!expiresAt) return null;
  const left = new Date(expiresAt).getTime() - now;
  if (left <= 0) return { label: "Expired", tone: "blocked" };
  if (left < DAY) return { label: `${Math.max(1, Math.round(left / 3_600_000))}h left`, tone: "human" };
  if (left < 14 * DAY) return { label: `${Math.round(left / DAY)}d left`, tone: "human" };
  return { label: "Active", tone: "done" };
}

const dateLabel = (ms: number) => new Date(ms).toLocaleDateString("en-US", { month: "short", day: "numeric", year: "numeric", timeZone: "UTC" });

/** The value's expiry in words: "Expires Nov 15, 2026", "Expired Nov 8, 2026", or none found. */
export function expiryText(expiresAt: string | Date | null | undefined, now = Date.now()): string {
  if (!expiresAt) return "No expiry found";
  const at = new Date(expiresAt).getTime();
  return `${at <= now ? "Expired" : "Expires"} ${dateLabel(at)}`;
}

/** "GET, HEAD" style list of what each policy row covers. */
export const READ_METHODS = "GET, HEAD";
export const WRITE_METHODS = "POST, PUT, PATCH, DELETE";

/**
 * A call to the vesper_secrets server: Claude names it
 * mcp__vesper_secrets__http_request, Codex vesper_secrets.http_request.
 */
export function secretCall(tool: string, input: unknown): { tool: string; handle: string; method: string; target: string } | null {
  const m = /^mcp__vesper_secrets__(.+)$/.exec(tool) ?? /^vesper_secrets\.(.+)$/.exec(tool);
  if (!m) return null;
  const o = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
  const handle = typeof o.secret === "string" ? o.secret : "";
  const method = typeof o.method === "string" && o.method ? o.method.toUpperCase() : "GET";
  let target = "";
  if (typeof o.url === "string") {
    try {
      const u = new URL(o.url);
      target = `${u.host}${u.pathname}`;
    } catch {
      target = o.url;
    }
  }
  return { tool: m[1], handle, method, target };
}

export type SecretKind = "static" | "oauth";

export const SECRET_KINDS: ReadonlyArray<{ value: SecretKind; label: string }> = [
  { value: "static", label: "Token or key" },
  { value: "oauth", label: "OAuth sign-in" },
];

/** scopes_required: the provider refuses a sign-in that asks for none (Google does). */
export type OAuthPreset = { value: string; label: string; authorize_url: string; token_url: string; hosts: string[]; scopes_hint: string; scopes_required: boolean };

/** Providers whose endpoints Vesper fills in; "custom" leaves them to the person. */
export const OAUTH_PRESETS: ReadonlyArray<OAuthPreset> = [
  {
    value: "google",
    label: "Google",
    authorize_url: "https://accounts.google.com/o/oauth2/v2/auth",
    token_url: "https://oauth2.googleapis.com/token",
    hosts: ["www.googleapis.com"],
    scopes_hint: "https://www.googleapis.com/auth/drive.readonly",
    scopes_required: true,
  },
  {
    value: "twitch",
    label: "Twitch",
    authorize_url: "https://id.twitch.tv/oauth2/authorize",
    token_url: "https://id.twitch.tv/oauth2/token",
    hosts: ["api.twitch.tv"],
    scopes_hint: "user:read:follows",
    scopes_required: true,
  },
  { value: "custom", label: "Other provider", authorize_url: "", token_url: "", hosts: [], scopes_hint: "read write", scopes_required: false },
];

/** Scopes typed with spaces, commas or new lines, without repeats. Matches the server's NormalizeScopes. */
export function splitScopes(raw: string): string[] {
  return [...new Set(raw.split(/[\s,]+/).filter(Boolean))];
}

/**
 * An OAuth secret's state for the list pill and the detail: it can't be used
 * until it's signed in, and a refresh the provider refused means signing in again.
 */
export function oauthStatus(oauth: { signed_in_at?: string; error: string } | undefined): { label: string; tone: "done" | "human" | "blocked"; action: string } | null {
  if (!oauth) return null;
  if (!oauth.signed_in_at) return { label: "Not signed in", tone: "human", action: "Sign in" };
  if (oauth.error) return { label: "Sign in again", tone: "blocked", action: "Sign in again" };
  return { label: "Signed in", tone: "done", action: "Sign in again" };
}
