"use client";

import { useMemo } from "react";
import { useMutation, useQuery, useQueryClient, keepPreviousData } from "@tanstack/react-query";
import {
  api,
  ApiError,
  contentUrl,
  postForm,
  unwrap,
  type AgentDetail,
  type AgentOverride,
  type AgentSpec,
  type Artifact,
  type ArtifactType,
  type Schemas,
  type Ticket,
  type TicketPatch,
  type TicketStatus,
} from "./client";
import { runEnded } from "../chat-dispatch";
import { createEventWindowSelector } from "../chat-events";
import { personaKeys } from "./persona-hooks";
import { confirmApprovalLocally } from "../desktop-bridge";

const RUN_EVENTS_PAGE = 1000;
const RUN_EVENTS_OVERLAP = 32;

async function eventsAfter<E extends { seq: number }>(known: E[], page: (after: number) => Promise<E[]>): Promise<E[]> {
  let all = known;
  let after = known.length > RUN_EVENTS_OVERLAP ? known[known.length - RUN_EVENTS_OVERLAP - 1].seq : 0;
  for (;;) {
    const next = await page(after);
    const have = new Set(all.filter((e) => e.seq > after).map((e) => e.seq));
    const fresh = next.filter((e) => e.seq > after && !have.has(e.seq));
    if (fresh.length) {
      const inOrder = fresh[0].seq > (all.at(-1)?.seq ?? 0) && fresh.every((e, i) => i === 0 || e.seq > fresh[i - 1].seq);
      all = inOrder ? [...all, ...fresh] : [...all, ...fresh].sort((a, b) => a.seq - b.seq);
    }
    const newest = next.at(-1)?.seq;
    if (next.length < RUN_EVENTS_PAGE || newest === undefined || newest <= after) return all;
    after = newest;
  }
}

export type TicketView = "active" | "backlog" | "agent_owned" | "needs_human" | "all";
export type TicketFilters = {
  ready?: boolean;
  epic?: string;
  project?: string;
  view?: TicketView;
  status?: TicketStatus;
  assignee?: string;
  label?: string;
  q?: string;
};

// Query keys. The shell SSE subscription invalidates these prefixes.
export const keys = {
  bootstrap: ["bootstrap"] as const,
  tickets: ["tickets"] as const,
  ticketList: (f: TicketFilters) => ["tickets", "list", f] as const,
  ticket: (key: string) => ["tickets", "detail", key] as const,
  activity: (key: string) => ["tickets", "activity", key] as const,
  artifacts: ["artifacts"] as const,
  artifactList: (f: ArtifactFilters) => ["artifacts", "list", f] as const,
  artifact: (id: string) => ["artifacts", "detail", id] as const,
  agent: (handle: string) => ["agents", handle] as const,
  resolved: (handle: string, project?: string) => ["agents", handle, "resolved", project ?? ""] as const,
};

export type ArtifactFilters = { type?: ArtifactType; project?: string; q?: string };

export function useBootstrap() {
  return useQuery({
    queryKey: keys.bootstrap,
    queryFn: () => unwrap(api.GET("/bootstrap")),
    staleTime: 60_000,
    // Slow fallback while the SSE connection is unavailable.
    refetchInterval: 20_000,
  });
}

const LIVE_RUN = ["queued", "starting", "running", "waiting", "waiting_for_quota", "paused", "blocked"];

/** True while the ticket has a run an agent may still be working on. */
export function hasLiveRun(t?: Ticket) {
  return !!t?.run && LIVE_RUN.includes(t.run.state);
}

// Slow fallback for live tickets if the realtime connection is interrupted.
const LIVE_POLL_MS = 5000;

export function useTicket(key: string) {
  return useQuery({
    enabled: !!key,
    queryKey: keys.ticket(key),
    queryFn: () => unwrap(api.GET("/tickets/{key}", { params: { path: { key } } })),
    refetchInterval: (q) => (hasLiveRun(q.state.data) ? LIVE_POLL_MS : false),
  });
}

/** Patch a ticket. The detail cache updates optimistically; lists refetch. */
export function useUpdateTicket(key: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (patch: TicketPatch) =>
      unwrap(api.PATCH("/tickets/{key}", { params: { path: { key } }, body: patch })),
    onMutate: async (patch) => {
      await qc.cancelQueries({ queryKey: keys.ticket(key) });
      const prev = qc.getQueryData<Ticket>(keys.ticket(key));
      if (prev) {
        const next = { ...prev };
        if (patch.title !== undefined) next.title = patch.title;
        if (patch.description_md !== undefined) next.description_md = patch.description_md;
        if (patch.status !== undefined) next.status = patch.status;
        if (patch.priority !== undefined) next.priority = patch.priority;
        if (patch.requires_mockup !== undefined) next.requires_mockup = patch.requires_mockup;
        qc.setQueryData(keys.ticket(key), next);
      }
      return { prev };
    },
    onError: (_e, _p, ctx) => ctx?.prev && qc.setQueryData(keys.ticket(key), ctx.prev),
    onSuccess: (t) => qc.setQueryData(keys.ticket(key), t),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ["tickets", "list"] });
      qc.invalidateQueries({ queryKey: keys.activity(key) });
      qc.invalidateQueries({ queryKey: ["knowledge"] }); // [[links]] in the description
    },
  });
}

// ---------------------------------------------------------------- artifacts

export function useArtifacts(f: ArtifactFilters) {
  return useQuery({
    queryKey: keys.artifactList(f),
    queryFn: () => unwrap(api.GET("/artifacts", { params: { query: f } })),
  });
}

