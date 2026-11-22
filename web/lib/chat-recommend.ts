// Recommendation cards in chat: a ```recommend fence holds a URL and a one-line
// reason (components/domain/recommend-fence). Kept free of React so
// `npm run test:unit` covers it.

export const isRecommendFence = (info: string | undefined) => (info ?? "").trim().split(/\s+/)[0]?.toLowerCase() === "recommend";

export type Recommendation = { url: string; note: string };

/** The fence's URL and reason, or null when it doesn't start with a usable link. */
export function parseRecommend(code: string): Recommendation | null {
  const [first, ...rest] = code.trim().split("\n");
  const url = first.trim();
  try {
    const u = new URL(url);
    if (u.protocol !== "https:" && u.protocol !== "http:") return null;
  } catch {
    return null;
  }
  return { url, note: rest.join(" ").replace(/\s+/g, " ").trim() };
}

/** The privacy-mode player, or null for anything but a well-formed id. */
export function videoEmbedUrl(id: string | undefined): string | null {
  return id && /^[A-Za-z0-9_-]{11}$/.test(id) ? `https://www.youtube-nocookie.com/embed/${id}?autoplay=1&rel=0` : null;
}

/**
 * The message a Summarize button sends. A page's title is untrusted and goes in the
 * chat as your words, so it loses anything that would format it or mention a persona.
 */
export function summarizePrompt(url: string, title: string | undefined, video: boolean): string {
  const name = (title ?? "").replace(/[[\]`@\n]/g, "").trim();
  return `Summarize this ${video ? "video" : "page"}: ${name ? `[${name}](${url})` : url}`;
}

const YT_HOSTS = new Set(["youtube.com", "www.youtube.com", "m.youtube.com", "youtu.be", "www.youtu.be"]);

function seconds(t: string): number | null {
  if (/^\d+s?$/.test(t)) return parseInt(t, 10);
  const m = /^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$/.exec(t);
  return m && t ? Number(m[1] ?? 0) * 3600 + Number(m[2] ?? 0) * 60 + Number(m[3] ?? 0) : null;
}

/** A YouTube link to a moment in a video; null for any other link. */
export function youtubeMoment(href: string | undefined): { id: string; seconds: number } | null {
  if (!href) return null;
  try {
    const u = new URL(href);
    if (!YT_HOSTS.has(u.hostname)) return null;
    const id = u.hostname.endsWith("youtu.be") ? u.pathname.slice(1) : (u.searchParams.get("v") ?? "");
    const at = seconds(u.searchParams.get("t") ?? u.searchParams.get("start") ?? "");
    return /^[A-Za-z0-9_-]{11}$/.test(id) && at !== null ? { id, seconds: at } : null;
  } catch {
    return null;
  }
}

const SUMMARY_REQUEST = /Summarize this (?:video|page): (?:\[[^\]]*\]\((https?:[^)\s]+)\)|(https?:\S+))/;

/** The URL a Summarize button's message asked about, or null for any other message. */
export function summaryRequestUrl(body: string | undefined): string | null {
  const m = SUMMARY_REQUEST.exec(body ?? "");
  return m ? (m[1] ?? m[2]) : null;
}

/**
 * Maps each assistant turn reply id to the URL from its preceding user Summarize prompt
 * in a single O(N) pass instead of scanning backwards from every message on every render.
 */
export function summaryUrlsForTurns(
  list: readonly { id: string; role: string; body_md: string }[] | undefined,
  turns: ReadonlyMap<string, unknown>,
): Map<string, string> {
  const out = new Map<string, string>();
  let lastUserBody: string | undefined;
  for (const m of list ?? []) {
    if (m.role === "user") {
      lastUserBody = m.body_md;
    } else if (m.role === "assistant" && turns.has(m.id)) {
      const url = summaryRequestUrl(lastUserBody);
      if (url) out.set(m.id, url);
    }
  }
  return out;
}

type Node = { type: string; tagName?: string; value?: string; properties?: Record<string, unknown>; children?: Node[] };

const isCard = (n: Node) => n.type === "element" && n.tagName === "pre" && n.children?.some((c) => c.tagName === "code" && (c.properties?.className as string[] | undefined)?.includes("language-recommend"));

export const RECOMMEND_ROW = "recommend-row";

/** Rehype plugin: neighbouring recommend fences share a row, side by side. */
export function groupRecommendFences() {
  return (tree: Node) => {
    const out: Node[] = [];
    let run: Node[] = [];
    let gap: Node[] = [];
    const flush = () => {
      if (run.length > 1) out.push({ type: "element", tagName: "div", properties: { className: [RECOMMEND_ROW] }, children: run });
      else out.push(...run);
      out.push(...gap);
      run = [];
      gap = [];
    };
    for (const n of tree.children ?? []) {
      if (isCard(n)) {
        gap = [];
        run.push(n);
      } else if (run.length && n.type === "text" && !n.value?.trim()) {
        gap.push(n);
      } else {
        flush();
        out.push(n);
      }
    }
    flush();
    tree.children = out;
  };
}
