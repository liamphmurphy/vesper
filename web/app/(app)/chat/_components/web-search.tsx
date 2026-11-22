"use client";

import { useMemo } from "react";
import { useChatTurnEvents } from "@/lib/api/hooks";
import { webSearches } from "@/lib/web-search";
import { Icon } from "@/components/ui/icon";

/** "Searched the web · N sources" under a reply; expands to the queries and sources (mockup frame 3b). */
export function WebSearchPill({ runId, since, until }: { runId?: string; since?: string; until?: string }) {
  const q = useChatTurnEvents(runId, since, until);
  const r = useMemo(() => webSearches(q.data, since, until), [q.data, since, until]);
  if (r.queries.length === 0 && r.sources.length === 0) return null;
  const n = r.sources.length;
  return (
    <details data-testid="web-search" className="group w-full max-w-[min(720px,100%)] rounded-lg border border-border bg-surface text-13">
      <summary className="flex cursor-pointer list-none items-center gap-2 px-3 py-1.5 text-fg-secondary">
        <Icon name="search" size={14} className="text-fg-tertiary" />
        <span>
          Searched the web
          {n > 0 && ` · ${n} ${n === 1 ? "source" : "sources"}`}
        </span>
        <Icon name="chev" size={12} className="text-fg-tertiary transition-transform group-open:rotate-180" />
      </summary>
      <div className="flex flex-col gap-2 border-t border-border-subtle px-3 py-2">
        {r.queries.length > 0 && (
          <div>
            <p className="mb-1 text-12 font-semibold uppercase tracking-wide text-fg-tertiary">Queries</p>
            <ul className="flex flex-col gap-0.5">
              {r.queries.map((x) => (
                <li key={x} data-testid="web-query" className="flex items-center gap-2 text-fg">
                  <Icon name="search" size={12} className="flex-none text-fg-tertiary" />
                  <span className="min-w-0 truncate">{x}</span>
                </li>
              ))}
            </ul>
          </div>
        )}
        {n > 0 && (
          <div>
            <p className="mb-1 text-12 font-semibold uppercase tracking-wide text-fg-tertiary">Sources</p>
            <ul className="flex flex-col gap-0.5">
              {r.sources.map((s) => (
                <li key={s.url} data-testid="web-source" className="flex items-baseline gap-3">
                  <a href={s.url} target="_blank" rel="noopener noreferrer" className="min-w-0 flex-1 truncate text-accent hover:underline">
                    {s.title}
                  </a>
                  <span className="flex-none text-12 text-fg-tertiary">{s.host}</span>
                </li>
              ))}
            </ul>
          </div>
        )}
      </div>
    </details>
  );
}
