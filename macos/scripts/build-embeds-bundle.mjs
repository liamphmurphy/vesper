#!/usr/bin/env node
// Builds macos/Sources/VesperCore/Resources/embeds/: the scripts the native chat's off-screen renderer
// (Vesper Native/ChatEmbeds/EmbedRenderer.swift) runs to draw ```mermaid fences and $$ math, as the
// web does (components/domain/mermaid-fence.tsx, rehype-katex). The output is checked in so the app
// build fetches nothing and the renderer page loads nothing remote; re-run after upgrading mermaid or
// katex in web/package.json:
//
//   node macos/scripts/build-embeds-bundle.mjs        (needs web/node_modules: npm --prefix web ci)
//
// - mermaid.js: mermaid's own IIFE build (dist/mermaid.min.js), unchanged.
// - katex.js: KaTeX's UMD build, unchanged.
// - katex.css: KaTeX's stylesheet with each font inlined as a woff2 data: URL (the page's CSP allows
//   fonts only from data:), dropping the woff/ttf fallbacks WebKit never picks.
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "../..");
const modules = join(repo, "web/node_modules");
const out = join(repo, "macos/Sources/VesperCore/Resources/embeds");
const version = (pkg) => JSON.parse(readFileSync(join(modules, pkg, "package.json"), "utf8")).version;

mkdirSync(out, { recursive: true });

const mermaid = readFileSync(join(modules, "mermaid/dist/mermaid.min.js"), "utf8");
writeFileSync(join(out, "mermaid.js"), `/* mermaid ${version("mermaid")} (MIT), dist/mermaid.min.js */\n${mermaid}`);

const katex = readFileSync(join(modules, "katex/dist/katex.min.js"), "utf8");
writeFileSync(join(out, "katex.js"), `/* KaTeX ${version("katex")} (MIT), dist/katex.min.js */\n${katex}`);

const fonts = join(modules, "katex/dist");
let inlined = 0;
const css = readFileSync(join(fonts, "katex.min.css"), "utf8").replace(/src:([^;}]+)/g, (whole, sources) => {
  const woff2 = /url\((fonts\/[^)]+\.woff2)\)/.exec(sources);
  if (!woff2) return whole;
  inlined++;
  const data = readFileSync(join(fonts, woff2[1])).toString("base64");
  return `src:url(data:font/woff2;base64,${data}) format("woff2")`;
});
if (inlined === 0 || /url\(fonts\//.test(css)) throw new Error("couldn't inline KaTeX's fonts: katex.min.css changed shape");
writeFileSync(join(out, "katex.css"), `/* KaTeX ${version("katex")} (MIT), dist/katex.min.css with woff2 fonts inlined */\n${css}`);

// EmbedRendererPage.swift inlines katex.js and katex.css in <script> and <style>: neither may close them.
if (/<\/script/i.test(katex) || /<\/style/i.test(css)) throw new Error("KaTeX's bundle contains </script or </style; it can't be inlined");

console.log(`wrote ${out} (mermaid ${version("mermaid")}, KaTeX ${version("katex")}, ${inlined} fonts)`);
