// Bundles the headless design & PDF worker into dist/server.mjs alongside @resvg/resvg-js,
// pdfjs-dist runtime files, and the bundled Inter & Liberation TTFs.
import { build } from "esbuild";
import { cpSync, existsSync, mkdirSync, readdirSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const out = join(root, "dist");
rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

await build({
  entryPoints: [join(root, "src", "main.ts")],
  outfile: join(out, "server.mjs"),
  bundle: true,
  platform: "node",
  format: "esm",
  target: "node22",
  external: ["@resvg/resvg-js"],
  tsconfig: join(root, "tsconfig.json"),
  logLevel: "warning",
});

const scope = join(root, "node_modules", "@resvg");
for (const name of readdirSync(scope)) {
  if (name === "resvg-js" || name.startsWith("resvg-js-")) {
    cpSync(join(scope, name), join(out, "node_modules", "@resvg", name), { recursive: true });
  }
}
if (!existsSync(join(out, "node_modules", "@resvg", "resvg-js"))) throw new Error("@resvg/resvg-js isn't installed");

const pdfjsSrc = join(root, "node_modules", "pdfjs-dist", "build");
const pdfjsDst = join(out, "pdfjs");
mkdirSync(pdfjsDst, { recursive: true });
for (const file of ["pdf.min.mjs", "pdf.worker.min.mjs"]) {
  const src = join(pdfjsSrc, file);
  if (!existsSync(src)) throw new Error(`missing ${src}`);
  cpSync(src, join(pdfjsDst, file));
}

cpSync(join(root, "fonts"), join(out, "fonts"), { recursive: true });
console.log("design worker bundled:", join("dist", "server.mjs"));
