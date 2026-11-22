"use client";

import { useMutation, useQueries, useQuery, useQueryClient, keepPreviousData } from "@tanstack/react-query";
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
import { runEach } from "../ticket-list";
import { runEnded } from "../chat-dispatch";
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

type NewTicket = Schemas["NewTicket"];

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

export function useTickets(f: TicketFilters, enabled = true) {
  return useQuery({
    queryKey: keys.ticketList(f),
    queryFn: () => unwrap(api.GET("/tickets", { params: { query: f } })).then((d) => d.tickets),
    enabled,
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

export function useActivity(key: string, live = false) {
  return useQuery({
    queryKey: keys.activity(key),
    queryFn: () => unwrap(api.GET("/tickets/{key}/activity", { params: { path: { key } } })).then((d) => d.events),
    refetchInterval: live ? LIVE_POLL_MS : false,
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

/**
 * Revision-checked PATCH for the ticket page (ADR-034, same contract as the
 * edit modal). Each save sends the revision the person saw; saves on one
 * ticket run one after another, and a save queued behind this page's own
 * earlier save uses that save's new revision. A 409 rolls the optimistic edit
 * back and refetches the ticket so the latest is shown.
 */
export type RevisionPatch = { patch: TicketPatch; revision: number; what: string };

export function useRevisionCheckedUpdate(key: string, onFailed?: (e: Error, v: RevisionPatch) => void) {
  const qc = useQueryClient();
  return useMutation({
    scope: { id: `ticket-patch:${key}` },
    mutationFn: ({ patch, revision }: RevisionPatch) => {
      // Our own earlier save in this queue may have bumped it since the click.
      const rev = Math.max(revision, ownRevisions.get(key) ?? 0);
      return unwrap(api.PATCH("/tickets/{key}", { params: { path: { key } }, body: { ...patch, revision: rev } }));
    },
    onMutate: async ({ patch }) => {
      await qc.cancelQueries({ queryKey: keys.ticket(key) });
      const prev = qc.getQueryData<Ticket>(keys.ticket(key));
      if (prev) {
        const next = { ...prev };
        if (patch.title !== undefined) next.title = patch.title;
        if (patch.description_md !== undefined) next.description_md = patch.description_md;
        if (patch.status !== undefined) next.status = patch.status;
        if (patch.priority !== undefined) next.priority = patch.priority;
        if (patch.requires_mockup !== undefined) next.requires_mockup = patch.requires_mockup;
        if (patch.estimate_points !== undefined) next.estimate_points = patch.estimate_points ?? undefined;
        qc.setQueryData(keys.ticket(key), next);
      }
      return { prev };
    },
    // Hook-level, not per-mutate: queued saves each report their own failure.
    onError: (e, v, ctx) => {
      // A queued save snapshots `prev` when mutate() is called, possibly before an
      // earlier save landed, so always refetch after rolling back.
      if (ctx?.prev) qc.setQueryData(keys.ticket(key), ctx.prev);
      void qc.invalidateQueries({ queryKey: keys.ticket(key) });
      onFailed?.(e, v);
    },
    onSuccess: (t) => {
      ownRevisions.set(key, t.revision);
      qc.setQueryData(keys.ticket(key), t);
    },
    onSettled: () => {
      void qc.invalidateQueries({ queryKey: keys.tickets, predicate: (q) => q.queryKey[1] !== "detail" });
      void qc.invalidateQueries({ queryKey: ["boards"] });
      void qc.invalidateQueries({ queryKey: ["knowledge"] });
    },
  });
}

/** The revision each ticket reached through this tab's own last save. */
const ownRevisions = new Map<string, number>();

/** Every run on a ticket, delegated runs included, newest first. */
export function useTicketRuns(key: string, live = false) {
  return useQuery({
    queryKey: ["runs", "ticket", key],
    queryFn: () => unwrap(api.GET("/runs", { params: { query: { ticket: key, state: "all" } } })),
    refetchInterval: live ? LIVE_POLL_MS : false,
  });
}

export function useBulkUpdate() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { keys: string[]; patch: TicketPatch; attach_artifact_id?: string }) =>
      unwrap(api.POST("/tickets/bulk", { body })),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: keys.tickets });
      qc.invalidateQueries({ queryKey: keys.artifacts });
    },
  });
}

