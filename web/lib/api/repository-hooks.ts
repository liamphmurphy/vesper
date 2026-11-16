"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, ApiError, unwrap, type Schemas } from "./client";
import { chatKeys } from "./hooks";

export function useRepositorySources() {
  return useQuery({ queryKey: ["repository-sources"], queryFn: () => unwrap(api.GET("/repositories/sources")) });
}
export function useRepositories(enabled = true, q = "") {
  return useQuery({ enabled, queryKey: ["repositories", q], queryFn: () => unwrap(api.GET("/repositories", { params: { query: { q } } })), staleTime: 60_000 });
}
export function useSaveRepositorySource(remove = false) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: Schemas["RepositorySource"]) => {
      const { response, error } = await (remove ? api.DELETE("/repositories/sources", { body }) : api.PUT("/repositories/sources", { body }));
      if (!response.ok) { const e = (error ?? {}) as Partial<Schemas["Error"]>; throw new ApiError(response.status, e.code ?? "internal", e.message ?? response.statusText, e.field); }
    },
    onSuccess: () => { qc.invalidateQueries({ queryKey: ["repository-sources"] }); qc.invalidateQueries({ queryKey: ["repositories"] }); },
  });
}
export function useSetChatRepository(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (repository: string) => unwrap(api.PUT("/chats/{id}/repository", { params: { path: { id } }, body: { repository } })),
    onSuccess: (chat) => {
      qc.setQueryData(chatKeys.detail(id), chat);
      qc.invalidateQueries({ queryKey: ["chats"] });
      qc.invalidateQueries({ queryKey: ["playgrounds", id] });
    },
  });
}

/** Presets are discovered from the connected GitHub account; choosing one saves it. */
export function useRepositoryPresets() {
  return useQuery({ queryKey: ["repository-presets"], queryFn: () => unwrap(api.GET("/repositories/presets")), staleTime: 60_000, retry: false });
}

/** Lists all repositories under a GitHub user or organization. */
export function useOwnerRepositories(owner: string, refresh = false) {
  const trimmed = owner.trim();
  return useQuery({
    enabled: trimmed.length > 0,
    queryKey: ["owner-repositories", trimmed, refresh],
    queryFn: () =>
      unwrap(
        api.GET("/repositories/owner/{owner}", {
          params: { path: { owner: trimmed }, query: refresh ? { refresh: true } : undefined },
        }),
      ),
    staleTime: 60_000,
    retry: false,
  });
}
