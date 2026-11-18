"use client";

import Link from "next/link";
import { Dialog } from "radix-ui";
import { useQueries } from "@tanstack/react-query";
import type { ReactNode } from "react";
import { api, unwrap, type Schemas } from "@/lib/api/client";
import { useDispatch, useDispatchPreview } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { Button, ButtonLink, IconButton } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { AgentAvatar } from "./avatars";
import { EnforcementChip, MonoChip, ScopeMode, type Enforcement } from "./labels";

type Preview = Schemas["DispatchPreview"];

function Row({ label, children }: { label: string; children: ReactNode }) {
  return (
    <div className="grid grid-cols-[116px_1fr] items-baseline gap-3 py-1.5 max-sm:grid-cols-1 max-sm:gap-1">
      <span className="text-13 text-fg-tertiary">{label}</span>
      <div className="flex min-w-0 flex-wrap items-center gap-1.5 text-13">{children}</div>
    </div>
  );
}

function ProjectMark() {
  return (
    <span className="rounded-[4px] border border-border-strong px-1.5 font-mono text-11 text-fg-tertiary" title="Set by the space override">
      project
    </span>
  );
}

/** When the run starts, from runner heartbeats and the queue. */
export function StartsLine({ p }: { p: Preview }) {
  const r = p.runner;
  if (!r.online) {
    if (r.starting) {
      return (
        <span className="flex items-center gap-1.5 text-fg-secondary">
          <span aria-hidden className="size-1.5 rounded-full bg-state-human" />
          Runner is starting: this run will start once it finishes booting
        </span>
      );
    }
    return (
      <span className="flex items-center gap-1.5 text-pill-blocked-fg">
        <span aria-hidden className="size-1.5 rounded-full bg-state-blocked" />
        No runner is online: it waits in the queue until one starts (<code className="inline">docker compose up runner</code>)
      </span>
    );
  }
  const free = r.slots - r.busy;
  return (
    <span className="flex items-center gap-1.5">
      <span aria-hidden className={cx("size-1.5 rounded-full", free > 0 ? "bg-state-done" : "bg-state-human")} />
      <span className="font-medium">{free > 0 && r.queued === 0 ? "Immediately" : "When a slot frees up"}</span>
      <span className="text-fg-tertiary">
        {r.busy} of {r.slots} runner slots in use{r.queued > 0 && ` · ${r.queued} queued`}
      </span>
    </span>
  );
}

