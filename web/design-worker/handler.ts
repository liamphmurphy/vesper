// The design worker's HTTP surface (ADR-designs §2.2), on node:http. The Go API posts a design body
// here with `Authorization: Bearer $DESIGN_WORKER_TOKEN` and gets a PNG, node boxes, inspect output or
// an imported node back. The logic lives in lib/designs/worker.ts (Request in, Response out); this
// file only adapts it to Node's server. It is used by the standalone server and the Vite dev server.
import type { IncomingMessage, ServerResponse } from "node:http";
import { handleImport, handleInspect, handleLayout, handleRender, tokenOk } from "../lib/designs/worker.ts";
import { handlePdf } from "../lib/pdf/render.ts";

export const PREFIX = "/internal/designs";

const posts: Record<string, (req: Request) => Promise<Response>> = {
  [`${PREFIX}/render`]: handleRender,
  [`${PREFIX}/layout`]: handleLayout,
  [`${PREFIX}/inspect`]: handleInspect,
  [`${PREFIX}/import`]: handleImport,
  [`${PREFIX}/pdf`]: handlePdf,
};

// The worker refuses bodies over 48 MiB itself; this only stops reading a hostile stream.
const READ_LIMIT = 49 * 1024 * 1024;

async function readBody(req: IncomingMessage): Promise<Buffer | null> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const chunk of req) {
    size += (chunk as Buffer).length;
    if (size > READ_LIMIT) return null;
    chunks.push(chunk as Buffer);
  }
  return Buffer.concat(chunks);
}

function send(res: ServerResponse, status: number, headers: Record<string, string>, body: Buffer | string) {
  res.writeHead(status, headers);
  res.end(body);
}

/** Is `pathname` one of the worker's paths (including the render-parity preview page)? */
export function isWorkerPath(pathname: string): boolean {
  return pathname in posts || pathname === `${PREFIX}/preview`;
}

/**
 * Handles a worker request. Returns false when the request isn't the worker's, or when it is the
 * preview page with a good token (the caller then serves its index.html).
 */
export async function handleDesignWorker(req: IncomingMessage, res: ServerResponse): Promise<boolean> {
  const url = new URL(req.url ?? "/", "http://worker");
  if (url.pathname === `${PREFIX}/preview`) {
    // A bare <DesignSvg> page for the render-parity e2e spec: like the routes it needs the token
    // (?token=), and it's a 404 when DESIGN_WORKER_TOKEN is unset.
    if (tokenOk(url.searchParams.get("token") ?? "")) return false;
    send(res, 404, { "content-type": "text/plain" }, "not found");
    return true;
  }
  const handler = posts[url.pathname];
  if (!handler) return false;
  if (req.method !== "POST") {
    send(res, 405, { allow: "POST" }, "");
    return true;
  }
  const body = await readBody(req);
  if (!body) {
    send(res, 400, { "content-type": "application/json" }, JSON.stringify({ message: "request is too large" }));
    return true;
  }
  const headers = new Headers();
  for (const [k, v] of Object.entries(req.headers)) if (v !== undefined) headers.set(k, Array.isArray(v) ? v.join(", ") : v);
  const out = await handler(new Request(`http://worker${url.pathname}`, { method: "POST", headers, body: new Uint8Array(body) }));
  const outHeaders: Record<string, string> = {};
  out.headers.forEach((v, k) => (outHeaders[k] = v));
  send(res, out.status, outHeaders, Buffer.from(await out.arrayBuffer()));
  return true;
}
