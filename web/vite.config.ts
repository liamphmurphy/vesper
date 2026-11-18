import { fileURLToPath } from "node:url";
import tailwindcss from "@tailwindcss/vite";
import react from "@vitejs/plugin-react";
import { defineConfig, type Plugin } from "vite";
import { themeScript } from "./lib/appearance-script.ts";

const root = (p: string) => fileURLToPath(new URL(p, import.meta.url));
const apiInternal = process.env.API_INTERNAL_URL ?? "http://localhost:8000";

/** The pre-paint appearance script (lib/appearance-script.ts) goes into <head>, as the root layout used to inline it. */
function appearanceScript(): Plugin {
  return {
    name: "vesper-appearance-script",
    transformIndexHtml: (html) => html.replace("<!-- APPEARANCE_SCRIPT -->", `<script>${themeScript}</script>`),
  };
}

/** `vite dev` serves the design worker's routes (/internal/designs/*) itself, as the standalone worker does. */
function designWorker(): Plugin {
  return {
    name: "vesper-design-worker",
    configureServer(server) {
      server.middlewares.use(async (req, res, next) => {
        const pathname = (req.url ?? "").split("?")[0];
        if (pathname !== "/internal" && !pathname.startsWith("/internal/")) return next();
        try {
          const { handleDesignWorker } = await import("./design-worker/handler.ts");
          if (await handleDesignWorker(req, res)) return;
          // The render-parity preview page, token accepted: a client route.
          if (pathname === "/internal/designs/preview") {
            req.url = "/";
            return next();
          }
          res.writeHead(404).end();
        } catch (e) {
          next(e);
        }
      });
    },
  };
}

export default defineConfig({
  plugins: [react(), tailwindcss(), appearanceScript(), designWorker()],
  resolve: {
    alias: [
      { find: /^@\//, replacement: root("./") },
      { find: /^next\/link$/, replacement: root("./lib/next-compat/link.tsx") },
      { find: /^next\/navigation$/, replacement: root("./lib/next-compat/navigation.tsx") },
    ],
  },
  server: {
    port: 3000,
    // The playground gateway and the desktop window reach the dev server under other host names.
    allowedHosts: true,
    // In production Go serves these; in dev the API runs on its own port.
    proxy: {
      "/api": apiInternal,
      "/mcp": apiInternal,
      "/events": apiInternal,
    },
  },
  build: {
    outDir: "dist",
    sourcemap: false,
    chunkSizeWarningLimit: 4000,
  },
});
