import type { Page, Route } from "@playwright/test";
import type { components } from "../lib/api/schema";

/**
 * In-memory stand-in for the chat REST contract (api/openapi.yaml, tag `chats`)
 * plus the fake harness: an assistant reply that echoes the prompt, tagged with
 * the selected harness/model. Swap `installChatApi` for the real stack once
 * LAZYAGENTS-11 lands; the spec only talks to the UI.
 *
 * A message starting with "app:" is answered with an interactive app.
 * A message starting with "building-app:" keeps the turn running while it writes one.
 * A message starting with "steps:" keeps the turn running with a plan in progress.
 * A message starting with "narrated:" keeps the turn running after narrating a decision, with thinking behind it.
 * A message starting with "between:" keeps the turn running after an edit has finished, before its next call.
 * POST /chats/{id}/asides records the question in `asides`.
 * A message starting with "slow:" keeps the turn running until it is cancelled
 * or interrupted: a message sent while a turn runs stops it, and the next reply
 * echoes "<new> (interrupting: <previous>)", like the server's merged turn;
 * its run reports one tool call (read_page Eng/Plan) for the live activity line.
 * Replies carry token usage and cost and a run_id whose events (GET /runs/{id}) hold the turn's tool calls.
 *
 * Assistant memory (LAZYAGENTS-71): an in-memory store behind /memories. A message
 * "remember: <title>" makes the turn call save_memory (creating the entry, sourced
 * from the chat) and "forget: <title>" calls forget_memory (deleting it); both put a
 * successful tool_result into the turn's run events, between the user message and the reply.
 *
 * Assistant personas (LAZYAGENTS-86): `opts.personas` seeds GET /personas (none by
 * default, so the built-in Assistant is the default). GET /chats honours persona_id
 * (omitted: the default persona), POST /chats takes it (omitted: the default), and
 * `updatePersona` edits one and pushes `persona.updated` like the real stream.
 * `chatPersonaFilters` records the persona_id each GET /chats asked for. A chat's
 * `guest_persona_ids` are its joined personas (payload `participants`).
 */

type Harness = "claude-code" | "codex";
type State = "idle" | "running" | "failed";
type Effort = "low" | "medium" | "high" | "xhigh" | "max";
type Chat = {
  id: string; project?: string; title: string; agent_id: string; harness: Harness; model: string; state: State;
  error?: string; current_run_id?: string; archived: boolean; revision: number; message_count: number;
  created_at: string; updated_at: string; last_message_at?: string; persona_id?: string; repo_url?: string; pending_repo_url?: string; repositories?: { repo_url: string; directory: string; work_branches: string[] }[]; work_branches?: string[]; commit_email?: string; workspace_path?: string; temporary?: boolean;
  effort?: Effort; auto_model?: boolean;
  unread?: number;
  /** A thread or second-opinion aside anchored to a message of parent_chat_id. Hidden from the chat list. */
  parent_chat_id?: string; anchor_message_id?: string; second_opinion?: boolean; hidden?: boolean;
  // Personas that joined besides the host (chat_participants); listed by their persona filter too.
  guest_persona_ids?: string[];
  /** The space the chat is in (PATCH space_id). */
  space?: components["schemas"]["ChatSpaceRef"];
};
type Message = {
  id: string; seq: number; role: "user" | "assistant" | "system"; body_md: string;
  harness?: Harness; model?: string; created_at: string;
  context_refs?: unknown[]; citations?: unknown[]; run_id?: string; code_changes?: unknown[]; attachments?: unknown[];
};
export type MockMemory = {
  id: string; title: string; summary: string; body: string; tags: string[]; type: string;
  source: string; source_chat_id?: string; created_at: string; updated_at: string;
};

// What the [[ picker can offer (api: GET /knowledge/suggest). OTHER-9 is deleted after the picker offers it, so sending it fails.
const PLAN = { kind: "artifact", id: "11111111-1111-4111-8111-111111111111", title: "Plan", artifact_type: "note", path: "Eng/Plan", href: "/wiki/Eng/Plan" };
const REPORT = { kind: "artifact", id: "22222222-2222-4222-8222-222222222222", title: "Q3 report", artifact_type: "report", href: "/artifacts/22222222-2222-4222-8222-222222222222" };
const TICKET = { kind: "ticket", id: "33333333-3333-4333-8333-333333333333", title: "Fix payouts", display_id: "WEB-3", href: "/tickets/WEB-3", status: "todo" };
const OTHER = { kind: "ticket", id: "44444444-4444-4444-8444-444444444444", title: "Elsewhere", display_id: "OTHER-9", href: "/tickets/OTHER-9", status: "todo" };
const TARGETS: Array<{ title: string; path?: string; display_id?: string }> = [PLAN, REPORT, TICKET, OTHER];

// Bootstrap agents: two main agents a chat can answer as, and the Personal Assistant, which can't be picked.
export const AGENTS = [
  { id: "aaaaaaaa-0000-4000-8000-000000000001", name: "Atlas", handle: "atlas", kind: "main", color_index: 0, role: "Tech lead", specialty: "Plans and reviews", model: "opus-5.5", status: "idle" },
  { id: "aaaaaaaa-0000-4000-8000-000000000002", name: "Juno", handle: "juno", kind: "main", color_index: 3, role: "Mastermind", specialty: "Product and UX", model: "opus-5.5", status: "idle" },
  { id: "aaaaaaaa-0000-4000-8000-000000000003", name: "Helper", handle: "helper", kind: "assistant", color_index: 5, role: "Implementer", specialty: "Code", model: "sonnet-5.5", status: "idle" },
];
const USAGE = { input_tokens: 48200, output_tokens: 1300, cached_input_tokens: 41000, uncached_input_tokens: 7200, unreported_input_tokens: 0, cost_usd: 0.0421 };

export type Posted = { chat: string; body: Record<string, unknown> };
export type MockPersona = {
  id: string; name: string; tone: string; color: string; avatar_url?: string; custom_instructions: string;
  default_harness?: Harness; default_model?: string; default_effort?: Effort;
  capabilities: { code: boolean; images: boolean; personas?: boolean; svg?: boolean; workflows?: boolean }; repos: string[];
  is_default: boolean; chat_count: number; last_used_at?: string; revision: number; created_at: string; updated_at: string;
};
export type MockProposal = {
  id: string; chat_id: string; name: string; tone: string; color: string; custom_instructions: string; reason: string;
  state: "pending" | "approved" | "declined"; proposed_by?: { id: string; name: string; color: string }; created_at: string;
  avatar_state?: "pending" | "ready" | "failed"; avatar_attachment_id?: string;
};
export type MockOptions = { codexAvailable?: boolean; replyDelayMs?: number; personas?: MockPersona[]; suggestions?: Array<{ title: string; prompt: string; icon: string }>; emails?: string[];
  /** GET /chat-spaces; PATCH /chats/{id} with space_id moves a chat into one (none by default). */
  spaces?: components["schemas"]["ChatSpace"][];
  /** Keys of work with tickets: stopping it is refused (409). */
  workWithTickets?: string[];
  /** false: a fresh install that hasn't finished the Welcome Wizard. */
  onboarded?: boolean;
  /** true: Dev workspace is enabled in Settings. */
  devWorkspaceEnabled?: boolean };

/** A persona fixture for the persona specs. */
export function persona(i: number, over: Partial<MockPersona> = {}): MockPersona {
  const t = `2026-11-0${Math.min(i, 9)}T09:00:00.000Z`;
  return {
    id: `77777777-7777-4777-8777-${String(i).padStart(12, "0")}`,
    name: `Persona ${i}`, tone: "neutral", color: "#8b8fff", custom_instructions: "", capabilities: { code: false, images: false }, repos: [], is_default: false,
    chat_count: 0, revision: 1, created_at: t, updated_at: t, ...over,
  };
}

export const catalog = (codexAvailable: boolean): components["schemas"]["ChatHarnessModels"][] => [
  {
    harness: "claude-code", label: "Claude Code", available: true,
    models: [
      { id: "opus-5.5", label: "Opus 5.5", default: true, efforts: ["low", "medium", "high", "xhigh", "max"] },
      { id: "sonnet-5.5", label: "Sonnet 5.5", default: false, efforts: ["low", "medium", "high", "xhigh", "max"] },
    ],
  },
  {
    harness: "codex", label: "Codex", available: codexAvailable,
    ...(codexAvailable ? {} : { unavailable_reason: "No harness:openai secret" }),
    models: [
      { id: "gpt-5-codex", label: "gpt-5-codex", default: true, efforts: ["low", "medium", "high"], default_effort: "medium" },
      { id: "gpt-5-mini", label: "gpt-5-mini", default: false, efforts: [] },
    ],
  },
];

const err = (status: number, code: string, message: string, field?: string) => ({
  status,
  body: { code, message, ...(field ? { field } : {}) },
});

