// The Code dock's pure parts (components: app/(app)/chat/_components/code-panel and push-requests).
// Kept free of React so `npm run test:unit` covers it.

import type { Schemas } from "@/lib/api/client";

type Change = Schemas["ChatCodeChange"];
export type CodeReviewFile = Schemas["CodeReviewFile"];

export type BranchTreeFileStatus = Change["status"] | "unchanged";

export interface BranchTreeFile {
  kind: "file";
  path: string;
  name: string;
  dir: string;
  status: BranchTreeFileStatus;
  oldPath?: string;
  additions: number;
  deletions: number;
  binary: boolean;
  size: number;
  truncated: boolean;
  exists: boolean;
  change?: Change;
  treeFile?: CodeReviewFile;
}

export interface BranchTreeDir {
  kind: "dir";
  path: string;
  name: string;
  children: BranchTreeNode[];
  fileCount: number;
  changedCount: number;
}

export type BranchTreeNode = BranchTreeDir | BranchTreeFile;

/** A comment the person left on one line of the diff, sent to the persona with the others as one review. */
export type LineComment = {
  path: string;
  /** The line's number in the new file, or in the old one for a removed line. */
  line: number;
  side: "new" | "old";
  /** The line itself, quoted so the persona sees what was meant even if the file moved on. */
  code: string;
  body: string;
};

/** A comment's identity: one per line and side. */
export const commentKey = (c: Pick<LineComment, "path" | "line" | "side">) => `${c.side}:${c.path}:${c.line}`;

/** The repository's short name: owner/name from a GitHub URL, else the URL. */
export function repoName(url: string): string {
  return url.replace(/^https:\/\/github\.com\//, "").replace(/^git@github\.com:/, "").replace(/\.git$/, "");
}

/**
 * The review as the message the persona gets: each comment anchored to file:line with the line
 * quoted, in file and line order, like a GitHub review. Empty comments are left out.
 */
export function reviewMessage(comments: readonly LineComment[], branch?: string): string {
  const kept = comments.filter((c) => c.body.trim());
  if (!kept.length) return "";
  const sorted = [...kept].sort((a, b) => a.path.localeCompare(b.path) || a.line - b.line);
  const parts = sorted.map((c) => {
    const where = `\`${c.path}:${c.line}\`${c.side === "old" ? " (removed line)" : ""}`;
    const quote = c.code.trim() ? `\n  > ${c.code.trim().slice(0, 200)}` : "";
    return `- ${where}${quote}\n  ${c.body.trim().replace(/\n/g, "\n  ")}`;
  });
  const n = kept.length;
  return `Review of ${branch ? `\`${branch}\`` : "your changes"} (${n} ${n === 1 ? "comment" : "comments"}). Please address each:\n\n${parts.join("\n")}`;
}

/** Files grouped by directory for the dock's tree: directories in order, files sorted within. */
export function fileTree(files: readonly Change[]): { dir: string; files: Change[] }[] {
  const byDir = new Map<string, Change[]>();
  for (const f of files) {
    const i = f.path.lastIndexOf("/");
    const dir = i < 0 ? "" : f.path.slice(0, i);
    byDir.set(dir, [...(byDir.get(dir) ?? []), f]);
  }
  return [...byDir.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([dir, fs]) => ({ dir, files: fs.sort((a, b) => a.path.localeCompare(b.path)) }));
}

/** The file's name without its directory. */
export const baseName = (path: string) => path.slice(path.lastIndexOf("/") + 1);

/** What a push card says while it isn't waiting on the person. */
export function pushStateLabel(r: Pick<Schemas["PushRequest"], "state" | "auto" | "pr_number">, persona: string): string {
  switch (r.state) {
    case "staging":
      return `Staged when ${persona}'s turn ends`;
    case "pending":
      return "Waiting for you";
    case "pushing":
      return "Pushing…";
    case "pushed":
      return `${r.auto ? "Pushed automatically" : "Pushed"}${r.pr_number ? ` · PR #${r.pr_number}` : ""}`;
    case "declined":
      return "Declined";
    case "failed":
      return "Not pushed";
  }
}

type PlacedPushMessage = Pick<Schemas["ChatMessage"], "id" | "role" | "created_at" | "run_id" | "turn_seq">;

export type PlacedPushRequests<T extends Pick<Schemas["PushRequest"], "id" | "state" | "error" | "created_at" | "run_id" | "message_id">> = {
  byMessage: Map<string, T[]>;
  afterMessage: Map<string, T[]>;
  leading: T[];
  trailing: T[];
  live: T[];
};

