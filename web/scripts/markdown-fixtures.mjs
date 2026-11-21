// Writes the expected output for the native markdown renderer's snapshot tests
// (protocol/markdown/README.md): each fixture goes through the web's own pipeline (the
// chat's rewrites, wikilinks, remark with the plugins components/domain/markdown.tsx uses)
// and Shiki with lib/highlight.ts's themes, and lands as normalized JSON the Mac app's
// MarkdownSnapshotTests compare against. Run after changing the fixtures or the web renderer:
//
//   node --experimental-strip-types web/scripts/markdown-fixtures.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { unified } from "unified";
import remarkParse from "remark-parse";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import { createHighlighterCore } from "shiki/core";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import githubLight from "shiki/themes/github-light.mjs";
import githubDark from "shiki/themes/github-dark.mjs";
import { linkify } from "../lib/wikilinks.ts";
import { linkCitations } from "../lib/chat-sources.ts";
import { linkTicketKeys } from "../lib/ticket-keys.ts";
import { langFromFence } from "../lib/code-diff.ts";
import { tokenColor } from "../lib/code-colors.ts";
import { VIZ_DARK, VIZ_LIGHT } from "../lib/chat-svg.ts";

const root = join(dirname(fileURLToPath(import.meta.url)), "../../protocol/markdown");
const fixtures = JSON.parse(readFileSync(join(root, "fixtures.json"), "utf8"));

// The same parser the Markdown component builds: GFM, and math only between $$.
const parser = unified().use(remarkParse).use(remarkGfm).use(remarkMath, { singleDollarTextMath: false });

/** The source as the web renders it: ChatMarkdown's rewrites in chat, then Markdown's wikilinks. */
function prepare(md, fixture) {
  if (fixture.chat) md = linkCitations(linkTicketKeys(md), fixture.cites ?? []);
  return linkify(md);
}

/**
 * mdast in the shape the native AST snapshots to: references resolved to links and images (as
 * remark-rehype does), footnotes numbered by first reference and listed at the end, adjacent text
 * merged, and code/HTML without their trailing newline.
 */
function normalize(tree) {
  const definitions = new Map();
  const footnoteDefs = new Map();
  const visitDefs = (n) => {
    if (n.type === "definition") definitions.set(n.identifier, n);
    if (n.type === "footnoteDefinition") footnoteDefs.set(n.identifier, n);
    n.children?.forEach(visitDefs);
  };
  visitDefs(tree);
  const footnoteOrder = [];
  const footnoteNumber = (id) => {
    let i = footnoteOrder.indexOf(id);
    if (i < 0) i = footnoteOrder.push(id) - 1;
    return i + 1;
  };

  const children = (n) => mergeText(n.children.flatMap(node));
  function node(n) {
    switch (n.type) {
      case "definition":
      case "footnoteDefinition":
        return [];
      case "paragraph":
      case "blockquote":
      case "emphasis":
      case "strong":
      case "delete":
      case "tableRow":
      case "tableCell":
        return [{ type: n.type, children: children(n) }];
      case "heading":
        return [{ type: "heading", depth: n.depth, children: children(n) }];
      case "thematicBreak":
        return [{ type: "thematicBreak" }];
      // Loose and tight lists look the same here (no paragraph margins), so spread isn't compared.
      case "list":
        return [{ type: "list", ordered: !!n.ordered, ...(n.ordered ? { start: n.start ?? 1 } : {}), children: children(n) }];
      case "listItem":
        return [{ type: "listItem", ...(typeof n.checked === "boolean" ? { checked: n.checked } : {}), children: children(n) }];
      case "code":
        return [{ type: "code", info: [n.lang, n.meta].filter(Boolean).join(" "), value: n.value }];
      case "math":
        return [{ type: "math", value: n.value }];
      case "inlineMath":
        return [{ type: "inlineMath", value: n.value }];
      case "html":
        return [{ type: "html", value: n.value.replace(/\n+$/, "") }];
      case "table":
        return [{ type: "table", align: n.align.map((a) => a ?? null), children: children(n) }];
      case "text":
        return [{ type: "text", value: n.value }];
      case "inlineCode":
        return [{ type: "inlineCode", value: n.value }];
      case "break":
        return [{ type: "break" }];
      case "link":
        return [link(n.url, n.title, children(n))];
      case "linkReference": {
        const d = definitions.get(n.identifier);
        return [link(d.url, d.title, children(n))];
      }
      case "image":
        return [image(n.url, n.title, n.alt)];
      case "imageReference": {
        const d = definitions.get(n.identifier);
        return [image(d.url, d.title, n.alt)];
      }
      case "footnoteReference":
        return [{ type: "footnoteReference", n: footnoteNumber(n.identifier) }];
      default:
        throw new Error(`unhandled mdast node ${n.type}`);
    }
  }
  const link = (url, title, kids) => ({ type: "link", url, ...(title ? { title } : {}), children: kids });
  const image = (url, title, alt) => ({ type: "image", url, alt: alt ?? "", ...(title ? { title } : {}) });

  const blocks = children(tree);
  // Definitions can reference more footnotes, so number while walking them.
  const footnotes = [];
  for (let i = 0; i < footnoteOrder.length; i++) {
    footnotes.push({ type: "footnote", n: i + 1, children: children(footnoteDefs.get(footnoteOrder[i])) });
  }
  return { type: "root", children: blocks, footnotes };
}

function mergeText(nodes) {
  const out = [];
  for (const n of nodes) {
    const last = out[out.length - 1];
    if (n.type === "text" && last?.type === "text") last.value += n.value;
    else out.push(n);
  }
  return out;
}

function codeBlocks(tree) {
  const out = [];
  const visit = (n) => {
    if (n.type === "code") out.push(n);
    n.children?.forEach(visit);
  };
  visit(tree);
  return out;
}

const highlighter = await createHighlighterCore({ themes: [githubLight, githubDark], langs: [], engine: createJavaScriptRegexEngine() });

/** lib/highlight.ts highlightLines and useHighlighted's colours, for the fallback palettes. */
async function tokens(code) {
  const lang = langFromFence(code.lang ?? undefined);
  if (!lang) return null;
  await highlighter.loadLanguage((await import(`shiki/langs/${lang}.mjs`)).default);
  const lines = code.value.replace(/\n$/, "").split("\n");
  const { tokens: result } = highlighter.codeToTokens(lines.join("\n"), { lang, themes: { light: "github-light", dark: "github-dark" }, defaultColor: false });
  return {
    lang,
    lines: lines.map((_, i) =>
      (result[i] ?? []).map((t) => {
        const light = t.htmlStyle?.["--shiki-light"] ?? null;
        const dark = t.htmlStyle?.["--shiki-dark"] ?? null;
        return [t.content, light, dark, tokenColor(light, VIZ_LIGHT), tokenColor(dark, VIZ_DARK)];
      }),
    ),
  };
}

for (const fixture of fixtures) {
  const md = readFileSync(join(root, "fixtures", `${fixture.name}.md`), "utf8");
  const tree = parser.parse(prepare(md, fixture));
  const code = (await Promise.all(codeBlocks(tree).map(tokens))).filter(Boolean);
  const expected = { ast: normalize(tree), code };
  writeFileSync(join(root, "expected", `${fixture.name}.json`), JSON.stringify(expected, null, 2) + "\n");
  console.log(`wrote expected/${fixture.name}.json`);
}
