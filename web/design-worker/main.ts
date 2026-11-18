// Entry of the bundled worker (scripts/build-design-worker.mjs): configuration comes from the environment.
//   PORT, HOSTNAME        where to listen (default 127.0.0.1:3000)
//   DESIGN_WORKER_TOKEN   bearer token the Go API presents; unset refuses every call
//   DESIGN_FONT_DIR       Inter TTFs (default ../fonts/designs beside this file)
//   STATIC_DIR            also serve the built UI from this directory
//   API_INTERNAL_URL      also proxy /api, /mcp and /events there
import { fileURLToPath } from "node:url";
import { createWebServer } from "./server.ts";

// The Inter TTFs sit in the UI build, one directory up from the bundled worker.
process.env.DESIGN_FONT_DIR ??= fileURLToPath(new URL("../fonts/designs", import.meta.url));

const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOSTNAME ?? "127.0.0.1";
createWebServer({ staticDir: process.env.STATIC_DIR, apiURL: process.env.API_INTERNAL_URL }).listen(port, host, () => {
  console.log(`web ready on http://${host}:${port}`);
});
for (const sig of ["SIGINT", "SIGTERM"] as const) process.on(sig, () => process.exit(0));
