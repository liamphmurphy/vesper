// Entry of the headless design & PDF worker (bundled by scripts/build.mjs):
//   PORT, HOSTNAME        where to listen (default 127.0.0.1:3000)
//   DESIGN_WORKER_TOKEN   bearer token the Go API presents; unset refuses every call
//   DESIGN_FONT_DIR       Inter TTFs (default ./fonts/designs beside this file)
//   VESPER_FONTS_DIR      Bundled fonts root (default ./fonts beside this file)
//   VESPER_PDFJS_DIR      Bundled pdfjs-dist runtime (default ./pdfjs beside this file)
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { closePdfBrowser } from "../lib/pdf/cdp.ts";
import { createWorkerServer } from "./server.ts";

function firstExisting(candidates: URL[]): string {
  for (const u of candidates) {
    const p = fileURLToPath(u);
    if (existsSync(p)) return p;
  }
  return fileURLToPath(candidates[0]);
}

process.env.DESIGN_FONT_DIR ??= firstExisting([
  new URL("./fonts/designs", import.meta.url),
  new URL("../fonts/designs", import.meta.url),
]);
process.env.VESPER_FONTS_DIR ??= firstExisting([
  new URL("./fonts", import.meta.url),
  new URL("../fonts", import.meta.url),
]);
process.env.VESPER_PDFJS_DIR ??= firstExisting([
  new URL("./pdfjs", import.meta.url),
  new URL("../node_modules/pdfjs-dist/build", import.meta.url),
]);

const port = Number(process.env.PORT ?? 3000);
const host = process.env.HOSTNAME ?? "127.0.0.1";
createWorkerServer().listen(port, host, () => {
  console.log(`design-worker ready on http://${host}:${port}`);
});
for (const sig of ["SIGINT", "SIGTERM"] as const) {
  process.on(sig, () => {
    closePdfBrowser();
    process.exit(0);
  });
}