const appendPlaced = <T>(map: Map<string, T[]>, key: string, item: T) => {
  const list = map.get(key);
  if (list) list.push(item);
  else map.set(key, [item]);
};

/**
 * Anchors each shown push request to its place in the chat log so open, pushed, and failed
 * PR blocks stay with the turn that requested them instead of stacking at the bottom.
 */
export function placePushRequests<T extends Pick<Schemas["PushRequest"], "id" | "state" | "error" | "created_at" | "run_id" | "message_id">>(
  requests: readonly T[],
  messages: readonly PlacedPushMessage[],
  opts: { running: boolean; currentRunId?: string | null; hasMore?: boolean },
): PlacedPushRequests<T> {
  const byMessage = new Map<string, T[]>();
  const afterMessage = new Map<string, T[]>();
  const leading: T[] = [];
  const trailing: T[] = [];
  const live: T[] = [];

  // Decided cards stay as a record only when they say something: a pull request, or why not.
  const shown = requests.filter((r) => r.state !== "declined" || !!r.error);
  if (!shown.length) return { byMessage, afterMessage, leading, trailing, live };

  const messageIds = new Set(messages.map((m) => m.id));
  const firstAt = messages.length ? Date.parse(messages[0].created_at) : Number.NaN;
  const lastAt = messages.length ? Date.parse(messages[messages.length - 1].created_at) : Number.NaN;

  for (const r of shown) {
    if (r.message_id && messageIds.has(r.message_id)) {
      appendPlaced(byMessage, r.message_id, r);
      continue;
    }

    const reqAt = Date.parse(r.created_at);
    // When earlier messages aren't loaded yet, requests linked before the window stay hidden with them.
    if (r.message_id && opts.hasMore && !Number.isNaN(firstAt) && reqAt < firstAt) {
      continue;
    }

    // Only treat an unlinked request as live when it belongs to the currently active turn
    // (a chat segment reuses current_run_id across turns, so ordering after the last message matters).
    const afterLast = !messages.length || Number.isNaN(lastAt) || reqAt >= lastAt;
    if (!r.message_id && opts.running && (!r.run_id || r.run_id === opts.currentRunId) && afterLast) {
      live.push(r);
      continue;
    }

    // Legacy rows (and requests in the brief turn-end refetch gap) fall back to creation time.
    const idx = messages.findIndex((m) => Date.parse(m.created_at) >= reqAt);
    if (idx === -1) {
      trailing.push(r);
      continue;
    }
    const anchor = messages[idx];
    if (anchor.role !== "user") {
      // Opening lines share a turn with the final reply; attach to the turn's last assistant message.
      let end = idx;
      while (
        anchor.role === "assistant" &&
        anchor.run_id &&
        end + 1 < messages.length &&
        messages[end + 1].role === "assistant" &&
        messages[end + 1].run_id === anchor.run_id &&
        messages[end + 1].turn_seq === anchor.turn_seq
      ) {
        end++;
      }
      appendPlaced(byMessage, messages[end].id, r);
      continue;
    }
    if (idx === 0) {
      leading.push(r);
    } else if (messages[idx - 1].role !== "user") {
      appendPlaced(byMessage, messages[idx - 1].id, r);
    } else {
      appendPlaced(afterMessage, messages[idx - 1].id, r);
    }
  }

  return { byMessage, afterMessage, leading, trailing, live };
}

/** Parent directory paths from outermost to immediate parent (e.g. "a/b/c.ts" -> ["a", "a/b"]). */
export function ancestorDirs(filePath: string): string[] {
  const parts = filePath.split("/");
  const dirs: string[] = [];
  for (let i = 0; i < parts.length - 1; i++) {
    dirs.push(parts.slice(0, i + 1).join("/"));
  }
  return dirs;
}

/** Summary counts combining the branch tree snapshot and diff changes. */
export function treeCounts(tree: readonly CodeReviewFile[] | undefined, changes: readonly Change[]) {
  const changedPaths = new Set(changes.map((c) => c.path));
  const existing = new Set<string>();
  for (const f of tree ?? []) existing.add(f.path);
  let deletedFiles = 0;
  for (const c of changes) {
    if (c.status === "deleted") deletedFiles++;
    else existing.add(c.path);
  }
  let unchangedFiles = 0;
  for (const p of existing) {
    if (!changedPaths.has(p)) unchangedFiles++;
  }
  return {
    totalFiles: existing.size,
    changedFiles: changes.length,
    unchangedFiles,
    deletedFiles,
    hasCompleteTree: (tree?.length ?? 0) > 0,
  };
}

