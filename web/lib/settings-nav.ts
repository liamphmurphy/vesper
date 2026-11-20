// Unified Settings routing, deep links, legacy /customization redirects, and filter matching.
// Pure (no React or DOM imports) so `node --test` and the router loader both run it directly.

export type SettingsSectionId =
  | "you"
  | "appearance"
  | "memory"
  | "personas"
  | "persona"
  | "secrets"
  | "connectors"
  | "repositories"
  | "workspace"
  | "runners"
  | "dev-workspace"
  | "spaces"
  | "sign-in"
  | "backup";

export type SecretsTab = "provider" | "api";
export type PersonaFilterParam = "all" | "chat" | "tickets" | "helper";

export type SettingsRoute =
  | { section: "you" }
  | { section: "appearance" }
  | { section: "memory"; focusId?: string }
  | { section: "personas"; personaFilter: PersonaFilterParam }
  | { section: "persona"; personaId: string }
  | { section: "secrets"; secretsTab: SecretsTab; secretId?: string }
  | { section: "connectors" }
  | { section: "repositories" }
  | { section: "workspace"; anchor?: "images" }
  | { section: "runners" }
  | { section: "dev-workspace" }
  | { section: "spaces"; spaceId?: string; anchor?: "overrides" }
  | { section: "sign-in" }
  | { section: "backup" };

export const SETTINGS_DEFAULT_SECTION = "you" as const;

const SIMPLE_SECTIONS = new Set<string>([
  "you",
  "appearance",
  "connectors",
  "repositories",
  "runners",
  "dev-workspace",
  "sign-in",
  "backup",
]);

const PERSONA_FILTERS = new Set<PersonaFilterParam>(["all", "chat", "tickets", "helper"]);

function parsePersonaFilter(raw: string | null): PersonaFilterParam {
  return raw && PERSONA_FILTERS.has(raw as PersonaFilterParam) ? (raw as PersonaFilterParam) : "all";
}

