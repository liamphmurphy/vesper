"use client";

import { useEffect, useMemo, useState, type CSSProperties } from "react";
import type { HighlighterCore } from "shiki/core";
import { useVizPalette } from "@/lib/viz-theme";
import { tokenColor } from "@/lib/code-colors";

/** One highlighted token; `style` carries shiki's --shiki-light/--shiki-dark variables (see globals.css). */
export type Tok = { content: string; style?: CSSProperties };

// Only languages the app maps (lib/code-diff.ts) are bundled, each as its own lazy chunk.
const LANGS: Record<string, () => Promise<unknown>> = {
  typescript: () => import("shiki/langs/typescript.mjs"),
  tsx: () => import("shiki/langs/tsx.mjs"),
  javascript: () => import("shiki/langs/javascript.mjs"),
  jsx: () => import("shiki/langs/jsx.mjs"),
  json: () => import("shiki/langs/json.mjs"),
  go: () => import("shiki/langs/go.mjs"),
  python: () => import("shiki/langs/python.mjs"),
  ruby: () => import("shiki/langs/ruby.mjs"),
  rust: () => import("shiki/langs/rust.mjs"),
  java: () => import("shiki/langs/java.mjs"),
  kotlin: () => import("shiki/langs/kotlin.mjs"),
  swift: () => import("shiki/langs/swift.mjs"),
  c: () => import("shiki/langs/c.mjs"),
  cpp: () => import("shiki/langs/cpp.mjs"),
  csharp: () => import("shiki/langs/csharp.mjs"),
  php: () => import("shiki/langs/php.mjs"),
  shellscript: () => import("shiki/langs/shellscript.mjs"),
  yaml: () => import("shiki/langs/yaml.mjs"),
  toml: () => import("shiki/langs/toml.mjs"),
  markdown: () => import("shiki/langs/markdown.mjs"),
  html: () => import("shiki/langs/html.mjs"),
  css: () => import("shiki/langs/css.mjs"),
  scss: () => import("shiki/langs/scss.mjs"),
  sql: () => import("shiki/langs/sql.mjs"),
  docker: () => import("shiki/langs/docker.mjs"),
  make: () => import("shiki/langs/make.mjs"),
};

let highlighter: Promise<HighlighterCore> | undefined;
const loaded = new Map<string, Promise<void>>();

// A singleton, created on first use in the browser: shiki is never imported during SSR or before a block opens.
function getHighlighter() {
  highlighter ??= (async () => {
    const [{ createHighlighterCore }, { createJavaScriptRegexEngine }, light, dark] = await Promise.all([
      import("shiki/core"),
      import("shiki/engine/javascript"),
      import("shiki/themes/github-light.mjs"),
      import("shiki/themes/github-dark.mjs"),
    ]);
    return createHighlighterCore({ themes: [light.default, dark.default], langs: [], engine: createJavaScriptRegexEngine() });
  })();
  return highlighter;
}

function ensureLang(h: HighlighterCore, lang: string) {
  let p = loaded.get(lang);
  if (!p) {
    p = LANGS[lang]().then((m) => h.loadLanguage((m as { default: never }).default));
    loaded.set(lang, p);
  }
  return p;
}

/** Highlights `lines` as one snippet (so multi-line constructs work); one token array per input line, or null if unsupported or on error. */
export async function highlightLines(lines: string[], lang: string | null): Promise<Tok[][] | null> {
  if (!lang || !LANGS[lang]) return null;
  try {
    const h = await getHighlighter();
    await ensureLang(h, lang);
    const { tokens } = h.codeToTokens(lines.join("\n"), { lang, themes: { light: "github-light", dark: "github-dark" }, defaultColor: false });
    return lines.map((_, i) => (tokens[i] ?? []).map((t) => ({ content: t.content, style: t.htmlStyle as CSSProperties | undefined })));
  } catch {
    return null;
  }
}

/** Tokens for `lines` once shiki has loaded (null before, when disabled, or for unknown languages: render plain text). */
export function useHighlighted(lines: string[][], lang: string | null, enabled: boolean): Tok[][][] | null {
  const palette = useVizPalette();
  const key = lines.map((l) => l.join("\n")).join("\u0000");
  const [done, setDone] = useState<{ key: string; lang: string | null; toks: Tok[][][] } | null>(null);
  useEffect(() => {
    if (!enabled || !lang) return;
    let live = true;
    void Promise.all(lines.map((l) => highlightLines(l, lang))).then((r) => {
      if (live && r.every(Boolean)) setDone({ key, lang, toks: r as Tok[][][] });
    });
    return () => {
      live = false;
    };
    // `key` stands in for `lines`, which is a fresh array every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, lang, key]);
  return useMemo(() => {
    if (!done || done.key !== key || done.lang !== lang) return null;
    const color = (source: unknown) => tokenColor(source, palette);
    return done.toks.map((block) => block.map((line) => line.map((t) => ({ ...t, style: {
      ...t.style,
      "--shiki-dark": color((t.style as Record<string, unknown>)?.["--shiki-dark"]),
      "--shiki-light": color((t.style as Record<string, unknown>)?.["--shiki-light"]),
    } as CSSProperties }))));
  }, [done, key, lang, palette]);
}
