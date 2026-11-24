// Pure logic for the chat screen (LAZYAGENTS-57): the live activity line, when a model switch asks first, and reply cost.
// Kept free of React so `npm run test:unit` covers it.

import { secretCall } from "./secrets-ui.ts";

export type RunEventLike = { seq: number; type: string; at: string; payload: Record<string, unknown> };
export type ToolCall = { key: number; tool: string; input: unknown; done: boolean; output?: string; failed?: true };

const str = (v: unknown) => (v == null ? "" : typeof v === "string" ? v : JSON.stringify(v));
const isSubagentEvent = (p: Record<string, unknown>) => p.subagent === true;

/**
 * Tool calls since `since` (the turn's user message) and up to `until` (the next one),
 * each marked done once its result arrives.
 */
export function toolCalls(events: RunEventLike[] | undefined, since?: string, until?: string): ToolCall[] {
  const t = since ? Date.parse(since) : 0;
  const hi = until ? Date.parse(until) : Infinity;
  const out: ToolCall[] = [];
  const open = new Map<string, number>();
  for (const e of events ?? []) {
    const at = Date.parse(e.at);
    if (at < t || at > hi) continue;
    const p = e.payload;
    if (isSubagentEvent(p)) continue;
    if (e.type === "tool_call") {
      if (p.id) open.set(str(p.id), out.length);
      out.push({ key: e.seq, tool: str(p.tool), input: p.input, done: false });
    } else if (e.type === "tool_result" && p.id && open.has(str(p.id))) {
      const call = out[open.get(str(p.id))!];
      call.done = true;
      if (p.output) call.output = str(p.output);
      if (p.is_error) call.failed = true;
    }
  }
  return out;
}

/**
 * The running turn's opening line: the assistant's first text since `since`, but only
 * once a tool call follows it. A turn that answers straight away has no tool call, so
 * its text is the reply itself and isn't shown early.
 */
export function interimLine(events: RunEventLike[] | undefined, since?: string): string | undefined {
  const t = since ? Date.parse(since) : 0;
  let line: string | undefined;
  for (const e of events ?? []) {
    if (Date.parse(e.at) < t) continue;
    const p = e.payload;
    if (e.type === "message" && line === undefined && p.role === "assistant" && !p.kind) {
      const text = str(p.text).trim();
      if (text) line = text;
    } else if (e.type === "tool_call" && line !== undefined) {
      return clip(line, 280);
    }
  }
  return undefined;
}

type MessageLike = { id: string; role: string; created_at: string; run_id?: string; turn_seq?: number };

/** One turn's event window; `followup` marks a turn no person's message started (the image follow-up). */
export type TurnWindow = { since?: string; until?: string; followup: boolean };

/**
 * Each turn's last assistant reply gets the window of events between the turn's start
 * and the next one's, so a turn's memory notices show once, under its answer. A turn
 * starts at a user message, or right after an earlier turn's reply when the assistant
 * replies again on its own (a different run turn, e.g. reacting to generated images).
 */
export function turnWindows(list: MessageLike[] | undefined): Map<string, TurnWindow> {
  const out = new Map<string, TurnWindow>();
  let since: string | undefined;
  let reply: MessageLike | undefined;
  let followup = false;
  const close = (until?: string) => reply && out.set(reply.id, { since, until, followup });
  const turnOf = (m: MessageLike) => (m.turn_seq === undefined ? undefined : `${m.run_id}:${m.turn_seq}`);
  for (const m of list ?? []) {
    if (m.role === "user") {
      // Mid-turn steer messages carry no run/turn until a fallback turn claims them; keep the active turn's window open.
      if (!reply && since !== undefined && m.run_id === undefined && m.turn_seq === undefined) continue;
      close(m.created_at);
      since = m.created_at;
      reply = undefined;
      followup = false;
    } else if (m.role === "assistant") {
      if (reply && turnOf(m) !== undefined && turnOf(reply) !== undefined && turnOf(m) !== turnOf(reply)) {
        close(reply.created_at);
        since = reply.created_at;
        followup = true;
      }
      reply = m;
    }
  }
  close(undefined);
  return out;
}

/**
 * Where the running turn's events start: the newest message. That is the person's
 * message for a turn they started, or the previous reply (and its notes) for a turn
 * the assistant takes on its own, so the earlier turn's opening line and tools aren't
 * shown again.
 */
export function runningSince(list: MessageLike[] | undefined): string | undefined {
  if (!list?.length) return undefined;
  let i = list.length - 1;
  if (list[i].role === "user") {
    while (i > 0 && list[i - 1].role === "user" && list[i].run_id === undefined && list[i].turn_seq === undefined) {
      i--;
    }
  }
  return list[i].created_at;
}

/** "mcp__lazyagents__read_page" (Claude) and "read_page" (Codex) are the same tool. */
export function bareTool(tool: string): string {
  const mcp = /^mcp__(.+?)__(.+)$/.exec(tool);
  if (mcp) return mcp[1] === "lazyagents" ? mcp[2] : `${mcp[1]}.${mcp[2]}`;
  return /^lazyagents[._]/.test(tool) ? tool.slice("lazyagents.".length) : tool;
}

/** A tool from one of the person's MCP connectors: harnesses name it mcp__slug__tool or slug.tool. */
export function connectorCall(tool: string): { name: string; tool: string } | null {
  const m = /^mcp__([a-z][a-z0-9-]*)__(.+)$/.exec(tool) ?? /^([a-z][a-z0-9-]*)\.([^.]+)$/.exec(tool);
  if (!m || m[1] === "lazyagents") return null;
  return { name: m[1].split("-").map((w) => w.charAt(0).toUpperCase() + w.slice(1)).join(" "), tool: m[2] };
}

/** What the live line says: a verb, then a [[ref]] to link or plain text. */
export type Activity = { verb: string; ref?: string; label?: string; text?: string };

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
const clip = (s: string, n = 60) => (s.length > n ? `${s.slice(0, n - 1)}…` : s);

/** A page name without its folders, with the section: "Arch/ADR - X#risks" → "ADR - X › risks". */
export function linkLabel(ref: string): string {
  const i = ref.indexOf("#");
  const target = i < 0 ? ref : ref.slice(0, i);
  const anchor = i < 0 ? "" : ref.slice(i + 1);
  const name = target.split("/").filter(Boolean).pop() ?? "";
  if (!anchor) return name || target;
  return name ? `${name} › ${anchor}` : anchor;
}

/** The newest tool call in words: "Reading [[ADR - Project chat sessions]]", "Searching “ledger”". */
export function activityOf(call: { tool: string; input: unknown }): Activity {
  const o = (call.input && typeof call.input === "object" ? call.input : {}) as Record<string, unknown>;
  const s = (k: string) => (typeof o[k] === "string" ? (o[k] as string).trim() : "");
  const link = (verb: string, raw: string, fallback: string): Activity => {
    const ref = raw.replace(/^\[\[/, "").replace(/\]\]$/, "").split("|")[0].trim();
    return ref ? { verb, ref, label: clip(linkLabel(ref)) } : { verb: fallback };
  };
  switch (bareTool(call.tool)) {
    case "read_page":
      return link("Reading", s("ref"), "Reading a page");
    case "read_artifact": {
      const a = s("artifact");
      // An artifact id doesn't resolve as a link; ADR ids and titles do.
      if (!a || UUID.test(a)) return { verb: "Reading an artifact" };
      return link("Reading", s("section") ? `${a}#${s("section")}` : a, "Reading an artifact");
    }
    case "get_ticket":
      return link("Opening", s("ticket"), "Opening a ticket");
    case "get_backlinks":
      return link("Finding links to", s("ref"), "Finding links");
    case "search_knowledge":
      return s("q") ? { verb: "Searching", text: `“${clip(s("q"))}”` } : { verb: "Searching the knowledge base" };
    case "find_pattern":
      return s("q") ? { verb: "Looking up patterns for", text: `“${clip(s("q"))}”` } : { verb: "Looking up patterns" };
    case "WebSearch":
    case "web_search":
      return s("query") ? { verb: "Searching the web for", text: `“${clip(s("query"))}”` } : { verb: "Searching the web" };
    case "WebFetch": {
      let host = s("url");
      try {
        host = new URL(host).hostname.replace(/^www\./, "");
      } catch {}
      return host ? { verb: "Reading", text: clip(host) } : { verb: "Reading a web page" };
    }
    case "whoami":
      return { verb: "Checking its instructions" };
    case "shell":
    case "Bash":
      return { verb: "Running a command" };
    default: {
      const secret = secretCall(call.tool, call.input);
      if (secret?.tool === "http_request") return { verb: `Using ${secret.handle || "a secret"}:`, text: clip(`${secret.method} ${secret.target}`) };
      if (secret) return { verb: "Checking which secrets it can use" };
      const connector = connectorCall(call.tool);
      if (connector) return { verb: `Using ${connector.name}:`, text: connector.tool };
      return { verb: "Using", text: bareTool(call.tool) || "a tool" };
    }
  }
}

/**
 * Switching to another harness ends the session (the ADR's handoff), so it asks
 * first. A model change on the same harness keeps the session, an empty chat has
 * no session to lose, and a switch already confirmed for that harness doesn't ask again.
 */
export function needsSwitchConfirm(
  current: { harness: string },
  next: { harness: string },
  pending: { harness: string } | null | undefined,
  messageCount: number,
): boolean {
  return messageCount > 0 && next.harness !== current.harness && pending?.harness !== next.harness;
}

/** A reply's cost; small turns keep three decimals so they don't read $0.00. Unknown or unpriced is undefined, never free. */
export function replyCost(cost: number | undefined): string | undefined {
  if (cost === undefined || !Number.isFinite(cost) || cost <= 0) return undefined;
  if (cost < 0.001) return "< $0.001";
  return `$${cost.toFixed(cost < 1 ? 3 : 2)}`;
}

/** A chat's display title: a new conversation has none until the first turn names it. */
export function chatTitle(c: { title: string }): string {
  return c.title.trim() || "New conversation";
}

/**
 * A history row's dot: running wins over an unread reply. The open chat is never unread, since
 * it is marked read on screen (that keeps a reply landing there from flashing a dot).
 */
export function rowMark(c: { state: string; unread?: number }, open = false): "running" | "unread" | null {
  if (c.state === "running") return "running";
  return !open && (c.unread ?? 0) > 0 ? "unread" : null;
}

/** The most recently active chat: by its last message, else when it last changed. */
export function newestChat<T extends { last_message_at?: string | null; updated_at: string }>(chats: T[] | undefined): T | undefined {
  const t = (c: T) => Date.parse(c.last_message_at ?? c.updated_at);
  return chats?.reduce<T | undefined>((a, c) => (!a || t(c) > t(a) ? c : a), undefined);
}

export type DayGroup<T> = { label: "Today" | "Yesterday" | "Earlier"; chats: T[] };

/** The history list's sections, by the local day of each chat's last activity; keeps the input order inside each. */
export function groupByDay<T extends { last_message_at?: string | null; created_at: string }>(chats: readonly T[], now = Date.now()): DayGroup<T>[] {
  const today = new Date(now);
  today.setHours(0, 0, 0, 0);
  const startToday = today.getTime();
  const startYesterday = new Date(today.getFullYear(), today.getMonth(), today.getDate() - 1).getTime();
  const groups: DayGroup<T>[] = [
    { label: "Today", chats: [] },
    { label: "Yesterday", chats: [] },
    { label: "Earlier", chats: [] },
  ];
  for (const c of chats) {
    const t = Date.parse(c.last_message_at ?? c.created_at);
    groups[t >= startToday ? 0 : t >= startYesterday ? 1 : 2].chats.push(c);
  }
  return groups.filter((g) => g.chats.length > 0);
}

// ---- the chat tab's status line: what the persona is doing, at a glance ----

/** The kind of work under way, which picks the status card's animated scene. */
export type ChatStatusKind =
  | "thinking"
  | "next-step"
  | "writing-reply"
  | "connector"
  | "secret"
  | "wiki"
  | "tickets"
  | "ticket-lookup"
  | "reading-code"
  | "searching-code"
  | "writing-code"
  | "tests"
  | "build"
  | "install"
  | "terminal"
  | "github"
  | "commit"
  | "push"
  | "pull-request"
  | "repo-history"
  | "web"
  | "web-page"
  | "video"
  | "image"
  | "image-view"
  | "canvas"
  | "canvas-comment"
  | "design"
  | "design-view"
  | "playground"
  | "runs"
  | "workflow"
  | "memory"
  | "memory-save"
  | "chat-history"
  | "repo-search"
  | "repo-attach"
  | "video-render"
  | "audio-render"
  | "finance"
  | "finance-sort"
  | "persona"
  | "schedule"
  | "learning"
  | "research"
  | "space"
  | "saved-links"
  | "projects"
  | "library"
  | "inbox"
  | "chart"
  | "diagram"
  | "app"
  | "custom-app"
  | "database"
  | "http"
  | "pdf"
  | "subagent"
  | "choices";
