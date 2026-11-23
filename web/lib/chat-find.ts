// Pure in-thread find across chat messages (components: app/(app)/chat/_components/find-bar.tsx).
// Kept free of React so `npm run test:unit` covers it.

export type ThreadFindHit = {
  messageId: string;
  occurrence: number;
  snippet: string;
};

export type ThreadFindMessage = {
  id: string;
  role: string;
  body_md: string;
};

/**
 * Finds all case-insensitive occurrences of `query` across non-system messages
 * in transcript order, returning one hit per occurrence with a short snippet.
 */
export function findInThread(messages: readonly ThreadFindMessage[], query: string): ThreadFindHit[] {
  const q = query.trim().toLowerCase();
  if (!q) return [];
  const hits: ThreadFindHit[] = [];
  for (const m of messages) {
    if (m.role === "system") continue;
    const raw = m.body_md;
    const lower = raw.toLowerCase();
    let from = 0;
    let occ = 0;
    while (from < lower.length) {
      const idx = lower.indexOf(q, from);
      if (idx < 0) break;
      const start = Math.max(0, idx - 28);
      const end = Math.min(raw.length, idx + q.length + 42);
      const prefix = start > 0 ? "…" : "";
      const suffix = end < raw.length ? "…" : "";
      const snippet = `${prefix}${raw.slice(start, end).replace(/\s+/g, " ").trim()}${suffix}`;
      hits.push({ messageId: m.id, occurrence: occ++, snippet });
      from = idx + q.length;
    }
  }
  return hits;
}

/** Wraps an index cleanly around `total` (returns -1 when total === 0). */
export function stepFindIndex(current: number, delta: number, total: number): number {
  if (total <= 0) return -1;
  if (current < 0 || current >= total) return delta >= 0 ? 0 : total - 1;
  return (current + delta + total) % total;
}
