// Pure logic for the ⌘K command palette (LAZYAGENTS-43). Kept free of React so
// `npm run test:unit` covers it; the component is components/shell/command-menu.tsx.

import { kindHref, type PageKind } from "./knowledge.ts";

/**
 * A searchable type: a chip (or a row under More), an `is:` filter, and the
 * /search kinds it covers. People are personas and agents together.
 */
export type TypeKey =
  | "ticket"
  | "page"
  | "chat"
  | "people"
  | "run"
  | "epic"
  | "memory"
  | "canvas"
  | "course"
  | "space"
  | "workflow"
  | "library"
  | "scheduled"
  | "artifact"
  | "app";

/** /search's kinds (SearchType in the API). */
export type SearchKind =
  | "ticket"
  | "page"
  | "artifact"
  | "chat"
  | "agent"
  | "epic"
  | "run"
  | "workflow"
  | "persona"
  | "memory"
  | "library"
  | "space"
  | "course"
  | "scheduled"
  | "canvas";

export type TypeDef = {
  key: TypeKey;
  /** Chip and group label. */
  label: string;
  /** "+ 28 more tickets". */
  noun: string;
  token: string;
  kinds: SearchKind[];
};

export const TYPES: TypeDef[] = [
  { key: "ticket", label: "Tickets", noun: "tickets", token: "is:ticket", kinds: ["ticket"] },
  { key: "page", label: "Pages", noun: "pages", token: "is:page", kinds: ["page"] },
  { key: "chat", label: "Chats", noun: "chats", token: "is:chat", kinds: ["chat"] },
  { key: "people", label: "People", noun: "people", token: "is:people", kinds: ["persona", "agent"] },
  { key: "run", label: "Runs", noun: "runs", token: "is:run", kinds: ["run"] },
  { key: "epic", label: "Epics", noun: "epics", token: "is:epic", kinds: ["epic"] },
  { key: "memory", label: "Memories", noun: "memories", token: "is:memory", kinds: ["memory"] },
  { key: "canvas", label: "Canvases", noun: "canvases", token: "is:canvas", kinds: ["canvas"] },
  { key: "course", label: "Courses", noun: "courses", token: "is:course", kinds: ["course"] },
  { key: "space", label: "Spaces", noun: "spaces", token: "is:space", kinds: ["space"] },
  { key: "workflow", label: "Workflows", noun: "workflows", token: "is:workflow", kinds: ["workflow"] },
  { key: "library", label: "Library", noun: "Library items", token: "is:library", kinds: ["library"] },
  { key: "scheduled", label: "Scheduled", noun: "scheduled tasks", token: "is:scheduled", kinds: ["scheduled"] },
  { key: "artifact", label: "Artifacts", noun: "artifacts", token: "is:artifact", kinds: ["artifact"] },
  // Matched in the browser from the menu, not by /search.
  { key: "app", label: "Apps", noun: "apps", token: "is:app", kinds: [] },
];

export const TYPE: Record<TypeKey, TypeDef> = Object.fromEntries(TYPES.map((t) => [t.key, t])) as Record<TypeKey, TypeDef>;

/** The chip row, after All; Tab steps through it. The rest are under More. */
export const CHIP_TYPES: TypeKey[] = ["ticket", "page", "chat", "people", "run"];
export const MORE_TYPES: TypeKey[] = TYPES.map((t) => t.key).filter((k) => !CHIP_TYPES.includes(k));

export type PaletteGroup =
  | "Top result"
  | "Needs you"
  | "Running"
  | "Continue"
  | "Recent"
  | "Jump to"
  | "Start a chat"
  | (typeof TYPES)[number]["label"]
  | "Actions"
  | "Switch space"
  | "Go to";

/** A navigable result, as stored in the recent list. */
export type PaletteLink = {
  id: string;
  title: string;
  meta?: string;
  href: string;
  kind: string;
  status?: string;
};

