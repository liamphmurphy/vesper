// Pure logic for the Work screens in the chat look (LAZYAGENTS-164): which
// tickets wait on the person, the list's groups (Needs you first), each row's
// state text, the filter box's tokens and an epic's progress. Pure, with
// .ts imports, so node can run it directly in unit tests.
import type { components } from "./api/schema";
import { groupTickets, isBlocked, type GroupBy, type TicketGroup } from "./ticket-list.ts";
import { isOpen, kindRank } from "./inbox.ts";

type TicketSummary = components["schemas"]["TicketSummary"];
type TicketStatus = components["schemas"]["TicketStatus"];
type InboxItem = components["schemas"]["InboxItem"];

/* -------------------------------------------------------------- needs you */

export type NeedsKind = InboxItem["kind"];

export type NeedsYou = {
  kind: NeedsKind;
  /** The inbox item id; "approval:<uuid>" for approvals. */
  id: string;
  summary: string;
  href: string;
  run_id?: string;
  created_at: string;
};

type NeedsItem = Pick<InboxItem, "id" | "kind" | "ticket_key" | "resolved" | "read" | "needs_you" | "summary" | "href" | "run_id" | "created_at">;

/**
 * The ticket keys the person has to act on, with the most urgent open item
 * each. The same rule as the tray's Needs you tab: open items the server marks
 * needs_you. The kind only ranks them (the Inbox's urgency order, then the
 * longest wait) and labels them.
 */
export function needsYouByTicket(items: readonly NeedsItem[] | undefined) {
  const out = new Map<string, NeedsYou>();
  for (const i of items ?? []) {
    if (!i.needs_you || !isOpen(i) || !i.ticket_key) continue;
    const prev = out.get(i.ticket_key);
    if (prev && (kindRank(prev.kind) - kindRank(i.kind) || Date.parse(prev.created_at) - Date.parse(i.created_at)) <= 0) continue;
    out.set(i.ticket_key, { kind: i.kind, id: i.id, summary: i.summary, href: i.href, run_id: i.run_id, created_at: i.created_at });
  }
  return out;
}

/** The approval's id from its inbox id ("approval:<uuid>"), for /approvals/{id}/{decision}. */
export function approvalId(n: Pick<NeedsYou, "id" | "kind">): string | undefined {
  return n.kind === "approval" && n.id.startsWith("approval:") ? n.id.slice("approval:".length) : undefined;
}

/** Each kind's state text, before the item's summary. */
export const NEEDS_PREFIX: Record<NeedsKind, string> = {
  approval: "Wants approval",
  question: "Asked you",
  blocked: "Run stopped",
  stalled: "Run stalled",
  mockup: "Mockup to review",
  planning: "Plan to review",
  review: "Review requested",
  dispatch: "Ready to dispatch",
  mention: "Mentioned you",
  suggestion: "Wiki edit to review",
  workflow_gate: "Workflow gate",
  scheduled: "Scheduled task",
  connector_approval: "Connector to approve",
  secret_approval: "Secret to approve",
  secret_expiring: "Secret expiring",
  merged: "PR merged",
  pr_approved: "PR approved",
  drive_backup: "Drive backup failed",
};

const ENDED_RUN_STATES = new Set(["completed", "failed", "cancelled"]);

/**
 * Filter a per-ticket needs-you indicator so stale dispatch prompts don't paint
 * amber on tickets already in backlog/progress/review/done or with a live run.
 */
export function ticketNeedsYou<T>(
  t: Pick<TicketSummary, "status"> & { run?: { state?: string } | null },
  item: T | undefined,
): T | undefined {
  if (!item || t.status === "done" || t.status === "canceled") return undefined;
  if (typeof item === "object" && item !== null && "kind" in item && (item as { kind?: unknown }).kind === "dispatch") {
    const liveRun = !!t.run?.state && !ENDED_RUN_STATES.has(t.run.state);
    return t.status === "todo" && !liveRun ? item : undefined;
  }
  return item;
}

/** A row's current-state text: what it waits on, what blocks it, or where it is. */
export function stateText(t: Pick<TicketSummary, "status" | "unmet_dependencies" | "pr">, needs?: Pick<NeedsYou, "kind" | "summary">): { text: string; tone: "human" | "blocked" | "quiet" } {
  if (needs) return { text: needs.summary ? `${NEEDS_PREFIX[needs.kind] ?? "Needs you"}: ${needs.summary}` : NEEDS_PREFIX[needs.kind] ?? "Needs you", tone: "human" };
  if (isBlocked(t as TicketSummary)) return { text: `Blocked by ${t.unmet_dependencies}`, tone: "blocked" };
  const pr = t.pr ? ` · PR #${t.pr.number}${t.pr.state === "merged" ? " merged" : ""}` : "";
  const text: Record<TicketStatus, string> = {
    backlog: "Backlog",
    todo: "Ready",
    in_progress: "In progress",
    in_review: "In review",
    done: "Done",
    canceled: "Canceled",
  };
  return { text: text[t.status] + pr, tone: "quiet" };
}

