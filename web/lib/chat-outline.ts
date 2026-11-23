// Thread outline / artifact index for a chat conversation.
// Kept free of React so `npm run test:unit` covers it.

export type OutlineCategory = "all" | "bookmarks" | "links" | "checklists" | "code" | "files";

export type OutlineItem = {
  id: string;
  category: Exclude<OutlineCategory, "all">;
  messageId: string;
  title: string;
  subtitle?: string;
  badge?: string;
  href?: string;
  createdAt?: string;
};

export type OutlineMessageInput = {
  id: string;
  role: string;
  body_md: string;
  created_at?: string;
  bookmarked?: boolean;
  persona?: { name: string };
  checklist_state?: Record<string, boolean>;
  attachments?: Array<{ id: string; filename: string; content_type?: string }>;
  code_changes?: Array<{ path: string; status: string; additions: number; deletions: number }>;
};

const FENCE_RE = /^ {0,3}(`{3,}|~{3,})[ \t]*([^\r\n]*)$/;
const TASK_RE = /^\s*[-*+]\s+\[([ xX])\]\s+(.+)$/;
const MD_LINK_RE = /\[([^\]]+)\]\((https?:\/\/[^)\s]+)\)/g;
const BARE_URL_RE = /(?:^|\s)(https?:\/\/[^\s)<>]+)/g;

function snippet(text: string, limit = 110): string {
  const firstLine = text
    .replace(/\r\n/g, "\n")
    .split("\n")
    .map((l) => l.replace(/^#+\s*/, "").replace(/^>\s*/, "").trim())
    .find((l) => l.length > 0 && !l.startsWith("```") && !l.startsWith("<!--")) ?? "";
  if (firstLine.length <= limit) return firstLine || "Message";
  return `${firstLine.slice(0, limit - 1).trimEnd()}…`;
}

function hostOf(raw: string): string {
  try {
    return new URL(raw).hostname.replace(/^www\./, "");
  } catch {
    return raw;
  }
}

function closesFence(line: string, fence: string): boolean {
  const t = line.trim();
  return t.length >= fence.length && t[0] === fence[0] && t.replaceAll(fence[0], "") === "";
}

