import type { Page, Route } from "@playwright/test";
import { menuResponse } from "./mock-menu";

/**
 * In-memory stand-in for the agent REST contract (api/openapi.yaml, tag `agents`):
 * GET /agents/{handle}, PUT /agents/{handle}/definition,
 * PUT /agents/{handle}/overrides/{project}, GET /agents/{handle}/resolved,
 * GET /agents/{handle}/runs, GET /agent-overviews and GET /wiki/pages.
 * State is kept across page reloads. The model "rejected-model" gets a 422.
 */

type Harness = "claude-code" | "codex" | "antigravity";
type Spec = {
  harness: Harness; model: string; instructions: string; scopes: Record<string, string>;
  budget: Record<string, unknown>; max_concurrency: number; mcp_servers: unknown[];
  harness_options: Record<string, Record<string, string>>; fallbacks?: Array<{ harness: Harness; model: string; harness_options?: Record<string, string> }>;
  skills?: Array<{ name: string; description: string; body: string }>;
};
type Override = { harness?: Harness; model?: string; scopes?: Record<string, string>; [k: string]: unknown };
type Skill = { name: string; description: string; body: string };

const HARNESSES = [
  { name: "claude-code", label: "Claude Code", tool_gating: true, permission_prompt: true, native_cost: true, resume: true },
  { name: "codex", label: "Codex", tool_gating: false, permission_prompt: false, native_cost: true, resume: true },
  { name: "antigravity", label: "Antigravity", tool_gating: true, permission_prompt: false, native_cost: false, resume: true },
];
const PROJECT = { id: "00000000-0000-4000-8000-0000000000a1", key: "WEB", name: "Web app", color: "#6e56cf", default_branch: "main", archived: false, revision: 1 };
const UUID = (n: number) => `00000000-0000-4000-8000-${String(n).padStart(12, "0")}`;

export type Saved = { definition: Array<Record<string, unknown>>; overrides: Array<{ project: string; body: Override }>; personas: Array<{ id: string; body: Record<string, unknown> }> };

const CATALOG = [
  { scope: "repo:read", description: "Clone and read the project repo", brokered: false, secret: "repo-token" },
  { scope: "tests:run", description: "Run the test suite", brokered: false },
  { scope: "db:migrate", description: "Apply migrations to staging", brokered: true },
  { scope: "wiki:write", description: "Edit wiki pages outside the agent's own memory", brokered: true, api_only: true },
];
const RANK: Record<string, number> = { allowed: 0, requires_approval: 1, denied: 2 };

/** Options seed state the default tests don't need: a project override, skills, more scopes. */
export type AgentApiOptions = {
  spec?: Partial<Spec>;
  override?: Override;
  /** Skills the project override adds and removes, applied only in resolved. */
  skillsAdd?: Skill[];
  skillsRemove?: string[];
};

