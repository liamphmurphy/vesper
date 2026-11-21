// Pure helpers for printing and PDF-exporting Knowledge pages.
// Kept free of React and DOM imports so `node --test` covers it directly.
import { defaultLabel, parseWikiLinks } from "./wikilinks.ts";

export type KnowledgePrintStyle = "clean" | "editorial" | "compact" | "technical";

export const DEFAULT_KNOWLEDGE_PRINT_STYLE: KnowledgePrintStyle = "clean";

export const KNOWLEDGE_PRINT_STYLES: readonly {
  id: KnowledgePrintStyle;
  label: string;
  description: string;
  icon: "artifacts" | "wiki" | "board" | "code";
}[] = [
  { id: "clean", label: "Clean", description: "Modern sans-serif with balanced whitespace", icon: "artifacts" },
  { id: "editorial", label: "Editorial", description: "Classic serif typography for long-form reading", icon: "wiki" },
  { id: "compact", label: "Compact", description: "Tighter type and spacing for dense notes", icon: "board" },
  { id: "technical", label: "Technical", description: "Structured spec layout with monospace accents", icon: "code" },
];

export function parseKnowledgePrintStyle(raw: string | null | undefined): KnowledgePrintStyle {
  const normalized = raw?.trim().toLowerCase();
  if (normalized && KNOWLEDGE_PRINT_STYLES.some((s) => s.id === normalized)) {
    return normalized as KnowledgePrintStyle;
  }
  return DEFAULT_KNOWLEDGE_PRINT_STYLE;
}

export function knowledgePrintHref(id: string, style: KnowledgePrintStyle = DEFAULT_KNOWLEDGE_PRINT_STYLE): string {
  return `/print/knowledge/${encodeURIComponent(id)}?style=${style}`;
}

/** Pre-filled composer prompt for asking a Knowledge persona to design a custom PDF via render_pdf. */
export function buildPersonaPdfPrompt(page: { title: string; path: string | null }): string {
  const target = page.path?.trim() || page.title?.trim() || "Untitled";
  return `Export [[${target}]] as a polished, print-ready PDF using render_pdf. `;
}

/** Formats a Knowledge page property value into clean print text without raw [[wikilink]] brackets. */
export function formatPropertyValue(v: unknown): string {
  if (v === null || v === undefined) return "";
  if (Array.isArray(v)) {
    return v.map((item) => formatPropertyValue(item)).filter(Boolean).join(", ");
  }
  if (typeof v === "object") {
    return JSON.stringify(v);
  }
  const s = String(v);
  const refs = parseWikiLinks(s);
  if (!refs.length) return s;
  let out = s;
  for (const r of refs) {
    out = out.replace(r.raw, defaultLabel(r));
  }
  return out;
}

/** Drops a leading `# Title` when it repeats the Knowledge page's own title header. */
export function stripDuplicateLeadingHeading(md: string, title: string): string {
  const normalizedTitle = title.trim().toLowerCase();
  if (!normalizedTitle) return md;
  const lines = md.replace(/\r\n?/g, "\n").split("\n");
  let first = 0;
  while (first < lines.length && lines[first].trim() === "") first++;
  if (first >= lines.length) return md;
  const match = /^\s*#\s+(.+?)\s*#*\s*$/.exec(lines[first]);
  if (!match || match[1].trim().toLowerCase() !== normalizedTitle) return md;
  let next = first + 1;
  while (next < lines.length && lines[next].trim() === "") next++;
  return lines.slice(next).join("\n");
}

