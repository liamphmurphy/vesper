// Bundles the design worker (and the small static/proxy server around it) into dist/design-worker/server.mjs,
// next to the UI build `vite build` leaves in dist/. Run after it: `npm run build` does both.
//
// The worker rasterises with @resvg/resvg-js, a native addon that can't be bundled; it is copied beside
// the bundle (node resolves it from dist/design-worker/node_modules) together with its platform binding.
// The Inter TTFs it draws with ship in dist/fonts/designs (public/ is copied there by vite).
import { build } from "esbuild";
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const web = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(web, "dist", "design-worker");
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

await build({
  entryPoints: [join(web, "design-worker", "main.ts")],
  outfile: join(out, "server.mjs"),
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  external: ["@resvg/resvg-js"],
  tsconfig: join(web, "tsconfig.json"),
  logLevel: "warning",
});

const scope = join(web, "node_modules", "@resvg");
for (const name of readdirSync(scope)) {
  if (name === "resvg-js" || name.startsWith("resvg-js-")) {
    cpSync(join(scope, name), join(out, "node_modules", "@resvg", name), { recursive: true });
  }
}
if (!existsSync(join(out, "node_modules", "@resvg", "resvg-js"))) throw new Error("@resvg/resvg-js isn't installed");

// Copy pdfjs-dist runtime files for offline PDF page preview rasterisation inside the worker.
const pdfjsSrc = join(web, "node_modules", "pdfjs-dist", "build");
const pdfjsDst = join(out, "pdfjs");
mkdirSync(pdfjsDst, { recursive: true });
for (const file of ["pdf.min.mjs", "pdf.worker.min.mjs"]) {
  const src = join(pdfjsSrc, file);
  if (!existsSync(src)) throw new Error(`missing ${src}`);
  cpSync(src, join(pdfjsDst, file));
}
console.log("design worker bundled:", join("dist", "design-worker", "server.mjs"));
