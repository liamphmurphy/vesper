"use client";

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query";
import { ApiError, SIGN_IN_PAGE, api, unwrap } from "./client";
import type { PageKind } from "@/lib/knowledge";

// ---- Knowledge: pages (Docs and the wiki in one store), reviews, capture,
// daily notes, saved queries, the vault graph and Obsidian imports. These
// routes are mounted by hand on the server (api/knowledge.openapi.yaml), so
// they aren't in the generated client.
//
// Every key starts with "knowledge": the live-update stream invalidates that
// prefix whenever an artifact or link changes.

export type Audience = "private" | "shared" | "agent";
export type Properties = Record<string, unknown>;

export type PageRow = {
  id: string;
  title: string;
  path: string;
  audience: Audience;
  summary: string;
  properties: Properties;
  updated_at: string;
  version_id: string | null;
  pending: number;
  unresolved: number;
  kind?: PageKind;
  canvas_id?: string | null;
};
export type PageTable = { columns: string[]; rows: PageRow[]; has_more: boolean };

export type PageQuery = {
  text?: string;
  folder?: string;
  tag?: string;
  audience?: Audience;
  properties?: Properties;
  after?: string;
  before?: string;
  links_to?: string;
  orphans?: boolean;
  unresolved?: boolean;
  include_agent?: boolean;
  limit?: number;
  offset?: number;
};

export type Embed = {
  ref: string;
  kind: "page" | "file" | "image" | "video" | "design" | "unresolved";
  title?: string;
  markdown?: string;
  url?: string;
  content_type?: string;
  available: boolean;
};

export type PageChange = {
  kind?: string;
  before?: string;
  after?: string;
  why?: string;
  state?: string;
  key?: string;
  [k: string]: unknown;
};

export type Review = { id: string; state: string; review_state: string | null; changes: PageChange[] | null; author_id: string; created_at: string };
export type Version = { id: string; seq: number; label: string; note: string; author_type: "user" | "agent"; author_id: string; created_at: string };

export type Page = {
  id: string;
  title: string;
  path: string | null;
  audience: Audience;
  /** A deck or design page's body is its canvas (canvas_id), edited in its editor. */
  kind?: PageKind;
  canvas_id?: string | null;
  body_md: string | null;
  version_id: string;
  seq: number;
  properties: Properties;
  direct: boolean;
  paused: boolean;
  chat_id: string | null;
  url: string;
  embeds: Embed[];
  reviews: Review[];
  versions: Version[];
};

export type PageInput = {
  title?: string;
  path?: string;
  body_md?: string;
  properties?: Properties;
  audience?: "private" | "shared";
  base_version_id?: string;
  note?: string;
  template?: string;
};

export type ReviewDecision = { index: number; accept: boolean; reason?: string };

export type Network = {
  nodes: { id: string; title: string; path: string; audience: Audience }[];
  links: { source: string; target?: string; unresolved?: string }[];
};

export type VaultEntry = {
  source: string;
  path: string;
  kind: string;
  title?: string;
  renamed?: boolean;
  conflict?: boolean;
  duplicate?: boolean;
  original_title?: string;
  existing_id?: string;
  tags?: string[];
  daily?: boolean;
  error?: string;
  unsupported?: boolean;
};
export type ImportResult = { source: string; status: "created" | "updated" | "unchanged" | "skipped" | "failed" | "conflict" | string; reason: string };
export type VaultPlan = {
  entries: VaultEntry[];
  notes: number;
  attachments: number;
  resolved: number;
  unresolved: string[] | null;
  folders: string[] | null;
  tags: string[] | null;
};
export type ImportState = "queued" | "scanning" | "preview" | "queued_commit" | "importing" | "done" | "failed" | "undone";
export type ImportJob = {
  id: string;
  state: ImportState;
  folder: string;
  policy: "skip" | "replace" | "keep_both" | null;
  plan: VaultPlan | null;
  report: ImportResult[] | null;
  files_done: number;
  error: string | null;
  created_at: string;
  updated_at: string;
};

const BASE = "/api/v1/knowledge";

