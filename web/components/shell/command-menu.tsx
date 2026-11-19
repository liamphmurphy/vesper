"use client";

import { Dialog, Popover } from "radix-ui";
import { usePathname, useRouter } from "next/navigation";
import { useEffect, useRef, useState, type ReactNode } from "react";
import type { Schemas } from "@/lib/api/client";
import { hasLiveRun, useArtifact, useAskChat, useBootstrap, useChats, useControlRun, useCreateChat, useDecideApproval, useInbox, useLiveRuns, useSearch, useTicket, useUpdateTicket, useWikiPage } from "@/lib/api/hooks";
import { useCreatePage, usePages, usePage, type PageRow } from "@/lib/api/knowledge-hooks";
import { useQueryClient } from "@tanstack/react-query";
import { Icon, type IconName } from "@/components/ui/icon";
import { Kbd } from "@/components/ui/primitives";
import { artifactTitle } from "@/components/domain/artifacts";
import { usePersonas } from "@/lib/api/persona-hooks";
import { useCustomApps } from "@/lib/api/custom-app-hooks";
import { useDevWorkspace } from "@/lib/api/dev-workspace-hooks";
import { resolveAppIcon } from "@/lib/custom-app-bridge";
import { cx } from "@/lib/cx";
import { SIDEBAR_TOGGLE_HINT } from "@/lib/navigator";
import { shortAgo } from "@/lib/format";
import { approvalId, KIND as INBOX_KIND } from "@/lib/inbox";
import { attachQuery, chipFromTarget, type ContextRef } from "@/lib/chat-context";
import { KINDS, pageHref, pageIcon, type PageKind } from "@/lib/knowledge";
import {
  CHIP_TYPES,
  KIND_JUMPS,
  KNOWLEDGE_VIEW_KEY,
  MORE_TYPES,
  RECENT_KEY,
  TYPE,
  TYPES,
  appMatches,
  bestOf,
  facets,
  groupChats,
  knowledgeFolder,
  linkFromTarget,
  matchParts,
  matchesWords,
  pageContext,
  pageScope,
  parseFilters,
  parseKnowledgeQuery,
  parseRecent,
  personaMatches,
  plainExcerpt,
  projectOfKey,
  pushRecent,
  rankGroups,
  removeToken,
  searchKind,
  snippetParts,
  stepChip,
  stepKnowledgeKind,
  ticketKeyFrom,
  typeCounts,
  typeOf,
  type ChatMatch,
  type MessageMatch,
  type PageScope,
  type PaletteLink,
  type TypeKey,
} from "@/lib/command-palette";
import { APP_ITEMS, NAV_GROUPS, projectSection, switchHref, toolItems, withProject } from "@/lib/project-scope";
import { CommandPreview, statusLabel, statusTone, type Preview, type PreviewAction } from "./command-preview";
import { rememberProject, useRememberedProject } from "./project-scope";

const TYPE_ICON: Record<TypeKey, IconName> = {
  ticket: "tickets",
  page: "wiki",
  chat: "msg",
  people: "users",
  run: "play",
  epic: "epics",
  memory: "bookmark",
  canvas: "edit",
  course: "learn",
  space: "folder",
  workflow: "branch",
  library: "library",
  scheduled: "clock",
  artifact: "artifacts",
  app: "dashboard",
};

/** A recent entry's icon, from the group label it was stored under. */
const LABEL_ICON: Record<string, IconName> = {
  ...Object.fromEntries(TYPES.map((t) => [t.label, TYPE_ICON[t.key]])),
  Agents: "users",
  Personas: "users",
};

/** In the All list, each type shows this many before "+ N more". */
/** Search words for tools whose label alone wouldn't find them. */
const TOOL_ALIASES: Record<string, string> = {
  "/http": "bruno api curl rest requests",
  "/dev": "terminal lazyvim nvim tmux",
};

const PER_GROUP = 3;

type Row = {
  id: string;
  title: string;
  /** The second line. */
  sub?: ReactNode;
  /** Right-hand: a time or a status. */
  meta?: string;
  /** Right-hand: a one-key shortcut, drawn as a key. */
  shortcut?: string;
  metaClass?: string;
  icon: IconName;
  tone?: "human" | "run";
  /** Navigates (and is remembered as recent when `recent` is set). */
  href?: string;
  recent?: PaletteLink;
  perform?: () => void;
  score?: number;
  /** Takes the query as its input, so it stays offered whatever was typed. */
  fallback?: boolean;
  /** Only offered once asked for: too specific, or too consequential, for the opening list. */
  onDemand?: boolean;
  /** Matched here rather than by the server, so ↵ may take it while a search is still on its way. */
  local?: boolean;
  /** Whether to mark the query's words in the title. */
  mark?: boolean;
  type?: TypeKey;
  preview?: Preview;
  /** ⌥↵: a new chat with this attached. */
  attach?: { ref: ContextRef; label: string };
  chat?: ChatMatch;
  message?: MessageMatch;
  /** The "+ N more" row: ↵ opens that type. */
  moreOf?: TypeKey;
  facet?: string;
};

type Section = { key: string; label?: string; count?: number; tone?: "human"; rows: Row[] };

const STATUSES = [
  ["backlog", "Backlog"],
  ["todo", "Todo"],
  ["in_progress", "In progress"],
  ["in_review", "In review"],
  ["done", "Done"],
] as const;

const MARK = "font-bold text-accent";

function Parts({ parts, className = MARK }: { parts: { text: string; match: boolean }[]; className?: string }) {
  return (
    <>
      {parts.map((p, i) =>
        p.match ? (
          <span key={i} className={className}>
            {p.text}
          </span>
        ) : (
          <span key={i}>{p.text}</span>
        ),
      )}
    </>
  );
}

/** Waits for typing to pause before searching (the server ranks; nothing is filtered client-side). */
function useDebounced(value: string, ms: number) {
  const [v, setV] = useState(value);
  useEffect(() => {
    const t = setTimeout(() => setV(value), ms);
    return () => clearTimeout(t);
  }, [value, ms]);
  return v;
}

type Hit = Schemas["SearchHit"];

/** A /search hit as a row of its type (chats are folded first, by groupChats). */
function hitRow(h: Hit, type: TypeKey): Row | undefined {
  const t = h.target;
  const link = linkFromTarget(t);
  if (!link) return undefined;
  const at = h.updated_at ? shortAgo(h.updated_at) : undefined;
  const base: Row = { id: `${type}-${link.id}`, title: t.title, href: link.href, recent: link, icon: TYPE_ICON[type], score: h.score, mark: true, type, meta: at };
  const chip = chipFromTarget(t);
  const attach = chip ? { ref: chip.ref, label: chip.label } : undefined;
  switch (type) {
    case "ticket":
      return {
        ...base,
        sub: [t.display_id, h.detail ?? "unassigned"].join(" · "),
        meta: t.status ? statusLabel(t.status) : undefined,
        metaClass: statusTone(t.status),
        preview: { kind: "ticket", key: t.display_id ?? "", title: t.title },
        attach,
        facet: t.status,
      };
    case "page": {
      const folder = h.detail ?? "";
      // A page found by its words rather than its name shows where they are.
      const sub: ReactNode = foundInBody(h.snippet, t.title) ? (
        <>
          {folder ? `${folder} · ` : ""}“…<Parts parts={snippetParts(h.snippet)} className="font-bold text-fg-secondary" />…”
        </>
      ) : (
        [folder, "page"].filter(Boolean).join(" · ")
      );
      return { ...base, sub, preview: { kind: "page", id: t.id ?? "", path: t.path ?? "", title: t.title }, attach, facet: folder || undefined };
    }
    case "canvas":
      return { ...base, sub: [h.detail, "canvas"].filter(Boolean).join(" · "), attach: t.id ? { ref: { kind: "canvas", id: t.id }, label: t.title } : undefined, preview: item(type, h) };
    case "people":
      return { ...base, sub: t.kind === "agent" ? [h.detail, "agent"].filter(Boolean).join(" · ") : "persona", preview: item(type, h) };
    case "run":
      return { ...base, sub: h.detail, meta: t.status?.replaceAll("_", " "), metaClass: t.status === "failed" ? "text-state-blocked" : undefined, preview: item(type, h), facet: t.status };
    case "course":
      return { ...base, sub: [t.status, "course"].filter(Boolean).join(" · "), preview: item(type, h) };
    default:
      return { ...base, sub: [h.detail, type === "artifact" ? t.artifact_type : t.kind].filter(Boolean).join(" · ") || undefined, attach: type === "artifact" ? attach : undefined, preview: item(type, h) };
  }
}

/** A page hit whose marked snippet words aren't in its title was found by its body. */
function foundInBody(snippet: string, title: string): boolean {
  const marked = [...snippet.matchAll(/«([^»]*)»/g)].map((m) => m[1].toLowerCase());
  return marked.length > 0 && !marked.some((w) => title.toLowerCase().includes(w));
}