/** Resolves which file is active in the panel, preserving selected unchanged or changed files across transitions. */
export function resolveSelectedFile(
  selectedPath: string | null | undefined,
  tree: readonly CodeReviewFile[] | undefined,
  changes: readonly Change[],
  includeUnchanged: boolean,
): { path: string | undefined; change?: Change; treeFile?: CodeReviewFile } {
  const treeMap = new Map<string, CodeReviewFile>();
  for (const tf of tree ?? []) treeMap.set(tf.path, tf);
  const changeMap = new Map<string, Change>();
  for (const c of changes) changeMap.set(c.path, c);

  if (selectedPath) {
    const ch = changeMap.get(selectedPath);
    const tf = treeMap.get(selectedPath);
    if (ch) return { path: ch.path, change: ch, treeFile: tf };
    if (includeUnchanged && tf) return { path: tf.path, treeFile: tf };
  }
  if (changes[0]) {
    const c = changes[0];
    return { path: c.path, change: c, treeFile: treeMap.get(c.path) };
  }
  if (includeUnchanged && tree?.[0]) {
    return { path: tree[0].path, treeFile: tree[0] };
  }
  return { path: undefined };
}

/** Nested expandable directory tree merging unchanged branch files and diff changes. */
export function branchFileTree(tree: readonly CodeReviewFile[] | undefined, changes: readonly Change[]): BranchTreeNode[] {
  const treeByPath = new Map<string, CodeReviewFile>();
  for (const tf of tree ?? []) treeByPath.set(tf.path, tf);
  const changeByPath = new Map<string, Change>();
  for (const ch of changes) changeByPath.set(ch.path, ch);

  const allPaths = new Set<string>([...treeByPath.keys(), ...changeByPath.keys()]);
  const files: BranchTreeFile[] = [];
  for (const path of allPaths) {
    const tf = treeByPath.get(path);
    const ch = changeByPath.get(path);
    const slash = path.lastIndexOf("/");
    const dir = slash < 0 ? "" : path.slice(0, slash);
    const name = slash < 0 ? path : path.slice(slash + 1);
    if (ch) {
      files.push({
        kind: "file",
        path,
        name,
        dir,
        status: ch.status,
        oldPath: ch.old_path,
        additions: ch.additions,
        deletions: ch.deletions,
        binary: ch.binary || (tf?.binary ?? false),
        size: tf?.size ?? 0,
        truncated: ch.truncated || (tf?.truncated ?? false),
        exists: ch.status !== "deleted",
        change: ch,
        treeFile: tf,
      });
    } else if (tf) {
      files.push({
        kind: "file",
        path,
        name,
        dir,
        status: "unchanged",
        additions: 0,
        deletions: 0,
        binary: tf.binary,
        size: tf.size,
        truncated: tf.truncated,
        exists: true,
        treeFile: tf,
      });
    }
  }

  interface MutableDir {
    path: string;
    name: string;
    dirs: Map<string, MutableDir>;
    files: BranchTreeFile[];
  }
  const root: MutableDir = { path: "", name: "", dirs: new Map(), files: [] };

  for (const f of files) {
    const parts = f.path.split("/");
    let cur = root;
    for (let i = 0; i < parts.length - 1; i++) {
      const seg = parts[i];
      const dPath = parts.slice(0, i + 1).join("/");
      let next = cur.dirs.get(seg);
      if (!next) {
        next = { path: dPath, name: seg, dirs: new Map(), files: [] };
        cur.dirs.set(seg, next);
      }
      cur = next;
    }
    cur.files.push(f);
  }

  const freeze = (d: MutableDir): BranchTreeNode[] => {
    const dirNodes: BranchTreeDir[] = [...d.dirs.values()]
      .sort((a, b) => a.name.localeCompare(b.name))
      .map((sub) => {
        const children = freeze(sub);
        let fileCount = 0;
        let changedCount = 0;
        for (const ch of children) {
          if (ch.kind === "dir") {
            fileCount += ch.fileCount;
            changedCount += ch.changedCount;
          } else {
            if (ch.exists) fileCount += 1;
            if (ch.status !== "unchanged") changedCount += 1;
          }
        }
        return { kind: "dir", path: sub.path, name: sub.name, children, fileCount, changedCount };
      });
    const fileNodes = [...d.files].sort((a, b) => a.name.localeCompare(b.name));
    return [...dirNodes, ...fileNodes];
  };

  return freeze(root);
}

/** Compact human byte formatting for file headers. */
export function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
