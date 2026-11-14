import type { Page } from "@playwright/test";

/**
 * Every deck and design is a Knowledge page (LAZYAGENTS-212): its old /apps address finds the page
 * (GET /wiki/canvas-pages/<canvas>) and Knowledge opens the page, which is the editor. This serves
 * both for one deck or design, so a spec that opens /apps/slides/<id> or /apps/designs/<id> lands in
 * its editor inside Knowledge.
 */
export async function routeCanvasPage(page: Page, c: { id: string; kind: "deck" | "design"; title: string; chatId?: string }) {
  // A page id of its own (a UUID, as Knowledge's tabs expect), derived from the canvas's.
  const pageId = `${c.id[0] === "a" ? "b" : "a"}${c.id.slice(1)}`;
  const path = `${c.kind === "deck" ? "Slides" : "Designs"}/${c.title}`;
  const body = {
    id: pageId, title: c.title, path, audience: "private", kind: c.kind, canvas_id: c.id, body_md: "", version_id: "v1", seq: 1,
    properties: {}, direct: false, paused: false, chat_id: c.chatId ?? null, url: `/knowledge/${pageId}`, embeds: [], reviews: [], versions: [],
  };
  await page.route(`**/api/v1/wiki/canvas-pages/${c.id}`, (route) => route.fulfill({ json: { id: pageId, path, title: c.title } }));
  await page.route(`**/api/v1/knowledge/pages/${pageId}`, (route) => route.fulfill({ json: body }));
  return pageId;
}
