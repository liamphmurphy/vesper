"use client";

// A coding chat's Code dock (each repository's branch as the runner last read
// it) and the pushes a persona asked for, which wait for the person.
// SSE code_review.updated and push_request.updated invalidate these.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./client";
import { confirmApprovalLocally } from "../desktop-bridge";

export type CodeReview = Schemas["CodeReview"];
export type PushRequest = Schemas["PushRequest"];
export type PushDecision = Schemas["PushRequestDecision"];

const reviewKey = (chatId: string) => ["code-review", chatId] as const;
const pushKey = (chatId: string) => ["push-requests", chatId] as const;

export function useCodeReview(chatId: string | undefined) {
  return useQuery({
    queryKey: reviewKey(chatId ?? ""),
    enabled: !!chatId,
    queryFn: () => unwrap(api.GET("/chats/{id}/code-review", { params: { path: { id: chatId! } } })),
  });
}

export function usePushRequests(chatId: string | undefined, live?: boolean) {
  return useQuery({
    queryKey: pushKey(chatId ?? ""),
    enabled: !!chatId,
    queryFn: () => unwrap(api.GET("/chats/{id}/push-requests", { params: { path: { id: chatId! } } })),
    refetchInterval: live ? 3000 : false,
  });
}

export function useDecidePush(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { id: string } & PushDecision) => {
      const { id, ...body } = v;
      if (body.decision !== "deny") await confirmApprovalLocally("push_requests");
      return unwrap(api.POST("/push-requests/{id}", { params: { path: { id } }, body }));
    },
    onSettled: () =>
      Promise.all([qc.invalidateQueries({ queryKey: pushKey(chatId) }), qc.invalidateQueries({ queryKey: ["push-policies"] })]),
  });
}

export function usePushPolicies() {
  return useQuery({
    queryKey: ["push-policies"],
    queryFn: () => unwrap(api.GET("/repository-push-policies")),
  });
}

export function useSetPushPolicy() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: Schemas["RepositoryPushPolicy"]) => unwrap(api.PUT("/repository-push-policies", { body: v })),
    onSettled: () => qc.invalidateQueries({ queryKey: ["push-policies"] }),
  });
}
