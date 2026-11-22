"use client";

// ---- Assistant personas (ADR: Assistant personas). SSE `persona.updated` invalidates ["personas"] and ["chats"].

import { useQuery } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./client";

export type Persona = Schemas["Persona"];

export const personaKeys = {
  all: ["personas"] as const,
  list: ["personas", "list"] as const,
  detail: (id: string) => ["personas", "detail", id] as const,
};

/** The caller's personas, default first. */
export function usePersonas() {
  return useQuery({
    queryKey: personaKeys.list,
    queryFn: () => unwrap(api.GET("/personas")),
  });
}
