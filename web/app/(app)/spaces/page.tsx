"use client";

import Link from "next/link";
import { useEffect, useMemo, useRef } from "react";
import { useAllSpaceBranches, useSpaces, type Space } from "@/lib/api/space-hooks";
import { useChats } from "@/lib/api/hooks";
import { shortAgo } from "@/lib/format";
import { setTopBarTitle } from "@/lib/native-shell/title";
import { repoShortName } from "@/lib/persona-ui";
import { spaceHex } from "@/lib/spaces";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { SpaceTile } from "./_components/space-parts";

function sortByActivity(spaces: Space[]): Space[] {
  return [...spaces].sort((a, b) => {
    const ta = Date.parse(a.last_activity_at ?? a.updated_at) || 0;
    const tb = Date.parse(b.last_activity_at ?? b.updated_at) || 0;
    if (ta !== tb) return tb - ta;
    return a.name.localeCompare(b.name);
  });
}

function branchLabel(b: { active: boolean; pr_state?: string; push_state?: string; pr_url?: string; live: boolean; dirty: boolean }): string {
  if (b.pr_state === "merged") return b.active ? "New commits" : "Merged";
  if (b.pr_state === "closed") return b.active ? "New commits" : "Closed";
  if (b.pr_state === "draft") return "Draft PR";
  if (b.pr_state === "open") return "Open PR";
  if (b.push_state === "staging" || b.push_state === "pending") return "Pending push";
  if (b.push_state === "pushing") return "Pushing";
  if (b.push_state === "pushed") return b.pr_url ? "Open PR" : "Pushed";
  if (b.live) return "Editing";
  if (b.dirty) return "Uncommitted";
  return "Local branch";
}

