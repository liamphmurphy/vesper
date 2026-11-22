// Regression test: KnowledgePageEditorSlot in the macOS app hosts Designs, Slides, and legacy Docs
// via HostedWebPageView at /apps/designs/[id], /apps/slides/[id], and /apps/docs/[id].
// Because /knowledge/[id] is native-only (no web route), those three routes must render their
// editors directly instead of redirecting back to /knowledge/.
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import test from "node:test";

const web = new URL("..", import.meta.url).pathname;

const HOSTED_EDITORS = [
  { route: "app/(app)/apps/designs/[id]/page.tsx", component: "DesignEditor" },
  { route: "app/(app)/apps/slides/[id]/page.tsx", component: "DeckScreen" },
  { route: "app/(app)/apps/docs/[id]/page.tsx", component: "DocScreen" },
];

for (const { route, component } of HOSTED_EDITORS) {
  test(`${route} renders ${component} directly without redirecting to /knowledge`, () => {
    const src = readFileSync(join(web, route), "utf8");
    assert.match(src, new RegExp(`<${component}\\b`), `expected ${route} to render <${component}>`);
    assert.doesNotMatch(src, /CanvasPageRedirect|LegacyRedirect|redirect\(/, `${route} must not redirect to the native-only /knowledge route`);
  });
}
