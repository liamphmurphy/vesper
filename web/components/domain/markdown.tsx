"use client";

import { createContext, isValidElement, useContext, useMemo, type ReactNode } from "react";
import ReactMarkdown, { defaultUrlTransform, type Components, type Options } from "react-markdown";
import rehypeKatex from "rehype-katex";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import "katex/dist/katex.min.css";
import type { LinkTarget } from "@/lib/api/client";
import { useResolvedLinks } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { headingAnchors } from "@/lib/slug";
import { linkify, parseWikiLinks, WIKILINK_SCHEME } from "@/lib/wikilinks";
import { rehypeSlots, rehypeSourceSpans, SLOT_CLASS, type Slot } from "@/lib/canvas-source";
import { usePrintMode } from "./print-mode";
import { visualFence } from "./visuals";
import { LinkTargets, WikiLink } from "./wikilink";

const urlTransform = (url: string) => (url.startsWith(WIKILINK_SCHEME) ? url : defaultUrlTransform(url));
// Tables, task lists, strikethrough and bare-URL links.
// Math needs $$: a single dollar is far more often a price.
const remarkPlugins: Options["remarkPlugins"] = [remarkGfm, [remarkMath, { singleDollarTextMath: false }]];
const rehypePlugins: Options["rehypePlugins"] = [rehypeKatex];

/** Draws what belongs in a slot; see the slots prop. */
export const MarkdownSlots = createContext<((id: string) => ReactNode) | null>(null);

function SlotContent({ id }: { id: string }) {
  return useContext(MarkdownSlots)?.(id) ?? null;
}

/**
 * Renders user and agent markdown. react-markdown escapes raw HTML by
 * default, so agent-written content can't inject markup.
 */
export function Markdown({ children, className, anchors, visualBlocks, sourceSpans, slots }: { children: string; className?: string; anchors?: boolean; visualBlocks?: boolean; sourceSpans?: boolean; slots?: Slot[] }) {
  const print = usePrintMode();
  // Heading ids come from source lines, so they match the API's outline
  // anchors and stay stable across re-renders.
  const ids = useMemo(() => (anchors ? headingAnchors(children) : undefined), [anchors, children]);
  // [[links]] become wikilink: links, resolved in one request per body.
  // With sourceSpans the text is parsed as written, so positions match its source.
  const refs = useMemo(() => (sourceSpans ? [] : parseWikiLinks(children).map((r) => r.ref)), [children, sourceSpans]);
  const md = useMemo(() => (refs.length ? linkify(children) : children), [children, refs.length]);
  const resolved = useResolvedLinks(print ? [] : refs);
  const targets = useMemo(() => {
    const m = new Map<string, LinkTarget>();
    for (const l of resolved.data ?? []) m.set(l.ref, l.target);
    return m;
  }, [resolved.data]);
  // Memoized so each element keeps its component identity across re-renders:
  // a new renderer would remount its subtree, resetting a running app or an expanded fence.
  // Slots first: they read block positions, which the span wrapper leaves alone.
  const sourcePlugins = useMemo<Options["rehypePlugins"]>(() => (sourceSpans ? [rehypeKatex, [rehypeSlots, slots ?? []], rehypeSourceSpans] : undefined), [sourceSpans, slots]);
  const components = useMemo<Components>(() => {
    const idOf = (node: { position?: { start: { line: number } } } | undefined) =>
      ids && node?.position ? ids.get(node.position.start.line) : undefined;
    const headings: Components = {
      h1: ({ children, node }) => <h2 id={idOf(node)} className="type-title mt-4 scroll-mt-6">{children}</h2>,
      h2: ({ children, node }) => <h3 id={idOf(node)} className="type-heading mt-4 scroll-mt-6">{children}</h3>,
      h3: ({ children, node }) => <h4 id={idOf(node)} className="mt-2 scroll-mt-6 font-semibold">{children}</h4>,
      h4: ({ children, node }) => <h5 id={idOf(node)} className="mt-2 scroll-mt-6 font-semibold">{children}</h5>,
    };
    return {
      p: ({ children }) => <p>{children}</p>,
      div: ({ children, className }) => className?.startsWith(SLOT_CLASS) ? <SlotContent id={className.slice(SLOT_CLASS.length)} /> : <div className={className}>{children}</div>,
      // Task lists show their checkboxes in place of bullets.
      ul: ({ children, className }) => <ul className={className?.includes("contains-task-list") ? "ml-1 list-none space-y-1 [&_input]:mr-2 [&_input]:align-middle" : "ml-5 list-disc space-y-1"}>{children}</ul>,
      ol: ({ children }) => <ol className="ml-5 list-decimal space-y-1">{children}</ol>,
      blockquote: ({ children }) => <blockquote className="flex flex-col gap-2 border-l-2 border-border-strong pl-3 text-fg-secondary">{children}</blockquote>,
      hr: () => <hr className="my-1 border-border" />,
      // Wide tables scroll inside their own frame, not the whole message.
      table: ({ children }) => (
        <div className="max-w-full overflow-x-auto rounded-lg border border-border">
          <table className="w-full border-collapse text-left text-[0.92em]">{children}</table>
        </div>
      ),
      thead: ({ children }) => <thead className="bg-surface-sunken">{children}</thead>,
      tr: ({ children }) => <tr className="border-b border-border-row last:border-b-0 [thead_&]:border-border">{children}</tr>,
      // style carries the column alignment from the delimiter row.
      th: ({ children, style }) => <th style={style} className="px-3 py-2 align-bottom font-semibold">{children}</th>,
      td: ({ children, style }) => <td style={style} className="px-3 py-2 align-top">{children}</td>,
      ...(anchors
        ? headings
        : {
            h1: ({ children }) => <h3 className="type-heading mt-2">{children}</h3>,
            h2: ({ children }) => <h3 className="type-heading mt-2">{children}</h3>,
            h3: ({ children }) => <h4 className="mt-1 font-semibold">{children}</h4>,
          }),
      pre: ({ children }) => {
        const code = visualBlocks && isValidElement<{ className?: string; children?: ReactNode }>(children) ? children.props : undefined;
        if (code && typeof code.children === "string") {
          const info = /language-(\S+)/.exec(code.className ?? "")?.[1];
          const visual = visualFence(info, code.children);
          if (visual) return visual;
        }
        return (
        <pre className="overflow-x-auto rounded-lg border border-border bg-surface-sunken p-3 font-mono text-12 leading-relaxed [&_code]:border-0 [&_code]:bg-transparent [&_code]:p-0">
          {children}
        </pre>
        );
      },
      a: ({ href, children }) =>
        href?.startsWith(WIKILINK_SCHEME) ? (
          <WikiLink refText={decodeURIComponent(href.slice(WIKILINK_SCHEME.length))}>{children}</WikiLink>
        ) : href?.startsWith("#") ? (
          <a href={href}>{children}</a>
        ) : (
          <a href={href} target="_blank" rel="noreferrer noopener">
            {children}
          </a>
        ),
    };
  }, [anchors, visualBlocks, ids]);
  return (
    <LinkTargets.Provider value={targets}>
    <div className={cx("prose-code flex flex-col gap-2.5 [&_a]:text-accent [&_a]:underline-offset-2 hover:[&_a]:underline", className)}>
      <ReactMarkdown remarkPlugins={remarkPlugins} rehypePlugins={sourcePlugins ?? rehypePlugins} urlTransform={urlTransform} components={components}>
        {md}
      </ReactMarkdown>
    </div>
    </LinkTargets.Provider>
  );
}
