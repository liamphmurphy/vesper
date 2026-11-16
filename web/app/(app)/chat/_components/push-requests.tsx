"use client";

import { useState } from "react";
import { ApiError } from "@/lib/api/client";
import { useDecidePush, usePushPolicies, useSetPushPolicy, type PushRequest } from "@/lib/api/code-review-hooks";
import { pushStateLabel, repoName } from "@/lib/code-review";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { OpenInDevWorkspaceButton } from "@/components/domain/open-in-dev-button";
import { CodeChanges } from "./code-changes";
import { PersonaAvatar, PersonaName, personaLook } from "./persona";

const message = (e: unknown) => (e instanceof ApiError || e instanceof Error ? e.message : null);

/**
 * Branches a persona asked to push from this chat. Its turn holds no credential that can push:
 * the runner stages the exact commit when the turn ends, and nothing reaches the branch or opens
 * a pull request until the person pushes it here (or always allows the repository). The staged
 * commit is on GitHub already, so a card can be approved after the chat's workspace is gone.
 */
export function PushRequests({ chatId, requests, disabled }: { chatId: string; requests: PushRequest[]; disabled?: boolean }) {
  if (!requests.length) return null;
  return (
    <div className="flex w-full flex-col gap-2" data-testid="push-requests">
      {requests.map((r) => (
        <PushCard key={r.id} chatId={chatId} r={r} disabled={!!disabled} />
      ))}
    </div>
  );
}

function PushCard({ chatId, r, disabled }: { chatId: string; r: PushRequest; disabled: boolean }) {
  const decide = useDecidePush(chatId);
  const error = message(decide.error);
  const busy = decide.isPending || disabled;
  const onDecide = (d: { decision: "push" | "always" | "deny"; title?: string; body?: string; draft?: boolean }) =>
    decide.mutate({ id: r.id, ...d });
  const by = personaLook(r.persona);
  const name = r.persona?.name ?? "The assistant";
  const [title, setTitle] = useState(r.title);
  const [body, setBody] = useState(r.body);
  const [draft, setDraft] = useState(r.draft);
  const [devError, setDevError] = useState<string | null>(null);
  const waiting = r.state === "pending";
  const edits = { title: title.trim() || r.title, body, draft };
  return (
    <div data-testid="push-request" data-state={r.state} className={`flex max-w-[min(720px,100%)] flex-col gap-2 rounded-xl border bg-surface px-3.5 py-3 ${waiting ? "border-state-human" : "border-border"}`}>
      <p className="flex flex-wrap items-center gap-1.5 text-12 text-fg-tertiary">
        <PersonaAvatar persona={by} size={16} />
        <PersonaName persona={by} />
        <span>{waiting ? "wants to push and open a pull request" : "asked to push"}</span>
        <span className="ml-auto" data-testid="push-state">
          {pushStateLabel(r, name)}
        </span>
      </p>
      <p className="flex flex-wrap items-center gap-1.5 font-mono text-13 text-fg">
        <Icon name="github" size={14} className="text-fg-tertiary" />
        <span>{repoName(r.repository)}</span>
        <Icon name="branch" size={13} className="text-fg-tertiary" />
        <span>{r.branch}</span>
        {r.base_branch && <span className="text-fg-tertiary">→ {r.base_branch}</span>}
      </p>
      {r.commits.length > 0 && (
        <ul className="flex flex-col gap-0.5 rounded-md border border-border-subtle bg-surface-sunken px-3 py-2 text-13" aria-label="Commits">
          {r.commits.map((c) => (
            <li key={c.sha} className="flex gap-2">
              <span className="flex-none font-mono text-12 text-fg-tertiary">{c.sha.slice(0, 7)}</span>
              <span className="min-w-0 truncate text-fg">{c.subject}</span>
            </li>
          ))}
        </ul>
      )}
      <CodeChanges changes={r.files} />
      {waiting ? (
        <div className="flex flex-col gap-1.5">
          <label className="flex flex-col gap-1 text-12 text-fg-tertiary">
            Pull request title
            <input value={title} onChange={(e) => setTitle(e.target.value)} maxLength={200} className="rounded-md border border-border bg-surface-sunken px-2 py-1 text-14 text-fg" />
          </label>
          <details className="text-12 text-fg-tertiary">
            <summary className="cursor-pointer">Description</summary>
            <textarea value={body} onChange={(e) => setBody(e.target.value)} rows={8} aria-label="Pull request description" className="mt-1 w-full resize-y rounded-md border border-border bg-surface-sunken px-2 py-1 font-mono text-12 text-fg" />
          </details>
          <label className="flex items-center gap-1.5 text-13 text-fg-secondary">
            <input type="checkbox" checked={draft} onChange={(e) => setDraft(e.target.checked)} />
            Open as a draft
          </label>
        </div>
      ) : (
        <p className="text-14 font-medium text-fg">{r.title}</p>
      )}
      {r.error && <p className="text-13 text-pill-blocked-fg">{r.error}</p>}
      {error && (
        <p role="alert" className="text-13 text-pill-blocked-fg">
          Not pushed: {error}
        </p>
      )}
      {r.pr_url && (
        <div className="flex flex-wrap items-center justify-between gap-2">
          <a href={r.pr_url} target="_blank" rel="noreferrer" className="flex items-center gap-1.5 text-13 text-accent hover:underline">
            <Icon name="pr" size={14} />
            {r.pr_number ? `Pull request #${r.pr_number}` : "Pull request"} on GitHub
            {r.pr_state && r.pr_state !== "open" && (
              <span className="text-12 text-fg-tertiary">· {r.pr_state}</span>
            )}
          </a>
          <OpenInDevWorkspaceButton
            repository={r.repository}
            branch={r.branch}
            prNumber={r.pr_number}
            prUrl={r.pr_url}
            prState={r.pr_state}
            onError={setDevError}
          />
        </div>
      )}
      {devError && (
        <p role="alert" className="text-13 text-pill-blocked-fg">
          {devError}
        </p>
      )}
      {r.auto && <AlwaysAllowed repository={r.repository} />}
      {waiting && (
        <div className="flex flex-wrap justify-end gap-2">
          <Button variant="outline" disabled={busy} onClick={() => onDecide({ decision: "deny" })}>
            Decline
          </Button>
          <Button variant="outline" disabled={busy} onClick={() => onDecide({ decision: "always", ...edits })} title={`Push this, and push ${name}'s later requests for ${repoName(r.repository)} without asking. ${name} still never holds a credential that can push.`}>
            Always allow for this repo
          </Button>
          <Button variant="primary" disabled={busy} onClick={() => onDecide({ decision: "push", ...edits })}>
            Push & open PR
          </Button>
        </div>
      )}
    </div>
  );
}

/** On a card pushed without asking: the repository's "always allow", and the way to undo it. */
function AlwaysAllowed({ repository }: { repository: string }) {
  const allowed = usePushPolicies().data?.policies.some((p) => p.repository === repository && p.auto_push);
  const set = useSetPushPolicy();
  if (!allowed) return null;
  return (
    <p className="flex flex-wrap items-center gap-2 text-12 text-fg-tertiary">
      Pushes to {repoName(repository)} don&apos;t ask.
      <button type="button" disabled={set.isPending} onClick={() => set.mutate({ repository, auto_push: false })} className="text-accent hover:underline">
        Ask again
      </button>
    </p>
  );
}
