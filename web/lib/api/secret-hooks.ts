"use client";

// API secrets: values personas use in requests without ever seeing them.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./client";

export type ApiSecret = Schemas["ApiSecret"];
export type NewApiSecret = Schemas["NewApiSecret"];
export type ApiSecretPatch = Schemas["ApiSecretPatch"];
export type ApiSecretPlacement = Schemas["ApiSecretPlacement"];
export type ApiSecretPolicy = Schemas["ApiSecretPolicy"];

const secretKey = ["api-secrets"] as const;

export function useApiSecrets() {
  return useQuery({ queryKey: secretKey, refetchInterval: 15000, queryFn: () => unwrap(api.GET("/api-secrets")) });
}

function useSecretInvalidate() {
  const qc = useQueryClient();
  return () => qc.invalidateQueries({ queryKey: secretKey });
}

export function useCreateApiSecret() {
  const done = useSecretInvalidate();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: NewApiSecret) => unwrap(api.POST("/api-secrets", { body })),
    onSettled: () => Promise.all([done(), qc.invalidateQueries({ queryKey: ["api-secret-proposals"] })]),
  });
}

export function useUpdateApiSecret() {
  const done = useSecretInvalidate();
  return useMutation({
    mutationFn: (v: { id: string; patch: ApiSecretPatch }) => unwrap(api.PATCH("/api-secrets/{id}", { params: { path: { id: v.id } }, body: v.patch })),
    onSettled: done,
  });
}

/** Starts an OAuth secret's sign-in; open the returned authorize_url to finish it. */
export function useSignInApiSecret() {
  const done = useSecretInvalidate();
  return useMutation({
    mutationFn: (id: string) => unwrap(api.POST("/api-secrets/{id}/sign-in", { params: { path: { id } } })),
    onSettled: done,
  });
}

export function useDeleteApiSecret() {
  const done = useSecretInvalidate();
  return useMutation({ mutationFn: (id: string) => unwrap(api.DELETE("/api-secrets/{id}", { params: { path: { id } } })), onSettled: done });
}

export function useApiSecretCalls(id: string) {
  return useQuery({
    queryKey: ["api-secret-calls", id],
    refetchInterval: 10000,
    queryFn: () => unwrap(api.GET("/api-secrets/{id}/calls", { params: { path: { id } } })),
  });
}

export function useChatApiSecrets(chatId: string) {
  return useQuery({
    queryKey: ["chat-api-secrets", chatId],
    refetchInterval: 5000,
    queryFn: () => unwrap(api.GET("/chats/{id}/api-secrets", { params: { path: { id: chatId } } })),
  });
}

export function useDisableChatApiSecret(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (secretId: string) => unwrap(api.POST("/chats/{id}/api-secrets/{secret_id}/disable", { params: { path: { id: chatId, secret_id: secretId } } })),
    onSettled: () => qc.invalidateQueries({ queryKey: ["chat-api-secrets", chatId] }),
  });
}

export function useApiSecretApprovals(chatId: string) {
  return useQuery({
    queryKey: ["api-secret-approvals", chatId],
    refetchInterval: 2000,
    queryFn: () => unwrap(api.GET("/chats/{id}/api-secret-approvals", { params: { path: { id: chatId } } })),
  });
}

export function useDecideApiSecretApproval(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { id: string; decision: Schemas["ConnectorApprovalDecision"]["decision"] }) =>
      unwrap(api.POST("/api-secret-approvals/{id}", { params: { path: { id: v.id } }, body: { decision: v.decision } })),
    onSettled: () => Promise.all([qc.invalidateQueries({ queryKey: ["api-secret-approvals", chatId] }), qc.invalidateQueries({ queryKey: secretKey })]),
  });
}

export function useApiSecretProposals(chatId: string) {
  return useQuery({
    queryKey: ["api-secret-proposals", chatId],
    refetchInterval: 5000,
    queryFn: () => unwrap(api.GET("/chats/{id}/api-secret-proposals", { params: { path: { id: chatId } } })),
  });
}

export function useDeclineApiSecretProposal() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => unwrap(api.POST("/api-secret-proposals/{id}/decline", { params: { path: { id } } })),
    onSettled: () => qc.invalidateQueries({ queryKey: ["api-secret-proposals"] }),
  });
}