type TargetLike = {
  kind: string;
  id?: string;
  anchor?: string;
  title: string;
  artifact_type?: string;
  path?: string;
  display_id?: string;
  href?: string;
  status?: string;
};

/** A ticket key typed on its own ("lazyagents-39 " → "LAZYAGENTS-39"), or a bare number in `project`. */
export function ticketKeyFrom(query: string, project?: string): string | undefined {
  const text = query.trim();
  if (project && /^\d+$/.test(text)) return `${project}-${text}`;
  const m = text.match(/^([A-Za-z][A-Za-z0-9]*-\d+)$/);
  return m ? m[1].toUpperCase() : undefined;
}

/** `is:` words, the API's names and a few plurals and synonyms included. */
const FILTER_TYPES: Record<string, TypeKey> = {
  ticket: "ticket",
  tickets: "ticket",
  page: "page",
  pages: "page",
  note: "page",
  chat: "chat",
  chats: "chat",
  message: "chat",
  people: "people",
  person: "people",
  persona: "people",
  agent: "people",
  run: "run",
  runs: "run",
  epic: "epic",
  memory: "memory",
  canvas: "canvas",
  course: "course",
  learn: "course",
  space: "space",
  project: "space",
  workflow: "workflow",
  library: "library",
  scheduled: "scheduled",
  schedule: "scheduled",
  artifact: "artifact",
  app: "app",
};

export type PaletteFilters = { text: string; types: TypeKey[]; status?: string; tokens: string[] };

/**
 * Splits `is:ticket status:done deploy` into filters and search text; unknown tokens stay text.
 * A leading `@` asks for people and `#` for tickets, as `is:people` and `is:ticket` do.
 */
