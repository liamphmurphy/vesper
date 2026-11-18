"use client";

// The Safari tab shared with a chat (docs/dev/safari-extension.md). SSE
// browser_share.updated invalidates these: a share starting, a new snapshot,
// a persona reading it, or sharing stopping.

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ApiError } from "./client";
import type { BrowserShare } from "../browser-share";

const shareKey = (chatId: string) => ["browser-shares", chatId] as const;

async function shareJson(path: string, init?: RequestInit): Promise<{ share: BrowserShare | null }> {
  const res = await fetch(`/api/v1${path}`, { ...init, headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) } });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const err = body as { code?: string; message?: string; field?: string };
    throw new ApiError(res.status, err.code ?? "internal", err.message ?? res.statusText, err.field);
  }
  return body as { share: BrowserShare | null };
}

/** The chat's shared tab: the active share, else the last one to end (null when there never was one). */
export function useBrowserShare(chatId: string | undefined) {
  return useQuery({
    queryKey: shareKey(chatId ?? ""),
    enabled: !!chatId,
    queryFn: () => shareJson(`/chats/${chatId}/browser-share`).then((r) => r.share),
  });
}

export function useStopBrowserShare(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => shareJson(`/chats/${chatId}/browser-share/stop`, { method: "POST" }).then((r) => r.share),
    onSettled: () => qc.invalidateQueries({ queryKey: shareKey(chatId) }),
  });
}