/**
 * Patch each ticket on its own (PATCH /tickets/{key}), so one refusal (a 409
 * for canceling a ticket with a live run) doesn't undo the others.
 */
export function useBulkEach() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ keys: ks, patch }: { keys: string[]; patch: TicketPatch }) =>
      runEach(ks, (key) => unwrap(api.PATCH("/tickets/{key}", { params: { path: { key } }, body: patch }))),
    onSettled: (_r, _e, v) => {
      qc.invalidateQueries({ queryKey: ["tickets", "list"] });
      for (const k of v.keys) qc.invalidateQueries({ queryKey: keys.ticket(k) });
      qc.invalidateQueries({ queryKey: ["boards"] });
      qc.invalidateQueries({ queryKey: ["epics"] });
    },
  });
}

export type SavedView = Schemas["SavedView"];
const savedViewsKey = ["saved-views"] as const;

/** The signed-in person's saved ticket-list views. */
export function useSavedViews() {
  return useQuery({
    queryKey: savedViewsKey,
    queryFn: () => unwrap(api.GET("/saved-views")).then((d) => d.views),
    staleTime: 60_000,
  });
}

export function useCreateSavedView() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: Schemas["SavedViewInput"]) => unwrap(api.POST("/saved-views", { body })),
    onSettled: () => qc.invalidateQueries({ queryKey: savedViewsKey }),
  });
}

export function useUpdateSavedView() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, ...body }: Schemas["SavedViewPatch"] & { id: string }) =>
      unwrap(api.PATCH("/saved-views/{id}", { params: { path: { id } }, body })),
    onSettled: () => qc.invalidateQueries({ queryKey: savedViewsKey }),
  });
}

export function useDeleteSavedView() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const r = await api.DELETE("/saved-views/{id}", { params: { path: { id } } });
      if (!r.response.ok) throw new Error("Couldn't delete the view");
    },
    onSettled: () => qc.invalidateQueries({ queryKey: savedViewsKey }),
  });
}

export function useCreateTicket() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: NewTicket) => unwrap(api.POST("/tickets", { body })),
    onSuccess: (t) => {
      qc.setQueryData(keys.ticket(t.key), t);
      qc.invalidateQueries({ queryKey: ["tickets", "list"] });
    },
  });
}

function useTicketChildMutation<V>(key: string, fn: (v: V) => Promise<unknown>) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSettled: () => {
      qc.invalidateQueries({ queryKey: keys.ticket(key) });
      qc.invalidateQueries({ queryKey: keys.activity(key) });
      qc.invalidateQueries({ queryKey: ["tickets", "list"] });
      qc.invalidateQueries({ queryKey: ["knowledge"] }); // comments can carry [[links]]
    },
  });
}

export function useAddCriterion(key: string) {
  return useTicketChildMutation(key, (text: string) =>
    unwrap(api.POST("/tickets/{key}/criteria", { params: { path: { key } }, body: { text } })),
  );
}

export function useUpdateCriterion(key: string) {
  const qc = useQueryClient();
  const m = useTicketChildMutation(key, (v: { id: string; done?: boolean; text?: string }) =>
    unwrap(api.PATCH("/criteria/{id}", { params: { path: { id: v.id } }, body: { done: v.done, text: v.text } })),
  );
  return {
    ...m,
    mutate: (v: { id: string; done?: boolean; text?: string }) => {
      // Tick instantly; the server response reconciles. Cancel an in-flight
      // refetch (e.g. after adding a criterion) so it can't overwrite the tick.
      void qc.cancelQueries({ queryKey: keys.ticket(key) });
      const prev = qc.getQueryData<Ticket>(keys.ticket(key));
      if (prev) {
        qc.setQueryData(keys.ticket(key), {
          ...prev,
          criteria: prev.criteria.map((c) => (c.id === v.id ? { ...c, ...(v.done !== undefined && { done: v.done }), ...(v.text !== undefined && { text: v.text }) } : c)),
        });
      }
      m.mutate(v);
    },
  };
}

