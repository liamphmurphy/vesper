// Pure helpers for resolving Ticket/Run agent references to Persona identities
// and live character animation states. Kept free of React for node --test.

import { agentAvatarColor, navAvatar } from "./native-shell/models/common.ts";
import type { Avatar } from "./native-shell/protocol.ts";
import type { CharacterState } from "./persona-character.ts";

export type WorkAgentLike = {
  id?: string | null;
  handle?: string | null;
  name: string;
  color_index?: number | null;
};

export type WorkPersonaLike = {
  id: string;
  name: string;
  handle?: string | null;
  color?: string | null;
  avatar_url?: string | null;
  character_svg?: string | null;
};

/**
 * Resolve a ticket/run assignee reference against loaded personas.
 * Working personas share their UUID between `agents.id` and `personas.id`,
 * with handle and case-insensitive name fallbacks for historical records.
 */
export function matchWorkPersona<P extends WorkPersonaLike>(
  personas: readonly P[] | undefined,
  agent: WorkAgentLike,
): P | undefined {
  if (!personas?.length) return undefined;
  const byId = agent.id ? personas.find((p) => p.id === agent.id) : undefined;
  if (byId) return byId;
  if (agent.handle) {
    const h = agent.handle.trim().toLowerCase();
    const byHandle = personas.find((p) => p.handle?.toLowerCase() === h || p.id === agent.handle);
    if (byHandle) return byHandle;
  }
  const lower = agent.name.trim().toLowerCase();
  return lower ? personas.find((p) => p.name.trim().toLowerCase() === lower) : undefined;
}

/** Build a native sidebar Avatar from an agent ref, preferring its matching Persona look. */
export function personaNavAvatar(
  personas: readonly WorkPersonaLike[] | undefined,
  agent: WorkAgentLike,
  origin?: string,
): Avatar {
  const match = matchWorkPersona(personas, agent);
  const name = match?.name || agent.name;
  const color = match?.color || agentAvatarColor(agent.color_index ?? 0);
  return navAvatar(name, color, match?.avatar_url, origin);
}

/** Map a run's lifecycle state to its animated SVG character state. */
export function runCharacterState(run: { state: string }): CharacterState {
  switch (run.state) {
    case "running":
      return "coding";
    case "waiting":
    case "paused":
      return "needs_you";
    case "queued":
    case "starting":
      return "thinking";
    default:
      return "static";
  }
}