export function useArtifact(id: string | undefined) {
  return useQuery({
    queryKey: keys.artifact(id ?? ""),
    queryFn: () => unwrap(api.GET("/artifacts/{id}", { params: { path: { id: id! } } })),
    enabled: !!id,
  });
}

/** Body of an older text version, fetched raw; undefined id or the current version skip it. */
export function useArtifactVersionBody(a: Artifact | undefined, versionId: string | null) {
  const v = a?.versions.find((x) => x.id === versionId);
  return useQuery({
    queryKey: ["artifacts", "content", a?.id, versionId],
    enabled: !!a && !!v && (v.content.kind === "markdown" || v.content.kind === "svg") && v.id !== a.current_version.id,
    queryFn: async () => {
      const res = await fetch(contentUrl(a!.id, v!.id));
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.text();
    },
    staleTime: Infinity, // versions are immutable
  });
}

/** Create from FormData (project_key, type, title?, body_md | file, …). */
export function useCreateArtifact() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (form: FormData) => postForm<Artifact>("/artifacts", form),
    onSuccess: (a) => {
      qc.setQueryData(keys.artifact(a.id), a);
      qc.invalidateQueries({ queryKey: ["artifacts", "list"] });
    },
  });
}

export function useNewVersion(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (form: FormData) => postForm<Artifact>(`/artifacts/${id}/versions`, form),
    onSuccess: (a) => {
      qc.setQueryData(keys.artifact(a.id), a);
      qc.invalidateQueries({ queryKey: ["artifacts", "list"] });
      qc.invalidateQueries({ queryKey: ["knowledge"] });
    },
  });
}

export function useUpdateArtifact(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { title?: string; summary?: string; epic_id?: string | null }) =>
      unwrap(api.PATCH("/artifacts/{id}", { params: { path: { id } }, body })),
    onSuccess: (a) => {
      qc.setQueryData(keys.artifact(a.id), a);
      qc.invalidateQueries({ queryKey: ["artifacts", "list"] });
    },
  });
}

/** Person review of a mockup version (current version only). */
export function useReviewMockup(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { versionId: string; decision: "approved" | "changes_requested"; note?: string; pins?: Schemas["MockupPin"][] }) =>
      unwrap(
        api.POST("/artifacts/{id}/versions/{versionId}/review", {
          params: { path: { id, versionId: v.versionId } },
          body: { decision: v.decision, note: v.note, pins: v.pins },
        }),
      ),
    onSuccess: (a) => {
      qc.setQueryData(keys.artifact(a.id), a);
      qc.invalidateQueries({ queryKey: ["artifacts", "list"] });
      qc.invalidateQueries({ queryKey: keys.tickets });
      qc.invalidateQueries({ queryKey: ["inbox"] });
      qc.invalidateQueries({ queryKey: keys.bootstrap });
    },
  });
}

// ------------------------------------------------------------------- agents

export function useAgent(handle: string) {
  return useQuery({ queryKey: keys.agent(handle), queryFn: () => unwrap(api.GET("/agents/{handle}", { params: { path: { handle } } })) });
}

export function useResolved(handle: string, project?: string) {
  return useQuery({
    queryKey: keys.resolved(handle, project),
    queryFn: () => unwrap(api.GET("/agents/{handle}/resolved", { params: { path: { handle }, query: { project } } })),
  });
}

function useAgentMutation<V>(handle: string, fn: (v: V) => Promise<AgentDetail>) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: (d) => {
      qc.setQueryData(keys.agent(handle), d);
      qc.invalidateQueries({ queryKey: ["agents", handle, "resolved"] });
      qc.invalidateQueries({ queryKey: ["agent-overviews"] });
      qc.invalidateQueries({ queryKey: personaKeys.all });
      qc.invalidateQueries({ queryKey: keys.bootstrap });
    },
  });
}

export type DefinitionInput = { name: string; role: string; specialty: string; color_index: number; spec: AgentSpec; note?: string };

export function useSaveDefinition(handle: string) {
  return useAgentMutation(handle, (body: DefinitionInput) =>
    unwrap(api.PUT("/agents/{handle}/definition", { params: { path: { handle } }, body })),
  );
}

export function useSetOverride(handle: string) {
  return useAgentMutation(handle, (v: { project: string; override: AgentOverride }) =>
    unwrap(api.PUT("/agents/{handle}/overrides/{project}", { params: { path: { handle, project: v.project } }, body: v.override })),
  );
}

// ------------------------------------------------------- tokens and secrets

export function useAgentTokens(handle: string) {
  return useQuery({
    queryKey: ["agents", handle, "tokens"],
    queryFn: () => unwrap(api.GET("/agents/{handle}/tokens", { params: { path: { handle } } })),
  });
}

export function useCreateToken(handle: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (label: string) => unwrap(api.POST("/agents/{handle}/tokens", { params: { path: { handle } }, body: { label } })),
    onSuccess: () => qc.invalidateQueries({ queryKey: ["agents", handle, "tokens"] }),
  });
}

export function useRevokeToken(handle: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (tokenId: string) => {
      const r = await api.DELETE("/agents/{handle}/tokens/{tokenId}", { params: { path: { handle, tokenId } } });
      if (!r.response.ok) throw new Error("Couldn't revoke the token");
    },
    onSettled: () => qc.invalidateQueries({ queryKey: ["agents", handle, "tokens"] }),
  });
}

