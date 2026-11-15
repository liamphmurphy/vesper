"use client";

// ---- Assistant personas (ADR: Assistant personas). SSE `persona.updated` invalidates ["personas"] and ["chats"].

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, ApiError, postForm, unwrap, type Schemas } from "./client";
import { withDefault } from "../persona-ui";

export type Persona = Schemas["Persona"];
export type PersonaList = Schemas["PersonaList"];
export type PersonaTone = Schemas["PersonaTone"];
export type NewPersona = Schemas["NewPersona"];
export type PersonaPatch = Schemas["PersonaPatch"];

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

/** A persona change also changes the summary embedded in chats and any linked work record. */
function usePersonaInvalidate() {
  const qc = useQueryClient();
  return () =>
    Promise.all([
      qc.invalidateQueries({ queryKey: personaKeys.all }),
      qc.invalidateQueries({ queryKey: ["chats"] }),
      qc.invalidateQueries({ queryKey: ["agents"] }),
      qc.invalidateQueries({ queryKey: ["agent-overviews"] }),
      qc.invalidateQueries({ queryKey: ["bootstrap"] }),
    ]);
}

export function useCreatePersona() {
  const done = usePersonaInvalidate();
  return useMutation({
    mutationFn: (body: NewPersona) => unwrap(api.POST("/personas", { body })),
    onSettled: done,
  });
}

/** Revision-checked; a stale revision is a 409 ApiError. */
export function useUpdatePersona() {
  const done = usePersonaInvalidate();
  return useMutation({
    mutationFn: (v: { id: string; patch: PersonaPatch }) =>
      unwrap(api.PATCH("/personas/{id}", { params: { path: { id: v.id } }, body: v.patch })),
    onSettled: done,
  });
}

/**
 * Deletes a persona. When `nextDefault` is given (deleting the default), that
 * persona is made the default first, so the server doesn't pick one itself.
 * Already gone counts as done.
 */
export function useDeletePersona() {
  const done = usePersonaInvalidate();
  return useMutation({
    mutationFn: async (v: { id: string; revision?: number; nextDefault?: string }) => {
      if (v.nextDefault)
        await unwrap(api.POST("/personas/{id}/default", { params: { path: { id: v.nextDefault } } }));
      const { error, response } = await api.DELETE("/personas/{id}", {
        params: { path: { id: v.id }, query: v.revision === undefined || v.nextDefault ? {} : { revision: v.revision } },
      });
      if (response.ok || response.status === 404) return;
      const e = (error ?? {}) as Partial<Schemas["Error"]>;
      throw new ApiError(response.status, e.code ?? "internal", e.message ?? response.statusText, e.field);
    },
    onSettled: done,
  });
}

/** Moves the Default badge at once; the refetch (or persona.updated) confirms it. */
export function useSetDefaultPersona() {
  const qc = useQueryClient();
  const done = usePersonaInvalidate();
  return useMutation({
    mutationFn: (id: string) => unwrap(api.POST("/personas/{id}/default", { params: { path: { id } } })),
    onMutate: async (id) => {
      await qc.cancelQueries({ queryKey: personaKeys.list });
      const before = qc.getQueryData<PersonaList>(personaKeys.list);
      if (before) qc.setQueryData<PersonaList>(personaKeys.list, { personas: withDefault(before.personas, id), default_persona_id: id });
      return { before };
    },
    onError: (_e, _id, ctx) => {
      if (ctx?.before) qc.setQueryData(personaKeys.list, ctx.before);
    },
    onSettled: done,
  });
}

/** Multipart PUT; the server sniffs the bytes (413 too large, 415 wrong type, 422 empty). */
export function useUploadPersonaAvatar() {
  const done = usePersonaInvalidate();
  return useMutation({
    mutationFn: (v: { id: string; file: File }) => {
      const form = new FormData();
      form.append("file", v.file);
      return postForm<Persona>(`/personas/${encodeURIComponent(v.id)}/avatar`, form, "PUT");
    },
    onSettled: done,
  });
}

export function useDeletePersonaAvatar() {
  const done = usePersonaInvalidate();
  return useMutation({
    mutationFn: (id: string) => unwrap(api.DELETE("/personas/{id}/avatar", { params: { path: { id } } })),
    onSettled: done,
  });
}
