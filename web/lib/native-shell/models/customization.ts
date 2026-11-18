// The Customization rail (customization-screen.tsx's left column) as a NavModel.
import type { NavItem, NavModel } from "../protocol.ts";
import { navAvatar } from "./common.ts";

export const CUSTOMIZE_NAV_ID = "customization";
export const NEW_PERSONA_ACTION = "new-persona";
export const RETRY_PERSONAS_ACTION = "retry-personas";

export interface CustomizeInput {
  me?: { name: string; initials?: string; avatar_url?: string | null };
  personas: readonly { id: string; name: string; color: string; avatar_url?: string | null; is_default?: boolean }[];
  personasState: "loading" | "error" | "ready";
  spaces: readonly { id: string; name: string; color: string; memory_count: number }[];
  /** ?who= */
  who: string;
  /** The memory owner on show: "", "person", a persona id or "space:<id>". */
  whose: string;
  spaceParam: string;
  /** More personas can be added (under MAX_PERSONAS). */
  canAddPersona: boolean;
  origin?: string;
}

export function buildCustomizationNavModel(input: CustomizeInput): NavModel {
  const { who, whose } = input;
  const listing = who === "personas" || who === "agents";
  const top: NavItem[] = [
    { id: "everything", title: "Everything", icon: "bookmark" },
    { id: "person", title: "You", avatar: navAvatar(input.me?.name ?? "You", undefined, input.me?.avatar_url, input.origin) },
    { id: "connectors", title: "Connectors", icon: "plug" },
    { id: "secrets", title: "Secrets", icon: "key" },
  ];
  const personaItems: NavItem[] = [{ id: "all-personas", title: "All personas", icon: "agents" }];
  for (const p of input.personas) {
    personaItems.push({
      id: `persona:${p.id}`,
      title: p.name,
      avatar: navAvatar(p.name, p.color, p.avatar_url, input.origin),
      ...(p.is_default ? { badge: { text: "Default", tone: "accent" as const } } : {}),
    });
  }
  const actions = [];
  if (input.personasState === "error") actions.push({ id: RETRY_PERSONAS_ACTION, label: "Retry loading personas", icon: "refresh" });
  else if (input.personasState === "ready" && input.canAddPersona) actions.push({ id: NEW_PERSONA_ACTION, label: "New persona", icon: "plus", accent: true });
  const sections: NavModel["sections"] = [
    { id: "top", items: top },
    {
      id: "personas",
      title: "Personas",
      ...(actions.length ? { actions } : {}),
      items: personaItems,
      emptyText: input.personasState === "error" ? "Couldn’t load personas" : undefined,
    },
  ];
  if (input.personas.length === 0 && input.personasState === "ready") {
    sections[1].items.push({ id: "no-personas", title: "No personas yet. The built-in Assistant is your default.", disabled: true });
  }
  if (input.spaces.length > 0) {
    sections.push({
      id: "spaces",
      title: "Spaces",
      items: input.spaces.map((s) => ({
        id: `space:${s.id}`,
        title: s.name,
        avatar: navAvatar(s.name, s.color),
        trailing: String(s.memory_count),
      })),
    });
  }
  let selectedId: string | null = null;
  if (input.spaceParam) selectedId = `space:${input.spaceParam}`;
  else if (who === "connectors" || who === "secrets") selectedId = who;
  else if (listing) selectedId = "all-personas";
  else if (whose === "person") selectedId = "person";
  else if (!whose) selectedId = "everything";
  else selectedId = `persona:${whose}`;
  return { id: CUSTOMIZE_NAV_ID, title: "Customization", sections, selectedId };
}