export function useSecrets() {
  return useQuery({ queryKey: ["secrets"], queryFn: () => unwrap(api.GET("/secrets")), staleTime: 30_000, retry: 1 });
}

// --------------------------------------------------------- runs, approvals

function useTicketRefresh(key: string) {
  const qc = useQueryClient();
  return () => {
    if (key) {
      qc.invalidateQueries({ queryKey: keys.ticket(key) });
      qc.invalidateQueries({ queryKey: keys.activity(key) });
    }
    qc.invalidateQueries({ queryKey: ["runs"] });
    qc.invalidateQueries({ queryKey: ["chats"] });
    qc.invalidateQueries({ queryKey: keys.bootstrap });
    qc.invalidateQueries({ queryKey: ["inbox"] });
  };
}

export function useDecideApproval(key: string) {
  const refresh = useTicketRefresh(key);
  return useMutation({
    mutationFn: async (v: { id: string; decision: "approve" | "deny"; note?: string }) => {
      if (v.decision === "approve") await confirmApprovalLocally("run_approvals");
      return unwrap(api.POST("/approvals/{id}/{decision}", { params: { path: { id: v.id, decision: v.decision } }, body: { note: v.note } }));
    },
    onSettled: refresh,
  });
}

export function useControlRun(key: string) {
  const refresh = useTicketRefresh(key);
  return useMutation({
    mutationFn: (v: { id: string; action: "pause" | "resume" | "cancel" }) =>
      unwrap(api.POST("/runs/{id}/{action}", { params: { path: { id: v.id, action: v.action } } })),
    onSettled: refresh,
  });
}

// ----------------------------------------------------- dispatch & runs (§6)

export function useDispatchPreview(key: string | undefined) {
  return useQuery({
    queryKey: ["tickets", "dispatch", key] as const,
    queryFn: () => unwrap(api.GET("/tickets/{key}/dispatch", { params: { path: { key: key! } } })),
    enabled: !!key,
    staleTime: 5_000,
  });
}

export function useDispatch() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (keys: string[]) => {
      if (keys.length === 1) {
        await unwrap(api.POST("/tickets/{key}/dispatch", { params: { path: { key: keys[0] } } }));
        return 1;
      }
      return unwrap(api.POST("/tickets/dispatch", { body: { keys } })).then((d) => d.dispatched);
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: keys.tickets });
      qc.invalidateQueries({ queryKey: keys.bootstrap });
      qc.invalidateQueries({ queryKey: ["runner"] });
    },
  });
}

const chatTicketRunsKey = (chatId: string) => ["chats", chatId, "ticket-runs"] as const;

/** The ticket runs a chat started from ```dispatch cards; polled while any is live. */
export function useChatTicketRuns(chatId?: string) {
  return useQuery({
    enabled: !!chatId,
    queryKey: chatTicketRunsKey(chatId ?? ""),
    queryFn: () => unwrap(api.GET("/chats/{id}/runs", { params: { path: { id: chatId! } } })),
    refetchInterval: (q) => (q.state.data?.runs.some((r) => !runEnded(r.state)) ? LIVE_POLL_MS : false),
  });
}

/** Starts a ticket's run from a chat's ```dispatch card, as the signed-in person. */
export function useStartChatTicketRun(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["ChatTicketRunStart"]) => unwrap(api.POST("/chats/{id}/runs", { params: { path: { id: chatId } }, body })),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: chatTicketRunsKey(chatId) });
      qc.invalidateQueries({ queryKey: keys.tickets });
      qc.invalidateQueries({ queryKey: ["runner"] });
    },
  });
}

export function useRunnerStatus() {
  return useQuery({
    queryKey: ["runner"] as const,
    queryFn: () => unwrap(api.GET("/runner")),
    // Poll faster while offline or starting so the banner and status clear quickly once a runner registers.
    staleTime: (q) => (q.state.data && !q.state.data.online ? 0 : 30_000),
    refetchInterval: (q) => (q.state.data && !q.state.data.online ? 2_000 : 15_000),
  });
}

/** Update workspace runner settings (host-folder workspaces, subagent and delegation concurrency limits). */
export function useUpdateRunnerSettings() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["RunnerSettings"]) => unwrap(api.PUT("/runner/settings", { body })),
    onSuccess: (status) => qc.setQueryData(["runner"], status),
  });
}

export function useControlRunById(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (action: "pause" | "resume" | "cancel" | "retry") => unwrap(api.POST("/runs/{id}/{action}", { params: { path: { id, action } } })),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ["runs", id] });
      qc.invalidateQueries({ queryKey: keys.tickets });
    },
  });
}

export type RunListFilters = { state: string; agent?: string; project?: string; purpose?: "ticket" | "planning" | "chat" };

type ListRunsState = "live" | "all" | "queued" | "starting" | "running" | "waiting" | "waiting_for_quota" | "paused" | "blocked" | "completed" | "failed" | "cancelled";

function runListOptions(f: RunListFilters, offset: number) {
  return {
    queryKey: ["runs", "list", f, offset] as const,
    queryFn: () => unwrap(api.GET("/runs", { params: { query: { state: f.state as ListRunsState, agent: f.agent, project: f.project, purpose: f.purpose, offset } } })),
    refetchInterval: f.state === "live" ? 10_000 : (false as const),
  };
}

/** The first page of live runs, for surfaces that only glance at them. */
export function useLiveRuns(enabled: boolean) {
  return useQuery({ ...runListOptions({ state: "live" } as RunListFilters, 0), enabled });
}