function SinglePreview({ p }: { p: Preview }) {
  const res = p.resolved;
  const fromProject = (f: string) => res.provenance[f] === "project";
  const injected = p.secrets.filter((s) => s.injected);
  const withheld = p.secrets.filter((s) => !s.injected);
  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col divide-y divide-border-subtle">
        <Row label="Definition">
          <span>{p.agent.name}</span>
          {p.definition_version && <span className="font-mono text-12 text-fg-tertiary">v{p.definition_version}</span>}
          {p.has_override && <span className="text-fg-secondary">+ space override</span>}
          <Link href={`/agents/${p.agent.handle}`} className="ml-auto text-12 text-accent hover:underline">
            View definition
          </Link>
        </Row>
        <Row label="Harness">
          <MonoChip>{res.harness}</MonoChip>
          {fromProject("harness") && <ProjectMark />}
          <MonoChip>{res.model}</MonoChip>
          {fromProject("model") && <ProjectMark />}
          <span className="text-fg-tertiary">managed · container per run</span>
        </Row>
        <Row label="Repository">
          {p.repo_url ? (
            <span className="flex items-center gap-1.5 font-mono text-13">
              <Icon name="github" size={13} />
              {p.repo_url.replace(/^(?:ssh:\/\/)?git@github\.com[:/]/, "").replace(/\.git$/, "")}
            </span>
          ) : (
            <span className="text-fg-tertiary">None set for this space: the run starts from an empty repository</span>
          )}
        </Row>
        {p.repo_url && p.base_branch && <Row label="Base branch"><MonoChip>{p.base_branch}</MonoChip></Row>}
        <Row label="Branch">
          <span className="flex items-center gap-1.5 font-mono text-13">
            <Icon name="branch" size={13} />
            {p.branch}
          </span>
        </Row>
        {p.setup.length > 0 && (
          <Row label="Setup">
            {p.setup.map((c) => (
              <code key={c} className="inline">
                {c}
              </code>
            ))}
            <ProjectMark />
          </Row>
        )}
        <Row label="Context">
          {p.context.length ? (
            <>
              {p.context.map((c) => (
                <span key={c.path} className="rounded-[5px] bg-selected px-1.5 py-0.5 text-12" title={c.path}>
                  {c.kind === "wiki" ? "Wiki" : c.kind.toUpperCase()} · {c.title}
                </span>
              ))}
              <span className="font-mono text-12 text-fg-tertiary">→ .lazyagents/context/ and MCP</span>
            </>
          ) : (
            <span className="text-fg-tertiary">No documents attached</span>
          )}
        </Row>
      </div>

      <div className="overflow-x-auto rounded-xl border border-border">
        <table className="w-full min-w-[520px] text-left text-13">
          <thead className="text-12 text-fg-tertiary">
            <tr>
              <th className="px-3.5 py-2 font-normal">Scope</th>
              <th className="px-3 py-2 font-normal">Mode</th>
              <th className="px-3 py-2 font-normal">Enforced by</th>
              <th className="px-3 py-2 font-normal">What that means</th>
            </tr>
          </thead>
          <tbody>
            {p.scopes.map((s) => (
              <tr key={s.scope} className="border-t border-border-subtle">
                <td className="px-3.5 py-2 font-mono text-13">{s.scope}</td>
                <td className="px-3 py-2">
                  <ScopeMode mode={s.mode} />
                </td>
                <td className="px-3 py-2">
                  <EnforcementChip level={s.enforcement as Enforcement} />
                </td>
                <td className="px-3 py-2 text-13 text-fg-secondary">
                  {s.how} {s.source === "project" && <ProjectMark />}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="flex flex-col divide-y divide-border-subtle">
        <Row label="Secrets">
          {injected.map((s) => (
            <MonoChip key={s.name}>{s.name}</MonoChip>
          ))}
          {withheld.map((s) => (
            <span key={s.name} className="font-mono text-12 text-fg-tertiary" title={s.reason}>
              {s.name} withheld
            </span>
          ))}
          {p.secrets.length === 0 && <span className="text-fg-tertiary">None stored</span>}
        </Row>
        <Row label="Guards">
          <span className="font-mono text-13">
            {[res.budget.max_runtime && `${res.budget.max_runtime} runtime`, res.budget.max_turns && `${res.budget.max_turns} turns`]
              .filter(Boolean)
              .join(" · ") || "none"}
          </span>
          <span className="text-fg-tertiary">no spend cap</span>
        </Row>
        <Row label="Starts">
          <StartsLine p={p} />
        </Row>
      </div>
    </div>
  );
}

/** Bulk: one line per ticket, with anything that would block it. */
function BulkPreview({ previews }: { previews: Array<Preview | undefined> }) {
  const first = previews.find(Boolean);
  return (
    <div className="flex flex-col gap-3">
      <ul className="flex flex-col divide-y divide-border-subtle rounded-xl border border-border">
        {previews.map((p, i) =>
          p ? (
            <li key={p.ticket_key} className="flex flex-wrap items-center gap-2.5 px-3.5 py-2.5 text-13">
              <span className="w-16 font-mono text-12 text-fg-tertiary">{p.ticket_key}</span>
              {p.agent.name && <AgentAvatar name={p.agent.name} colorIndex={p.agent.color_index} label={false} />}
              <span className="font-medium">{p.agent.name || "No agent"}</span>
              {p.resolved && <MonoChip>{p.resolved.harness}</MonoChip>}
              {p.resolved && <MonoChip>{p.resolved.model}</MonoChip>}
              <span className="ml-auto text-12">
                {p.blockers.length ? (
                  <span className="text-pill-blocked-fg">{p.blockers.join("; ")}</span>
                ) : (p.queued_behind ?? []).length ? (
                  <span className="text-pill-human-fg">Queues until blockers are Done</span>
                ) : !p.harness_key.present ? (
                  <span className="text-pill-human-fg">No {p.harness_key.secret} key</span>
                ) : (
                  <span className="text-fg-tertiary">{p.scopes.filter((s) => s.mode === "requires_approval").length} scopes need approval</span>
                )}
              </span>
            </li>
          ) : (
            <li key={i} className="px-3.5 py-3">
              <Skeleton className="h-3 w-1/2" />
            </li>
          ),
        )}
      </ul>
      {first && (
        <Row label="Starts">
          <StartsLine p={first} />
        </Row>
      )}
    </div>
  );
}

/**
 * Dispatch (DESIGN.md §5 dispatch.html): exactly what the run will get, and
 * nothing starts until a person approves. One dialog for one or many.
 */
export function DispatchDialog({ keys, open, onOpenChange, onDone }: { keys: string[]; open: boolean; onOpenChange: (o: boolean) => void; onDone?: () => void }) {
  const single = keys.length === 1;
  const one = useDispatchPreview(single ? keys[0] : undefined);
  const many = useQueries({
    queries: single
      ? []
      : keys.map((key) => ({
          queryKey: ["tickets", "dispatch", key],
          queryFn: () => unwrap(api.GET("/tickets/{key}/dispatch", { params: { path: { key } } })),
        })),
  });
  const dispatch = useDispatch();
  const previews = single ? [one.data] : many.map((q) => q.data);
  const loaded = previews.every(Boolean);
  const blocked = previews.some((p) => p && p.blockers.length > 0);
  const isolates = (backend: string) => backend === "docker" || backend === "microvm";
  // Only isolated runs need a stored key; a fake/local runner uses the machine's own CLI login.
  const needsKey = (p: NonNullable<(typeof previews)[number]>) =>
    p.runner.runners.length === 0 || p.runner.runners.some((r) => isolates(r.backend));
  const keyless = previews.filter((p): p is NonNullable<typeof p> => !!p && p.blockers.length === 0 && !p.harness_key.present && needsKey(p));
  const noKey = keyless.length > 0;
  // Every online runner is isolated, so a run without its harness key would sit in starting: refuse before approving.
  const stuck = keyless.filter((p) => p.runner.runners.length > 0 && p.runner.runners.every((r) => isolates(r.backend)));
  const stuckReasons = [...new Set(stuck.map((p) => `${p.resolved?.harness ?? "This harness"}: no ${p.harness_key.secret} secret`))];
  const p = one.data;

  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Overlay className="motion-scrim fixed inset-0 z-40 bg-scrim" />
        <Dialog.Content
          aria-describedby="dispatch-desc"
          className="motion-dialog fixed left-1/2 top-[6vh] z-50 flex max-h-[88vh] w-[min(720px,calc(100%-32px))] -translate-x-1/2 flex-col overflow-hidden rounded-2xl border border-border-float bg-surface-raised shadow-[var(--shadow-float)] outline-none"
        >
          <div className="flex items-start gap-3 border-b border-border-subtle px-[18px] py-3.5">
            {single && p?.agent.name && <AgentAvatar name={p.agent.name} colorIndex={p.agent.color_index} size="md" label={false} />}
            <div className="flex flex-1 flex-col">
              <Dialog.Title className="type-heading">
                {single ? (
                  <>
                    Dispatch <span className="font-mono">{keys[0]}</span>
                    {p?.agent.name && ` to ${p.agent.name}`}
                  </>
                ) : (
                  `Dispatch ${keys.length} tickets`
                )}
              </Dialog.Title>
              <p id="dispatch-desc" className="text-13 text-fg-secondary">
                This is exactly what {single ? "the run" : "each run"} will get. Nothing starts until you approve.
              </p>
            </div>
            <Dialog.Close asChild>
              <IconButton icon="x" label="Close" />
            </Dialog.Close>
          </div>
          <div className="flex flex-col gap-3 overflow-y-auto px-[18px] py-4">
            {(one.isError || many.some((q) => q.isError)) && (
              <Banner tone="blocked" title="Couldn't load the preview">
                {(one.error ?? many.find((q) => q.error)?.error)?.message}
              </Banner>
            )}
            {single ? (
              !p ? (
                <div aria-busy="true" className="flex flex-col gap-2">
                  <Skeleton className="h-3 w-2/3" />
                  <Skeleton className="h-3 w-1/2" />
                  <Skeleton className="h-24 w-full" />
                </div>
              ) : p.blockers.length ? (
                <Banner tone="blocked" title="This ticket can't be dispatched">
                  {p.blockers.join(". ")}.
                </Banner>
              ) : (
                <>
                  {(p.queued_behind ?? []).length > 0 && (
                    <Banner tone="human" title="Queued behind blockers">
                      {(p.queued_behind ?? []).join(". ")}. The run starts automatically once they are Done.
                    </Banner>
                  )}
                  <SinglePreview p={p} />
                </>
              )
            ) : (
              <BulkPreview previews={previews} />
            )}
            {stuck.length > 0 ? (
              <Banner
                tone="blocked"
                title="No harness can run this"
                actions={
                  <ButtonLink href="/settings#secrets" variant="outline">
                    Add a key
                  </ButtonLink>
                }
              >
                {stuckReasons.join(". ")}. Every online runner uses an isolated sandbox, so the run would sit in starting.
              </Banner>
            ) : noKey && (
              <Banner
                tone="human"
                title="No harness API key"
                actions={
                  <ButtonLink href="/settings#secrets" variant="outline">
                    Add a key
                  </ButtonLink>
                }
              >
                Sandboxed runs fail at start without <code className="inline">{(p ?? previews.find(Boolean))?.harness_key.secret}</code>. A local runner can use
                the machine&apos;s own CLI login instead.
              </Banner>
            )}
            {dispatch.isError && (
              <Banner tone="blocked" title="Couldn't dispatch">
                {dispatch.error.message}
              </Banner>
            )}
          </div>
          <div className="flex flex-wrap items-center gap-3 border-t border-track bg-surface-sunken px-[18px] py-3">
            <span className="mr-auto text-12 text-fg-tertiary">Logged on the ticket as dispatched by you</span>
            <Dialog.Close asChild>
              <Button variant="ghost">Cancel</Button>
            </Dialog.Close>
            {single && p?.agent.handle && (
              <ButtonLink href={`/agents/${p.agent.handle}`} variant="outline" icon="edit">
                Edit agent
              </ButtonLink>
            )}
            <Button
              variant="approve"
              disabled={!loaded || blocked || stuck.length > 0 || dispatch.isPending}
              onClick={() =>
                dispatch.mutate(keys, {
                  onSuccess: () => {
                    onOpenChange(false);
                    onDone?.();
                  },
                })
              }
            >
              Approve &amp; dispatch
            </Button>
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}
