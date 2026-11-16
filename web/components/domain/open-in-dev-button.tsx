"use client";

import { useRouter } from "next/navigation";
import { ApiError, type Schemas } from "@/lib/api/client";
import { useDevWorkspace, useOpenDevWorkspaceBranch } from "@/lib/api/dev-workspace-hooks";
import { Button } from "@/components/ui/button";

export type PullRequestState = Schemas["PullRequestState"];

export function isOpenPullRequestState(state: string | null | undefined): boolean {
  return state === "open" || state === "draft";
}

export function parsePullRequestNumber(prUrl: string | null | undefined): number | undefined {
  const m = /\/pull\/(\d+)(?:[/?#]|$)/.exec(prUrl ?? "");
  return m ? Number(m[1]) : undefined;
}

type Props = {
  repository?: string | null;
  branch?: string | null;
  prNumber?: number | null;
  prUrl?: string | null;
  prState?: string | null;
  variant?: "outline" | "primary" | "secondary" | "ghost";
  onError?: (message: string | null) => void;
};

/**
 * Shown on open pull request cards when the persistent Dev workspace is enabled:
 * pulls the PR branch into /workspace/<repo>, focuses tmux there, and opens /dev.
 */
export function OpenInDevWorkspaceButton({
  repository,
  branch,
  prNumber,
  prUrl,
  prState,
  variant = "outline",
  onError,
}: Props) {
  const router = useRouter();
  const devWorkspace = useDevWorkspace();
  const openBranch = useOpenDevWorkspaceBranch();

  if (!devWorkspace.data?.enabled || !repository || !branch || !isOpenPullRequestState(prState)) {
    return null;
  }

  const resolvedPRNumber = prNumber ?? parsePullRequestNumber(prUrl);

  const handleOpen = async () => {
    onError?.(null);
    try {
      await openBranch.mutateAsync({
        repository,
        branch,
        ...(resolvedPRNumber ? { pr_number: resolvedPRNumber } : {}),
      });
      router.push("/dev");
    } catch (err) {
      const msg = err instanceof ApiError || err instanceof Error ? err.message : "Could not open branch in Dev workspace";
      onError?.(msg);
    }
  };

  return (
    <Button
      variant={variant}
      icon="terminal"
      disabled={openBranch.isPending}
      onClick={() => void handleOpen()}
      title={`Pull ${branch} and open in Dev workspace`}
    >
      {openBranch.isPending ? "Opening…" : "Open in Dev workspace"}
    </Button>
  );
}