function normalizeHash(hash: string): string {
  const raw = hash.replace(/^#/, "");
  try {
    return decodeURIComponent(raw).toLowerCase();
  } catch {
    return raw.toLowerCase();
  }
}

/**
 * Resolves the active Settings section and its parameters from URL query params and legacy #hashes.
 * Supports canonical `?section=...`, implicit deep-link params (`?persona=`, `?id=`, `?space=`, `?secret=`),
 * and legacy Settings hashes (`#appearance`, `#secrets`, `#images`, `#overrides`, etc.).
 */
export function resolveSettingsRoute(search: URLSearchParams, hash = ""): SettingsRoute {
  const normHash = normalizeHash(hash);
  const section = search.get("section");

  if (section) {
    if (SIMPLE_SECTIONS.has(section)) {
      return { section: section as Exclude<SettingsSectionId, "memory" | "personas" | "persona" | "secrets" | "workspace" | "spaces"> };
    }
    if (section === "memory") {
      const focusId = search.get("id") || undefined;
      return { section: "memory", ...(focusId ? { focusId } : {}) };
    }
    if (section === "personas") {
      const personaId = search.get("persona") || "";
      if (personaId) return { section: "persona", personaId };
      return { section: "personas", personaFilter: parsePersonaFilter(search.get("filter")) };
    }
    if (section === "persona") {
      const personaId = search.get("persona") || search.get("id") || "";
      if (personaId) return { section: "persona", personaId };
      return { section: "personas", personaFilter: "all" };
    }
    if (section === "secrets") {
      const secretId = search.get("secret") || undefined;
      const tab = search.get("tab");
      const secretsTab: SecretsTab = tab === "api" || (!!secretId && tab !== "provider") ? "api" : "provider";
      return { section: "secrets", secretsTab, ...(secretId ? { secretId } : {}) };
    }
    if (section === "workspace") {
      return { section: "workspace", ...(normHash === "images" ? { anchor: "images" as const } : {}) };
    }
    if (section === "spaces") {
      const spaceId = search.get("space") || undefined;
      return { section: "spaces", ...(spaceId ? { spaceId } : {}), ...(normHash === "overrides" ? { anchor: "overrides" as const } : {}) };
    }
  }

  const personaId = search.get("persona") || "";
  if (personaId) return { section: "persona", personaId };
  const focusId = search.get("id") || "";
  if (focusId) return { section: "memory", focusId };
  const spaceId = search.get("space") || "";
  if (spaceId) return { section: "spaces", spaceId };
  const secretId = search.get("secret") || "";
  if (secretId) return { section: "secrets", secretsTab: "api", secretId };

  if (normHash === "workspace") return { section: "workspace" };
  if (normHash === "spaces") return { section: "spaces" };
  if (normHash === "memory") return { section: "memory" };
  if (normHash === "personas") return { section: "personas", personaFilter: "all" };
  if (normHash === "secrets") return { section: "secrets", secretsTab: "provider" };
  if (normHash === "images") return { section: "workspace", anchor: "images" };
  if (normHash === "overrides") return { section: "spaces", anchor: "overrides" };
  if (SIMPLE_SECTIONS.has(normHash)) {
    return { section: normHash as Exclude<SettingsSectionId, "memory" | "personas" | "persona" | "secrets" | "workspace" | "spaces"> };
  }

  return { section: SETTINGS_DEFAULT_SECTION };
}

/** Formats a canonical `/settings?...` href for a SettingsRoute. */
export function settingsHref(route: SettingsRoute): string {
  const q = new URLSearchParams();
  let hash = "";

  switch (route.section) {
    case "memory":
      q.set("section", "memory");
      if (route.focusId) q.set("id", route.focusId);
      break;
    case "personas":
      q.set("section", "personas");
      if (route.personaFilter !== "all") q.set("filter", route.personaFilter);
      break;
    case "persona":
      q.set("section", "personas");
      q.set("persona", route.personaId);
      break;
    case "secrets":
      q.set("section", "secrets");
      if (route.secretsTab === "api") q.set("tab", "api");
      if (route.secretId) q.set("secret", route.secretId);
      break;
    case "workspace":
      q.set("section", "workspace");
      if (route.anchor === "images") hash = "#images";
      break;
    case "spaces":
      q.set("section", "spaces");
      if (route.spaceId) q.set("space", route.spaceId);
      if (route.anchor === "overrides") hash = "#overrides";
      break;
    default:
      q.set("section", route.section);
      break;
  }

  return `/settings?${q.toString()}${hash}`;
}

/** Returns the sidebar item id corresponding to a resolved route. */
export function selectedNavId(route: SettingsRoute): string {
  if (route.section === "personas") return "all-personas";
  if (route.section === "persona") return `persona:${route.personaId}`;
  return route.section;
}

/** Extra keywords per sidebar item so filtering finds sub-topics (e.g. "image engine", "oauth", "palette"). */
export const SETTINGS_FILTER_KEYWORDS: Record<string, string> = {
  you: "profile account name email avatar bio about",
  appearance: "theme dark light mode font text size palette colors harness activity",
  memory: "memories facts import export forget everything",
  "all-personas": "personas agents models roles permissions tickets helpers",
  secrets: "provider credentials api secrets keys tokens oauth anthropic openai google github ssh pat",
  connectors: "mcp servers tools oauth integration",
  repositories: "repos github owners organizations presets discovery",
  workspace: "setup checklist encryption secrets_key image engine generation codex antigravity",
  runners: "runner backends microvm docker fake concurrency slots host folders environment",
  "dev-workspace": "nix lazyvim neovim tmux gitconfig container ssh dev",
  spaces: "space memory overrides skills project instructions",
  "sign-in": "password authentication login browser session",
  backup: "export archive zip migrate move restore instance encrypt encryption password",
};

/** Returns true when every whitespace-separated word in `query` matches `label` or `extra`. */
export function matchesSettingsFilter(query: string, label: string, extra?: string): boolean {
  const words = query.trim().toLowerCase().split(/\s+/).filter(Boolean);
  if (words.length === 0) return true;
  const hay = `${label} ${extra ?? ""}`.toLowerCase();
  return words.every((w) => hay.includes(w));
}

/** Maps legacy `/customization` URLs to unified `/settings` destinations, preserving intent and hash. */
export function customizationRedirect(url: URL): string | null {
  const path = url.pathname.length > 1 ? url.pathname.replace(/\/+$/, "") : url.pathname;
  if (path !== "/customization") return null;

  const sp = url.searchParams;
  const space = sp.get("space");
  if (space) {
    return `${settingsHref({ section: "spaces", spaceId: space })}${url.hash}`;
  }

  const who = sp.get("who");
  if (who === "person") {
    return `${settingsHref({ section: "you" })}${url.hash}`;
  }
  if (who === "personas") {
    return `${settingsHref({ section: "personas", personaFilter: "all" })}${url.hash}`;
  }
  if (who === "agents") {
    return `${settingsHref({ section: "personas", personaFilter: "tickets" })}${url.hash}`;
  }
  if (who === "connectors") {
    return `${settingsHref({ section: "connectors" })}${url.hash}`;
  }
  if (who === "secrets") {
    const secretId = sp.get("secret") || undefined;
    return `${settingsHref({ section: "secrets", secretsTab: "api", secretId })}${url.hash}`;
  }
  if (who) {
    return `${settingsHref({ section: "persona", personaId: who })}${url.hash}`;
  }

  const focusId = sp.get("id") || undefined;
  return `${settingsHref({ section: "memory", focusId })}${url.hash}`;
}