export type CostQuery = { from?: string; to?: string; project?: string; ticket?: string; chat?: string; epic?: string };

/**
 * Spend summed server-side from run counters (GET /costs). Ticket and range
 * reports live under ["runs"] and a chat's under ["chats"], so run and chat
 * SSE events refresh them; the interval covers spend added by a live run.
 */
export function useCosts(q: CostQuery, enabled = true) {
  return useQuery({
    queryKey: [q.chat ? "chats" : "runs", "costs", q] as const,
    queryFn: () => unwrap(api.GET("/costs", { params: { query: q } })),
    enabled,
    refetchInterval: 30_000,
  });
}

// ------------------------------------------------------------- wiki (§12)

export const wikiKeys = {
  all: ["wiki"] as const,
  tree: ["wiki", "tree"] as const,
  page: (path: string) => ["wiki", "page", path.toLowerCase()] as const,
  suggestions: (artifactId?: string) => ["wiki", "suggestions", artifactId ?? ""] as const,
  // Links, backlinks and graphs change whenever anything is saved, so they
  // share one prefix that every save invalidates.
  knowledge: ["knowledge"] as const,
};

export function useWikiTree() {
  return useQuery({ queryKey: wikiKeys.tree, queryFn: () => unwrap(api.GET("/wiki/pages")) });
}

export function useWikiPage(path: string) {
  return useQuery({
    queryKey: wikiKeys.page(path),
    queryFn: () => unwrap(api.GET("/wiki/page", { params: { query: { path } } })),
    enabled: path !== "",
    retry: (n, e) => !(e instanceof ApiError && e.status === 404) && n < 2,
  });
}

/** Everything a page save can change: the tree, pages, links, artifacts lists. */
function useInvalidateWiki() {
  const qc = useQueryClient();
  return () => {
    qc.invalidateQueries({ queryKey: wikiKeys.all });
    qc.invalidateQueries({ queryKey: wikiKeys.knowledge });
    qc.invalidateQueries({ queryKey: keys.artifacts });
    qc.invalidateQueries({ queryKey: keys.bootstrap });
    qc.invalidateQueries({ queryKey: ["inbox"] });
  };
}

export function useCreateWikiPage() {
  const invalidate = useInvalidateWiki();
  return useMutation({
    mutationFn: (body: Schemas["NewWikiPage"]) => unwrap(api.POST("/wiki/pages", { body })),
    onSuccess: invalidate,
  });
}

/** Resolves [[link]] texts in one request; cached per set of refs. */
export function useResolvedLinks(refs: string[]) {
  const sorted = [...new Set(refs)].sort();
  return useQuery({
    queryKey: [...wikiKeys.knowledge, "resolve", sorted] as const,
    queryFn: () => unwrap(api.GET("/knowledge/resolve", { params: { query: { ref: sorted } } })).then((d) => d.links),
    enabled: sorted.length > 0,
    staleTime: 30_000,
  });
}

export function useLinkSuggest(q: string, enabled = true) {
  return useQuery({
    queryKey: [...wikiKeys.knowledge, "suggest", q] as const,
    queryFn: () => unwrap(api.GET("/knowledge/suggest", { params: { query: { q } } })).then((d) => d.targets),
    enabled,
    staleTime: 10_000,
    placeholderData: (prev) => prev,
  });
}

export function useBacklinks(kind: Schemas["NodeKind"], id: string | undefined) {
  return useQuery({
    queryKey: [...wikiKeys.knowledge, "backlinks", kind, id] as const,
    queryFn: () => unwrap(api.GET("/knowledge/backlinks", { params: { query: { kind, id: id! } } })),
    enabled: !!id,
  });
}

export function useLinkMention() {
  const qc = useQueryClient();
  const invalidate = useInvalidateWiki();
  return useMutation({
    mutationFn: async (body: { target_kind: Schemas["NodeKind"]; target_id: string; source_kind: "artifact" | "ticket"; source_id: string }) => {
      const { error, response } = await api.POST("/knowledge/link-mention", { body });
      if (error) await unwrap(Promise.resolve({ error, response }));
    },
    onSuccess: () => {
      invalidate();
      qc.invalidateQueries({ queryKey: keys.tickets });
    },
  });
}

// ------------------------------------------------------------- attention
export function useInbox(project?: string, enabled = true) {
  return useQuery({enabled,queryKey:["inbox",project??""],queryFn:()=>unwrap(api.GET("/inbox",{params:{query:{project}}})).then(d=>d.items)});
}
/** ⌘K search: hits capped per type, with how many of each matched; kind lists one type in full. */
export function useSearch(q:string,project?:string,kind?:Schemas["SearchType"],enabled=true) {
 return useQuery({queryKey:["search",q,project??"",kind??""],queryFn:()=>unwrap(api.GET("/search",{params:{query:{q,project,kind}}})),enabled:enabled&&q.trim().length>0,placeholderData:keepPreviousData});
}
export function useAgentOverviews() {
 return useQuery({queryKey:["agent-overviews"],queryFn:()=>unwrap(api.GET("/agent-overviews")),refetchInterval:30_000});
}
export function useAgentRuns(handle:string,offset=0) {
 return useQuery({queryKey:["agent-overviews","runs",handle,offset],queryFn:()=>unwrap(api.GET("/agents/{handle}/runs",{params:{path:{handle},query:{offset}}}))});
}

// ---- Chats (ADR: Project chat sessions). SSE `chat.updated` invalidates ["chats"].

