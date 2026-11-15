"use client";

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { createPortal } from "react-dom";
import { usePathname, useRouter, useSearchParams } from "next/navigation";
import { codeFullscreen, exitCodeFullscreen, openCodeFullscreen, switchPanel } from "@/lib/chat-panels";
import { useCodeReview, type CodeReview } from "@/lib/api/code-review-hooks";
import { useChat, useChatAsides, useChatMessages, useChatModels, useQueueFollowup, useSendChatMessage, useStartSecondOpinion } from "@/lib/api/hooks";
import type { Schemas } from "@/lib/api/client";
import { SecondOpinions } from "./asides";
import { SecondOpinionMenu } from "./second-opinion-menu";
import { changeTotals, STATUS_BADGE } from "@/lib/code-diff";
import {
  ancestorDirs,
  baseName,
  branchFileTree,
  commentKey,
  fileTree,
  formatBytes,
  repoName,
  resolveSelectedFile,
  reviewMessage,
  treeCounts,
  type BranchTreeNode,
  type LineComment,
} from "@/lib/code-review";
import { cx } from "@/lib/cx";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { CodeChanges, CodeFileView, Counts, Diff } from "./code-changes";

type Change = Schemas["ChatCodeChange"];
type Mode = "branch" | "turn";

const EMPTY_COMMENTS: Record<string, LineComment> = {};
const EMPTY_DIRS: Record<string, boolean> = {};
const noSubscribe = () => () => {};

/**
 * The Code dock & fullscreen reviewer: each repository's branch against its default branch,
 * including the captured branch file tree when expanded to fullscreen, or just what the last
 * reply changed. Comments on diff lines collect into one review per repository.
 */
