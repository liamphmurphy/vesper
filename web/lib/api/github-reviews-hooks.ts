"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { api, unwrap } from "./client";

export const githubReviewsKey = ["github-review-requests"] as const;

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
