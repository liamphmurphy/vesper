/**
 * Calls the Vesper API with the app's persistent session, for actions taken
 * outside a page (notification buttons, the tray, quick capture, sent files).
 * Paths are built by the validated request builders in notifications.ts,
 * capture.ts and drop.ts, and are always same-origin.
 */

export type FetchFn = (url: string, init?: RequestInit) => Promise<Response>;

export interface ApiResult<T = unknown> {
  ok: boolean;
  status: number;
  data?: T;
  error?: string;
}

export function joinApiUrl(serverUrl: string, apiPath: string): string {
  if (!apiPath.startsWith("/api/v1/")) throw new Error(`refusing non-API path ${apiPath}`);
  return `${serverUrl.replace(/\/+$/, "")}${apiPath}`;
}

/** The API's error body is { code, message }; fall back to the status. */
export function apiErrorMessage(status: number, body: unknown): string {
  const b = body && typeof body === "object" ? (body as Record<string, unknown>) : {};
  if (typeof b.message === "string" && b.message.trim()) return b.message.trim().slice(0, 300);
  if (status === 401 || status === 403) return "Vesper isn't signed in.";
  if (status === 404) return "It's no longer there.";
  if (status === 409) return "It has already changed; open Vesper to see it.";
  return `The server answered ${status}.`;
}

export async function apiRequest<T = unknown>(
  fetchFn: FetchFn,
  serverUrl: string,
  method: "GET" | "POST",
  apiPath: string,
  body?: unknown,
  opts: { timeoutMs?: number; rawBody?: { data: Buffer; contentType: string } } = {},
): Promise<ApiResult<T>> {
  let url: string;
  try {
    url = joinApiUrl(serverUrl, apiPath);
  } catch (err) {
    return { ok: false, status: 0, error: err instanceof Error ? err.message : String(err) };
  }
  const headers: Record<string, string> = { Accept: "application/json" };
  let payload: BodyInit | undefined;
  if (opts.rawBody) {
    headers["Content-Type"] = opts.rawBody.contentType;
    payload = new Uint8Array(opts.rawBody.data);
  } else if (body !== undefined) {
    headers["Content-Type"] = "application/json";
    payload = JSON.stringify(body);
  }
  try {
    const res = await fetchFn(url, {
      method,
      headers,
      ...(payload !== undefined ? { body: payload } : {}),
      signal: AbortSignal.timeout(opts.timeoutMs ?? 15_000),
    });
    const text = await res.text().catch(() => "");
    let data: unknown;
    try {
      data = text ? JSON.parse(text) : undefined;
    } catch {
      data = undefined;
    }
    if (!res.ok) return { ok: false, status: res.status, error: apiErrorMessage(res.status, data) };
    return { ok: true, status: res.status, data: data as T };
  } catch (err) {
    const name = err instanceof Error ? err.name : "";
    return {
      ok: false,
      status: 0,
      error: name === "TimeoutError" || name === "AbortError" ? "Vesper didn't answer in time." : "Vesper isn't reachable.",
    };
  }
}
