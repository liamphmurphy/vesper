"use client";

import { useState } from "react";
import { langFromFence } from "@/lib/code-diff";
import { useHighlighted } from "@/lib/highlight";
import { Icon } from "@/components/ui/icon";

export const FENCE_COLLAPSE_LINES = 20;

/** A fenced code block in chat markdown: sticky header with language, line count, Expand/Collapse, Copy, and lazy highlighting. */
export function CodeFence({ code, info }: { code: string; info?: string }) {
  const lines = code.replace(/\n$/, "").split("\n");
  const lang = langFromFence(info);
  const label = info?.trim().split(/\s+/)[0] || "text";
  const [expanded, setExpanded] = useState(false);
  const [copied, setCopied] = useState(false);
  const long = lines.length > FENCE_COLLAPSE_LINES;
  const shown = long && !expanded ? lines.slice(0, FENCE_COLLAPSE_LINES) : lines;
  const toks = useHighlighted([shown], lang, true)?.[0];
  return (
    <div className="rounded-lg border border-border bg-surface-sunken" data-testid="code-fence">
      <div className="sticky top-0 z-10 flex items-center justify-between gap-2 rounded-t-lg border-b border-border-row bg-surface-sunken/95 px-3 py-1.5 text-12 text-fg-tertiary backdrop-blur-xs">
        <div className="flex items-center gap-2">
          <span className="font-mono font-medium text-fg-secondary">{label}</span>
          <span className="font-mono text-11 opacity-80">{lines.length} {lines.length === 1 ? "line" : "lines"}</span>
        </div>
        <div className="flex items-center gap-2">
          {long && (
            <button
              type="button"
              aria-expanded={expanded}
              className="flex items-center gap-1 rounded px-1.5 py-0.5 text-12 text-fg-secondary hover:bg-hover hover:text-fg"
              onClick={() => setExpanded((e) => !e)}
            >
              <Icon name={expanded ? "shrink" : "expand"} size={12} />
              {expanded ? "Collapse" : `Expand (${lines.length})`}
            </button>
          )}
          <button
            type="button"
            className="flex items-center gap-1 rounded px-1.5 py-0.5 hover:bg-hover hover:text-fg"
            onClick={() => {
              void navigator.clipboard?.writeText(lines.join("\n")).then(() => {
                setCopied(true);
                setTimeout(() => setCopied(false), 1500);
              });
            }}
          >
            <Icon name={copied ? "check" : "link"} size={12} />
            {copied ? "Copied" : "Copy"}
          </button>
        </div>
      </div>
      <pre className="overflow-x-auto p-3 font-mono text-12 leading-relaxed">
        {/* Not an inline chip: reset the .prose-code `code` styles (border, background, padding, size, colour),
            which otherwise draw as empty pills around the first and last lines. */}
        <code className="block rounded-none border-0 bg-transparent p-0 text-[length:inherit] text-fg">
          {shown.map((l, i) => (
            <span key={i} className="block whitespace-pre">
              {toks?.[i]
                ? toks[i].map((t, j) => (
                    <span key={j} className="shiki-tok" style={t.style}>
                      {t.content}
                    </span>
                  ))
                : l}
              {l === "" && " "}
            </span>
          ))}
        </code>
      </pre>
      {long && (
        <button
          type="button"
          aria-expanded={expanded}
          className="w-full rounded-b-lg border-t border-border-row px-3 py-1 text-left text-12 text-fg-secondary hover:bg-hover hover:text-fg"
          onClick={() => setExpanded((e) => !e)}
        >
          {expanded ? "Collapse code block" : `Show ${lines.length - FENCE_COLLAPSE_LINES} more lines`}
        </button>
      )}
    </div>
  );
}
