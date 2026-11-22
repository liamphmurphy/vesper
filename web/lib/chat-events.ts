// Windowed event selection for chat segment runs. Kept free of React so `npm run test:unit` covers it.

export type WindowedRunEvent = {
  seq: number;
  type: string;
  at: string;
  payload: Record<string, unknown>;
};

/**
 * Returns a stateful selector for TanStack Query's `select` option that extracts only
 * the events relevant to a single turn's `[since, until]` window and preserves the
 * previous array reference whenever newly appended events fall outside that window.
 *
 * Includes:
 * - all events with `lo <= at <= hi`
 * - any `tool_result` whose `payload.id` matches a `tool_call` in `[lo, hi]`
 *   (so `webSearches` still pairs results landing after `until`)
 * - any earlier `tool_call` whose `payload.id` matches a `tool_result` in `[lo, hi]`
 *   (so `memoryNotices` still resolves tool names omitted on the result)
 */
export function createEventWindowSelector<E extends WindowedRunEvent>(
  since?: string,
  until?: string,
): (events: E[]) => E[] {
  const lo = since ? Date.parse(since) : -Infinity;
  const hi = until ? Date.parse(until) : Infinity;

  let prevEvents: readonly E[] | undefined;
  let prevLen = 0;
  let prevLast: E | undefined;
  let prevSlice: E[] = [];
  let windowCallIds = new Set<string>();

  const fullScan = (events: E[]): E[] => {
    const calls = new Set<string>();
    const earlierCallById = new Map<string, E>();
    const needEarlierIds = new Set<string>();
    const matched: E[] = [];

    for (const e of events) {
      const at = Date.parse(e.at);
      const id = e.payload.id != null ? String(e.payload.id) : undefined;
      if (at < lo) {
        if (e.type === "tool_call" && id !== undefined) earlierCallById.set(id, e);
        continue;
      }
      if (at <= hi) {
        if (e.type === "tool_call" && id !== undefined) calls.add(id);
        else if (e.type === "tool_result" && id !== undefined && !calls.has(id)) needEarlierIds.add(id);
        matched.push(e);
        continue;
      }
      // Event after `hi`: include only if it answers a tool_call inside the window.
      if (e.type === "tool_result" && id !== undefined && calls.has(id)) {
        matched.push(e);
      }
    }

    let nextSlice = matched;
    if (needEarlierIds.size > 0) {
      const prefix: E[] = [];
      for (const id of needEarlierIds) {
        const call = earlierCallById.get(id);
        if (call) prefix.push(call);
      }
      if (prefix.length > 0) {
        prefix.sort((a, b) => a.seq - b.seq);
        nextSlice = [...prefix, ...matched];
      }
    }

    windowCallIds = calls;
    prevEvents = events;
    prevLen = events.length;
    prevLast = events[events.length - 1];

    if (nextSlice.length === prevSlice.length && nextSlice.every((e, i) => e === prevSlice[i])) {
      return prevSlice;
    }
    prevSlice = nextSlice;
    return prevSlice;
  };

  return (events: E[]): E[] => {
    if (events === prevEvents) return prevSlice;

    // Fast path: `eventsAfter` strictly appends in-order polls, so checking
    // `events[prevLen - 1] === prevLast` guarantees no elements were inserted earlier.
    const isAppend =
      prevEvents !== undefined &&
      events.length > prevLen &&
      (prevLen === 0 || (events[0] === prevEvents[0] && events[prevLen - 1] === prevLast));

    if (!isAppend) return fullScan(events);

    let added: E[] | undefined;
    for (let i = prevLen; i < events.length; i++) {
      const e = events[i];
      const at = Date.parse(e.at);
      const id = e.payload.id != null ? String(e.payload.id) : undefined;
      if (at >= lo && at <= hi) {
        if (e.type === "tool_call" && id !== undefined) windowCallIds.add(id);
        else if (e.type === "tool_result" && id !== undefined && !windowCallIds.has(id)) {
          return fullScan(events);
        }
        (added ??= []).push(e);
      } else if (at > hi && e.type === "tool_result" && id !== undefined && windowCallIds.has(id)) {
        (added ??= []).push(e);
      }
    }

    prevEvents = events;
    prevLen = events.length;
    prevLast = events[events.length - 1];

    if (!added) return prevSlice;
    prevSlice = [...prevSlice, ...added];
    return prevSlice;
  };
}