async function call<T>(method: string, path: string, body?: unknown, init?: RequestInit): Promise<T> {
  const raw = body instanceof Blob || body instanceof File;
  const res = await fetch(BASE + path, {
    method,
    headers: body === undefined || raw ? init?.headers : { "Content-Type": "application/json", ...init?.headers },
    body: body === undefined ? undefined : raw ? (body as BodyInit) : JSON.stringify(body),
    ...init,
  });
  if (res.status === 401 && typeof window !== "undefined" && window.location.pathname !== SIGN_IN_PAGE) window.location.assign(SIGN_IN_PAGE);
  const text = await res.text();
  const data = text ? JSON.parse(text) : undefined;
  if (!res.ok) throw new ApiError(res.status, data?.code ?? "internal", data?.message ?? res.statusText, data?.field);
  return data as T;
}

/** The query string for a GET, dropping empty values. */
function qs(q: Record<string, unknown>): string {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries(q)) if (v !== undefined && v !== "" && v !== false) p.set(k, String(v));
  const s = p.toString();
  return s ? `?${s}` : "";
}

export const knowledgeKeys = {
  all: ["knowledge"] as const,
  pages: (q: PageQuery) => ["knowledge", "pages", q] as const,
  page: (id: string) => ["knowledge", "page", id] as const,
  query: (id: string) => ["knowledge", "saved-query", id] as const,
  network: (agent: boolean) => ["knowledge", "network", agent] as const,
  templates: ["knowledge", "templates"] as const,
  imports: ["knowledge", "imports"] as const,
  import: (id: string) => ["knowledge", "import", id] as const,
  tree: (agent: boolean) => ["knowledge", "tree", agent] as const,
};

export const fetchPages = (q: PageQuery) => call<PageTable>("POST", "/query", q);
export const fetchPage = (id: string) => call<Page>("GET", `/pages/${id}`);
export const resolveLegacy = (path: string) => call<{ id: string; url: string }>("GET", `/legacy${qs({ path })}`);

/** Pages matching a filter, newest first. */
export function usePages(q: PageQuery, enabled = true) {
  return useQuery({ queryKey: knowledgeKeys.pages(q), queryFn: () => fetchPages(q), enabled });
}

/**
 * Every page the explorer shows: the API pages 200 rows at a time, so this
 * follows has_more until it has them all (a vault of a few thousand pages is
 * a handful of requests).
 */
export function useAllPages(includeAgent: boolean) {
  return useQuery({
    queryKey: knowledgeKeys.tree(includeAgent),
    queryFn: async () => {
      const rows: PageRow[] = [];
      for (let offset = 0; ; offset += 200) {
        const t = await fetchPages({ include_agent: includeAgent, audience: includeAgent ? "agent" : undefined, limit: 200, offset });
        rows.push(...t.rows);
        if (!t.has_more || offset > 20000) return rows;
      }
    },
  });
}

export function usePage(id: string | undefined) {
  return useQuery({ queryKey: knowledgeKeys.page(id ?? ""), queryFn: () => fetchPage(id!), enabled: !!id });
}

/** The rows of the saved query a page holds in its `query` property. */
export function useSavedQuery(id: string | undefined, enabled: boolean) {
  return useQuery({ queryKey: knowledgeKeys.query(id ?? ""), queryFn: () => call<PageTable>("GET", `/pages/${id}/query`), enabled: !!id && enabled });
}

export function useNetwork(includeAgent: boolean) {
  return useQuery({ queryKey: knowledgeKeys.network(includeAgent), queryFn: () => call<Network>("GET", `/network${qs({ include_agent: includeAgent })}`) });
}

export function useTemplates() {
  return useQuery({ queryKey: knowledgeKeys.templates, queryFn: () => call<{ templates: Record<string, string> }>("GET", "/templates").then((d) => d.templates), staleTime: Infinity });
}

/** Writes that return the page: the result seeds the page's cache and everything else refreshes. */
function usePageWrite<V>(fn: (v: V) => Promise<Page>) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: (p) => {
      qc.setQueryData(knowledgeKeys.page(p.id), p);
      void qc.invalidateQueries({ queryKey: knowledgeKeys.all, predicate: (q) => q.queryKey[1] !== "page" || q.queryKey[2] !== p.id });
    },
  });
}