export function useDeleteCriterion(key: string) {
  return useTicketChildMutation(key, (id: string) =>
    api.DELETE("/criteria/{id}", { params: { path: { id } } }).then((r) => {
      if (!r.response.ok) throw new Error("delete failed");
    }),
  );
}

export function useComment(key: string) {
  return useTicketChildMutation(key, (v: { body_md: string; parent_comment_id?: string }) =>
    unwrap(api.POST("/tickets/{key}/comments", { params: { path: { key } }, body: v })),
  );
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

function useTicketArtifactMutation<V>(key: string, fn: (v: V) => Promise<Ticket>) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: (t) => qc.setQueryData(keys.ticket(key), t),
    onSettled: () => {
      qc.invalidateQueries({ queryKey: keys.activity(key) });
      qc.invalidateQueries({ queryKey: keys.artifacts });
    },
  });
}

export function useAttachArtifact(key: string) {
  return useTicketArtifactMutation(key, (artifactId: string) =>
    unwrap(api.POST("/tickets/{key}/artifacts", { params: { path: { key } }, body: { artifact_id: artifactId } })),
  );
}

export function useDetachArtifact(key: string) {
  return useTicketArtifactMutation(key, (artifactId: string) =>
    unwrap(api.DELETE("/tickets/{key}/artifacts/{artifactId}", { params: { path: { key, artifactId } } })),
  );
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

/** The Welcome Wizard's Verify: stores a pasted credential as the harness key (when sent) and lists its models. */
export function useVerifyHarness() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (v: { harness: Schemas["Harness"]; body?: Schemas["HarnessVerifyRequest"] }) =>
      unwrap(api.POST("/harness/{harness}/verify", { params: { path: { harness: v.harness } }, ...(v.body ? { body: v.body } : {}) })),
    // The credential is in the variables: don't keep it in the mutation cache.
    gcTime: 0,
    // harness_connected (bootstrap me) may have changed too.
    onSettled: (_d, _e, v) =>
      Promise.all([v.body ? invalidateSecretDependents(qc) : qc.invalidateQueries({ queryKey: chatKeys.models }), qc.invalidateQueries({ queryKey: ["bootstrap"] })]),
  });
}

/**
 * A secret change can make harnesses available or unavailable: refresh the
 * secrets list (and the sidebar dot), chat model availability and dispatch
 * previews, which list the secrets a run would receive. GitHub changes also
 * refresh account presets and repository discovery.
 */
function invalidateSecretDependents(qc: ReturnType<typeof useQueryClient>) {
  return Promise.all([
    qc.invalidateQueries({ queryKey: ["secrets"] }),
    qc.invalidateQueries({ queryKey: ["repository-presets"] }),
    qc.invalidateQueries({ queryKey: ["repositories"] }),
    qc.invalidateQueries({ queryKey: chatKeys.models }),
    qc.invalidateQueries({ queryKey: ["tickets", "dispatch"] }),
  ]);
}

export function useSetSecret() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { name: string; value: string; grants_scope?: string; project_key?: string }) => unwrap(api.PUT("/secrets", { body })),
    onSettled: () => invalidateSecretDependents(qc),
    // The variables hold the plaintext value: don't keep them in the mutation cache.
    gcTime: 0,
  });
}

export function useDeleteSecret() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (id: string) => {
      const r = await api.DELETE("/secrets/{id}", { params: { path: { id } } });
      if (!r.response.ok) throw new Error("Couldn't delete the secret");
    },
    onSettled: () => invalidateSecretDependents(qc),
  });
}