export function installChatApi(page: Page, opts: MockOptions = {}) {
  const codexAvailable = opts.codexAvailable ?? true;
  const delay = opts.replyDelayMs ?? 300;
  const chats: Chat[] = [];
  // Dock chat switcher lists (api: GET/POST /dock-chats), scope → chat ids, newest last.
  const dockChats = new Map<string, string[]>();
  const messages = new Map<string, Message[]>();
  const timers = new Map<string, ReturnType<typeof setTimeout>>();
  // The running turn's prompt per chat, which an interruption folds in.
  const prompts = new Map<string, string>();
  const runEvents = new Map<string, Array<{ seq: number; type: string; at: string; payload: Record<string, unknown> }>>();
  const unhandled: string[] = [];
  const spaces = (opts.spaces ?? []).map((x) => ({ ...x }));
  const workRequests: string[] = [];
  const connectors: { id: string; name: string; slug: string; url: string; auth_kind: unknown; status: string; last_error: string; revision: number; created_at: string; persona_ids: string[]; tools: { name: string; description: string; write: boolean; policy: string }[] }[] = [];
  const connectorApprovals: Record<string, unknown>[] = [];
  const connectorDecisions: string[] = [];
  // Proposed ticket edits; one with `refuse` set answers its apply with that 409 message.
  const ticketChanges: Array<Record<string, unknown> & { id: string; refuse?: string }> = [];
  const ticketChangeDecisions: string[] = [];
  const apiSecrets: Record<string, unknown>[] = [];
  const apiSecretPosts: Record<string, unknown>[] = [];
  const apiSecretSignIns: string[] = [];
  // The public half of an OAuth secret, as the API returns it: never the client secret.
  const oauthView = (o: Record<string, unknown>) => ({ authorize_url: o.authorize_url, token_url: o.token_url, client_id: o.client_id, scopes: o.scopes ?? [],
    has_client_secret: Boolean(o.client_secret), error: "" });
  const secretApprovals: Record<string, unknown>[] = [];
  const secretDecisions: string[] = [];
  const secretProposals: Record<string, unknown>[] = [];
  const chatSecrets: Record<string, unknown>[] = [];
  const scheduledTasks: Record<string, unknown>[] = [];
  const posted: Posted[] = [];
  const asides: string[] = [];
  const secondOpinions: Array<{ chat: string; body: string; harness: Harness; model: string; anchor_message_id?: string; repository?: string }> = [];
  const suggestions = opts.suggestions ?? [];
  const created: Array<Record<string, unknown>> = [];
  const artifactForms: string[] = [];
  const memories: MockMemory[] = [];
  const memoryRequests: string[] = [];
  const memoryPatches: Array<Record<string, unknown>> = [];
  const memoryImports: Array<Record<string, unknown>> = [];
  const wikiPages: Array<{ path: string; body_md: string; project_key?: string }> = [];
  // The welcome's "Pick up where you left off" reads these; specs push into them.
  const inbox: Record<string, unknown>[] = [];
  const dock: Record<string, unknown>[] = [];
  // Assistant personas (ADR: Assistant personas): private to the caller, at most one default.
  const personas: MockPersona[] = [...(opts.personas ?? [])];
  let imageEngine = "auto";
  const repositorySources: { kind: "repository" | "organization"; name: string }[] = personas.flatMap((p) => p.repos.map((name) => ({ kind: "repository" as const, name })));
  // Personas the chat's personas proposed (several personas in one chat).
  const proposals: MockProposal[] = [];
  const decisions: Array<{ id: string; decision: string }> = [];
  const defaultPersona = () => personas.find((p) => p.is_default);
  const personaRequests: string[] = [];
  // Chat videos by chat: "video: <state>" puts one on the reply, "video-live: <stage>" shows one while the turn runs.
  const videos = new Map<string, Record<string, unknown>[]>();
  // Chat audio the same way: "audio: <state>" and "audio-live: <stage>".
  const audio = new Map<string, Record<string, unknown>[]>();
  const codeReviews = new Map<string, components["schemas"]["CodeReview"][]>();
  const pushRequests = new Map<string, components["schemas"]["PushRequest"][]>();
  const refusePush = new Map<string, string>();
  const pushPolicies: components["schemas"]["RepositoryPushPolicy"][] = [];
  const devWorkspaceOpenBranches: components["schemas"]["OpenDevWorkspaceBranchRequest"][] = [];
  const devWorkspace: components["schemas"]["DevWorkspace"] = {
    enabled: !!opts.devWorkspaceEnabled,
    nix_mode: "default",
    repos: [],
    extra_packages: [],
    tmux_prefix: "C-b",
    state: opts.devWorkspaceEnabled ? "ready" : "stopped",
    action: null,
    step: null,
    error: null,
    port: null,
    arch: null,
    updated_at: new Date().toISOString(),
  };
  function mockPushRequest(title: string, runId?: string, messageId?: string): components["schemas"]["PushRequest"] {
    return {
      id: uuid(),
      repository: "https://github.com/acme/alpha.git",
      branch: "feat/" + title.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, ""),
      base_branch: "main",
      title: title || "Update alpha",
      body: "Changes for review.",
      draft: false,
      state: messageId ? "pending" : "staging",
      auto: false,
      commits: [{ sha: "abcdef1234567890abcdef1234567890abcdef12", subject: title || "Update alpha" }],
      files: [{ path: "src/app.ts", status: "modified", additions: 2, deletions: 1, binary: false, truncated: false }],
      created_at: now(),
      run_id: runId,
      message_id: messageId,
    };
  }
  // The persona_id each GET /chats asked for ("" when omitted, i.e. the default).
  const chatPersonaFilters: string[] = [];
  let n = 0;
  const uuid = () => `00000000-0000-4000-8000-${String(++n).padStart(12, "0")}`;
  const now = () => new Date().toISOString();
  const label = (h: Harness, m: string) => {
    const g = catalog(true).find((x) => x.harness === h)!;
    return `${g.label} · ${g.models.find((x) => x.id === m)?.label ?? m}`;
  };
  const add = (c: Chat, role: Message["role"], body: string, extra: Partial<Message> = {}) => {
    const list = messages.get(c.id)!;
    const m: Message = { id: uuid(), seq: list.length + 1, role, body_md: body, created_at: now(), ...extra };
    list.push(m);
    c.message_count = list.length;
    c.last_message_at = c.updated_at = m.created_at;
    return m;
  };
  const touch = (c: Chat) => {
    c.revision++;
    c.updated_at = now();
  };

  const emit = (c: Chat) =>
    page
      .evaluate((ids) => {
        const data = JSON.stringify({ type: "chat.updated", ids });
        for (const s of (window as unknown as { __sse: Array<{ onmessage?: (e: { data: string }) => void }> }).__sse) s.onmessage?.({ data });
      }, [c.id, ...(c.parent_chat_id ? [c.parent_chat_id] : [])])
      .catch(() => undefined); // page may be navigating; the next fetch catches up

  function memoryEvents(c: Chat, prompt: string) {
    const save = /^remember:\s*(.+)$/.exec(prompt);
    const forget = /^forget:\s*(.+)$/.exec(prompt);
    if (!save && !forget) return;
    const runId = c.current_run_id!;
    const events = runEvents.get(runId) ?? [];
    // Strictly after the user message, so the turn window (since < at) holds.
    const lastUser = messages.get(c.id)!.findLast((x) => x.role === "user");
    const at = new Date(Date.parse(lastUser?.created_at ?? now()) + 1).toISOString();
    const tool = (name: string, output: unknown) => {
      const id = `mem-${events.length + 1}`;
      events.push({ seq: events.length + 1, type: "tool_call", at, payload: { id, tool: `mcp__lazyagents__${name}`, input: {} } });
      events.push({ seq: events.length + 1, type: "tool_result", at, payload: { id, tool: `mcp__lazyagents__${name}`, output: JSON.stringify(output) } });
    };
    if (save) {
      const title = save[1].trim();
      const t = now();
      const m: MockMemory = {
        id: uuid(), title, summary: `About ${title}`, body: `Details about ${title}`, tags: ["chat"], type: "fact",
        source: `chat ${c.id}`, source_chat_id: c.id, created_at: t, updated_at: t,
      };
      memories.unshift(m);
      tool("save_memory", { id: m.id, action: "created", title });
    } else if (forget) {
      const title = forget[1].trim();
      const i = memories.findIndex((x) => x.title === title);
      if (i < 0) return;
      const [gone] = memories.splice(i, 1);
      tool("forget_memory", { forgotten: gone.id, title });
    }
    runEvents.set(runId, events);
  }

  // "web:" runs a search with three results; "webnone:" gets the same search and uses none of it.
  function webEvents(c: Chat) {
    const runId = c.current_run_id!;
    const events = runEvents.get(runId) ?? [];
    const lastUser = messages.get(c.id)!.findLast((x) => x.role === "user");
    const at = new Date(Date.parse(lastUser?.created_at ?? now()) + 1).toISOString();
    const links = [{ title: "Pricing page", url: "https://www.example.com/pricing" }, { title: "Latency notes", url: "https://b.example.org/latency" }, { title: "Unused forum", url: "https://forum.example.net/t/1" }];
    const id = `web-${events.length + 1}`;
    events.push({ seq: events.length + 1, type: "tool_call", at, payload: { id, tool: "WebSearch", input: { query: "tts pricing" } } });
    events.push({ seq: events.length + 1, type: "tool_result", at, payload: { id, tool: "WebSearch", output: `Links: ${JSON.stringify(links)}` } });
    runEvents.set(runId, events);
  }

  function finishTurn(c: Chat, prompt: string) {
    c.state = "idle";
    if (prompt.startsWith("video:") || prompt.startsWith("video-live:")) {
      const reply = add(c, "assistant", "Here's the render: 15 s at 1080p. I checked four stills first.", { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      const list = videos.get(c.id) ?? [];
      if (prompt.startsWith("video:")) list.push(mockVideo(prompt.slice(6).trim(), c.current_run_id!));
      for (const v of list) if (!v.message_id && v.run_id === c.current_run_id) v.message_id = reply.id;
      videos.set(c.id, list);
      void emit(c);
      return;
    }
    if (prompt.startsWith("audio:") || prompt.startsWith("audio-live:")) {
      const reply = add(c, "assistant", "Here's the render: 24 s of MIDI through a soundfont. I measured it but can't listen.", { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      const list = audio.get(c.id) ?? [];
      if (prompt.startsWith("audio:")) list.push(mockAudio(prompt.slice(6).trim(), c.current_run_id!));
      for (const a of list) if (!a.message_id && a.run_id === c.current_run_id) a.message_id = reply.id;
      audio.set(c.id, list);
      void emit(c);
      return;
    }
    if (prompt.startsWith("push:") || prompt.startsWith("push-live:")) {
      const label = prompt.replace(/^push(?:-live)?:\s*/, "").trim() || "changes";
      const reply = add(c, "assistant", `Staged ${label} for your review.`, { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      const list = pushRequests.get(c.id) ?? [];
      if (prompt.startsWith("push:")) list.push(mockPushRequest(label, c.current_run_id, reply.id));
      for (const r of list) {
        if (!r.message_id && r.run_id === c.current_run_id) {
          r.message_id = reply.id;
          if (r.state === "staging") r.state = "pending";
        }
      }
      pushRequests.set(c.id, list);
      void emit(c);
      return;
    }
    memoryEvents(c, prompt);
    if (prompt.startsWith("web:") || prompt.startsWith("webnone:")) webEvents(c);
    if (prompt.startsWith("web:") || prompt.startsWith("webnone:")) {
      const body = prompt.startsWith("web:") ? "The answer.\n\nSources:\n- https://example.com/pricing\n- https://b.example.org/latency" : "I found nothing useful.";
      add(c, "assistant", body, { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE, ...(prompt.startsWith("web:") ? { citations: [{ target: TICKET, title: TICKET.title }] } : {}) });
      void emit(c);
      return;
    }
    // "cite:" prompts get citations (one duplicate, one versioned section, one ticket).
    const citations = prompt.startsWith("cite:")
      ? [
          { target: REPORT, artifact_id: REPORT.id, title: REPORT.title, version_id: "55555555-5555-4555-8555-555555555555", version: "v2", section: "risks" },
          { target: REPORT, artifact_id: REPORT.id, title: REPORT.title, version_id: "55555555-5555-4555-8555-555555555555", version: "v2", section: "risks" },
          { target: PLAN, artifact_id: PLAN.id, title: PLAN.title, path: PLAN.path },
          { target: TICKET, title: TICKET.title },
        ]
      : undefined;
    // "code:" replies like a coding persona: changed files (two hunks, an added file, a binary) and a long fence.
    if (prompt.startsWith("code:")) {
      const long = Array.from({ length: 25 }, (_, i) => `  const v${i} = ${i};`).join("\n");
      add(c, "assistant", `Done.\n\n\`\`\`ts\nfunction run() {\n${long}\n}\n\`\`\``, {
        harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE,
        code_changes: [
          {
            path: "src/app.ts", status: "modified", additions: 2, deletions: 1, binary: false, truncated: false,
            patch: "@@ -1,3 +1,4 @@\n import a from \"a\";\n-const x = 1;\n+const x = 2;\n+const y = 3;\n export {};\n@@ -20,2 +21,2 @@\n function f() {\n-  return 1;\n+  return 2;\n }\n",
          },
          { path: "cmd/main.go", status: "added", additions: 3, deletions: 0, binary: false, truncated: false, patch: "@@ -0,0 +1,3 @@\n+package main\n+\n+func main() {}\n" },
          { path: "assets/logo.png", status: "modified", additions: 0, deletions: 0, binary: true, truncated: false },
        ],
      });
      if (!codeReviews.has(c.id)) {
        codeReviews.set(c.id, [
          {
            repository: c.repo_url ?? "https://github.com/acme/alpha.git",
            branch: "feat/code-review",
            base_sha: "1111111111111111111111111111111111111111",
            head_sha: "abcdef1234567890abcdef1234567890abcdef12",
            commits: [{ sha: "abcdef1234567890abcdef1234567890abcdef12", subject: "Update app and add main" }],
            files: [
              {
                path: "src/app.ts", status: "modified", additions: 2, deletions: 1, binary: false, truncated: false,
                patch: "@@ -1,3 +1,4 @@\n import a from \"a\";\n-const x = 1;\n+const x = 2;\n+const y = 3;\n export {};\n@@ -20,2 +21,2 @@\n function f() {\n-  return 1;\n+  return 2;\n }\n",
              },
              { path: "cmd/main.go", status: "added", additions: 3, deletions: 0, binary: false, truncated: false, patch: "@@ -0,0 +1,3 @@\n+package main\n+\n+func main() {}\n" },
              { path: "assets/logo.png", status: "modified", additions: 0, deletions: 0, binary: true, truncated: false },
              { path: "docs/new-guide.md", old_path: "docs/old-guide.md", status: "renamed", additions: 0, deletions: 0, binary: false, truncated: false },
              { path: "legacy/drop.ts", status: "deleted", additions: 0, deletions: 1, binary: false, truncated: false, patch: "@@ -1 +0,0 @@\n-export const old = true;\n" },
            ],
            dirty: false,
            live: false,
            tree: [
              { path: "README.md", size: 28, binary: false, content: "# Alpha\n\nTracked readme body.\n", truncated: false },
              { path: "src/config.ts", size: 35, binary: false, content: "export const API_URL = '/api/v1';\n", truncated: false },
              { path: "src/app.ts", size: 120, binary: false, content: "import a from \"a\";\nconst x = 2;\n", truncated: false },
              { path: "cmd/main.go", size: 32, binary: false, content: "package main\n\nfunc main() {}\n", truncated: false },
              { path: "docs/new-guide.md", size: 22, binary: false, content: "# Renamed Guide\n", truncated: false },
              { path: "assets/logo.png", size: 128, binary: true, truncated: false },
              { path: "assets/unchanged.bin", size: 256, binary: true, truncated: false },
              { path: "data/huge.sql", size: 512000, binary: false, truncated: true },
              { path: "docs/notes.txt", size: 50000, binary: false, content: "First part of truncated notes\n", truncated: true },
            ],
            tree_truncated: false,
            updated_at: now(),
          },
        ]);
      }
      void emit(c);
      return;
    }
    // "app:" replies with an interactive app: a counter, plus a fetch the sandbox must block.
    if (prompt.startsWith("app:")) {
      const app = `<!DOCTYPE html>\n<button id="b">Count: 0</button><p id="net">pending</p>\n<script>let n=0;b.onclick=()=>{b.textContent="Count: "+(++n)};fetch("/api/v1/bootstrap").then(()=>net.textContent="reached",()=>net.textContent="blocked");</script>`;
      add(c, "assistant", `Here you go.\n\n\`\`\`app\n${app}\n\`\`\``, { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return;
    }
    // "dispatch all:" offers WEB-3, WEB-4 and WEB-5 in one card.
    if (prompt.startsWith("dispatch all:")) {
      add(c, "assistant", "Filed the epic's tickets.\n\n```dispatch\nWEB-3\nWEB-4\nWEB-5\n```", { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return;
    }
    // "dispatch:" offers to start WEB-3's run.
    if (prompt.startsWith("dispatch:")) {
      add(c, "assistant", "Filed WEB-3 and assigned it to @pike.\n\n```dispatch\nWEB-3\n```", { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return;
    }
    // "research:" replies with a plan to approve.
    if (prompt.startsWith("research:")) {
      add(c, "assistant", "Here's a plan.\n\n```research-plan\nLocal TTS\n- Quality | Which sounds best?\n- Latency | How fast is it?\n```", { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return;
    }
    // "rich:" replies with citations, math, a diagram, a moment in a video and a choice.
    if (prompt.startsWith("rich:")) {
      const body = [
        "A claim [1] and another [2], not [9].",
        "Energy is $$E = mc^2$$ and it costs $5 or $10.",
        "```mermaid\ngraph TD\n  A[Start] --> B[Finish]\n```",
        "```mermaid\nthis is not a diagram !!\n```",
        "```recommend\nhttps://www.youtube.com/watch?v=dQw4w9WgXcQ\nShort and useful.\n```",
        "The key part is at [1:05](https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=65).",
        "```choices\nWhich one?\n- Kokoro | Free, local\n- Cartesia\n```",
        "Sources:\n1. [Pricing page](https://example.com/pricing)\n2. [[Eng/Plan]]",
      ].join("\n\n");
      add(c, "assistant", body, { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return;
    }
    // "gfm:" replies with GitHub-flavored markdown.
    if (prompt.startsWith("gfm:")) {
      add(c, "assistant", "| Option | Cost |\n|---|--:|\n| OpenAI tts-1 | $0.015 |\n| Cartesia | $0.011 |\n\n- [x] Shipped\n- [ ] Pending\n\n~~old~~\n\n> Quoted", { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return;
    }
    // "recommend:" replies with a video, a site and a page with no preview.
    if (prompt.startsWith("recommend:")) {
      const fence = (u: string, why: string) => `\`\`\`recommend\n${u}\n${why}\n\`\`\``;
      add(c, "assistant", `Two things:\n\n${fence("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "Short and useful.")}\n\n${fence("https://trailatlas.example/routes", "Start with the river loop.")}\n\nAnd:\n\n${fence("https://notes.example/grinders", "Best comparison.")}`, { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return;
    }
    // "playground: <id>" replies with a card for the chat's playground.
    if (prompt.startsWith("playground:")) {
      add(c, "assistant", `It's running.\n\n\`\`\`playground\n${prompt.slice(11).trim()}\n\`\`\``, { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return;
    }
    // "canvas: <id>" replies with a card for that canvas.
    if (prompt.startsWith("canvas:")) {
      add(c, "assistant", `Drafted it.\n\n\`\`\`canvas\n${prompt.slice(7).trim()}\n\`\`\``, { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return;
    }
    // "svg:" replies with an SVG image; "badsvg:" with one the browser can't draw.
    if (prompt.startsWith("svg:") || prompt.startsWith("badsvg:")) {
      const svg = prompt.startsWith("svg:") ? `<svg viewBox="0 0 40 20" width="40" height="20"><script>document.title="ran"</script><rect width="40" height="20" fill="#36c"/></svg>` : "<svg><rect></svg>";
      add(c, "assistant", `Here you go.\n\n\`\`\`svg-image\n${svg}\n\`\`\``, { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return;
    }
    // "viz:" replies with a themed diagram, a step-through and a chart; "badchart:" with a chart it can't draw.
    if (prompt.startsWith("viz:") || prompt.startsWith("badchart:")) {
      const box = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 320 120" width="320" height="120"><title>Client and server</title><rect x="24" y="36" width="104" height="48" rx="8" fill="var(--viz-panel)" stroke="var(--viz-line)" stroke-width="1.5"/><text x="76" y="65" text-anchor="middle" font-family="system-ui, sans-serif" font-size="13" fill="var(--viz-ink)">Client</text><g data-step="2"><rect x="192" y="36" width="104" height="48" rx="8" fill="var(--viz-1-soft)" stroke="var(--viz-1)" stroke-width="1.5"/><text x="244" y="65" text-anchor="middle" font-family="system-ui, sans-serif" font-size="13" fill="var(--viz-ink)">Server</text></g></svg>`;
      const chart = JSON.stringify({ type: "bar", title: "Requests by region", x: { label: "Region" }, y: { label: "Requests", unit: "K" }, categories: ["us", "eu", "ap"], series: [{ name: "2025", values: [120, 90, 40] }, { name: "2026", values: [160, 110, 75] }] });
      const body = prompt.startsWith("viz:") ? `Here.\n\n\`\`\`svg-image\n${box.replace(' data-step="2"', "")}\n\`\`\`\n\n\`\`\`svg-steps\n${box}\n1. The client starts alone\n2. The server appears\n\`\`\`\n\n\`\`\`chart\n${chart}\n\`\`\`` : "Oops.\n\n```chart\n{\"type\":\"pie\"}\n```";
      add(c, "assistant", body, { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return;
    }
    // "effort:" prompts run at an effort Vesper picked: it aimed for extra high, which the model lacks, after a retry.
    const effort = prompt.startsWith("effort:") ? { effort: "high" as const, effort_level: "xhigh" as const, effort_reasons: ["effort_mismatch" as const] } : {};
    add(c, "assistant", `Echo: ${prompt}`, { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE, ...effort, ...(citations ? { citations } : {}) });
    void emit(c);
  }
  function ref(c: Chat) {
    const a = AGENTS.find((x) => x.id === c.agent_id)!;
    const p = personas.find((x) => x.id === c.persona_id);
    const summary = (x: MockPersona) => ({ id: x.id, name: x.name, color: x.color, ...(x.avatar_url ? { avatar_url: x.avatar_url } : {}) });
    const guests = (c.guest_persona_ids ?? []).flatMap((id) => personas.filter((x) => x.id === id && x.id !== c.persona_id));
    return {
      ...c, agent_id: undefined, persona_id: undefined, guest_persona_ids: undefined,
      participants: [...(p ? [summary(p)] : []), ...guests.map(summary)],
      agent: { id: a.id, name: a.name, handle: a.handle, color_index: a.color_index },
      ...(p ? { persona: { id: p.id, name: p.name, color: p.color, ...(p.avatar_url ? { avatar_url: p.avatar_url } : {}), capabilities: p.capabilities } } : {}),
    };
  }
  const updatePersona = (id: string, patch: Partial<MockPersona>) => {
    const p = personas.find((x) => x.id === id)!;
    Object.assign(p, patch, { revision: p.revision + 1 });
    return page
      .evaluate((pid) => {
        const data = JSON.stringify({ type: "persona.updated", ids: [pid] });
        for (const s of (window as unknown as { __sse: Array<{ onmessage?: (e: { data: string }) => void }> }).__sse) s.onmessage?.({ data });
      }, id)
      .catch(() => undefined);
  };

  // Your profile (Settings → Profile): shared by /bootstrap and /me so edits show in the sidebar.
  const emails = opts.emails ?? ["liam@example.com"];
  const me: Record<string, unknown> & { id: string; name: string; emails: string[] } = {
    id: "00000000-0000-4000-8000-0000000000aa", name: "Liam", email: emails[0], emails, initials: "L", role_title: "Owner",
    harness_connected: true, ...(opts.onboarded === false ? {} : { onboarded_at: "2026-11-01T09:00:00.000Z" }),
  };
  const ownEmail = (e: unknown) => me.emails.find((x) => x.toLowerCase() === String(e).trim().toLowerCase());
  const profileRequests: string[] = [];
  const commitEmailRequests: string[] = [];
  const initialsOf = (name: string) => name.trim().split(/\s+/).map((w) => w[0]).slice(0, 2).join("").toUpperCase();

  async function handle(route: Route) {
    const req = route.request();
    const url = new URL(req.url());
    const path = url.pathname.replace(/^\/api\/v1/, "");
    const method = req.method();
    const body = () => (req.postDataJSON() ?? {}) as Record<string, unknown>;
    const json = (data: unknown, status = 200) =>
      route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
    const fail = (e: ReturnType<typeof err>) => json(e.body, e.status);

    if (/^\/chats\/[^/]+\/canvases$/.test(path)) return json({ canvases: [] });
    if (/^\/chats\/[^/]+\/playground$/.test(path)) return json({ playground: null });
    const videoList = /^\/chats\/([^/]+)\/videos$/.exec(path);
    if (videoList) return json({ videos: videos.get(videoList[1]) ?? [] });
    const audioList = /^\/chats\/([^/]+)\/audio$/.exec(path);
    if (audioList) return json({ audio: audio.get(audioList[1]) ?? [] });
    if (/^\/chats\/[^/]+\/audio\/[^/]+\/content$/.test(path)) return route.fulfill({ status: 200, contentType: "audio/wav", body: mockWav() });
    const frame = /^\/chats\/[^/]+\/videos\/[^/]+\/frames\/([a-z]+)\/(\d+)$/.exec(path);
    if (frame) return route.fulfill({ status: 200, contentType: "image/svg+xml", body: frameSvg(frame[1], Number(frame[2])) });
    if (/^\/library\/[^/]+\/poster$/.test(path)) return route.fulfill({ status: 200, contentType: "image/svg+xml", body: frameSvg("poster", 0) });
    if (path === "/library" && method === "GET" && url.searchParams.get("kind") === "video") {
      const all = [...videos.values()].flat().filter((v) => v.library_item_id);
      return json({ has_more: false, items: all.map((v) => ({ id: v.library_item_id, kind: "video", title: v.title, filename: "black-cat.mp4", content_type: "video/mp4", size_bytes: 25_270_000,
        duration_ms: 15000, width: 1920, height: 1080, has_poster: true, chat_id: chats[0]?.id, chat_title: "Videos", persona_name: "VesperBot", source: "generated", created_at: now() })) });
    }
    if (path === "/bootstrap") {
      return json({
        workspace: { id: uuid(), name: "Acme", slug: "acme" },
        me,
        users: [], agents: AGENTS, epics: [], labels: [],
        projects: [{ id: uuid(), key: "WEB", name: "Web app", color: "#6e56cf", default_branch: "main", archived: false, revision: 1 }],
        counts: { inbox: 0, wiki_suggestions: 0, live_agents: 0 },
      });
    }
    if (path === "/me" && method === "GET") return json(me);
    if (path === "/me/onboarding/complete" && method === "POST") {
      me.onboarded_at ??= now();
      return json(me);
    }
    if (path === "/me" && method === "PATCH") {
      const b = body() as { name?: string; role_title?: string; emails?: string[] };
      profileRequests.push(`PATCH ${JSON.stringify(b)}`);
      if (b.name !== undefined && !b.name.trim()) return fail(err(422, "invalid", "Name is required.", "name"));
      if (b.emails !== undefined && !b.emails.length) return fail(err(422, "invalid", "add at least one email", "emails"));
      if (b.emails?.some((e) => e.endsWith("@taken.example"))) return fail(err(409, "conflict", `${b.emails[0]} is already another person's primary email`, "emails"));
      if (b.name !== undefined) Object.assign(me, { name: b.name.trim(), initials: initialsOf(b.name) });
      if (b.role_title !== undefined) me.role_title = b.role_title.trim();
      if (b.emails !== undefined) Object.assign(me, { email: b.emails[0], emails: b.emails });
      return json(me);
    }
    if (path === "/me/avatar" && method === "PUT") {
      const raw = (req.postDataBuffer() ?? Buffer.alloc(0)).toString("latin1");
      profileRequests.push("PUT avatar");
      if (!raw.includes("\x89PNG") && !raw.includes("\xff\xd8\xff") && !raw.includes("WEBP")) return fail(err(415, "unsupported_type", "PNG, JPEG or WebP only"));
      me.avatar_url = `/api/v1/users/${me.id}/avatar?v=${profileRequests.length}`;
      return json(me);
    }
    if (path === "/me/avatar" && method === "DELETE") {
      profileRequests.push("DELETE avatar");
      delete me.avatar_url;
      return json(me);
    }
    if (/^\/users\/[^/]+\/avatar$/.test(path) && method === "GET") {
      const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", "base64");
      return route.fulfill({ status: 200, contentType: "image/png", body: png });
    }
    if (/^\/chat-attachments\/[^/]+\/content$/.test(path) && method === "GET") {
      const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", "base64");
      return route.fulfill({ status: 200, contentType: "image/png", body: png });
    }
    const cr = /^\/chats\/([^/]+)\/code-review$/.exec(path);
    if (cr && method === "GET") return json({ repositories: codeReviews.get(cr[1]) ?? [] });
    const pr = /^\/chats\/([^/]+)\/push-requests$/.exec(path);
    if (pr && method === "GET") return json({ requests: pushRequests.get(pr[1]) ?? [] });
    const prDecide = /^\/push-requests\/([^/]+)$/.exec(path);
    if (prDecide && method === "POST") {
      const id = prDecide[1];
      const msg = refusePush.get(id);
      if (msg) return fail(err(422, "invalid", msg));
      const b = body() as components["schemas"]["PushRequestDecision"];
      for (const list of pushRequests.values()) {
        const hit = list.find((r) => r.id === id);
        if (!hit) continue;
        if (b.decision === "deny") {
          hit.state = "declined";
        } else {
          hit.state = "pushed";
          hit.auto = b.decision === "always";
          hit.pr_number = hit.pr_number ?? 99;
          hit.pr_url = hit.pr_url ?? `https://github.com/acme/alpha/pull/${hit.pr_number}`;
          hit.pr_state = hit.pr_state ?? (hit.draft ? "draft" : "open");
          if (b.title) hit.title = b.title;
        }
        return json(hit);
      }
      return fail(err(404, "not_found", "push request not found"));
    }
    if (path === "/repository-push-policies" && method === "GET") return json({ policies: pushPolicies });
    if (/^\/chats\/[^/]+\/research$/.test(path) && method === "GET") return json({ jobs: [] });
    if (/^\/chats\/[^/]+\/runs$/.test(path) && method === "GET") return json({ runs: [] });
    if (/^\/chats\/[^/]+\/followups$/.test(path) && method === "GET") return json({ followups: [] });
    const asidesOf = /^\/chats\/([^/]+)\/asides$/.exec(path);
    if (asidesOf && method === "GET") return json({ asides: chats.filter((x) => x.parent_chat_id === asidesOf[1]).map(ref) });
    const asideOn = asidesOf;
    if (asideOn && method === "POST") {
      const c = chats.find((x) => x.id === asideOn[1]);
      if (!c) return fail(err(404, "not_found", "chat not found"));
      const b = body();
      if (b.second_opinion) {
        const list = messages.get(c.id) ?? [];
        const hasReviews = (codeReviews.get(c.id)?.length ?? 0) > 0;
        if (c.state !== "running" && list.length === 0 && !hasReviews) {
          return fail(err(409, "conflict", "Start a conversation or generate changes before asking for a second opinion."));
        }
        const harness = (b.harness as Harness | undefined) ?? c.harness;
        const g = catalog(codexAvailable).find((x) => x.harness === harness);
        const model = (b.model as string | undefined) ?? g?.models.find((m) => m.default)?.id ?? g?.models[0]?.id;
        if (!g || !g.available || !model || !g.models.some((m) => m.id === model)) {
          return fail(err(422, "invalid", "Unknown or unavailable harness/model", "model"));
        }
        let anchorId = b.anchor_message_id as string | undefined;
        if (anchorId && !list.some((m) => m.id === anchorId)) {
          return fail(err(422, "invalid", "not a message of this chat", "anchor_message_id"));
        }
        if (!anchorId && c.state !== "running") {
          anchorId = list.findLast((m) => m.role === "assistant" || m.role === "user")?.id;
        }
        const prompt = String(b.body ?? "").trim() || "Give a concise second opinion on the latest reply and code changes.";
        const repo = typeof b.repository === "string" && b.repository ? b.repository : undefined;
        secondOpinions.push({
          chat: c.id,
          body: prompt,
          harness,
          model,
          ...(anchorId ? { anchor_message_id: anchorId } : {}),
          ...(repo ? { repository: repo } : {}),
        });
        const opinion: Chat = {
          ...c,
          id: uuid(),
          title: `Second opinion: ${prompt.slice(0, 40)}`,
          harness,
          model,
          effort: undefined,
          auto_model: undefined,
          state: "running",
          revision: 1,
          message_count: 0,
          created_at: now(),
          updated_at: now(),
          parent_chat_id: c.id,
          ...(anchorId ? { anchor_message_id: anchorId } : {}),
          second_opinion: true,
          hidden: true,
        };
        chats.push(opinion);
        messages.set(opinion.id, []);
        add(opinion, "user", prompt);
        prompts.set(opinion.id, prompt);
        opinion.current_run_id = uuid();
        touch(opinion);
        timers.set(
          opinion.id,
          setTimeout(() => {
            opinion.state = "idle";
            add(
              opinion,
              "assistant",
              `Second opinion (${label(harness, model)}): looks solid${repo ? ` in ${repo}` : ""}, watch edge cases — ${prompt}`,
              { harness, model, run_id: opinion.current_run_id, ...USAGE },
            );
            touch(opinion);
            void emit(opinion);
          }, delay),
        );
        void emit(opinion);
        return json(ref(opinion), 201);
      }
      asides.push(String(b.body));
      if (!b.anchor_message_id) return json(ref(c), 201);
      // A thread: a hidden chat about one message, which answers like any chat (an Echo).
      if (!messages.get(c.id)?.some((m) => m.id === b.anchor_message_id)) return fail(err(422, "invalid", "not a message of this chat", "anchor_message_id"));
      const t: Chat = { ...c, id: uuid(), title: `Thread: ${String(b.body).slice(0, 40)}`, state: "idle", revision: 1, message_count: 0, created_at: now(), updated_at: now(),
        parent_chat_id: c.id, anchor_message_id: String(b.anchor_message_id), hidden: true };
      chats.push(t);
      messages.set(t.id, []);
      c.revision++;
      const question = String(b.body);
      add(t, "user", question);
      prompts.set(t.id, question);
      t.state = "running";
      t.current_run_id = uuid();
      touch(t);
      timers.set(t.id, setTimeout(() => finishTurn(t, question), delay));
      void emit(t);
      return json(ref(t), 201);
    }
    if (path === "/persona-dock") return json({ personas: dock, space_chats: [], harnesses: [] });
    if (path === "/inbox" && method === "GET") return json({ items: inbox });
    if (path === "/workflows" && method === "GET") return json({ workflows: [] });
    if (path === "/connectors" && method === "GET") return json({ connectors });
    if (path === "/connectors/probe" && method === "POST") return json({ reachable: true, needs_auth: false, tools: 2 });
    if (path === "/connectors" && method === "POST") {
      const b = body();
      const c = { id: uuid(), name: String(b.name), slug: String(b.name).toLowerCase(), url: String(b.url), auth_kind: b.auth_kind, status: "connected", last_error: "", revision: 1, created_at: now(), persona_ids: [] as string[],
        tools: [{ name: "read_thing", description: "", write: false, policy: "allow" }, { name: "write_thing", description: "", write: true, policy: "ask" }] };
      connectors.push(c);
      return json({ connector: c });
    }
    if (/^\/connectors\/[^/]+$/.test(path) && method === "PATCH") {
      const c = connectors.find((x) => path.endsWith(x.id))!;
      const b = body();
      if (b.persona_ids) c.persona_ids = b.persona_ids as string[];
      for (const [name, policy] of Object.entries((b.policies ?? {}) as Record<string, string>)) c.tools.find((t) => t.name === name)!.policy = policy;
      c.revision++;
      return json(c);
    }
    if (/^\/chats\/[^/]+\/connector-approvals$/.test(path) && method === "GET") return json({ approvals: connectorApprovals });
    if (/^\/connector-approvals\/[^/]+$/.test(path) && method === "POST") {
      connectorDecisions.push(body().decision as string);
      connectorApprovals.length = 0;
      return route.fulfill({ status: 204 });
    }
    if (/^\/chats\/[^/]+\/connector-proposals$/.test(path) && method === "GET") return json({ proposals: [] });
    if (/^\/chats\/[^/]+\/ticket-changes$/.test(path) && method === "GET") return json({ requests: ticketChanges.map((r) => ({ ...r, refuse: undefined })) });
    if (/^\/ticket-changes\/[^/]+$/.test(path) && method === "POST") {
      const i = ticketChanges.findIndex((r) => path.endsWith(r.id));
      if (i < 0) return json({ code: "conflict", message: "this change is no longer waiting" }, 409);
      const decision = body().decision as string;
      ticketChangeDecisions.push(decision);
      const [{ refuse, ...r }] = ticketChanges.splice(i, 1);
      if (refuse && decision !== "deny") return json({ code: "conflict", message: refuse }, 409);
      return json({ ...r, state: decision === "deny" ? "declined" : "applied" });
    }
    if (path === "/api-secrets" && method === "GET") return json({ secrets: apiSecrets, key_configured: true, oauth_redirect_uri: "https://vesper.example.ts.net/api/v1/connector-oauth/callback" });
    if (path === "/api-secrets" && method === "POST") {
      const b = body();
      apiSecretPosts.push(b);
      const name = String(b.name);
      const sec = { id: uuid(), name, handle: name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, ""), placement: b.placement, placement_key: b.placement_key ?? "",
        allowed_hosts: b.allowed_hosts, read_policy: "allow", write_policy: "ask", persona_ids: [] as string[], revision: 1, created_at: now(), updated_at: now(),
        kind: b.oauth ? "oauth" : "static", ...(b.oauth ? { oauth: oauthView(b.oauth as Record<string, unknown>) } : {}) };
      apiSecrets.push(sec);
      secretProposals.length = 0;
      return json(sec);
    }
    if (/^\/api-secrets\/[^/]+$/.test(path) && method === "PATCH") {
      const sec = apiSecrets.find((x) => path.endsWith(String(x.id)))!;
      const patch = body();
      delete patch.revision;
      delete patch.value; // Values are write-only: never echoed back.
      Object.assign(sec, patch, { revision: Number(sec.revision) + 1 });
      return json(sec);
    }
    if (/^\/api-secrets\/[^/]+\/sign-in$/.test(path) && method === "POST") {
      const sec = apiSecrets.find((x) => path.includes(String(x.id)))!;
      apiSecretSignIns.push(String(sec.id));
      const o = sec.oauth as Record<string, unknown>;
      return json({ secret: sec, authorize_url: `${o.authorize_url}?client_id=${o.client_id}&state=mock-state` });
    }
    if (/^\/api-secrets\/[^/]+\/calls$/.test(path) && method === "GET") return json({ calls: [] });
    if (/^\/chats\/[^/]+\/api-secrets$/.test(path) && method === "GET") return json({ secrets: chatSecrets });
    if (/^\/chats\/[^/]+\/api-secrets\/[^/]+\/disable$/.test(path) && method === "POST") {
      for (const c of chatSecrets) if (path.includes(String(c.id))) c.enabled = false;
      return route.fulfill({ status: 204 });
    }
    if (/^\/chats\/[^/]+\/api-secret-approvals$/.test(path) && method === "GET") return json({ approvals: secretApprovals });
    if (/^\/api-secret-approvals\/[^/]+$/.test(path) && method === "POST") {
      secretDecisions.push(body().decision as string);
      secretApprovals.length = 0;
      return route.fulfill({ status: 204 });
    }
    if (/^\/chats\/[^/]+\/api-secret-proposals$/.test(path) && method === "GET") return json({ proposals: secretProposals });
    if (/^\/api-secret-proposals\/[^/]+\/decline$/.test(path) && method === "POST") {
      secretProposals.length = 0;
      return route.fulfill({ status: 204 });
    }
    if (path === "/scheduled-tasks" && method === "GET") return json({ tasks: scheduledTasks });
    if (path === "/scheduled-tasks" && method === "POST") {
      const b = body();
      const t = { ...b, id: uuid(), revision: 1, runs: [], upcoming: [], next_run_at: "2026-11-09T16:00:00Z" };
      scheduledTasks.push(t);
      return json(t);
    }
    if (/^\/chats\/[^/]+\/workflows$/.test(path) && method === "GET") return json({ runs: [] });
    // Settings → Sign-in: an install already set up with a password.
    if (path === "/auth/status") return json({ claimed: true, password_set: true, signed_in: true });
    if (path === "/runner") return json({ online: true, runners: [], slots: 1, busy: 0, live: 0, queued: 0, host_folder_workspaces: false, max_concurrent_subagents: 3, max_parallel_delegations: 3 });
    // Sidebar settings dot (LAZYAGENTS-44): both harness keys set, so no dot.
    if (path === "/secrets") return json({ key_configured: true, known: [], secrets: ["harness:anthropic", "harness:openai"].map((name, i) => ({ id: `secret-${i}`, name, created_at: "2026-11-01T00:00:00Z", updated_at: "2026-11-01T00:00:00Z" })) });
    if (path === "/saved-views" && method === "GET") return json({ views: [] });
    if (path === "/dock-chats" && method === "GET") {
      const ids = dockChats.get(url.searchParams.get("scope") ?? "") ?? [];
      return json({ chats: ids.toReversed().map((id) => chats.find((c) => c.id === id)).filter(Boolean) });
    }
    if (path === "/dock-chats" && method === "POST") {
      const b = route.request().postDataJSON() as { scope: string; chat_id: string };
      dockChats.set(b.scope, [...(dockChats.get(b.scope) ?? []).filter((id) => id !== b.chat_id), b.chat_id]);
      return route.fulfill({ status: 204 });
    }
    if (path === "/knowledge/resolve") {
      // Only the plan page resolves, so the live activity line can link it.
      return json({ links: url.searchParams.getAll("ref").filter((r) => r === PLAN.path).map((r) => ({ ref: r, target: PLAN })) });
    }
    if (path === "/knowledge/suggest") {
      const q = (url.searchParams.get("q") ?? "").toLowerCase();
      return json({ targets: TARGETS.filter((t) => !q || `${t.title} ${t.path ?? ""} ${t.display_id ?? ""}`.toLowerCase().includes(q)) });
    }
    if (path === "/wiki/pages" && method === "GET") {
      return json({ pages: [], suggestions: 0 });
    }
    if (path === "/wiki/pages" && method === "POST") {
      const b = body() as { path: string; body_md: string; project_key?: string };
      if (wikiPages.some((p) => p.path === b.path)) return fail(err(409, "conflict", "A page already exists at that path.", "path"));
      wikiPages.push(b);
      return json({ id: uuid(), type: "note", path: b.path, title: b.path.split("/").pop(), body_md: b.body_md }, 201);
    }
    if (path === "/artifacts" && method === "POST") {
      const raw = req.postData() ?? "";
      artifactForms.push(raw);
      const title = /name="title"\r\n\r\n([^\r]*)/.exec(raw)?.[1] ?? "";
      return json({ id: "66666666-6666-4666-8666-666666666666", type: "report", title }, 201);
    }
    // The chat header's spend chip: nothing spent, so no chip (an unhandled 404 would be retried and stall mutations).
    if (path === "/costs") {
      return json({
        total: { key: "", label: "", runs: 0, tokens: 0, cost_micros: 0, unpriced_runs: 0 }, unpriced_runs: 0, estimated: { tickets: 0, points: 0, cost_micros: 0 },
        days: [], agents: [], projects: [], models: [], purposes: [], top_tickets: [],
      });
    }
    if (path === "/chat-models") return json(catalog(codexAvailable));
    if (path === "/chat-suggestions") return json({ suggestions });

    if (path === "/memories" && method === "GET") {
      memoryRequests.push(`GET ${path}${url.search}`);
      const q = (url.searchParams.get("q") ?? "").toLowerCase();
      const type = url.searchParams.get("type");
      const ofType = memories.filter((x) => !type || x.type === type);
      const hits = ofType.filter((x) => !q || `${x.title} ${x.summary} ${x.tags.join(" ")}`.toLowerCase().includes(q));
      return json({ memories: hits, total: ofType.length, has_more: false });
    }
    if (path === "/memories" && method === "DELETE") {
      memoryRequests.push(`DELETE ${path}${url.search}`);
      if (url.searchParams.get("confirm") !== "true") return fail(err(422, "invalid", "confirm=true is required", "confirm"));
      const deleted = memories.length;
      memories.length = 0;
      return json({ deleted });
    }
    if (path === "/memories/export" && method === "GET") {
      memoryRequests.push(`GET ${path}`);
      return json({ exported_at: now(), memories });
    }
    if (path === "/memories/import" && method === "POST") {
      memoryRequests.push(`POST ${path}`);
      const b = body();
      memoryImports.push(b);
      const entries = (b.memories ?? []) as Array<Partial<MockMemory>>;
      let created = 0;
      let updated = 0;
      for (const e of entries) {
        const hit = memories.find((x) => x.title === e.title);
        const stamp = new Date(Date.now() + 1000).toISOString();
        if (hit) {
          Object.assign(hit, e, { updated_at: stamp });
          updated++;
        } else {
          const t = now();
          memories.unshift({
            id: `88888888-8888-4888-8888-${String(memories.length + 1).padStart(12, "0")}`,
            title: e.title ?? "", summary: e.summary ?? "", body: e.body ?? "", tags: e.tags ?? [], type: e.type ?? "other",
            source: "import", created_at: t, updated_at: t,
          });
          created++;
        }
      }
      return json({ created, updated, failed: [] });
    }
    const mem = /^\/memories\/([^/]+)$/.exec(path);
    if (mem) {
      memoryRequests.push(`${method} ${path}`);
      const i = memories.findIndex((x) => x.id === mem[1]);
      if (i < 0) return fail(err(404, "not_found", "Memory not found"));
      if (method === "GET") return json(memories[i]);
      if (method === "DELETE") {
        memories.splice(i, 1);
        return route.fulfill({ status: 204 });
      }
      if (method === "PATCH") {
        const b = body();
        memoryPatches.push(b);
        Object.assign(memories[i], b, { updated_at: new Date(Date.now() + 1000).toISOString() });
        return json(memories[i]);
      }
    }

    if (path === "/image-engine") {
      if (method === "PUT") imageEngine = String(body().engine);
      return json({ engine: imageEngine, options: [
        { engine: "codex", label: "Codex", available: true },
        { engine: "antigravity", label: "Antigravity", available: false, reason: "no harness:google secret" },
      ] });
    }
    if (path === "/planning-sessions" && method === "GET") return json({ sessions: [], has_more: false });
    if (path === "/repositories/presets" && method === "GET") return json({ owners: [{ login: "liamphmurphy", organization: false }, { login: "acme", organization: true }] });
    if (path === "/repositories/sources") {
      if (method === "GET") return json(repositorySources);
      const b = body() as { kind: "repository" | "organization"; name: string };
      if (b.kind === "organization" || b.name.trim().endsWith("/*")) { b.kind = "organization"; b.name = b.name.trim().toLowerCase().replace("https://github.com/", "").replace(/\/\*$/, "").replace(/\/$/, ""); }
      if (method === "PUT") { if (!repositorySources.some((s) => s.kind === b.kind && s.name === b.name)) repositorySources.push(b); }
      if (method === "DELETE") { const i = repositorySources.findIndex((s) => s.kind === b.kind && s.name === b.name); if (i >= 0) repositorySources.splice(i, 1); }
      return route.fulfill({ status: 204 });
    }
    if (path === "/repositories" && method === "GET") return json(repositorySources.flatMap((s) => s.kind === "repository" ? [{ name: s.name.replace("https://github.com/", "").replace("git@github.com:", "").replace(/\.git$/, ""), url: s.name }] : [{ name: `${s.name}/org-app`, url: `https://github.com/${s.name}/org-app.git` }]));
    const repositorySelection = /^\/chats\/([^/]+)\/repository$/.exec(path);
    if (repositorySelection && method === "PUT") {
      const c = chats.find((c) => c.id === repositorySelection[1]);
      if (!c) return fail(err(404, "not_found", "Chat not found"));
      const raw = String(body().repository);
      const url = raw.startsWith("https://") ? raw : `https://github.com/${raw}.git`;
      c.repositories ??= c.repo_url ? [{ repo_url: c.repo_url, directory: ".", work_branches: c.work_branches ?? [] }] : [];
      if (!c.repositories.some((r) => r.repo_url === url)) c.repositories.push({ repo_url: url, directory: `.lazyagents/repos/${raw.replace("https://github.com/", "").replace(/\.git$/, "")}`, work_branches: [] });
      if (c.state === "running") c.pending_repo_url = url;
      else { c.repo_url = url; c.work_branches = c.repositories.find((r) => r.repo_url === url)!.work_branches; }
      return json(ref(c));
    }
    if (path === "/chats" && method === "GET") {
      const archived = url.searchParams.get("archived") === "true";
      const pid = url.searchParams.get("persona_id");
      chatPersonaFilters.push(pid ?? "");
      const want = pid ?? defaultPersona()?.id ?? "none";
      const list = chats
        .filter((c) => c.archived === archived && !c.hidden)
        .filter((c) => want === "all" || (want === "none" ? !c.persona_id : c.persona_id === want || !!c.guest_persona_ids?.includes(want)))
        .sort((a, b) => (b.last_message_at ?? b.created_at).localeCompare(a.last_message_at ?? a.created_at));
      return json({ chats: list.map(ref), has_more: false });
    }
    if (path === "/chats" && method === "POST") {
      const b = body();
      const agent = b.agent_id === undefined ? AGENTS[0] : AGENTS.find((a) => a.id === b.agent_id);
      if (!agent) return fail(err(422, "invalid", "unknown agent", "agent_id"));
      if (agent.kind === "sub") return fail(err(422, "invalid", "pick a main agent", "agent_id"));
      if (b.persona_id !== undefined && !personas.some((p) => p.id === b.persona_id)) return fail(err(422, "invalid", "unknown persona", "persona_id"));
      const first = b.message as { body?: string; harness?: Harness; model?: string; effort?: Effort } | undefined;
      const persona = personas.find((p) => p.id === ((b.persona_id as string | undefined) ?? defaultPersona()?.id));
      created.push(b);
      const c: Chat = {
        id: uuid(), project: b.project as string | undefined, title: String(b.title ?? ""), agent_id: agent.id,
        harness: (b.harness as Harness) ?? first?.harness ?? persona?.default_harness ?? "claude-code",
        model: String(b.model ?? (first?.model && first.model !== "auto" ? first.model : undefined) ?? persona?.default_model ?? "opus-5.5"),
        effort: (b.effort as Effort | undefined) ?? first?.effort ?? persona?.default_effort,
        state: "idle", archived: false, revision: 1, message_count: 0, created_at: now(), updated_at: now(),
        persona_id: (b.persona_id as string | undefined) ?? defaultPersona()?.id,
        ...(b.temporary ? { temporary: true } : {}),
      };
      // A coding persona's chat works in the requested repo (default: its first) on its own branch.
      const owner = personas.find((p) => p.id === c.persona_id);
      const repo = (b.repo_url as string | undefined) ?? owner?.repos[0];
      if (b.repo_url !== undefined && !(owner?.capabilities.code)) return fail(err(422, "invalid", "persona cannot write code", "repo_url"));
      if (owner?.capabilities.code && repo) Object.assign(c, { repo_url: repo, work_branches: [] });
      if (b.commit_email !== undefined) {
        if (!c.repo_url) return fail(err(422, "invalid", "only a chat with a repository makes commits", "commit_email"));
        if (!ownEmail(b.commit_email)) return fail(err(422, "invalid", `add ${b.commit_email} to your profile first`, "commit_email"));
        c.commit_email = ownEmail(b.commit_email);
      }
      chats.unshift(c);
      messages.set(c.id, []);
      // `message` is posted as the first message, which starts a turn (the workflow editor's build chat).
      if (first?.body) {
        if (!c.title) c.title = first.body.slice(0, 40);
        posted.push({ chat: c.id, body: first });
        add(c, "user", first.body);
        prompts.set(c.id, first.body);
        c.state = "running";
        c.current_run_id = uuid();
        touch(c);
        if (first.body.startsWith("push-live:")) pushRequests.set(c.id, [...(pushRequests.get(c.id) ?? []), mockPushRequest(first.body.slice(10).trim(), c.current_run_id)]);
        timers.set(c.id, setTimeout(() => finishTurn(c, first.body!), delay));
        void emit(c);
      }
      return json(ref(c), 201);
    }

    const ce = /^\/chats\/([^/]+)\/commit-email$/.exec(path);
    if (ce && method === "PUT") {
      const c = chats.find((x) => x.id === ce[1]);
      if (!c) return fail(err(404, "not_found", "Chat not found"));
      const email = body().email;
      commitEmailRequests.push(String(email));
      if (!c.repo_url) return fail(err(422, "invalid", "only a chat with a repository makes commits", "commit_email"));
      if (!ownEmail(email)) return fail(err(422, "invalid", `add ${email} to your profile first`, "commit_email"));
      c.commit_email = ownEmail(email);
      return json(ref(c));
    }

    const pp = /^\/chats\/([^/]+)\/persona-proposals(?:\/([^/]+))?$/.exec(path);
    if (pp && method === "GET") return json({ proposals: proposals.filter((x) => x.chat_id === pp[1]) });
    if (pp && pp[2] && method === "POST") {
      const p = proposals.find((x) => x.id === pp[2]);
      if (!p) return fail(err(404, "not_found", "Proposal not found"));
      if (p.state !== "pending") return fail(err(409, "conflict", `already ${p.state}`));
      const decision = String(body().decision);
      decisions.push({ id: p.id, decision });
      p.state = decision === "approve" ? "approved" : "declined";
      return json(p);
    }

    if (path === "/chat-search") {
      const q = (url.searchParams.get("q") ?? "").toLowerCase();
      const hits = chats.flatMap((c) => (messages.get(c.id) ?? []).filter((x) => x.role !== "system" && x.body_md.toLowerCase().includes(q)).map((x) => ({
        message_id: x.id, chat_id: c.id, chat_title: c.title, project_key: "WEB", role: x.role, archived: false, created_at: x.created_at,
        snippet: x.body_md.replace(new RegExp(q, "i"), (w) => `${w}`),
      })));
      return json({ hits });
    }
    const redo = /^\/chats\/([^/]+)\/edit-last$/.exec(path);
    if (redo && method === "POST") {
      const c = chats.find((x) => x.id === redo[1])!;
      const list = messages.get(c.id)!;
      const at = list.findLastIndex((x) => x.role === "user");
      list.splice(at + 1);
      list[at].body_md = (body() as { body: string }).body;
      add(c, "assistant", `Redone: ${list[at].body_md}`, { harness: c.harness, model: c.model, run_id: c.current_run_id, ...USAGE });
      void emit(c);
      return json({ chat: c, message: list[at] }, 202);
    }
    const m = /^\/chats\/([^/]+)(?:\/(messages|cancel))?$/.exec(path);
    if (m) {
      const c = chats.find((x) => x.id === m[1]);
      if (!c) return fail(err(404, "not_found", "Chat not found"));
      const sub = m[2];
      if (!sub && method === "GET") return json(ref(c));
      if (!sub && method === "DELETE") {
        chats.splice(chats.indexOf(c), 1);
        return route.fulfill({ status: 204 });
      }
      if (!sub && method === "PATCH") {
        const b = body();
        if (b.revision !== c.revision) return fail(err(409, "conflict", "This chat changed. Reload and try again."));
        if (c.state === "running") return fail(err(409, "conflict", "A turn is running."));
        if (typeof b.title === "string") c.title = b.title;
        if (typeof b.archived === "boolean") c.archived = b.archived;
        if (typeof b.space_id === "string") {
          // As the server does: the chat files tickets where its new space does, unless the patch names a project.
          const sp = spaces.find((x) => x.id === b.space_id);
          if (b.space_id && !sp) return fail(err(422, "invalid", "unknown space", "space_id"));
          c.space = sp && { id: sp.id, name: sp.name, color: sp.color, space_memory: sp.space_memory, source_count: sp.source_count, has_instructions: !!sp.instructions };
          if (sp?.project && typeof b.project !== "string") c.project = sp.project;
        }
        if (typeof b.project === "string") c.project = b.project || undefined;
        touch(c);
        return json(ref(c));
      }
      if (sub === "messages" && method === "GET") {
        const after = Number(url.searchParams.get("after") ?? 0);
        return json({ messages: messages.get(c.id)!.filter((x) => x.seq > after), has_more: false });
      }
      if (sub === "messages" && method === "POST") {
        const b = body();
        const text = String(b.body ?? "");
        if (c.archived) return fail(err(409, "conflict", "This chat is archived."));
        if (!text.trim()) return fail(err(422, "invalid", "Message is empty", "body"));
        const harness = (b.harness as Harness | undefined) ?? c.harness;
        // "auto" routes the model per turn on the server; here it just keeps the current one.
        const auto = b.model === "auto" ? true : b.model !== undefined || b.harness !== undefined ? false : !!c.auto_model;
        const picked = b.model === "auto" ? undefined : (b.model as string | undefined);
        const model = picked ?? (harness === c.harness ? c.model : catalog(true).find((g) => g.harness === harness)!.models[0].id);
        const g = catalog(codexAvailable).find((x) => x.harness === harness);
        if (!g || !g.models.some((x) => x.id === model) || !g.available) {
          return fail(err(422, "invalid", "Unknown or unavailable harness/model", "model"));
        }
        const offered: string[] = g.models.find((x) => x.id === model)!.efforts;
        if (b.effort === "default") c.effort = undefined;
        else if (b.effort) {
          if (!offered.includes(b.effort as string)) return fail(err(422, "invalid", "Effort not offered", "effort"));
          c.effort = b.effort as Effort;
        } else if (c.effort && !offered.includes(c.effort)) c.effort = undefined;
        if (harness !== c.harness || model !== c.model) {
          c.harness = harness;
          c.model = model;
          add(c, "system", `Switched to ${label(harness, model)}`);
        }
        c.auto_model = auto || undefined;
        if (!c.title) c.title = text.slice(0, 40);
        posted.push({ chat: c.id, body: b });
        const refs = (b.context_refs as Array<{ key?: string }> | undefined) ?? [];
        if (refs.some((r) => r.key === "OTHER-9")) return fail(err(422, "invalid", "context_refs: ticket OTHER-9 was not found", "context_refs"));
        const interrupted = c.state === "running" ? prompts.get(c.id) : undefined;
        clearTimeout(timers.get(c.id));
        // Uploads are always PNGs here; the spec names them by id.
        const attachments = ((b.attachment_ids as string[] | undefined) ?? []).map((id) => ({ id, filename: `${id}.png`, content_type: "image/png", size_bytes: 3 }));
        const user = add(c, "user", text, { ...(refs.length ? { context_refs: refs } : {}), ...(attachments.length ? { attachments } : {}) });
        const prompt = interrupted === undefined ? text : `${text} (interrupting: ${interrupted})`;
        prompts.set(c.id, prompt);
        c.state = "running";
        c.error = undefined;
        c.current_run_id = uuid();
        touch(c);
        if (text.startsWith("audio-live:")) audio.set(c.id, [...(audio.get(c.id) ?? []), mockAudio(text.slice(11).trim(), c.current_run_id)]);
        if (text.startsWith("video-live:")) videos.set(c.id, [...(videos.get(c.id) ?? []), mockVideo(text.slice(11).trim(), c.current_run_id)]);
        if (text.startsWith("push-live:")) pushRequests.set(c.id, [...(pushRequests.get(c.id) ?? []), mockPushRequest(text.slice(10).trim(), c.current_run_id)]);
        if (text.startsWith("slow:")) {
          const events = runEvents.get(c.current_run_id) ?? [];
          events.push({ seq: events.length + 1, type: "tool_call", at: now(), payload: { id: `call-${events.length + 1}`, tool: "mcp__lazyagents__read_page", input: { ref: PLAN.path } } });
          runEvents.set(c.current_run_id, events);
        }
        if (text.startsWith("steps:")) {
          const todos = (...rows: [string, string][]) => rows.map(([content, status]) => ({ content, status }));
          runEvents.set(c.current_run_id, [
            { seq: 1, type: "tool_call", at: now(), payload: { id: "plan-1", tool: "TodoWrite", input: { todos: todos(["Read the code", "in_progress"], ["Run tests", "pending"]) } } },
            { seq: 2, type: "tool_call", at: now(), payload: { id: "plan-2", tool: "TodoWrite", input: { todos: todos(["Read the code", "completed"], ["Fix the snapshot", "in_progress"], ["Run tests", "pending"]) } } },
          ]);
        }
        if (text.startsWith("narrated:")) {
          const say = (seq: number, t: string) => ({ seq, type: "message", at: now(), payload: { role: "assistant", text: t } });
          const think = (seq: number, t: string) => ({ seq, type: "message", at: now(), payload: { kind: "thinking", text: t } });
          runEvents.set(c.current_run_id, [
            say(1, "On it."),
            { seq: 2, type: "tool_call", at: now(), payload: { id: "read-1", tool: "Read", input: { file_path: "/repo/poller.go" } } },
            { seq: 3, type: "tool_result", at: now(), payload: { id: "read-1", tool: "Read", output: "package runs" } },
            think(4, "It fails on main as well, so the test races the backoff."),
            say(5, "Surprise: it fails on main too, so it's the test."),
            { seq: 6, type: "tool_call", at: now(), payload: { id: "test-1", tool: "Bash", input: { command: "go test ./internal/runs -count=10" } } },
          ]);
        }
        if (text.startsWith("between:")) {
          runEvents.set(c.current_run_id, [
            { seq: 1, type: "tool_call", at: now(), payload: { id: "edit-1", tool: "Edit", input: { file_path: "/repo/runner.go" } } },
            { seq: 2, type: "tool_result", at: now(), payload: { id: "edit-1", tool: "Edit", output: "ok" } },
          ]);
        }
        if (text.startsWith("building-app:")) {
          runEvents.set(c.current_run_id, [
            { seq: 1, type: "tool_call", at: now(), payload: { id: "read-1", tool: "Read", input: {} } },
            { seq: 2, type: "lifecycle", at: now(), payload: { state: "reply_block", kind: "app" } },
          ]);
        }
        if (!/^(slow|steps|narrated|between|building-app):/.test(text)) timers.set(c.id, setTimeout(() => finishTurn(c, prompt), delay));
        void emit(c);
        return json({ chat: ref(c), message: user }, 202);
      }
      if (sub === "cancel" && method === "POST") {
        if (c.state !== "running") return fail(err(409, "conflict", "No turn is running."));
        clearTimeout(timers.get(c.id));
        c.state = "idle";
        add(c, "system", "Turn cancelled");
        touch(c);
        void emit(c);
        return json(ref(c));
      }
    }

    // The chat sidebar lists spaces on every page; most specs have none.
    if (path === "/chat-spaces" && method === "GET") {
      return json({ spaces: spaces });
    }
    // A space's page and its work (LAZYAGENTS-213), as the server answers them.
    const spaceRoute = path.match(/^\/chat-spaces\/([^/]+)(?:\/(work|sources))?$/);
    if (spaceRoute) {
      const sp = spaces.find((x) => x.id === spaceRoute[1]);
      if (!sp) return fail(err(404, "not_found", "Not found"));
      if (!spaceRoute[2] && method === "GET") return json(sp);
      if (spaceRoute[2] === "sources" && method === "GET") return json({ sources: [] });
      if (spaceRoute[2] === "work" && method === "PUT") {
        const b = body();
        workRequests.push(`PUT ${path} ${JSON.stringify(b)}`);
        const key = String(b.key ?? "").toUpperCase();
        if (!/^[A-Z][A-Z0-9]{1,9}$/.test(key)) return fail(err(422, "invalid", "use 2–10 letters or digits, starting with a letter", "key"));
        if (sp.work) return fail(err(409, "conflict", "this space already tracks work"));
        if (spaces.some((x) => x.work?.key === key)) return fail(err(409, "conflict", `the key ${key} is already in use`));
        sp.work = { key, default_branch: "main", archived: false, revision: 1, ...(b.repo_url ? { repo_url: String(b.repo_url) } : {}) };
        sp.project = key;
        return json(sp);
      }
      if (spaceRoute[2] === "work" && method === "DELETE") {
        workRequests.push(`DELETE ${path}`);
        if (!sp.work) return fail(err(409, "conflict", "this space doesn't track work"));
        if (opts.workWithTickets?.includes(sp.work.key)) return fail(err(409, "conflict", `${sp.work.key} has tickets, so it keeps tracking work; archive it instead`));
        sp.work = undefined;
        sp.project = undefined;
        return json(sp);
      }
    }
    const workRoute = path.match(/^\/projects\/([^/]+)$/);
    if (workRoute && method === "PUT") {
      const b = body();
      workRequests.push(`PUT ${path} ${JSON.stringify(b)}`);
      const sp = spaces.find((x) => x.work?.key === workRoute[1]);
      if (!sp?.work) return fail(err(404, "not_found", "Not found"));
      if (b.revision !== sp.work.revision) return fail(err(409, "conflict", "the space’s work changed; reload before saving"));
      sp.work = { ...sp.work, repo_url: (b.repo_url as string) || undefined, default_branch: String(b.default_branch), archived: !!b.archived, revision: sp.work.revision + 1 };
      return json({ id: `project-${sp.work.key}`, key: sp.work.key, name: sp.name, color: String(b.color), default_branch: sp.work.default_branch, archived: sp.work.archived, revision: sp.work.revision, space_id: sp.id });
    }

    if (path === "/personas" && method === "GET") {
      return json({ personas, ...(personas.find((x) => x.is_default) ? { default_persona_id: personas.find((x) => x.is_default)!.id } : {}) });
    }
    const personaBody = (b: Record<string, unknown>, self?: MockPersona) => {
      const name = typeof b.name === "string" ? b.name.trim() : undefined;
      if (name !== undefined && personas.some((x) => x !== self && x.name.toLowerCase() === name.toLowerCase()))
        return err(422, "invalid", "You already have a persona with this name", "name");
      if (typeof b.color === "string" && !/^#[0-9a-f]{6}$/i.test(b.color)) return err(422, "invalid", "Use #rrggbb", "color");
      return null;
    };
    if (path === "/personas" && method === "POST") {
      const b = body();
      personaRequests.push(`POST ${path} ${JSON.stringify(b)}`);
      const bad = personaBody(b);
      if (bad) return fail(bad);
      if (b.is_default) for (const x of personas) x.is_default = false;
      const t = now();
      const p: MockPersona = {
        id: uuid(), name: String(b.name).trim(), tone: (b.tone as string) ?? "neutral", color: String(b.color ?? "#64748b").toLowerCase(),
        custom_instructions: (b.custom_instructions as string) ?? "", is_default: !!b.is_default,
        capabilities: (b.capabilities as MockPersona["capabilities"] | undefined) ?? { code: false, images: false }, repos: (b.repos as string[] | undefined) ?? [], chat_count: 0, revision: 1, created_at: t, updated_at: t,
      };
      personas.push(p);
      return json(p, 201);
    }
    const pm = /^\/personas\/([^/]+)(?:\/(default|avatar))?$/.exec(path);
    if (pm) {
      const p = personas.find((x) => x.id === pm[1]);
      if (!p) return fail(err(404, "not_found", "persona not found"));
      personaRequests.push(`${method} ${path}`);
      const bump = () => {
        p.revision++;
        p.updated_at = now();
      };
      if (!pm[2] && method === "PATCH") {
        const b = body();
        if (b.revision !== p.revision) return fail(err(409, "conflict", "persona changed"));
        const bad = personaBody(b, p);
        if (bad) return fail(bad);
        for (const k of ["name", "tone", "custom_instructions"] as const) if (typeof b[k] === "string") p[k] = (b[k] as string).trim() || p[k];
        if (typeof b.custom_instructions === "string") p.custom_instructions = b.custom_instructions;
        if (typeof b.color === "string") p.color = b.color.toLowerCase();
        if (b.capabilities) p.capabilities = b.capabilities as MockPersona["capabilities"];
        if (Array.isArray(b.repos)) p.repos = b.repos as string[];
        if ("default_harness" in b || "default_model" in b) {
          if (!b.default_harness || b.default_model === "" || b.default_model === "auto") {
            delete p.default_harness;
            delete p.default_model;
          } else {
            p.default_harness = b.default_harness as Harness;
            p.default_model = String(b.default_model);
          }
        }
        if ("default_effort" in b) {
          if (!b.default_effort || b.default_effort === "default") delete p.default_effort;
          else p.default_effort = b.default_effort as Effort;
        }
        bump();
        return json(p);
      }
      if (!pm[2] && method === "DELETE") {
        const rev = url.searchParams.get("revision");
        if (rev && Number(rev) !== p.revision) return fail(err(409, "conflict", "persona changed"));
        personas.splice(personas.indexOf(p), 1);
        // ON DELETE SET NULL: its chats fall back to the built-in Assistant.
        for (const c of chats) if (c.persona_id === p.id) c.persona_id = undefined;
        if (p.is_default && personas.length) {
          const t = (x: MockPersona) => Date.parse(x.last_used_at ?? "") || 0;
          [...personas].sort((a, b) => t(b) - t(a) || Date.parse(b.created_at) - Date.parse(a.created_at))[0].is_default = true;
        }
        return route.fulfill({ status: 204 });
      }
      if (pm[2] === "default" && method === "POST") {
        for (const x of personas) if (x.is_default && x !== p) {
          x.is_default = false;
          x.revision++;
        }
        if (!p.is_default) {
          p.is_default = true;
          bump();
        }
        return json(p);
      }
      if (pm[2] === "avatar" && method === "PUT") {
        const raw = req.postDataBuffer() ?? Buffer.alloc(0);
        if (raw.length > 1_048_576 + 4096) return fail(err(413, "too_large", "avatar over 1 MB"));
        const text = raw.toString("latin1");
        if (!text.includes("\x89PNG") && !text.includes("\xff\xd8\xff") && !text.includes("WEBP")) return fail(err(415, "unsupported_type", "PNG, JPEG or WebP only"));
        bump();
        p.avatar_url = `/api/v1/personas/${p.id}/avatar?v=${p.revision}`;
        return json(p);
      }
      if (pm[2] === "avatar" && method === "DELETE") {
        if (p.avatar_url) bump();
        delete p.avatar_url;
        return json(p);
      }
      if (pm[2] === "avatar" && method === "GET") {
        // A 1×1 PNG.
        const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", "base64");
        return route.fulfill({ status: 200, contentType: "image/png", body: png });
      }
    }

    if (/^\/chat-messages\/[^/]+\/link-previews$/.test(path)) return json({ previews: [
      { url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", kind: "video", title: "Why small rooms sound better", description: "", site: "Room Acoustics Lab",  saved: false, video_id: "dQw4w9WgXcQ", image_url: "/api/v1/link-previews/thumb/image" },
      { url: "https://trailatlas.example/routes", kind: "site", title: "A field guide to quiet bike routes", description: "Routes", site: "", saved: false, image_url: "/api/v1/link-previews/site/image" },
      { url: "https://notes.example/grinders", kind: "site", title: "", description: "", site: "", saved: false },
    ] });
    if (path === "/library/links/summary" && method === "POST") return json({ id: "11111111-aaaa-4aaa-8aaa-222222222222", kind: "link", title: "T", filename: "link", content_type: "image/png", size_bytes: 9, created_at: now() }, 201);
    if (path === "/library/links" && method === "POST") return json({ id: "11111111-aaaa-4aaa-8aaa-111111111111", kind: "link", title: "T", filename: "link", content_type: "image/png", size_bytes: 9, created_at: now() }, 201);
    if (/^\/link-previews\/[^/]+\/image$/.test(path)) {
      const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==", "base64");
      return route.fulfill({ status: 200, contentType: "image/png", body: png });
    }

    const runEv = /^\/runs\/([^/]+)\/events$/.exec(path);
    if (runEv && method === "GET") {
      const after = Number(url.searchParams.get("after") ?? 0);
      return json({ events: (runEvents.get(runEv[1]) ?? []).filter((e) => e.seq > after) });
    }
    const run = /^\/runs\/([^/]+)$/.exec(path);
    if (run) {
      return json({ run: {}, turns: [], approvals: [], events: runEvents.get(run[1]) ?? [] });
    }
    if (path === "/custom-apps" && method === "GET") return json({ apps: [] });
    if (path === "/dev-workspace" && method === "GET") return json(devWorkspace);
    if (path === "/dev-workspace/open-branch" && method === "POST") {
      if (!devWorkspace.enabled) return fail(err(409, "conflict", "Enable the persistent dev workspace in Settings first."));
      const b = body() as components["schemas"]["OpenDevWorkspaceBranchRequest"];
      devWorkspaceOpenBranches.push(b);
      devWorkspace.state = "starting";
      devWorkspace.action = "open_branch";
      devWorkspace.step = `Opening ${b.branch}`;
      devWorkspace.updated_at = now();
      return json(devWorkspace);
    }
    unhandled.push(`${method} ${path}`);
    return fail(err(404, "not_found", `mock: no handler for ${method} ${path}`));
  }

  return (async () => {
    // Replace EventSource with a stub that reports "open" so the shell shows no
    // offline banner; `emit` pushes a hint like the real /events stream does.
    await page.addInitScript(() => {
      const w = window as unknown as { __sse: Array<{ onmessage?: (e: { data: string }) => void }> };
      w.__sse = [];
      // Other streams (a playground's logs, which the spec routes) stay real.
      const Real = window.EventSource;
      class FakeEventSource {
        onopen?: () => void;
        onerror?: () => void;
        onmessage?: (e: { data: string }) => void;
        constructor(url?: string | URL, init?: EventSourceInit) {
          if (url !== undefined && String(url) !== "/events") return new Real(url, init) as unknown as FakeEventSource;
          w.__sse.push(this);
          setTimeout(() => this.onopen?.(), 0);
        }
        close() {
          w.__sse = w.__sse.filter((x) => x !== this);
        }
      }
      (window as unknown as { EventSource: unknown }).EventSource = FakeEventSource;
    });
    await page.route("**/api/v1/**", handle);
    return { spaces, workRequests, asides, secondOpinions, inbox, dock, apiSecrets, apiSecretPosts, apiSecretSignIns, secretApprovals, secretDecisions, secretProposals, chatSecrets, connectors, connectorApprovals, connectorDecisions, ticketChanges, ticketChangeDecisions, scheduledTasks, proposals, decisions, chats, messages, unhandled, posted, created, wikiPages, artifactForms, memories, memoryRequests, memoryPatches, memoryImports, personas, personaRequests, chatPersonaFilters, updatePersona, profileRequests, commitEmailRequests, codeReviews, pushRequests, refusePush, devWorkspace, devWorkspaceOpenBranches };
  })();
}

const STAGE_ORDER = ["write", "stills", "render", "encode", "save"];

/**
 * A chat video at one state: write, stills, render, encode, save, done, failed or stopped,
 * with the frames, checks and progress the card shows at that point.
 */
export function mockVideo(state: string, runId: string): Record<string, unknown> {
  const id = `0000000v-0000-4000-8000-${String(Math.floor(Math.random() * 1e12)).padStart(12, "0")}`;
  const stage = state === "done" ? "save" : state === "failed" || state === "stopped" ? "encode" : state;
  const at = STAGE_ORDER.indexOf(stage);
  const frames: { kind: string; idx: number; version: number }[] = [];
  if (at >= 1) for (const idx of [0, 120, 300, 449]) frames.push({ kind: "still", idx, version: 1 });
  if (at >= 2) {
    for (let i = 0; i < (at >= 3 ? 30 : 14); i++) frames.push({ kind: "strip", idx: i, version: 1 });
    frames.push({ kind: "preview", idx: 0, version: 1 });
  }
  if (state === "done") frames.push({ kind: "poster", idx: 0, version: 1 });
  const started = new Date(Date.now() - 88_000).toISOString();
  return {
    id, title: "Black cat on a rainy cyberpunk street", width: 1920, height: 1080, fps: 30, duration_ms: 15000,
    stage, state: state === "done" ? "done" : state === "failed" || state === "stopped" ? "failed" : "running",
    ...(state === "failed" ? { failure_kind: "error", error: "ffmpeg isn't installed in this runner image. All 450 frames rendered and stay in the chat's workspace, so a retry only re-encodes.", error_log: "sh: 1: ffmpeg: not found\nexit status 127" } : {}),
    ...(state === "stopped" ? { failure_kind: "stopped", error: "Stopped before the video was finished." } : {}),
    script_path: "scratch/cyberpunk_cat.py", script_lines: 1024,
    script_tail: "def rain_overlay(t):  # streaks + splashes\n    ...\ndef render_frame(t):  # reflection, fog, bloom\n    ...\ndef main():  # pool.imap -> ffmpeg libx264\n    ...",
    checks: at >= 1 ? [
      { label: "Paws stay planted while the street scrolls", passed: true },
      { label: "Rain falls along its slant", passed: true },
      { label: "Cat stays in the middle third of the frame", ...(at > 1 ? { passed: true } : {}) },
      { label: "Neon reflections read on the wet road", ...(at > 1 ? { passed: true } : {}) },
    ] : [],
    frames_done: at >= 3 ? 450 : at === 2 ? 212 : 0, frames_total: at >= 2 ? 450 : 0, stage_note: at >= 3 ? "H.264 (libx264, CRF 18)" : "",
    ...(at >= 2 ? { render_started_at: started } : {}),
    run_id: runId,
    ...(state === "done" ? { library_item_id: "11111111-vvvv-4vvv-8vvv-000000000001".replace(/v/g, "0"), finished_at: new Date().toISOString(),
      output: { filename: "black-cat-on-a-rainy-cyberpunk-street.mp4", content_type: "video/mp4", size_bytes: 25_270_000, codec: "H.264", duration_ms: 15000 } } : {}),
    frames, created_at: new Date().toISOString(), updated_at: new Date().toISOString(),
  };
}

/** A quiet tone, `seconds` long (one by default): enough for an <audio> element to load. */
export function mockWav(seconds = 1): Buffer {
  const rate = 8000;
  const data = Buffer.alloc(rate * 2 * seconds);
  for (let i = 0; i < rate * seconds; i++) data.writeInt16LE(Math.round(Math.sin((2 * Math.PI * 440 * i) / rate) * 3000), i * 2);
  const head = Buffer.alloc(44);
  head.write("RIFF", 0);
  head.writeUInt32LE(36 + data.length, 4);
  head.write("WAVEfmt ", 8);
  head.writeUInt32LE(16, 16);
  head.writeUInt16LE(1, 20);
  head.writeUInt16LE(1, 22);
  head.writeUInt32LE(rate, 24);
  head.writeUInt32LE(rate * 2, 28);
  head.writeUInt16LE(2, 32);
  head.writeUInt16LE(16, 34);
  head.write("data", 36);
  head.writeUInt32LE(data.length, 40);
  return Buffer.concat([head, data]);
}

/**
 * Chat audio at one state: compose, render, check, save, done, failed or stopped, with the
 * progress, checks and waveform the card shows at that point.
 */
export function mockAudio(state: string, runId: string): Record<string, unknown> {
  const id = `0000000a-0000-4000-8000-${String(Math.floor(Math.random() * 1e12)).padStart(12, "0")}`;
  const order = ["compose", "render", "check", "save"];
  const stage = state === "done" ? "save" : state === "failed" || state === "stopped" ? "render" : state;
  const at = order.indexOf(stage);
  const peaks = Array.from({ length: 64 }, (_, i) => Math.round(255 * (0.3 + 0.7 * Math.abs(Math.sin(i / 5)))));
  return {
    id, title: "Metal riff demo", duration_ms: 24000, method: "MIDI → FluidSynth (GeneralUser GS)",
    stage, state: state === "done" ? "done" : state === "failed" || state === "stopped" ? "failed" : "running",
    ...(state === "failed" ? { failure_kind: "error", error: "fluidsynth isn't installed in this runner image.", error_log: "sh: 1: fluidsynth: not found\nexit status 127" } : {}),
    ...(state === "stopped" ? { failure_kind: "stopped", error: "Stopped before the audio was finished." } : {}),
    script_path: "scratch/riff.py",
    checks: at >= 2 || state === "done" ? [
      { label: "Peak stays under -1 dBFS", passed: true },
      { label: "No silence longer than 1 s", ...(state === "done" ? { passed: true } : {}) },
    ] : [],
    percent: state === "done" ? 100 : at === 1 ? 54 : at >= 2 ? 100 : 0, stage_note: at === 1 ? "Rendering MIDI with FluidSynth" : "",
    run_id: runId,
    ...(state === "done" ? { library_item_id: "00000000-aaaa-4aaa-8aaa-000000000001", finished_at: new Date().toISOString(), peaks,
      output: { filename: "metal-riff-demo.wav", content_type: "audio/wav", size_bytes: 4_200_000, duration_ms: 24000 } } : {}),
    created_at: new Date().toISOString(), updated_at: new Date().toISOString(),
  };
}

/** A small night street for frames: a gradient sky, towers with lit windows, a neon sign and a label. */
export function frameSvg(kind: string, idx: number): string {
  const shift = (idx * 7) % 200;
  const towers = Array.from({ length: 9 }, (_, i) => {
    const x = ((i * 80 - shift + 720) % 720) - 40;
    const h = 90 + ((i * 53) % 120);
    return `<rect x="${x}" y="${280 - h}" width="64" height="${h}" fill="#16122b"/><rect x="${x + 10}" y="${290 - h}" width="6" height="${h * 0.3}" fill="${["#ff2896", "#1ee1ff", "#9646ff", "#ffa528"][i % 4]}"/>`;
  }).join("");
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 360" width="640" height="360"><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#06061a"/><stop offset="1" stop-color="#46104f"/></linearGradient></defs><rect width="640" height="360" fill="url(#g)"/><circle cx="480" cy="68" r="28" fill="#cdd0f0" opacity=".85"/>${towers}<rect y="280" width="640" height="80" fill="#0f0f1c"/><ellipse cx="${220 + idx / 4}" cy="250" rx="46" ry="14" fill="#0a0910"/><circle cx="${266 + idx / 4}" cy="236" r="13" fill="#0a0910"/><text x="12" y="350" fill="#8b8b94" font-family="monospace" font-size="12">${kind} ${idx}</text></svg>`;
}