export const chatKeys = {
  all: ["chats"] as const,
  /**
   * persona: a persona id, "all", "none", or "" for the server's default (the caller's default persona).
   * space: a space id, "all", or "" for chats outside every space (the server's default).
   */
  list: (archived = false, persona = "", space = "") => ["chats", "list", archived, persona, space] as const,
  detail: (id: string) => ["chats", "detail", id] as const,
  messages: (id: string) => ["chats", "messages", id] as const,
  proposals: (id: string) => ["chats", "proposals", id] as const,
  characterProposals: (id: string) => ["chats", "character-proposals", id] as const,
  models: ["chats", "models"] as const,
  suggestions: ["chats", "suggestions"] as const,
};

// Slow fallback while a turn runs and the realtime connection is unavailable.
const CHAT_POLL_MS = 3000;

/** The person's chats, whatever project they have attached; outside every space unless `space` says otherwise. */
export function useChats(archived = false, persona = "", enabled = true, space = "") {
  return useQuery({
    enabled,
    queryKey: chatKeys.list(archived, persona, space),
    queryFn: () =>
      unwrap(api.GET("/chats", { params: { query: { archived, ...(persona ? { persona_id: persona } : {}), ...(space ? { space } : {}) } } })),
  });
}

export function useChat(id?: string) {
  return useQuery({
    enabled: !!id,
    queryKey: chatKeys.detail(id ?? ""),
    queryFn: () => unwrap(api.GET("/chats/{id}", { params: { path: { id: id! } } })),
    retry: (n, e) => !(e instanceof ApiError && e.status === 404) && n < 2,
    refetchInterval: (q) => (q.state.data?.state === "running" ? CHAT_POLL_MS : false),
  });
}

/** Conversation starters for an empty chat, written ahead of time by the runner. */
export function useChatSuggestions() {
  return useQuery({
    queryKey: chatKeys.suggestions,
    queryFn: () => unwrap(api.GET("/chat-suggestions")),
  });
}

/** limit above the usual 200 loads far enough back to reach a search hit. */
export function useChatMessages(id?: string, limit = 200) {
  return useQuery({
    enabled: !!id,
    queryKey: limit === 200 ? chatKeys.messages(id ?? "") : ([...chatKeys.messages(id ?? ""), limit] as const),
    queryFn: () => unwrap(api.GET("/chats/{id}/messages", { params: { path: { id: id! }, query: { limit } } })),
  });
}

const researchKey = (chatId: string) => ["chats", "research", chatId] as const;

/** A chat's research jobs; follows along while any is active. */
export function useChatResearch(chatId?: string) {
  return useQuery({
    enabled: !!chatId,
    queryKey: researchKey(chatId ?? ""),
    queryFn: () => unwrap(api.GET("/chats/{id}/research", { params: { path: { id: chatId! } } })),
    refetchInterval: (q) => (q.state.data?.jobs.some((j) => ["running", "finishing", "ready", "writing"].includes(j.state)) ? 3000 : false),
  });
}

export function useStartResearch(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["ResearchStart"]) => unwrap(api.POST("/chats/{id}/research", { params: { path: { id: chatId } }, body })),
    onSettled: () => qc.invalidateQueries({ queryKey: researchKey(chatId) }),
  });
}

export function useControlResearch(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { id: string; action: "stop" | "finish" }) => unwrap(api.POST("/chats/{id}/research/{jobId}/{action}", { params: { path: { id: chatId, jobId: v.id, action: v.action } } })),
    onSettled: () => qc.invalidateQueries({ queryKey: researchKey(chatId) }),
  });
}

/** Replaces the last message and redoes its turn; the same text retries it. */
export function useEditLastChatMessage(id: string) {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: (body: string) => unwrap(api.POST("/chats/{id}/edit-last", { params: { path: { id } }, body: { body } })),
    onSettled: done,
  });
}

/** Finds messages across the caller's chats; waits for at least two characters. */
export function useChatSearch(q: string) {
  const query = q.trim();
  return useQuery({
    enabled: query.length >= 2,
    queryKey: ["chats", "search", query] as const,
    queryFn: () => unwrap(api.GET("/chat-search", { params: { query: { q: query } } })),
    staleTime: 10_000,
  });
}

/** Who is working, replied or needs the person, across their chats. SSE `chat.updated` refreshes it. */
/** Sidebar activity: personas with chat activity, plus harness activity and plan usage. */
export function usePersonaDock() {
  return useQuery({
    queryKey: ["dock"] as const,
    queryFn: () => unwrap(api.GET("/persona-dock")),
    // Usage readings land in the background with no event to announce them.
    refetchInterval: 60_000,
  });
}

export function useMarkChatRead() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { id: string; seq: number }) => {
      await api.POST("/chats/{id}/read", { params: { path: { id: v.id } }, body: { seq: v.seq } });
    },
    // The history lists carry `unread` too, so their dots clear with the dock's.
    onSuccess: () => Promise.all([qc.invalidateQueries({ queryKey: ["dock"] }), qc.invalidateQueries({ queryKey: [...chatKeys.all, "list"] })]),
  });
}

/** Personas the chat's personas proposed; pending ones wait for the person's approval. */
export function usePersonaProposals(id?: string) {
  return useQuery({
    enabled: !!id,
    queryKey: chatKeys.proposals(id ?? ""),
    queryFn: () => unwrap(api.GET("/chats/{id}/persona-proposals", { params: { path: { id: id! } } })),
  });
}

