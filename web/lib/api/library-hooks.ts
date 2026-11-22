"use client";

// ---- The Library: the caller's permanent keepsakes from assistant chats.

import { useInfiniteQuery, useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./client";
export type LibraryItemKind = Schemas["LibraryItemKind"];

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

