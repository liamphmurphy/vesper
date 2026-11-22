"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./client";

export type Playground = Schemas["Playground"];
export type PlaygroundAction = "start" | "reset" | "stop";

// SSE `playground.updated` invalidates ["playgrounds"] as the runner moves it
// along. While it starts or an action is pending it also polls, in case an
// event is missed.
const BUSY_MS = 2000;

type State = Schemas["ChatPlaygroundState"];

const busy = (p: Playground | null | undefined) => !!p && (p.state === "starting" || !!p.action);

function useChatPlaygroundState<T>(chatId: string | undefined, select: (s: State) => T) {
  return useQuery({
    enabled: !!chatId,
    queryKey: ["playgrounds", chatId ?? ""],
    queryFn: () => unwrap(api.GET("/chats/{id}/playground", { params: { path: { id: chatId! } } })),
    select,
    refetchInterval: (q) => (busy(q.state.data?.playground) ? BUSY_MS : false),
  });
}

/** A chat's playground, or null when it has none. */
export function useChatPlayground(chatId?: string) {
  return useChatPlaygroundState(chatId, (s) => s.playground ?? null);
}

/** Start an ended playground again (or a chat's first, from the saved spec), reset its data, or stop it. */
export function usePlaygroundAction(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (action: PlaygroundAction) => unwrap(api.POST("/chats/{id}/playground/{action}", { params: { path: { id: chatId, action } } })),
    onSuccess: (pg) => qc.setQueryData<State>(["playgrounds", chatId], (old) => ({ saved_spec: old?.saved_spec ?? false, playground: pg })),
  });
}
