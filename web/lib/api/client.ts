import createClient from "openapi-fetch";
import type { components, paths } from "./schema";

export type Schemas = components["schemas"];
export type Ticket = Schemas["Ticket"];
export type TicketSummary = Schemas["TicketSummary"];
export type TicketStatus = Schemas["TicketStatus"];
export type Priority = Schemas["Priority"];
export type TicketPatch = Schemas["TicketPatch"];
export type ActivityEvent = Schemas["ActivityEvent"];
export type Bootstrap = Schemas["Bootstrap"];
export type ArtifactType = Schemas["ArtifactType"];
export type ArtifactSummary = Schemas["ArtifactSummary"];
export type Artifact = Schemas["Artifact"];
export type DocCardData = Schemas["DocCard"];
export type AgentDetail = Schemas["AgentDetail"];
export type AgentKind = Schemas["AgentKind"];
export type AgentSpec = Schemas["AgentSpec"];
export type AgentOverride = Schemas["AgentOverride"];
export type ScopeMode = Schemas["ScopeMode"];
export type Harness = Schemas["Harness"];
export type Run = Schemas["Run"];
export type Approval = Schemas["Approval"];
export type LinkTarget = Schemas["LinkTarget"];
export type Mention = Schemas["Mention"];
export type WikiPageSummary = Schemas["WikiPageSummary"];
export type WikiPattern = Schemas["WikiPattern"];
export type WikiADR = Schemas["WikiADR"];
export type WikiCitations = Schemas["WikiCitations"];
export type TagCount = Schemas["TagCount"];
export type WikiSuggestion = Schemas["WikiSuggestion"];
export type GraphData = Schemas["Graph"];
export type NodeKind = Schemas["NodeKind"];

// The browser always talks to the same origin (Caddy in compose, Next
// rewrites in dev). Server components call the API over the internal network.
const baseUrl =
  typeof window === "undefined"
    ? `${process.env.API_INTERNAL_URL ?? "http://localhost:8000"}/api/v1`
    : "/api/v1";

export const api = createClient<paths>({ baseUrl });

/** Where the browser goes when the API wants a signed-in browser. */
export const SIGN_IN_PAGE = "/sign-in";

/** Sends a browser the API refused (401) to the sign-in page. */
function redirectIfSignedOut(response: Response) {
  if (response.status === 401 && typeof window !== "undefined" && window.location.pathname !== SIGN_IN_PAGE) {
    // A full load on purpose: this runs outside React, and the page needs
    // nothing from the signed-out app.
    window.location.assign(SIGN_IN_PAGE);
  }
}

api.use({
  onResponse({ response }) {
    redirectIfSignedOut(response);
  },
});

/** Thrown by `unwrap` so TanStack Query sees failures. */
export class ApiError extends Error {
  constructor(
    public status: number,
    public code: string,
    message: string,
    public field?: string,
  ) {
    super(message);
  }
}

/** Returns data or throws an ApiError built from the shared Error shape. */
export async function unwrap<T>(p: Promise<{ data?: T; error?: unknown; response: Response }>): Promise<T> {
  const { data, error, response } = await p;
  if (error !== undefined || data === undefined) {
    const e = (error ?? {}) as Partial<Schemas["Error"]>;
    throw new ApiError(response.status, e.code ?? "internal", e.message ?? response.statusText, e.field);
  }
  return data;
}

/**
 * Multipart POST for uploads (openapi-fetch types binary parts as strings).
 * Same error contract as `unwrap`.
 */
export async function postForm<T>(path: string, form: FormData, method: "POST" | "PUT" = "POST"): Promise<T> {
  const res = await fetch(`/api/v1${path}`, { method, body: form });
  redirectIfSignedOut(res);
  const body = await res.json().catch(() => ({}));
  if (!res.ok) {
    const e = body as Partial<Schemas["Error"]>;
    throw new ApiError(res.status, e.code ?? "internal", e.message ?? res.statusText, e.field);
  }
  return body as T;
}

/** URL of an uploaded chat attachment's file. */
export function chatAttachmentUrl(attachmentId: string) {
  return `/api/v1/chat-attachments/${attachmentId}/content`;
}

/** URL of an image a workflow step generated. */
export function workflowImageUrl(runId: string, imageId: string) {
  return `/api/v1/workflow-runs/${runId}/images/${imageId}/content`;
}

/** URL of one of the caller's Library items. */
export function libraryItemUrl(itemId: string, download = false) {
  return `/api/v1/library/${itemId}/content${download ? "?download=true" : ""}`;
}

/** URL of one version's raw content (markdown text or the stored file). */
export function contentUrl(artifactId: string, versionId: string, download = false) {
  return `/api/v1/artifacts/${artifactId}/versions/${versionId}/content${download ? "?download=true" : ""}`;
}