export function CodePanel({ chatId }: { chatId: string }) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const fullscreen = codeFullscreen(searchParams);
  const mounted = useSyncExternalStore(noSubscribe, () => true, () => false);

  const reviews = useCodeReview(chatId).data?.repositories ?? [];
  const chat = useChat(chatId).data;
  const messages = useChatMessages(chatId).data?.messages;
  const models = useChatModels();
  const asideList = useChatAsides(chatId).data;
  const secondOpinion = useStartSecondOpinion(chatId);
  const [showSecondOpinions, setShowSecondOpinions] = useState(false);
  const [repo, setRepo] = useState<string>();
  const [mode, setMode] = useState<Mode>("branch");
  const [treeFilter, setTreeFilter] = useState<"all" | "changed">("all");
  const [pathsByRepo, setPathsByRepo] = useState<Record<string, string | undefined>>({});
  const [commentsByRepo, setCommentsByRepo] = useState<Record<string, Record<string, LineComment>>>({});
  const [collapsedDirsByRepo, setCollapsedDirsByRepo] = useState<Record<string, Record<string, boolean>>>({});
  const [editing, setEditing] = useState<{ repo: string; key: string }>();

  const send = useSendChatMessage(chatId);
  const queue = useQueueFollowup(chatId);

  const fullscreenBtnRef = useRef<HTMLButtonElement | null>(null);
  const exitFullscreenBtnRef = useRef<HTMLButtonElement | null>(null);
  const prevFullscreenRef = useRef(fullscreen);

  const review: CodeReview | undefined = reviews.find((r) => r.repository === repo) ?? reviews.find((r) => r.repository === chat?.repo_url) ?? reviews[0];
  const repoKey = review?.repository ?? "__default__";
  const primaryRepo = chat?.repo_url ?? reviews[0]?.repository;

  const enterFullscreen = useCallback(() => {
    router.replace(`${pathname}?${openCodeFullscreen(new URLSearchParams(searchParams.toString())).toString()}`, { scroll: false });
  }, [pathname, router, searchParams]);

  const exitFullscreen = useCallback(() => {
    router.replace(`${pathname}?${exitCodeFullscreen(new URLSearchParams(searchParams.toString())).toString()}`, { scroll: false });
  }, [pathname, router, searchParams]);

  // Restore focus between fullscreen trigger and fullscreen exit button cleanly across transitions.
  useEffect(() => {
    if (prevFullscreenRef.current === fullscreen) return;
    prevFullscreenRef.current = fullscreen;
    if (fullscreen) exitFullscreenBtnRef.current?.focus();
    else fullscreenBtnRef.current?.focus();
  }, [fullscreen]);

  // Dismiss fullscreen on Escape when focus isn't inside an active text/select control (e.g. draft comment textarea).
  useEffect(() => {
    if (!fullscreen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "Escape" || e.defaultPrevented) return;
      const target = e.target;
      if (target instanceof HTMLElement && target.closest("input, textarea, select, [contenteditable], [role='menu'], [data-radix-menu-content]")) return;
      e.preventDefault();
      e.stopPropagation();
      exitFullscreen();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [fullscreen, exitFullscreen]);

  const lastCodeMessage = useMemo(() => messages?.findLast((x) => x.role === "assistant" && x.code_changes?.length), [messages]);
  const lastTurn = useMemo(() => {
    return (lastCodeMessage?.code_changes ?? []).filter((c) => {
      if (!review) return true;
      return c.repository ? c.repository === review.repository : review.repository === primaryRepo;
    });
  }, [lastCodeMessage, review, primaryRepo]);
  const secondOpinions = useMemo(() => (asideList ?? []).filter((a) => a.second_opinion), [asideList]);
  const hasRunningSecondOpinion = secondOpinions.some((a) => a.state === "running");
  const secondOpinionsOpen = showSecondOpinions || hasRunningSecondOpinion;

  const branchFiles = review?.files;
  const files: Change[] = useMemo(() => (mode === "branch" ? (branchFiles ?? []) : lastTurn), [mode, branchFiles, lastTurn]);
  const branchTreeFiles = review?.tree;
  const hasTree = (branchTreeFiles?.length ?? 0) > 0;
  const showFullTree = fullscreen && mode === "branch" && hasTree && treeFilter === "all";
  const includeUnchanged = fullscreen && mode === "branch" && hasTree;

  const selectedPath = pathsByRepo[repoKey];
  const resolved = useMemo(
    () => resolveSelectedFile(selectedPath, branchTreeFiles, files, includeUnchanged),
    [selectedPath, branchTreeFiles, files, includeUnchanged],
  );
  const activeChange = resolved.change;
  const activeTreeFile = resolved.treeFile;

  const selectPath = useCallback(
    (nextPath: string) => {
      setPathsByRepo((all) => ({ ...all, [repoKey]: nextPath }));
      const dirs = ancestorDirs(nextPath);
      if (dirs.length > 0) {
        setCollapsedDirsByRepo((all) => {
          const cur = all[repoKey];
          if (!cur || dirs.every((d) => !cur[d])) return all;
          const nextDirs = { ...cur };
          for (const d of dirs) nextDirs[d] = false;
          return { ...all, [repoKey]: nextDirs };
        });
      }
    },
    [repoKey],
  );

  const toggleDir = useCallback(
    (dirPath: string) => {
      setCollapsedDirsByRepo((all) => {
        const cur = all[repoKey] ?? EMPTY_DIRS;
        return { ...all, [repoKey]: { ...cur, [dirPath]: !cur[dirPath] } };
      });
    },
    [repoKey],
  );

  const comments = commentsByRepo[repoKey] ?? EMPTY_COMMENTS;
  const collapsedDirs = collapsedDirsByRepo[repoKey] ?? EMPTY_DIRS;
  const pending = Object.values(comments).filter((c) => c.body.trim());
  const totals = changeTotals(files);
  const counts = useMemo(() => treeCounts(branchTreeFiles, files), [branchTreeFiles, files]);
  const compactTree = useMemo(() => fileTree(files), [files]);
  const nestedTree = useMemo(
    () => (showFullTree ? branchFileTree(branchTreeFiles, files) : []),
    [showFullTree, branchTreeFiles, files],
  );

  const setRepoComments = useCallback(
    (updater: (cur: Record<string, LineComment>) => Record<string, LineComment>) => {
      setCommentsByRepo((all) => ({ ...all, [repoKey]: updater(all[repoKey] ?? EMPTY_COMMENTS) }));
    },
    [repoKey],
  );

  if (!review) {
    return (
      <div className="grid flex-1 place-items-center p-6 text-center text-13 text-fg-tertiary" data-testid="code-panel-empty">
        No code yet. Once the persona works in a repository, its branch shows here, updating as it edits.
      </div>
    );
  }

  const sendReview = () => {
    const body = reviewMessage(pending, review.branch);
    if (!body) return;
    const targetRepo = repoKey;
    const done = {
      onSuccess: () => {
        setCommentsByRepo((all) => {
          const next = { ...all };
          delete next[targetRepo];
          return next;
        });
      },
    };
    if (chat?.state === "running") queue.mutate(body, done);
    else send.mutate({ body }, done);
  };
  const sending = send.isPending || queue.isPending;

  const renderNestedNodes = (nodes: BranchTreeNode[], depth: number) =>
    nodes.map((node) => {
      const padLeft = 10 + depth * 12;
      if (node.kind === "dir") {
        const collapsed = !!collapsedDirs[node.path];
        return (
          <div key={`dir:${node.path}`}>
            <button
              type="button"
              data-testid="code-tree-dir"
              data-dir-path={node.path}
              aria-expanded={!collapsed}
              onClick={() => toggleDir(node.path)}
              style={{ paddingLeft: `${padLeft}px` }}
              className="flex w-full items-center gap-1.5 py-1 pr-2 text-left text-12 text-fg-secondary hover:bg-row-hover hover:text-fg"
            >
              <Icon name={collapsed ? "chevr" : "chev"} size={12} className="text-fg-tertiary" />
              <Icon name="folder" size={12} className="text-fg-tertiary" />
              <span className="min-w-0 flex-1 truncate font-mono">{node.name}</span>
              {node.changedCount > 0 && (
                <span className="flex-none rounded bg-accent/15 px-1 font-mono text-10 text-accent" title={`${node.changedCount} changed`}>
                  {node.changedCount}
                </span>
              )}
            </button>
            {!collapsed && <div>{renderNestedNodes(node.children, depth + 1)}</div>}
          </div>
        );
      }

      const n = pending.filter((c) => c.path === node.path).length;
      const isSelected = node.path === resolved.path;
      const badge = node.status !== "unchanged" ? STATUS_BADGE[node.status] : null;
      return (
        <button
          key={`file:${node.path}`}
          type="button"
          data-testid="code-tree-file"
          data-file-path={node.path}
          data-file-status={node.status}
          aria-current={isSelected ? "true" : undefined}
          title={node.status === "renamed" && node.oldPath ? `Renamed from ${node.oldPath}` : node.path}
          onClick={() => selectPath(node.path)}
          style={{ paddingLeft: `${padLeft + 14}px` }}
          className={cx(
            "flex w-full items-center gap-1.5 py-0.5 pr-2 text-left text-12 hover:bg-row-hover",
            isSelected && "bg-selected font-medium text-fg",
            node.status === "deleted" && "text-fg-tertiary",
          )}
        >
          {badge ? (
            <span title={badge.label} className="w-3 flex-none text-center font-mono text-10 text-fg-secondary">
              {badge.letter}
            </span>
          ) : (
            <span aria-hidden className="w-3 flex-none text-center text-fg-tertiary/60">·</span>
          )}
          <span className={cx("min-w-0 flex-1 truncate font-mono", node.status === "deleted" && "line-through")}>
            {node.name}
          </span>
          {n > 0 && (
            <span className="flex-none rounded-full bg-accent/15 px-1 text-10 text-accent" aria-label={`${n} comments`}>
              {n}
            </span>
          )}
        </button>
      );
    });

  const panelBody = (
    <div
      className={cx(
        "flex min-h-0 flex-col bg-surface",
        fullscreen ? "fixed inset-0 z-[100] h-dvh w-screen" : "flex-1",
      )}
      data-testid="code-panel"
      data-fullscreen={fullscreen ? "true" : "false"}
      role={fullscreen ? "dialog" : undefined}
      aria-modal={fullscreen ? "true" : undefined}
      aria-label={fullscreen ? `Code review for ${repoName(review.repository)}` : undefined}
    >
      <header className="flex flex-none flex-wrap items-center gap-2 border-b border-border-subtle px-3 py-2 text-13">
        {fullscreen && (
          <button
            ref={exitFullscreenBtnRef}
            type="button"
            onClick={exitFullscreen}
            data-testid="code-fullscreen-exit"
            className="flex items-center gap-1 rounded-md border border-border bg-surface px-2 py-1 text-12 font-medium text-fg hover:bg-hover"
          >
            <span aria-hidden>←</span> Back to chat
          </button>
        )}
        {reviews.length > 1 ? (
          <select
            aria-label="Repository"
            data-testid="code-repo-select"
            value={review.repository}
            onChange={(e) => setRepo(e.target.value)}
            className="rounded-md border border-border bg-surface px-1.5 py-0.5 text-12"
          >
            {reviews.map((r) => (
              <option key={r.repository} value={r.repository}>
                {repoName(r.repository)}
              </option>
            ))}
          </select>
        ) : (
          <span className="text-fg-tertiary" data-testid="code-repo-name">{repoName(review.repository)}</span>
        )}
        <span className="flex min-w-0 items-center gap-1 font-mono text-12 text-fg" data-testid="code-branch">
          <Icon name="branch" size={13} className="flex-none text-fg-tertiary" />
          <span className="truncate">{review.branch ?? "detached"}</span>
        </span>
        {review.head_sha && (
          <code
            className="rounded bg-surface-sunken px-1.5 py-0.5 font-mono text-11 text-fg-secondary"
            data-testid="code-revision"
            title={review.head_sha}
          >
            {review.head_sha.slice(0, 7)}
          </code>
        )}
        <span className="text-12 text-fg-tertiary">
          {review.commits.length} {review.commits.length === 1 ? "commit" : "commits"}
          {review.dirty && " · uncommitted changes"}
        </span>
        {review.live ? (
          <span className="flex items-center gap-1 text-12 text-state-progress" data-testid="code-live">
            <span className="size-1.5 animate-pulse rounded-full bg-current" aria-hidden />
            live
          </span>
        ) : (
          <span className="text-11 text-fg-tertiary" data-testid="code-settled">
            {review.dirty ? "uncommitted" : "settled"}
          </span>
        )}
        <span className="ml-auto flex items-center gap-1.5">
          <SecondOpinionMenu
            variant="button"
            testId="code-second-opinion"
            groups={models.data}
            currentHarness={chat?.harness}
            currentModel={chat?.model}
            disabled={chat?.archived || secondOpinion.isPending}
            onSelect={(pick) => {
              setShowSecondOpinions(true);
              secondOpinion.mutate({
                harness: pick.harness,
                model: pick.model,
                ...(pick.body ? { body: pick.body } : {}),
                repository: review.repository,
                ...(mode === "turn" && lastCodeMessage?.id ? { anchor_message_id: lastCodeMessage.id } : {}),
              });
            }}
          />
          <span className="flex rounded-md bg-surface-sunken p-0.5 text-12" role="tablist" aria-label="Show">
            {(["branch", "turn"] as const).map((m) => (
              <button
                key={m}
                type="button"
                role="tab"
                aria-selected={mode === m}
                onClick={() => setMode(m)}
                className={cx("rounded px-2 py-0.5", mode === m ? "bg-surface text-fg shadow-sm" : "text-fg-tertiary hover:text-fg")}
              >
                {m === "branch" ? "Branch" : "Last reply"}
              </button>
            ))}
          </span>
          {!fullscreen ? (
            <button
              ref={fullscreenBtnRef}
              type="button"
              onClick={enterFullscreen}
              aria-label="Full screen"
              title="Full screen"
              data-testid="code-fullscreen-open"
              className="grid size-7 place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg"
            >
              <Icon name="expand" size={14} />
            </button>
          ) : (
            <button
              type="button"
              onClick={exitFullscreen}
              aria-label="Exit full screen"
              title="Exit full screen (Esc)"
              className="grid size-7 place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg"
            >
              <Icon name="shrink" size={14} />
            </button>
          )}
        </span>
      </header>
      {(secondOpinions.length > 0 || secondOpinion.error) && (
        <section
          aria-label="Second opinions"
          data-testid="code-second-opinion-strip"
          className="flex flex-none flex-col gap-2 border-b border-border-subtle bg-surface-sunken/50 px-3 py-2"
        >
          <div className="flex items-center gap-2 text-12">
            <button
              type="button"
              aria-expanded={secondOpinionsOpen}
              onClick={() => setShowSecondOpinions((o) => !o)}
              className="inline-flex items-center gap-1.5 font-medium text-fg hover:text-accent"
            >
              <Icon name="compare" size={13} className="text-fg-secondary" />
              <span>
                {secondOpinions.length} second {secondOpinions.length === 1 ? "opinion" : "opinions"}
              </span>
              {hasRunningSecondOpinion && <span className="text-11 text-state-progress">running…</span>}
              <Icon name="chev" size={11} className={cx("transition-transform", secondOpinionsOpen && "rotate-180")} />
            </button>
            {secondOpinion.error && (
              <span role="alert" className="text-12 text-pill-blocked-fg">
                {secondOpinion.error instanceof Error ? secondOpinion.error.message : "Could not start second opinion."}
              </span>
            )}
          </div>
          {secondOpinionsOpen && (
            <div className="max-h-72 overflow-y-auto">
              <SecondOpinions
                compact
                asides={secondOpinions}
                speakerName={(chat?.speaker ?? chat?.persona)?.name ?? chat?.agent.name ?? "the assistant"}
              />
            </div>
          )}
        </section>
      )}
      <div className="flex min-h-0 flex-1">
        <nav
          aria-label={showFullTree ? "Branch files" : "Changed files"}
          data-testid={showFullTree ? "code-branch-tree" : "code-changed-tree"}
          className={cx(
            "flex flex-none flex-col overflow-y-auto border-r border-border-subtle py-1 text-12",
            fullscreen ? "w-52 md:w-[280px]" : "w-56",
          )}
        >
          <div className="flex items-center gap-1.5 px-3 py-1 text-fg-tertiary">
            <span>
              {showFullTree
                ? `${counts.totalFiles} ${counts.totalFiles === 1 ? "file" : "files"}`
                : `${files.length} ${files.length === 1 ? "file" : "files"}`}
            </span>
            <Counts {...totals} />
          </div>
          {fullscreen && mode === "branch" && hasTree && (
            <div className="mx-2.5 mb-1.5 flex rounded-md bg-surface-sunken p-0.5 text-11">
              <button
                type="button"
                data-testid="code-tree-filter-all"
                aria-pressed={treeFilter === "all"}
                onClick={() => setTreeFilter("all")}
                className={cx("flex-1 rounded px-1.5 py-0.5", treeFilter === "all" ? "bg-surface font-medium text-fg shadow-sm" : "text-fg-tertiary hover:text-fg")}
              >
                All files ({counts.totalFiles})
              </button>
              <button
                type="button"
                data-testid="code-tree-filter-changed"
                aria-pressed={treeFilter === "changed"}
                onClick={() => setTreeFilter("changed")}
                className={cx("flex-1 rounded px-1.5 py-0.5", treeFilter === "changed" ? "bg-surface font-medium text-fg shadow-sm" : "text-fg-tertiary hover:text-fg")}
              >
                Changed ({files.length})
              </button>
            </div>
          )}
          <div className="min-h-0 flex-1 overflow-y-auto">
            {showFullTree ? (
              <>
                {renderNestedNodes(nestedTree, 0)}
                {review.tree_truncated && (
                  <p className="px-3 py-2 text-11 text-fg-tertiary" data-testid="code-tree-truncated">
                    Branch file tree truncated to 1,000 files.
                  </p>
                )}
              </>
            ) : (
              compactTree.map((d) => (
                <div key={d.dir}>
                  {d.dir && <p className="truncate px-3 pt-1.5 font-mono text-11 text-fg-tertiary">{d.dir}/</p>}
                  {d.files.map((f) => {
                    const n = pending.filter((c) => c.path === f.path).length;
                    return (
                      <button
                        key={f.path}
                        type="button"
                        data-testid="code-tree-file"
                        data-file-path={f.path}
                        data-file-status={f.status}
                        aria-current={f.path === resolved.path ? "true" : undefined}
                        onClick={() => selectPath(f.path)}
                        className={cx(
                          "flex w-full items-center gap-1.5 py-0.5 pr-2 text-left hover:bg-row-hover",
                          d.dir ? "pl-5" : "pl-3",
                          f.path === resolved.path && "bg-selected",
                        )}
                      >
                        <span title={STATUS_BADGE[f.status].label} className="flex-none font-mono text-10 text-fg-tertiary">
                          {STATUS_BADGE[f.status].letter}
                        </span>
                        <span className={cx("min-w-0 flex-1 truncate font-mono", f.status === "deleted" && "line-through text-fg-tertiary")}>
                          {baseName(f.path)}
                        </span>
                        {n > 0 && (
                          <span className="flex-none rounded-full bg-accent/15 px-1 text-10 text-accent" aria-label={`${n} comments`}>
                            {n}
                          </span>
                        )}
                      </button>
                    );
                  })}
                </div>
              ))
            )}
          </div>
        </nav>
        <section
          className="flex min-w-0 flex-1 flex-col"
          aria-label={
            activeChange
              ? `Diff of ${activeChange.path}`
              : activeTreeFile
                ? `Contents of ${activeTreeFile.path}`
                : "Diff"
          }
        >
          {activeChange ? (
            <>
              <p className="flex flex-none items-center gap-2 border-b border-border-subtle px-3 py-1.5 font-mono text-12 text-fg" data-testid="code-detail-header">
                <span className="rounded bg-surface-sunken px-1.5 py-0.5 font-sans text-11 text-fg-secondary">
                  {STATUS_BADGE[activeChange.status].label}
                </span>
                <span className="min-w-0 truncate">
                  {activeChange.status === "renamed" && activeChange.old_path ? `${activeChange.old_path} → ${activeChange.path}` : activeChange.path}
                </span>
                <span className="ml-auto">
                  <Counts additions={activeChange.additions} deletions={activeChange.deletions} />
                </span>
              </p>
              <div className="min-h-0 flex-1 overflow-auto">
                {activeChange.binary ? (
                  <p className="px-3 py-2 text-12 text-fg-tertiary" data-testid="code-file-fallback">Binary file changed</p>
                ) : !activeChange.patch ? (
                  <p className="px-3 py-2 text-12 text-fg-tertiary" data-testid="code-file-fallback">Diff not shown (too large).</p>
                ) : (
                  <Diff
                    key={`${repoKey}:${mode}:${activeChange.path}`}
                    tall
                    patch={activeChange.patch}
                    path={activeChange.path}
                    active
                    onLine={(row) => {
                      const line = row.newNo ?? row.oldNo ?? 0;
                      const c: LineComment = { path: activeChange.path, line, side: row.newNo === undefined ? "old" : "new", code: row.text, body: "" };
                      const k = commentKey(c);
                      setRepoComments((all) => (all[k] ? all : { ...all, [k]: c }));
                      setEditing({ repo: repoKey, key: k });
                    }}
                    below={(row) => {
                      const k = commentKey({ path: activeChange.path, line: row.newNo ?? row.oldNo ?? 0, side: row.newNo === undefined ? "old" : "new" });
                      const c = comments[k];
                      if (!c) return null;
                      return (
                        <LineCommentBox
                          comment={c}
                          editing={editing?.repo === repoKey && editing?.key === k}
                          onEdit={() => setEditing({ repo: repoKey, key: k })}
                          onSave={(body) => {
                            setRepoComments((all) => ({ ...all, [k]: { ...c, body } }));
                            setEditing(undefined);
                          }}
                          onDelete={() => {
                            setRepoComments((all) => Object.fromEntries(Object.entries(all).filter(([key]) => key !== k)));
                            setEditing(undefined);
                          }}
                        />
                      );
                    }}
                  />
                )}
                {activeChange.truncated && <p className="px-3 py-2 text-12 text-fg-tertiary">Diff truncated.</p>}
              </div>
            </>
          ) : activeTreeFile ? (
            <>
              <p className="flex flex-none items-center gap-2 border-b border-border-subtle px-3 py-1.5 font-mono text-12 text-fg" data-testid="code-detail-header">
                <span className="rounded bg-surface-sunken px-1.5 py-0.5 font-sans text-11 text-fg-secondary">Unchanged</span>
                <span className="min-w-0 truncate">{activeTreeFile.path}</span>
                <span className="ml-auto font-sans text-11 text-fg-tertiary">{formatBytes(activeTreeFile.size)}</span>
              </p>
              <div className="min-h-0 flex-1 overflow-auto">
                {activeTreeFile.binary ? (
                  <p className="px-3 py-2 text-12 text-fg-tertiary" data-testid="code-file-fallback">Binary file not shown.</p>
                ) : activeTreeFile.content == null && activeTreeFile.truncated ? (
                  <p className="px-3 py-2 text-12 text-fg-tertiary" data-testid="code-file-fallback">File not shown (too large).</p>
                ) : activeTreeFile.content == null ? (
                  <p className="px-3 py-2 text-12 text-fg-tertiary" data-testid="code-file-fallback">File content unavailable.</p>
                ) : (
                  <>
                    <CodeFileView key={`${repoKey}:${activeTreeFile.path}`} content={activeTreeFile.content} path={activeTreeFile.path} active tall />
                    {activeTreeFile.truncated && (
                      <p className="border-t border-border-subtle px-3 py-2 text-12 text-fg-tertiary" data-testid="code-file-truncated">
                        File content truncated (showing first 40 KB).
                      </p>
                    )}
                  </>
                )}
              </div>
            </>
          ) : (
            <p className="grid flex-1 place-items-center text-13 text-fg-tertiary">
              {mode === "turn" ? "The last reply changed no files here." : "No changes on this branch yet."}
            </p>
          )}
        </section>
      </div>
      {pending.length > 0 && (
        <footer className="flex flex-none items-center gap-2 border-t border-border-subtle px-3 py-2 text-13" data-testid="code-review-bar">
          <span className="text-fg-secondary">
            {pending.length} {pending.length === 1 ? "comment" : "comments"} for the persona
          </span>
          <span className="flex-1" />
          <Button variant="outline" disabled={sending} onClick={() => setRepoComments(() => EMPTY_COMMENTS)}>
            Discard
          </Button>
          <Button variant="primary" disabled={sending} onClick={sendReview} title={chat?.state === "running" ? "Queued after the current reply" : undefined}>
            Send review
          </Button>
        </footer>
      )}
    </div>
  );

  if (fullscreen && mounted) {
    return createPortal(panelBody, document.body);
  }
  return panelBody;
}