function item(type: TypeKey, h: Hit): Preview {
  const label = h.target.kind === "agent" ? "Agent" : h.target.kind === "persona" ? "Persona" : TYPE[type].label.replace(/s$/, "");
  return { kind: "item", label, title: h.target.title, detail: h.detail ?? h.target.status?.replaceAll("_", " "), at: h.updated_at };
}

function chatRow(c: ChatMatch, expanded: boolean): Row {
  const n = c.messages.length;
  const matched = n ? `${n} ${n === 1 ? "message matches" : "messages match"}` : "chat";
  return {
    id: `chat-${c.id}`,
    title: c.title,
    sub: (
      <>
        {[c.persona, matched].filter(Boolean).join(" · ")}
        {n > 0 && <span aria-hidden className="ml-1.5 max-md:hidden">{expanded ? "↓" : "→"}</span>}
      </>
    ),
    meta: c.at ? shortAgo(c.at) : undefined,
    href: c.href,
    recent: { id: c.id, title: c.title, meta: "chat", href: c.href, kind: "Chats" },
    icon: "msg",
    score: c.score,
    mark: c.titled,
    type: "chat",
    chat: c,
    preview: { kind: "chat", chat: c },
    facet: c.persona,
  };
}

function messageRows(c: ChatMatch): Row[] {
  return c.messages.map((m) => ({
    id: `message-${m.id}`,
    title: [m.author || "Message", m.at && new Date(m.at).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" })].filter(Boolean).join(" · "),
    sub: (
      <>
        …<Parts parts={snippetParts(m.snippet)} className="font-bold text-fg-secondary" />…
      </>
    ),
    href: m.href,
    icon: "msg",
    type: "chat" as const,
    chat: c,
    message: m,
    preview: { kind: "message" as const, chat: c, message: m },
  }));
}

export type OpenPaletteDetail = {
  scope?: PageScope | "all" | "page";
  includeAgent?: boolean;
  /** Text to start with, e.g. what was typed into the Mac app's toolbar search field. */
  query?: string;
};

/** Opens the command palette globally or scoped to the current page / Knowledge. */
export function openCommandPalette(detail?: OpenPaletteDetail) {
  window.dispatchEvent(new CustomEvent<OpenPaletteDetail>("la:search", { detail }));
}

function knowledgePageRow(r: PageRow): Row {
  const href = pageHref(r.id, r.title);
  const title = r.title || "Untitled";
  const folder = knowledgeFolder(r.path);
  const kindLabel = r.kind === "deck" ? "Deck" : r.kind === "design" ? "Design" : undefined;
  const audLabel = r.audience === "agent" ? "Agent" : r.audience === "shared" ? "Shared" : undefined;
  const summary = r.summary ? plainExcerpt(r.summary, 60) : undefined;
  return {
    id: `kpage-${r.id}`,
    title,
    sub: [folder, kindLabel, audLabel, summary].filter(Boolean).join(" · "),
    meta: shortAgo(r.updated_at),
    icon: pageIcon(r),
    href,
    recent: { id: r.id, title: r.path || title, meta: r.kind ?? "page", href, kind: "Pages" },
    mark: true,
    type: "page",
    attach: { ref: { kind: "page", id: r.id }, label: title },
    preview: { kind: "page", id: r.id, path: r.path, title, source: "knowledge", row: r },
    facet: folder,
  };
}

export function CommandMenu() {
  const router = useRouter();
  const qc = useQueryClient();
  const pathname = usePathname();
  const boot = useBootstrap();
  const createChat = useCreateChat();
  const askChat = useAskChat();
  const createPage = useCreatePage();
  const remembered = useRememberedProject();
  const personas = usePersonas();
  const [open, setOpen] = useState(false);
  const customApps = useCustomApps(open);
  const devWorkspace = useDevWorkspace();
  const [query, setQuery] = useState("");
  const [project, setProject] = useState<string>();
  const [scope, setScope] = useState(false);
  const [paletteScope, setPaletteScope] = useState<PageScope>();
  const [knowledgeKind, setKnowledgeKind] = useState<PageKind>();
  const [includeAgent, setIncludeAgent] = useState(false);
  const [mode, setMode] = useState<"root" | "projects">("root");
  const [active, setActive] = useState(0);
  const [recent, setRecent] = useState<PaletteLink[]>([]);
  const [actionFailed, setActionFailed] = useState(false);
  // The type picked from the chip row (or More); a typed is: token wins over it.
  const [chip, setChip] = useState<TypeKey>();
  const [facet, setFacet] = useState<string>();
  const [expanded, setExpanded] = useState<string>();
  const [moreOpen, setMoreOpen] = useState(false);
  const [moreActive, setMoreActive] = useState(0);
  const returnFocus = useRef<HTMLElement | null>(null);
  const openRef = useRef(open);
  const rememberedRef = useRef(remembered);
  const inputRef = useRef<HTMLInputElement>(null);

  const knowledgeMode = paletteScope?.kind === "knowledge";
  const typeScoped = paletteScope?.kind === "type";
  const commands = !knowledgeMode && !typeScoped && query.startsWith(">");
  const filters = parseFilters(commands || knowledgeMode ? "" : query);
  const title = commands ? query.replace(/^>\s*/, "").trim() : filters.text;
  const typed = typeScoped ? [] : filters.types;
  // The types on show: locked to paletteScope when page-scoped, else typed is: tokens, else the chip.
  const shownTypes: TypeKey[] | undefined = typeScoped ? [paletteScope.type] : typed.length ? typed : chip ? [chip] : undefined;
  const oneType = shownTypes?.length === 1 ? shownTypes[0] : undefined;
  const root = mode === "root" && !commands;
  const searchText = !knowledgeMode && root ? filters.text : "";
  const text = useDebounced(searchText, 150);
  const scoped = scope ? project : undefined;
  const all = useSearch(open && !knowledgeMode ? text : "", scoped);
  const kind = searchKind(oneType);
  const one = useSearch(open && !knowledgeMode ? text : "", scoped, kind, !!kind);
  const shown = kind ? one : all;

  // Knowledge-only query via POST /knowledge/query (covers immediate recents, #tags, kinds & agent view).
  const kQuery = parseKnowledgeQuery(knowledgeMode ? query : "");
  const kDebouncedText = useDebounced(kQuery.text, 150);
  const kDebouncedTag = useDebounced(kQuery.tag, 150);
  const pagesQuery = usePages(
    {
      text: kDebouncedText || undefined,
      tag: kDebouncedTag || undefined,
      kind: knowledgeKind,
      include_agent: includeAgent,
      limit: 25,
    },
    open && knowledgeMode,
  );

  // Until the answer for exactly this text arrives, the rows on screen are stale.
  const pending = knowledgeMode
    ? kQuery.text !== kDebouncedText || kQuery.tag !== kDebouncedTag || pagesQuery.isLoading || pagesQuery.isPlaceholderData
    : !!searchText && (text !== searchText || shown.isLoading || shown.isPlaceholderData);

  // What the page is about (only fetched while open; the page usually has it cached).
  const ctx = pageContext(pathname);
  const ticket = useTicket(open && !knowledgeMode && ctx?.kind === "ticket" ? ctx.key : "");
  const artifact = useArtifact(open && !knowledgeMode && ctx?.kind === "artifact" ? ctx.id : undefined);
  const wiki = useWikiPage(open && !knowledgeMode && ctx?.kind === "wiki" ? ctx.path : "");
  const currentKnowledgePage = usePage(open && !knowledgeMode && ctx?.kind === "knowledge" ? ctx.id : undefined);
  const ticketKey = ctx?.kind === "ticket" ? ctx.key : "";
  const updateTicket = useUpdateTicket(ticketKey);
  const controlRun = useControlRun(ticketKey);
  const decideApproval = useDecideApproval(ticketKey);
  let attachHere: { ref: ContextRef; label: string; project?: string } | undefined;
  if (ctx?.kind === "ticket") attachHere = { ref: { kind: "ticket", key: ctx.key }, label: ctx.key, project: projectOfKey(ctx.key) };
  const doc = ctx?.kind === "artifact" ? artifact.data : ctx?.kind === "wiki" ? wiki.data : undefined;
  if (doc) attachHere = { ref: { kind: doc.type === "note" ? "page" : "artifact", id: doc.id }, label: artifactTitle(doc), project: doc.project?.key };
  else if (ctx?.kind === "knowledge" && currentKnowledgePage.data) {
    attachHere = { ref: { kind: "page", id: currentKnowledgePage.data.id }, label: currentKnowledgePage.data.title || "Untitled" };
  }

  const projects = (boot.data?.projects ?? []).filter((p) => !p.archived);
  // Where actions happen: the page's project, then the URL's, then the remembered one.
  const actionProject = attachHere?.project ?? project ?? remembered ?? projects[0]?.key;

  // The opening list: global idle fetches inbox + runs + chats; page-scoped fetches only what that type needs.
  const idleGlobal = open && !paletteScope && mode === "root" && !query.trim();
  const inbox = useInbox(undefined, idleGlobal);
  const liveRuns = useLiveRuns(idleGlobal || (open && typeScoped && oneType === "run" && !searchText));
  const chats = useChats(false, "", idleGlobal || (open && typeScoped && oneType === "chat" && !searchText), "all");

  const close = (next: boolean) => {
    // A failed action's alert belongs to that attempt only.
    if (!next) {
      createChat.reset();
      askChat.reset();
      createPage.reset();
      setActionFailed(false);
    }
    setOpen(next);
  };

  const failed = () => {
    setActionFailed(true);
    setOpen(true);
  };

  const remember = (link: PaletteLink) => {
    const next = pushRecent(recent, link);
    setRecent(next);
    try {
      window.localStorage.setItem(RECENT_KEY, JSON.stringify(next));
    } catch {
      /* storage full or disabled: recents are a nicety */
    }
  };

  /** Shows one type (undefined: All), dropping typed is: tokens so the chip is what filters. */
  const pickType = (next: TypeKey | undefined) => {
    let q = query;
    for (const token of filters.tokens) if (/^(is|in):/i.test(token)) q = removeToken(q, token);
    // @ and # are typed types too.
    q = q.replace(/^\s*[@#]\s*/, "");
    setQuery(q);
    setChip(next);
    setFacet(undefined);
    setExpanded(undefined);
    setMoreOpen(false);
    setActive(0);
    inputRef.current?.focus();
  };

  const go = (row: Row, newTab = false) => {
    if (row.moreOf) {
      pickType(row.moreOf);
      return;
    }
    if (newTab && row.href) {
      window.open(row.href, "_blank", "noopener");
      return;
    }
    if (row.href) returnFocus.current = null;
    close(false);
    if (row.recent) remember(row.recent);
    if (row.perform) row.perform();
    else if (row.href) {
      router.push(row.href);
      if (row.href.startsWith("/knowledge/")) {
        window.dispatchEvent(new CustomEvent("la:knowledge-reveal", { detail: { href: row.href } }));
      }
    }
  };

  /** ⌥↵: a new chat with the row attached, as "New chat with … attached" does for the page you're on. */
  const attachToChat = (row: Row) => {
    const a = row.attach;
    if (!a) return;
    close(false);
    if (row.recent) remember(row.recent);
    createChat.mutate({}, { onSuccess: (c) => router.push(`/chat/${c.id}?${attachQuery(undefined, a.ref, a.label)}`), onError: () => setOpen(true) });
  };

  const switchTo = (key: string) => {
    rememberProject(key);
    const href = switchHref(window.location.pathname, new URLSearchParams(window.location.search), key);
    if (href) router.push(href);
  };

  const projectRows: Row[] = projects
    .map((p) => ({
      id: `project-${p.key}`,
      title: `${p.key} · ${p.name}`,
      meta: p.key === actionProject ? "current" : undefined,
      icon: "folder" as const,
      perform: () => switchTo(p.key),
    }))
    .filter((i) => matchesWords(i.title, mode === "projects" ? query : title.replace(/^(switch|project|space)\b\s*/i, "")));

  const key = root && !knowledgeMode && (!typeScoped || oneType === "ticket") ? ticketKeyFrom(query.replace(/^#\s*/, ""), actionProject) : undefined;
  const jump: Row[] = key
    ? [{ id: `jump-${key}`, title: `Open ${key}`, sub: `/tickets/${key}`, icon: "tickets", href: `/tickets/${key}`, local: true,
        recent: { id: `jump-${key}`, title: key, meta: key, href: `/tickets/${key}`, kind: "Tickets" },
        preview: { kind: "ticket", key, title: key }, attach: { ref: { kind: "ticket", key }, label: key } }]
    : [];

  // Typing a persona's name offers a new chat with them first; an app's name, the app.
  // Matched here, from lists the shell already has, so they don't wait on the search.
  const offers = (type: TypeKey) => root && !knowledgeMode && (!shownTypes || shownTypes.includes(type));
  const chatWith: Row[] = offers("people")
    ? personaMatches(personas.data?.personas ?? [], filters.text).map((p) => ({
        id: `chat-with-${p.id}`,
        title: `Chat with ${p.name}`,
        sub: "new chat",
        icon: "msg" as const,
        href: `/chat?new&persona=${encodeURIComponent(p.id)}`,
        local: true,
        mark: true,
      }))
    : [];
  const myApps = (customApps.data?.apps ?? []).map((a) => ({
    href: `/apps/${a.slug}`,
    label: a.name,
    aliases: a.slug === a.name.toLowerCase() ? undefined : a.slug,
    icon: resolveAppIcon(a.icon) as IconName,
    kind: "custom app",
  }));
  const appsMenu = [
    ...APP_ITEMS.map((i) => ({ ...i, kind: "app" })),
    ...myApps,
    ...KIND_JUMPS.map((i) => ({ ...i, kind: "in Knowledge" })),
    ...toolItems(!!devWorkspace.data?.enabled).map((i) => ({ ...i, aliases: TOOL_ALIASES[i.href], kind: "tool" })),
  ];
  // is:app on its own lists every app.
  const appsWanted = filters.text ? appMatches(appsMenu, filters.text) : oneType === "app" ? appsMenu : [];
  const apps: Row[] = offers("app")
    ? appsWanted.map((a) => ({
        id: `app-${a.href}`,
        title: a.label,
        sub: a.kind,
        icon: a.kind === "custom app" && "icon" in a ? a.icon : TYPE_ICON.app,
        href: withProject(a.href, remembered),
        recent: { id: `app-${a.href}`, title: a.label, meta: a.kind, href: withProject(a.href, remembered), kind: "Apps" },
        local: true,
        mark: true,
        type: "app" as const,
      }))
    : [];

  // Server hits by type; chats folded so a chat's matching messages sit under it.
  const hits = searchText ? (shown.data?.hits ?? []) : [];
  const byType = new Map<TypeKey, Row[]>();
  const add = (type: TypeKey, row: Row) => byType.set(type, [...(byType.get(type) ?? []), row]);
  for (const c of groupChats(hits)) add("chat", chatRow(c, expanded === c.id));
  for (const h of hits) {
    const type = typeOf(h.target);
    if (type === "chat" || (shownTypes && !shownTypes.includes(type))) continue;
    if (filters.status && type === "ticket" && h.target.status !== filters.status) continue;
    const row = hitRow(h, type);
    if (row) add(type, row);
  }
  if (apps.length) byType.set("app", apps);

  const counts = typeCounts(all.data?.counts);
  if (apps.length) counts.app = apps.length;
  const total = Object.values(counts).reduce((a, b) => a + (b ?? 0), 0);

  const withMessages = (rows: Row[]) => rows.flatMap((r) => (r.chat && !r.message && expanded === r.chat.id ? [r, ...messageRows(r.chat)] : [r]));

  // The result sections: one type in full (with its facets), or every type capped and ranked.
  let resultSections: Section[] = [];
  let facetValues: { value: string; count: number }[] = [];
  let oneTotal = 0;
  let oneShown = 0;
  if (searchText && oneType) {
    const rows = byType.get(oneType) ?? [];
    facetValues = oneType === "ticket" || oneType === "page" || oneType === "chat" || oneType === "run" ? facets(rows.map((r) => r.facet)) : [];
    const kept = facet ? rows.filter((r) => r.facet === facet) : rows;
    oneShown = kept.length;
    oneTotal = facet ? kept.length : Math.max(counts[oneType] ?? 0, rows.length);
    resultSections = [{ key: oneType, rows: withMessages(kept) }];
  } else if (searchText) {
    const groups = rankGroups(
      [...byType].filter(([type]) => !shownTypes || shownTypes.includes(type)).map(([type, items]) => ({ type, items })),
      shownTypes ? Number.POSITIVE_INFINITY : PER_GROUP + 1,
      counts,
    );
    // The best local match leads; otherwise the server's best hit, lifted out of its group.
    const local = [...chatWith, ...apps];
    const top = local[0] ?? bestOf(groups.flatMap((g) => g.items));
    resultSections = [
      ...(top ? [{ key: "top", label: "Top result", rows: withMessages([top]) }] : []),
      ...groups.flatMap((g): Section[] => {
        const rest = g.items.filter((r) => r !== top).slice(0, shownTypes ? undefined : PER_GROUP);
        if (!rest.length) return [];
        const more = g.total - rest.length - (g.items.includes(top!) ? 1 : 0);
        const moreRow: Row[] =
          more > 0 && !shownTypes
            ? [{ id: `more-${g.type}`, title: `+ ${more} more ${TYPE[g.type].noun}`, icon: TYPE_ICON[g.type], moreOf: g.type, meta: CHIP_TYPES.includes(g.type) ? `Tab to ${TYPE[g.type].label}` : `${TYPE[g.type].token}` }]
            : [];
        return [{ key: g.type, label: TYPE[g.type].label, count: g.total, rows: [...withMessages(rest), ...moreRow] }];
      }),
    ];
    // Persona offers beyond the first.
    if (chatWith.length > 1 && top === chatWith[0]) resultSections.splice(1, 0, { key: "start", label: "Start a chat", rows: chatWith.slice(1) });
  }

  const recentRows: Row[] = idleGlobal
    ? recent.map((r) => ({ id: `recent-${r.href}`, title: r.title, sub: r.meta, icon: LABEL_ICON[r.kind] ?? "history", href: r.href, recent: r }))
    : [];
  const inboxItems = idleGlobal ? (inbox.data ?? []).filter((i) => !i.resolved && i.needs_you) : [];
  const needsYou: Row[] = inboxItems.slice(0, 3).map((i) => ({
    id: `inbox-${i.id}`,
    title: i.title,
    sub: [i.agent?.name ?? i.ticket_key ?? i.project, (INBOX_KIND[i.kind]?.label ?? i.kind).toLowerCase()].filter(Boolean).join(" · "),
    meta: shortAgo(i.created_at),
    icon: "alert" as const,
    tone: "human" as const,
    href: i.href,
    preview: { kind: "inbox" as const, item: i },
  }));
  const running: Row[] = idleGlobal
    ? (liveRuns.data?.runs ?? []).slice(0, 3).map((r) => ({
        id: `live-${r.id}`,
        title: [r.ticket_key, r.work_title].filter(Boolean).join(" ") || r.agent.name,
        sub: [r.agent.name, r.state.replaceAll("_", " ")].join(" · "),
        icon: "play" as const,
        tone: "run" as const,
        href: `/runs/${r.id}`,
        preview: { kind: "item" as const, label: r.ticket_key ? `Run · ${r.ticket_key}` : "Run", title: r.work_title ?? r.ticket_key ?? r.agent.name, detail: `${r.agent.name} · ${r.state.replaceAll("_", " ")}` },
      }))
    : [];
  const lastChat = idleGlobal ? chats.data?.chats[0] : undefined;
  const resume: Row[] = lastChat
    ? [{
        id: `continue-${lastChat.id}`,
        title: lastChat.title || "Untitled chat",
        sub: [lastChat.persona?.name, "chat"].filter(Boolean).join(" · "),
        meta: shortAgo(lastChat.last_message_at ?? lastChat.updated_at),
        icon: "msg",
        href: `/chat/${lastChat.id}`,
        preview: { kind: "chat", chat: { id: lastChat.id, title: lastChat.title || "Untitled chat", href: `/chat/${lastChat.id}`, persona: lastChat.persona?.name, at: lastChat.last_message_at ?? lastChat.updated_at, score: 0, titled: true, messages: [] } },
      }]
    : [];

  // Knowledge-only rows, facets and create-page fallback.
  const kRawRows = knowledgeMode ? (pagesQuery.data?.rows ?? []) : [];
  const kMappedRows = kRawRows.map(knowledgePageRow);
  const kFacetValues = knowledgeMode ? facets(kMappedRows.map((r) => r.facet)) : [];
  const kVisibleRows = knowledgeMode && facet ? kMappedRows.filter((r) => r.facet === facet) : kMappedRows;
  const kCanCreate = knowledgeMode && !!kQuery.text && !kQuery.tag && !kRawRows.some((r) => r.title.toLowerCase() === kQuery.text.toLowerCase());
  const createKnowledgePage = () => {
    if (!kQuery.text || createPage.isPending) return;
    close(false);
    createPage.mutate(
      { title: kQuery.text, path: `Inbox/${kQuery.text.replace(/[[\]#|^/\\]/g, " ").trim()}`, body_md: "" },
      {
        onSuccess: (p) => router.push(pageHref(p.id, p.title)),
        onError: failed,
      },
    );
  };
  const knowledgeSections: Section[] = knowledgeMode
    ? [
        ...(kVisibleRows.length > 0
          ? [{ key: "knowledge", label: kQuery.text || kQuery.tag ? "Pages" : "Recent pages", count: kVisibleRows.length, rows: kVisibleRows }]
          : []),
        ...(kCanCreate
          ? [{
              key: "knowledge-create",
              rows: [{
                id: "knowledge-create",
                title: `Create “${kQuery.text}”`,
                sub: "in Inbox",
                icon: "plus" as const,
                shortcut: "⇧↵",
                local: true,
                perform: createKnowledgePage,
              }],
            }]
          : []),
      ]
    : [];

  // Type-scoped opening rows when the search box is empty (shows relevant items immediately).
  const scopedIdleRows: Row[] = (() => {
    if (!typeScoped || !oneType || searchText) return [];
    if (oneType === "app") return apps;
    if (oneType === "people") {
      return (personas.data?.personas ?? []).slice(0, 15).map((p) => ({
        id: `chat-with-${p.id}`,
        title: `Chat with ${p.name}`,
        sub: "new chat",
        icon: "msg" as const,
        href: `/chat?new&persona=${encodeURIComponent(p.id)}`,
        local: true,
      }));
    }
    if (oneType === "chat") {
      return (chats.data?.chats ?? []).slice(0, 10).map((c) => ({
        id: `chat-${c.id}`,
        title: c.title || "Untitled chat",
        sub: [c.persona?.name, "chat"].filter(Boolean).join(" · "),
        meta: shortAgo(c.last_message_at ?? c.updated_at),
        icon: "msg" as const,
        href: `/chat/${c.id}`,
        recent: { id: c.id, title: c.title || "Untitled chat", meta: "chat", href: `/chat/${c.id}`, kind: "Chats" },
        preview: { kind: "chat" as const, chat: { id: c.id, title: c.title || "Untitled chat", href: `/chat/${c.id}`, persona: c.persona?.name, at: c.last_message_at ?? c.updated_at, score: 0, titled: true, messages: [] } },
      }));
    }
    const matchingRecent = recent
      .filter((r) => r.kind === TYPE[oneType].label)
      .map((r) => ({ id: `recent-${r.href}`, title: r.title, sub: r.meta, icon: LABEL_ICON[r.kind] ?? TYPE_ICON[oneType], href: r.href, recent: r }));
    if (oneType === "run") {
      const live: Row[] = (liveRuns.data?.runs ?? []).slice(0, 8).map((r) => ({
        id: `live-${r.id}`,
        title: [r.ticket_key, r.work_title].filter(Boolean).join(" ") || r.agent.name,
        sub: [r.agent.name, r.state.replaceAll("_", " ")].join(" · "),
        icon: "play" as const,
        tone: "run" as const,
        href: `/runs/${r.id}`,
        preview: { kind: "item" as const, label: r.ticket_key ? `Run · ${r.ticket_key}` : "Run", title: r.work_title ?? r.ticket_key ?? r.agent.name, detail: `${r.agent.name} · ${r.state.replaceAll("_", " ")}` },
      }));
      const seen = new Set(live.map((r) => r.href));
      return [...live, ...matchingRecent.filter((r) => !seen.has(r.href))];
    }
    return matchingRecent;
  })();

  const withQuery = (base: string, params: Record<string, string | undefined>) => {
    const q = new URLSearchParams();
    for (const [k, v] of Object.entries(params)) if (v) q.set(k, v);
    const s = q.toString();
    return s ? `${base}?${s}` : base;
  };
  const actions: Row[] = [
    {
      id: "new-ticket",
      title: title ? `New ticket: ${title}` : "New ticket",
      shortcut: "C",
      icon: "plus",
      fallback: true,
      href: withQuery("/tickets/new", { title: title || undefined, project: actionProject }),
    },
    ...(title && actionProject
      ? [{
          id: "ask",
          title: `Ask: ${title}`,
          sub: "new chat",
          icon: "msg" as const,
          fallback: true,
          perform: () =>
            askChat.mutate(
              { project: actionProject, body: title },
              { onSuccess: (c) => router.push(`/chat/${c.id}`), onError: () => setOpen(true) },
            ),
        }]
      : []),
    {
      id: "new-chat",
      title: attachHere ? `New chat with ${attachHere.label} attached` : "New chat",
      icon: "msg",
      perform: () => {
        const p = attachHere?.project;
        createChat.mutate(
          p ? { project: p } : {},
          {
            onSuccess: (c) => router.push(attachHere ? `/chat/${c.id}?${attachQuery(p, attachHere.ref, attachHere.label)}` : `/chat/${c.id}`),
            // Reopen so the alert below explains what happened.
            onError: () => setOpen(true),
          },
        );
      },
    },
    {
      id: "plan",
      title: title ? `Start planning: ${title}` : "Start planning",
      icon: "bulb",
      fallback: true,
      href: withQuery("/plans", {
        project: actionProject,
        goal: title || undefined,
        artifact: doc && doc.type !== "note" ? doc.id : undefined,
      }),
    },
    {
      id: "switch",
      title: "Switch space…",
      icon: "folder",
      perform: () => {
        // Stay open on the project list instead of navigating.
        setMode("projects");
        setQuery("");
        setActive(0);
        setOpen(true);
      },
    },
    ...(ctx?.kind === "ticket" && ticket.data?.run
      ? [{ id: "run", title: `Go to run for ${ctx.key}`, icon: "play" as const, meta: ticket.data.run.state, href: `/runs/${ticket.data.run.id}` }]
      : []),
    ...(ctx?.kind === "ticket" && ticket.data && hasLiveRun(ticket.data) && ticket.data.run
      ? [{
          id: "cancel-run",
          title: `Cancel run for ${ctx.key}`,
          icon: "x" as const,
          onDemand: true,
          perform: () => controlRun.mutate({ id: ticket.data!.run!.id, action: "cancel" }, { onError: failed }),
        }]
      : []),
    ...(ticket.data && ctx?.kind === "ticket"
      ? STATUSES.filter(([s]) => s !== ticket.data!.status).map(([status, label]) => ({
          id: `status-${status}`,
          title: `Set status: ${label}`,
          icon: "tickets" as const,
          onDemand: true,
          perform: () => updateTicket.mutate({ status, revision: ticket.data!.revision }, { onError: failed }),
        }))
      : []),
    ...(ticket.data && ctx?.kind === "ticket"
      ? ticket.data.approvals.filter((a) => a.state === "pending").map((a) => ({
          id: `approve-${a.id}`,
          title: `Approve: ${a.action_summary}`,
          icon: "check" as const,
          onDemand: true,
          perform: () => decideApproval.mutate({ id: a.id, decision: "approve" }, { onError: failed }),
        }))
      : []),
    {
      id: "copy-link",
      title: "Copy link to this page",
      icon: "link",
      onDemand: true,
      perform: () => void navigator.clipboard.writeText(window.location.href).catch(failed),
    },
    {
      id: "toggle-sidebar",
      title: "Toggle left sidebar",
      shortcut: SIDEBAR_TOGGLE_HINT,
      icon: "sidebar",
      onDemand: true,
      perform: () => window.dispatchEvent(new Event("la:toggle-sidebar")),
    },
    {
      id: "shortcuts",
      title: "Keyboard shortcuts",
      shortcut: "?",
      icon: "key",
      perform: () => window.dispatchEvent(new Event("la:shortcuts")),
    },
  ];
  const shownActions = paletteScope
    ? []
    : actions.filter((a) => {
        if (commands) return matchesWords(a.title, title);
        if (oneType) return false;
        if (title) return a.fallback || matchesWords(a.title, title);
        return !a.onDemand;
      });

  // Same item set as the sidebar (lib/project-scope.ts), scoped to the remembered project.
  const goTo: Row[] = paletteScope
    ? []
    : NAV_GROUPS.flatMap((g) =>
        g.items.map((i) => ({
          id: `nav-${i.href}`,
          title: `Go to ${i.label}`,
          sub: g.label,
          icon: "compass" as const,
          href: withProject(i.href, remembered),
        })),
      )
        .filter((i) => !oneType && (title ? matchesWords(i.title, title) : commands))
        // An app already offered above isn't offered again here.
        .filter((i) => !apps.some((a) => a.href === i.href));

  const sections: Section[] =
    mode === "projects"
      ? [{ key: "projects", label: "Switch space", rows: projectRows }]
      : knowledgeMode
        ? knowledgeSections
        : typeScoped
          ? [
              { key: "jump", label: "Jump to", rows: jump },
              ...(searchText ? resultSections : [{ key: oneType!, label: TYPE[oneType!].label, rows: scopedIdleRows }]),
            ].filter((s) => s.rows.length > 0)
          : [
              { key: "needs", label: "Needs you", count: inboxItems.length || undefined, tone: "human" as const, rows: needsYou },
              { key: "running", label: "Running", rows: running },
              { key: "continue", label: "Continue", rows: resume },
              { key: "recent", label: "Recent", rows: recentRows },
              { key: "jump", label: "Jump to", rows: jump },
              ...resultSections,
              { key: "actions", label: "Actions", rows: shownActions },
              ...(commands && title ? [{ key: "projects", label: "Switch space", rows: projectRows }] : []),
              { key: "goto", label: "Go to", rows: goTo },
            ].filter((s) => s.rows.length > 0);
  const rows = sections.flatMap((s) => s.rows);
  const index = Math.max(0, Math.min(active, rows.length - 1));
  const selected = rows[index];
  const activeId = rows.length ? `command-${index}` : undefined;

  // The types under More: those with hits first (with counts), then the rest.
  const moreWith = MORE_TYPES.filter((t) => (counts[t] ?? 0) > 0);
  const moreWithout = MORE_TYPES.filter((t) => !(counts[t] ?? 0));
  const moreChoices = searchText ? moreWith : MORE_TYPES;
  const moreType = oneType && MORE_TYPES.includes(oneType) ? oneType : undefined;

  // The approval in the preview, decided with ⌥A / ⌥D (bare A and D would type into the search).
  const approval = selected?.preview?.kind === "inbox" && selected.preview.item.kind === "approval" ? selected.preview.item : undefined;
  const decide = useDecideApproval(approval?.ticket_key ?? "");
  const decideSelected = (decision: "approve" | "deny") => {
    const id = approval && approvalId(approval.id);
    if (!id || decide.isPending) return;
    decide.mutate(
      { id, decision },
      {
        onSuccess: () => {
          void qc.invalidateQueries({ queryKey: ["inbox"] });
          void qc.invalidateQueries({ queryKey: ["bootstrap"] });
        },
        onError: failed,
      },
    );
  };
  const previewActions: PreviewAction[] = !selected
    ? []
    : approval
      ? [
          { label: "Approve", keys: "⌥A", tone: "approve", run: () => decideSelected("approve") },
          { label: "Deny", keys: "⌥D", run: () => decideSelected("deny") },
        ]
      : [
          ...(selected.href || selected.perform || selected.moreOf
            ? [{ label: selected.message ? "Jump to message" : selected.moreOf ? `Show ${TYPE[selected.moreOf].label}` : selected.perform && !selected.href ? "Run" : "Open", keys: "↵", run: () => go(selected) }]
            : []),
          ...(selected.attach ? [{ label: "Attach to new chat", keys: "⌥↵", run: () => attachToChat(selected) }] : []),
        ];

  // Entering or leaving the project list keeps typing in the input.
  useEffect(() => {
    if (open) inputRef.current?.focus();
  }, [mode, open]);

  useEffect(() => {
    if (open && activeId) document.getElementById(activeId)?.scrollIntoView({ block: "nearest" });
  }, [activeId, open]);

  useEffect(() => {
    rememberedRef.current = remembered;
  }, [remembered]);

  useEffect(() => {
    openRef.current = open;
  }, [open]);

  useEffect(() => {
    const show = (detail?: OpenPaletteDetail) => {
      if (!openRef.current) {
        if (document.activeElement instanceof HTMLElement && document.activeElement !== document.body)
          returnFocus.current = document.activeElement;
        else returnFocus.current = null;
      }
      const nextScope: PageScope | undefined =
        detail?.scope === "all" || !detail?.scope
          ? undefined
          : detail.scope === "page"
            ? pageScope(window.location.pathname, window.location.search)
            : detail.scope;
      const currentProject =
        new URLSearchParams(window.location.search).get("project") ??
        window.location.pathname.match(/^\/tickets\/([A-Z][A-Z0-9]*)-\d+$/)?.[1] ??
        // A chat's URL may not name its project; the remembered one is what actions use too.
        (projectSection(window.location.pathname) ? rememberedRef.current : undefined);
      setProject(currentProject ?? undefined);
      setScope(!!currentProject);
      setPaletteScope(nextScope);
      setKnowledgeKind(undefined);
      let nextAgent = false;
      if (typeof detail?.includeAgent === "boolean") {
        nextAgent = detail.includeAgent;
      } else {
        try {
          nextAgent = JSON.parse(window.localStorage.getItem(KNOWLEDGE_VIEW_KEY) ?? "null") === "agent";
        } catch {
          nextAgent = false;
        }
      }
      setIncludeAgent(nextAgent);
      if (detail?.query !== undefined) setQuery(detail.query);
      else if (!openRef.current) setQuery("");
      setMode("root");
      setActive(0);
      setChip(nextScope?.kind === "type" ? nextScope.type : undefined);
      setFacet(undefined);
      setExpanded(undefined);
      setMoreOpen(false);
      let stored: string | null = null;
      try {
        stored = window.localStorage.getItem(RECENT_KEY);
      } catch {
        /* storage blocked: no recents */
      }
      setRecent(parseRecent(stored));
      setOpen(true);
    };
    const key = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && !e.altKey && e.key.toLowerCase() === "k") {
        if (e.target instanceof Element && e.target.closest("[data-dev-terminal]")) return;
        e.preventDefault();
        show({ scope: e.shiftKey ? "page" : "all" });
      }
    };
    const onSearch = (e: Event) => {
      const detail = e instanceof CustomEvent ? (e.detail as OpenPaletteDetail | undefined) : undefined;
      show(detail);
    };
    window.addEventListener("keydown", key);
    window.addEventListener("la:search", onSearch);
    return () => {
      window.removeEventListener("keydown", key);
      window.removeEventListener("la:search", onSearch);
    };
  }, []);

  const switchToGlobal = () => {
    setPaletteScope(undefined);
    setKnowledgeKind(undefined);
    setChip(undefined);
    setFacet(undefined);
    setExpanded(undefined);
    setActive(0);
    inputRef.current?.focus();
  };

  const pickKnowledgeKind = (next: PageKind | undefined) => {
    setKnowledgeKind(next);
    setFacet(undefined);
    setActive(0);
    inputRef.current?.focus();
  };

  const onKeyDown = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (moreOpen) {
      const n = moreChoices.length;
      if (e.key === "ArrowDown" && n) {
        e.preventDefault();
        setMoreActive((moreActive + 1) % n);
      } else if (e.key === "ArrowUp" && n) {
        e.preventDefault();
        setMoreActive((moreActive + n - 1) % n);
      } else if (e.key === "Enter" && moreChoices[moreActive]) {
        e.preventDefault();
        pickType(moreChoices[moreActive]);
      } else if (e.key === "Escape") {
        // Closes the menu, not the palette.
        e.preventDefault();
        e.stopPropagation();
        setMoreOpen(false);
      }
      return;
    }
    if (e.key === "ArrowDown" && rows.length) {
      e.preventDefault();
      setActive((index + 1) % rows.length);
    }
    if (e.key === "ArrowUp" && rows.length) {
      e.preventDefault();
      setActive((index + rows.length - 1) % rows.length);
    }
    if (e.key === "Home" && rows.length) {
      e.preventDefault();
      setActive(0);
    }
    if (e.key === "End" && rows.length) {
      e.preventDefault();
      setActive(rows.length - 1);
    }
    const atEnd = e.currentTarget.selectionStart === e.currentTarget.value.length;
    if (e.key === "ArrowRight" && atEnd && selected?.chat && !selected.message && selected.chat.messages.length && expanded !== selected.chat.id) {
      e.preventDefault();
      setExpanded(selected.chat.id);
    }
    if (e.key === "ArrowLeft" && selected?.chat && (selected.message || expanded === selected.chat.id)) {
      e.preventDefault();
      const chatId = selected.chat.id;
      setExpanded(undefined);
      // Back onto the chat's own row.
      const at = rows.findIndex((r) => r.chat?.id === chatId && !r.message);
      if (at >= 0) setActive(at);
    }
    if (e.altKey && approval && (e.code === "KeyA" || e.code === "KeyD")) {
      e.preventDefault();
      decideSelected(e.code === "KeyA" ? "approve" : "deny");
      return;
    }
    if (e.key === "Enter" && e.shiftKey && kCanCreate) {
      e.preventDefault();
      createKnowledgePage();
      return;
    }
    // While results are stale, ↵ must not fall through to an action or an old hit.
    if (e.key === "Enter" && selected && (!pending || selected.local || selected.moreOf || jump.includes(selected))) {
      e.preventDefault();
      if (e.altKey) attachToChat(selected);
      else go(selected, e.metaKey || e.ctrlKey);
    }
    if (e.key === "Backspace" && mode === "projects" && !query) {
      e.preventDefault();
      setMode("root");
    }
    if (e.key === "Tab" && mode === "root" && !commands) {
      e.preventDefault();
      if (knowledgeMode) pickKnowledgeKind(stepKnowledgeKind(knowledgeKind, e.shiftKey));
      else if (!typeScoped) pickType(stepChip(oneType, e.shiftKey));
    }
  };

  const hints: [string, string][] =
    mode === "projects"
      ? [["↑↓", "move"], ["↵", "switch"], ["⌫", "back"], ["esc", "close"]]
      : moreOpen
        ? [["↑↓", "move"], ["↵", "show this type"], ["esc", "close menu"]]
        : commands
          ? [["↑↓", "move"], ["↵", "run"], ["esc", "close"]]
          : knowledgeMode
            ? [
                ["↑↓", "move"],
                ["↵", "open"],
                ...(kCanCreate ? [["⇧↵", "create"] as [string, string]] : []),
                ["Tab", "next kind"],
                ["#", "tags"],
                ["⌥↵", "attach to chat"],
                ["⌘↵", "new tab"],
                ["⌘K", "all Vesper"],
              ]
            : typeScoped
              ? [["↑↓", "move"], ["↵", "open"], ["⌥↵", "attach to chat"], ["⌘↵", "new tab"], ["⌘K", "all Vesper"]]
              : selected?.message
                ? [["↑↓", "move"], ["↵", "jump to message"], ["←", "collapse"], ["⌘↵", "new tab"]]
                : approval
                  ? [["↑↓", "move"], ["⌥A", "approve"], ["⌥D", "deny"], ["Tab", "next type"], ["⌘↵", "new tab"]]
                  : !searchText
                    ? [["↑↓", "move"], ["↵", "open"], ["Tab", "next type"], ["⌘↵", "new tab"], ["@", "people"], ["#", "tickets"], [">", "commands"]]
                    : oneType
                      ? [["↑↓", "move"], ["↵", "open"], ["Tab", "next type"], ["⇧Tab", "back to All"], ["⌥↵", "attach to chat"], ["⌘↵", "new tab"]]
                      : [["↑↓", "move"], ["↵", "open"], ["→", "expand chat"], ["Tab", "next type"], ["⌥↵", "attach to chat"], ["⌘↵", "new tab"]];

  const chipClass = (on: boolean, empty: boolean) =>
    cx(
      "inline-flex h-[26px] flex-none items-center gap-1 rounded-full border px-3 text-12 transition-colors",
      on ? "border-accent bg-accent-soft font-semibold text-fg" : empty ? "border-border text-fg-tertiary/70 hover:bg-hover" : "border-border-strong text-fg-secondary hover:bg-hover",
    );
  const count = (n: number | undefined, on: boolean) => (searchText && n ? <span className={cx("font-normal", on ? "text-fg-secondary" : "text-fg-tertiary")}>{n}</span> : null);

  // An element, not a component: it reads the palette's state as it renders.
  const moreMenu = (
    <div role="listbox" aria-label="More types">
      <div className="px-2 pb-1 pt-1.5 text-11 font-semibold uppercase tracking-wide text-fg-tertiary">{searchText ? "With results" : "Types"}</div>
      {moreChoices.length === 0 && <p className="px-2 py-1.5 text-13 text-fg-tertiary">Nothing else matched.</p>}
      {moreChoices.map((t, i) => (
        <div
          key={t}
          role="option"
          aria-selected={i === moreActive}
          onMouseDown={(e) => e.preventDefault()}
          onMouseMove={() => setMoreActive(i)}
          onClick={() => pickType(t)}
          className={cx("flex h-[30px] cursor-pointer items-center gap-2 rounded-lg px-2 text-13", i === moreActive ? "bg-selected text-fg" : "text-fg-secondary")}
        >
          <span className="flex-1">
            {TYPE[t].label} {searchText && <span className="text-fg-tertiary">{counts[t]}</span>}
          </span>
          <span className="font-mono text-11 text-fg-tertiary">{TYPE[t].token}</span>
        </div>
      ))}
      {searchText && moreWithout.length > 0 && (
        <div className="mt-1.5 border-t border-border px-2 pb-1 pt-2.5">
          <div className="pb-1 text-11 font-semibold uppercase tracking-wide text-fg-tertiary">No results</div>
          <p className="text-12 leading-relaxed text-fg-tertiary/80">{moreWithout.map((t) => TYPE[t].label).join(" · ")}</p>
        </div>
      )}
    </div>
  );

  const chipRow = root && (
    <div data-palette-chips="" className="flex flex-none items-center gap-2 border-b border-border px-4 py-2.5 max-md:overflow-x-auto max-md:[scrollbar-width:none]">
      {knowledgeMode ? (
        <>
          <div role="toolbar" aria-label="Knowledge kinds" className="flex items-center gap-2">
            <button type="button" aria-pressed={!knowledgeKind} onMouseDown={(e) => e.preventDefault()} onClick={() => pickKnowledgeKind(undefined)} className={chipClass(!knowledgeKind, false)}>
              All
            </button>
            {KINDS.map((k) => (
              <button
                key={k.kind}
                type="button"
                aria-pressed={knowledgeKind === k.kind}
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => pickKnowledgeKind(k.kind)}
                className={chipClass(knowledgeKind === k.kind, false)}
              >
                {k.plural}
              </button>
            ))}
          </div>
          <div className="ml-auto flex items-center gap-2 max-md:ml-0">
            <button
              type="button"
              aria-pressed={includeAgent}
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => {
                setIncludeAgent(!includeAgent);
                setActive(0);
              }}
              className={chipClass(includeAgent, false)}
            >
              Agent knowledge
            </button>
            <button type="button" onMouseDown={(e) => e.preventDefault()} onClick={switchToGlobal} className={chipClass(false, true)}>
              All Vesper
            </button>
          </div>
        </>
      ) : typeScoped ? (
        <>
          <div role="toolbar" aria-label="Scoped search" className="flex items-center gap-2">
            <span className={chipClass(true, false)}>
              {paletteScope.label} {count(counts[paletteScope.type], true)}
            </span>
            <button type="button" onMouseDown={(e) => e.preventDefault()} onClick={switchToGlobal} className={chipClass(false, true)}>
              All Vesper
            </button>
          </div>
          {project && (
            <button
              type="button"
              aria-pressed={scope}
              aria-label={scope ? `Searching ${project} only; search all spaces` : `Searching all spaces; search ${project} only`}
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => setScope(!scope)}
              className={cx(chipClass(scope, false), "ml-auto max-md:ml-0")}
            >
              {scope ? project : "All spaces"}
            </button>
          )}
        </>
      ) : (
        <>
          <div role="toolbar" aria-label="Search types" className="flex items-center gap-2">
            <button type="button" aria-pressed={!oneType} onMouseDown={(e) => e.preventDefault()} onClick={() => pickType(undefined)} className={chipClass(!oneType, false)}>
              All {count(total, !oneType)}
            </button>
            {CHIP_TYPES.map((t) => (
              <button
                key={t}
                type="button"
                aria-pressed={oneType === t}
                onMouseDown={(e) => e.preventDefault()}
                onClick={() => pickType(t)}
                className={chipClass(oneType === t, !!searchText && !pending && !counts[t])}
              >
                {TYPE[t].label} {count(counts[t], oneType === t)}
              </button>
            ))}
            <Popover.Root open={moreOpen} onOpenChange={setMoreOpen}>
              <Popover.Anchor asChild>
                <button
                  type="button"
                  aria-haspopup="listbox"
                  aria-expanded={moreOpen}
                  aria-pressed={!!moreType}
                  onMouseDown={(e) => e.preventDefault()}
                  onClick={() => {
                    setMoreOpen(!moreOpen);
                    setMoreActive(0);
                  }}
                  className={chipClass(!!moreType || moreOpen, false)}
                >
                  {moreType ? (
                    <>
                      {TYPE[moreType].label} {count(counts[moreType], true)}
                    </>
                  ) : (
                    <>More {searchText && moreWith.length ? <span className="font-normal text-fg-tertiary">{moreWith.length}</span> : "+"}</>
                  )}
                </button>
              </Popover.Anchor>
              <Popover.Portal>
                <Popover.Content
                  align="start"
                  sideOffset={6}
                  // Typing stays in the search box; ↑↓ ↵ and esc there drive the menu.
                  onOpenAutoFocus={(e) => e.preventDefault()}
                  onCloseAutoFocus={(e) => e.preventDefault()}
                  // Focus belongs in the search box, which drives this menu; only a click elsewhere closes it.
                  onFocusOutside={(e) => e.preventDefault()}
                  className="z-[60] w-[280px] rounded-xl border border-border-float bg-surface-raised p-1.5 shadow-2xl"
                >
                  {moreMenu}
                </Popover.Content>
              </Popover.Portal>
            </Popover.Root>
          </div>
          {project && (
            <button
              type="button"
              aria-pressed={scope}
              aria-label={scope ? `Searching ${project} only; search all spaces` : `Searching all spaces; search ${project} only`}
              onMouseDown={(e) => e.preventDefault()}
              onClick={() => setScope(!scope)}
              className={cx(chipClass(scope, false), "ml-auto max-md:ml-0")}
            >
              {scope ? project : "All spaces"}
            </button>
          )}
        </>
      )}
    </div>
  );

  const showPreview = root && rows.length > 0;
  const dialogTitle = mode === "projects" ? "Switch space" : paletteScope ? `Search ${paletteScope.label}` : "Search and commands";
  const inputLabel = mode === "projects" ? "Switch to space" : paletteScope ? `Search ${paletteScope.label}` : "Search everything";
  const inputPlaceholder =
    mode === "projects"
      ? "Switch to space…"
      : knowledgeMode
        ? "Search Knowledge pages, #tags…"
        : typeScoped
          ? `Search ${TYPE[paletteScope.type].noun}…`
          : "Search everything, or type @ people  # tickets  > commands";
  const activeFacets = knowledgeMode ? kFacetValues : facetValues;
  const showFacets = knowledgeMode ? (kFacetValues.length > 1 || (!!(kQuery.text || kQuery.tag) && kFacetValues.length > 0)) : !!searchText && !!oneType && facetValues.length > 0;
  const highlightQuery = knowledgeMode ? kQuery.text : title;

  return (
    <Dialog.Root open={open} onOpenChange={close}>
      <Dialog.Portal>
        <Dialog.Overlay data-command-scrim="" className="motion-scrim fixed inset-0 z-50 bg-scrim backdrop-blur-[3px]" />
        <Dialog.Content
          data-command-palette=""
          className="motion-dialog-fast fixed left-1/2 top-[12vh] z-50 flex h-[min(560px,calc(100dvh-12vh-24px))] w-[880px] max-w-[calc(100vw-24px)] -translate-x-1/2 flex-col overflow-hidden rounded-2xl border border-border-float bg-surface-raised shadow-2xl max-md:inset-0 max-md:h-dvh max-md:w-full max-md:max-w-none max-md:translate-x-0 max-md:rounded-none max-md:border-0 max-md:px-safe max-md:pt-safe max-md:pb-safe"
          aria-describedby={undefined}
          onOpenAutoFocus={(e) => {
            // The input, not the first chip.
            e.preventDefault();
            inputRef.current?.focus();
          }}
          onCloseAutoFocus={(e) => {
            // Back to whatever had focus before ⌘K (Radix would pick the body when opened by keyboard).
            // Cleared on navigation so returning focus to a previously clicked sidebar row can't yank scroll back.
            e.preventDefault();
            const el = returnFocus.current;
            if (el?.isConnected) el.focus();
          }}
        >
          {/* A hairline of the theme's accent along the top edge: the palette's only ornament. */}
          <div aria-hidden className="pointer-events-none absolute inset-x-8 top-0 h-px bg-gradient-to-r from-transparent via-accent to-transparent opacity-70" />
          <Dialog.Title className="sr-only">{dialogTitle}</Dialog.Title>
          <div data-palette-input-row="" className="flex h-14 flex-none items-center gap-3 border-b border-border px-5 max-md:h-auto max-md:border-0 max-md:px-3 max-md:pb-1 max-md:pt-3">
            <div className="flex min-w-0 flex-1 items-center gap-3 max-md:h-11 max-md:rounded-xl max-md:bg-surface-sunken max-md:px-3">
              <Icon name="search" size={16} className="flex-none text-fg-tertiary" />
              {mode === "projects" && (
                <button
                  type="button"
                  className="rounded-full border border-border px-2.5 py-0.5 text-12 font-medium text-fg-secondary transition-colors hover:bg-hover"
                  onClick={() => {
                    setMode("root");
                    setQuery("");
                  }}
                >
                  ← Back
                </button>
              )}
              <input
                ref={inputRef}
                autoComplete="off"
                spellCheck={false}
                role="combobox"
                aria-label={inputLabel}
                aria-expanded={rows.length > 0}
                aria-autocomplete="list"
                aria-controls="command-results"
                aria-activedescendant={activeId}
                value={query}
                onChange={(e) => {
                  setQuery(e.target.value);
                  setActive(0);
                  setExpanded(undefined);
                }}
                placeholder={inputPlaceholder}
                className="min-w-0 flex-1 bg-transparent text-16 outline-none placeholder:text-fg-tertiary focus-visible:!outline-none"
                onKeyDown={onKeyDown}
              />
              <span role="status" className="flex flex-none items-center gap-1.5 text-12 text-fg-tertiary">
                {pending && <span aria-hidden className="size-1.5 animate-skeleton rounded-full bg-accent" />}
                {pending ? "Searching…" : ""}
              </span>
            </div>
            <span aria-hidden className="max-md:hidden">
              <Kbd>esc</Kbd>
            </span>
            <Dialog.Close asChild>
              <button type="button" className="hidden h-11 flex-none px-1 text-15 text-accent max-md:block">
                Cancel
              </button>
            </Dialog.Close>
          </div>
          {chipRow}
          {root && filters.tokens.length > 0 && (
            <div className="flex flex-none flex-wrap gap-1 border-b border-border px-4 py-2">
              {filters.tokens.map((token) => (
                <button
                  key={token}
                  type="button"
                  aria-label={`Remove filter ${token}`}
                  className="rounded-full border border-transparent bg-accent-soft px-2.5 py-0.5 font-mono text-12 text-accent transition-colors hover:border-accent"
                  onClick={() => {
                    setQuery(removeToken(query, token));
                    inputRef.current?.focus();
                  }}
                >
                  {token} ×
                </button>
              ))}
            </div>
          )}
          <div className="flex min-h-0 flex-1">
            <div
              className={cx(
                "scroll-py-2 overflow-y-auto overflow-x-hidden overscroll-contain px-2 pb-2 transition-opacity",
                showPreview ? "w-[500px] flex-none max-[919px]:w-full max-[919px]:flex-1" : "flex-1",
                moreOpen && "opacity-40",
              )}
            >
              {(all.isError || one.isError || (knowledgeMode && pagesQuery.isError)) && (
                <p role="alert" className="p-3 text-12 text-pill-blocked-fg">
                  Search failed. Try again.
                </p>
              )}
              {(createChat.isError || askChat.isError) && (
                <p role="alert" className="p-3 text-12 text-pill-blocked-fg">
                  Couldn’t start the chat.
                </p>
              )}
              {createPage.isError && (
                <p role="alert" className="p-3 text-12 text-pill-blocked-fg">
                  Couldn’t create the page.
                </p>
              )}
              {actionFailed && (
                <p role="alert" className="p-3 text-12 text-pill-blocked-fg">
                  That action didn’t go through. Try again.
                </p>
              )}
              {showFacets && (
                <div role="group" aria-label={knowledgeMode ? "Filter folders" : `Filter ${TYPE[oneType!].noun}`} className="flex flex-wrap gap-1.5 px-2 pb-1 pt-2.5">
                  {[{ value: undefined, label: !knowledgeMode && (oneType === "ticket" || oneType === "run") ? "Any status" : knowledgeMode || oneType === "page" ? "Any folder" : "Anyone" }, ...activeFacets.slice(0, 6).map((f) => ({ value: f.value, label: `${!knowledgeMode && oneType === "ticket" ? statusLabel(f.value) : f.value} ${f.count}` }))].map((f) => (
                    <button
                      key={f.value ?? "any"}
                      type="button"
                      aria-pressed={facet === f.value}
                      onMouseDown={(e) => e.preventDefault()}
                      onClick={() => {
                        setFacet(f.value);
                        setActive(0);
                      }}
                      className={cx(
                        "h-[22px] rounded-md border px-2 text-11 transition-colors",
                        facet === f.value ? "border-transparent bg-border-strong font-semibold text-fg" : "border-border text-fg-secondary hover:bg-hover",
                      )}
                    >
                      {f.label}
                    </button>
                  ))}
                </div>
              )}
              {knowledgeMode && !pending && rows.length === 0 && (
                <p className="px-3 py-8 text-center text-14 text-fg-tertiary">
                  {kQuery.tag ? `No pages tagged #${kQuery.tag}.` : kQuery.text ? `No Knowledge pages match “${kQuery.text}”.` : "No Knowledge pages yet."}
                </p>
              )}
              {!knowledgeMode && searchText && !pending && resultSections.length === 0 && jump.length === 0 && (
                <p className="px-3 py-8 text-center text-14 text-fg-tertiary">
                  {oneType ? `No ${TYPE[oneType].noun} match “${filters.text}”.` : `No results for “${query.trim()}”.`}
                </p>
              )}
              {typeScoped && !searchText && !pending && rows.length === 0 && (
                <p className="px-3 py-8 text-center text-14 text-fg-tertiary">
                  Type to search {TYPE[paletteScope.type].noun}…
                </p>
              )}
              {mode === "projects" && rows.length === 0 && <p className="px-3 py-8 text-center text-14 text-fg-tertiary">No project matches “{query}”.</p>}
              <div id="command-results" role="listbox" aria-label="Results" aria-busy={pending} className={cx(pending && "opacity-60")}>
                {sections.map((s) => {
                  const labelId = `command-group-${s.key}`;
                  return (
                    <div key={s.key} role="group" aria-labelledby={s.label ? labelId : undefined} aria-label={s.label ? undefined : TYPE[s.key as TypeKey]?.label}>
                      {s.label && (
                        <div
                          id={labelId}
                          data-palette-section=""
                          role="presentation"
                          className={cx("px-3 pb-1.5 pt-3 text-11 font-semibold uppercase tracking-wide", s.tone === "human" ? "text-state-human" : "text-fg-tertiary")}
                        >
                          {s.label}
                          {s.count ? ` · ${s.count}` : ""}
                        </div>
                      )}
                      {s.rows.map((row) => {
                        const i = rows.indexOf(row);
                        return <RowView key={row.id} row={row} i={i} on={i === index} query={highlightQuery} expanded={!!row.chat && expanded === row.chat.id} onPick={go} onHover={setActive} onToggle={(id) => setExpanded(expanded === id ? undefined : id)} />;
                      })}
                    </div>
                  );
                })}
                {!knowledgeMode && searchText && oneType && oneTotal > oneShown && (
                  <p className="px-3 py-3 text-12 text-fg-tertiary">
                    {oneShown} of {oneTotal}
                    {oneShown < 50 ? " · scroll for more" : " · add words to narrow it"}
                  </p>
                )}
              </div>
            </div>
            {showPreview && (
              <div className="flex min-w-0 flex-1 border-l border-border max-[919px]:hidden">
                <CommandPreview preview={selected?.preview} query={highlightQuery} actions={previewActions} />
              </div>
            )}
          </div>
          <div data-palette-hints="" className="flex h-10 flex-none items-center gap-x-5 overflow-hidden border-t border-border bg-surface-sunken px-5 text-12 text-fg-tertiary max-md:hidden">
            {hints.map(([keys, what]) => (
              <span key={what} className="flex flex-none items-center gap-1.5 whitespace-nowrap">
                <span className="text-fg-secondary">{keys}</span>
                {what}
              </span>
            ))}
          </div>
        </Dialog.Content>
      </Dialog.Portal>
    </Dialog.Root>
  );
}