/** Approving creates the persona (and may start its introduction), so personas and the chat refetch. */
export function useDecidePersonaProposal(chatId: string) {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: (v: { id: string; decision: "approve" | "decline"; fallback_png_base64?: string }) =>
      unwrap(api.POST("/chats/{id}/persona-proposals/{proposal_id}", { params: { path: { id: chatId, proposal_id: v.id } }, body: { decision: v.decision, fallback_png_base64: v.fallback_png_base64 } })),
    onSettled: done,
  });
}

/** Animated SVG character drafts proposed in this chat; pending ones wait for the person's approval. */
export function usePersonaCharacterProposals(id?: string) {
  return useQuery({
    enabled: !!id,
    queryKey: chatKeys.characterProposals(id ?? ""),
    queryFn: () => unwrap(api.GET("/chats/{id}/persona-character-proposals", { params: { path: { id: id! } } })),
  });
}

/** Approving updates the target persona's SVG character and refreshes personas and chats. */
export function useDecidePersonaCharacterProposal(chatId: string) {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: (v: { id: string; decision: "approve" | "decline"; fallback_png_base64?: string }) =>
      unwrap(api.POST("/chats/{id}/persona-character-proposals/{proposal_id}", { params: { path: { id: chatId, proposal_id: v.id } }, body: { decision: v.decision, fallback_png_base64: v.fallback_png_base64 } })),
    onSettled: done,
  });
}

export function useChatModels() {
  return useQuery({
    queryKey: chatKeys.models,
    queryFn: () => unwrap(api.GET("/chat-models")),
    // A partial catalog is a successful response, so query retries won't
    // pick up a runner's later answer. Poll only while discovery is pending.
    staleTime: (q) => (q.state.data?.some((g) => g.checking) ? 0 : 60_000),
    refetchInterval: (q) => (q.state.data?.some((g) => g.checking) ? 2_000 : false),
  });
}

function useChatInvalidate() {
  const qc = useQueryClient();
  // Persona.chat_count changes when a chat is created or deleted.
  return () => Promise.all([qc.invalidateQueries({ queryKey: chatKeys.all }), qc.invalidateQueries({ queryKey: personaKeys.all })]);
}

export function useCreateChat() {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: (body: Schemas["NewChat"]) => unwrap(api.POST("/chats", { body })),
    // Not awaited: callers open the new chat from mutate's onSuccess, which would wait for every chat query to refetch.
    onSettled: () => void done(),
  });
}

export function useUpdateChat() {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: (v: { id: string; patch: Schemas["ChatPatch"] }) =>
      unwrap(api.PATCH("/chats/{id}", { params: { path: { id: v.id } }, body: v.patch })),
    onSettled: done,
  });
}

export function useCompactChat(id: string) {
  const qc = useQueryClient();
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: (focus?: string) =>
      unwrap(api.POST("/chats/{id}/compact", { params: { path: { id } }, body: focus ? { focus } : {} })),
    onSuccess: (chat) => qc.setQueryData(chatKeys.detail(id), chat),
    onSettled: async () => {
      await Promise.all([
        qc.invalidateQueries({ queryKey: chatKeys.detail(id) }),
        qc.invalidateQueries({ queryKey: chatKeys.messages(id) }),
        done(),
      ]);
    },
  });
}

export function useForkChat(id: string) {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: (body: Schemas["ForkChatRequest"]) =>
      unwrap(api.POST("/chats/{id}/fork", { params: { path: { id } }, body })),
    onSettled: done,
  });
}

export function useSetChatAutoRollover(id: string) {
  const qc = useQueryClient();
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: (v: { revision: number; autoRolloverTokens: number | null }) =>
      unwrap(
        api.PATCH("/chats/{id}", {
          params: { path: { id } },
          body: { revision: v.revision, auto_rollover_tokens: v.autoRolloverTokens },
        }),
      ),
    onSuccess: (chat) => qc.setQueryData(chatKeys.detail(id), chat),
    onSettled: done,
  });
}

export function useSetChatMessageBookmark(chatId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { messageId: string; bookmarked: boolean }) =>
      unwrap(
        api.PATCH("/chats/{id}/messages/{messageId}/bookmark", {
          params: { path: { id: chatId, messageId: v.messageId } },
          body: { bookmarked: v.bookmarked },
        }),
      ),
    onMutate: async (v) => {
      type MessagesPage = { messages: Schemas["ChatMessage"][]; has_more?: boolean };
      const key = chatKeys.messages(chatId);
      await qc.cancelQueries({ queryKey: key });
      const prev = qc.getQueryData<MessagesPage>(key);
      if (prev) {
        qc.setQueryData<MessagesPage>(key, {
          ...prev,
          messages: prev.messages.map((m) =>
            m.id === v.messageId
              ? { ...m, bookmarked: v.bookmarked || undefined, bookmarked_at: v.bookmarked ? new Date().toISOString() : undefined }
              : m,
          ),
        });
      }
      return { prev };
    },
    onError: (_err, _v, ctx) => {
      if (ctx?.prev) qc.setQueryData(chatKeys.messages(chatId), ctx.prev);
    },
    onSettled: () => qc.invalidateQueries({ queryKey: chatKeys.messages(chatId) }),
  });
}

export function useCreateTicket() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["NewTicket"]) => unwrap(api.POST("/tickets", { body })),
    onSettled: () => qc.invalidateQueries({ queryKey: keys.tickets }),
  });
}