function LineCommentBox({ comment, editing, onEdit, onSave, onDelete }: { comment: LineComment; editing: boolean; onEdit: () => void; onSave: (body: string) => void; onDelete: () => void }) {
  const [draft, setDraft] = useState(comment.body);
  if (!editing) {
    return (
      <div className="mx-3 my-1 whitespace-pre-wrap rounded-md border border-border bg-surface px-3 py-2 font-sans text-13 text-fg" data-testid="line-comment">
        {comment.body}
        <span className="ml-2 inline-flex gap-2 text-12">
          <button type="button" className="text-accent hover:underline" onClick={onEdit}>
            Edit
          </button>
          <button type="button" className="text-fg-tertiary hover:underline" onClick={onDelete}>
            Delete
          </button>
        </span>
      </div>
    );
  }
  return (
    <div className="mx-3 my-1 flex flex-col gap-2 rounded-md border border-accent/40 bg-surface p-2 font-sans" data-testid="line-comment-editor">
      <textarea
        autoFocus
        aria-label={`Comment on ${comment.path}:${comment.line}`}
        value={draft}
        onChange={(e) => setDraft(e.target.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) onSave(draft);
          if (e.key === "Escape") {
            e.stopPropagation();
            if (comment.body) onSave(comment.body);
            else onDelete();
          }
        }}
        rows={3}
        placeholder="What should change here?"
        className="w-full resize-y rounded border border-border bg-surface-sunken px-2 py-1 text-13 text-fg"
      />
      <span className="flex justify-end gap-2">
        <Button variant="outline" onClick={() => (comment.body ? onSave(comment.body) : onDelete())}>
          Cancel
        </Button>
        <Button variant="primary" disabled={!draft.trim()} onClick={() => onSave(draft)}>
          Add to review
        </Button>
      </span>
    </div>
  );
}

/** A reply's changed files, with a way into the Code dock for the whole branch. */
export function ReplyCodeChanges({ changes }: { changes?: Change[] }) {
  const router = useRouter();
  if (!changes?.length) return null;
  const review = () => router.replace(`${window.location.pathname}?${switchPanel(new URLSearchParams(window.location.search), "code").toString()}`, { scroll: false });
  return <CodeChanges changes={changes} onReview={review} />;
}