export const useCreatePage = () => usePageWrite((v: PageInput) => call<Page>("POST", "/pages", v));
export const useSavePage = (id: string) => usePageWrite((v: PageInput) => call<Page>("PUT", `/pages/${id}`, v));
export const useCapture = () => usePageWrite((v: PageInput) => call<Page>("POST", "/capture", v));
export const useDaily = () => usePageWrite((v: { date?: string; folder?: string; template?: string }) => call<Page>("POST", "/daily", v));
export const usePageControls = (id: string) => usePageWrite((v: { direct: boolean; paused: boolean }) => call<Page>("PUT", `/pages/${id}/controls`, v));
export const useResolveReview = (id: string) =>
  usePageWrite((v: { version: string; decisions: ReviewDecision[] }) => call<Page>("POST", `/pages/${id}/reviews/${v.version}/resolve`, { decisions: v.decisions }));
export const useRestore = (id: string) => usePageWrite((version: string) => call<Page>("POST", `/pages/${id}/restore/${version}`));
export const useFileCapture = (id: string) => usePageWrite((v: { folder?: string; merge?: string }) => call<Page>("POST", `/pages/${id}/file`, v));
export const useMoveCanvas = () => usePageWrite((v: { chat_id: string; canvas_id: string; folder?: string }) => call<Page>("POST", "/pages/from-canvas", v));

// ---- Explorer: rename or move a page, delete one, and move or delete a folder
// (every page under a path prefix, in one view).

/** Renames or moves a page by its path; the body is left as it is. */
export const useMovePage = () => usePageWrite((v: { id: string; title?: string; path: string }) => call<Page>("PUT", `/pages/${v.id}`, { title: v.title, path: v.path }));

function useTreeWrite<V, R extends { deleted?: string[]; moved?: string[] }>(fn: (v: V) => Promise<R>) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: (r) => {
      for (const id of r.deleted ?? []) qc.removeQueries({ queryKey: knowledgeKeys.page(id) });
      void qc.invalidateQueries({ queryKey: knowledgeKeys.all });
    },
  });
}

export const useDeletePage = () => useTreeWrite((id: string) => call<{ deleted: string[] }>("DELETE", `/pages/${id}`));
export const useMoveFolder = () => useTreeWrite((v: { from: string; to: string; agent: boolean }) => call<{ moved: string[] }>("POST", "/folders/move", v));
export const useDeleteFolder = () => useTreeWrite((v: { folder: string; agent: boolean }) => call<{ deleted: string[] }>("POST", "/folders/delete", v));

// ---- Obsidian vault imports

export function useImports() {
  return useQuery({ queryKey: knowledgeKeys.imports, queryFn: () => call<{ imports: ImportJob[] }>("GET", "/imports").then((d) => d.imports) });
}

/** One import, polled while the server is working on it. */
export function useImport(id: string | undefined) {
  return useQuery({
    queryKey: knowledgeKeys.import(id ?? ""),
    queryFn: () => call<ImportJob>("GET", `/imports/${id}`),
    enabled: !!id,
    refetchInterval: (q) => (q.state.data && ["queued", "scanning", "queued_commit", "importing"].includes(q.state.data.state) ? 1000 : false),
  });
}

function useImportWrite<V>(fn: (v: V) => Promise<ImportJob>) {
  const qc = useQueryClient();
  return useMutation({
    mutationFn: fn,
    onSuccess: (j) => {
      qc.setQueryData(knowledgeKeys.import(j.id), j);
      void qc.invalidateQueries({ queryKey: knowledgeKeys.all, predicate: (q) => q.queryKey[1] !== "import" });
    },
  });
}

export const useUploadVault = () => useImportWrite((v: { file: File; folder: string }) => call<ImportJob>("POST", `/imports${qs({ folder: v.folder })}`, v.file, { headers: { "Content-Type": "application/zip" } }));
export const useConfirmImport = () => useImportWrite((v: { id: string; policy: "skip" | "replace" | "keep_both" }) => call<ImportJob>("POST", `/imports/${v.id}/confirm`, { policy: v.policy }));
export const useCancelImport = () => useImportWrite((id: string) => call<ImportJob>("POST", `/imports/${id}/cancel`));
export const useUndoImport = () => useImportWrite((id: string) => call<ImportJob>("POST", `/imports/${id}/undo`));
export const useAttachChat = (id: string) => usePageWrite((chat_id: string) => call<Page>("PUT", `/pages/${id}/chat`, { chat_id }));

/** The Knowledge page a deck or design is (LAZYAGENTS-212), from its canvas id: for old /apps links and new decks. */
export const fetchCanvasPage = (canvasId: string) => unwrap(api.GET("/wiki/canvas-pages/{canvas_id}", { params: { path: { canvas_id: canvasId } } }));
