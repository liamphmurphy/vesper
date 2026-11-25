// The design & PDF worker's HTTP surface on node:http. The Go API posts a design or PDF request
// here with `Authorization: Bearer $DESIGN_WORKER_TOKEN` and receives PNGs, node boxes, inspect
// output, imported nodes, or rendered PDFs.
import type { IncomingMessage, ServerResponse } from "node:http";
import { handleImport, handleInspect, handleLayout, handleRender } from "../lib/designs/worker.ts";
import { handlePdf } from "../lib/pdf/render.ts";

export const PREFIX = "/internal/designs";

const posts: Record<string, (req: Request) => Promise<Response>> = {
  [`${PREFIX}/render`]: handleRender,
  [`${PREFIX}/layout`]: handleLayout,
  [`${PREFIX}/inspect`]: handleInspect,
  [`${PREFIX}/import`]: handleImport,
  [`${PREFIX}/pdf`]: handlePdf,
};

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

export async function handleDesignWorker(req: IncomingMessage, res: ServerResponse): Promise<boolean> {
  const url = new URL(req.url ?? "/", "http://worker");
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
