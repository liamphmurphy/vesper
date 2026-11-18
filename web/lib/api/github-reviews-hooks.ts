"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { useCallback, useSyncExternalStore } from "react";
import {
  DISMISSED_STORAGE_KEY,
  dismissReviewRequests,
  parseDismissedReviewRequests,
  parseReviewFilterPrefs,
  restoreReviewRequests,
  REVIEW_FILTERS_STORAGE_KEY,
  saveDismissedReviewRequests,
  saveReviewFilterPrefs,
  type DismissedReviewRequests,
  type DismissibleReviewRequest,
  type ReviewFilterPrefs,
} from "../github-reviews";
import { api, unwrap } from "./client";

export const githubReviewsKey = ["github-review-requests"] as const;

const DEFAULT_PREFS: ReviewFilterPrefs = { direct: true, team: true };
const EMPTY_DISMISSED: DismissedReviewRequests = {};

function createStorageStore<T>(
  key: string,
  eventName: string,
  fallback: T,
  parse: (raw: string | null) => T,
  save: (storage: Pick<Storage, "setItem">, value: T) => void,
) {
  let cachedRaw: string | null | undefined;
  let cachedValue = fallback;
  const subscribe = (onChange: () => void) => {
    const onStorage = (e: StorageEvent) => {
      if (e.key === null || e.key === key) onChange();
    };
    window.addEventListener("storage", onStorage);
    window.addEventListener(eventName, onChange);
    return () => {
      window.removeEventListener("storage", onStorage);
      window.removeEventListener(eventName, onChange);
    };
  };
  const getSnapshot = (): T => {
    try {
      const raw = window.localStorage.getItem(key);
      if (raw === cachedRaw) return cachedValue;
      cachedRaw = raw;
      cachedValue = parse(raw);
      return cachedValue;
    } catch {
      return cachedValue;
    }
  };
  const write = (next: T) => {
    cachedRaw = JSON.stringify(next);
    cachedValue = next;
    save(window.localStorage, next);
    window.dispatchEvent(new Event(eventName));
  };
  const getServerSnapshot = () => fallback;
  return { subscribe, getSnapshot, getServerSnapshot, write };
}

const prefsStore = createStorageStore(
  REVIEW_FILTERS_STORAGE_KEY,
  "vesper:pr-review-filters-changed",
  DEFAULT_PREFS,
  parseReviewFilterPrefs,
  saveReviewFilterPrefs,
);

const dismissedStore = createStorageStore(
  DISMISSED_STORAGE_KEY,
  "vesper:pr-review-dismissed-changed",
  EMPTY_DISMISSED,
  parseDismissedReviewRequests,
  saveDismissedReviewRequests,
);

export function useReviewFilterPrefs(): [ReviewFilterPrefs, (next: ReviewFilterPrefs) => void] {
  const prefs = useSyncExternalStore(prefsStore.subscribe, prefsStore.getSnapshot, prefsStore.getServerSnapshot);
  const update = useCallback((next: ReviewFilterPrefs) => {
    prefsStore.write(next);
  }, []);
  return [prefs, update];
}

export function useDismissedReviewRequests() {
  const dismissed = useSyncExternalStore(
    dismissedStore.subscribe,
    dismissedStore.getSnapshot,
    dismissedStore.getServerSnapshot,
  );
  const dismiss = useCallback((item: DismissibleReviewRequest) => {
    dismissedStore.write(dismissReviewRequests(dismissedStore.getSnapshot(), [item]));
  }, []);
  const clearAll = useCallback((items: readonly DismissibleReviewRequest[]) => {
    if (items.length === 0) return;
    dismissedStore.write(dismissReviewRequests(dismissedStore.getSnapshot(), items));
  }, []);
  const restore = useCallback((items: readonly Pick<DismissibleReviewRequest, "id">[]) => {
    const current = dismissedStore.getSnapshot();
    const next = restoreReviewRequests(current, items);
    if (next !== current) dismissedStore.write(next);
  }, []);
  return { dismissed, dismiss, clearAll, restore };
}

export function useGitHubReviewRequests(enabled = true) {
  return useQuery({
    enabled,
    queryKey: githubReviewsKey,
    queryFn: ({ signal }) => unwrap(api.GET("/github/review-requests", { signal })),
    staleTime: 60_000,
    refetchInterval: 2 * 60_000,
    retry: false,
  });
}

export function useRefreshGitHubReviewRequests() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => unwrap(api.GET("/github/review-requests", { params: { query: { refresh: true } } })),
    onSuccess: (data) => {
      qc.setQueryData(githubReviewsKey, data);
    },
  });
}
