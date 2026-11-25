#!/usr/bin/env node
// Builds macos/Sources/VesperCore/Resources/shiki/shiki.js: Shiki with the JavaScript regex engine (no
// wasm), the web's themes and languages, as one script the native markdown renderer runs in
// JavaScriptCore (VesperCore Markdown/CodeHighlighter.swift). The output is checked in so the app
// build fetches nothing; re-run after upgrading shiki in design-worker/package.json:
//
//   node macos/scripts/build-shiki-bundle.mjs        (needs design-worker/node_modules: npm --prefix design-worker ci)
import { mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "../..");
const worker = join(repo, "design-worker");
const out = join(repo, "macos/Sources/VesperCore/Resources/shiki/shiki.js");
const { build } = createRequire(join(worker, "package.json"))("esbuild");

const langs = [
  "typescript", "tsx", "javascript", "jsx", "json", "go", "python", "ruby", "rust", "java",
  "kotlin", "swift", "c", "cpp", "csharp", "php", "shellscript", "yaml", "toml", "markdown",
  "html", "css", "scss", "sql", "docker", "make",
].map((id) => ({ id, file: id }));
const themes = ["github-light", "github-dark"];

// One entry point: a synchronous highlighter (JavaScriptCore runs no event loop between calls) behind
// a tiny API that returns JSON, so Swift crosses the bridge once per block.
const entry = `
import { createHighlighterCoreSync } from "shiki/core";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
${themes.map((t, i) => `import theme${i} from "shiki/themes/${t}.mjs";`).join("\n")}
${langs.map((l, i) => `import lang${i} from "shiki/langs/${l.file}.mjs";`).join("\n")}

const highlighter = createHighlighterCoreSync({
  themes: [${themes.map((_, i) => `theme${i}`).join(", ")}],
  langs: [${langs.map((_, i) => `lang${i}`).join(", ")}],
  // ES2018 regexes, not the "auto" target's ES2024 (\`v\` flag) ones: with those, JavaScriptCore
  // mis-colours tokens the first time a grammar runs (in TypeScript, everything after the first
  // member of an interface), while ES2018 gives the tokens Chrome does every time.
  engine: createJavaScriptRegexEngine({ target: "ES2018" }),
});
const languages = ${JSON.stringify(langs.map((l) => l.id))};

globalThis.VesperShiki = {
  languages,
  // One array per line of [content, light colour, dark colour], as lib/highlight.ts's highlightLines
  // passes them on (its --shiki-light / --shiki-dark variables).
  highlight(code, lang) {
    if (!languages.includes(lang)) return "null";
    const { tokens } = highlighter.codeToTokens(code, { lang, themes: { light: ${JSON.stringify(themes[0])}, dark: ${JSON.stringify(themes[1])} }, defaultColor: false });
    return JSON.stringify(tokens.map((line) => line.map((t) => [t.content, t.htmlStyle?.["--shiki-light"] ?? null, t.htmlStyle?.["--shiki-dark"] ?? null])));
  },
};
`;

mkdirSync(dirname(out), { recursive: true });
await build({
  stdin: { contents: entry, resolveDir: worker, sourcefile: "shiki-entry.js" },
  bundle: true,
  format: "iife",
  platform: "neutral",
  mainFields: ["module", "main"],
  target: "safari18",
  minify: true,
  legalComments: "eof",
  outfile: out,
  logLevel: "warning",
});
console.log(`wrote ${out} (${langs.length} languages, themes ${themes.join(", ")})`);