export type ChatStatusInfo = { kind: ChatStatusKind; phrase: string };

const status = (kind: ChatStatusKind, phrase: string): ChatStatusInfo => ({ kind, phrase });

// Options may sit between `git` and its subcommand: "git -C /repo push".
const GIT = String.raw`\bgit(?:\s+-c\s+\S+|\s+--\S+)*\s+`;
const GIT_PUSH = new RegExp(`${GIT}push\\b`);
const GIT_COMMIT = new RegExp(`${GIT}commit\\b`);
const GIT_OTHER = new RegExp(`${GIT}(add|am|apply|blame|branch|checkout|cherry-pick|clone|diff|fetch|init|log|ls-files|merge|merge-base|pull|rebase|remote|reset|restore|rev-list|rev-parse|revert|rm|show|stash|status|submodule|switch|tag|worktree)\\b`);

/**
 * A shell command as a kind of work, never the command itself: the chat tab says
 * "running tests", the Activity tab keeps the exact command.
 */
function shellStatus(command: string): ChatStatusInfo {
  // Codex runs everything through a login shell: /bin/zsh -lc 'cat x'.
  const c = command.toLowerCase().replace(/^(\S*\/)?(ba|z)?sh\s+-l?c\s+['"]?/, "");
  if (/\.lazyagents\/outbox/.test(c)) return status("image", "saving the image");
  if (GIT_PUSH.test(c)) return status("push", "pushing its branch");
  if (GIT_COMMIT.test(c)) return status("commit", "committing changes");
  if (/\bgh\s+pr\b/.test(c)) return status("pull-request", "preparing a pull request");
  if (/\bgh\s+\S/.test(c)) return status("github", "working on GitHub");
  if (/\b(go\s+test|npm\s+(run\s+)?test|pnpm\s+(run\s+)?test|yarn\s+test|pytest|jest|vitest|cargo\s+test|make\s+test|rspec|playwright\s+test|mvn\s+test|gradle\w*\s+test)\b/.test(c)) return status("tests", "running tests");
  if (/\b(npm\s+(ci|install|i)|pnpm\s+install|yarn(\s+install)?\s*$|go\s+mod\s+(download|tidy)|pip\s+install|bundle\s+install|cargo\s+fetch)\b/.test(c)) return status("install", "installing dependencies");
  if (/\b(go\s+(build|vet)|npm\s+run\s+(build|lint|typecheck)|tsc\b|cargo\s+(build|check|clippy)|make\b|eslint|gofmt)\b/.test(c)) return status("build", "checking the build");
  if (GIT_OTHER.test(c)) return status("repo-history", "looking over the repository");
  if (/^\s*(find|rg|grep|fd)\b|\|\s*(rg|grep)\b/.test(c)) return status("searching-code", "searching the code");
  if (/^\s*(cat|less|head|tail|ls|tree|sed\s+-n|wc|awk)\b|\|\s*(head|tail)\b/.test(c)) return status("reading-code", "reading the code");
  return status("terminal", "working in the terminal");
}

/** An MCP GitHub tool, from any server name: "github.create_pull_request", "plugin_github_github.get_issue". */
function githubToolStatus(tool: string): ChatStatusInfo | undefined {
  if (!/(^|[._-])github[._-]/i.test(tool)) return undefined;
  if (/(create|update|merge)\w*pull_?request/i.test(tool)) return status("pull-request", "preparing a pull request");
  return status("github", "working on GitHub");
}

/** A rich block being written into the reply, reported by the harness: no tool runs, but it can take a while. */
const REPLY_BLOCK = "reply_block";
const PLAN_STATE = "plan";
const REPLY_BLOCK_STATUS: Record<string, ChatStatusInfo> = {
  app: status("app", "building an interactive app"),
  "svg-image": status("image", "drawing an image"),
  "svg-steps": status("image", "drawing a step-through"),
  chart: status("chart", "drawing a chart"),
  mermaid: status("diagram", "drawing a diagram"),
  choices: status("choices", "laying out your options"),
  "workflow-run": status("workflow", "lining up a workflow"),
  recommend: status("web", "picking something for you to look at"),
  pdf: status("pdf", "attaching a PDF"),
};

/** The running turn's tool calls and the rich blocks written between them, in order, for the chat tab. */
export function chatCalls(events: RunEventLike[] | undefined, since?: string, until?: string): ToolCall[] {
  const t = since ? Date.parse(since) : 0;
  const hi = until ? Date.parse(until) : Infinity;
  const blocks = (events ?? [])
    .filter((e) => e.type === "lifecycle" && e.payload.state === REPLY_BLOCK && Date.parse(e.at) >= t && Date.parse(e.at) <= hi)
    .map((e): ToolCall => ({ key: e.seq, tool: REPLY_BLOCK, input: { kind: e.payload.kind }, done: true }));
  return [...toolCalls(events, since, until), ...blocks].sort((a, b) => a.key - b.key);
}

/** The turn's checklist as the server last sent it: every step, whichever harness wrote it. `seq` places it among the calls. */
export type PlanSnapshot = { seq: number; items: PlanItem[] };

/**
 * Every plan the server sent in this window, oldest first: `lifecycle` events with `state: "plan"`, which the runner
 * emits for Claude Code's TodoWrite and tasks, Codex's own plan, and Vesper's `set_plan` alike. Turns from before
 * the server sent them have none, and their plan is read from the calls instead (planVersions).
 */
export function planSnapshots(events: RunEventLike[] | undefined, since?: string, until?: string): PlanSnapshot[] {
  const t = since ? Date.parse(since) : 0;
  const hi = until ? Date.parse(until) : Infinity;
  const out: PlanSnapshot[] = [];
  for (const e of events ?? []) {
    if (e.type !== "lifecycle" || e.payload.state !== PLAN_STATE || isSubagentEvent(e.payload)) continue;
    const at = Date.parse(e.at);
    if (at < t || at > hi) continue;
    const items = records(e.payload.steps)
      .filter((step) => str(step.title).trim())
      .map((step, i): PlanItem => ({ id: str(step.id) || String(i + 1), title: str(step.title), state: planState(step.status) }));
    out.push({ seq: e.seq, items });
  }
  return out;
}

/**
 * One tool call as a kind of work and a short, high-level phrase for the chat tab
 * ("reading the code", "looking through the wiki"): no queries, paths, refs or commands,
 * which stay in the Activity tab. The phrase completes "<Persona> is …".
 */
export function chatStatusOf(call: { tool: string; input: unknown }): ChatStatusInfo {
  const o = (call.input && typeof call.input === "object" ? call.input : {}) as Record<string, unknown>;
  const tool = bareTool(call.tool);
  switch (tool) {
    case "read_page":
    case "read_artifact":
    case "get_backlinks":
    case "search_knowledge":
    case "find_pattern":
      return status("wiki", "looking through the wiki");
    case "librarian_pass":
    case "daily_note":
    case "import_vault":
    case "list_pages":
    case "page_outline":
    case "patch_page":
    case "set_properties":
    case "create_page":
    case "capture_note":
    case "suggest_links":
    case "write_note":
      return status("wiki", "writing a wiki note");
    case "move_page":
    case "move_folder":
      return status("wiki", "moving pages");
    case "delete_page":
    case "delete_folder":
      return status("wiki", "deleting pages");
    case "file_capture":
      return status("wiki", "filing a note");
    case "list_page_versions":
    case "list_page_reviews":
    case "knowledge_graph":
    case "list_imports":
      return status("wiki", "looking through the wiki");
    case "restore_page_version":
      return status("wiki", "restoring an earlier version");
    case "attach_file":
      return status("wiki", "attaching a file");
    case "withdraw_suggestion":
      return status("wiki", "withdrawing a suggestion");
    case "set_page_controls":
      return status("wiki", "changing a page's settings");
    case "attach_chat_to_page":
    case "promote_canvas":
      return status("wiki", "saving to Knowledge");
    case "confirm_import":
    case "cancel_import":
    case "undo_import":
      return status("wiki", "working on a vault import");
    case "get_ticket":
    case "list_epics":
    case "list_tickets":
      return status("ticket-lookup", "checking tickets");
    case "list_projects":
      return status("projects", "looking over your projects");
    case "get_epic":
      return status("ticket-lookup", "checking an epic");
    case "create_ticket":
    case "create_epic":
      return status("tickets", "drafting a ticket");
    case "update_ticket":
    case "comment_ticket":
    case "update_ticket_blockers":
      return status("tickets", "updating a ticket");
    case "update_epic":
      return status("tickets", "updating an epic");
    case "list_runs":
    case "get_run":
      return status("runs", "checking on runs");
    case "reply_to_run":
      return status("runs", "replying to a run");
    case "search_memory":
    case "read_memory":
      return status("memory", "recalling what it knows about you");
    case "save_memory":
    case "update_memory":
      return status("memory-save", "making a note");
    case "forget_memory":
      return status("memory", "forgetting that");
    case "search_chats":
      return status("chat-history", "looking back through your past chats");
    case "read_chat":
      return status("chat-history", "rereading an earlier chat");
    case "set_chat_title":
      return status("thinking", "naming the conversation");
    case "WebSearch":
    case "web_search":
    case "websearch":
      return status("web", "searching the web");
    case "WebFetch":
    case "webfetch":
      return status("web-page", "reading a page");
    case "browser_snapshot":
      return status("web-page", "reading the Safari tab you shared");
    case "list_saved_links":
      return status("saved-links", "checking your saved links");
    case "save_link":
      return status("saved-links", "saving a link");
    case "search_library":
      return status("library", "looking through your Library");
    case "save_file":
      return status("library", "saving a file to your Library");
    case "render_pdf":
      return status("pdf", "creating a PDF");
    case "read_library_item":
      return status("library", "opening something from your Library");
    case "list_inbox":
      return status("inbox", "checking what needs you");
    case "propose_persona":
      return status("persona", "sketching a new persona");
    case "propose_persona_character":
      return status("persona", "designing an animated character");
    case "create_space":
      return status("space", "setting up a space");
    case "create_scheduled_task":
      return status("schedule", "scheduling a task");
    case "list_scheduled_tasks":
      return status("schedule", "checking your scheduled tasks");
    case "update_scheduled_task":
      return status("schedule", "changing a scheduled task");
    case "delete_scheduled_task":
      return status("schedule", "removing a scheduled task");
    case "create_learning_module":
      return status("learning", "starting a learning module");
    case "list_learning_modules":
      return status("learning", "looking over your learning modules");
    case "get_learning_progress":
      return status("learning", "checking your progress");
    case "submit_research_report":
      return status("research", "writing up its research");
    case "search_repositories":
      return status("repo-search", "looking for a repository");
    case "use_repository":
      return status("repo-attach", "checking out a repository");
    case "request_push":
      return status("push", "asking to push a branch");
    case "start_video":
      return status("video-render", "setting up a video");
    case "update_video":
      return status("video-render", "rendering a video");
    case "finish_video":
      return status("video-render", "finishing the video");
    case "fail_video":
      return status("video-render", "reporting a failed render");
    case "start_audio":
      return status("audio-render", "setting up audio");
    case "generate_music":
      return status("audio-render", "generating music");
    case "update_audio":
      return status("audio-render", "rendering audio");
    case "finish_audio":
      return status("audio-render", "finishing the audio");
    case "fail_audio":
      return status("audio-render", "reporting a failed render");
    case "get_video_transcript":
      return status("video", "watching a video");
    case "canvas_list":
    case "canvas_read":
      return status("canvas", "looking at a canvas");
    case "canvas_create":
      return status("canvas", "drafting a canvas");
    case "canvas_patch":
      return status("canvas", "revising a canvas");
    case "canvas_comment":
    case "canvas_reply":
      return status("canvas-comment", "commenting on a canvas");
    case "design_flows":
      return status("design-view", "tracing a design's flow");
    case "design_list":
      return status("design-view", "looking through your designs");
    case "design_outline":
    case "design_read":
      return status("design-view", "looking at a design");
    case "design_render":
      return status("design-view", "rendering a design");
    case "design_comments":
      return status("design-view", "reading comments on a design");
    case "design_create":
      return status("design", "starting a design");
    case "design_components":
      return status("design-view", "looking at a design's components");
    case "design_tokens":
      return status("design-view", "checking a design's tokens");
    case "design_inspect":
      return status("design-view", "inspecting a design");
    case "design_link_ticket":
      return status("design", "linking a design to a ticket");
    case "design_patch":
      return status("design", "suggesting design changes");
    case "design_import":
      return status("design", "importing a diagram into a design");
    case "design_comment":
    case "design_reply":
      return status("design", "commenting on a design");
    case "start_playground":
      return status("playground", "spinning up a playground");
    case "playground_status":
      return status("playground", "checking on the playground");
    case "stop_playground":
      return status("playground", "stopping the playground");
    case "set_playground_openapi":
      return status("playground", "mapping the playground's API");
    case "propose_connector":
      return status("connector", "suggesting a connector");
    case "propose_secret":
      return status("secret", "asking for a secret");
    case "list_connectors":
      return status("connector", "checking your connectors");
    case "list_secret_names":
      return status("secret", "checking which secrets you have");
    case "list_workflows":
    case "read_workflow":
      return status("workflow", "looking over a workflow");
    case "list_custom_apps":
    case "get_custom_app":
      return status("custom-app", "inspecting a custom app");
    case "create_custom_app":
      return status("custom-app", "creating a custom app");
    case "update_custom_app":
      return status("custom-app", "updating a custom app");
    case "delete_custom_app":
      return status("custom-app", "deleting a custom app");
    case "custom_app_sql":
      return status("database", "querying app data");
    case "http_list_workspaces":
    case "http_get_workspace":
      return status("http", "checking HTTP collections");
    case "http_save_request":
      return status("http", "saving an HTTP request");
    case "http_run_request":
      return status("http", "sending an HTTP request");
    case "Agent":
    case "Task":
    case "delegate":
    case "run_subagent":
    case "run_subagents":
      return status("subagent", "delegating to a helper");
    case "claim_ticket":
    case "next_ticket":
      return status("ticket-lookup", "picking up a ticket");
    case "estimate_ticket":
    case "propose_tickets":
    case "comment":
    case "check_criterion":
    case "check_epic_criterion":
      return status("tickets", "updating ticket progress");
    case "create_artifact":
    case "propose_pattern":
    case "list_proposed_patterns":
    case "publish_pattern":
    case "reject_pattern":
      return status("wiki", "updating project knowledge");
    case "create_mockup":
      return status("design", "creating a mockup");
    case "post_plan":
    case "update_step":
      return status("next-step", "updating its plan");
    case "set_branch":
      return status("repo-history", "updating the branch");
    case "set_pr":
    case "recheck_review":
      return status("pull-request", "updating the pull request");
    case "request_approval":
    case "wait_for_approval":
    case "await_human":
    case "await_signal":
      return status("inbox", "waiting on you");
    case "submit_findings":
      return status("research", "submitting its findings");
    case "submit_outline":
    case "submit_lesson":
    case "submit_review":
      return status("learning", "building a lesson");
    case "submit_workflow_output":
      return status("workflow", "finishing a workflow step");
    case "run_gated":
      return status("secret", "running a gated action");
    case "get_prior_attempts":
      return status("runs", "reviewing prior attempts");
    case "propose_workflow_edit":
      return status("workflow", "sketching a workflow");
    case "image_generation":
    case "image_gen":
    case "generate_image":
      return status("image", "creating an image");
    case "Read":
    case "read":
    case "read_file":
      // The image follow-up opens the generated images it is about to react to.
      if (typeof o.file_path === "string" && o.file_path.includes(".lazyagents/attachments/generated/")) return status("image-view", "looking at the image");
      return status("reading-code", "reading the code");
    case "Glob":
    case "glob":
    case "Grep":
    case "grep":
      return status("searching-code", "searching the code");
    case "LS":
    case "list":
    case "list_dir":
      return status("reading-code", "reading the code");
    case "Edit":
    case "edit":
    case "MultiEdit":
    case "Write":
    case "write":
    case "NotebookEdit":
    case "apply_patch":
    case "patch":
      return status("writing-code", "writing code");
    case REPLY_BLOCK:
      return REPLY_BLOCK_STATUS[str(o.kind)] ?? status("thinking", "working on it");
    case "TodoWrite":
    case "todowrite":
    case "TaskCreate":
    case "TaskUpdate":
    case "set_plan":
      return status("thinking", "planning its next steps");
    case "shell":
    case "Bash":
    case "bash":
    case "exec_command":
    case "shell_command":
      return shellStatus(typeof o.command === "string" ? o.command : typeof o.cmd === "string" ? o.cmd : "");
    default: {
      const secret = secretCall(call.tool, o);
      if (secret) return status("secret", secret.handle ? `using ${secret.handle}` : "checking its secrets");
      const connector = connectorCall(call.tool);
      if (connector) return status("connector", `using ${connector.name}`);
      return githubToolStatus(tool) ?? status("thinking", "working on it");
    }
  }
}

const WRITING_REPLY = status("writing-reply", "drafting a reply");

/** Contextual between-steps phrases derived from the kind of step that just finished. */
const AFTER_KIND_PHRASE: Partial<Record<ChatStatusKind, string>> = {
  tests: "reviewing the test results",
  build: "checking the build output",
  install: "checking the install output",
  "reading-code": "reviewing the code",
  "searching-code": "reviewing what it found",
  terminal: "checking the command output",
  "repo-history": "reviewing the repository state",
  web: "reviewing the search results",
  "web-page": "reviewing the page",
  wiki: "reviewing the notes",
  "ticket-lookup": "reviewing the tickets",
  runs: "reviewing the run details",
};

function nextStepStatus(lastKind?: ChatStatusKind): ChatStatusInfo {
  return status("next-step", (lastKind && AFTER_KIND_PHRASE[lastKind]) ?? "planning the next step");
}

/** Live streaming phase from harness activity heartbeats (or a trailing thinking block). */
export type TurnActivityPhase = "thinking" | "writing_reply";
export type TurnActivity = { phase: TurnActivityPhase; detail?: string; at: number };

/** Mirrors Go harness.thinkingHeading for non-streaming thinking blocks (e.g. completed Codex reasoning). */
function thinkingHeading(text: string): string | undefined {
  let latest: string | undefined;
  for (const raw of text.split("\n")) {
    const s = raw.trim();
    if (!s) continue;
    let candidate = "";
    if (s.startsWith("**") && s.endsWith("**") && s.length > 4) {
      const inner = s.slice(2, -2);
      if (inner.includes("**")) continue;
      candidate = inner;
    } else {
      const m = /^#{1,3}[ \t]+(.+)$/.exec(s);
      if (!m) continue;
      candidate = m[1];
    }
    candidate = candidate.replace(/`/g, "").replace(/\s+/g, " ").trim().replace(/[:.]+$/, "").trim();
    if (candidate.length < 3 || candidate.length > 90) continue;
    if (/:\/\/|=|\/(?:Users|home|etc|var|tmp)\//.test(candidate)) continue;
    latest = clip(candidate, 64);
  }
  return latest;
}

/**
 * The newest live phase since the last tool call or reply: thinking (with optional safe heading)
 * or writing_reply. Cleared once a tool call, rich reply block, or finished assistant text lands.
 */
export function turnActivity(events: RunEventLike[] | undefined, since?: string, until?: string): TurnActivity | undefined {
  const t = since ? Date.parse(since) : 0;
  const hi = until ? Date.parse(until) : Infinity;
  let activity: TurnActivity | undefined;
  for (const e of events ?? []) {
    const at = Date.parse(e.at);
    if (at < t || at > hi) continue;
    const p = e.payload;
    if (isSubagentEvent(p)) continue;
    if (e.type === "tool_call" || e.type === "tool_result") {
      activity = undefined;
    } else if (e.type === "lifecycle" && p.state === REPLY_BLOCK) {
      activity = undefined;
    } else if (e.type === "lifecycle" && p.state === "activity" && (p.phase === "thinking" || p.phase === "writing_reply")) {
      const phase = p.phase as TurnActivityPhase;
      const raw = typeof p.detail === "string" ? p.detail.trim() : "";
      const detail = phase === "thinking" ? raw || (activity?.phase === "thinking" ? activity.detail : undefined) : undefined;
      activity = { phase, ...(detail ? { detail } : {}), at };
    } else if (e.type === "message" && p.kind === "thinking") {
      const detail = thinkingHeading(str(p.text));
      activity = { phase: "thinking", ...(detail ? { detail } : {}), at };
    } else if (e.type === "message" && p.role === "assistant" && !p.kind) {
      activity = undefined;
    }
  }
  return activity;
}

/** Tools whose in-flight call delegates work to one or more subagents. */
const SUBAGENT_DELEGATION_TOOLS = new Set(["Agent", "Task", "delegate", "run_subagent", "run_subagents"]);

function isSubagentDelegationTool(tool: string): boolean {
  return SUBAGENT_DELEGATION_TOOLS.has(bareTool(tool));
}

/**
 * Live, chat-safe summary of in-flight subagents while a parent `run_subagent`/`run_subagents`
 * call is blocking. Uses only safe high-level phrases (`chatStatusOf`) and basenames (`stepDetail`),
 * never raw commands or full paths.
 */
export function liveSubagentStatus(branches: SubagentBranch[] | undefined): { phrase: string; detail: string } | undefined {
  if (!branches?.length) return undefined;
  const total = branches.length;
  const done = branches.filter((b) => b.status === "completed" || b.status === "failed" || b.status === "canceled").length;
  const running = branches.filter((b) => b.status === "running");
  const queued = branches.filter((b) => b.status === "queued");
  const totalCalls = branches.reduce((n, b) => n + b.toolCalls, 0);

  let activeBranch: SubagentBranch | undefined;
  if (running.length > 0) {
    activeBranch = running.reduce((best, b) => {
      const bestKey = best.calls.at(-1)?.key ?? 0;
      const curKey = b.calls.at(-1)?.key ?? 0;
      if (curKey !== bestKey) return curKey > bestKey ? b : best;
      return (b.startedAt ?? b.createdAt) >= (best.startedAt ?? best.createdAt) ? b : best;
    });
  } else {
    activeBranch = queued[0] ?? branches[branches.length - 1];
  }

  const latestCall = activeBranch?.calls.at(-1);
  const latestPhrase = latestCall ? chatStatusOf(latestCall).phrase : undefined;
  const latestDetail = latestCall ? stepDetail(latestCall) : undefined;

  let phrase: string;
  if (total === 1) {
    const b = branches[0];
    const who = clip(b.role || b.agentType || "a helper", 28);
    if (b.status === "queued") {
      phrase = `starting ${who}`;
    } else if (b.status === "running") {
      phrase = latestPhrase ? `running ${who} · ${latestPhrase}` : `running ${who}`;
    } else {
      phrase = `wrapping up ${who}`;
    }
  } else if (running.length === 0 && done === 0) {
    phrase = `queuing ${total} subagents`;
  } else if (running.length === 0 && done === total) {
    phrase = `wrapping up ${total} subagents`;
  } else {
    const head = done > 0
      ? `running ${running.length} of ${total} subagents (${done} done)`
      : `running ${running.length} of ${total} subagents`;
    phrase = latestPhrase ? `${head} · ${latestPhrase}` : head;
  }

  const detailParts: string[] = [];
  if (total > 1) {
    if (done > 0) detailParts.push(`${done}/${total} done`);
    else if (running.length > 0) detailParts.push(`${running.length}/${total} running`);
    else detailParts.push(`${queued.length} queued`);
  } else if (branches[0].status === "queued") {
    detailParts.push("Queued");
  }
  if (totalCalls > 0) detailParts.push(`${totalCalls} ${totalCalls === 1 ? "call" : "calls"}`);
  if (activeBranch) {
    const who = total > 1 ? clip(activeBranch.role || activeBranch.agentType, 24) : "";
    if (latestDetail) detailParts.push(who ? `${who}: ${latestDetail}` : latestDetail);
    else if (who && activeBranch.status === "running") detailParts.push(`${who}: working`);
  }

  return { phrase, detail: detailParts.join(" · ") };
}

/**
 * The chat tab's status for a running turn: the newest call's, or "thinking" before any tool runs.
 * `between` (from turnPulse) means that call finished a while ago, so its phrase would be stale;
 * `activity` carries live streaming phases (thinking with optional heading, or drafting a reply);
 * `branches` provides live subagent progress while `run_subagent`/`run_subagents` is in flight.
 */
export function chatStatus(
  calls: { tool: string; input: unknown; done?: boolean }[],
  between = false,
  activity?: TurnActivity,
  branches?: SubagentBranch[],
): ChatStatusInfo {
  const newest = calls.at(-1);
  if (newest?.tool === REPLY_BLOCK) return chatStatusOf(newest);
  if (newest && newest.done === false) {
    if (isSubagentDelegationTool(newest.tool)) {
      const live = liveSubagentStatus(branches);
      if (live) return status("subagent", live.phrase);
    }
    return chatStatusOf(newest);
  }
  if (activity?.phase === "writing_reply") return WRITING_REPLY;
  if (!calls.length) return status("thinking", "thinking");
  if (between || (activity?.phase === "thinking" && !!activity.detail)) {
    const lastWork = calls.filter((c) => !BOOKKEEPING.has(bareTool(c.tool))).at(-1);
    return nextStepStatus(lastWork ? chatStatusOf(lastWork).kind : undefined);
  }
  return chatStatusOf(calls[calls.length - 1]);
}

// ---- the status card's clock: is the turn alive, and how long has each step taken ----

/** How long after the newest call finishes before the card stops naming it: normal round-trips shouldn't flicker. */
export const NEXT_STEP_AFTER_MS = 8_000;
/** No events for this long reads as quiet: still running, but worth a check-in. */
export const QUIET_AFTER_MS = 2 * 60_000;
/** The same while a call is still running, since tests or a build can legitimately take minutes. */
export const QUIET_RUNNING_MS = 5 * 60_000;
/** How often a long-running turn refreshes harness quota/usage data once past 60s. */
export const LONG_TURN_USAGE_REFRESH_INTERVAL_MS = 60_000;

/** Coarse timing phase of a turn for per-phase live timers and pure thinking accumulation. */
export type TurnTimingPhase = "thinking" | "tool" | "writing_reply";

/** One completed reasoning (`kind === "thinking"`) block emitted during a turn. */
export type ThinkingBlock = { seq: number; text: string; heading?: string; at: number };

/** Summary of a turn's plan checklist (any harness's, see planSnapshots) for the pinned composer bar. */
export type PlanChecklistProgress = {
  steps: ChatStep[];
  completed: number;
  failed: number;
  total: number;
  activeStep?: ChatStep;
  label: string;
};

/** Delay (ms) before the first mid-turn usage/quota refresh should fire for a running turn. */
export function longTurnUsageRefreshDelayMs(
  sinceEpochMs: number | undefined,
  nowEpochMs: number,
  intervalMs = LONG_TURN_USAGE_REFRESH_INTERVAL_MS,
): number {
  if (intervalMs <= 0) return 0;
  if (sinceEpochMs === undefined || !Number.isFinite(sinceEpochMs)) return intervalMs;
  const elapsed = Math.max(0, nowEpochMs - sinceEpochMs);
  return elapsed < intervalMs ? intervalMs - elapsed : 0;
}

/** When the turn began, when anything last happened, each call's times, and phase-timing state (ms). */
export type TurnClock = {
  started?: number;
  last?: number;
  calls: Map<number, { at: number; doneAt?: number }>;
  phase?: TurnTimingPhase;
  phaseStart?: number;
  closedThinkingMs: number;
  hasEvents: boolean;
};

export function turnClock(events: RunEventLike[] | undefined, since?: string, until?: string): TurnClock {
  const t = since ? Date.parse(since) : 0;
  const hi = until ? Date.parse(until) : Infinity;
  const calls: TurnClock["calls"] = new Map();
  const open = new Map<string, number>();
  const openToolIds = new Set<string>();
  let first: number | undefined;
  let last: number | undefined;
  let phase: TurnTimingPhase | undefined = since ? "thinking" : undefined;
  let phaseStart: number | undefined = since ? t : undefined;
  let closedThinkingMs = 0;

  const transition = (next: TurnTimingPhase, at: number, resetIfSame = false) => {
    if (phase === undefined) {
      phase = next;
      phaseStart = at;
      return;
    }
    if (phase === next) {
      if (resetIfSame) phaseStart = at;
      return;
    }
    if (phase === "thinking" && phaseStart !== undefined) {
      closedThinkingMs += Math.max(0, at - phaseStart);
    }
    phase = next;
    phaseStart = at;
  };

  for (const e of events ?? []) {
    const at = Date.parse(e.at);
    if (at < t || at > hi) continue;
    if (first === undefined) {
      first = at;
      if (phase === undefined) {
        phase = "thinking";
        phaseStart = at;
      }
    }
    last = Math.max(last ?? at, at);
    const p = e.payload;
    if (isSubagentEvent(p)) continue;
    if (e.type === "tool_call") {
      calls.set(e.seq, { at });
      const id = str(p.id);
      if (id) open.set(id, e.seq);
      openToolIds.add(id || `#${e.seq}`);
      transition("tool", at);
    } else if (e.type === "tool_result" && p.id && open.has(str(p.id))) {
      const id = str(p.id);
      calls.get(open.get(id)!)!.doneAt = at;
      if (openToolIds.delete(id) && openToolIds.size === 0) {
        transition("thinking", at);
      }
    } else if (e.type === "lifecycle" && p.state === REPLY_BLOCK) {
      calls.set(e.seq, { at, doneAt: at });
      transition("writing_reply", at, true);
    } else if (e.type === "lifecycle" && p.state === "activity" && (p.phase === "thinking" || p.phase === "writing_reply")) {
      if (openToolIds.size === 0) {
        transition(p.phase as TurnTimingPhase, at);
      }
    } else if (e.type === "message" && p.kind === "thinking") {
      if (openToolIds.size === 0) {
        transition("thinking", at);
      }
    } else if (e.type === "message" && p.role === "assistant" && !p.kind) {
      if (openToolIds.size === 0) {
        transition("writing_reply", at);
      }
    }
  }
  return {
    started: since ? t : first,
    last,
    calls,
    phase,
    phaseStart,
    closedThinkingMs,
    hasEvents: first !== undefined,
  };
}

/**
 * The turn's pulse at `now`: total turn elapsed, current phase elapsed (resetting across
 * thinking/tool/writing_reply transitions), cumulative pure thinking duration, idle time,
 * between-steps state, and quiet state.
 */
export type TurnPulse = {
  elapsed?: number;
  phase: TurnTimingPhase;
  phaseElapsed?: number;
  thinkingDurationMs: number;
  idle?: number;
  between: boolean;
  quiet: boolean;
};

export function turnPulse(calls: ToolCall[], clock: TurnClock, now: number): TurnPulse {
  const elapsed = clock.started === undefined ? undefined : Math.max(0, now - clock.started);
  const phase: TurnTimingPhase = clock.phase ?? "thinking";
  const phaseElapsed = clock.phaseStart === undefined ? undefined : Math.max(0, now - clock.phaseStart);
  const thinkingDurationMs = clock.closedThinkingMs + (clock.phase === "thinking" ? (phaseElapsed ?? 0) : 0);
  const lastAt = clock.last ?? clock.started;
  const idle = lastAt === undefined ? undefined : Math.max(0, now - lastAt);
  const newest = calls.at(-1);
  // A rich block is written into the reply itself, so its own status stays true after its event.
  const doneAt = newest?.done && newest.tool !== REPLY_BLOCK ? clock.calls.get(newest.key)?.doneAt : undefined;
  const between = doneAt !== undefined && now - doneAt >= NEXT_STEP_AFTER_MS;
  const quiet = idle !== undefined && idle >= (newest && !newest.done ? QUIET_RUNNING_MS : QUIET_AFTER_MS);
  return { elapsed, phase, phaseElapsed, thinkingDurationMs, idle, between, quiet };
}

/** Completed reasoning blocks (`message` with `kind === "thinking"`) inside a turn window. */
export function thinkingBlocks(events: RunEventLike[] | undefined, since?: string, until?: string): ThinkingBlock[] {
  const t = since ? Date.parse(since) : 0;
  const hi = until ? Date.parse(until) : Infinity;
  const out: ThinkingBlock[] = [];
  for (const e of events ?? []) {
    const at = Date.parse(e.at);
    if (at < t || at > hi) continue;
    const p = e.payload;
    if (isSubagentEvent(p)) continue;
    if (e.type === "message" && p.kind === "thinking") {
      const text = str(p.text).trim();
      if (!text) continue;
      const heading = thinkingHeading(text);
      out.push({ seq: e.seq, text, ...(heading ? { heading } : {}), at });
    }
  }
  return out;
}

/** Plan checklist progress for a running turn with a plan, excluding synthetic reply-block steps. */
export function planProgress(steps: ChatStep[], planned: boolean): PlanChecklistProgress | undefined {
  if (!planned) return undefined;
  const planOnly = steps.filter((s) => s.key.includes("#"));
  if (planOnly.length === 0) return undefined;
  const completed = planOnly.filter((s) => s.state === "done").length;
  const failed = planOnly.filter((s) => s.state === "failed").length;
  const activeStep = planOnly.find((s) => s.state === "active");
  const total = planOnly.length;
  const base = `${completed}/${total} ${total === 1 ? "step" : "steps"}`;
  const label = failed > 0 ? `${base} · ${failed} failed` : base;
  return { steps: planOnly, completed, failed, total, activeStep, label };
}

/** A duration for the card: "12s", "4m 05s", "1h 02m". */
export function formatSpan(ms: number): string {
  const s = Math.floor(Math.max(0, ms) / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  if (m < 60) return `${m}m ${String(s % 60).padStart(2, "0")}s`;
  return `${Math.floor(m / 60)}h ${String(m % 60).padStart(2, "0")}m`;
}

/** How long it has been quiet, in words: "2 minutes", "over an hour". */
export function quietFor(ms: number): string {
  const m = Math.floor(ms / 60_000);
  if (m >= 60) return "over an hour";
  return m <= 1 ? "a minute" : `${m} minutes`;
}

// ---- the chat tab's step rail: the turn's plan, or its work so far ----

/** A step's place in the turn. A finished step is "failed" when its last call errored at work where an error means failure. */
export type ChatStepState = "planned" | "active" | "done" | "failed";
/** `kind` picks the step's glyph: the kind of its newest call, absent until a planned step's work starts. */
export type ChatStep = {
  key: string;
  title: string;
  state: ChatStepState;
  kind?: ChatStatusKind;
  added?: true;
  detail?: string;
  /** The newest decision the assistant narrated during this step, in its own words. */
  intent?: string;
  tag?: IntentTag;
  /** The step has thinking to read in the Activity tab. */
  reasoning?: true;
  /** When its first call started and its last finished (ms), given a TurnClock. An active step runs until now. */
  startedAt?: number;
  endedAt?: number;
};

/** The rail's stand-in while the newest call has finished and the next hasn't started. */
export const NEXT_STEP_KEY = "next-step";

type PlanState = "planned" | "active" | "done" | "failed";
type PlanItem = { id: string; title: string; state: PlanState };

const planState = (v: unknown): PlanState => (v === "completed" ? "done" : v === "failed" ? "failed" : v === "in_progress" ? "active" : "planned");
const records = (list: unknown) => (Array.isArray(list) ? (list as Record<string, unknown>[]) : []);
const planItems = (list: unknown): PlanItem[] =>
  records(list)
    .filter((item) => item.content && item.status !== "cancelled")
    .map((item, i) => ({ id: String(i), title: str(item.content), state: planState(item.status) }));

/**
 * Every version of the plan, oldest first, and from which call on each one holds (`call`, an index into calls).
 * The server's plan snapshots are the source when the turn has any; each holds from the first call after it.
 * Older turns have none: their plan is read from Claude Code's calls, where TodoWrite sends the whole list and
 * TaskCreate and TaskUpdate change one task, each holding from the call that wrote it.
 */
type PlanVersion = { items: PlanItem[]; call: number };
function planVersions(calls: ToolCall[], plans?: PlanSnapshot[]): PlanVersion[] {
  if (plans?.length) {
    return plans.map((p) => {
      const next = calls.findIndex((c) => c.key > p.seq);
      return { items: p.items, call: next < 0 ? calls.length : next };
    });
  }
  const versions: PlanVersion[] = [];
  let tasks: PlanItem[] = [];
  for (const [at, call] of calls.entries()) {
    const o = (call.input && typeof call.input === "object" ? call.input : {}) as Record<string, unknown>;
    switch (bareTool(call.tool)) {
      case "TodoWrite":
      case "todowrite":
        versions.push({ items: planItems(o.todos), call: at });
        break;
      case "TaskCreate":
        tasks = [...tasks, { id: /#(\d+)/.exec(call.output ?? "")?.[1] ?? String(tasks.length + 1), title: str(o.subject), state: "planned" }];
        versions.push({ items: tasks, call: at });
        break;
      case "TaskUpdate": {
        const id = str(o.taskId);
        if (!tasks.some((t) => t.id === id)) break;
        tasks = o.status === "deleted"
          ? tasks.filter((t) => t.id !== id)
          : tasks.map((t) => (t.id === id ? { ...t, title: o.subject ? str(o.subject) : t.title, state: o.status ? planState(o.status) : t.state } : t));
        versions.push({ items: tasks, call: at });
        break;
      }
    }
  }
  return versions;
}

/** Kinds where an errored call means the work failed. Elsewhere an error is routine: a search with no match, an edit retried. */
const FAILABLE = new Set<ChatStatusKind>(["tests", "build", "install", "commit", "push", "pull-request", "github", "terminal", "connector", "secret", "image"]);

const failedAt = (call: ToolCall, kind: ChatStatusKind) => !!call.failed && FAILABLE.has(kind);

/**
 * Each plan step's kind and outcome, from the calls made while it was the step under way:
 * the newest call's kind, and whether that call failed.
 */
function planWork(calls: ToolCall[], versions: PlanVersion[], owner: (string | undefined)[] = []): Map<string, { kind: ChatStatusKind; failed: boolean }> {
  const work = new Map<string, { kind: ChatStatusKind; failed: boolean }>();
  let v = -1;
  for (const [i, call] of calls.entries()) {
    while (v + 1 < versions.length && versions[v + 1].call <= i) v++;
    if (v < 0 || BOOKKEEPING.has(bareTool(call.tool)) || call.tool === REPLY_BLOCK) continue;
    const active = versions[v].items.find((s) => s.state === "active");
    if (!active) continue;
    const { kind } = chatStatusOf(call);
    work.set(active.title, { kind, failed: failedAt(call, kind) });
    owner[i] = `${active.title}#0`;
  }
  return work;
}

/** Calls that keep the turn running but aren't work to show: its plan, tool loading, the chat's title. */
const BOOKKEEPING = new Set(["TodoWrite", "todowrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "set_plan", "ToolSearch", "Skill", "set_chat_title", "whoami"]);

const basename = (p: string) => p.split("/").filter(Boolean).pop() ?? p;

/** A URL's site, never its path or query, which can carry tokens. */
function hostOf(raw: string): string {
  try {
    return new URL(raw).hostname.replace(/^www\./, "");
  } catch {
    return "";
  }
}

/** Rejects model-authored shell summaries that look like raw commands, URLs, secrets or host paths. */
function cleanShellSummary(raw: unknown): string {
  if (typeof raw !== "string") return "";
  const s = raw.replace(/\s+/g, " ").trim().replace(/\.+$/, "");
  if (!s) return "";
  if (/:\/\/|[A-Z_][A-Z0-9_]*=|--?(?:token|secret|password|key|auth)\b|\/(?:Users|home|etc|var|tmp)\//i.test(s)) return "";
  return clip(s, 60);
}

const GIT_SUBCOMMAND_DETAIL: Record<string, string> = {
  status: "Checking git status",
  diff: "Checking git diff",
  log: "Checking git log",
  branch: "Checking branches",
  checkout: "Switching branches",
  switch: "Switching branches",
  fetch: "Syncing with origin",
  pull: "Syncing with origin",
  rebase: "Updating branch",
  merge: "Updating branch",
  show: "Inspecting a commit",
  stash: "Managing git stash",
  add: "Staging changes",
  blame: "Checking git blame",
};

const GO_TEST_VALUE_FLAGS = new Set(["-run", "-skip", "-bench", "-count", "-timeout", "-tags", "-parallel", "-cpu", "-coverprofile", "-coverpkg", "-o", "-fuzz", "-fuzztime", "-ldflags", "-gcflags"]);

/**
 * Coarse, secret-free target extracted from common shell commands (e.g. Codex command_execution,
 * which carries no description field). Never echoes env vars, credentials, URLs, or arbitrary args.
 */
function shellTarget(command: string, kind: ChatStatusKind): string {
  let c = command.trim().replace(/^(\S*\/)?(ba|z)?sh\s+-l?c\s+/, "");
  if ((c.startsWith("'") && c.endsWith("'")) || (c.startsWith("\"") && c.endsWith("\""))) c = c.slice(1, -1).trim();
  if (c.startsWith("(") && c.endsWith(")")) c = c.slice(1, -1).trim();
  let dir = "";
  const cd = /^cd\s+([^\s;&|]+)\s*(?:&&|;)\s*/.exec(c);
  if (cd) {
    const rawDir = cd[1].replace(/^['"]|['"]$/g, "");
    const base = basename(rawDir);
    if (/^[A-Za-z0-9._-]+$/.test(base) && base !== "." && base !== "..") dir = base;
    c = c.slice(cd[0].length).trim();
  }
  // Drop leading env assignments so secrets never reach the label.
  c = c.replace(/^(?:[A-Za-z_][A-Za-z0-9_]*=(?:'[^']*'|"[^"]*"|\S+)\s+)+/, "");
  const head = c.split(/\s*(?:&&|\|\||;|\|)\s*/)[0]?.trim() ?? "";
  if (!head) return "";

  if (kind === "tests") {
    const goTest = /^go\s+test\b(.*)$/.exec(head);
    if (goTest) {
      const tokens = goTest[1].trim().split(/\s+/).filter(Boolean);
      for (let i = 0; i < tokens.length; i++) {
        const tok = tokens[i];
        if (GO_TEST_VALUE_FLAGS.has(tok)) {
          i++;
          continue;
        }
        if (tok.startsWith("-")) continue;
        if (/^\.\/[A-Za-z0-9_./-]+$/.test(tok) && tok !== "./...") return `Testing ${clip(tok, 48)}`;
      }
      return dir ? `Testing ${dir}` : "";
    }
    const jsTest = /^(?:npm|pnpm|yarn)\s+(?:run\s+)?(test(?::[A-Za-z0-9_-]+)?)\b/.exec(head);
    if (jsTest) {
      const script = jsTest[1];
      if (script !== "test") return dir ? `Running ${dir} ${script}` : `Running ${script}`;
      return dir ? `Running ${dir} tests` : "";
    }
    const runnerTest = /^(?:npx\s+)?(?:pytest|jest|vitest|playwright\s+test|rspec)\b(.*)$/.exec(head);
    if (runnerTest) {
      const tokens = runnerTest[1].trim().split(/\s+/).filter(Boolean);
      for (const tok of tokens) {
        if (tok.startsWith("-") || tok === "run") continue;
        if (/^[A-Za-z0-9_./-]+\.[A-Za-z0-9]+$/.test(tok)) return `Testing ${clip(basename(tok), 48)}`;
      }
      return dir ? `Running ${dir} tests` : "";
    }
    const cargoTest = /^cargo\s+test\b(.*)$/.exec(head);
    if (cargoTest) {
      const tokens = cargoTest[1].trim().split(/\s+/).filter(Boolean);
      for (let i = 0; i < tokens.length; i++) {
        const tok = tokens[i];
        if (tok === "-p" || tok === "--package") {
          const pkg = tokens[++i];
          if (pkg && /^[A-Za-z0-9_.-]+$/.test(pkg)) return `Testing ${clip(pkg, 48)}`;
          continue;
        }
        if (tok.startsWith("-")) continue;
        if (/^[A-Za-z0-9_:-]+$/.test(tok)) return `Testing ${clip(tok, 48)}`;
      }
      return dir ? `Running ${dir} tests` : "";
    }
    if (/^make\s+test\b/.test(head) && dir) return `Running ${dir} tests`;
    return "";
  }

  if (kind === "build") {
    const goBuild = /^go\s+(build|vet)\b(.*)$/.exec(head);
    if (goBuild) {
      const verb = goBuild[1] === "vet" ? "Vetting" : "Building";
      const tokens = goBuild[2].trim().split(/\s+/).filter(Boolean);
      for (let i = 0; i < tokens.length; i++) {
        const tok = tokens[i];
        if (tok === "-o" || tok === "-tags" || tok === "-ldflags") {
          i++;
          continue;
        }
        if (tok.startsWith("-")) continue;
        if (/^\.\/[A-Za-z0-9_./-]+$/.test(tok) && tok !== "./...") return `${verb} ${clip(tok, 48)}`;
      }
      return `${verb} ${dir || "Go packages"}`;
    }
    const jsBuild = /^(?:npm|pnpm|yarn)\s+(?:run\s+)?(build|lint|typecheck)\b/.exec(head);
    if (jsBuild) {
      const verb = jsBuild[1] === "lint" ? "Linting" : jsBuild[1] === "typecheck" ? "Type-checking" : "Building";
      return dir ? `${verb} ${dir}` : `${verb} ${jsBuild[1] === "build" ? "project" : "code"}`;
    }
    if (/^(?:npx\s+)?tsc\b/.test(head)) return dir ? `Type-checking ${dir}` : "Type-checking";
    if (/^(?:npx\s+)?eslint\b/.test(head)) return dir ? `Linting ${dir}` : "Linting code";
    if (/^gofmt\b/.test(head)) return "Formatting Go code";
    const cargo = /^cargo\s+(build|check|clippy)\b/.exec(head);
    if (cargo) return cargo[1] === "clippy" ? "Running clippy" : cargo[1] === "check" ? "Checking Rust build" : "Building Rust";
    return "";
  }

  if (kind === "repo-history") {
    const m = new RegExp(`^${GIT}(${Object.keys(GIT_SUBCOMMAND_DETAIL).join("|")})\\b`, "i").exec(head);
    if (m) return GIT_SUBCOMMAND_DETAIL[m[1].toLowerCase()] ?? "";
    return "";
  }

  if (kind === "install" && dir) return `Installing ${dir} dependencies`;
  return "";
}

/**
 * What a step is doing right now, safe for the chat tab: a file's name but not its path,
 * search terms, page names and sites. Shell commands use their model-authored summary or a
 * coarse, secret-free target rather than the raw command. Memory stays general because it's private.
 * Tools that take only an id use `names`, what earlier calls in the turn said it's called.
 */
export function stepDetail(call: { tool: string; input: unknown }, names: Map<string, string> = new Map()): string {
  const o = (call.input && typeof call.input === "object" ? call.input : {}) as Record<string, unknown>;
  const { kind, phrase } = chatStatusOf(call);
  const general = phrase[0].toUpperCase() + phrase.slice(1);
  const file = basename(str(o.file_path ?? o.notebook_path ?? o.path));
  const quoted = `“${clip(str(o.pattern))}”`;
  const named = (verb: string, name: unknown, fallback?: unknown) => (name ? `${verb} “${clip(str(name))}”` : fallback ? `${verb}: ${clip(str(fallback))}` : general);
  const known = (id: unknown) => names.get(str(id));
  switch (bareTool(call.tool)) {
    case "Read":
    case "read_file":
      return file && kind !== "image-view" ? `Reading ${file}` : general;
    case "Edit":
    case "MultiEdit":
    case "NotebookEdit":
      return file ? `Editing ${file}` : general;
    case "Write":
      return file ? `Writing ${file}` : general;
    case "Grep":
      return o.pattern ? `Searching ${quoted}` : general;
    case "Glob":
      return o.pattern ? `Finding ${quoted}` : general;
    case "LS":
    case "list_dir":
      return file ? `Listing ${file}` : general;
    case "apply_patch": {
      // Codex reports each change as "<kind> <path>".
      const files = Array.isArray(o.files) ? o.files.map((f) => basename(str(f).split(" ").slice(1).join(" "))) : [];
      return files.length ? `Editing ${files[0]}${files.length > 1 ? ` and ${files.length - 1} more` : ""}` : general;
    }
    case "canvas_create":
      return named("Drafting", o.title);
    case "canvas_read":
      return named("Looking at", known(o.canvas_id));
    case "canvas_patch":
      return named("Revising", known(o.canvas_id), o.note);
    case "canvas_comment":
    case "canvas_reply":
      return named("Commenting on", known(o.canvas_id));
    case "design_flows":
      return named("Tracing the flow of", known(o.canvas_id));
    case "design_create":
      return named("Starting the design", o.title);
    case "read_workflow":
      return named("Looking over", known(o.workflow_id));
    case "propose_workflow_edit":
      return named("Sketching", o.name || known(o.workflow_id), o.summary);
    case "create_ticket":
      return named("Drafting", o.title);
    case "create_epic":
      return named("Drafting", o.name);
    case "get_ticket":
      return o.ticket ? `Reading ${clip(str(o.ticket))}` : general;
    case "list_epics":
      return o.project ? `Looking over ${clip(str(o.project))} epics` : general;
    case "list_tickets": {
      const statuses = Array.isArray(o.status) ? o.status.map(str) : [];
      const which = [o.project ? str(o.project).toUpperCase() : "", statuses.length === 1 && statuses[0] !== "all" ? statuses[0].replace(/_/g, "-") : ""].filter(Boolean).join(" ");
      return which ? `Looking over ${clip(which)} tickets` : general;
    }
    case "update_ticket":
      return o.ticket ? `Updating ${clip(str(o.ticket))}` : general;
    case "comment_ticket":
      return o.ticket ? `Commenting on ${clip(str(o.ticket))}` : general;
    case "generate_image":
    case "image_generation":
    case "image_gen":
      return named("Creating", o.prompt);
    case "propose_persona":
      return named("Sketching", o.name);
    case "propose_persona_character":
      return o.persona ? named("Designing character for", o.persona) : o.summary ? `Designing character: ${clip(str(o.summary))}` : general;
    case "create_space":
      return named("Setting up", o.name);
    case "list_custom_apps":
      return "Listing custom apps";
    case "get_custom_app":
      return named("Inspecting", o.slug);
    case "create_custom_app":
      return named("Creating app", o.name || o.slug);
    case "update_custom_app":
      return named("Updating app", o.slug, o.note);
    case "delete_custom_app":
      return named("Deleting app", o.slug);
    case "custom_app_sql":
      return o.slug ? `Querying ${clip(str(o.slug))}` : general;
    case "http_list_workspaces":
      return "Listing HTTP workspaces";
    case "http_get_workspace":
      return named("Inspecting HTTP workspace", known(o.workspace_id));
    case "http_save_request":
      return named("Saving request", o.name || o.url);
    case "http_run_request":
      return named("Sending request", known(o.request_id));
    case "Agent":
    case "Task":
    case "delegate":
      return named("Delegating", o.description || o.agent);
    case "run_subagent":
      return named("Delegating", o.role || o.type);
    case "run_subagents": {
      const tasks = Array.isArray(o.tasks) ? o.tasks : [];
      if (tasks.length === 1) {
        const first = (tasks[0] && typeof tasks[0] === "object" ? tasks[0] : {}) as Record<string, unknown>;
        return named("Delegating", first.role || first.type);
      }
      return tasks.length > 1 ? `Running ${tasks.length} subagents` : general;
    }
    case "create_scheduled_task":
      return named("Scheduling", o.name);
    case "update_scheduled_task":
      return named("Changing", known(o.task_id));
    case "browser_snapshot":
      // The page is untrusted: the persona got it fenced as data (browserext.Untrusted), and the step says so.
      return "Reading your shared Safari tab · untrusted page";
    case "save_link":
      return named("Saving", o.title || hostOf(str(o.url)));
    case "save_file":
      return named("Saving", o.title || str(o.filename));
    case "render_pdf":
      return named("Rendering PDF", o.title || str(o.filename));
    case "search_library":
      return o.q ? `Searching “${clip(str(o.q))}”` : general;
    case "read_library_item":
      return named("Opening", known(o.item_id));
    case "delete_scheduled_task":
      return named("Removing", known(o.task_id));
    case "create_learning_module":
      return named("Starting a module on", o.topic);
    case "get_learning_progress":
      return named("Checking progress on", known(o.module_id));
    case "get_run":
      return known(o.id) ? `Checking ${known(o.id)}` : general;
    case "list_runs":
      return o.ticket || o.agent ? `Checking runs of ${clip(str(o.ticket || o.agent))}` : general;
    case "Bash":
    case "bash":
    case "shell":
    case "exec_command":
    case "shell_command": {
      const summary = cleanShellSummary(o.description ?? o.toolSummary);
      if (summary) return summary;
      const cmd = typeof o.command === "string" ? o.command : typeof o.cmd === "string" ? o.cmd : "";
      return shellTarget(cmd, kind) || general;
    }
    case "get_video_transcript":
      return typeof o.from_seconds === "number" && o.from_seconds > 0 ? `Watching from ${Math.floor(o.from_seconds / 60)}:${String(Math.floor(o.from_seconds % 60)).padStart(2, "0")}` : general;
  }
  if (kind === "github" || kind === "pull-request") {
    const number = o.pull_number ?? o.pullNumber ?? o.issue_number ?? o.number;
    if (o.title) return named("Working on", o.title);
    if (o.repo) return `Working on ${clip(`${o.owner ? `${str(o.owner)}/` : ""}${str(o.repo)}${number ? `#${str(number)}` : ""}`)}`;
    return general;
  }
  const a = activityOf(call);
  return a.verb === "Using" || a.verb === "Running a command" ? general : [a.verb, a.label, a.text].filter(Boolean).join(" ");
}

/** A tool result as JSON: plain, or the MCP envelope Codex passes through. Undefined when it was clipped or isn't JSON. */
export function resultJSON(output?: string): Record<string, unknown> | undefined {
  try {
    const v = JSON.parse(output ?? "");
    const text = v?.content?.[0]?.text;
    return typeof text === "string" ? JSON.parse(text) : v;
  } catch {
    return undefined;
  }
}

/** The names the turn has seen for canvases, workflows, runs, scheduled tasks, Library items and learning modules, by id. */
function knownNames(calls: ToolCall[]): Map<string, string> {
  const names = new Map<string, string>();
  const note = (id: unknown, name: unknown) => {
    if (id && name) names.set(str(id), str(name));
  };
  for (const call of calls) {
    const out = resultJSON(call.output);
    if (!out) continue;
    const input = (call.input ?? {}) as Record<string, unknown>;
    switch (bareTool(call.tool)) {
      case "canvas_create":
        note(out.canvas_id, input.title);
        break;
      case "canvas_read":
        note(out.canvas_id, out.title);
        break;
      case "canvas_list":
        for (const c of records(out.canvases)) note(c.canvas_id, c.title);
        break;
      case "list_workflows":
        for (const w of records(out.workflows)) note(w.id, w.name);
        break;
      case "read_workflow":
        note(out.id, out.name);
        break;
      case "propose_workflow_edit":
        note(out.workflow_id, input.name);
        break;
      case "list_runs":
        for (const r of records(out.runs)) note(r.id, r.ticket);
        break;
      case "list_scheduled_tasks":
        for (const t of records(out.tasks)) note(t.task_id, t.name);
        break;
      case "search_library":
        for (const it of records(out.items)) note(it.item_id, it.title);
        break;
      case "save_link":
        note(out.item_id, out.title);
        break;
      case "create_learning_module":
        note(out.module_id, out.topic);
        break;
      case "list_learning_modules":
        for (const m of records(out.modules)) note(m.module_id, m.topic);
        break;
      case "get_run": {
        const run = out.run as Record<string, unknown> | undefined;
        note(run?.id, run?.ticket);
        break;
      }
    }
  }
  return names;
}

/** Puts what's happening now on the step under way, unless it would only repeat the title. */
function withDetail(steps: ChatStep[], calls: ToolCall[], branches?: SubagentBranch[]): ChatStep[] {
  const newest = calls.filter((c) => !BOOKKEEPING.has(bareTool(c.tool))).pop();
  const active = steps.find((s) => s.state === "active");
  if (!newest || !active || newest.tool === REPLY_BLOCK) return steps;
  if (!newest.done && isSubagentDelegationTool(newest.tool)) {
    const live = liveSubagentStatus(branches);
    if (live?.detail && live.detail !== active.title) {
      active.detail = live.detail;
      return steps;
    }
  }
  const detail = stepDetail(newest, knownNames(calls));
  if (detail !== active.title) active.detail = detail;
  return steps;
}

/**
 * The turn's steps. The newest plan when the assistant wrote one, marking steps added after
 * work began. Otherwise its consecutive tool calls with the same description as one step, newest active, in the same
 * high-level wording as the status line.
 */
export function chatSteps(calls: ToolCall[], notes?: TurnNote[], opts: { between?: boolean; clock?: TurnClock; activity?: TurnActivity; branches?: SubagentBranch[]; plans?: PlanSnapshot[] } = {}): { steps: ChatStep[]; planned: boolean } {
  const { steps, planned, owner } = buildSteps(calls, opts.between, opts.activity, opts.branches, opts.plans);
  if (opts.clock) stampTimes(steps, calls, owner, opts.clock);
  if (notes?.length) {
    const byKey = new Map(steps.map((st) => [st.key, st]));
    for (const n of notes) {
      const st = byKey.get(noteOwner(n, calls, owner) ?? "");
      if (!st) continue;
      if (n.kind === "thinking") st.reasoning = true;
      else {
        st.intent = n.text;
        if (n.tag) st.tag = n.tag;
        else delete st.tag;
      }
    }
  }
  return { steps, planned };
}

/** Each step's span, from the calls it owns. The stand-in next step starts when the newest call finished. */
function stampTimes(steps: ChatStep[], calls: ToolCall[], owner: (string | undefined)[], clock: TurnClock) {
  const byKey = new Map(steps.map((st) => [st.key, st]));
  for (const [i, call] of calls.entries()) {
    const st = byKey.get(owner[i] ?? "");
    const t = clock.calls.get(call.key);
    if (!st || !t) continue;
    st.startedAt = Math.min(st.startedAt ?? t.at, t.at);
    st.endedAt = Math.max(st.endedAt ?? 0, t.doneAt ?? t.at);
  }
  const next = byKey.get(NEXT_STEP_KEY);
  const newest = calls.at(-1);
  if (next) next.startedAt = newest ? clock.calls.get(newest.key)?.doneAt : clock.started;
}

/**
 * The steps, and for each call the key of the step it was part of (none for bookkeeping, or work before the plan started).
 * `between`: a planless turn's newest step is finished, and a contextual stand-in step is under way instead.
 * `activity`: live harness phase (thinking heading or drafting a reply) between tool calls.
 */
function buildSteps(calls: ToolCall[], between = false, activity?: TurnActivity, branches?: SubagentBranch[], plans?: PlanSnapshot[]): { steps: ChatStep[]; planned: boolean; owner: (string | undefined)[] } {
  const owner: (string | undefined)[] = new Array(calls.length).fill(undefined);
  const versions = planVersions(calls, plans);
  const latest = versions[versions.length - 1]?.items;
  if (latest?.length) {
    const baseline = versions.find((v) => v.items.some((s) => s.state !== "planned"))?.items;
    const original = new Set(baseline?.map((s) => s.title) ?? latest.map((s) => s.title));
    const work = planWork(calls, versions, owner);
    const seen = new Map<string, number>();
    const steps = latest.map((s): ChatStep => {
      // By title, not position, so a step added mid-list doesn't remount the ones after it.
      const n = seen.get(s.title) ?? 0;
      seen.set(s.title, n + 1);
      const w = s.state === "planned" ? undefined : work.get(s.title);
      return {
        key: `${s.title}#${n}`,
        title: s.title,
        state: s.state === "done" && w?.failed ? "failed" : s.state,
        ...(w ? { kind: w.kind } : {}),
        ...(original.has(s.title) ? {} : { added: true as const }),
      };
    });
    // A plan doesn't list the rich blocks in the reply, so they follow it.
    const newest = calls[calls.length - 1];
    for (const [i, call] of calls.entries()) {
      if (call.tool !== REPLY_BLOCK) continue;
      const { kind, phrase } = chatStatusOf(call);
      steps.push({ key: String(call.key), title: phrase[0].toUpperCase() + phrase.slice(1), state: call === newest ? "active" : "done", kind });
      owner[i] = String(call.key);
    }
    const detailed = withDetail(steps, calls, branches);
    if (activity && (!newest || (newest.done && newest.tool !== REPLY_BLOCK))) {
      const active = detailed.find((s) => s.state === "active");
      if (active) {
        if (activity.phase === "writing_reply") active.detail = "Drafting a reply";
        else if (activity.detail) active.detail = activity.detail;
      }
    }
    return { steps: detailed, planned: true, owner };
  }
  const steps: ChatStep[] = [];
  let last: string | undefined;
  for (const [i, call] of calls.entries()) {
    if (BOOKKEEPING.has(bareTool(call.tool))) continue;
    const { kind, phrase } = chatStatusOf(call);
    const failed = failedAt(call, kind);
    if (phrase === last) {
      // The group's newest call decides: a test run that failed, then passed, is done.
      steps[steps.length - 1].state = failed ? "failed" : "done";
      owner[i] = steps[steps.length - 1].key;
      continue;
    }
    last = phrase;
    steps.push({ key: String(call.key), title: phrase[0].toUpperCase() + phrase.slice(1), state: failed ? "failed" : "done", kind });
    owner[i] = String(call.key);
  }
  if (!steps.length) {
    if (activity?.phase === "writing_reply") {
      steps.push({ key: NEXT_STEP_KEY, title: "Drafting a reply", state: "active", kind: "writing-reply" });
    } else if (activity?.phase === "thinking" && activity.detail) {
      steps.push({ key: NEXT_STEP_KEY, title: "Thinking", state: "active", kind: "thinking", detail: activity.detail });
    }
    return { steps, planned: false, owner };
  }
  const newest = steps[steps.length - 1];
  const finished = newest.state;
  newest.state = "active";
  withDetail(steps, calls, branches);
  const lastCall = calls.at(-1);
  const callRunning = !!lastCall && !lastCall.done;
  const replyBlockActive = lastCall?.tool === REPLY_BLOCK;
  const showPostTool = !callRunning && !replyBlockActive && (activity?.phase === "writing_reply" || between || (activity?.phase === "thinking" && !!activity.detail));
  if (showPostTool) {
    newest.state = finished;
    if (activity?.phase === "writing_reply") {
      steps.push({ key: NEXT_STEP_KEY, title: "Drafting a reply", state: "active", kind: "writing-reply" });
    } else {
      const { phrase } = nextStepStatus(newest.kind);
      steps.push({
        key: NEXT_STEP_KEY,
        title: phrase[0].toUpperCase() + phrase.slice(1),
        state: "active",
        kind: "next-step",
        ...(activity?.detail ? { detail: activity.detail } : {}),
      });
    }
  }
  return { steps, planned: false, owner };
}

/**
 * Keeps the rail short on long turns: all but the newest two of more than three finished steps fold away, and at most four upcoming steps show.
 * A failed step never folds, so a failure stays in sight.
 */
export function foldSteps(steps: ChatStep[]): { earlier: number; shown: ChatStep[]; later: number } {
  const done = steps.filter((s) => s.state === "done");
  const hidden = new Set(done.length > 3 ? done.slice(0, -2) : []);
  const upcoming = steps.filter((s) => s.state === "planned");
  for (const s of upcoming.slice(4)) hidden.add(s);
  return { earlier: done.length > 3 ? done.length - 2 : 0, shown: steps.filter((s) => !hidden.has(s)), later: Math.max(0, upcoming.length - 4) };
}

/** How a finished turn ended: with a reply, an error, or the person stopping (or interrupting) it. */
export type TurnOutcome = "done" | "failed" | "stopped";
export type FinishedTurn = {
  steps: ChatStep[];
  duration?: number;
  thinkingDurationMs?: number;
  thinkingBlocks: ThinkingBlock[];
};

const OUTCOME_VERB: Record<TurnOutcome, string> = {
  done: "Worked for",
  failed: "Failed after",
  stopped: "Stopped after",
};

/** Summary line for a finished working card ("Worked for 2m 14s · Thought for 32s · 7 steps"). */
export function finishedSummary(
  outcome: TurnOutcome,
  stepCount: number,
  durationMs?: number,
  thinkingDurationMs?: number,
): string {
  const verb = OUTCOME_VERB[outcome];
  const lead = durationMs !== undefined && durationMs >= 1000 ? `${verb} ${formatSpan(durationMs)}` : verb.split(" ")[0];
  const parts = [lead];
  if (thinkingDurationMs !== undefined && thinkingDurationMs >= 1000) {
    parts.push(`Thought for ${formatSpan(thinkingDurationMs)}`);
  }
  parts.push(`${stepCount} ${stepCount === 1 ? "step" : "steps"}`);
  return parts.join(" · ");
}

/**
 * A finished turn's steps, duration, pure thinking duration, and thinking blocks.
 * Plain replies with only bookkeeping and reply blocks return empty steps (so no working strip
 * renders) while still preserving thinkingDurationMs and thinkingBlocks when events exist.
 * `end` (ms) is when the turn ended, its reply's time when there is one.
 */
export function finishedTurn(events: RunEventLike[] | undefined, outcome: TurnOutcome, since?: string, until?: string, end?: number): FinishedTurn {
  const calls = chatCalls(events, since, until);
  const clock = turnClock(events, since, until);
  const blocks = thinkingBlocks(events, since, until);
  const last = end ?? clock.last;
  const duration = clock.started !== undefined && last !== undefined ? Math.max(0, last - clock.started) : undefined;
  const thinkingDurationMs =
    clock.hasEvents && clock.started !== undefined && last !== undefined
      ? clock.closedThinkingMs + (clock.phase === "thinking" && clock.phaseStart !== undefined ? Math.max(0, last - clock.phaseStart) : 0)
      : undefined;
  if (!calls.some((c) => c.tool !== REPLY_BLOCK && !BOOKKEEPING.has(bareTool(c.tool)))) {
    return { steps: [], duration, thinkingDurationMs, thinkingBlocks: blocks };
  }
  const { steps } = chatSteps(calls, turnNotes(events, since, until), { clock, plans: planSnapshots(events, since, until) });
  for (const st of steps) {
    if (st.state !== "active") continue;
    st.state = outcome === "failed" ? "failed" : "done";
  }
  return { steps, duration, thinkingDurationMs, thinkingBlocks: blocks };
}

/** Where a turn that ended without a reply shows its strip, and the events it covers. */
export type EndedTurn = { outcome: Exclude<TurnOutcome, "done">; since: string; until?: string; end?: number };

/**
 * The turns that ended without a reply, keyed by the message the strip goes under. A failed
 * turn leaves a system message with its turn (keyed by that message); a stopped or interrupted
 * one leaves nothing, so the person's unanswered message holds it until their next one. The
 * newest unanswered message is the running turn while `running`, which the live card shows.
 */
export function endedTurns(list: (MessageLike & { role: string })[] | undefined, running: boolean): Map<string, EndedTurn> {
  const out = new Map<string, EndedTurn>();
  let open: MessageLike | undefined;
  for (const m of list ?? []) {
    if (m.role === "assistant") open = undefined;
    else if (m.role === "system" && m.turn_seq !== undefined && open) {
      out.set(m.id, { outcome: "failed", since: open.created_at, until: m.created_at, end: Date.parse(m.created_at) });
      open = undefined;
    } else if (m.role === "user") {
      if (open) out.set(open.id, { outcome: "stopped", since: open.created_at, until: m.created_at });
      open = m;
    }
  }
  if (open && !running) out.set(open.id, { outcome: "stopped", since: open.created_at });
  return out;
}

// ---- narrated decisions and thinking: on the chat tab's steps, and in full in the Activity tab ----

/** A narrated decision's tag: the assistant dropped its approach for another, or found something that changed the picture. */
export type IntentTag = "approach" | "surprise";

/** An intent line or a thinking block, and the seq of the tool call it came just before (none when the reply followed it). */
export type TurnNote = { kind: "intent" | "thinking"; text: string; tag?: IntentTag; before?: number };

const TAGS: [RegExp, IntentTag][] = [
  [/^(?:new approach|change of plan|changing approach)\s*[:—–-]\s*/i, "approach"],
  [/^surprise\s*[:—–-]\s*/i, "surprise"],
];

/** "New approach: …" and "Surprise: …" become a tag on the rest of the line. */
export function intentOf(text: string): { text: string; tag?: IntentTag } {
  const t = text.trim();
  for (const [re, tag] of TAGS) {
    const m = re.exec(t);
    if (m && t.length > m[0].length) {
      const rest = t.slice(m[0].length);
      return { text: rest[0].toUpperCase() + rest.slice(1), tag };
    }
  }
  return { text: t };
}

/**
 * The turn's narrated decisions and thinking, in order. An intent line is assistant text
 * between tool calls: not the turn's first text (the opening line), and not text no call
 * follows yet (the reply, or a line that may still become one). Thinking is pinned to the call it
 * led to, or to the reply when none followed.
 */
export function turnNotes(events: RunEventLike[] | undefined, since?: string, until?: string): TurnNote[] {
  const t = since ? Date.parse(since) : 0;
  const hi = until ? Date.parse(until) : Infinity;
  const notes: TurnNote[] = [];
  let pending: TurnNote[] = [];
  let seenText = false;
  for (const e of events ?? []) {
    const at = Date.parse(e.at);
    if (at < t || at > hi) continue;
    const p = e.payload;
    if (isSubagentEvent(p)) continue;
    if (e.type === "message" && p.kind === "thinking") {
      const text = str(p.text).trim();
      if (text) pending.push({ kind: "thinking", text });
    } else if (e.type === "message" && p.role === "assistant" && !p.kind) {
      const text = str(p.text).trim();
      if (!text) continue;
      if (seenText) pending.push({ kind: "intent", ...intentOf(clip(text, 280)) });
      seenText = true;
    } else if (e.type === "tool_call") {
      for (const n of pending) notes.push({ ...n, before: e.seq });
      pending = [];
    }
  }
  // What no call followed: thinking belongs to the reply; text is the reply itself.
  for (const n of pending) if (n.kind === "thinking") notes.push(n);
  return notes;
}

/** The step a note belongs to: that of the call it came before, or the next call that belongs to one. */
function noteOwner(n: TurnNote, calls: ToolCall[], owner: (string | undefined)[]): string | undefined {
  if (n.before === undefined) return undefined;
  const from = calls.findIndex((c) => c.key === n.before);
  if (from < 0) return undefined;
  for (let i = from; i < calls.length; i++) if (owner[i]) return owner[i];
  return undefined;
}

/** Flag highlighting a subagent routing or execution anomaly in Chat Activity. */
export type SubagentBranchFlag = "capped" | "spinning" | "queue_bound" | "serial" | "failed";

/** Reconstructed in-turn subagent branch for Chat Activity, built purely from streamed run events. */
export type SubagentBranch = {
  id: string;
  batchId?: string;
  batchSize: number;
  agentType: string;
  role: string;
  reason?: string;
  requestedTier?: string;
  tier?: string;
  model?: string;
  effort?: string;
  status: "queued" | "running" | "completed" | "failed" | "canceled";
  error?: string;
  createdAt: number;
  startedAt?: number;
  finishedAt?: number;
  queuedMs?: number;
  durationMs?: number;
  toolCalls: number;
  inputTokens?: number;
  outputTokens?: number;
  costUsd?: number;
  calls: ToolCall[];
  flags: SubagentBranchFlag[];
  firstSeq: number;
};

type PartialBranch = {
  id: string;
  batchId?: string;
  reportedBatchSize?: number;
  agentType: string;
  role: string;
  reason?: string;
  requestedTier?: string;
  tier?: string;
  model?: string;
  effort?: string;
  status: SubagentBranch["status"];
  error?: string;
  createdAt: number;
  hasLifecycleCreated?: boolean;
  startedAt?: number;
  finishedAt?: number;
  queuedMs?: number;
  durationMs?: number;
  reportedToolCalls?: number;
  inputTokens?: number;
  outputTokens?: number;
  costUsd?: number;
  calls: ToolCall[];
  firstSeq: number;
};

const optStr = (v: unknown) => (typeof v === "string" && v ? v : undefined);
const optNum = (v: unknown) => (typeof v === "number" && Number.isFinite(v) ? v : undefined);
const optTime = (v: unknown) => {
  if (typeof v !== "string" || !v) return undefined;
  const ms = Date.parse(v);
  return Number.isFinite(ms) ? ms : undefined;
};
const finishedStatus = (v: unknown): SubagentBranch["status"] =>
  v === "failed" || v === "canceled" || v === "completed" ? v : "completed";

/**
 * Reconstructs in-turn subagent branches from streamed run events (`subagent_queued`,
 * `subagent_started`, `subagent_finished` plus `subagent: true` child tool events).
 */
export function subagentBranches(events: RunEventLike[] | undefined, since?: string, until?: string): SubagentBranch[] {
  const t = since ? Date.parse(since) : 0;
  const hi = until ? Date.parse(until) : Infinity;
  const branches = new Map<string, PartialBranch>();
  const perBranchOpen = new Map<string, Map<string, number>>();
  const ordered = [...(events ?? [])].sort((a, b) => a.seq - b.seq);

  const ensure = (sid: string, p: Record<string, unknown>, seq: number, at: number): PartialBranch => {
    let b = branches.get(sid);
    if (!b) {
      b = {
        id: sid,
        agentType: optStr(p.subagent_type) ?? "subagent",
        role: optStr(p.subagent_role) ?? "",
        status: "queued",
        createdAt: optTime(p.created_at) ?? at,
        hasLifecycleCreated: optTime(p.created_at) !== undefined,
        calls: [],
        firstSeq: seq,
      };
      branches.set(sid, b);
      perBranchOpen.set(sid, new Map());
    }
    b.firstSeq = Math.min(b.firstSeq, seq);
    if (optStr(p.batch_id) && !b.batchId) b.batchId = optStr(p.batch_id);
    if (optStr(p.subagent_type) && b.agentType === "subagent") b.agentType = optStr(p.subagent_type)!;
    if (optStr(p.subagent_role) && !b.role) b.role = optStr(p.subagent_role)!;
    if (optStr(p.reason) && !b.reason) b.reason = optStr(p.reason);
    if (optStr(p.requested_tier) && !b.requestedTier) b.requestedTier = optStr(p.requested_tier);
    if (optStr(p.subagent_tier) && !b.tier) b.tier = optStr(p.subagent_tier);
    if (optStr(p.subagent_model) && !b.model) b.model = optStr(p.subagent_model);
    if (optStr(p.subagent_effort) && !b.effort) b.effort = optStr(p.subagent_effort);
    const bs = optNum(p.batch_size);
    if (bs !== undefined && bs > 0) b.reportedBatchSize = Math.max(b.reportedBatchSize ?? 0, bs);
    return b;
  };

  for (const e of ordered) {
    const at = Date.parse(e.at);
    if (at < t || at > hi) continue;
    const p = e.payload;
    const sid = optStr(p.subagent_id);
    if (!sid) continue;

    if (e.type === "lifecycle" && (p.state === "subagent_queued" || p.state === "subagent_started" || p.state === "subagent_finished")) {
      const b = ensure(sid, p, e.seq, at);
      const created = optTime(p.created_at);
      if (created !== undefined && !b.hasLifecycleCreated) {
        b.createdAt = created;
        b.hasLifecycleCreated = true;
      }
      if (p.state === "subagent_started") {
        b.startedAt = optTime(p.started_at) ?? b.startedAt ?? at;
        const q = optNum(p.queued_ms);
        if (q !== undefined) b.queuedMs = q;
        if (b.status === "queued") b.status = "running";
      } else if (p.state === "subagent_finished") {
        b.finishedAt = at;
        b.status = finishedStatus(p.status);
        if (optStr(p.error)) b.error = optStr(p.error);
        const q = optNum(p.queued_ms);
        if (q !== undefined) b.queuedMs = q;
        const dur = optNum(p.duration_ms);
        if (dur !== undefined) b.durationMs = dur;
        const tc = optNum(p.tool_calls);
        if (tc !== undefined) b.reportedToolCalls = tc;
        const inp = optNum(p.input_tokens);
        if (inp !== undefined) b.inputTokens = inp;
        const outp = optNum(p.output_tokens);
        if (outp !== undefined) b.outputTokens = outp;
        const cost = optNum(p.cost_usd);
        if (cost !== undefined) b.costUsd = cost;
      }
    } else if (isSubagentEvent(p) && (e.type === "tool_call" || e.type === "tool_result")) {
      const b = ensure(sid, p, e.seq, at);
      const open = perBranchOpen.get(sid)!;
      if (e.type === "tool_call") {
        if (b.status === "queued") {
          b.status = "running";
          b.startedAt ??= at;
        }
        if (p.id) open.set(str(p.id), b.calls.length);
        b.calls.push({ key: e.seq, tool: str(p.tool), input: p.input, done: false });
      } else if (e.type === "tool_result" && p.id && open.has(str(p.id))) {
        const call = b.calls[open.get(str(p.id))!];
        call.done = true;
        if (p.output) call.output = str(p.output);
        if (p.is_error) call.failed = true;
      }
    }
  }

  const list = [...branches.values()];
  const batchCounts = new Map<string, number>();
  let unbatchedCount = 0;
  for (const b of list) {
    if (b.batchId) batchCounts.set(b.batchId, (batchCounts.get(b.batchId) ?? 0) + 1);
    else unbatchedCount++;
  }

  return list
    .sort((a, b) => a.firstSeq - b.firstSeq || a.id.localeCompare(b.id))
    .map((b): SubagentBranch => {
      const batchSize = Math.max(b.reportedBatchSize ?? 0, b.batchId ? (batchCounts.get(b.batchId) ?? 1) : 1);
      const queuedMs = b.queuedMs ?? (b.startedAt !== undefined ? Math.max(0, b.startedAt - b.createdAt) : undefined);
      const durationMs = b.durationMs ?? (b.startedAt !== undefined && b.finishedAt !== undefined ? Math.max(0, b.finishedAt - b.startedAt) : undefined);
      const toolCallsCount = Math.max(b.reportedToolCalls ?? 0, b.calls.length);
      const flags: SubagentBranchFlag[] = [];
      if (b.requestedTier && b.tier && b.requestedTier !== b.tier) flags.push("capped");
      if (b.status === "failed") flags.push("failed");
      if (toolCallsCount >= 20) flags.push("spinning");
      if (queuedMs !== undefined && queuedMs >= 5_000 && (durationMs === undefined || queuedMs > durationMs)) flags.push("queue_bound");
      if (!b.batchId && unbatchedCount >= 3) flags.push("serial");
      return {
        id: b.id,
        ...(b.batchId ? { batchId: b.batchId } : {}),
        batchSize,
        agentType: b.agentType,
        role: b.role,
        ...(b.reason ? { reason: b.reason } : {}),
        ...(b.requestedTier ? { requestedTier: b.requestedTier } : {}),
        ...(b.tier ? { tier: b.tier } : {}),
        ...(b.model ? { model: b.model } : {}),
        ...(b.effort ? { effort: b.effort } : {}),
        status: b.status,
        ...(b.error ? { error: b.error } : {}),
        createdAt: b.createdAt,
        ...(b.startedAt !== undefined ? { startedAt: b.startedAt } : {}),
        ...(b.finishedAt !== undefined ? { finishedAt: b.finishedAt } : {}),
        ...(queuedMs !== undefined ? { queuedMs } : {}),
        ...(durationMs !== undefined ? { durationMs } : {}),
        toolCalls: toolCallsCount,
        ...(b.inputTokens !== undefined ? { inputTokens: b.inputTokens } : {}),
        ...(b.outputTokens !== undefined ? { outputTokens: b.outputTokens } : {}),
        ...(b.costUsd !== undefined ? { costUsd: b.costUsd } : {}),
        calls: b.calls,
        flags,
        firstSeq: b.firstSeq,
      };
    });
}

/** One step of a turn in the Activity tab: what it said, what it thought, and every call it made. */
export type TraceStep = {
  key: string;
  title: string;
  state: ChatStepState;
  kind?: ChatStatusKind;
  tag?: IntentTag;
  intents: string[];
  thinking: string[];
  calls: ToolCall[];
  subagents?: SubagentBranch[];
};

const isSubagentTool = (tool: string) => {
  const bare = bareTool(tool);
  return bare === "run_subagent" || bare === "run_subagents";
};

/**
 * A turn as steps for the Activity tab, the same steps as the chat tab's rail. Calls outside
 * any step (the plan's bookkeeping, a look around before it) join the next step, or the last.
 * Thinking after the final call, before the reply, ends the list as "Writing the reply".
 */
export function turnTrace(events: RunEventLike[] | undefined, since?: string, until?: string): TraceStep[] {
  const calls = toolCalls(events, since, until);
  const notes = turnNotes(events, since, until);
  const branches = subagentBranches(events, since, until);
  const { steps, owner } = buildSteps(calls, false, undefined, undefined, planSnapshots(events, since, until));
  const trace = steps.map((st): TraceStep => ({ key: st.key, title: st.title, state: st.state, ...(st.kind ? { kind: st.kind } : {}), intents: [], thinking: [], calls: [] }));
  const byKey = new Map(trace.map((st) => [st.key, st]));
  const prelude: TraceStep = { key: "prelude", title: "Getting started", state: "done", intents: [], thinking: [], calls: [] };
  const reply: TraceStep = { key: "reply", title: "Writing the reply", state: "done", kind: "thinking", intents: [], thinking: [], calls: [] };
  const home = (i: number): TraceStep => {
    for (let j = i; j < calls.length; j++) if (owner[j]) return byKey.get(owner[j]!)!;
    for (let j = i - 1; j >= 0; j--) if (owner[j]) return byKey.get(owner[j]!)!;
    return prelude;
  };
  for (const [i, call] of calls.entries()) home(i).calls.push(call);
  for (const n of notes) {
    const i = n.before === undefined ? -1 : calls.findIndex((c) => c.key === n.before);
    const st = i < 0 ? reply : home(i);
    if (n.kind === "thinking") st.thinking.push(n.text);
    else {
      st.intents.push(n.text);
      if (n.tag) st.tag = n.tag;
    }
  }
  if (branches.length > 0) {
    const workSteps = [prelude, ...trace];
    const anySubagentStep = [...workSteps].reverse().find((st) => st.calls.some((c) => isSubagentTool(c.tool)));
    const fallbackStep = anySubagentStep ?? trace.at(-1) ?? prelude;
    for (const branch of branches) {
      let matched: { step: TraceStep; key: number } | undefined;
      for (const st of workSteps) {
        for (const c of st.calls) {
          if (isSubagentTool(c.tool) && c.key <= branch.firstSeq && (!matched || c.key > matched.key)) {
            matched = { step: st, key: c.key };
          }
        }
      }
      const target = matched?.step ?? fallbackStep;
      (target.subagents ??= []).push(branch);
    }
  }
  const showPrelude = prelude.calls.length > 0 || prelude.thinking.length > 0 || (prelude.subagents?.length ?? 0) > 0;
  return [...(showPrelude ? [prelude] : []), ...trace, ...(reply.thinking.length ? [reply] : [])];
}

// ---- model names: a chat's model may be its agent definition's alias ("opus-5.5"), which the live catalog doesn't list ----

const modelKey = (id: string) => id.toLowerCase().replace(/^claude-/, "").replace(/[._]/g, "-");

/** An id made readable when nothing better is known: "opus-5.5" → "Opus 5.5", "gpt-5-codex" → "GPT-5 Codex". */
export function readableModelId(id: string): string {
  if (/^gpt-/i.test(id)) {
    const [, version, ...rest] = id.split("-");
    return [`GPT-${version}`, ...rest.map((w) => w[0].toUpperCase() + w.slice(1))].join(" ");
  }
  // Consecutive number parts are one version: "haiku-5-5" is Haiku 5.5.
  const words: string[] = [];
  for (const w of id.replace(/^claude-/i, "").split("-")) {
    const prev = words.at(-1);
    if (/^\d+$/.test(w) && prev && /^\d+(\.\d+)*$/.test(prev)) words[words.length - 1] = `${prev}.${w}`;
    else words.push(/^[a-z]/.test(w) ? w[0].toUpperCase() + w.slice(1) : w);
  }
  return words.join(" ");
}

/** The catalog's label for a model id, matching an alias to the catalog model it names ("opus-5.5" ↔ "claude-opus-5-5"). */
export function catalogModelLabel(models: readonly { id: string; label: string }[], id: string): string {
  const exact = models.find((m) => m.id === id);
  if (exact) return exact.label;
  const key = modelKey(id);
  return models.find((m) => modelKey(m.id) === key || modelKey(m.label.replace(/\s+/g, "-")) === key)?.label ?? readableModelId(id);
}
