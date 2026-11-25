"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import {
  api,
  ApiError,
  contentUrl,
  postForm,
  unwrap,
  type Artifact,
  type Schemas,
} from "./client";
import { personaKeys } from "./persona-hooks";

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

// Query keys. The shell SSE subscription invalidates these prefixes.
export const keys = {
  bootstrap: ["bootstrap"] as const,
  artifacts: ["artifacts"] as const,
  artifact: (id: string) => ["artifacts", "detail", id] as const,
};

export function useBootstrap() {
  return useQuery({
    queryKey: keys.bootstrap,
    queryFn: () => unwrap(api.GET("/bootstrap")),
    staleTime: 60_000,
    // Slow fallback while the SSE connection is unavailable.
    refetchInterval: 20_000,
  });
}

// ---------------------------------------------------------------- artifacts

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
      qc.invalidateQueries({ queryKey: ["inbox"] });
      qc.invalidateQueries({ queryKey: keys.bootstrap });
    },
  });
}

// ------------------------------------------------------------------- secrets & runner

export function useSecrets() {
  return useQuery({ queryKey: ["secrets"], queryFn: () => unwrap(api.GET("/secrets")), staleTime: 30_000, retry: 1 });
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

// ------------------------------------------------------------------- wiki & knowledge

const wikiKeys = {
  all: ["wiki"] as const,
  knowledge: ["knowledge"] as const,
};

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

export function useBacklinks(kind: Schemas["NodeKind"], id: string | undefined) {
  return useQuery({
    queryKey: [...wikiKeys.knowledge, "backlinks", kind, id] as const,
    queryFn: () => unwrap(api.GET("/knowledge/backlinks", { params: { query: { kind, id: id! } } })),
    enabled: !!id,
  });
}

export function useLinkMention() {
  const invalidate = useInvalidateWiki();
  return useMutation({
    mutationFn: async (body: { target_kind: Schemas["NodeKind"]; target_id: string; source_kind: "artifact" | "ticket"; source_id: string }) => {
      const { error, response } = await api.POST("/knowledge/link-mention", { body });
      if (error) await unwrap(Promise.resolve({ error, response }));
    },
    onSuccess: invalidate,
  });
}

// ------------------------------------------------------------- attention

export function useInbox(project?: string, enabled = true) {
  return useQuery({
    enabled,
    queryKey: ["inbox", project ?? ""],
    queryFn: () => unwrap(api.GET("/inbox", { params: { query: { project } } })).then((d) => d.items),
  });
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
  models: ["chats", "models"] as const,
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

/** limit above the usual 200 loads far enough back to reach a search hit. */
export function useChatMessages(id?: string, limit = 200) {
  return useQuery({
    enabled: !!id,
    queryKey: limit === 200 ? chatKeys.messages(id ?? "") : ([...chatKeys.messages(id ?? ""), limit] as const),
    queryFn: () => unwrap(api.GET("/chats/{id}/messages", { params: { path: { id: id! }, query: { limit } } })),
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

// ---- Assistant memory (LAZYAGENTS-71): the signed-in person's private memory store ----

export const memoryKeys = {
  all: ["memories"] as const,
};
