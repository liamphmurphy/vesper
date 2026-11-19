// Unified Settings sidebar (Personal, Personas, Integrations, System) as a NavModel.
import type { NavAction, NavItem, NavModel, NavSection, Tone } from "../protocol.ts";
import { navAvatar } from "./common.ts";
import { matchesSettingsFilter, SETTINGS_FILTER_KEYWORDS } from "../../settings-nav.ts";

export const SETTINGS_NAV_ID = "settings";
export const SETTINGS_SEARCH_ID = "settings-filter";
export const NEW_PERSONA_ACTION = "new-persona";
export const RETRY_PERSONAS_ACTION = "retry-personas";

export type SettingsHealth = "ok" | "attention" | "idle" | "unknown";

export interface UnifiedSettingsPersona {
  id: string;
  name: string;
  handle?: string | null;
  color: string;
  avatar_url?: string | null;
  is_default?: boolean;
}

export interface UnifiedSettingsNavInput {
  me?: { name: string; initials?: string; avatar_url?: string | null };
  personas: readonly UnifiedSettingsPersona[];
  personasState: "loading" | "error" | "ready";
  canAddPersona: boolean;
  memoryTotal?: number;
  health: {
    secrets: SettingsHealth;
    missingCredentials: number;
    workspace: SettingsHealth;
    runners: SettingsHealth;
    signIn: SettingsHealth;
  };
  selectedId: string | null;
  filter: string;
  origin?: string;
}

const HEALTH_TONE: Partial<Record<SettingsHealth, Tone>> = { ok: "done", attention: "human" };

function healthStatus(h: SettingsHealth): { status?: Tone } {
  const status = HEALTH_TONE[h];
  return status ? { status } : {};
}

type TaggedItem = { item: NavItem; extra?: string };

function filterItems(entries: readonly TaggedItem[], filter: string): NavItem[] {
  if (!filter.trim()) return entries.map((e) => e.item);
  return entries
    .filter((e) => !e.item.disabled && matchesSettingsFilter(filter, e.item.title, e.extra))
    .map((e) => e.item);
}

/** Builds the grouped, searchable Settings sidebar for the native shell. */
export function buildSettingsNavModel(input: UnifiedSettingsNavInput): NavModel {
  const { me, personas, personasState, canAddPersona, memoryTotal, health, selectedId, filter, origin } = input;
  const filtering = filter.trim().length > 0;

  const personalEntries: TaggedItem[] = [
    {
      item: {
        id: "you",
        title: "You",
        avatar: navAvatar(me?.name ?? "You", undefined, me?.avatar_url, origin),
      },
      extra: `${SETTINGS_FILTER_KEYWORDS.you} ${me?.name ?? ""}`,
    },
    {
      item: { id: "appearance", title: "Appearance", icon: "sun" },
      extra: SETTINGS_FILTER_KEYWORDS.appearance,
    },
    {
      item: {
        id: "memory",
        title: "Memory",
        icon: "bookmark",
        ...(memoryTotal !== undefined && memoryTotal > 0 ? { trailing: String(memoryTotal) } : {}),
      },
      extra: SETTINGS_FILTER_KEYWORDS.memory,
    },
  ];

  const personaEntries: TaggedItem[] = [
    {
      item: { id: "all-personas", title: "All personas", icon: "agents" },
      extra: SETTINGS_FILTER_KEYWORDS["all-personas"],
    },
    ...personas.map((p): TaggedItem => ({
      item: {
        id: `persona:${p.id}`,
        title: p.name,
        avatar: navAvatar(p.name, p.color, p.avatar_url, origin),
        ...(p.is_default ? { badge: { text: "Default", tone: "accent" } } : {}),
      },
      extra: p.handle ? `persona @${p.handle} ${p.handle}` : "persona",
    })),
  ];
  if (personas.length === 0 && personasState === "ready" && !filtering) {
    personaEntries.push({
      item: {
        id: "no-personas",
        title: "No personas yet. The built-in Assistant is your default.",
        disabled: true,
      },
    });
  }

  const personaActions: NavAction[] = [];
  if (personasState === "error") {
    personaActions.push({ id: RETRY_PERSONAS_ACTION, label: "Retry loading personas", icon: "refresh" });
  } else if (personasState === "ready" && canAddPersona) {
    personaActions.push({ id: NEW_PERSONA_ACTION, label: "New persona", icon: "plus", accent: true });
  }

  const integrationEntries: TaggedItem[] = [
    {
      item: {
        id: "secrets",
        title: "Secrets & Credentials",
        icon: "key",
        ...healthStatus(health.secrets),
        ...(health.missingCredentials > 0
          ? { badge: { text: `${health.missingCredentials} off`, tone: "human" } }
          : {}),
      },
      extra: SETTINGS_FILTER_KEYWORDS.secrets,
    },
    {
      item: { id: "connectors", title: "Connectors", icon: "plug" },
      extra: SETTINGS_FILTER_KEYWORDS.connectors,
    },
    {
      item: { id: "repositories", title: "Repositories", icon: "github" },
      extra: SETTINGS_FILTER_KEYWORDS.repositories,
    },
  ];

  const systemEntries: TaggedItem[] = [
    {
      item: { id: "workspace", title: "Workspace", icon: "briefcase", ...healthStatus(health.workspace) },
      extra: SETTINGS_FILTER_KEYWORDS.workspace,
    },
    {
      item: { id: "runners", title: "Runners", icon: "server", ...healthStatus(health.runners) },
      extra: SETTINGS_FILTER_KEYWORDS.runners,
    },
    {
      item: { id: "dev-workspace", title: "Dev workspace", icon: "terminal" },
      extra: SETTINGS_FILTER_KEYWORDS["dev-workspace"],
    },
    {
      item: { id: "spaces", title: "Spaces", icon: "folder" },
      extra: SETTINGS_FILTER_KEYWORDS.spaces,
    },
    {
      item: { id: "sign-in", title: "Sign-in", icon: "lock", ...healthStatus(health.signIn) },
      extra: SETTINGS_FILTER_KEYWORDS["sign-in"],
    },
    {
      item: { id: "backup", title: "Backup & move", icon: "download" },
      extra: SETTINGS_FILTER_KEYWORDS.backup,
    },
  ];

  const rawSections: NavSection[] = [
    { id: "personal", title: "Personal", items: filterItems(personalEntries, filter) },
    {
      id: "personas",
      title: "Personas",
      ...(personaActions.length ? { actions: personaActions } : {}),
      items: filterItems(personaEntries, filter),
      emptyText: personasState === "error" ? "Couldn’t load personas" : undefined,
    },
    { id: "integrations", title: "Integrations", items: filterItems(integrationEntries, filter) },
    { id: "system", title: "System", items: filterItems(systemEntries, filter) },
  ];

  const sections = filtering ? rawSections.filter((s) => s.items.length > 0) : rawSections;

  return {
    id: SETTINGS_NAV_ID,
    title: "Settings",
    search: { id: SETTINGS_SEARCH_ID, placeholder: "Filter settings…", value: filter },
    sections,
    selectedId,
  };
}