/* ----------------------------------------------------------------- groups */

export type WorkGroup = TicketGroup & {
  /** The group's label: "Needs you", "In progress", or the group-by's name. */
  title: string;
  needs: boolean;
};

/** Monday 00:00 local time of the week that contains `now`. */
export function weekStart(now: Date): number {
  const d = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  d.setDate(d.getDate() - ((d.getDay() + 6) % 7));
  return d.getTime();
}

const STATUS_BUCKETS: Array<{ id: string; title: string; match: (t: TicketSummary, week: number) => boolean }> = [
  { id: "in_progress", title: "In progress", match: (t) => t.status === "in_progress" || t.status === "in_review" },
  { id: "todo", title: "Ready", match: (t) => t.status === "todo" },
  { id: "backlog", title: "Backlog", match: (t) => t.status === "backlog" },
  { id: "done_week", title: "Done this week", match: (t, week) => t.status === "done" && Date.parse(t.updated_at) >= week },
  { id: "done", title: "Done earlier", match: (t) => t.status === "done" },
  { id: "canceled", title: "Canceled", match: (t) => t.status === "canceled" },
];

function bucket(id: string, by: GroupBy, title: string, tickets: TicketSummary[], needs = false): WorkGroup {
  let criteriaDone = 0, criteriaTotal = 0, points = 0;
  for (const t of tickets) {
    criteriaDone += t.criteria_done;
    criteriaTotal += t.criteria_total;
    if (t.status !== "canceled") points += t.estimate_points ?? 0;
  }
  return { id, by, name: title, title, tickets, criteriaDone, criteriaTotal, points, needs };
}

/**
 * The list's groups. Tickets waiting on the person come first as Needs you
 * (open tickets only). Grouped by status, the rest fall into In progress,
 * Ready, Backlog, Done this week, Done earlier and Canceled; any other
 * group-by keeps its own groups after Needs you.
 */
export function workGroups(tickets: TicketSummary[], needs: ReadonlyMap<string, unknown>, by: GroupBy, now = new Date()): WorkGroup[] {
  const waiting = tickets.filter((t) => Boolean(ticketNeedsYou(t, needs.get(t.key))));
  const waitingKeys = new Set(waiting.map((t) => t.key));
  const rest = tickets.filter((t) => !waitingKeys.has(t.key));
  const out: WorkGroup[] = waiting.length ? [bucket("needs_you", by, "Needs you", waiting, true)] : [];
  if (by === "status") {
    const week = weekStart(now);
    const left = new Set(rest);
    for (const b of STATUS_BUCKETS) {
      const hit = [...left].filter((t) => b.match(t, week));
      for (const t of hit) left.delete(t);
      if (hit.length) out.push(bucket(b.id, by, b.title, hit));
    }
    return out;
  }
  for (const g of groupTickets(rest, by)) out.push({ ...g, title: g.name, needs: false });
  return out;
}

/* ----------------------------------------------------------- filter box */

export const FILTER_KEYS = ["project", "epic", "agent", "status"] as const;
export type FilterKey = (typeof FILTER_KEYS)[number];
export type FilterToken = { key: FilterKey; value: string };

/** Splits the box into key:value tokens (values may be "quoted") and the free text left over. */
export function parseFilterText(text: string): { tokens: FilterToken[]; text: string } {
  const tokens: FilterToken[] = [];
  const re = /(?:^|\s)(project|epic|agent|status):(?:"([^"]*)"?|(\S*))/gi;
  const free = text.replace(re, (_m, key: string, quoted?: string, bare?: string) => {
    const value = (quoted ?? bare ?? "").trim();
    if (value) tokens.push({ key: key.toLowerCase() as FilterKey, value });
    return " ";
  });
  return { tokens, text: free.replace(/\s+/g, " ").trim() };
}

// Values can't contain a double quote inside quotes; drop it rather than break the token.
const quote = (v: string) => (/\s/.test(v) ? `"${v.replace(/"/g, "")}"` : v);