export function parseFilters(query: string): PaletteFilters {
  const out: PaletteFilters = { text: "", types: [], tokens: [] };
  const words: string[] = [];
  let rest = query.trim();
  const prefix = rest.match(/^([@#])\s*/);
  if (prefix) {
    out.types.push(prefix[1] === "@" ? "people" : "ticket");
    rest = rest.slice(prefix[0].length);
  }
  for (const word of rest.split(/\s+/).filter(Boolean)) {
    const lower = word.toLowerCase();
    const kind = lower.match(/^(?:is|in):(.+)$/)?.[1];
    const status = lower.match(/^status:(.+)$/)?.[1];
    if (kind && FILTER_TYPES[kind]) {
      if (!out.types.includes(FILTER_TYPES[kind])) out.types.push(FILTER_TYPES[kind]);
      out.tokens.push(word);
    } else if (status) {
      out.status = status;
      out.tokens.push(word);
    } else words.push(word);
  }
  out.text = words.join(" ");
  return out;
}

/** The query with one filter token taken out. */
export function removeToken(query: string, token: string): string {
  return query.trim().split(/\s+/).filter((w) => w !== token).join(" ");
}

/** Cuts a server snippet («match») into plain and marked runs. */
export function snippetParts(snippet: string): { text: string; match: boolean }[] {
  // [[Path|label]] reads as its label (or path); a cut-off "[[" or "]]" is dropped.
  return snippet
    .replace(/\[\[(?:[^\]|]*\|)?([^\]]*)\]\]/g, "$1")
    .replace(/\[\[|\]\]/g, "")
    .split(/(«[^»]*»)/)
    .filter(Boolean)
    .map((s) => (s.startsWith("«") && s.endsWith("»") ? { text: s.slice(1, -1), match: true } : { text: s, match: false }));
}

/** Cuts text around every query word, case-insensitively. */
export function matchParts(text: string, query: string): { text: string; match: boolean }[] {
  const words = query.split(/\s+/).filter(Boolean).map((w) => w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  if (!words.length) return [{ text, match: false }];
  const re = new RegExp(`(${words.join("|")})`, "gi");
  return text.split(re).filter(Boolean).map((s) => ({ text: s, match: words.some((w) => new RegExp(`^${w}$`, "i").test(s)) }));
}

/** The type a search hit belongs to; wiki pages are pages, other artifacts artifacts. */
export function typeOf(t: Pick<TargetLike, "kind" | "artifact_type">): TypeKey {
  switch (t.kind) {
    case "ticket":
    case "chat":
    case "run":
    case "epic":
    case "memory":
    case "canvas":
    case "course":
    case "space":
    case "workflow":
    case "library":
    case "scheduled":
      return t.kind;
    case "agent":
    case "persona":
      return "people";
    default:
      return t.artifact_type === "note" ? "page" : "artifact";
  }
}

/** The /search kind to ask for so a type's chip lists all of it; none when it spans several (People). */
export function searchKind(type: TypeKey | undefined): SearchKind | undefined {
  const kinds = type ? TYPE[type].kinds : [];
  return kinds.length === 1 ? kinds[0] : undefined;
}

/** Matches per type from /search's counts (per kind). */
export function typeCounts(counts: Partial<Record<string, number>> | undefined): Partial<Record<TypeKey, number>> {
  const out: Partial<Record<TypeKey, number>> = {};
  for (const t of TYPES) {
    const n = t.kinds.reduce((sum, k) => sum + (counts?.[k] ?? 0), 0);
    if (n) out[t.key] = n;
  }
  return out;
}

/** A search hit as a palette link; undefined when it has nowhere to go. */
export function linkFromTarget(t: TargetLike): PaletteLink | undefined {
  if (!t.href) return undefined;
  const type = typeOf(t);
  const page = type === "page";
  return {
    id: t.id ?? t.href,
    title: page && t.path ? t.path : t.title,
    meta: page ? "page" : (t.display_id ?? t.artifact_type ?? (t.kind === "agent" || t.kind === "persona" ? "persona" : TYPE[type].label.toLowerCase())),
    href: t.href,
    kind: TYPE[type].label,
    ...(t.status ? { status: t.status } : {}),
  };
}

type Hit = { target: TargetLike; snippet: string; score: number; detail?: string; updated_at?: string };

/** One matching message under its chat. */
export type MessageMatch = { id: string; href: string; snippet: string; author: string; at?: string };

/** A chat found by its title, its messages, or both: one row, its messages under it. */
export type ChatMatch = {
  id: string;
  title: string;
  href: string;
  /** The chat's persona, when the server said. */
  persona?: string;
  at?: string;
  score: number;
  /** Matched by its title, not only by what was said in it. */
  titled: boolean;
  messages: MessageMatch[];
};

/**
 * Folds chat hits into one row per chat: /search returns a title match as the chat and each
 * matching message as the chat with the message as its anchor. Order is the best hit's.
 */
export function groupChats(hits: Hit[]): ChatMatch[] {
  const byId = new Map<string, ChatMatch>();
  for (const h of hits) {
    const t = h.target;
    if (t.kind !== "chat" || !t.id || !t.href) continue;
    let chat = byId.get(t.id);
    if (!chat) {
      chat = { id: t.id, title: t.title || "Untitled chat", href: `/chat/${t.id}`, score: h.score, titled: false, messages: [] };
      byId.set(t.id, chat);
    }
    chat.score = Math.max(chat.score, h.score);
    if (t.anchor) {
      chat.messages.push({ id: t.anchor, href: t.href, snippet: h.snippet, author: h.detail ?? "", at: h.updated_at });
      // A message's author names the persona when it isn't the person.
      if (!chat.persona && h.detail && h.detail !== "You") chat.persona = h.detail;
    } else {
      chat.titled = true;
      chat.href = t.href;
      if (h.detail) chat.persona = h.detail;
      chat.at = h.updated_at ?? chat.at;
    }
    if (!chat.at && h.updated_at) chat.at = h.updated_at;
  }
  return [...byId.values()];
}

/**
 * Orders groups by their best score, keeping each group's own order, and shows at most `cap`
 * of each; `more` is how many matched beyond those (from the server's count when it has one).
 */
export function rankGroups<T extends { score?: number }>(
  groups: { type: TypeKey; items: T[] }[],
  cap: number,
  counts: Partial<Record<TypeKey, number>> = {},
): { type: TypeKey; items: T[]; total: number; more: number }[] {
  const best = (items: T[]) => Math.max(...items.map((i) => i.score ?? 0));
  return groups
    .filter((g) => g.items.length > 0)
    .map((g, i) => ({ g, i, best: best(g.items) }))
    .sort((a, b) => b.best - a.best || a.i - b.i)
    .map(({ g }) => {
      const total = Math.max(counts[g.type] ?? 0, g.items.length);
      const items = g.items.slice(0, cap);
      return { type: g.type, items, total, more: total - items.length };
    });
}

/** The hit with the highest score across groups, or undefined when there's nothing to lift. */
export function bestOf<T extends { score?: number }>(items: T[]): T | undefined {
  let best: T | undefined;
  for (const it of items) if (!best || (it.score ?? 0) > (best.score ?? 0)) best = it;
  return best;
}

/** Facet values in a one-type list (status for tickets, folder for pages, persona for chats), with counts, most common first. */
export function facets(values: (string | undefined)[]): { value: string; count: number }[] {
  const counts = new Map<string, number>();
  for (const v of values) if (v) counts.set(v, (counts.get(v) ?? 0) + 1);
  return [...counts].map(([value, count]) => ({ value, count })).sort((a, b) => b.count - a.count || a.value.localeCompare(b.value));
}

/** Step forward or back through a ring of filter values. */
function stepInOrder<T>(order: readonly T[], current: T, back = false): T {
  const i = Math.max(0, order.indexOf(current));
  return order[(i + (back ? order.length - 1 : 1)) % order.length];
}

/** The chip after (or, with `back`, before) `current`: All, then each chip type, wrapping. */
export function stepChip(current: TypeKey | undefined, back = false): TypeKey | undefined {
  return stepInOrder<TypeKey | undefined>([undefined, ...CHIP_TYPES], current, back);
}

/** Knowledge kind filter chips (All, Documents, Decks, Designs), cycled with Tab in Knowledge mode. */
export const KNOWLEDGE_KINDS: (PageKind | undefined)[] = [undefined, "document", "deck", "design"];

/** The Knowledge kind chip after (or, with `back`, before) `current`, wrapping. */
export function stepKnowledgeKind(current: PageKind | undefined, back = false): PageKind | undefined {
  return stepInOrder(KNOWLEDGE_KINDS, current, back);
}

/** Markdown as one plain line for a preview: code, links, images and markup dropped; cut at `max` characters. */
export function plainExcerpt(md: string, max: number): string {
  const text = md
    .replace(/```[\s\S]*?(```|$)/g, " ")
    .replace(/!\[[^\]]*\]\([^)]*\)|!\[\[[^\]]*\]\]/g, " ")
    .replace(/\[\[([^\]|]*\|)?([^\]]*)\]\]/g, "$2")
    .replace(/\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/^---\n[\s\S]*?\n---\n/, " ")
    .replace(/^\s{0,3}(#{1,6}|>|[-*+]|\d+\.)\s+/gm, "")
    .replace(/[*_`~]+/g, "")
    .replace(/\s+/g, " ")
    .trim();
  return text.length > max ? `${text.slice(0, max - 1).trimEnd()}…` : text;
}

/** Every word of the query appears in the text (case-insensitive); empty matches all. */
export function matchesWords(text: string, query: string): boolean {
  const hay = text.toLowerCase();
  return query
    .toLowerCase()
    .split(/\s+/)
    .filter(Boolean)
    .every((w) => hay.includes(w));
}

const words = (s: string) => s.toLowerCase().split(/\s+/).filter(Boolean);

/**
 * Every query word starts a word of the text ("hea co" finds "Health Coach"). Prefixes, not
 * substrings: one typed letter would otherwise match most names and take the top result.
 */
function startsWords(text: string, query: string): boolean {
  const hay = words(text);
  const want = words(query);
  return want.length > 0 && want.every((w) => hay.some((h) => h.startsWith(w)));
}

/**
 * Personas the typed text names, best first: the whole name, then the name's start, then the
 * start of a word in it. A leading "chat with" or "talk to" is the intent, not part of the name.
 */
export function personaMatches<P extends { name: string }>(personas: P[], query: string): P[] {
  const q = query.trim().toLowerCase().replace(/^(?:chat(?:\s+with)?|talk\s+to)\s+/, "");
  if (!q) return [];
  const rank = (name: string) => {
    const n = name.toLowerCase();
    if (n === q) return 0;
    if (n.startsWith(q)) return 1;
    return startsWords(n, q) ? 2 : -1;
  };
  return personas
    .map((p, i) => ({ p, i, r: rank(p.name) }))
    .filter((x) => x.r >= 0)
    .sort((a, b) => a.r - b.r || a.i - b.i)
    .map((x) => x.p);
}

/**
 * Apps the typed text names, in menu order. "app" or "apps" lists them all; a leading
 * "open" or "go to" is the intent, not part of the name.
 */
export function appMatches<A extends { label: string; aliases?: string }>(apps: A[], query: string): A[] {
  const q = query.trim().replace(/^(?:open|go\s+to)\s+/i, "");
  if (!q) return [];
  return apps.filter((a) => startsWords(`${a.label} ${a.aliases ?? ""} apps`, q));
}

/**
 * The start pages of what used to be apps of their own (LAZYAGENTS-212): their names still find
 * them, in Knowledge. Not in APP_ITEMS, which is also the Apps flyout they've left.
 */
export const KIND_JUMPS: { href: string; label: string; aliases?: string }[] = [
  { href: kindHref("document"), label: "Documents", aliases: "docs" },
  { href: kindHref("deck"), label: "Slides", aliases: "decks" },
  { href: kindHref("design"), label: "Designs" },
];

export const MAX_RECENT = 6;

/** Most recent first, deduped by href, capped. */
export function pushRecent(list: PaletteLink[], item: PaletteLink, max = MAX_RECENT): PaletteLink[] {
  return [item, ...list.filter((r) => r.href !== item.href)].slice(0, max);
}

/** Reads the stored recent list, dropping anything malformed. */
export function parseRecent(raw: string | null): PaletteLink[] {
  if (!raw) return [];
  try {
    const v: unknown = JSON.parse(raw);
    if (!Array.isArray(v)) return [];
    return v
      .filter(
        (r): r is PaletteLink =>
          !!r &&
          typeof r === "object" &&
          typeof (r as PaletteLink).href === "string" &&
          (r as PaletteLink).href.startsWith("/") &&
          typeof (r as PaletteLink).title === "string" &&
          typeof (r as PaletteLink).id === "string",
      )
      .slice(0, MAX_RECENT);
  } catch {
    return [];
  }
}

/** Where ⌘K keeps its Recent list (localStorage). */
export const RECENT_KEY = "la:palette-recent";

type RecentStore = Pick<Storage, "getItem" | "setItem">;

/**
 * Remembers an opened item as recent, as picking it in ⌘K does: back and forward cover the last
 * few steps, Recent the places you have been. Blocked or full storage just skips it.
 */
export function recordRecent(store: RecentStore, item: PaletteLink): void {
  try {
    const next = pushRecent(parseRecent(store.getItem(RECENT_KEY)), item);
    store.setItem(RECENT_KEY, JSON.stringify(next));
  } catch {
    /* Recents are a nicety. */
  }
}

/** localStorage key shared with KnowledgeShell for the Yours / Agent knowledge toggle. */
export const KNOWLEDGE_VIEW_KEY = "vesper.knowledge.view";

/** Page-scoped ⌘⇧K palette target derived from the current URL, or undefined for global fallback. */
export type PageScope =
  | { kind: "knowledge"; label: "Knowledge" }
  | { kind: "type"; type: TypeKey; label: string };

const KNOWLEDGE_PREFIXES = ["/knowledge", "/wiki", "/apps/docs", "/apps/slides", "/apps/designs"] as const;

const TYPE_SCOPE_PREFIXES: readonly [string, TypeKey][] = [
  ["/tickets", "ticket"],
  ["/board", "ticket"],
  ["/epics", "epic"],
  ["/runs", "run"],
  ["/chat", "chat"],
  ["/agents", "people"],
  ["/customization", "people"],
  ["/workflows", "workflow"],
  ["/library", "library"],
  ["/scheduled", "scheduled"],
  ["/learn", "course"],
  ["/spaces", "space"],
  ["/artifacts", "artifact"],
  ["/apps", "app"],
];

const matchesPrefix = (pathname: string, prefix: string) => pathname === prefix || pathname.startsWith(`${prefix}/`);

/** Which item scope ⌘⇧K should open for the current route, if the page has one. */
export function pageScope(pathname: string, search?: string | URLSearchParams): PageScope | undefined {
  const [path, rawQuery] = pathname.split("?");
  if (KNOWLEDGE_PREFIXES.some((p) => matchesPrefix(path, p))) {
    return { kind: "knowledge", label: "Knowledge" };
  }
  const query = new URLSearchParams(search ?? rawQuery);
  if (matchesPrefix(path, "/tickets") && query.get("layout") === "epics") {
    return { kind: "type", type: "epic", label: TYPE.epic.label };
  }
  if (matchesPrefix(path, "/work")) {
    const view = query.get("view");
    const type: TypeKey = view === "tickets" ? "ticket" : view === "epics" ? "epic" : "run";
    return { kind: "type", type, label: TYPE[type].label };
  }
  const hit = TYPE_SCOPE_PREFIXES.find(([p]) => matchesPrefix(path, p));
  return hit ? { kind: "type", type: hit[1], label: TYPE[hit[1]].label } : undefined;
}

/** Splits a Knowledge palette input into plain search text or a leading `#tag` query. */
export function parseKnowledgeQuery(raw: string): { text: string; tag: string } {
  const trimmed = raw.trim();
  if (trimmed.startsWith("#")) return { text: "", tag: trimmed.slice(1).trim() };
  return { text: trimmed, tag: "" };
}

/** Display folder for a Knowledge page path ("Campaign/Sessions/Dawn" → "Campaign / Sessions"). */
export function knowledgeFolder(path: string): string {
  return path.split("/").slice(0, -1).join(" / ") || "Top level";
}

/** What the current page is about, for "New chat with … attached" and "Go to run". */
export type PageContext =
  | { kind: "ticket"; key: string }
  | { kind: "artifact"; id: string }
  | { kind: "knowledge"; id: string }
  | { kind: "wiki"; path: string }
  | undefined;

export function pageContext(pathname: string): PageContext {
  const ticket = pathname.match(/^\/tickets\/([A-Z][A-Z0-9]*-\d+)$/);
  if (ticket) return { kind: "ticket", key: ticket[1] };
  const artifact = pathname.match(/^\/artifacts\/([0-9a-f-]{36})$/i);
  if (artifact) return { kind: "artifact", id: artifact[1] };
  const knowledge = pathname.match(/^\/knowledge\/([0-9a-f-]{36})(?:\/|$)/i);
  if (knowledge) return { kind: "knowledge", id: knowledge[1] };
  const wiki = pathname.match(/^\/wiki\/(.+)$/);
  if (wiki) {
    const path = wiki[1]
      .split("/")
      .map((s) => {
        try {
          return decodeURIComponent(s);
        } catch {
          return s;
        }
      })
      .join("/");
    return { kind: "wiki", path };
  }
  return undefined;
}

/** The project key a ticket key belongs to. */
export function projectOfKey(key: string): string {
  return key.replace(/-\d+$/, "");
}

/** `?` reference (keep in sync with the handlers in app-shell.tsx and ticket-screen.tsx). */
export const SHORTCUTS: { section: string; items: { label: string; keys: string[] }[] }[] = [
  {
    section: "Global",
    items: [
      { label: "Open command palette", keys: ["⌘/Ctrl", "K"] },
      { label: "Open page-scoped command palette", keys: ["⌘/Ctrl", "⇧", "K"] },
      { label: "Toggle left sidebar", keys: ["⌘/Ctrl", "⇧", "\\"] },
      { label: "Show this reference", keys: ["?"] },
    ],
  },
  {
    section: "Work",
    items: [{ label: "New ticket", keys: ["C"] }],
  },
  {
    section: "Chat",
    items: [
      { label: "Next / previous message", keys: ["J", "K"] },
      { label: "Reply to the message (quote it)", keys: ["R"] },
      { label: "Start a thread on the message", keys: ["T"] },
      { label: "Edit your last message", keys: ["E"] },
      { label: "Back to the message box", keys: ["Esc"] },
    ],
  },
  {
    section: "Palette",
    items: [
      { label: "Move / open / close", keys: ["↑", "↓", "↵", "Esc"] },
      { label: "Next / previous type", keys: ["Tab", "⇧Tab"] },
      { label: "Expand / collapse a chat's matching messages", keys: ["→", "←"] },
      { label: "Attach to a chat", keys: ["⌥", "↵"] },
      { label: "People · tickets · commands only", keys: ["@", "#", ">"] },
      { label: "Open in a new tab", keys: ["⌘/Ctrl", "↵"] },
    ],
  },
  {
    section: "Ticket",
    items: [
      { label: "Next / previous ticket", keys: ["J", "K"] },
      { label: "Edit the ticket", keys: ["E"] },
      { label: "Save description / comment", keys: ["⌘/Ctrl", "↵"] },
    ],
  },
  {
    section: "Needs you tray",
    items: [
      { label: "Next / previous item", keys: ["J", "K"] },
      { label: "Open the item’s page", keys: ["↵"] },
      { label: "Switch between Needs you and Updates", keys: ["←", "→"] },
      { label: "Approve the selected approval", keys: ["A"] },
      { label: "Deny the selected approval (with an optional reason)", keys: ["D"] },
      { label: "Reply to the selected question", keys: ["R"] },
      { label: "Close the tray, or leave the reply box", keys: ["Esc"] },
    ],
  },
  {
    section: "Inbox",
    items: [
      { label: "Next / previous item", keys: ["J", "K"] },
      { label: "Open the item’s page", keys: ["↵"] },
      { label: "Approve (approvals, mockups)", keys: ["A"] },
      { label: "Deny (approvals)", keys: ["D"] },
      { label: "Reply (questions) or focus the note", keys: ["R"] },
      { label: "Mark done: hide until it changes", keys: ["E"] },
      { label: "Send the reply or note", keys: ["⌘/Ctrl", "↵"] },
      { label: "Leave the text box, back to the list", keys: ["Esc"] },
    ],
  },
  {
    section: "Knowledge",
    items: [
      { label: "Go to page", keys: ["⌘/Ctrl", "O"] },
      { label: "Quick capture", keys: ["⌘/Ctrl", "⌥", "N"] },
      { label: "Today’s daily note", keys: ["⌘/Ctrl", "D"] },
      { label: "Close active tab", keys: ["⌥", "W"] },
      { label: "Close all tabs", keys: ["⌥", "⇧", "W"] },
    ],
  },
];
