"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, ApiError, unwrap, type Schemas } from "./client";

export type CustomAppSummary = Schemas["CustomAppSummary"];
export type CustomAppDetail = Schemas["CustomAppDetail"];
export type CustomAppVersion = Schemas["CustomAppVersion"];
export type CustomAppVersionSummary = Schemas["CustomAppVersionSummary"];
export type CustomAppManifest = Schemas["CustomAppManifest"];
export type CustomAppCapabilities = Schemas["CustomAppCapabilities"];
export type CustomAppCapabilityMode = Schemas["CustomAppCapabilityMode"];
export type CustomAppNavItem = Schemas["CustomAppNavItem"];
export type NewCustomApp = Schemas["NewCustomApp"];
export type UpdateCustomApp = Schemas["UpdateCustomApp"];
export type CustomAppInvokeRequest = Schemas["CustomAppInvokeRequest"];
export type CustomAppInvokeResponse = Schemas["CustomAppInvokeResponse"];

export const customAppKeys = {
  all: ["custom-apps"] as const,
  list: ["custom-apps", "list"] as const,
  detail: (slug: string) => ["custom-apps", "detail", slug] as const,
  version: (slug: string, seq: number) => ["custom-apps", "version", slug, seq] as const,
};

export function useCustomApps(enabled = true) {
  return useQuery({
    enabled,
    queryKey: customAppKeys.list,
    queryFn: () => unwrap(api.GET("/custom-apps")),
  });
}

export function useCustomApp(slug?: string) {
  return useQuery({
    enabled: !!slug,
    queryKey: customAppKeys.detail(slug ?? ""),
    queryFn: () => unwrap(api.GET("/custom-apps/{slug}", { params: { path: { slug: slug! } } })),
    retry: (n, e) => !(e instanceof ApiError && e.status === 404) && n < 2,
  });
}

export function useCustomAppVersion(slug: string, seq?: number) {
  return useQuery({
    enabled: !!slug && !!seq && seq > 0,
    queryKey: customAppKeys.version(slug, seq ?? 0),
    queryFn: () => unwrap(api.GET("/custom-apps/{slug}/versions/{seq}", { params: { path: { slug, seq: seq! } } })),
    staleTime: Infinity,
  });
}

export function useCreateCustomApp() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: NewCustomApp) => unwrap(api.POST("/custom-apps", { body })),
    onSuccess: (created) => {
      qc.setQueryData(customAppKeys.detail(created.slug), created);
      void qc.invalidateQueries({ queryKey: customAppKeys.all });
    },
  });
}

export function useUpdateCustomApp(slug: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: UpdateCustomApp) => unwrap(api.PATCH("/custom-apps/{slug}", { params: { path: { slug } }, body })),
    onSuccess: (updated) => {
      qc.setQueryData(customAppKeys.detail(slug), updated);
      void qc.invalidateQueries({ queryKey: customAppKeys.list });
    },
  });
}

export function useDeleteCustomApp() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (slug: string) => {
      const { error, response } = await api.DELETE("/custom-apps/{slug}", { params: { path: { slug } } });
      if (error || !response.ok) {
        const e = (error ?? {}) as Partial<Schemas["Error"]>;
        throw new ApiError(response.status, e.code ?? "internal", e.message ?? response.statusText, e.field);
      }
    },
    onSuccess: (_, slug) => {
      qc.removeQueries({ queryKey: customAppKeys.detail(slug) });
      void qc.invalidateQueries({ queryKey: customAppKeys.all });
    },
  });
}

export async function invokeCustomApp(slug: string, body: CustomAppInvokeRequest): Promise<CustomAppInvokeResponse> {
  return unwrap(api.POST("/custom-apps/{slug}/invoke", { params: { path: { slug } }, body }));
}
