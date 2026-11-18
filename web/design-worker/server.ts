// The node process next to the static UI: the design worker (always), and, when STATIC_DIR is set, the
// built UI too (a real file, else index.html, as Go serves it), plus a proxy of /api, /mcp and /events to
// API_INTERNAL_URL. `vesper app` runs it with neither STATIC_DIR nor a proxy: Go serves the UI itself.
//
//   PORT, HOSTNAME        where to listen (default 127.0.0.1:3000)
//   DESIGN_WORKER_TOKEN   bearer token the Go API presents; unset refuses every call
//   STATIC_DIR            serve this directory as the UI
//   API_INTERNAL_URL      proxy /api, /mcp, /events here
import { createServer, request as httpRequest, type IncomingMessage, type ServerResponse } from "node:http";
import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { extname, join, normalize, resolve, sep } from "node:path";
import { handleDesignWorker } from "./handler.ts";

const TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".ttf": "font/ttf",
  ".map": "application/json",
  ".wasm": "application/wasm",
  ".txt": "text/plain; charset=utf-8",
};

const isApiPath = (p: string) => /^\/(api|mcp|events)(\/|$)/.test(p);

function proxy(target: URL, req: IncomingMessage, res: ServerResponse) {
  const up = httpRequest(
    { hostname: target.hostname, port: target.port, path: req.url, method: req.method, headers: { ...req.headers, host: target.host } },
    (r) => {
      res.writeHead(r.statusCode ?? 502, r.headers);
      r.pipe(res);
    },
  );
  up.on("error", () => {
    if (!res.headersSent) res.writeHead(502, { "content-type": "text/plain" });
    res.end("bad gateway");
  });
  req.pipe(up);
}

async function serveStatic(root: string, pathname: string, res: ServerResponse): Promise<void> {
  let rel: string;
  try {
    rel = normalize(decodeURIComponent(pathname));
  } catch {
    res.writeHead(400).end();
    return;
  }
  let file = resolve(join(root, rel));
  if (file !== root && !file.startsWith(root + sep)) {
    res.writeHead(404).end();
    return;
  }
  let info = await stat(file).catch(() => null);
  let hashed = false;
  if (info?.isFile()) hashed = rel.startsWith(`${sep}assets${sep}`);
  else {
    // A missing built asset or font is a 404; any other path is a client route and gets the app.
    if (/^[/\\](assets|fonts)[/\\]/.test(rel)) {
      res.writeHead(404).end();
      return;
    }
    file = join(root, "index.html");
    info = await stat(file).catch(() => null);
    if (!info) {
      res.writeHead(404).end();
      return;
    }
  }
  res.writeHead(200, {
    "content-type": TYPES[extname(file)] ?? "application/octet-stream",
    "content-length": String(info.size),
    "cache-control": hashed ? "public, max-age=31536000, immutable" : "no-cache",
  });
  createReadStream(file).pipe(res);
}

export function createWebServer(opts: { staticDir?: string; apiURL?: string }) {
  const root = opts.staticDir ? resolve(opts.staticDir) : "";
  const api = opts.apiURL ? new URL(opts.apiURL) : undefined;
  return createServer(async (req, res) => {
    try {
      const pathname = new URL(req.url ?? "/", "http://web").pathname;
      if (pathname === "/internal" || pathname.startsWith("/internal/")) {
        if (!(await handleDesignWorker(req, res))) {
          // The preview page (token already checked) is a client route; anything else under /internal is a 404.
          if (pathname === "/internal/designs/preview" && root) await serveStatic(root, "/index.html", res);
          else res.writeHead(404).end();
        }
        return;
      }
      if (api && isApiPath(pathname)) return proxy(api, req, res);
      if (!root) {
        res.writeHead(404).end();
        return;
      }
      if (req.method !== "GET" && req.method !== "HEAD") {
        res.writeHead(405, { allow: "GET, HEAD" }).end();
        return;
      }
      await serveStatic(root, pathname, res);
    } catch (e) {
      console.error("web server:", e);
      if (!res.headersSent) res.writeHead(500);
      res.end();
    }
  });
}
