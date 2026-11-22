"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./client";

export type Workflow = Schemas["Workflow"];
export type WorkflowRun = Schemas["WorkflowRun"];

const active = (runs: WorkflowRun[] | undefined) => runs?.some((r) => r.state === "running" || r.state === "waiting");

const keys = {
  all: ["workflows"] as const,
  one: (id: string) => ["workflows", id] as const,
  runs: ["workflows", "runs"] as const,
  run: (id: string) => ["workflows", "runs", id] as const,
  chat: (id: string) => ["workflows", "chat", id] as const,
};

export function useWorkflows(enabled = true) {
  return useQuery({ enabled, queryKey: keys.all, queryFn: () => unwrap(api.GET("/workflows")) });
}

export function useChatWorkflowRuns(chatId?: string) {
  return useQuery({
    enabled: !!chatId,
    queryKey: keys.chat(chatId ?? ""),
    queryFn: () => unwrap(api.GET("/chats/{id}/workflows", { params: { path: { id: chatId! } } })),
    refetchInterval: (q) => (active(q.state.data?.runs) ? 3000 : false),
  });
}

export function useStartWorkflow(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["WorkflowRunStart"]) => unwrap(api.POST("/chats/{id}/workflows", { params: { path: { id: chatId } }, body })),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.chat(chatId) }),
  });
}

export function useDecideGate(runId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["WorkflowGateDecision"]) => unwrap(api.POST("/workflow-runs/{id}/gate", { params: { path: { id: runId } }, body })),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.all }),
  });
}

export function useStopWorkflowRun(runId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => unwrap(api.POST("/workflow-runs/{id}/stop", { params: { path: { id: runId } } })),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.all }),
  });
}