function RowView({
  row,
  i,
  on,
  query,
  expanded,
  onPick,
  onHover,
  onToggle,
}: {
  row: Row;
  i: number;
  on: boolean;
  query: string;
  expanded: boolean;
  onPick: (row: Row, newTab?: boolean) => void;
  onHover: (i: number) => void;
  onToggle: (chatId: string) => void;
}) {
  const child = !!row.message;
  return (
    <div
      id={`command-${i}`}
      role="option"
      aria-selected={on}
      aria-expanded={row.chat && !row.message && row.chat.messages.length ? expanded : undefined}
      onClick={(e) => onPick(row, e.metaKey || e.ctrlKey)}
      onMouseMove={() => onHover(i)}
      className={cx(
        "relative flex cursor-pointer items-center gap-3 rounded-lg text-left transition-colors duration-(--motion-fast)",
        // A message sits indented under its chat; full width plus the indent would scroll the list sideways.
        row.moreOf ? "min-h-8 px-3" : child ? "ml-6 min-h-[42px] border-l border-border pl-3 pr-3" : "min-h-11 w-full px-3 py-1",
        on ? "bg-selected" : "hover:bg-hover",
      )}
    >
      {on && <span aria-hidden className="absolute bottom-2 left-0 top-2 w-[3px] rounded-full bg-accent" />}
      {!child &&
        (row.moreOf ? (
          <span aria-hidden className="size-7 flex-none" />
        ) : (
          <span
            aria-hidden
            className={cx(
              "grid size-7 flex-none place-items-center rounded-md transition-colors duration-(--motion-fast)",
              row.tone === "human"
                ? "bg-pill-human-bg text-state-human"
                : row.tone === "run"
                  ? "bg-surface-sunken text-state-progress"
                  : on
                    ? "bg-accent-soft text-accent"
                    : "bg-surface-sunken text-fg-secondary",
            )}
          >
            <Icon name={row.icon} size={14} />
          </span>
        ))}
      <span className="min-w-0 flex-1">
        <span className={cx("block truncate", row.moreOf ? "text-12 font-semibold text-accent" : child ? "text-12 font-semibold text-fg-secondary" : "text-14", !row.moreOf && !child && (on ? "text-fg" : "text-fg-secondary"))}>
          {row.mark ? <Parts parts={matchParts(row.title, query)} /> : row.title}
        </span>
        {row.sub && <span className={cx("block truncate text-fg-tertiary", child ? "text-12" : "text-12")}>{row.sub}</span>}
      </span>
      {row.chat && !row.message && row.chat.messages.length > 0 && (
        <button
          type="button"
          aria-label={expanded ? "Hide matching messages" : "Show matching messages"}
          onMouseDown={(e) => e.preventDefault()}
          onClick={(e) => {
            e.stopPropagation();
            onToggle(row.chat!.id);
          }}
          className="hidden size-8 flex-none place-items-center rounded-md text-fg-tertiary hover:bg-hover max-md:grid"
        >
          <Icon name={expanded ? "chev" : "chevr"} size={14} />
        </button>
      )}
      {row.shortcut ? (
        <Kbd>{row.shortcut}</Kbd>
      ) : (
        row.meta && (
          // On a phone a chat with matching messages shows its chevron there instead.
          <span
            className={cx(
              "max-w-[40%] flex-none truncate text-12",
              row.metaClass ?? "text-fg-tertiary",
              // A phone has no Tab key, and its chats with matching messages show a chevron there instead.
              (row.moreOf || (row.chat && !row.message && row.chat.messages.length > 0)) && "max-md:hidden",
            )}
          >
            {row.meta}
          </span>
        )
      )}
    </div>
  );
}