/** Extracts bookmarks, links, checklists, diffs/code blocks, and files/canvases from a chat transcript. */
export function buildThreadOutline(
  messages: readonly OutlineMessageInput[],
  canvases: readonly { id: string; title: string; kind?: string }[] = [],
): OutlineItem[] {
  const items: OutlineItem[] = [];
  const seenLinks = new Set<string>();
  const canvasById = new Map(canvases.map((c) => [c.id, c]));

  for (const m of messages) {
    if (m.role === "system") continue;
    const author = m.role === "user" ? "You" : (m.persona?.name ?? "Assistant");

    // 1. Bookmarked messages
    if (m.bookmarked) {
      items.push({
        id: `bm:${m.id}`,
        category: "bookmarks",
        messageId: m.id,
        title: snippet(m.body_md),
        subtitle: author,
        badge: "Pinned",
        createdAt: m.created_at,
      });
    }

    // 2. Attachments
    for (const att of m.attachments ?? []) {
      items.push({
        id: `att:${m.id}:${att.id}`,
        category: "files",
        messageId: m.id,
        title: att.filename,
        subtitle: author,
        badge: att.content_type?.split("/")[1]?.toUpperCase() || "File",
        createdAt: m.created_at,
      });
    }

    // 3. Code changes attached to reply
    for (const ch of m.code_changes ?? []) {
      items.push({
        id: `chg:${m.id}:${ch.path}`,
        category: "code",
        messageId: m.id,
        title: ch.path,
        subtitle: `${author} · ${ch.status}`,
        badge: `+${ch.additions} -${ch.deletions}`,
        createdAt: m.created_at,
      });
    }

    // Scan lines outside code blocks for checklists, fences, and links.
    const lines = m.body_md.replace(/\r\n/g, "\n").split("\n");
    let taskCount = 0;
    let taskDone = 0;
    let firstTaskLabel = "";
    let fenceIdx = 0;

    for (let i = 0; i < lines.length; i++) {
      const fm = FENCE_RE.exec(lines[i]);
      if (fm) {
        const fence = fm[1];
        const info = fm[2].trim().split(/\s+/)[0]?.toLowerCase() ?? "";
        let end = i + 1;
        while (end < lines.length && !closesFence(lines[end], fence)) end++;
        const block = lines.slice(i + 1, end).join("\n").trim();

        if (info === "canvas") {
          const cid = block.split(/\s+/)[0];
          const canvas = cid ? canvasById.get(cid) : undefined;
          if (cid) {
            items.push({
              id: `canvas:${m.id}:${cid}:${fenceIdx}`,
              category: "files",
              messageId: m.id,
              title: canvas?.title || "Canvas",
              subtitle: author,
              badge: canvas?.kind === "svg" ? "Design" : "Doc",
              createdAt: m.created_at,
            });
          }
        } else if (info === "diff" || info === "code-group" || (info && !["recommend", "gallery", "product", "choices", "dispatch", "workflow-run", "research-plan", "chart", "stats", "compare", "timeline", "tree", "graph", "plot", "datatable", "kv", "json-tree", "http", "tabs", "details", "mermaid", "svg-image", "svg-steps", "app", "pdf", "playground"].includes(info))) {
          let label = info === "diff" ? "Diff" : info === "code-group" ? "Code group" : `${info} snippet`;
          if (info === "diff" || info === "code-group") {
            try {
              const parsed = JSON.parse(block) as { title?: string };
              if (parsed.title) label = parsed.title;
            } catch {
              // raw unified diff
            }
          }
          items.push({
            id: `code:${m.id}:${fenceIdx}`,
            category: "code",
            messageId: m.id,
            title: label,
            subtitle: author,
            badge: info,
            createdAt: m.created_at,
          });
        } else if (info === "recommend") {
          const url = block.split("\n")[0]?.trim();
          if (url && /^https?:\/\//.test(url) && !seenLinks.has(url)) {
            seenLinks.add(url);
            items.push({
              id: `link:${m.id}:${url}`,
              category: "links",
              messageId: m.id,
              title: hostOf(url),
              subtitle: block.split("\n").slice(1).join(" ").trim() || url,
              badge: "Recommend",
              href: url,
              createdAt: m.created_at,
            });
          }
        } else if (info === "gallery" || info === "product") {
          try {
            const parsed = JSON.parse(block) as { items?: Array<{ name?: string; caption?: string; url?: string; image?: string }> };
            for (const entry of parsed.items ?? []) {
              const url = entry.url ?? entry.image;
              if (url && /^https?:\/\//.test(url) && !seenLinks.has(url)) {
                seenLinks.add(url);
                items.push({
                  id: `link:${m.id}:${url}`,
                  category: "links",
                  messageId: m.id,
                  title: entry.name || entry.caption || hostOf(url),
                  subtitle: hostOf(url),
                  badge: info === "product" ? "Product" : "Image",
                  href: url,
                  createdAt: m.created_at,
                });
              }
            }
          } catch {
            // ignore malformed JSON
          }
        }
        fenceIdx++;
        i = end;
        continue;
      }

      // Checklists (assistant replies)
      if (m.role === "assistant") {
        const tm = TASK_RE.exec(lines[i]);
        if (tm) {
          const idx = taskCount++;
          const defaultChecked = tm[1].toLowerCase() === "x";
          const checked = m.checklist_state && String(idx) in m.checklist_state
            ? m.checklist_state[String(idx)]
            : defaultChecked;
          if (checked) taskDone++;
          if (!firstTaskLabel) firstTaskLabel = tm[2].trim();
        }
      }

      // Markdown links & bare URLs
      for (const lm of lines[i].matchAll(MD_LINK_RE)) {
        const label = lm[1].trim();
        const url = lm[2].trim();
        if (!seenLinks.has(url)) {
          seenLinks.add(url);
          items.push({
            id: `link:${m.id}:${url}`,
            category: "links",
            messageId: m.id,
            title: label || hostOf(url),
            subtitle: hostOf(url),
            href: url,
            createdAt: m.created_at,
          });
        }
      }
      for (const bm of lines[i].matchAll(BARE_URL_RE)) {
        const url = bm[1].replace(/[.,;)>]+$/, "");
        if (!seenLinks.has(url)) {
          seenLinks.add(url);
          items.push({
            id: `link:${m.id}:${url}`,
            category: "links",
            messageId: m.id,
            title: hostOf(url),
            subtitle: url,
            href: url,
            createdAt: m.created_at,
          });
        }
      }
    }

    if (taskCount > 0) {
      items.push({
        id: `chk:${m.id}`,
        category: "checklists",
        messageId: m.id,
        title: firstTaskLabel || "Checklist",
        subtitle: `${author} · ${taskDone}/${taskCount} completed`,
        badge: `${taskDone}/${taskCount}`,
        createdAt: m.created_at,
      });
    }
  }

  return items;
}

export function filterOutline(
  items: readonly OutlineItem[],
  category: OutlineCategory,
  query: string,
): OutlineItem[] {
  const q = query.trim().toLowerCase();
  return items.filter((item) => {
    if (category !== "all" && item.category !== category) return false;
    if (!q) return true;
    return (
      item.title.toLowerCase().includes(q) ||
      (item.subtitle?.toLowerCase().includes(q) ?? false) ||
      (item.badge?.toLowerCase().includes(q) ?? false)
    );
  });
}

export function outlineCounts(items: readonly OutlineItem[]): Record<OutlineCategory, number> {
  const counts: Record<OutlineCategory, number> = {
    all: items.length,
    bookmarks: 0,
    links: 0,
    checklists: 0,
    code: 0,
    files: 0,
  };
  for (const item of items) counts[item.category]++;
  return counts;
}
