"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ApiError } from "./client";

export type AuthType = "inherit" | "none" | "bearer" | "basic" | "apikey" | "oauth2";
export type BodyMode = "none" | "json" | "raw" | "form_urlencoded" | "multipart";
export type EnvColor = "green" | "amber" | "red" | "blue" | "purple" | "gray";

export type KeyValue = {
  key: string;
  value: string;
  enabled: boolean;
};

export type EnvVar = {
  key: string;
  value: string;
  secret_handle?: string;
  enabled: boolean;
};

export type OAuth2Config = {
  grant_type?: string;
  token_url?: string;
  client_id?: string;
  client_secret?: string;
  scope?: string;
  audience?: string;
};

export type AuthConfig = {
  type: AuthType;
  token?: string;
  username?: string;
  password?: string;
  api_key_name?: string;
  api_key_value?: string;
  api_key_in?: "header" | "query";
  oauth2?: OAuth2Config;
};

export type HttpWorkspace = {
  id: string;
  name: string;
  description: string;
  active_environment_id: string | null;
  default_auth: AuthConfig;
  default_headers: KeyValue[];
  default_vars: EnvVar[];
  created_at: string;
  updated_at: string;
};

export type HttpEnvironment = {
  id: string;
  http_workspace_id: string;
  name: string;
  color: EnvColor;
  variables: EnvVar[];
  sort_order: number;
  created_at: string;
  updated_at: string;
};

export type HttpFolder = {
  id: string;
  http_workspace_id: string;
  parent_folder_id: string | null;
  name: string;
  default_auth: AuthConfig;
  default_headers: KeyValue[];
  sort_order: number;
  created_at: string;
  updated_at: string;
};

export type HttpRequest = {
  id: string;
  http_workspace_id: string;
  folder_id: string | null;
  name: string;
  method: string;
  url: string;
  params: KeyValue[];
  headers: KeyValue[];
  auth: AuthConfig;
  body_mode: BodyMode;
  body: string;
  body_form: KeyValue[];
  timeout_ms: number;
  follow_redirects: boolean;
  sort_order: number;
  created_at: string;
  updated_at: string;
};

export type HttpExecution = {
  id: string;
  http_workspace_id: string;
  request_id: string | null;
  environment_id: string | null;
  environment_name: string;
  method: string;
  resolved_url: string;
  request_headers: Record<string, string>;
  request_body: string;
  status_code: number;
  status_text: string;
  duration_ms: number;
  size_bytes: number;
  response_headers: Record<string, string[]>;
  response_body: string;
  response_truncated: boolean;
  error?: string;
  created_at: string;
};

export type HttpWorkspaceBundle = {
  workspace: HttpWorkspace;
  environments: HttpEnvironment[];
  folders: HttpFolder[];
  requests: HttpRequest[];
};

export type ImportResult = {
  folders_created: number;
  requests_created: number;
  environments_created: number;
  warnings?: string[];
};

async function httpJson<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`/api/v1${path}`, {
    ...init,
    headers: {
      "Content-Type": "application/json",
      ...(init?.headers ?? {}),
    },
  });
  if (res.status === 204) return undefined as T;
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = body as { code?: string; message?: string; field?: string };
    throw new ApiError(res.status, err.code ?? "internal", err.message ?? res.statusText, err.field);
  }
  return body as T;
}

const keys = {
  workspaces: ["http-client", "workspaces"] as const,
  bundle: (id: string) => ["http-client", "bundle", id] as const,
  reqExecs: (id: string) => ["http-client", "executions", "request", id] as const,
};

export function useHttpWorkspaces() {
  return useQuery({
    queryKey: keys.workspaces,
    queryFn: () => httpJson<{ workspaces: HttpWorkspace[] }>("/http/workspaces").then((r) => r.workspaces),
  });
}

export function useHttpWorkspaceBundle(id: string | null) {
  return useQuery({
    queryKey: id ? keys.bundle(id) : ["http-client", "bundle", "none"],
    enabled: Boolean(id),
    queryFn: () => httpJson<HttpWorkspaceBundle>(`/http/workspaces/${id}`),
  });
}

export function useHttpRequestExecutions(requestId: string | null) {
  return useQuery({
    queryKey: requestId ? keys.reqExecs(requestId) : ["http-client", "executions", "none"],
    enabled: Boolean(requestId),
    queryFn: () => httpJson<{ executions: HttpExecution[] }>(`/http/requests/${requestId}/executions?limit=25`).then((r) => r.executions),
  });
}

export function useCreateHttpWorkspace() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: {
      name: string;
      description?: string;
      seed_environments?: boolean;
      default_auth?: AuthConfig;
      default_headers?: KeyValue[];
      default_vars?: EnvVar[];
    }) => httpJson<HttpWorkspaceBundle>("/http/workspaces", { method: "POST", body: JSON.stringify(body) }),
    onSuccess: (bundle) => {
      qc.invalidateQueries({ queryKey: keys.workspaces });
      qc.setQueryData(keys.bundle(bundle.workspace.id), bundle);
    },
  });
}

export function useUpdateHttpWorkspace() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: {
      id: string;
      name: string;
      description: string;
      active_environment_id: string | null;
      default_auth: AuthConfig;
      default_headers: KeyValue[];
      default_vars: EnvVar[];
    }) => httpJson<HttpWorkspace>(`/http/workspaces/${id}`, { method: "PUT", body: JSON.stringify(body) }),
    onSuccess: (ws) => {
      qc.invalidateQueries({ queryKey: keys.workspaces });
      qc.invalidateQueries({ queryKey: keys.bundle(ws.id) });
    },
  });
}

