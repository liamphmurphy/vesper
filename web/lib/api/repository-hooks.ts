"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap } from "./client";
import { chatKeys } from "./hooks";
export function useRepositories(enabled = true, q = "") {
  return useQuery({ enabled, queryKey: ["repositories", q], queryFn: () => unwrap(api.GET("/repositories", { params: { query: { q } } })), staleTime: 60_000 });
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
