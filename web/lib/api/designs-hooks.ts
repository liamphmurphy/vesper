"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, postForm, unwrap, type Schemas } from "./client";
import { libraryKeys } from "./library-hooks";
import type { paths } from "./schema";

// ---- The Designs app: the person's designs, each a design canvas in its own chat.

export type DesignSummary = Schemas["DesignSummary"];
export type DesignRef = Schemas["Design"];
export type DesignVersion = Schemas["DesignVersion"];
export type DesignStarter = NonNullable<CreateDesignBody["starter"]>;
type CreateDesignBody = NonNullable<paths["/designs"]["post"]["requestBody"]>["content"]["application/json"];

// Under ["canvases"], so a persona's turn on a design refreshes them (SSE chat.* invalidates it).
export const designKeys = {
  list: ["canvases", "designs"] as const,
  one: (id: string) => ["canvases", "designs", id] as const,
  // A version never changes, so it's cached for good.
  proposals: (id: string) => ["canvases", "designs", id, "proposals"] as const,
  version: (id: string, seq: number) => ["design-versions", id, seq] as const,
};

/** One design: its chat, current seq, switches and pending suggestions. */
export function useDesign(id: string) {
  return useQuery({ queryKey: designKeys.one(id), queryFn: () => unwrap(api.GET("/designs/{canvasId}", { params: { path: { canvasId: id } } })) });
}

/** A version's body; seq undefined waits. */
export function useDesignVersion(id: string | undefined, seq: number | undefined) {
  return useQuery({
    queryKey: designKeys.version(id ?? "", seq ?? 0),
    queryFn: () => unwrap(api.GET("/designs/{canvasId}/versions/{seq}", { params: { path: { canvasId: id!, seq: seq! } } })),
    enabled: !!id && !!seq,
    staleTime: Infinity,
  });
}

export async function fetchDesignVersion(id: string, seq: number): Promise<DesignVersion> {
  return unwrap(api.GET("/designs/{canvasId}/versions/{seq}", { params: { path: { canvasId: id, seq } } }));
}

export async function fetchDesign(id: string): Promise<DesignRef> {
  return unwrap(api.GET("/designs/{canvasId}", { params: { path: { canvasId: id } } }));
}

/** Saves a version on base_seq; 409 (ApiError) when the design moved on. */
export function useSaveDesign(id: string) {
  return useMutation({
    mutationFn: (body: { base_seq: number; body: string; note?: string }) => unwrap(api.POST("/designs/{canvasId}/versions", { params: { path: { canvasId: id } }, body })),
  });
}

export function useCreateDesign() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: CreateDesignBody) => unwrap(api.POST("/designs", { body })),
    onSettled: () => void qc.invalidateQueries({ queryKey: designKeys.list }),
  });
}

export function useRenameDesign() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { id: string; title: string }) => unwrap(api.PATCH("/designs/{canvasId}", { params: { path: { canvasId: v.id } }, body: { title: v.title } })),
    onSettled: () => void qc.invalidateQueries({ queryKey: ["canvases"] }),
  });
}

export function useDuplicateDesign() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (id: string) => unwrap(api.POST("/designs/{canvasId}/duplicate", { params: { path: { canvasId: id } } })),
    onSettled: () => void qc.invalidateQueries({ queryKey: designKeys.list }),
  });
}

/** Stores an image for a design; the caller adds it to the design's assets. */
export async function uploadDesignAsset(canvasId: string, file: Blob): Promise<Schemas["DeckAsset"]> {
  const form = new FormData();
  form.append("file", file);
  const r = await fetch(`/api/v1/designs/${canvasId}/assets`, { method: "POST", body: form, credentials: "same-origin" });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error((body as { message?: string }).message ?? `Upload failed (${r.status})`);
  return body as Schemas["DeckAsset"];
}

/** Keeps one finished export file (PNG, SVG or PDF) in the person's Library. */
export function useSaveDesignExport(canvasId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (file: File) => {
      const form = new FormData();
      form.append("file", file);
      return postForm<Schemas["LibraryItem"]>(`/designs/${canvasId}/library`, form);
    },
    onSettled: () => void qc.invalidateQueries({ queryKey: libraryKeys.all }),
  });
}

export type DesignProposal = Schemas["DesignProposal"];
export type DesignSettings = Schemas["DesignSettings"];

/** The persona suggestions waiting for a review, oldest first. */
export function useDesignProposals(id: string, enabled = true) {
  return useQuery({
    enabled,
    queryKey: designKeys.proposals(id),
    queryFn: () => unwrap(api.GET("/designs/{canvasId}/proposals", { params: { path: { canvasId: id }, query: { status: "pending" } } })),
    select: (d) => [...d.proposals].sort((a, b) => a.created_at.localeCompare(b.created_at)),
  });
}

/** Resolves a suggestion: one decision per op. Accepted ops become one version on the current head. */
export function useResolveProposal(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { proposalId: string; decisions: { i: number; state: "accepted" | "rejected"; reason?: string }[] }) =>
      unwrap(api.POST("/designs/{canvasId}/proposals/{proposalId}/resolve", { params: { path: { canvasId: id, proposalId: v.proposalId } }, body: { decisions: v.decisions } })),
    // Drop the resolved one at once, so its banner and Review tab don't linger until the refetch.
    onSuccess: (_, v) => qc.setQueryData<{ proposals: { id: string }[] }>(designKeys.proposals(id), (d) => (d ? { ...d, proposals: d.proposals.filter((p) => p.id !== v.proposalId) } : d)),
    onSettled: () => void qc.invalidateQueries({ queryKey: ["canvases"] }),
  });
}

/** "Let personas edit directly" and Pause. */
export function useDesignSettings(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { direct_edit?: boolean; persona_paused?: boolean }) => unwrap(api.PATCH("/designs/{canvasId}/settings", { params: { path: { canvasId: id } }, body })),
    onSettled: () => void qc.invalidateQueries({ queryKey: ["canvases"] }),
  });
}