export function useSetHttpActiveEnvironment() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ workspaceId, environmentId }: { workspaceId: string; environmentId: string | null }) =>
      httpJson<HttpWorkspace>(`/http/workspaces/${workspaceId}/active-environment`, {
        method: "PATCH",
        body: JSON.stringify({ environment_id: environmentId }),
      }),
    onSuccess: (ws) => {
      qc.invalidateQueries({ queryKey: keys.workspaces });
      qc.invalidateQueries({ queryKey: keys.bundle(ws.id) });
    },
  });
}

export function useDeleteHttpWorkspace() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => httpJson<void>(`/http/workspaces/${id}`, { method: "DELETE" }),
    onSuccess: () => qc.invalidateQueries({ queryKey: keys.workspaces }),
  });
}

export function useCreateHttpEnvironment(workspaceId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { name: string; color: EnvColor; variables: EnvVar[]; sort_order?: number }) =>
      httpJson<HttpEnvironment>(`/http/workspaces/${workspaceId}/environments`, { method: "POST", body: JSON.stringify(body) }),
    onSuccess: () => {
      if (workspaceId) qc.invalidateQueries({ queryKey: keys.bundle(workspaceId) });
    },
  });
}

export function useUpdateHttpEnvironment(workspaceId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: { id: string; name: string; color: EnvColor; variables: EnvVar[]; sort_order?: number }) =>
      httpJson<HttpEnvironment>(`/http/environments/${id}`, { method: "PUT", body: JSON.stringify(body) }),
    onSuccess: () => {
      if (workspaceId) qc.invalidateQueries({ queryKey: keys.bundle(workspaceId) });
    },
  });
}

export function useDeleteHttpEnvironment(workspaceId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => httpJson<void>(`/http/environments/${id}`, { method: "DELETE" }),
    onSuccess: () => {
      if (workspaceId) qc.invalidateQueries({ queryKey: keys.bundle(workspaceId) });
    },
  });
}

export function useCreateHttpFolder(workspaceId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: {
      parent_folder_id?: string | null;
      name: string;
      default_auth?: AuthConfig;
      default_headers?: KeyValue[];
    }) => httpJson<HttpFolder>(`/http/workspaces/${workspaceId}/folders`, { method: "POST", body: JSON.stringify(body) }),
    onSuccess: () => {
      if (workspaceId) qc.invalidateQueries({ queryKey: keys.bundle(workspaceId) });
    },
  });
}

export function useUpdateHttpFolder(workspaceId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: {
      id: string;
      parent_folder_id: string | null;
      name: string;
      default_auth: AuthConfig;
      default_headers: KeyValue[];
      sort_order?: number;
    }) => httpJson<HttpFolder>(`/http/folders/${id}`, { method: "PUT", body: JSON.stringify(body) }),
    onSuccess: () => {
      if (workspaceId) qc.invalidateQueries({ queryKey: keys.bundle(workspaceId) });
    },
  });
}

export function useDeleteHttpFolder(workspaceId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => httpJson<void>(`/http/folders/${id}`, { method: "DELETE" }),
    onSuccess: () => {
      if (workspaceId) qc.invalidateQueries({ queryKey: keys.bundle(workspaceId) });
    },
  });
}

export type RequestDraftInput = {
  folder_id: string | null;
  name: string;
  method: string;
  url: string;
  params: KeyValue[];
  headers: KeyValue[];
  auth: AuthConfig;
  body_mode: BodyMode;
  body: string;
  body_form: KeyValue[];
  timeout_ms: number;
  follow_redirects: boolean;
};

export function useCreateHttpRequest(workspaceId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: RequestDraftInput) =>
      httpJson<HttpRequest>(`/http/workspaces/${workspaceId}/requests`, { method: "POST", body: JSON.stringify(body) }),
    onSuccess: () => {
      if (workspaceId) qc.invalidateQueries({ queryKey: keys.bundle(workspaceId) });
    },
  });
}

export function useUpdateHttpRequest(workspaceId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: RequestDraftInput & { id: string }) =>
      httpJson<HttpRequest>(`/http/requests/${id}`, { method: "PUT", body: JSON.stringify(body) }),
    onSuccess: () => {
      if (workspaceId) qc.invalidateQueries({ queryKey: keys.bundle(workspaceId) });
    },
  });
}

export function useDeleteHttpRequest(workspaceId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => httpJson<void>(`/http/requests/${id}`, { method: "DELETE" }),
    onSuccess: () => {
      if (workspaceId) qc.invalidateQueries({ queryKey: keys.bundle(workspaceId) });
    },
  });
}

export function useRunHttpRequest() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ requestId, environmentId, override }: {
      requestId: string;
      environmentId?: string | null;
      override?: RequestDraftInput;
    }) =>
      httpJson<HttpExecution>(`/http/requests/${requestId}/run`, {
        method: "POST",
        body: JSON.stringify({
          environment_id: environmentId ?? null,
          override,
        }),
      }),
    onSuccess: (_exec, vars) => {
      qc.invalidateQueries({ queryKey: keys.reqExecs(vars.requestId) });
    },
  });
}

export function useImportHttpCollection(workspaceId: string | null) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: {
      format: "bru" | "openapi" | "curl";
      content?: string;
      zip_base64?: string;
      files?: { path: string; content: string }[];
      folder_id?: string | null;
    }) => httpJson<ImportResult>(`/http/workspaces/${workspaceId}/import`, { method: "POST", body: JSON.stringify(body) }),
    onSuccess: () => {
      if (workspaceId) qc.invalidateQueries({ queryKey: keys.bundle(workspaceId) });
    },
  });
}
