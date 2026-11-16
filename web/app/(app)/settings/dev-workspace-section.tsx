"use client";

import { useState } from "react";
import { useDevWorkspace, useDevWorkspaceAction, useUpdateDevWorkspace } from "@/lib/api/dev-workspace-hooks";
import { useOwnerRepositories, useRepositoryPresets } from "@/lib/api/repository-hooks";
import { devWorkspaceStatusLabel, devWorkspaceStatusTone, filterDevWorkspaceRepos } from "@/lib/dev-workspace";
import { Button, ButtonLink } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Toggle } from "@/components/ui/controls";
import { Banner, Card, Skeleton } from "@/components/ui/primitives";
import { SmallPill } from "@/components/domain/labels";

export function DevWorkspaceSection() {
  const q = useDevWorkspace();
  const update = useUpdateDevWorkspace();
  const action = useDevWorkspaceAction();
  const presets = useRepositoryPresets();
  const [repoInput, setRepoInput] = useState("");
  const [pkgInput, setPkgInput] = useState("");
  const [ownerInput, setOwnerInput] = useState("");
  const [seekOwner, setSeekOwner] = useState("");
  const [selectedOrgUrls, setSelectedOrgUrls] = useState<string[] | null>(null);
  const [zshrcDraft, setZshrcDraft] = useState<string | null>(null);
  const [tmuxConfDraft, setTmuxConfDraft] = useState<string | null>(null);
  const [reposExpanded, setReposExpanded] = useState(false);
  const [repoFilter, setRepoFilter] = useState("");
  const [confirmClearAll, setConfirmClearAll] = useState(false);
  const ownerRepos = useOwnerRepositories(seekOwner);

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
  const existingUrls = new Set(ws.repos.map((r) => r.repo_url));
  const fetchedEntries = ownerRepos.data ?? [];
  const availableEntries = fetchedEntries.filter((e) => !existingUrls.has(e.url));
  const checkedUrls = selectedOrgUrls ?? availableEntries.map((e) => e.url);
  const checkedSet = new Set(checkedUrls);

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

  const addPackages = () => {
    const parts = pkgInput
      .split(/[\s,]+/)
      .map((s) => s.trim())
      .filter(Boolean);
    if (parts.length === 0) return;
    const next = Array.from(new Set([...ws.extra_packages, ...parts]));
    update.mutate({ extra_packages: next }, { onSuccess: () => setPkgInput("") });
  };

  const removePackage = (pkg: string) => {
    update.mutate({ extra_packages: ws.extra_packages.filter((p) => p !== pkg) });
  };

  const startSeekOwner = (owner: string) => {
    const trimmed = owner.trim();
    if (!trimmed) return;
    setOwnerInput(trimmed);
    setSeekOwner(trimmed);
    setSelectedOrgUrls(null);
  };

  const toggleOrgUrl = (url: string) => {
    const base = new Set(checkedUrls);
    if (base.has(url)) base.delete(url);
    else base.add(url);
    setSelectedOrgUrls([...base]);
  };

  const addSelectedOrgRepos = () => {
    const toAdd = availableEntries.filter((e) => checkedSet.has(e.url)).map((e) => e.url);
    if (toAdd.length === 0) return;
    update.mutate(
      { repos: [...ws.repos.map((r) => r.repo_url), ...toAdd] },
      {
        onSuccess: () => {
          setSeekOwner("");
          setOwnerInput("");
          setSelectedOrgUrls(null);
        },
      },
    );
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
              <div className="text-13 font-semibold text-fg">Vesper default (nixos-unstable + LazyVim)</div>
              <p className="mt-1 text-12 text-fg-secondary">
                Latest nixos-unstable: go, nodejs, neovim, tmux, zsh, oh-my-zsh, lazygit, rg, fd, gopls, pyright, tsserver, nixd
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

        <div className="space-y-2.5 border-t border-border-subtle pt-4">
          <div>
            <div className="text-13 font-medium text-fg">
              Extra Nix packages {ws.extra_packages.length > 0 ? `(${ws.extra_packages.length})` : ""}
            </div>
            <p className="text-12 text-fg-tertiary">
              Add any <code className="font-mono">nixpkgs</code> package names (e.g. <code className="font-mono">eza bat btop rustc cargo uv</code>).
              Adding or removing packages rebuilds the profile automatically.
            </p>
          </div>

          {ws.extra_packages.length > 0 && (
            <div className="flex flex-wrap gap-1.5">
              {ws.extra_packages.map((pkg) => (
                <span
                  key={pkg}
                  className="inline-flex items-center gap-1.5 rounded-md border border-border bg-surface px-2 py-0.5 font-mono text-12 text-fg"
                >
                  {pkg}
                  <button
                    type="button"
                    aria-label={`Remove ${pkg}`}
                    disabled={busy}
                    onClick={() => removePackage(pkg)}
                    className="text-fg-tertiary hover:text-pill-blocked-fg disabled:opacity-50"
                  >
                    ×
                  </button>
                </span>
              ))}
            </div>
          )}

          <form
            className="flex flex-wrap gap-2"
            onSubmit={(e) => {
              e.preventDefault();
              addPackages();
            }}
          >
            <input
              aria-label="Extra Nix packages"
              value={pkgInput}
              onChange={(e) => setPkgInput(e.target.value)}
              placeholder="e.g. eza bat btop rustc cargo"
              className="min-w-60 flex-1 rounded-md border border-border bg-surface px-3 py-1.5 font-mono text-13 text-fg"
            />
            <Button type="submit" variant="outline" disabled={!pkgInput.trim() || busy}>
              + Add packages
            </Button>
          </form>
        </div>

        <div className="space-y-3 border-t border-border-subtle pt-4">
          <div className="flex flex-wrap items-center justify-between gap-3">
            <div>
              <div className="text-13 font-medium text-fg">Shell &amp; custom .zshrc</div>
              <p className="text-12 text-fg-tertiary">
                Includes <code className="font-mono">oh-my-zsh</code>, <code className="font-mono">zsh-autosuggestions</code>, and{" "}
                <code className="font-mono">zsh-syntax-highlighting</code>. <code className="font-mono">~/.zshenv</code> keeps Nix tools and{" "}
                <code className="font-mono">$ZSH</code> on <code className="font-mono">PATH</code>.
              </p>
            </div>
            <label className="flex items-center gap-2 text-12 text-fg-secondary">
              <span>tmux prefix</span>
              <select
                aria-label="tmux prefix"
                disabled={busy}
                value={ws.tmux_prefix}
                onChange={(e) => update.mutate({ tmux_prefix: e.target.value as typeof ws.tmux_prefix })}
                className="rounded-md border border-border bg-surface px-2.5 py-1 text-12 text-fg"
              >
                <option value="C-b">Ctrl+b (default)</option>
                <option value="C-a">Ctrl+a</option>
                <option value="C-Space">Ctrl+Space</option>
                <option value="C-s">Ctrl+s</option>
              </select>
            </label>
          </div>
          <textarea
            aria-label="Custom .zshrc"
            rows={5}
            value={zshrcDraft ?? (ws.custom_zshrc ?? "")}
            onChange={(e) => setZshrcDraft(e.target.value)}
            placeholder={`# Leave blank for Vesper's default oh-my-zsh config (robbyrussell + git + ll/neovim aliases).\nZSH_THEME="robbyrussell"\nplugins=(git)\nsource "$ZSH/oh-my-zsh.sh"`}
            className="w-full rounded-md border border-border bg-surface p-2.5 font-mono text-12 text-fg"
          />
          <div className="flex flex-wrap items-center justify-end gap-2">
            {(ws.custom_zshrc || (zshrcDraft !== null && zshrcDraft !== "")) && (
              <Button
                variant="outline"
                disabled={busy}
                onClick={() => update.mutate({ custom_zshrc: null }, { onSuccess: () => setZshrcDraft(null) })}
              >
                Reset to default
              </Button>
            )}
            <Button
              variant="outline"
              disabled={busy || zshrcDraft === null || zshrcDraft === (ws.custom_zshrc ?? "")}
              onClick={() => {
                const value = zshrcDraft ?? "";
                update.mutate(
                  { custom_zshrc: value.trim() === "" ? null : value },
                  { onSuccess: () => setZshrcDraft(null) },
                );
              }}
            >
              Save .zshrc
            </Button>
          </div>

          <div className="space-y-2 pt-2">
            <div>
              <div className="text-12 font-medium text-fg">Custom .tmux.conf</div>
              <p className="text-12 text-fg-tertiary">
                Leave blank for Vesper’s default <code className="font-mono">.tmux.conf</code> using the prefix above. Reloads live sessions on save.
              </p>
            </div>
            <textarea
              aria-label="Custom .tmux.conf"
              rows={4}
              value={tmuxConfDraft ?? (ws.custom_tmux_conf ?? "")}
              onChange={(e) => setTmuxConfDraft(e.target.value)}
              placeholder={`# Leave blank for Vesper's default .tmux.conf.\nset -g mouse on\nunbind C-b\nset -g prefix C-a\nbind C-a send-prefix`}
              className="w-full rounded-md border border-border bg-surface p-2.5 font-mono text-12 text-fg"
            />
            <div className="flex flex-wrap items-center justify-end gap-2">
              {(ws.custom_tmux_conf || (tmuxConfDraft !== null && tmuxConfDraft !== "")) && (
                <Button
                  variant="outline"
                  disabled={busy}
                  onClick={() => update.mutate({ custom_tmux_conf: null }, { onSuccess: () => setTmuxConfDraft(null) })}
                >
                  Reset to default
                </Button>
              )}
              <Button
                variant="outline"
                disabled={busy || tmuxConfDraft === null || tmuxConfDraft === (ws.custom_tmux_conf ?? "")}
                onClick={() => {
                  const value = tmuxConfDraft ?? "";
                  update.mutate(
                    { custom_tmux_conf: value.trim() === "" ? null : value },
                    { onSuccess: () => setTmuxConfDraft(null) },
                  );
                }}
              >
                Save .tmux.conf
              </Button>
            </div>
          </div>
        </div>

        <div className="space-y-3 border-t border-border-subtle pt-4">
          <div>
            <div className="text-13 font-medium text-fg">
              Auto-cloned repositories {ws.repos.length > 0 ? `(${ws.repos.length})` : ""}
            </div>
            <p className="text-12 text-fg-tertiary">
              Cloned into <code className="font-mono">/workspace/&lt;repo&gt;</code> so LazyVim’s explorer sees every repo at once.
            </p>
          </div>

          {ws.repos.length > 0 && (() => {
            const filteredRepos = filterDevWorkspaceRepos(ws.repos, repoFilter);
            return (
              <div className="rounded-lg border border-border bg-surface">
                <div className="flex flex-wrap items-center justify-between gap-2 px-3 py-2">
                  <button
                    type="button"
                    aria-expanded={reposExpanded}
                    onClick={() => setReposExpanded((open) => !open)}
                    className="flex items-center gap-2 text-left text-13 font-medium text-fg hover:text-accent"
                  >
                    <Icon name={reposExpanded ? "chev" : "chevr"} size={14} className="text-fg-tertiary" />
                    <span>
                      {ws.repos.length} {ws.repos.length === 1 ? "repository" : "repositories"} configured
                    </span>
                  </button>
                  <button
                    type="button"
                    onClick={() => setReposExpanded((open) => !open)}
                    className="text-12 text-accent hover:underline"
                  >
                    {reposExpanded ? "Hide list" : "Show list"}
                  </button>
                </div>

                {reposExpanded && (
                  <div className="space-y-2 border-t border-border p-3">
                    <div className="flex flex-wrap items-center gap-2">
                      <input
                        aria-label="Filter configured repositories"
                        value={repoFilter}
                        onChange={(e) => setRepoFilter(e.target.value)}
                        placeholder="Filter by repo or /workspace path…"
                        className="min-w-48 flex-1 rounded-md border border-border bg-surface-muted/40 px-2.5 py-1 text-12 text-fg"
                      />
                      {!confirmClearAll ? (
                        <button
                          type="button"
                          disabled={busy}
                          onClick={() => setConfirmClearAll(true)}
                          className="text-12 text-pill-blocked-fg hover:underline disabled:opacity-50"
                        >
                          Clear all
                        </button>
                      ) : (
                        <div className="flex items-center gap-2 text-12">
                          <button
                            type="button"
                            disabled={busy}
                            onClick={() =>
                              update.mutate(
                                { repos: [] },
                                {
                                  onSuccess: () => {
                                    setConfirmClearAll(false);
                                    setRepoFilter("");
                                    setReposExpanded(false);
                                  },
                                },
                              )
                            }
                            className="font-medium text-pill-blocked-fg hover:underline disabled:opacity-50"
                          >
                            Remove all {ws.repos.length}
                          </button>
                          <button
                            type="button"
                            disabled={busy}
                            onClick={() => setConfirmClearAll(false)}
                            className="text-fg-secondary hover:underline"
                          >
                            Cancel
                          </button>
                        </div>
                      )}
                    </div>

                    {filteredRepos.length > 0 ? (
                      <ul className="max-h-64 divide-y divide-border overflow-y-auto rounded-md border border-border bg-surface">
                        {filteredRepos.map((r) => (
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
                    ) : (
                      <p className="text-12 text-fg-tertiary">No repositories match “{repoFilter.trim()}”.</p>
                    )}
                  </div>
                )}
              </div>
            );
          })()}

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

          <div className="rounded-lg border border-border bg-surface-muted/40 p-3 space-y-2.5">
            <div className="flex flex-wrap items-center justify-between gap-2">
              <span className="text-12 font-medium text-fg">Seek a whole organization or user</span>
              {presets.data?.owners && presets.data.owners.length > 0 && (
                <div className="flex flex-wrap gap-1.5">
                  {presets.data.owners.map((o) => (
                    <button
                      key={o.login}
                      type="button"
                      disabled={busy}
                      onClick={() => startSeekOwner(o.login)}
                      className="rounded-md border border-border bg-surface px-2 py-0.5 text-12 text-fg hover:bg-hover disabled:opacity-50"
                    >
                      {o.login}
                    </button>
                  ))}
                </div>
              )}
            </div>
            <form
              className="flex flex-wrap gap-2"
              onSubmit={(e) => {
                e.preventDefault();
                startSeekOwner(ownerInput);
              }}
            >
              <input
                aria-label="GitHub organization or username"
                value={ownerInput}
                onChange={(e) => setOwnerInput(e.target.value)}
                placeholder="Organization or username (e.g. liamphmurphy)"
                className="min-w-52 flex-1 rounded-md border border-border bg-surface px-3 py-1.5 text-13 text-fg"
              />
              <Button type="submit" variant="outline" disabled={!ownerInput.trim() || ownerRepos.isFetching}>
                {ownerRepos.isFetching ? "Fetching…" : "Seek repos"}
              </Button>
            </form>

            {ownerRepos.isError && (
              <p role="alert" className="text-12 text-pill-blocked-fg">
                {ownerRepos.error.message}
              </p>
            )}

            {seekOwner && ownerRepos.data && (
              <div className="space-y-2 pt-1">
                <div className="flex flex-wrap items-center justify-between gap-2 text-12 text-fg-secondary">
                  <span>
                    Found {fetchedEntries.length} {fetchedEntries.length === 1 ? "repository" : "repositories"} under{" "}
                    <strong className="text-fg">{seekOwner}</strong> ({availableEntries.length} new)
                  </span>
                  <div className="flex items-center gap-2">
                    <button
                      type="button"
                      onClick={() => setSelectedOrgUrls(availableEntries.map((e) => e.url))}
                      className="text-accent hover:underline"
                    >
                      Select all
                    </button>
                    <button
                      type="button"
                      onClick={() => setSelectedOrgUrls([])}
                      className="text-fg-secondary hover:underline"
                    >
                      Clear
                    </button>
                    <button
                      type="button"
                      onClick={() => {
                        setSeekOwner("");
                        setSelectedOrgUrls(null);
                      }}
                      className="text-fg-tertiary hover:underline"
                    >
                      Close
                    </button>
                  </div>
                </div>

                {availableEntries.length > 0 ? (
                  <>
                    <ul className="max-h-44 divide-y divide-border overflow-y-auto rounded-md border border-border bg-surface">
                      {availableEntries.map((entry) => (
                        <li key={entry.url}>
                          <label className="flex cursor-pointer items-center gap-2.5 px-3 py-1.5 text-13 hover:bg-hover">
                            <input
                              type="checkbox"
                              checked={checkedSet.has(entry.url)}
                              onChange={() => toggleOrgUrl(entry.url)}
                            />
                            <span className="truncate text-fg">{entry.name}</span>
                          </label>
                        </li>
                      ))}
                    </ul>
                    <div className="flex justify-end">
                      <Button
                        variant="primary"
                        disabled={busy || availableEntries.filter((e) => checkedSet.has(e.url)).length === 0}
                        onClick={addSelectedOrgRepos}
                      >
                        Add {availableEntries.filter((e) => checkedSet.has(e.url)).length} repositories
                      </Button>
                    </div>
                  </>
                ) : (
                  <p className="text-12 text-fg-tertiary">All repositories under {seekOwner} are already added.</p>
                )}
              </div>
            )}
          </div>
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
