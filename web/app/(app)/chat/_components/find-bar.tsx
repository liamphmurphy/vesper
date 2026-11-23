"use client";

import { useEffect, useMemo, useRef, useState } from "react";
import { findInThread, stepFindIndex, type ThreadFindMessage } from "@/lib/chat-find";
import { Icon } from "@/components/ui/icon";

/** Floating in-thread Find bar (Cmd/Ctrl+F): live match count, prev/next stepping, Esc to close. */
export function ThreadFindBar({
  messages,
  onJump,
  onClose,
}: {
  messages: readonly ThreadFindMessage[];
  onJump: (messageId: string) => void;
  onClose: () => void;
}) {
  const [query, setQuery] = useState("");
  const [index, setIndex] = useState(0);
  const inputRef = useRef<HTMLInputElement>(null);

  const hits = useMemo(() => findInThread(messages, query), [messages, query]);
  const safeIndex = hits.length > 0 ? Math.min(index, hits.length - 1) : -1;
  const activeHit = safeIndex >= 0 ? hits[safeIndex] : undefined;

  useEffect(() => {
    inputRef.current?.focus();
    inputRef.current?.select();
  }, []);

  useEffect(() => {
    if (activeHit) onJump(activeHit.messageId);
  }, [activeHit, onJump]);

  const step = (delta: number) => {
    const next = stepFindIndex(safeIndex, delta, hits.length);
    if (next >= 0) setIndex(next);
  };

  return (
    <div
      role="search"
      aria-label="Find in conversation"
      data-testid="thread-find-bar"
      className="motion-float absolute right-4 top-2 z-30 flex items-center gap-1.5 rounded-xl border border-border-float bg-surface-raised px-2.5 py-1.5 shadow-[var(--shadow-float)]"
    >
      <Icon name="search" size={13} className="text-fg-tertiary" />
      <input
        ref={inputRef}
        type="search"
        aria-label="Find in thread"
        value={query}
        placeholder="Find in thread…"
        onChange={(e) => {
          setQuery(e.target.value);
          setIndex(0);
        }}
        onKeyDown={(e) => {
          if (e.key === "Escape") {
            e.preventDefault();
            onClose();
          } else if (e.key === "Enter") {
            e.preventDefault();
            step(e.shiftKey ? -1 : 1);
          }
        }}
        className="h-6 w-48 bg-transparent text-13 text-fg placeholder:text-fg-tertiary outline-none"
      />
      {query.trim() && (
        <span data-testid="thread-find-count" className="min-w-[44px] text-right font-mono text-11 text-fg-tertiary">
          {hits.length > 0 ? `${safeIndex + 1} / ${hits.length}` : "0 / 0"}
        </span>
      )}
      <button
        type="button"
        aria-label="Previous match"
        title="Previous match (Shift+Enter)"
        disabled={hits.length === 0}
        onClick={() => step(-1)}
        className="grid size-6 place-items-center rounded-md text-fg-secondary hover:bg-hover hover:text-fg disabled:opacity-40"
      >
        <Icon name="chevronUp" size={12} />
      </button>
      <button
        type="button"
        aria-label="Next match"
        title="Next match (Enter)"
        disabled={hits.length === 0}
        onClick={() => step(1)}
        className="grid size-6 place-items-center rounded-md text-fg-secondary hover:bg-hover hover:text-fg disabled:opacity-40"
      >
        <Icon name="chev" size={12} />
      </button>
      <button
        type="button"
        aria-label="Close find"
        title="Close (Esc)"
        onClick={onClose}
        className="grid size-6 place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg"
      >
        <Icon name="x" size={12} />
      </button>
    </div>
  );
}
