"use client";

// MCP connectors and scheduled tasks.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./client";
import { confirmApprovalLocally } from "../desktop-bridge";

export type Connector = Schemas["Connector"];
export type NewConnector = Schemas["NewConnector"];
export type ConnectorPatch = Schemas["ConnectorPatch"];
export type ScheduledTask = Schemas["ScheduledTask"];
export type ScheduledTaskInput = Schemas["ScheduledTaskInput"];

const POLL_MS = 5000;
const connectorKey = ["connectors"] as const;
const taskKey = ["scheduled-tasks"] as const;

export function useConnectors() {
  return useQuery({ queryKey: connectorKey, refetchInterval: POLL_MS, queryFn: () => unwrap(api.GET("/connectors")) });
}

function useConnectorInvalidate() {
  const qc = useQueryClient();
  return () => qc.invalidateQueries({ queryKey: connectorKey });
}

export function useProbeConnector() {
  return useMutation({ mutationFn: (body: Schemas["ConnectorProbeRequest"]) => unwrap(api.POST("/connectors/probe", { body })) });
}

export function useCreateConnector() {
  const done = useConnectorInvalidate();
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: NewConnector) => unwrap(api.POST("/connectors", { body })),
    onSettled: () => Promise.all([done(), qc.invalidateQueries({ queryKey: ["connector-proposals"] })]),
  });
}

export function useUpdateConnector() {
  const done = useConnectorInvalidate();
  return useMutation({
    mutationFn: (v: { id: string; patch: ConnectorPatch }) => unwrap(api.PATCH("/connectors/{id}", { params: { path: { id: v.id } }, body: v.patch })),
    onSettled: done,
  });
}

export function useDeleteConnector() {
  const done = useConnectorInvalidate();
  return useMutation({ mutationFn: (id: string) => unwrap(api.DELETE("/connectors/{id}", { params: { path: { id } } })), onSettled: done });
}

export function useTestConnector() {
  const done = useConnectorInvalidate();
  return useMutation({ mutationFn: (id: string) => unwrap(api.POST("/connectors/{id}/test", { params: { path: { id } } })), onSettled: done });
}

export function useAuthorizeConnector() {
  return useMutation({ mutationFn: (id: string) => unwrap(api.POST("/connectors/{id}/authorize", { params: { path: { id } } })) });
}

export function useConnectorApprovals(chatId: string) {
  return useQuery({
    queryKey: ["connector-approvals", chatId],
    refetchInterval: 2000,
    queryFn: () => unwrap(api.GET("/chats/{id}/connector-approvals", { params: { path: { id: chatId } } })),
  });
}

export function useDecideConnectorApproval(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { id: string; decision: Schemas["ConnectorApprovalDecision"]["decision"] }) => {
      if (v.decision !== "deny") await confirmApprovalLocally("connector_approvals");
      return unwrap(api.POST("/connector-approvals/{id}", { params: { path: { id: v.id } }, body: { decision: v.decision } }));
    },
    onSettled: () => qc.invalidateQueries({ queryKey: ["connector-approvals", chatId] }),
  });
}

export function useConnectorProposals(chatId: string) {
  return useQuery({
    queryKey: ["connector-proposals", chatId],
    refetchInterval: 5000,
    queryFn: () => unwrap(api.GET("/chats/{id}/connector-proposals", { params: { path: { id: chatId } } })),
  });
}

export function useDeclineConnectorProposal() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => unwrap(api.POST("/connector-proposals/{id}/decline", { params: { path: { id } } })),
    onSettled: () => qc.invalidateQueries({ queryKey: ["connector-proposals"] }),
  });
}

export function useScheduledTasks(enabled = true) {
  return useQuery({ enabled, queryKey: taskKey, refetchInterval: POLL_MS, queryFn: () => unwrap(api.GET("/scheduled-tasks")) });
}

function useTaskInvalidate() {
  const qc = useQueryClient();
  return () => qc.invalidateQueries({ queryKey: taskKey });
}

export function useSaveScheduledTask() {
  const done = useTaskInvalidate();
  return useMutation({
    mutationFn: (v: { id?: string; body: ScheduledTaskInput }) =>
      v.id ? unwrap(api.PUT("/scheduled-tasks/{id}", { params: { path: { id: v.id } }, body: v.body })) : unwrap(api.POST("/scheduled-tasks", { body: v.body })),
    onSettled: done,
  });
}

export function useDeleteScheduledTask() {
  const done = useTaskInvalidate();
  return useMutation({ mutationFn: (id: string) => unwrap(api.DELETE("/scheduled-tasks/{id}", { params: { path: { id } } })), onSettled: done });
}

export function useRunScheduledTask() {
  const done = useTaskInvalidate();
  return useMutation({ mutationFn: (id: string) => unwrap(api.POST("/scheduled-tasks/{id}/run", { params: { path: { id } } })), onSettled: done });
}
