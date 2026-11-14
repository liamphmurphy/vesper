/**
 * Drafting a deck from an outline (LAZYAGENTS-123). The New deck chooser
 * sends the outline to the deck's persona as one chat message; the persona
 * adds slides with canvas_patch, and they arrive as per-slide suggestions in
 * the deck's review, like any persona edit. The opening words are what the
 * fake harness (server/cmd/fake-harness) recognises; keep them in step.
 */
export const OUTLINE_PROMPT = "Draft slides from this outline";

/** The chat message that asks the persona to draft slides from an outline. */
export const outlinePrompt = (outline: string) =>
  `${OUTLINE_PROMPT}: one slide per top-level line, its indented lines as that slide's points, added after the slides already in the deck. Pick the deck's layouts that suit each slide and keep to its theme.\n\n${outline.trim()}`;