export async function installAgentApi(page: Page, opts: AgentApiOptions = {}) {
  const now = () => new Date().toISOString();
  const agent = { id: UUID(1), kind: "main", name: "Atlas", handle: "atlas", color_index: 0, role: "Backend", specialty: "APIs", model: "opus-5.5", status: "idle" };
  let spec: Spec = {
    harness: "claude-code", model: "opus-5.5", instructions: "Be helpful.", scopes: { "repo:read": "allowed" },
    budget: {}, max_concurrency: 1, mcp_servers: [], harness_options: {}, ...opts.spec,
  };
  let version = 1;
  let override: Override | undefined = opts.override;
  const unhandled: string[] = [];
  const saved: Saved = { definition: [], overrides: [], personas: [] };

  const detail = () => ({
    agent: { ...agent, model: spec.model },
    specialty: agent.specialty,
    definition: { id: UUID(100 + version), version, note: "", created_at: now() },
    spec,
    versions: [{ id: UUID(100 + version), version, note: "", created_at: now() }],
    overrides: override ? [{ project: PROJECT, override, changes: Object.keys(override).map((k) => `${k} = ${String(override![k])}`), version: 1, updated_at: now() }] : [],
    harnesses: HARNESSES,
    catalog: CATALOG,
  });

  // Mirrors agentdef.Resolve for exact scope names (enough for these tests).
  const resolvedScopes = () => {
    const names = [...new Set([...Object.keys(spec.scopes), ...Object.keys(override?.scopes ?? {})])].sort();
    return names.map((name) => {
      const base = spec.scopes[name];
      const p = override?.scopes?.[name];
      const mode = p && (!base || RANK[p] > RANK[base]) ? p : (base ?? "denied");
      const source = p && (!base || RANK[p] > RANK[base]) ? "project" : "agent";
      return { scope: name, mode, source, enforcement: "harness", how: "", description: "" };
    });
  };
  const resolvedSkills = () => [
    ...(spec.skills ?? []).filter((k) => !(override && opts.skillsRemove?.includes(k.name))),
    ...(override ? (opts.skillsAdd ?? []) : []),
  ];

  const overview = () => ({
    agent: { ...agent, model: spec.model, status: "running" },
    max_concurrency: 2,
    harness: spec.harness,
    planning_runs: [],
    assignments: [
      { run_id: UUID(500), ticket: { id: UUID(600), key: "WEB-7", title: "Agents directory", status: "in_progress" }, state: "running", harness: spec.harness, model: spec.model, started_at: now(), step: "Write the scopes tab", step_position: 2, steps_done: 1, steps_total: 4 },
    ],
    queue: [{ id: UUID(601), key: "WEB-8", title: "Next thing", status: "todo" }],
    queue_count: 3,
    stats: { completed: 5, median_cycle_seconds: 3600, merged_prs: 4, closed_prs: 5, spend_usd: 12.5 },
    scopes: Object.entries(spec.scopes).map(([scope, mode]) => ({ scope, mode, enforcement: "harness", how: "" })),
  });
  const helper = {
    agent: { id: UUID(9), kind: "sub", name: "Scout", handle: "scout", color_index: 2, role: "Read-only fact gathering", specialty: "", model: "haiku-5.5", status: "idle" },
    max_concurrency: 1, harness: "claude-code", planning_runs: [], assignments: [], queue: [], queue_count: 0,
    stats: { completed: 0, median_cycle_seconds: null, merged_prs: 0, closed_prs: 0, spend_usd: 0.4 },
    scopes: [{ scope: "repo:read", mode: "allowed", enforcement: "credential", how: "" }],
  };

  const CHAT_MODELS = [
    {
      harness: "claude-code",
      label: "Claude Code",
      available: true,
      models: [
        { id: "opus-5.5", label: "Opus 5.5", default: true, efforts: ["low", "medium", "high", "xhigh", "max"] },
        { id: "sonnet-5.5", label: "Sonnet 5.5", default: false, efforts: ["low", "medium", "high", "xhigh", "max"] },
      ],
    },
    {
      harness: "codex",
      label: "Codex",
      available: true,
      models: [
        { id: "gpt-5-codex", label: "gpt-5-codex", default: true, efforts: ["low", "medium", "high"], default_effort: "medium" },
        { id: "gpt-5", label: "gpt-5", default: false, efforts: ["low", "medium", "high"] },
      ],
    },
    {
      harness: "antigravity",
      label: "Antigravity",
      available: true,
      models: [
        { id: "gemini-2.5-pro", label: "Gemini 2.5 Pro", default: true, efforts: [] },
        { id: "gemini-2.5-flash", label: "Gemini 2.5 Flash", default: false, efforts: [] },
      ],
    },
  ];

  const persona = (id: string, name: string, color: string, extra: Record<string, unknown>) => ({
    id, name, tone: "neutral", color, custom_instructions: "", capabilities: { code: false, images: false }, repos: [], is_default: false,
    chat_count: 0, in_chat_list: true, work: "none", revision: 1, created_at: now(), updated_at: now(), ...extra,
  });
  const personas: Array<ReturnType<typeof persona> & {
    handle?: string; work_model?: string; default_harness?: Harness; default_model?: string; default_effort?: string; work: string; in_chat_list: boolean; revision: number;
  }> = [
    persona(UUID(1), "Atlas", "#4547c9", {
      work: "tickets", handle: "atlas", work_model: spec.model, work_status: "idle",
      default_harness: spec.harness, default_model: spec.model,
      ...(spec.harness_options[spec.harness]?.effort ? { default_effort: spec.harness_options[spec.harness].effort } : {}),
    }),
    persona(UUID(9), "Scout", "#b42f48", {
      work: "helper", handle: "scout", work_model: "haiku-5.5", work_status: "idle", in_chat_list: false,
      default_harness: "claude-code", default_model: "haiku-5.5",
    }),
    persona(UUID(10), "Hackerman", "#9b8cff", { capabilities: { code: true, images: false }, is_default: true }),
  ];

  async function handle(route: Route) {
    const req = route.request();
    const url = new URL(req.url());
    const path = url.pathname.replace(/^\/api\/v1/, "");
    const method = req.method();
    const json = (data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
    const body = () => (req.postDataJSON() ?? {}) as Record<string, unknown>;

    if (path === "/bootstrap") {
      return json({
        workspace: { id: UUID(2), name: "Acme", slug: "acme" },
        me: { id: UUID(3), name: "Liam", email: "liam@example.com", initials: "L", role_title: "Owner" },
        users: [], agents: [agent], epics: [], labels: [], projects: [PROJECT],
        counts: { inbox: 0, wiki_suggestions: 0, live_agents: 0 },
      });
    }
    if (path === "/persona-dock") return json({ personas: [], harnesses: [] });
    if (path === "/chat-models") return json(CHAT_MODELS);
    // Settings → Sign-in: an install already set up with a password.
    if (path === "/auth/status") return json({ claimed: true, password_set: true, signed_in: true });
    if (path === "/runner") return json({ online: true, runners: [], slots: 1, busy: 0, live: 0, queued: 0 });
    // Sidebar settings dot (LAZYAGENTS-44): both harness keys set, so no dot.
    if (path === "/secrets") return json({ key_configured: true, known: [], secrets: ["harness:anthropic", "harness:openai"].map((name, i) => ({ id: `secret-${i}`, name, created_at: "2026-11-01T00:00:00Z", updated_at: "2026-11-01T00:00:00Z" })) });
    if (path === "/saved-views" && method === "GET") return json({ views: [] });
    if (path === "/agents/atlas" && method === "GET") return json(detail());
    if (path === "/agents/atlas/definition" && method === "PUT") {
      const b = body();
      saved.definition.push(b);
      const s = b.spec as Spec;
      if (s.model === "rejected-model") {
        return json({ code: "invalid", field: "model", message: `model "${s.model}" is not available` }, 422);
      }
      spec = s;
      version++;
      return json(detail());
    }
    if (path === "/agents/atlas/overrides/WEB" && method === "PUT") {
      const b = body() as Override;
      saved.overrides.push({ project: "WEB", body: b });
      override = Object.keys(b).some((k) => b[k] !== undefined && !(Array.isArray(b[k]) && (b[k] as unknown[]).length === 0)) ? b : undefined;
      return json(detail());
    }
    if (path === "/agent-overviews") return json({ agents: [overview(), helper], stats_as_of: now() });
    if (path === "/agents/atlas/runs") {
      const run = (n: number, state: string, key: string, title: string, cost: number, source: string) => ({
        id: UUID(700 + n), ticket: { id: UUID(800 + n), key, title, status: "done" }, state, harness: "claude-code", model: "opus-5.5",
        started_at: new Date(Date.now() - n * 3_600_000).toISOString(), ended_at: new Date(Date.now() - n * 3_600_000 + 360_000).toISOString(),
        cost_usd: cost, cost_source: source, tool_calls: 14, tokens: 1000,
      });
      return json({ runs: [run(1, "completed", "WEB-5", "Mockup review", 0.31, "reported"), run(2, "failed", "WEB-4", "Board drag and drop", 0.44, "reported"), run(3, "cancelled", "WEB-3", "Runs filters", 0, "unknown")], has_more: false });
    }
    if (path === "/wiki/pages") {
      const pg = (n: number, path: string, title: string, extra: Record<string, unknown> = {}) => ({
        id: UUID(900 + n), path, title, author: { type: "agent", name: "Atlas" }, updated_at: new Date(Date.now() - n * 86_400_000).toISOString(), published: true, suggestions: 0, ...extra,
      });
      return json({
        pages: [pg(3, "agents/atlas/Epic stacking", "Epic stacking"), pg(1, "agents/atlas/Memory", "Memory"), pg(2, "agents/atlas/Signing commits", "Signing commits", { suggestions: 1 }), pg(4, "agents/scout/Memory", "Memory"), pg(5, "Patterns/Go/Wrap errors", "Wrap errors")],
        suggestions: 1,
      });
    }
    if (path === "/agents/atlas/resolved") {
      return json({
        harness: override?.harness ?? spec.harness, model: override?.model ?? spec.model, instructions: spec.instructions,
        scopes: resolvedScopes(), skills: resolvedSkills(), budget: {}, max_concurrency: 1, mcp_servers: [], harness_options: {}, setup: [],
        provenance: { ...(override?.harness ? { harness: "project" } : {}), ...(override?.model ? { model: "project" } : {}) },
      });
    }
    // Agents and personas are one actor: each work record is a persona with its id.
    if (path === "/personas" && method === "GET") return json({ personas, default_persona_id: personas[2].id });
    const personaPatch = path.match(/^\/personas\/([^/]+)$/);
    if (personaPatch && method === "PATCH") {
      const p = personas.find((x) => x.id === personaPatch[1]);
      if (!p) return json({ code: "not_found", message: "no persona" }, 404);
      const b = body();
      saved.personas.push({ id: p.id, body: b });
      Object.assign(p, b.work ? { work: b.work, handle: p.handle ?? p.name.toLowerCase(), work_model: p.work_model ?? "opus-5.5", work_status: "idle" } : {}, "in_chat_list" in b ? { in_chat_list: b.in_chat_list } : {});
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
        else p.default_effort = String(b.default_effort);
      }
      if (p.id === agent.id && p.work !== "none") {
        const nextHarness = p.default_harness ?? "claude-code";
        const nextModel = p.default_model ?? "sonnet-5.5";
        spec = {
          ...spec,
          harness: nextHarness,
          model: nextModel,
          harness_options: {
            ...spec.harness_options,
            ...(p.default_effort ? { [nextHarness]: { ...(spec.harness_options[nextHarness] ?? {}), effort: p.default_effort } } : {}),
          },
        };
        if (!p.default_effort && spec.harness_options[nextHarness]) {
          const rest = { ...spec.harness_options[nextHarness] };
          delete rest.effort;
          if (Object.keys(rest).length) spec.harness_options[nextHarness] = rest;
          else delete spec.harness_options[nextHarness];
        }
        p.work_model = nextModel;
        agent.model = nextModel;
        version++;
      }
      p.revision++;
      return json(p);
    }
    if (path === "/connectors" && method === "GET") return json({ connectors: [] });
    const menu = menuResponse(method, path);
    if (menu) return json(menu);
    // The agent list is in Customization, which counts memories in its header.
    if (path === "/memories" && method === "GET") return json({ memories: [], total: 0, has_more: false });
    unhandled.push(`${method} ${path}`);
    return json({ code: "not_found", message: `mock: no handler for ${method} ${path}` }, 404);
  }

  await page.addInitScript(() => {
    class FakeEventSource {
      onopen?: () => void;
      onerror?: () => void;
      onmessage?: (e: { data: string }) => void;
      constructor() {
        setTimeout(() => this.onopen?.(), 0);
      }
      close() {}
    }
    (window as unknown as { EventSource: unknown }).EventSource = FakeEventSource;
  });
  await page.route("**/api/v1/**", handle);
  return { unhandled, saved };
}
