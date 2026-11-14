// What a design's card in a chat says about it. Pure, so it's unit-tested.
import type { Design } from "./schema.ts";

/** The Design card's line in a chat (docs/design/designs-from-chat.svg): "4 frames · 3 links · 1 sticky · Flows". */
export function designCounts(d: Design): string {
  const nodes = d.pages.flatMap((p) => p.children);
  const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`;
  const frames = nodes.filter((n) => n.type === "frame").length;
  const stickies = nodes.filter((n) => n.type === "sticky").length;
  const parts = [count(frames, "frame", "frames")];
  if (d.links.length) parts.push(count(d.links.length, "link", "links"));
  if (stickies) parts.push(count(stickies, "sticky", "stickies"));
  if (d.pages.length > 1) parts.push(count(d.pages.length, "page", "pages"));
  else if (d.pages[0]) parts.push(d.pages[0].name);
  return parts.join(" · ");
}