export function useBackupEncryption() {
  return useQuery({
    queryKey: ["backup-encryption"],
    queryFn: () => unwrap(api.GET("/instance/backup-encryption")),
    staleTime: 30_000,
    retry: 1,
  });
}

export function useSetBackupEncryption() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (password: string) => unwrap(api.PUT("/instance/backup-encryption", { body: { password } })),
    onSettled: () => qc.invalidateQueries({ queryKey: ["backup-encryption"] }),
    // Never retain the plaintext backup password in the mutation cache.
    gcTime: 0,
  });
}

export function useClearBackupEncryption() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async () => {
      const r = await api.DELETE("/instance/backup-encryption");
      if (!r.response.ok) throw new Error("Couldn't turn off backup encryption");
    },
    onSettled: () => qc.invalidateQueries({ queryKey: ["backup-encryption"] }),
  });
}

/** A provider sign-in from Settings. Polls while the runner is driving it. */
export function useSignIn(id: string | null) {
  const qc = useQueryClient();
  return useQuery({
    queryKey: ["sign-ins", id],
    enabled: !!id,
    queryFn: async () => {
      const s = await unwrap(api.GET("/sign-ins/{id}", { params: { path: { id: id! } } }));
      if (s.status === "done") await invalidateSecretDependents(qc);
      return s;
    },
    refetchInterval: (q) => (q.state.data && ["done", "failed", "cancelled"].includes(q.state.data.status) ? false : 1500),
    retry: 1,
  });
}

export function useStartSignIn() {
  return useMutation({
    mutationFn: (provider: Schemas["SignInProvider"]) => unwrap(api.POST("/sign-ins", { body: { provider } })),
  });
}

export function useSubmitSignInCode() {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: ({ id, code }: { id: string; code: string }) => unwrap(api.POST("/sign-ins/{id}/code", { params: { path: { id } }, body: { code } })),
    onSuccess: (s) => qc.setQueryData(["sign-ins", s.id], s),
    // The variables hold the code: don't keep them in the mutation cache.
    gcTime: 0,
  });
}

