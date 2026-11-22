import type { Page, Route } from "@playwright/test";
import type { components } from "../lib/api/schema";
import { menuResponse } from "./mock-menu";

type S = components["schemas"];
const project: S["Project"] = { id: "project-web", key: "WEB", name: "Web app", color: "#6e56cf", default_branch: "main", archived: false, revision: 1 };
const ops: S["Project"] = { ...project, id: "project-ops", key: "OPS", name: "Operations" };
const builder: S["Agent"] = { id: "agent-builder", name: "Builder", handle: "builder", kind: "main", color_index: 0, role: "Developer", specialty: "UI", model: "test", status: "idle" };
const reviewer: S["Agent"] = { ...builder, id: "agent-reviewer", name: "Reviewer", handle: "reviewer", color_index: 2 };
const statuses: S["TicketStatus"][] = ["backlog", "todo", "in_progress", "in_review", "done", "canceled"];
const stamp = (revision: number) => new Date(Date.UTC(2026, 10, 6, 12, 0, revision)).toISOString();

/** In-memory LAZYAGENTS-29 contract, not a substitute for real-backend integration. */
export async function installBoardApi(page: Page) {
  const epics: S["Epic"][] = ["Kanban board", "Other epic"].map((name, i) => ({
    id: `epic-${i + 1}`, project_id: project.id, name, health: i ? "at_risk" : "on_track", requires_mockup: false,
    status: "open", criteria_total: 2, criteria_done: 1, points_total: 0, points_done: 0, tickets_total: 0, tickets_open: 0,
  }));
  const criteria: S["EpicCriterion"][] = [
    { id: "criterion-1", epic_id: "epic-1", position: 1, text: "Board shows all statuses", done: true,
      checked_by: { type: "agent", id: "agent-builder", name: "Builder" }, checked_at: stamp(1) },
    { id: "criterion-2", epic_id: "epic-1", position: 2, text: "Cards can move", done: false },
  ];
  function make(n: number, status: S["TicketStatus"], title: string, extra: Partial<S["Ticket"]> = {}): S["Ticket"] {
    return {
      id: `ticket-${n}`, key: `WEB-${n}`, project, title, status, description_md: "", priority: "medium", labels: [],
      revision: 1, dependency_revision: 1, blocked_by: [], blocks: [], criteria: [], artifacts: [], approvals: [],
      requires_mockup: false, epic_review: false, mockup_gate: { required: false, from_epic: false, approved: false, mockups: [] },
      created_at: stamp(1), updated_at: stamp(1), epic: { id: epics[0].id, name: epics[0].name }, ...extra,
    };
  }
  const tickets: S["Ticket"][] = [
    make(1, "todo", "Build ticket modal", { priority: "high", estimate_points: 3, assignee: builder, blocked_by: [{ id: "blocker", key: "WEB-2", title: "Write integration checks", status: "backlog" }] }),
    make(2, "backlog", "Write integration checks", { priority: "none" }),
    make(3, "done", "ADR and contract", { estimate_points: 5, assignee: builder }),
    make(4, "in_progress", "Other epic work", { priority: "urgent", estimate_points: 8, assignee: reviewer, epic: { id: epics[1].id, name: epics[1].name } }),
    make(5, "in_review", "Review board", { priority: "low", estimate_points: 2, assignee: builder }),
    make(6, "canceled", "Canceled task", { estimate_points: 3 }),
  ];
  // Detail criteria are used for the summary progress too.
  tickets[0].criteria = [{ id: "ticket-criterion", position: 1, text: "Works", done: true }];
  tickets[0].description_md = "Original description";
  tickets[0].estimated_by = { type: "agent", id: builder.id, name: builder.name };
  tickets[2].estimated_by = { type: "user", id: "other-user", name: "Sam" };
  const me = { type: "user" as const, id: "user", name: "Liam" };
  // Mutable so specs can archive projects or bump the shell's live counts.
  const projects: S["Project"][] = [project, ops];
  const counts: S["Bootstrap"]["counts"] = { inbox: 0, needs_you: 0, wiki_suggestions: 0, live_agents: 0 };
  const runner: S["RunnerStatus"] = { online: true, runners: [], slots: 3, busy: 0, live: 0, queued: 0, host_folder_workspaces: false, max_concurrent_subagents: 3, max_parallel_delegations: 3 };
  let newCriterionId = 0;
  const patches: Array<{ key: string; body: S["TicketPatch"] }> = [];
  const boardRequests: string[] = [];
  const unhandled: string[] = [];
  const savedViews: S["SavedView"][] = [];
  // Open Inbox items; approval/question/blocked ones mark their ticket Needs you.
  const inbox: S["InboxItem"][] = [];
  const decisions: Array<{ id: string; decision: string }> = [];
  let rejection: { status: number; message: string; field?: string } | undefined;
  const criteriaRequests: string[] = [];
  let gate: Promise<void> | undefined;
  let boardError = false;
  let criterionError: string | undefined;
  const epicWrites: Array<{ method: string; path: string; body: unknown }> = [];
  let nextCriterion = 3;
  const renumber = (epicId: string) => criteria.filter((c) => c.epic_id === epicId)
    .sort((a, b) => a.position - b.position).forEach((c, i) => { c.position = i + 1; });
  const sorted = () => [...criteria].sort((a, b) => a.position - b.position);
  function epicSummary(epic: S["Epic"]): S["Epic"] {
    const ts = tickets.filter((t) => t.epic?.id === epic.id && t.status !== "canceled");
    return { ...epic, tickets_total: ts.length, tickets_open: ts.filter((t) => t.status !== "done").length,
      points_total: ts.reduce((n, t) => n + (t.estimate_points ?? 0), 0),
      points_done: ts.filter((t) => t.status === "done").reduce((n, t) => n + (t.estimate_points ?? 0), 0),
      criteria_total: criteria.filter((c) => c.epic_id === epic.id).length,
      criteria_done: criteria.filter((c) => c.epic_id === epic.id && c.done).length };
  }
  function reviewOf(epicId: string) {
    const r = tickets.find((x) => x.epic?.id === epicId && x.epic_review);
    return r ? { review: { id: r.id, key: r.key, title: r.title, status: r.status, priority: r.priority } satisfies S["WorkTicket"] } : {};
  }
  function summary(t: S["Ticket"]): S["TicketSummary"] {
    return { id: t.id, key: t.key, project_key: t.project.key, title: t.title, status: t.status, priority: t.priority,
      assignee: t.assignee, epic: t.epic, labels: t.labels, estimate_points: t.estimate_points, updated_at: t.updated_at, pr: t.pr,
      unmet_dependencies: t.blocked_by.filter((b) => b.status !== "done").length,
      criteria_total: t.criteria.length, criteria_done: t.criteria.filter((c) => c.done).length };
  }
  async function handle(route: Route) {
    const request = route.request();
    const url = new URL(request.url());
    const path = url.pathname.replace(/^\/api\/v1/, "");
    const json = (data: unknown, status = 200) => route.fulfill({ status, json: data });
    if (path === "/bootstrap") return json({
      workspace: { id: "workspace", name: "Vesper", slug: "lazyagents" },
      me: { id: "user", name: "Liam", email: "liam@example.com", initials: "LM", role_title: "Owner" },
      users: [], agents: [builder, reviewer], epics: epics.map(epicSummary), projects, labels: [],
      counts,
    } satisfies S["Bootstrap"]);
    if (path === "/epics" && request.method() === "GET") return json({ epics: epics.map((e, i) => {
      const ts = tickets.filter((t) => t.epic?.id === e.id && t.status !== "canceled");
      const count = (s: S["TicketStatus"]) => ts.filter((t) => t.status === s).length;
      return { epic: epicSummary(e), project, objective: i ? "Other work" : "Ship the board", agents: [], agent_seconds: 0,
        ...(i ? { target_date: "2026-01-15" } : { owner: { id: "user", name: "Liam", initials: "LM" }, start_date: "2026-11-01", target_date: "2099-12-01" }),
        counts: { total: ts.length, backlog: count("backlog"), todo: count("todo"), in_progress: count("in_progress"), in_review: count("in_review"), done: count("done") },
        tickets: ts.map((t) => ({ id: t.id, key: t.key, title: t.title, status: t.status, priority: t.priority })) };
    }) } satisfies S["EpicOverviewList"]);
    if (path === "/tickets" && request.method() === "GET") return json({ tickets: tickets.filter((t) => !url.searchParams.get("epic") || t.epic?.id === url.searchParams.get("epic")).map(summary) });
    if (path === "/inbox" && request.method() === "GET") return json({ items: inbox });
    const decided = path.match(/^\/approvals\/([^/]+)\/(approve|deny)$/);
    if (decided && request.method() === "POST") {
      decisions.push({ id: decided[1], decision: decided[2] });
      const item = inbox.find((i) => i.id === `approval:${decided[1]}`);
      if (item) item.resolved = true;
      return json({});
    }
    if (path === "/persona-dock") return json({ personas: [], harnesses: [] });
    // The companion's work chat, mounted beside every page with no panel of its own: no chats yet.
    if (path === "/dock-chats" && request.method() === "GET") return json({ chats: [] });
    if (path === "/custom-apps" && request.method() === "GET") return json({ apps: [] });
    if (path === "/chat-models") return json([]);
    if (path === "/runner") return json(runner);
    // Sidebar settings dot (LAZYAGENTS-44): both harness keys set, so no dot.
    if (path === "/secrets") return json({ key_configured: true, known: [], secrets: ["harness:anthropic", "harness:openai"].map((name, i) => ({ id: `secret-${i}`, name, created_at: "2026-11-01T00:00:00Z", updated_at: "2026-11-01T00:00:00Z" })) });
    if (path === "/personas" && request.method() === "GET") return json({ personas: [] });
    if (path === "/memories" && request.method() === "GET") return json({ memories: [], total: 0, has_more: false });
    // Saved views: per person, names unique ignoring case (409).
    if (path === "/saved-views" && request.method() === "GET") return json({ views: [...savedViews].sort((a, b) => a.name.localeCompare(b.name)) });
    const view = savedViews.find((v) => path === `/saved-views/${v.id}`);
    if ((path === "/saved-views" && request.method() === "POST") || (view && request.method() === "PATCH")) {
      const body = request.postDataJSON() as Partial<S["SavedViewInput"]>;
      const name = body.name?.trim();
      if (name && savedViews.some((v) => v !== view && v.name.toLowerCase() === name.toLowerCase())) {
        return json({ code: "conflict", message: "You already have a view with that name", field: "name" }, 409);
      }
      if (view) {
        Object.assign(view, name ? { name } : {}, body.query !== undefined ? { query: body.query } : {});
        return json(view);
      }
      const created = { id: `view-${savedViews.length + 1}`, name: name ?? "", query: body.query ?? "", created_at: stamp(1), updated_at: stamp(1) };
      savedViews.push(created);
      return json(created, 201);
    }
    if (view && request.method() === "DELETE") {
      savedViews.splice(savedViews.indexOf(view), 1);
      return route.fulfill({ status: 204 });
    }
    if (/^\/projects\/(WEB|OPS)\/board$/.test(path)) {
      boardRequests.push(request.url());
      if (boardError) return json({ code: "internal", message: "Board service unavailable" }, 501);
      const p = path.includes("/OPS/") ? ops : project;
      const epic = epics.find((e) => e.id === url.searchParams.get("epic"));
      const cards = tickets.filter((t) => t.project.key === p.key && (!epic || t.epic?.id === epic.id)
        && (!url.searchParams.get("assignee") || t.assignee?.handle === url.searchParams.get("assignee")));
      return json({ project: p, columns: statuses.filter((s) => s !== "canceled" || url.searchParams.get("include_canceled") === "true").map((status) => {
        const all = cards.filter((t) => t.status === status);
        const capped = status === "done" || status === "canceled";
        return { status, cards: (capped ? all.slice(-50) : all).map(summary), count: all.length,
          points: all.reduce((n, t) => n + (t.estimate_points ?? 0), 0), truncated: capped && all.length > 50 };
      }), ...(epic ? { epic: { epic: epicSummary(epic), ...reviewOf(epic.id), criteria: sorted().filter((c) => c.epic_id === epic.id),
        done_blockers: { open_tickets: tickets.filter((t) => t.epic?.id === epic.id && !["done", "canceled"].includes(t.status)).map((t) => t.key),
          unchecked_criteria: criteria.filter((c) => c.epic_id === epic.id && !c.done).map((c) => c.position) } } } : {}) } satisfies S["Board"]);
    }
    const epicPatch = epics.find((e) => path === `/epics/${e.id}`);
    if (epicPatch && request.method() === "PATCH") {
      const body = request.postDataJSON() as { status?: S["EpicStatus"] };
      epicWrites.push({ method: "PATCH", path, body });
      if (body.status === "done") {
        // Mirrors server/internal/tracker/epics.go: message only, state unchanged.
        const unchecked = sorted().filter((c) => c.epic_id === epicPatch.id && !c.done).map((c) => c.position);
        const open = tickets.filter((t) => t.epic?.id === epicPatch.id && !["done", "canceled"].includes(t.status)).map((t) => t.key);
        if (unchecked.length || open.length) return json({ code: "conflict", message: `epic has unchecked criteria [${unchecked.join(" ")}] and open tickets [${open.join(" ")}]` }, 409);
      }
      if (body.status) epicPatch.status = body.status;
      return json(epicSummary(epicPatch));
    }
    const epicReview = epics.find((e) => path === `/epics/${e.id}/review`);
    if (epicReview && request.method() === "POST") {
      epicWrites.push({ method: "POST", path, body: undefined });
      if (epicReview.status === "done") return json({ code: "conflict", message: "epic is done" }, 409);
      let r = tickets.find((x) => x.epic?.id === epicReview.id && x.epic_review);
      if (!r) {
        r = make(tickets.length + 1, "backlog", `Final review: ${epicReview.name}`, { epic_review: true, epic: { id: epicReview.id, name: epicReview.name } });
        tickets.push(r);
      }
      return json({ id: r.id, key: r.key, title: r.title, status: r.status, priority: r.priority } satisfies S["WorkTicket"]);
    }
    const epicCriteria = epics.find((e) => path === `/epics/${e.id}/criteria`);
    if (epicCriteria && request.method() === "POST") {
      const body = request.postDataJSON() as { text: string };
      epicWrites.push({ method: "POST", path, body });
      if (criterionError) return json({ code: "invalid", message: criterionError, field: "text" }, 422);
      const created = { id: `criterion-${nextCriterion++}`, epic_id: epicCriteria.id, position: criteria.filter((c) => c.epic_id === epicCriteria.id).length + 1, text: body.text, done: false };
      criteria.push(created);
      return json(created, 201);
    }
    const criterion = criteria.find((c) => path === `/epic-criteria/${c.id}`);
    if (criterion && ["PATCH", "DELETE"].includes(request.method())) {
      const body = request.method() === "PATCH" ? request.postDataJSON() as { text?: string; done?: boolean; position?: number } : undefined;
      epicWrites.push({ method: request.method(), path, body });
      const hold = gate; gate = undefined;
      if (hold) await hold;
      if (criterionError) return json({ code: "conflict", message: criterionError }, 409);
      if (!body) {
        criteria.splice(criteria.indexOf(criterion), 1);
        renumber(criterion.epic_id);
        return route.fulfill({ status: 204 });
      }
      if (body.text !== undefined) criterion.text = body.text;
      if (body.done !== undefined) {
        criterion.done = body.done;
        Object.assign(criterion, body.done ? { checked_by: { type: "user", id: "user", name: "Liam" }, checked_at: new Date().toISOString() } : { checked_by: undefined, checked_at: undefined });
      }
      if (body.position !== undefined) {
        const siblings = sorted().filter((c) => c.epic_id === criterion.epic_id && c !== criterion);
        siblings.splice(body.position - 1, 0, criterion);
        siblings.forEach((c, i) => { c.position = i + 1; });
      }
      return json(criterion);
    }
    const t = tickets.find((t) => path === `/tickets/${t.key}`);
    if (t && request.method() === "GET") return json(t);
    if (t && request.method() === "PATCH") {
      const body = request.postDataJSON() as S["TicketPatch"];
      patches.push({ key: t.key, body });
      const hold = gate; gate = undefined;
      if (hold) await hold;
      const reject = rejection; rejection = undefined;
      if (reject) return json({ code: reject.status === 409 ? "conflict" : "invalid", message: reject.message, ...(reject.field && { field: reject.field }) }, reject.status);
      if (body.revision !== t.revision) return json({ code: "conflict", message: "Revision changed elsewhere", field: "revision" }, 409);
      if (body.criteria && JSON.stringify(body.criteria.expected) !== JSON.stringify(t.criteria)) {
        return json({ code: "conflict", message: "Criteria changed elsewhere", field: "criteria" }, 409);
      }
      if (body.title !== undefined) t.title = body.title;
      if (body.description_md !== undefined) t.description_md = body.description_md;
      if (body.status !== undefined) t.status = body.status;
      if (body.priority !== undefined) t.priority = body.priority;
      if (body.epic_id !== undefined) { const e = epics.find((x) => x.id === body.epic_id); t.epic = e ? { id: e.id, name: e.name } : undefined; }
      if (body.assignee_agent_id !== undefined) t.assignee = [builder, reviewer].find((a) => a.id === body.assignee_agent_id);
      if ("estimate_points" in body) {
        t.estimate_points = body.estimate_points ?? undefined;
        t.estimated_by = body.estimate_points == null ? undefined : me;
      }
      if (body.criteria) {
        t.criteria = body.criteria.items.map((item, i) => ({ id: item.id ?? `criterion-new-${++newCriterionId}`, position: i + 1, text: item.text, done: item.done }));
      }
      Object.assign(t, { revision: t.revision + 1, updated_at: stamp(t.revision + 1) });
      return json(t);
    }
    // Ticket criteria have their own endpoints and never bump the ticket revision.
    const owner = tickets.find((t) => path === `/tickets/${t.key}/criteria`);
    if (owner && request.method() === "POST") {
      criteriaRequests.push(`POST ${path}`);
      const c = { id: `crit-${owner.key}-${owner.criteria.length + 1}-${Date.now()}`, position: owner.criteria.length + 1, text: (request.postDataJSON() as { text: string }).text, done: false };
      owner.criteria.push(c);
      return json(c, 201);
    }
    const crit = path.startsWith("/criteria/") && tickets.flatMap((t) => t.criteria.map((c) => ({ t, c }))).find(({ c }) => path === `/criteria/${c.id}`);
    if (crit && request.method() === "PATCH") {
      criteriaRequests.push(`PATCH ${path}`);
      const body = request.postDataJSON() as { done?: boolean; text?: string };
      if (body.done !== undefined) crit.c.done = body.done;
      if (body.text !== undefined) crit.c.text = body.text;
      return json(crit.c);
    }
    if (crit && request.method() === "DELETE") {
      criteriaRequests.push(`DELETE ${path}`);
      crit.t.criteria = crit.t.criteria.filter((c) => c !== crit.c).map((c, i) => ({ ...c, position: i + 1 }));
      return route.fulfill({ status: 204 });
    }
    const menu = menuResponse(request.method(), path);
    if (menu) return json(menu);
    // Runs' header shows the last 7 days' spend.
    if (path === "/inbox" && request.method() === "GET") return json({ items: [] });
    if (path === "/costs" && request.method() === "GET") {
      const none = { key: "", label: "", runs: 0, tokens: 0, cost_micros: 0, unpriced_runs: 0 };
      return json({ total: none, unpriced_runs: 0, estimated: { tickets: 0, points: 0, cost_micros: 0 }, days: [], agents: [], projects: [], models: [], purposes: [], top_tickets: [] } satisfies S["CostReport"]);
    }
    unhandled.push(`${request.method()} ${path}`);
    return json({ code: "not_found", message: `mock: no handler for ${path}` }, 404);
  }
  await page.addInitScript(() => {
    const streams: Array<{ onmessage?: (e: { data: string }) => void }> = [];
    class FakeEventSource {
      onopen?: () => void;
      onmessage?: (e: { data: string }) => void;
      constructor() { streams.push(this); setTimeout(() => this.onopen?.(), 0); }
      close() { const index = streams.indexOf(this); if (index >= 0) streams.splice(index, 1); }
    }
    Object.assign(window, { EventSource: FakeEventSource, __boardStreams: streams });
  });
  await page.route("**/api/v1/**", handle);
  return {
    epics, tickets, criteria, patches, projects, counts, runner, boardRequests, unhandled, epicWrites, criteriaRequests, savedViews, inbox, decisions,
    failCriteria: (message?: string) => { criterionError = message; },
    rejectNext: (status: number, message: string, field?: string) => { rejection = { status, message, field }; },
    failBoard: (fail: boolean) => { boardError = fail; },
    holdNextPatch: () => { let release!: () => void; gate = new Promise<void>((resolve) => { release = resolve; }); return release; },
    editTicket: (key: string, patch: Partial<S["Ticket"]>) => {
      const ticket = tickets.find((t) => t.key === key)!;
      Object.assign(ticket, patch, { revision: ticket.revision + 1, updated_at: stamp(ticket.revision + 1) });
    },
    emit: (type: string) => page.evaluate((type) => {
      const streams = (window as unknown as { __boardStreams: Array<{ onmessage?: (e: { data: string }) => void }> }).__boardStreams;
      for (const stream of streams) stream.onmessage?.({ data: JSON.stringify({ type, ids: [] }) });
    }, type),
  };
}
