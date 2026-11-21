"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./client";

// SSE `audio.updated` invalidates ["audio"] as renders or music jobs progress.
// Poll while a turn runs OR any chat audio job is still running (e.g. standalone music).
const LIVE_MS = 3000;

export type StartChatMusicBody = Schemas["StartChatMusicRequest"];

/** A chat's audio, oldest first. */
export function useChatAudio(chatId?: string, live?: boolean) {
  return useQuery({
    enabled: !!chatId,
    queryKey: ["audio", chatId ?? ""],
    queryFn: () => unwrap(api.GET("/chats/{id}/audio", { params: { path: { id: chatId! } } })),
    refetchInterval: (query) =>
      live || query.state.data?.audio?.some((a) => a.state === "running") ? LIVE_MS : false,
  });
}

export function useStartChatMusic(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: StartChatMusicBody) =>
      unwrap(api.POST("/chats/{id}/music", { params: { path: { id: chatId } }, body })),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["audio", chatId] }),
  });
}

export function useStopChatAudio(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (audioId: string) =>
      unwrap(api.POST("/chats/{id}/audio/{audioId}/stop", { params: { path: { id: chatId, audioId } } })),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["audio", chatId] }),
  });
}
