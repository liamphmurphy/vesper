"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./client";

export type DevWorkspace = Schemas["DevWorkspace"];
export type UpdateDevWorkspace = Schemas["UpdateDevWorkspace"];
export type DevWorkspaceActionKind = Schemas["DevWorkspaceActionRequest"]["action"];
export type OpenDevWorkspaceBranch = Schemas["OpenDevWorkspaceBranchRequest"];

const BUSY_MS = 2000;

export function useDevWorkspace() {
  return useQuery({
    queryKey: ["dev-workspace"],
    queryFn: () => unwrap(api.GET("/dev-workspace")),
    refetchInterval: (q) => {
      const d = q.state.data;
      return d && (d.state === "starting" || !!d.action) ? BUSY_MS : false;
    },
  });
}

export function useUpdateDevWorkspace() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: UpdateDevWorkspace) => unwrap(api.PATCH("/dev-workspace", { body })),
    onSuccess: (ws) => qc.setQueryData<DevWorkspace>(["dev-workspace"], ws),
  });
}

export function useDevWorkspaceAction() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (action: DevWorkspaceActionKind) => unwrap(api.POST("/dev-workspace/action", { body: { action } })),
    onSuccess: (ws) => qc.setQueryData<DevWorkspace>(["dev-workspace"], ws),
  });
}

export function useOpenDevWorkspaceBranch() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: OpenDevWorkspaceBranch) => unwrap(api.POST("/dev-workspace/open-branch", { body })),
    onSuccess: (ws) => qc.setQueryData<DevWorkspace>(["dev-workspace"], ws),
  });
}