const CODE_SPAN_RE = /(`+)([^`\n]*?)\1/g;
const INLINE_EMBED_RE = /!\[\[([^[\]\n]+?)\]\]/g;
const STANDALONE_EMBED_RE = /^!\[\[([^[\]\n]+?)\]\]$/;
const CALLOUT_OPEN_RE = /^ {0,3}>\s*\[!([A-Za-z-]+)\]([+-])?(?:\s+(.*))?$/;
const FENCE_OPEN_RE = /^ {0,3}(`{3,}|~{3,})/;

function fenceCloseMatch(line: string, fence: string): boolean {
  const trimmed = line.trim();
  const char = fence[0];
  return trimmed.length >= fence.length && [...trimmed].every((c) => c === char);
}

/** Masks inline code spans with underscores of equal length so regexes skip code literals without shifting indices. */
function maskInlineCode(line: string): string {
  return line.replace(CODE_SPAN_RE, (m) => "_".repeat(m.length));
}

/** Strips Obsidian `^block-id` suffixes outside fenced code blocks and inline code spans. */
export function stripObsidianBlockIds(md: string): string {
  const lines = md.replace(/\r\n?/g, "\n").split("\n");
  let fence = "";
  return lines
    .map((line) => {
      if (!fence) {
        const open = FENCE_OPEN_RE.exec(line);
        if (open) {
          fence = open[1];
          return line;
        }
      } else {
        if (fenceCloseMatch(line, fence)) fence = "";
        return line;
      }
      const masked = maskInlineCode(line);
      const m = /\s+\^[A-Za-z0-9-]+\s*$/.exec(masked);
      return m ? line.slice(0, m.index) : line;
    })
    .join("\n");
}

export type PrintEmbedLike = {
  ref: string;
  kind: string;
  title?: string;
  markdown?: string;
  url?: string;
  content_type?: string;
  available: boolean;
};

export type CalloutTone = "note" | "tip" | "warning" | "danger" | "quote";

export function calloutTone(type: string): CalloutTone {
  switch (type.trim().toLowerCase()) {
    case "tip":
    case "hint":
    case "important":
    case "success":
    case "check":
    case "done":
      return "tip";
    case "warning":
    case "caution":
    case "attention":
    case "question":
    case "help":
    case "faq":
      return "warning";
    case "danger":
    case "error":
    case "fail":
    case "failure":
    case "missing":
    case "bug":
      return "danger";
    case "quote":
    case "cite":
      return "quote";
    default:
      return "note";
  }
}

export type PrintSegment =
  | { kind: "markdown"; content: string }
  | { kind: "callout"; calloutType: string; tone: CalloutTone; title: string; body: string }
  | { kind: "embed"; raw: string; fallbackLabel: string; embed?: PrintEmbedLike };

/** Human-readable fallback label for an `![[...]]` embed when no server title is present. */
export function embedFallbackLabel(raw: string): string {
  const parsed = parseWikiLinks(raw)[0];
  if (!parsed) return raw.replace(/^!\[\[/, "").replace(/\]\]$/, "").trim();
  if (parsed.display) return parsed.display;
  let target = parsed.target;
  if (target.startsWith("attachment:")) {
    const rest = target.slice("attachment:".length);
    const slash = rest.indexOf("/");
    target = slash >= 0 ? rest.slice(slash + 1) : rest;
    if (slash < 0 && !target) return "Attachment";
  } else if (target.startsWith("library:")) {
    target = target.slice("library:".length) || "Library item";
  } else if (target.startsWith("design:")) {
    target = target.slice("design:".length) || "Design";
  }
  const base = target.split("/").pop() || target;
  if (!base) return parsed.anchor || "Attachment";
  return parsed.anchor ? `${base} › ${parsed.anchor}` : base;
}

function findEmbed(raw: string, embeds: readonly PrintEmbedLike[]): PrintEmbedLike | undefined {
  const exact = embeds.find((e) => e.ref === raw);
  if (exact) return exact;
  const parsed = parseWikiLinks(raw)[0];
  if (!parsed) return undefined;
  return embeds.find((e) => parseWikiLinks(e.ref)[0]?.ref === parsed.ref);
}

function rewriteInlineEmbeds(line: string, embeds: readonly PrintEmbedLike[]): string {
  const masked = maskInlineCode(line);
  let out = "";
  let last = 0;
  for (const m of masked.matchAll(INLINE_EMBED_RE)) {
    const idx = m.index ?? 0;
    const raw = line.slice(idx, idx + m[0].length);
    const embed = findEmbed(raw, embeds);
    const fallback = embedFallbackLabel(raw);
    let replacement: string;
    if (embed?.available && embed.url && (embed.kind === "image" || embed.content_type?.startsWith("image/"))) {
      const alt = (embed.title || fallback).replace(/[[\]]/g, "");
      const safeUrl = embed.url.replace(/ /g, "%20").replace(/\(/g, "%28").replace(/\)/g, "%29");
      replacement = `![${alt}](${safeUrl})`;
    } else {
      replacement = embed?.title || fallback;
    }
    out += line.slice(last, idx) + replacement;
    last = idx + m[0].length;
  }
  return last ? out + line.slice(last) : line;
}

/**
 * Splits a Knowledge page's Markdown into clean print segments:
 * - removes duplicate leading `# Title` and Obsidian `^block-id` suffixes
 * - turns Obsidian `> [!type]` callouts into structured callout segments
 * - turns standalone `![[...]]` embeds into embed segments and cleans inline embeds outside code
 */
export function prepareKnowledgePrint(
  body: string,
  title: string,
  embeds: readonly PrintEmbedLike[] = [],
  opts?: { stripTitle?: boolean },
): PrintSegment[] {
  const withoutTitle = opts?.stripTitle === false ? body : stripDuplicateLeadingHeading(body, title);
  const cleaned = stripObsidianBlockIds(withoutTitle);
  const lines = cleaned.replace(/\r\n?/g, "\n").split("\n");

  const segments: PrintSegment[] = [];
  let mdBuffer: string[] = [];
  let fence = "";

  const flushMarkdown = () => {
    const content = mdBuffer.join("\n").trim();
    if (content) segments.push({ kind: "markdown", content });
    mdBuffer = [];
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (fence) {
      mdBuffer.push(line);
      if (fenceCloseMatch(line, fence)) fence = "";
      continue;
    }
    const open = FENCE_OPEN_RE.exec(line);
    if (open) {
      fence = open[1];
      mdBuffer.push(line);
      continue;
    }

    const callout = CALLOUT_OPEN_RE.exec(line);
    if (callout) {
      flushMarkdown();
      const rawType = callout[1];
      const explicitTitle = callout[3]?.trim();
      const calloutTitle = explicitTitle || rawType.charAt(0).toUpperCase() + rawType.slice(1).toLowerCase();
      const bodyLines: string[] = [];
      let calloutFence = "";
      while (i + 1 < lines.length && /^ {0,3}>/.test(lines[i + 1])) {
        i++;
        const inner = lines[i].replace(/^ {0,3}>\s?/, "");
        if (calloutFence) {
          bodyLines.push(inner);
          if (fenceCloseMatch(inner, calloutFence)) calloutFence = "";
        } else {
          const innerOpen = FENCE_OPEN_RE.exec(inner);
          if (innerOpen) {
            calloutFence = innerOpen[1];
            bodyLines.push(inner);
          } else {
            bodyLines.push(rewriteInlineEmbeds(inner, embeds));
          }
        }
      }
      segments.push({
        kind: "callout",
        calloutType: rawType.toLowerCase(),
        tone: calloutTone(rawType),
        title: calloutTitle,
        body: bodyLines.join("\n").trim(),
      });
      continue;
    }

    const trimmed = line.trim();
    if (STANDALONE_EMBED_RE.test(trimmed)) {
      flushMarkdown();
      segments.push({
        kind: "embed",
        raw: trimmed,
        fallbackLabel: embedFallbackLabel(trimmed),
        embed: findEmbed(trimmed, embeds),
      });
      continue;
    }

    mdBuffer.push(rewriteInlineEmbeds(line, embeds));
  }

  flushMarkdown();
  return segments;
}