export function useCancelSignIn() {
  return useMutation({
    mutationFn: async (id: string) => {
      const r = await api.DELETE("/sign-ins/{id}", { params: { path: { id } } });
      if (!r.response.ok) throw new Error("Couldn't cancel the sign-in");
    },
  });
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

export function useAddressTicketPRFeedback(key: string) {
  const qc = useQueryClient();
  const refresh = useTicketRefresh(key);
  return useMutation({
    mutationFn: (mode: Schemas["AddressPRFeedbackRequest"]["mode"]) =>
      unwrap(api.POST("/tickets/{key}/address-pr-feedback", { params: { path: { key } }, body: { mode } })),
    onSettled: () => {
      refresh();
      void qc.invalidateQueries({ queryKey: keys.tickets });
    },
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

const RUN_DONE = ["completed", "failed", "cancelled"];

/**
 * A run with its turns and events. SSE invalidates this query; polling is a
 * fallback. Events are fetched incrementally with ?after=seq.
 */
function runLogOptions(qc: ReturnType<typeof useQueryClient>, id: string, enabled = true) {
  return {
    enabled: enabled && !!id,
    queryKey: ["runs", id] as const,
    queryFn: async () => {
      const prev = qc.getQueryData<Schemas["RunDetail"]>(["runs", id]);
      const after = prev?.events.at(-1)?.seq ?? 0;
      const d = await unwrap(api.GET("/runs/{id}", { params: { path: { id }, query: { after } } }));
      return prev ? { ...d, events: [...prev.events, ...d.events] } : d;
    },
    refetchInterval: (q: { state: { data?: Schemas["RunDetail"] } }) =>
      q.state.data && RUN_DONE.includes(q.state.data.run.state) ? false as const : 2_000,
  };
}

export function useRunLog(id: string, enabled = true) {
  const qc = useQueryClient();
  return useQuery(runLogOptions(qc, id, enabled));
}

/** Each delegated run has its own event cursor and live query. */
export function useDelegatedRunLogs(runs: Schemas["Run"][]) {
  const qc = useQueryClient();
  return useQueries({ queries: runs.map((run) => runLogOptions(qc, run.id)) });
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

/** Decide an approval from the run page; works for runs without a ticket. */
export function useDecideRunApproval(runId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: async (v: { id: string; decision: "approve" | "deny"; note?: string }) => {
      if (v.decision === "approve") await confirmApprovalLocally("run_approvals");
      return unwrap(api.POST("/approvals/{id}/{decision}", { params: { path: { id: v.id, decision: v.decision } }, body: { note: v.note } }));
    },
    onSettled: () => {
      qc.invalidateQueries({ queryKey: ["runs", runId] });
      qc.invalidateQueries({ queryKey: ["inbox"] });
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

/** Top-level runs, newest first, one query per loaded page. Under ["runs"] so SSE invalidation refreshes them. */
export function useRunPages(f: RunListFilters, pages: number) {
  return useQueries({ queries: Array.from({ length: pages }, (_, i) => runListOptions(f, i * RUNS_PAGE)) });
}

export const RUNS_PAGE = 50;

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

/** Private persona routing samples, refreshed while chats work. */
export function useHighlights(q: { from: string; to: string; project?: string }, enabled = true) {
  return useQuery({
    queryKey: ["chats", "highlights", q] as const,
    queryFn: () => unwrap(api.GET("/highlights", { params: { query: q } })),
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

export function useSaveWikiPage(id: string) {
  const invalidate = useInvalidateWiki();
  return useMutation({
    mutationFn: (body: Schemas["WikiPageSave"]) => unwrap(api.PUT("/wiki/pages/{id}", { params: { path: { id } }, body })),
    onSuccess: invalidate,
  });
}

export function useWikiSuggestions(artifactId?: string) {
  return useQuery({
    queryKey: wikiKeys.suggestions(artifactId),
    queryFn: () =>
      unwrap(api.GET("/wiki/suggestions", { params: { query: artifactId ? { artifact_id: artifactId } : {} } })).then((d) => d.suggestions),
  });
}

export function useDecideSuggestion() {
  const invalidate = useInvalidateWiki();
  return useMutation({
    mutationFn: async ({ id, decision }: { id: string; decision: "accept" | "reject" }) => {
      const { error, response } = await api.POST("/wiki/suggestions/{versionId}/{decision}", { params: { path: { versionId: id, decision } } });
      if (error) await unwrap(Promise.resolve({ error, response }));
    },
    onSuccess: invalidate,
  });
}

export function useImportWiki() {
  const invalidate = useInvalidateWiki();
  return useMutation({
    mutationFn: (file: File) => {
      const f = new FormData();
      f.append("file", file);
      return postForm<Schemas["WikiImportResult"]>("/wiki/import", f);
    },
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

export function useGraph(kind: Schemas["NodeKind"], id: string | undefined, depth = 2) {
  return useQuery({
    queryKey: [...wikiKeys.knowledge, "graph", kind, id, depth] as const,
    queryFn: () => unwrap(api.GET("/knowledge/graph", { params: { query: { kind, id: id!, depth } } })),
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

export function useKnowledgeSearch(q: string) {
  return useQuery({
    queryKey: [...wikiKeys.knowledge, "search", q] as const,
    queryFn: () => unwrap(api.GET("/knowledge/search", { params: { query: { q } } })).then((d) => d.hits),
    enabled: q.trim().length > 1,
    placeholderData: (prev) => prev,
  });
}

export const PATTERN_TOPICS = ["Go", "React", "Postgres", "Testing", "API", "Architecture", "Process"] as const;

/**
 * Fuzzy pattern finder; an empty q browses every pattern. tags filters to
 * patterns with all of them; the response's tag facet ignores that filter.
 */
export function useFindPatterns(q: string, topic?: string, tags: string[] = []) {
  return useQuery({
    queryKey: [...wikiKeys.all, "patterns", q, topic ?? "", tags.join(",")] as const,
    queryFn: () =>
      unwrap(
        api.GET("/wiki/patterns", {
          params: { query: { q: q || undefined, topic: topic || undefined, tag: tags.length ? tags : undefined, limit: 50 } },
        }),
      ),
    placeholderData: (prev) => prev,
  });
}

/** The ADR index: status and open questions parsed from each ADR. */
export function useWikiADRs() {
  return useQuery({
    queryKey: [...wikiKeys.all, "adrs"] as const,
    queryFn: () => unwrap(api.GET("/wiki/adrs")).then((d) => d.adrs),
  });
}

/** Runs and chats that read a page. */
export function useWikiCitations(id: string | undefined) {
  return useQuery({
    queryKey: [...wikiKeys.all, "citations", id] as const,
    queryFn: () => unwrap(api.GET("/wiki/pages/{id}/citations", { params: { path: { id: id! } } })),
    enabled: !!id,
  });
}

/** Raw text of one version (for diffs). Versions never change, so it's cached for good. */
export function useVersionText(artifactId: string | undefined, versionId: string | undefined) {
  return useQuery({
    queryKey: ["artifact-version-text", artifactId, versionId] as const,
    queryFn: async () => {
      const res = await fetch(contentUrl(artifactId!, versionId!));
      if (!res.ok) throw new ApiError(res.status, "internal", res.statusText);
      return res.text();
    },
    enabled: !!artifactId && !!versionId,
    staleTime: Infinity,
  });
}

// ------------------------------------------------------------- attention
export function useInbox(project?: string, enabled = true) {
  return useQuery({enabled,queryKey:["inbox",project??""],queryFn:()=>unwrap(api.GET("/inbox",{params:{query:{project}}})).then(d=>d.items)});
}
export function useReadInbox() {
 const qc=useQueryClient();
 return useMutation({mutationFn:async(id:string)=>{
  const r=await api.POST("/inbox/read",{body:{id}});
  if(!r.response.ok)throw new Error("Couldn't mark item read");
 },onSuccess:()=>{void qc.invalidateQueries({queryKey:["inbox"]});void qc.invalidateQueries({queryKey:keys.bootstrap});}});
}
/** ⌘K search: hits capped per type, with how many of each matched; kind lists one type in full. */
export function useSearch(q:string,project?:string,kind?:Schemas["SearchType"],enabled=true) {
 return useQuery({queryKey:["search",q,project??"",kind??""],queryFn:()=>unwrap(api.GET("/search",{params:{query:{q,project,kind}}})),enabled:enabled&&q.trim().length>0,placeholderData:keepPreviousData});
}

// ------------------------------------------------------------- overviews
export function useEpicOverviews(enabled = true) {
 return useQuery({enabled,queryKey:["epics"],queryFn:()=>unwrap(api.GET("/epics")).then(d=>d.epics)});
}
/** Toggle an epic's "requires mockup" flag or change its status (done is gated server-side: 409). */
export function useUpdateEpic(id: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: (body: { requires_mockup?: boolean; status?: Schemas["EpicStatus"] }) => unwrap(api.PATCH("/epics/{id}", { params: { path: { id } }, body })),
    onSettled: () => invalidateEpic(qc),
  });
}

/** Add the epic's final review ticket (idempotent; 409 when the epic is done or the project archived). */
export function useCreateEpicReview(epicId: string) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: () => unwrap(api.POST("/epics/{id}/review", { params: { path: { id: epicId } } })),
    onSettled: () => invalidateEpic(qc),
  });
}

function invalidateEpic(qc: ReturnType<typeof useQueryClient>) {
  return Promise.all([
    qc.invalidateQueries({ queryKey: keys.bootstrap }),
    qc.invalidateQueries({ queryKey: ["epics"] }),
    qc.invalidateQueries({ queryKey: ["boards"] }),
    qc.invalidateQueries({ queryKey: keys.tickets }),
  ]);
}

/** Epic final acceptance criteria. Callers render server data; every write refetches. */
export function useEpicCriterionMutations(epicId: string) {
  const qc = useQueryClient();
  const settle = { onSettled: () => invalidateEpic(qc) };
  return {
    create: useMutation({
      mutationFn: (text: string) => unwrap(api.POST("/epics/{id}/criteria", { params: { path: { id: epicId } }, body: { text } })),
      ...settle,
    }),
    update: useMutation({
      mutationFn: ({ id, ...body }: { id: string; text?: string; done?: boolean; position?: number }) =>
        unwrap(api.PATCH("/epic-criteria/{id}", { params: { path: { id } }, body })),
      ...settle,
    }),
    remove: useMutation({
      mutationFn: async (id: string) => {
        const { error, response } = await api.DELETE("/epic-criteria/{id}", { params: { path: { id } } });
        if (!response.ok) {
          const e = (error ?? {}) as Partial<Schemas["Error"]>;
          throw new ApiError(response.status, e.code ?? "internal", e.message ?? response.statusText, e.field);
        }
      },
      ...settle,
    }),
  };
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
export type MemoryType = Schemas["MemoryType"];

export const memoryKeys = {
  all: ["memories"] as const,
  list: (q: string, type?: string, whose = "") => ["memories", "list", q, type ?? "", whose] as const,
  detail: (id: string) => ["memories", "detail", id] as const,
};

/**
 * First 50 matches (ranked when q is set); `total` counts every entry of the type.
 * whose: "" for everything, "person" for what the assistant remembers about the
 * person, "persona" for every persona's own memory, one persona's id, or "space:<id>" for one space's.
 */
export function useMemories(q = "", type?: MemoryType, offset = 0, whose = "") {
  // whose may also be "space:<id>": one space's memory.
  const scope: { about?: Schemas["MemoryAbout"]; persona_id?: string; space_id?: string } =
    whose === "person" || whose === "persona" ? { about: whose } : whose.startsWith("space:") ? { space_id: whose.slice(6) } : whose ? { persona_id: whose } : {};
  return useQuery({
    queryKey: [...memoryKeys.list(q, type, whose), offset] as const,
    queryFn: () =>
      unwrap(
        api.GET("/memories", { params: { query: { ...(q ? { q } : {}), ...(type ? { type } : {}), ...(offset ? { offset } : {}), ...scope } } }),
      ),
  });
}

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

export function useDeleteAllMemories() {
  const done = useMemoryInvalidate();
  return useMutation({
    mutationFn: () => unwrap(api.DELETE("/memories", { params: { query: { confirm: true } } })),
    onSettled: done,
  });
}

/** Adds many entries at once; near-duplicates of existing ones update them. */
export function useImportMemories() {
  const done = useMemoryInvalidate();
  return useMutation({
    mutationFn: (body: Schemas["MemoryImport"]) => unwrap(api.POST("/memories/import", { body })),
    onSuccess: done,
  });
}

export function exportMemories() {
  return unwrap(api.GET("/memories/export"));
}

/** The first message of a new conversation: create the chat, then send into it. */
export function useStartChat() {
  const done = useChatInvalidate();
  return useMutation({
    mutationFn: async (v: { project?: string; persona_id?: string; temporary?: boolean; repo_url?: string; commit_email?: string; message: Schemas["NewChatMessage"] }) => {
      const chat = await unwrap(
        api.POST("/chats", {
          body: {
            project: v.project,
            ...(v.persona_id ? { persona_id: v.persona_id } : {}),
            ...(v.temporary ? { temporary: true } : {}),
            ...(v.repo_url ? { repo_url: v.repo_url } : {}),
            ...(v.commit_email ? { commit_email: v.commit_email } : {}),
          },
        }),
      );
      await unwrap(api.POST("/chats/{id}/messages", { params: { path: { id: chat.id } }, body: v.message }));
      return chat;
    },
    onSettled: done,
  });
}

