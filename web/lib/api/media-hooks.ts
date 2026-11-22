"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap, type Schemas } from "./client";

export type MediaCapability = Schemas["MediaCapability"];
export type MediaFieldSpec = Schemas["MediaFieldSpec"];
export type MediaProvider = Schemas["MediaProvider"];
export type MediaProviderCheckResponse = Schemas["MediaProviderCheckResponse"];
export type UpdateMediaProviderRequest = Schemas["UpdateMediaProviderRequest"];

const QUERY_KEY = ["media-providers"] as const;

/** Registered media providers (cloud & local) and per-capability workspace defaults. */
export function useMediaProviders() {
  return useQuery({
    queryKey: QUERY_KEY,
    queryFn: () => unwrap(api.GET("/media/providers")),
  });
}

export function useUpdateMediaProvider() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, body }: { id: string; body: UpdateMediaProviderRequest }) =>
      unwrap(api.PUT("/media/providers/{id}", { params: { path: { id } }, body })),
    onSuccess: () => qc.invalidateQueries({ queryKey: QUERY_KEY }),
  });
}

export function useClearMediaProviderSecret() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, field }: { id: string; field?: string }) =>
      unwrap(api.DELETE("/media/providers/{id}/secret", { params: { path: { id }, query: field ? { field } : undefined } })),
    onSuccess: () => qc.invalidateQueries({ queryKey: QUERY_KEY }),
  });
}

export function useCheckMediaProvider() {
  return useMutation({
    mutationFn: (id: string) =>
      unwrap(api.POST("/media/providers/{id}/check", { params: { path: { id } } })),
  });
}

export function useSetMediaDefault() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ capability, providerId }: { capability: MediaCapability; providerId: string }) =>
      unwrap(api.PUT("/media/defaults/{capability}", { params: { path: { capability } }, body: { provider_id: providerId } })),
    onSuccess: (snap) => qc.setQueryData(QUERY_KEY, snap),
  });
}
