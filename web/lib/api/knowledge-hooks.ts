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
  kind?: PageKind;
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

export function usePage(id: string | undefined) {
  return useQuery({ queryKey: knowledgeKeys.page(id ?? ""), queryFn: () => fetchPage(id!), enabled: !!id });
}

/** The rows of the saved query a page holds in its `query` property. */
export function useSavedQuery(id: string | undefined, enabled: boolean) {
  return useQuery({ queryKey: knowledgeKeys.query(id ?? ""), queryFn: () => call<PageTable>("GET", `/pages/${id}/query`), enabled: !!id && enabled });
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
export const useDaily = () => usePageWrite((v: { date?: string; folder?: string; template?: string }) => call<Page>("POST", "/daily", v));
export const usePageControls = (id: string) => usePageWrite((v: { direct: boolean; paused: boolean }) => call<Page>("PUT", `/pages/${id}/controls`, v));
export const useRestore = (id: string) => usePageWrite((version: string) => call<Page>("POST", `/pages/${id}/restore/${version}`));
export const useFileCapture = (id: string) => usePageWrite((v: { folder?: string; merge?: string }) => call<Page>("POST", `/pages/${id}/file`, v));
export const useAttachChat = (id: string) => usePageWrite((chat_id: string) => call<Page>("PUT", `/pages/${id}/chat`, { chat_id }));

/** The Knowledge page a deck or design is (LAZYAGENTS-212), from its canvas id: for old /apps links and new decks. */
export const fetchCanvasPage = (canvasId: string) => unwrap(api.GET("/wiki/canvas-pages/{canvas_id}", { params: { path: { canvas_id: canvasId } } }));
