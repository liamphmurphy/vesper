"use client";

// ---- The Library: the caller's permanent keepsakes from assistant chats.

import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, ApiError, postForm, unwrap, type Schemas } from "./client";

export type LibraryItem = Schemas["LibraryItem"];
export type LibraryItemKind = Schemas["LibraryItemKind"];
export type LibraryReferenceRole = Schemas["LibraryReferenceRole"];
export type LibraryFilePreview = Schemas["LibraryFilePreview"];

export const libraryKeys = {
  all: ["library"] as const,
  list: (kind?: LibraryItemKind) => ["library", "list", kind ?? ""] as const,
  item: (itemId: string) => ["library", "item", itemId] as const,
};

/** One Library item of the caller's, for inline chat cards. */
export function useLibraryItem(itemId: string | undefined) {
  return useQuery({
    enabled: !!itemId,
    queryKey: libraryKeys.item(itemId ?? ""),
    queryFn: () => unwrap(api.GET("/library/{itemId}", { params: { path: { itemId: itemId! } } })),
    staleTime: 30_000,
    retry: false,
  });
}

/** Newest first, a page at a time. */
export function useLibrary(kind?: LibraryItemKind) {
  return useInfiniteQuery({
    queryKey: libraryKeys.list(kind),
    initialPageParam: 0,
    queryFn: ({ pageParam }) =>
      unwrap(api.GET("/library", { params: { query: { ...(kind ? { kind } : {}), ...(pageParam ? { offset: pageParam } : {}) } } })),
    getNextPageParam: (last, pages) => (last.has_more ? pages.reduce((n, p) => n + p.items.length, 0) : undefined),
  });
}

/** Already gone (404) counts as removed. */
export function useDeleteLibraryItem() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (itemId: string) => {
      const { error, response } = await api.DELETE("/library/{itemId}", { params: { path: { itemId } } });
      if (response.ok || response.status === 404) return;
      const e = (error ?? {}) as Partial<Schemas["Error"]>;
      throw new ApiError(response.status, e.code ?? "internal", e.message ?? response.statusText, e.field);
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: libraryKeys.all });
      // A card shows Saved until its link is removed.
      qc.invalidateQueries({ queryKey: ["link-previews"] });
    },
  });
}

/** Multipart POST of one image (PNG, JPEG, GIF or WebP) or audio file (MP3, WAV, OGG or M4A) of the person's own, up to 25 MB. */
export function useUploadLibraryItem() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (file: File) => {
      const form = new FormData();
      form.append("file", file);
      return postForm<LibraryItem>("/library", form);
    },
    onSettled: () => qc.invalidateQueries({ queryKey: libraryKeys.all }),
  });
}

/** A file's first lines, rows or zip entries, read when its dialog opens. */
export function useLibraryFilePreview(itemId: string, enabled: boolean) {
  return useQuery({
    enabled,
    queryKey: ["library", "preview", itemId],
    queryFn: () => unwrap(api.GET("/library/{itemId}/preview", { params: { path: { itemId } } })),
    staleTime: Infinity,
  });
}

/** Retitles one of the caller's items. */
export function useRenameLibraryItem() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { itemId: string; title: string }) =>
      unwrap(api.PATCH("/library/{itemId}", { params: { path: { itemId: v.itemId } }, body: { title: v.title } })),
    onSettled: () => qc.invalidateQueries({ queryKey: libraryKeys.all }),
  });
}

/** Keeps an SVG from an assistant reply. Saving the same one again changes nothing. */
export function useSaveLibraryDiagram() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["LibraryDiagramSave"]) => unwrap(api.POST("/library/diagrams", { body })),
    onSettled: () => qc.invalidateQueries({ queryKey: libraryKeys.all }),
  });
}

/** Keeps a link a reply recommends. Saving the same one again changes nothing. */
export function useSaveLibraryLink() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["LibraryLinkSave"]) => unwrap(api.POST("/library/links", { body })),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: libraryKeys.all });
      qc.invalidateQueries({ queryKey: ["link-previews"] });
    },
  });
}

/** Keeps a reply as the summary of a link, saving the link too if it isn't yet. */
export function useSaveLibraryLinkSummary() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["LibraryLinkSummarySave"]) => unwrap(api.POST("/library/links/summary", { body })),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: libraryKeys.all });
      qc.invalidateQueries({ queryKey: ["link-previews"] });
    },
  });
}

export function useSetLibraryLinkStatus() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { itemId: string; status: Schemas["LibraryLinkStatus"] }) => {
      const { error, response } = await api.PUT("/library/{itemId}/link-status", { params: { path: { itemId: v.itemId } }, body: { status: v.status } });
      if (response.ok) return;
      const e = (error ?? {}) as Partial<Schemas["Error"]>;
      throw new ApiError(response.status, e.code ?? "internal", e.message ?? response.statusText, e.field);
    },
    onSettled: () => qc.invalidateQueries({ queryKey: libraryKeys.all }),
  });
}

/** Makes the item the person's (role self) or a persona's reference image, replacing the previous one. */
export function useSetLibraryReference() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { itemId: string; role: LibraryReferenceRole; personaId?: string }) => {
      const body = v.role === "persona" ? { role: v.role, persona_id: v.personaId } : { role: v.role };
      const { error, response } = await api.PUT("/library/{itemId}/reference", { params: { path: { itemId: v.itemId } }, body });
      if (response.ok) return;
      const e = (error ?? {}) as Partial<Schemas["Error"]>;
      throw new ApiError(response.status, e.code ?? "internal", e.message ?? response.statusText, e.field);
    },
    onSettled: () => qc.invalidateQueries({ queryKey: libraryKeys.all }),
  });
}

/** The image stays in the Library; it just stops being a reference. */
export function useClearLibraryReference() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (itemId: string) => {
      const { error, response } = await api.DELETE("/library/{itemId}/reference", { params: { path: { itemId } } });
      if (response.ok) return;
      const e = (error ?? {}) as Partial<Schemas["Error"]>;
      throw new ApiError(response.status, e.code ?? "internal", e.message ?? response.statusText, e.field);
    },
    onSettled: () => qc.invalidateQueries({ queryKey: libraryKeys.all }),
  });
}
