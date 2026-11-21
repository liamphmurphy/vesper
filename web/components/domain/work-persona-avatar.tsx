"use client";

import { usePersonas } from "@/lib/api/persona-hooks";
import { agentAvatarColor } from "@/lib/native-shell/models/common";
import type { CharacterState } from "@/lib/persona-character";
import { matchWorkPersona, type WorkAgentLike } from "@/lib/work-persona";
import { PersonaAvatar } from "./persona-avatar";

const SIZES = {
  sm: 20,
  md: 24,
  lg: 38,
  stack: 22,
} as const;

export type WorkPersonaAvatarSize = keyof typeof SIZES | number;

/**
 * Renders a Work agent/assignee reference using its matching Persona avatar
 * (animated SVG character, uploaded photo, or circular colored initial),
 * falling back to a circular initial in the agent's palette hue.
 */
export function WorkPersonaAvatar({
  agent,
  size = "sm",
  state = "static",
  framed = true,
  className,
}: {
  agent: WorkAgentLike;
  size?: WorkPersonaAvatarSize;
  state?: CharacterState;
  framed?: boolean;
  className?: string;
}) {
  const personas = usePersonas();
  const match = matchWorkPersona(personas.data?.personas, agent);
  const px = typeof size === "number" ? size : SIZES[size];
  const color = match?.color || agentAvatarColor(agent.color_index ?? 0);
  return (
    <PersonaAvatar
      name={match?.name ?? agent.name}
      color={color}
      src={match?.avatar_url ?? undefined}
      characterSvg={match?.character_svg ?? undefined}
      state={state}
      framed={framed}
      size={px}
      className={className}
    />
  );
}
