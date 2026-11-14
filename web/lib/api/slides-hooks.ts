"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, postForm, unwrap, type Schemas } from "./client";
import { libraryKeys } from "./library-hooks";
import type { paths } from "./schema";

// ---- The Slides app: the person's decks, each a deck canvas in its own chat.

/** Keeps one finished export (PDF or PowerPoint), linked to its deck, in the person's Library. */
export function useSaveDeckExport(deckId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (file: File) => {
      const form = new FormData();
      form.append("file", file);
      return postForm<Schemas["LibraryItem"]>(`/slides/${deckId}/library`, form);
    },
    onSettled: () => void qc.invalidateQueries({ queryKey: libraryKeys.all }),
  });
}

export type DeckSummary = Schemas["DeckSummary"];
export type DeckRef = Schemas["MyCanvas"];
export type SavedTheme = Schemas["SlideTheme"];
export type SlideStarter = Schemas["SlideStarter"];
export type StarterKey = NonNullable<CreateDeckBody["starter"]>;
type CreateDeckBody = NonNullable<paths["/slides"]["post"]["requestBody"]>["content"]["application/json"];

// Under ["canvases"], so a persona's turn on a deck refreshes the list (SSE chat.* invalidates it).
export const slideKeys = {
  list: ["canvases", "decks"] as const,
  one: (id: string) => ["canvases", "mine", id] as const,
  themes: ["slide-themes"] as const,
  starters: ["slide-starters"] as const,
};

/** One deck with the chat it lives in (the same endpoint Docs uses). */
export function useDeckRef(id: string) {
  return useQuery({ queryKey: slideKeys.one(id), queryFn: () => unwrap(api.GET("/canvases/{canvasId}", { params: { path: { canvasId: id } } })) });
}

export function useCreateDeck() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { title: string; theme?: NonNullable<CreateDeckBody["theme"]>; starter?: StarterKey }) => unwrap(api.POST("/slides", { body })),
    onSettled: () => void qc.invalidateQueries({ queryKey: slideKeys.list }),
  });
}

/** Stores an image for a deck; the caller adds it to the deck's assets. */
export async function uploadDeckAsset(canvasId: string, file: Blob): Promise<Schemas["DeckAsset"]> {
  const form = new FormData();
  form.append("file", file);
  const r = await fetch(`/api/v1/slides/${canvasId}/assets`, { method: "POST", body: form, credentials: "same-origin" });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error((body as { message?: string }).message ?? `Upload failed (${r.status})`);
  return body as Schemas["DeckAsset"];
}

// ---- Saved themes: the person's own, offered in every deck's theme menu.

/** The New deck chooser's starter decks; fixed per server build. */
export function useSlideStarters() {
  return useQuery({ queryKey: slideKeys.starters, queryFn: () => unwrap(api.GET("/slide-starters")), select: (d) => d.starters, staleTime: Infinity });
}

export function useSlideThemes() {
  return useQuery({ queryKey: slideKeys.themes, queryFn: () => unwrap(api.GET("/slide-themes")), select: (d) => d.themes });
}

export function useCreateSlideTheme() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["SlideThemeInput"]) => unwrap(api.POST("/slide-themes", { body })),
    onSettled: () => void qc.invalidateQueries({ queryKey: slideKeys.themes }),
  });
}

export function useUpdateSlideTheme() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: { id: string } & Partial<Schemas["SlideThemeInput"]>) => unwrap(api.PATCH("/slide-themes/{themeId}", { params: { path: { themeId: id } }, body })),
    onSettled: () => void qc.invalidateQueries({ queryKey: slideKeys.themes }),
  });
}

export function useDeleteSlideTheme() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const { error } = await api.DELETE("/slide-themes/{themeId}", { params: { path: { themeId: id } } });
      if (error) throw new Error(error.message);
    },
    onSettled: () => void qc.invalidateQueries({ queryKey: slideKeys.themes }),
  });
}