/** The box's text without its project: token, once the project picker has taken it. */
export function withoutProjectToken(text: string): string {
  return text.replace(/(^|\s)project:(?:"[^"]*"?|\S*)/gi, " ").replace(/\s+/g, " ").trim();
}

/** The box's text for the list's current filters. */
export function filterText(f: { project?: string; epic?: string; agent?: string; status?: string; q?: string }): string {
  const parts: string[] = [];
  for (const k of FILTER_KEYS) if (f[k]) parts.push(`${k}:${quote(f[k]!)}`);
  if (f.q) parts.push(f.q);
  return parts.join(" ");
}

const STATUS_ALIASES: Record<string, TicketStatus> = {
  backlog: "backlog", todo: "todo", ready: "todo", in_progress: "in_progress", progress: "in_progress", "in-progress": "in_progress",
  in_review: "in_review", review: "in_review", "in-review": "in_review", done: "done", canceled: "canceled", cancelled: "canceled",
};

export type FilterLookups = {
  projects: ReadonlyArray<{ id: string; key: string; name: string }>;
  epics: ReadonlyArray<{ id: string; name: string; project_id: string }>;
  agents: ReadonlyArray<{ handle: string; name: string }>;
  /** The URL's epic id: wins when several epics share the token's name. */
  currentEpic?: string;
};

export type ResolvedFilter = { project?: string; epic?: string; assignee?: string; status?: TicketStatus; q?: string; unknown: string[] };

const norm = (s: string) => s.toLowerCase().replace(/[\s_-]+/g, " ").trim();

/**
 * The URL filters for the box: project by key or name, epic by id or name
 * (the project's epics first), agent by handle or name, status by name or
 * alias. Tokens that match nothing are listed in `unknown` and not applied.
 */
export function resolveFilter(text: string, look: FilterLookups): ResolvedFilter {
  const { tokens, text: q } = parseFilterText(text);
  const out: ResolvedFilter = { unknown: [] };
  if (q) out.q = q;
  const byKey = new Map(tokens.map((t) => [t.key, t.value]));
  const pv = byKey.get("project");
  if (pv) {
    const p = look.projects.find((x) => x.key.toLowerCase() === pv.toLowerCase()) ?? look.projects.find((x) => norm(x.name) === norm(pv));
    if (p) out.project = p.key;
    else out.unknown.push(`project:${pv}`);
  }
  const ev = byKey.get("epic");
  if (ev) {
    const proj = out.project ? look.projects.find((p) => p.key === out.project) : undefined;
    const named = look.epics.filter((e) => e.id === ev || norm(e.name) === norm(ev));
    const e = named.find((x) => x.id === look.currentEpic) ?? named.find((x) => !proj || x.project_id === proj.id) ?? named[0];
    if (e) out.epic = e.id;
    else out.unknown.push(`epic:${ev}`);
  }
  const av = byKey.get("agent");
  if (av) {
    const h = av.replace(/^@/, "").toLowerCase();
    const a = look.agents.find((x) => x.handle.toLowerCase() === h) ?? look.agents.find((x) => norm(x.name) === norm(av));
    if (a) out.assignee = a.handle;
    else out.unknown.push(`agent:${av}`);
  }
  const sv = byKey.get("status");
  if (sv) {
    const s = STATUS_ALIASES[sv.toLowerCase().replace(/\s+/g, "_")];
    if (s) out.status = s;
    else out.unknown.push(`status:${sv}`);
  }
  return out;
}

/* ----------------------------------------------------------------- epics */

export type EpicProgress = { done: number; running: number; needs: number; open: number; total: number };

/** Segments for an epic's bar: done, running, needs you, and the rest still open. Canceled tickets don't count. */
export function epicProgress(tickets: readonly (Pick<TicketSummary, "key" | "status"> & { run?: { state?: string } | null })[], needs: ReadonlyMap<string, unknown>): EpicProgress {
  const p: EpicProgress = { done: 0, running: 0, needs: 0, open: 0, total: 0 };
  for (const t of tickets) {
    if (t.status === "canceled") continue;
    p.total++;
    if (t.status === "done") p.done++;
    else if (ticketNeedsYou(t, needs.get(t.key))) p.needs++;
    else if (t.status === "in_progress" || t.status === "in_review") p.running++;
    else p.open++;
  }
  return p;
}

/**
 * Start ready: open tickets with no live run and every blocker done start now;
 * the blocked ones are listed so the card can say what waits on what.
 */
export function startReady<T extends Pick<TicketSummary, "key" | "status" | "unmet_dependencies">>(tickets: readonly T[], live: ReadonlySet<string>) {
  const open = tickets.filter((t) => t.status !== "done" && t.status !== "canceled" && !live.has(t.key));
  const blocked = (t: T) => (t.unmet_dependencies ?? 0) > 0;
  return { ready: open.filter((t) => !blocked(t)), blocked: open.filter(blocked) };
}
