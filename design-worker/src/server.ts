import { createServer } from "node:http";
import { handleDesignWorker } from "./handler.ts";

export function createWorkerServer() {
  return createServer(async (req, res) => {
    try {
      const pathname = new URL(req.url ?? "/", "http://worker").pathname;
      if (pathname === "/internal" || pathname.startsWith("/internal/")) {
        if (!(await handleDesignWorker(req, res))) {
          res.writeHead(404).end();
        }
        return;
      }
      res.writeHead(404).end();
    } catch (e) {
      console.error("design-worker:", e);
      if (!res.headersSent) res.writeHead(500);
      res.end();
    }
  });
}
