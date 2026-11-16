"use client";

import { useState } from "react";
import { useDevWorkspace, useDevWorkspaceAction, useUpdateDevWorkspace } from "@/lib/api/dev-workspace-hooks";
import { devWorkspaceStatusLabel, devWorkspaceStatusTone } from "@/lib/dev-workspace";
import { Button, ButtonLink } from "@/components/ui/button";
import { Toggle } from "@/components/ui/controls";
import { Banner, Card, Skeleton } from "@/components/ui/primitives";
import { SmallPill } from "@/components/domain/labels";

export function DevWorkspaceSection() {
  const q = useDevWorkspace();
  const update = useUpdateDevWorkspace();
  const action = useDevWorkspaceAction();
  const [repoInput, setRepoInput] = useState("");

  if (q.isPending) {
    return (
      <div aria-label="Loading dev workspace settings" className="space-y-3">
        <Skeleton className="h-32" />
        <Skeleton className="h-14" />
      </div>
    );
  }
  if (q.isError) {
    return (
      <Banner
        tone="blocked"
        title="Couldn’t load dev workspace settings"
        actions={<Button variant="outline" onClick={() => void q.refetch()}>Retry</Button>}
      >
        {q.error.message}
      </Banner>
    );
  }

  const ws = q.data;
  const busy = ws.state === "starting" || !!ws.action || update.isPending || action.isPending;
  const err = update.error ?? action.error;

  const addRepo = () => {
    const trimmed = repoInput.trim();
    if (!trimmed) return;
    const next = [...ws.repos.map((r) => r.repo_url), trimmed];
    update.mutate({ repos: next }, { onSuccess: () => setRepoInput("") });
  };

  const removeRepo = (repoUrl: string) => {
    const next = ws.repos.filter((r) => r.repo_url !== repoUrl).map((r) => r.repo_url);
    update.mutate({ repos: next });
  };

  return (
    <div className="flex flex-col gap-4">
      <Card className="space-y-5">
        <div>
          <Toggle
            checked={ws.enabled}
            disabled={update.isPending}
            onChange={(enabled) => update.mutate({ enabled })}
            label="Enable persistent dev workspace"
          />
          <p className="mt-1 text-12 text-fg-tertiary">
            {ws.enabled
              ? "On — mounts the shared /nix store, persistent /workspace, and /home/node state volume."
              : "Off — no dev container is running or consuming disk or memory."}
          </p>
        </div>

        <div className="border-t border-border-subtle pt-4">
          <div className="mb-2 text-13 font-medium text-fg">Nix environment</div>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="rounded-lg border border-accent bg-accent-soft/40 p-3">
              <div className="text-13 font-semibold text-fg">Vesper default (Nix + LazyVim)</div>
              <p className="mt-1 text-12 text-fg-secondary">
                Pinned flake: neovim, tmux, lazygit, rg, fd, gopls, pyright, tsserver, nixd
              </p>
            </div>
            <div
              aria-disabled="true"
              className="rounded-lg border border-border bg-surface-muted p-3 opacity-65"
            >
              <div className="flex items-center justify-between gap-2">
                <span className="text-13 font-semibold text-fg-secondary">Custom Nix flake repo</span>
                <SmallPill tone="neutral">Coming later</SmallPill>
              </div>
              <p className="mt-1 text-12 text-fg-tertiary">
                Point at your own flake repo (e.g. os-setup) in a follow-up.
              </p>
            </div>
          </div>
        </div>

        <div className="border-t border-border-subtle pt-4">
          <div className="mb-2 flex items-center justify-between gap-2">
            <div>
              <div className="text-13 font-medium text-fg">
                Auto-cloned repositories {ws.repos.length > 0 ? `(${ws.repos.length})` : ""}
              </div>
              <p className="text-12 text-fg-tertiary">
                Cloned into <code className="font-mono">/workspace/&lt;repo&gt;</code> so LazyVim’s explorer sees every repo at once.
              </p>
            </div>
          </div>

          {ws.repos.length > 0 && (
            <ul className="mb-3 divide-y divide-border rounded-lg border border-border bg-surface">
              {ws.repos.map((r) => (
                <li key={r.repo_url} className="flex flex-wrap items-center gap-3 px-3 py-2 text-13">
                  <span className="font-medium text-fg">{r.repo_url}</span>
                  <span className="font-mono text-12 text-fg-tertiary">/workspace/{r.directory}</span>
                  <button
                    type="button"
                    disabled={busy}
                    onClick={() => removeRepo(r.repo_url)}
                    className="ml-auto text-12 text-pill-blocked-fg hover:underline disabled:opacity-50"
                  >
                    Remove
                  </button>
                </li>
              ))}
            </ul>
          )}

          <form
            className="flex flex-wrap gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              addRepo();
            }}
          >
            <input
              aria-label="Repository to auto-clone"
              value={repoInput}
              onChange={(e) => setRepoInput(e.target.value)}
              placeholder="owner/repo or https://github.com/owner/repo"
              className="min-w-60 flex-1 rounded-md border border-border bg-surface px-3 py-1.5 text-13 text-fg"
            />
            <Button type="submit" variant="outline" disabled={!repoInput.trim() || busy}>
              + Add repository
            </Button>
          </form>
        </div>
      </Card>

      {ws.error && (
        <Banner tone="blocked" title="Dev workspace error">
          <pre className="whitespace-pre-wrap font-mono text-12">{ws.error}</pre>
        </Banner>
      )}
      {err && (
        <Banner tone="blocked" title="Couldn’t update dev workspace">
          {err.message}
        </Banner>
      )}

      <Card className="flex flex-wrap items-center justify-between gap-3">
        <div className="flex flex-wrap items-center gap-2.5 text-13">
          <SmallPill tone={devWorkspaceStatusTone(ws.state)}>{devWorkspaceStatusLabel(ws)}</SmallPill>
          <span className="text-fg-secondary">
            {ws.arch ? `${ws.arch} · ` : ""}
            {ws.enabled ? "/nix shared" : "Disabled"}
            {ws.repos.length > 0 ? ` · ${ws.repos.length} ${ws.repos.length === 1 ? "repo" : "repos"}` : ""}
          </span>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          {ws.enabled && (
            <>
              <Button variant="outline" disabled={busy} onClick={() => action.mutate("sync")}>
                Sync repos
              </Button>
              <Button variant="outline" disabled={busy} onClick={() => action.mutate("rebuild")}>
                Rebuild env
              </Button>
            </>
          )}
          <ButtonLink
            href="/dev"
            variant="primary"
            aria-disabled={!ws.enabled || ws.state !== "ready"}
            className={!ws.enabled || ws.state !== "ready" ? "pointer-events-none opacity-50" : undefined}
          >
            Open Terminal
          </ButtonLink>
        </div>
      </Card>
    </div>
  );
}
