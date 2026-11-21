#!/usr/bin/env node
// Builds macos/Sources/VesperCore/Resources/shiki/shiki.js: Shiki with the JavaScript regex engine (no
// wasm), the web's themes and languages, as one script the native markdown renderer runs in
// JavaScriptCore (VesperCore Markdown/CodeHighlighter.swift). The output is checked in so the app
// build fetches nothing; re-run after upgrading shiki or changing web/lib/highlight.ts:
//
//   node macos/scripts/build-shiki-bundle.mjs        (needs web/node_modules: npm --prefix web ci)
//
// The languages and themes are read from web/lib/highlight.ts, so the two can't drift.
import { readFileSync, mkdirSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "../..");
const web = join(repo, "web");
const out = join(repo, "macos/Sources/VesperCore/Resources/shiki/shiki.js");
const { build } = createRequire(join(web, "package.json"))("esbuild");

const source = readFileSync(join(web, "lib/highlight.ts"), "utf8");
const langs = [...source.matchAll(/^\s*([\w-]+): \(\) => import\("shiki\/langs\/([\w-]+)\.mjs"\)/gm)].map((m) => ({ id: m[1], file: m[2] }));
const themes = [...source.matchAll(/import\("shiki\/themes\/([\w-]+)\.mjs"\)/g)].map((m) => m[1]);
if (langs.length === 0 || themes.length !== 2) throw new Error("couldn't read the languages and themes from web/lib/highlight.ts");

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
  stdin: { contents: entry, resolveDir: web, sourcefile: "shiki-entry.js" },
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
