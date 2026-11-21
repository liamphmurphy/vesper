"use client";

import type { Schemas } from "@/lib/api/client";
import { Button } from "@/components/ui/button";
import { SmallPill } from "./labels";

type Feedback = Schemas["PRFeedback"];
type FeedbackMode = Schemas["AddressPRFeedbackRequest"]["mode"];

/**
 * Surfaces synced GitHub CI check status and unresolved review threads on an open/draft PR,
 * with one-click actions to dispatch or resume the originating agent on its branch.
 */
export function PRFeedbackStrip({
  feedback,
  prState,
  busy,
  activeMode,
  disabled,
  error,
  onAddress,
}: {
  feedback?: Feedback;
  prState?: Schemas["PullRequestState"];
  busy?: boolean;
  activeMode?: FeedbackMode;
  disabled?: boolean;
  error?: string | null;
  onAddress?: (mode: FeedbackMode) => void;
}) {
  if (!feedback || (prState && prState !== "open" && prState !== "draft")) return null;
  const hasFailures = feedback.failed_checks_count > 0;
  const hasThreads = feedback.unresolved_threads > 0;
  if (!hasFailures && !hasThreads && feedback.ci_state === "unknown") return null;

  const ciPill =
    feedback.ci_state === "failing"
      ? { tone: "blocked" as const, label: `CI failing (${feedback.failed_checks_count})` }
      : feedback.ci_state === "passing"
        ? { tone: "done" as const, label: "CI passing" }
        : feedback.ci_state === "pending"
          ? { tone: "neutral" as const, label: "CI running" }
          : null;

  return (
    <div className="flex flex-col gap-2 rounded-lg border border-border-subtle bg-surface-sunken px-3 py-2 text-12" data-testid="pr-feedback-strip">
      <div className="flex flex-wrap items-center gap-1.5">
        {ciPill && <SmallPill tone={ciPill.tone}>{ciPill.label}</SmallPill>}
        {hasThreads && (
          <SmallPill tone="human">
            {feedback.unresolved_threads} unresolved {feedback.unresolved_threads === 1 ? "comment" : "comments"}
          </SmallPill>
        )}
      </div>

      {(feedback.failed_checks.length > 0 || feedback.review_threads.length > 0) && (
        <details className="text-12 text-fg-secondary">
          <summary className="cursor-pointer select-none text-fg-tertiary hover:text-fg-secondary">
            View details
          </summary>
          <div className="mt-2 flex flex-col gap-2">
            {feedback.failed_checks.length > 0 && (
              <ul className="flex flex-col gap-1">
                {feedback.failed_checks.map((c, idx) => (
                  <li key={`${c.name}-${idx}`} className="flex flex-col gap-0.5 rounded-md border border-border-subtle bg-surface px-2.5 py-1.5">
                    <div className="flex flex-wrap items-center justify-between gap-2">
                      <span className="font-mono font-medium text-pill-blocked-fg">{c.name}</span>
                      {c.details_url && (
                        <a href={c.details_url} target="_blank" rel="noreferrer noopener" className="text-11 text-accent hover:underline">
                          Logs ↗
                        </a>
                      )}
                    </div>
                    {(c.title || c.summary) && (
                      <p className="line-clamp-2 whitespace-pre-wrap text-11 text-fg-tertiary">
                        {c.title || c.summary}
                      </p>
                    )}
                  </li>
                ))}
              </ul>
            )}
            {feedback.review_threads.length > 0 && (
              <ul className="flex flex-col gap-1">
                {feedback.review_threads.map((th) => {
                  const latest = th.comments[th.comments.length - 1];
                  const loc = th.line ? `${th.path}:${th.line}` : th.path;
                  return (
                    <li key={th.id} className="flex flex-col gap-0.5 rounded-md border border-border-subtle bg-surface px-2.5 py-1.5">
                      <div className="flex flex-wrap items-center justify-between gap-2">
                        <span className="font-mono text-11 text-fg">{loc || "Pull request comment"}</span>
                        {th.url && (
                          <a href={th.url} target="_blank" rel="noreferrer noopener" className="text-11 text-accent hover:underline">
                            Thread ↗
                          </a>
                        )}
                      </div>
                      {latest && (
                        <p className="line-clamp-2 text-11 text-fg-secondary">
                          <span className="font-medium text-fg">@{latest.author}:</span> {latest.body}
                        </p>
                      )}
                    </li>
                  );
                })}
              </ul>
            )}
          </div>
        </details>
      )}

      {onAddress && (hasFailures || hasThreads) && (
        <div className="flex flex-wrap items-center gap-2 pt-0.5">
          {hasFailures && (
            <Button
              variant="outline"
              disabled={busy || disabled}
              onClick={() => onAddress("ci")}
              data-testid="fix-ci-button"
            >
              {busy && activeMode === "ci" ? "Sending…" : "Fix CI"}
            </Button>
          )}
          {hasThreads && (
            <Button
              variant="outline"
              disabled={busy || disabled}
              onClick={() => onAddress("review")}
              data-testid="address-reviews-button"
            >
              {busy && activeMode === "review" ? "Sending…" : "Address review comments"}
            </Button>
          )}
          {hasFailures && hasThreads && (
            <Button
              variant="outline"
              disabled={busy || disabled}
              onClick={() => onAddress("all")}
              data-testid="fix-all-feedback-button"
            >
              {busy && activeMode === "all" ? "Sending…" : "Fix both"}
            </Button>
          )}
        </div>
      )}

      {error && (
        <p role="alert" className="text-12 text-pill-blocked-fg">
          {error}
        </p>
      )}
    </div>
  );
}