export default function SpacesHomePage() {
  const titleToken = useRef(Symbol("spaces-home"));
  useEffect(() => {
    const token = titleToken.current;
    setTopBarTitle(token, { title: "Spaces" });
    return () => setTopBarTitle(token, null);
  }, []);

  const spacesQ = useSpaces();
  const chatsQ = useChats(false, "all", true, "all");
  const branchesQ = useAllSpaceBranches();

  const spaces = useMemo(() => sortByActivity(spacesQ.data?.spaces ?? []), [spacesQ.data?.spaces]);
  const spaceById = useMemo(() => new Map(spaces.map((s) => [s.id, s])), [spaces]);
  const inFlightChats = useMemo(
    () => (chatsQ.data?.chats ?? []).filter((c) => c.space && (c.state === "running" || c.unread > 0)),
    [chatsQ.data?.chats],
  );
  const activeBranches = useMemo(
    () => (branchesQ.data?.branches ?? []).filter((b) => b.active),
    [branchesQ.data?.branches],
  );

  const runningSpaces = useMemo(() => new Set(inFlightChats.filter((c) => c.state === "running").map((c) => c.space?.id).filter(Boolean)), [inFlightChats]);
  const unreadSpaces = useMemo(() => new Set(inFlightChats.filter((c) => c.unread > 0).map((c) => c.space?.id).filter(Boolean)), [inFlightChats]);
  const openPRCountBySpace = useMemo(() => {
    const m = new Map<string, number>();
    for (const b of activeBranches) {
      if (b.space_id) m.set(b.space_id, (m.get(b.space_id) ?? 0) + 1);
    }
    return m;
  }, [activeBranches]);

  return (
    <div className="mx-auto max-w-[1040px] px-[32px] py-[28px]">
      <div className="flex items-start justify-between gap-[16px]">
        <div>
          <h1 className="text-22 font-semibold tracking-[-0.02em] text-fg">Spaces</h1>
          <p className="mt-[4px] text-13 text-fg-secondary">
            Focused workbenches with shared instructions, live repos, Knowledge links, and isolated memory.
          </p>
        </div>
        <Link href="/spaces/new">
          <Button variant="primary">
            <Icon name="plus" size={12} />
            New space
          </Button>
        </Link>
      </div>

      {spacesQ.error ? (
        <div className="mt-[20px]">
          <Banner tone="blocked" title="Couldn’t load spaces">
            {spacesQ.error instanceof Error ? spacesQ.error.message : "unknown error"}
          </Banner>
        </div>
      ) : spacesQ.isPending ? (
        <div className="mt-[24px] grid gap-[14px] sm:grid-cols-2 lg:grid-cols-3">
          <Skeleton className="h-[120px]" />
          <Skeleton className="h-[120px]" />
          <Skeleton className="h-[120px]" />
        </div>
      ) : spaces.length === 0 ? (
        <div className="mt-[28px] flex flex-col items-center rounded-xl border border-border-subtle bg-surface px-[24px] py-[40px] text-center">
          <h2 className="text-15 font-semibold text-fg">Create your first Space</h2>
          <p className="mt-[6px] max-w-[420px] text-13 text-fg-secondary">
            Group chats around a repo, a Knowledge folder, or a long-running project with shared instructions and memory.
          </p>
          <Link href="/spaces/new" className="mt-[16px]">
            <Button variant="primary">
              <Icon name="plus" size={12} />
              New space
            </Button>
          </Link>
        </div>
      ) : (
        <div className="mt-[24px] space-y-[26px]">
          {(inFlightChats.length > 0 || activeBranches.length > 0) && (
            <section>
              <h2 className="mb-[8px] text-11 font-semibold tracking-[0.05em] text-fg-tertiary">IN FLIGHT</h2>
              <div className="space-y-[6px]">
                {inFlightChats.slice(0, 6).map((c) => (
                  <Link
                    key={c.id}
                    href={`/chat/${c.id}`}
                    className="flex items-center gap-[8px] rounded-lg border border-border-subtle bg-surface px-[12px] py-[8px] text-13 hover:bg-hover"
                  >
                    <span className={`h-[7px] w-[7px] shrink-0 rounded-full ${c.state === "running" ? "bg-state-done" : "bg-state-human"}`} />
                    {c.space && (
                      <span className="flex items-center gap-[5px] rounded-full border border-border-subtle bg-canvas px-[7px] py-[1px] text-11 text-fg-secondary">
                        <span className="h-[6px] w-[6px] rounded-full" style={{ backgroundColor: spaceHex(c.space.color) }} />
                        {c.space.name}
                      </span>
                    )}
                    <span className="truncate font-medium text-fg">{c.title || "Untitled chat"}</span>
                    <span className="ml-auto shrink-0 text-11 text-fg-secondary">
                      {c.state === "running" ? "Running" : `${c.unread} unread`}
                    </span>
                  </Link>
                ))}
                {activeBranches.slice(0, 6).map((b) => {
                  const sp = b.space_id ? spaceById.get(b.space_id) : undefined;
                  return (
                    <div
                      key={`${b.chat_id}|${b.repo_url}|${b.branch}`}
                      className="flex items-center gap-[8px] rounded-lg border border-border-subtle bg-surface px-[12px] py-[8px] text-12"
                    >
                      {sp && (
                        <Link
                          href={`/spaces/${sp.id}`}
                          className="flex items-center gap-[5px] rounded-full border border-border-subtle bg-canvas px-[7px] py-[1px] text-11 text-fg-secondary hover:text-fg"
                        >
                          <span className="h-[6px] w-[6px] rounded-full" style={{ backgroundColor: spaceHex(sp.color) }} />
                          {sp.name}
                        </Link>
                      )}
                      <span className="truncate font-mono font-medium text-fg">{b.branch}</span>
                      <span className="shrink-0 text-11 text-fg-tertiary">{repoShortName(b.repo_url)}</span>
                      <span className="shrink-0 rounded-full border border-border-subtle bg-canvas px-[6px] py-[1px] text-11 font-medium text-fg-secondary">
                        {branchLabel(b)}
                      </span>
                      <div className="ml-auto flex shrink-0 items-center gap-[10px]">
                        {b.pr_url && (
                          <a href={b.pr_url} target="_blank" rel="noreferrer" className="text-11 font-medium text-accent hover:underline">
                            {b.pr_number ? `PR #${b.pr_number} ↗` : "PR ↗"}
                          </a>
                        )}
                        <Link href={`/chat/${b.chat_id}`} className="text-11 text-fg-secondary hover:text-fg">
                          Chat →
                        </Link>
                      </div>
                    </div>
                  );
                })}
              </div>
            </section>
          )}

          <section>
            <div className="mb-[10px] flex items-center gap-[6px]">
              <h2 className="text-11 font-semibold tracking-[0.05em] text-fg-tertiary">ALL SPACES</h2>
              <span className="text-11 text-fg-tertiary">{spaces.length}</span>
            </div>
            <div className="grid gap-[14px] sm:grid-cols-2 lg:grid-cols-3">
              {spaces.map((sp) => {
                const isRunning = runningSpaces.has(sp.id);
                const hasUnread = unreadSpaces.has(sp.id);
                const openPRs = openPRCountBySpace.get(sp.id) ?? 0;
                return (
                  <Link
                    key={sp.id}
                    href={`/spaces/${sp.id}`}
                    className="flex flex-col gap-[10px] rounded-xl border border-border-subtle bg-surface p-[14px] hover:border-border-strong hover:bg-hover/40"
                  >
                    <div className="flex items-start gap-[10px]">
                      <SpaceTile name={sp.name} color={sp.color} size={32} />
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-[6px]">
                          <span className="truncate text-15 font-semibold text-fg">{sp.name}</span>
                          {isRunning ? (
                            <span className="h-[6px] w-[6px] shrink-0 rounded-full bg-state-done" />
                          ) : hasUnread ? (
                            <span className="h-[6px] w-[6px] shrink-0 rounded-full bg-state-human" />
                          ) : null}
                        </div>
                        <div className="text-11 text-fg-tertiary">{shortAgo(sp.last_activity_at ?? sp.updated_at)}</div>
                      </div>
                    </div>
                    {sp.description.trim() && (
                      <p className="line-clamp-2 text-12 text-fg-secondary">{sp.description}</p>
                    )}
                    <div className="mt-auto flex items-center gap-[6px] text-11 text-fg-tertiary">
                      {(sp.repo_count ?? 0) > 0 && <span>{sp.repo_count} repo{sp.repo_count === 1 ? "" : "s"}</span>}
                      {(sp.knowledge_count ?? 0) > 0 && <span>· {sp.knowledge_count} Knowledge</span>}
                      {(sp.open_task_count ?? 0) > 0 && <span>· {sp.open_task_count} tasks</span>}
                      {openPRs > 0 && <span className="font-medium text-accent">· {openPRs} PR{openPRs === 1 ? "" : "s"}</span>}
                      <span className="ml-auto">{sp.chat_count} chat{sp.chat_count === 1 ? "" : "s"}</span>
                    </div>
                  </Link>
                );
              })}
            </div>
          </section>
        </div>
      )}
    </div>
  );
}
