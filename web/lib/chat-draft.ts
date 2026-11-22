// External draft store and textarea height sizing for the chat composer.
// Keeping draft state outside Conversation lets keystrokes re-render only
// the composer subtree instead of the whole transcript. Kept free of React
// so `npm run test:unit` covers it.

export type DraftStore = {
  get: () => string;
  hasText: () => boolean;
  set: (next: string | ((prev: string) => string)) => void;
  subscribe: (listener: () => void) => () => void;
};

/** Small synchronous store for a chat's unsent draft text. */
export function createDraftStore(initial = ""): DraftStore {
  let value = initial;
  const listeners = new Set<() => void>();
  return {
    get: () => value,
    hasText: () => value.trim().length > 0,
    set: (next) => {
      const resolved = typeof next === "function" ? next(value) : next;
      if (resolved === value) return;
      value = resolved;
      for (const listener of listeners) listener();
    },
    subscribe: (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  };
}

export type TextareaLike = {
  value: string;
  scrollHeight: number;
  clientHeight: number;
  style: { height: string };
};

export type TextareaHeightState = {
  baseHeight: number;
  height: number;
  text: string;
};

export const COMPOSER_MAX_HEIGHT = 220;

export function createTextareaHeightState(): TextareaHeightState {
  return { baseHeight: 0, height: 0, text: "" };
}

/**
 * Keeps an auto-growing textarea sized to its content without forcing a
 * `height = "auto"` collapse/reflow on every keystroke.
 *
 * - Normal typing within the current box height writes no styles.
 * - Growing (wrapping or newlines) expands directly to `min(scrollHeight + 2, maxHeight)`.
 * - Deleting or replacing with shorter/equal text while taller than one line
 *   collapses to `"auto"` once to measure the shrunk height.
 */
export function syncTextareaHeight(
  el: TextareaLike,
  state: TextareaHeightState,
  maxHeight = COMPOSER_MAX_HEIGHT,
): boolean {
  const value = el.value;
  const apply = (next: number) => {
    const clamped = Math.min(next, maxHeight);
    if (clamped !== state.height) {
      el.style.height = `${clamped}px`;
      state.height = clamped;
      return true;
    }
    return false;
  };

  if (state.height === 0) {
    el.style.height = "auto";
    if (el.scrollHeight === 0) return false;
    const measured = Math.min(el.scrollHeight + 2, maxHeight);
    if (value === "") state.baseHeight = measured;
    el.style.height = `${measured}px`;
    state.height = measured;
    state.text = value;
    return true;
  }

  if (value === "") {
    state.text = "";
    if (state.baseHeight > 0) return apply(state.baseHeight);
    el.style.height = "auto";
    if (el.scrollHeight === 0) return false;
    const measured = Math.min(el.scrollHeight + 2, maxHeight);
    state.baseHeight = measured;
    el.style.height = `${measured}px`;
    state.height = measured;
    return true;
  }

  const prevText = state.text;
  state.text = value;

  // Growing never needs `height = "auto"`: scrollHeight already exceeds clientHeight.
  if (el.scrollHeight > el.clientHeight) {
    if (state.height < maxHeight) return apply(el.scrollHeight + 2);
    return false;
  }

  // Only collapse to "auto" when taller than one line and content may have shrunk.
  const tallerThanBase = state.baseHeight === 0 || state.height > state.baseHeight;
  if (tallerThanBase && value.length <= prevText.length) {
    el.style.height = "auto";
    const measured = Math.min(el.scrollHeight + 2, maxHeight);
    el.style.height = `${measured}px`;
    const changed = measured !== state.height;
    state.height = measured;
    return changed;
  }

  return false;
}