/** Picks which of your addresses a coding chat commits as; it applies from the next turn, so it works mid-reply. */
export function useSetChatCommitEmail() {
  const qc = useQueryClient();
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: (v: { id: string; email: string }) =>
      unwrap(api.PUT("/chats/{id}/commit-email", { params: { path: { id: v.id } }, body: { email: v.email } })),
    onSuccess: (chat) => qc.setQueryData(chatKeys.detail(chat.id), chat),
    onSettled: done,
  });
}

/** Deletes a chat and its messages. Its detail queries are dropped first so the open view doesn't refetch a 404. */
export function useDeleteChat() {
  const qc = useQueryClient();
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: async (id: string) => {
      const { error, response } = await api.DELETE("/chats/{id}", { params: { path: { id } } });
      if (error || !response.ok) throw error ?? new Error(`Delete failed (${response.status})`);
    },
    onSuccess: (_, id) => {
      qc.removeQueries({ queryKey: chatKeys.detail(id) });
      qc.removeQueries({ queryKey: chatKeys.messages(id) });
    },
    onSettled: done,
  });
}

/** Creates a chat and sends its first message, for asking from outside the chat screen. */
export function useAskChat() {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: async (v: { project: string; body: string }) => {
      const chat = await unwrap(api.POST("/chats", { body: { project: v.project } }));
      await unwrap(api.POST("/chats/{id}/messages", { params: { path: { id: chat.id } }, body: { body: v.body } }));
      return chat;
    },
    onSettled: done,
  });
}

/**
 * Context a screen adds to every message sent in a chat it hosts (the design
 * editor's selection and viewport), asked for at send time so it is current.
 */
const chatRefProviders = new Map<string, () => Schemas["ChatContextRef"][] | undefined>();
export function provideChatRefs(chatId: string, provider: () => Schemas["ChatContextRef"][] | undefined): () => void {
  chatRefProviders.set(chatId, provider);
  return () => {
    if (chatRefProviders.get(chatId) === provider) chatRefProviders.delete(chatId);
  };
}

export function useSendChatMessage(id: string, prepare?: (body: Schemas["NewChatMessage"]) => Promise<Schemas["NewChatMessage"]>) {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: async (input: Schemas["NewChatMessage"]) => {
      const body = prepare ? await prepare(input) : input;
      const extra = chatRefProviders.get(id)?.() ?? [];
      // A ref the caller attached for the same canvas wins.
      const refs = [...(body.context_refs ?? []), ...extra.filter((r) => !(body.context_refs ?? []).some((x) => x.kind === r.kind && x.id === r.id))];
      return unwrap(api.POST("/chats/{id}/messages", { params: { path: { id } }, body: refs.length ? { ...body, context_refs: refs } : body }));
    },
    onSettled: done,
  });
}

export function useCancelChat(id: string) {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: () => unwrap(api.POST("/chats/{id}/cancel", { params: { path: { id } } })),
    onSettled: done,
  });
}

// ---- Follow-ups and asides: sending while a reply runs, without interrupting it.
// Both live under ["chats"], so SSE chat.updated (the server bumps the chat) refreshes them.

const followupsKey = (id: string) => ["chats", "followups", id] as const;
const asidesKey = (id: string) => ["chats", "asides", id] as const;
const toolApprovalsKey = (id: string) => ["chats", "tool-approvals", id] as const;

/** Pending in-turn tool approvals for this chat; polled every 1.5s while open or running. */
export function useChatToolApprovals(id?: string, live = true) {
  return useQuery({
    enabled: !!id,
    queryKey: toolApprovalsKey(id ?? ""),
    queryFn: () => unwrap(api.GET("/chats/{id}/tool-approvals", { params: { path: { id: id! } } })),
    refetchInterval: live ? 1_500 : false,
  });
}

/** Steers an active chat turn mid-flight (or falls back cleanly when unsupported). */
export function useSteerChat(id: string, prepare?: (body: string) => Promise<string>) {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: async (body: string) => unwrap(api.POST("/chats/{id}/steer", { params: { path: { id } }, body: { body: prepare ? await prepare(body) : body } })),
    onSettled: done,
  });
}

/** Messages queued behind the running reply, next to send first. */
export function useChatFollowups(id?: string) {
  return useQuery({
    enabled: !!id,
    queryKey: followupsKey(id ?? ""),
    queryFn: () => unwrap(api.GET("/chats/{id}/followups", { params: { path: { id: id! } } })).then((d) => d.followups),
  });
}

export function useQueueFollowup(id: string, prepare?: (body: string) => Promise<string>) {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: async (body: string) => unwrap(api.POST("/chats/{id}/followups", { params: { path: { id } }, body: { body: prepare ? await prepare(body) : body } })),
    onSettled: done,
  });
}

export function useDeleteFollowup(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (followupId: string) => {
      const { error, response } = await api.DELETE("/chats/{id}/followups/{followupId}", { params: { path: { id, followupId } } });
      if (error || !response.ok) throw error ?? new Error(`Remove failed (${response.status})`);
    },
    onSettled: () => qc.invalidateQueries({ queryKey: followupsKey(id) }),
  });
}

/** The chat's asides (hidden chats of their own), oldest first; followed while one is answering. */
export function useChatAsides(id?: string) {
  return useQuery({
    enabled: !!id,
    queryKey: asidesKey(id ?? ""),
    queryFn: () => unwrap(api.GET("/chats/{id}/asides", { params: { path: { id: id! } } })).then((d) => d.asides),
    refetchInterval: (q) => (q.state.data?.some((a) => a.state === "running") ? CHAT_POLL_MS : false),
  });
}

