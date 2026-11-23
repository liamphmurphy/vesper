"use client";

import { useMemo, useState } from "react";
import type { Schemas } from "@/lib/api/client";
import { buildThreadOutline, filterOutline, outlineCounts, type OutlineCategory, type OutlineItem } from "@/lib/chat-outline";
import { Icon, type IconName } from "@/components/ui/icon";
import { cx } from "@/lib/cx";

const CATEGORIES: Array<{ id: OutlineCategory; label: string; icon: IconName }> = [
  { id: "all", label: "All", icon: "list" },
  { id: "bookmarks", label: "Pinned", icon: "bookmark" },
  { id: "links", label: "Links", icon: "link" },
  { id: "checklists", label: "Checklists", icon: "check" },
  { id: "code", label: "Diffs & Code", icon: "code" },
  { id: "files", label: "Files", icon: "artifacts" },
];

const ITEM_ICON: Record<OutlineItem["category"], IconName> = {
  bookmarks: "bookmark",
  links: "link",
  checklists: "check",
  code: "code",
  files: "artifacts",
};

/** Thread outline & artifact index drawer: jump directly to bookmarked messages, links, checklists, diffs, and files. */
export function OutlinePanel({
  messages,
  onJump,
  onClose,
}: {
  messages: Schemas["ChatMessage"][];
  onJump: (messageId: string) => void;
  onClose: () => void;
}) {
  const [category, setCategory] = useState<OutlineCategory>("all");
  const [query, setQuery] = useState("");
  const allItems = useMemo(() => buildThreadOutline(messages), [messages]);
  const counts = useMemo(() => outlineCounts(allItems), [allItems]);
  const visible = useMemo(() => filterOutline(allItems, category, query), [allItems, category, query]);

  return (
    <aside
      aria-label="Thread outline"
      data-testid="thread-outline-panel"
      className="flex h-full w-[min(320px,85vw)] flex-none flex-col border-l border-border-subtle bg-surface"
    >
      <div className="flex flex-none items-center justify-between gap-2 border-b border-border-subtle px-3 py-2">
        <div className="flex items-center gap-1.5">
          <Icon name="list" size={14} className="text-fg-secondary" />
          <span className="text-13 font-semibold text-fg">Thread outline</span>
          <span className="rounded-full bg-surface-sunken px-1.5 py-0.5 font-mono text-11 text-fg-tertiary">{allItems.length}</span>
        </div>
        <button
          type="button"
          aria-label="Close outline"
          onClick={onClose}
          className="grid size-7 place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg"
        >
          <Icon name="x" size={13} />
        </button>
      </div>

      <div className="flex flex-none flex-col gap-2 border-b border-border-subtle p-2.5">
        <input
          type="search"
          aria-label="Filter thread outline"
          value={query}
          onChange={(e) => setQuery(e.target.value)}
          placeholder="Filter links, pins, diffs, files…"
          className="h-7 w-full rounded-md border border-border bg-bg px-2 text-12 text-fg placeholder:text-fg-tertiary focus:border-accent focus:outline-none"
        />
        <div className="flex flex-wrap gap-1">
          {CATEGORIES.map((cat) => {
            const count = counts[cat.id];
            const active = category === cat.id;
            return (
              <button
                key={cat.id}
                type="button"
                aria-pressed={active}
                onClick={() => setCategory(cat.id)}
                className={cx(
                  "inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-11 font-medium transition-colors",
                  active
                    ? "border-accent bg-accent-soft text-accent"
                    : "border-border text-fg-secondary hover:bg-hover hover:text-fg",
                )}
              >
                <span>{cat.label}</span>
                {count > 0 && <span className="font-mono opacity-75">{count}</span>}
              </button>
            );
          })}
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto p-2">
        {visible.length === 0 ? (
          <p className="px-3 py-8 text-center text-12 text-fg-tertiary">
            {allItems.length === 0
              ? "Bookmarks, links, checklists, diffs, and files from this thread will appear here."
              : "No matching items in this thread."}
          </p>
        ) : (
          <ul className="flex flex-col gap-1">
            {visible.map((item) => (
              <li key={item.id}>
                <button
                  type="button"
                  onClick={() => onJump(item.messageId)}
                  className="group flex w-full items-start gap-2 rounded-lg px-2 py-1.5 text-left transition-colors hover:bg-hover"
                >
                  <Icon
                    name={ITEM_ICON[item.category]}
                    size={13}
                    className={cx(
                      "mt-0.5",
                      item.category === "bookmarks" ? "text-accent" : "text-fg-tertiary group-hover:text-fg-secondary",
                    )}
                  />
                  <span className="min-w-0 flex-1">
                    <span className="line-clamp-2 block text-12 font-medium text-fg">{item.title}</span>
                    {item.subtitle && (
                      <span className="mt-0.5 block truncate text-11 text-fg-tertiary">{item.subtitle}</span>
                    )}
                  </span>
                  {item.badge && (
                    <span className="flex-none rounded bg-surface-sunken px-1.5 py-0.5 font-mono text-11 text-fg-secondary">
                      {item.badge}
                    </span>
                  )}
                </button>
              </li>
            ))}
          </ul>
        )}
      </div>
    </aside>
  );
}