export function useStartAside(id: string, prepare?: (body: string) => Promise<string>) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (body: string) => unwrap(api.POST("/chats/{id}/asides", { params: { path: { id } }, body: { body: prepare ? await prepare(body) : body } })),
    onSettled: () => qc.invalidateQueries({ queryKey: asidesKey(id) }),
  });
}

/** Starts a thread: an aside about one message of the chat, which can start at any time. */
export function useStartThread(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async ({ messageId, body }: { messageId: string; body: string }) =>
      unwrap(api.POST("/chats/{id}/asides", { params: { path: { id } }, body: { body, anchor_message_id: messageId } })),
    onSettled: () => qc.invalidateQueries({ queryKey: asidesKey(id) }),
  });
}

export type SecondOpinionRequest = Omit<Schemas["ChatAsideStart"], "body" | "second_opinion"> & { body?: string };

/** Starts a read-only cross-harness second opinion aside without touching the parent chat's harness, model, or prompt cache. */
export function useStartSecondOpinion(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (input: SecondOpinionRequest) =>
      unwrap(
        api.POST("/chats/{id}/asides", {
          params: { path: { id } },
          body: { ...input, body: input.body?.trim() ?? "", second_opinion: true },
        }),
      ),
    onSettled: () => qc.invalidateQueries({ queryKey: asidesKey(id) }),
  });
}

/** The current turn's tool calls/results, read from the segment run's events. */
export function useChatRunEvents(runId?: string, enabled = true, poll = true) {
  const qc = useQueryClient();
  const queryKey = ["runs", "chat", runId ?? ""] as const;
  return useQuery({
    enabled: !!runId && enabled,
    queryKey,
    // Each poll reads only what came after the newest event it has.
    queryFn: () =>
      eventsAfter(qc.getQueryData<Schemas["RunEvent"][]>(queryKey) ?? [], (after) =>
        unwrap(api.GET("/runs/{id}/events", { params: { path: { id: runId! }, query: { after } } })).then((d) => d.events),
      ),
    refetchInterval: poll ? 2_000 : false,
    staleTime: poll ? 0 : Infinity,
  });
}

/**
 * One finished turn's slice of a chat segment run's events, without polling.
 * Uses a windowed selector so completed turns keep a stable reference and skip
 * re-rendering while later turns append new events to the same segment run.
 */
export function useChatTurnEvents(runId?: string, since?: string, until?: string, enabled = true) {
  const qc = useQueryClient();
  const queryKey = ["runs", "chat", runId ?? ""] as const;
  const select = useMemo(() => createEventWindowSelector<Schemas["RunEvent"]>(since, until), [since, until]);
  return useQuery({
    enabled: !!runId && enabled,
    queryKey,
    queryFn: () =>
      eventsAfter(qc.getQueryData<Schemas["RunEvent"][]>(queryKey) ?? [], (after) =>
        unwrap(api.GET("/runs/{id}/events", { params: { path: { id: runId! }, query: { after } } })).then((d) => d.events),
      ),
    select,
    refetchInterval: false,
    staleTime: Infinity,
  });
}

/** A reply's recommendation cards. The server fetches each page once, so one load is enough. */
export function useLinkPreviews(messageId?: string) {
  return useQuery({
    enabled: !!messageId,
    queryKey: ["link-previews", messageId ?? ""] as const,
    queryFn: () => unwrap(api.GET("/chat-messages/{messageId}/link-previews", { params: { path: { messageId: messageId! } } })),
    staleTime: Infinity,
    retry: false,
  });
}

// ---- Assistant memory (LAZYAGENTS-71): the signed-in person's private memory store ----

type MemoryPatch = Schemas["MemoryPatch"];

export const memoryKeys = {
  all: ["memories"] as const,
  list: (q: string, type?: string, whose = "") => ["memories", "list", q, type ?? "", whose] as const,
  detail: (id: string) => ["memories", "detail", id] as const,
};

/** One entry. A forgotten (or someone else's) entry is a 404, not retried. */
export function useMemory(id?: string) {
  return useQuery({
    enabled: !!id,
    queryKey: memoryKeys.detail(id ?? ""),
    queryFn: () => unwrap(api.GET("/memories/{id}", { params: { path: { id: id! } } })),
    retry: (n, e) => !(e instanceof ApiError && e.status === 404) && n < 2,
  });
}

function useMemoryInvalidate() {
  const qc = useQueryClient();
  return () => qc.invalidateQueries({ queryKey: memoryKeys.all });
}

export function useUpdateMemory() {
  const done = useMemoryInvalidate();
  return useMutation({
    mutationFn: (v: { id: string; patch: MemoryPatch }) =>
      unwrap(api.PATCH("/memories/{id}", { params: { path: { id: v.id } }, body: v.patch })),
    onSettled: done,
  });
}

/** Forgets one entry. Already gone counts as done. */
export function useDeleteMemory() {
  const done = useMemoryInvalidate();
  return useMutation({
    mutationFn: async (id: string) => {
      const { error, response } = await api.DELETE("/memories/{id}", { params: { path: { id } } });
      if (response.ok || response.status === 404) return;
      const e = (error ?? {}) as Partial<Schemas["Error"]>;
      throw new ApiError(response.status, e.code ?? "internal", e.message ?? response.statusText, e.field);
    },
    onSettled: done,
  });
}

