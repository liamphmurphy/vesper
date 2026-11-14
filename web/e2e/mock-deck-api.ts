import type { Page } from "@playwright/test";
import { routeCanvasPage } from "./mock-canvas-pages";
import { installChatApi } from "./mock-chat-api";

// A mocked deck for the Slides editor specs (LAZYAGENTS-160): versions,
// saves (409 on a stale base) and marking a review done.

export const DECK = "99999999-9999-4999-8999-999999999160";
const at = "2026-11-12T12:00:00Z";
const theme = { name: "Light", fonts: { heading: "sans", body: "sans" }, colors: { background: "#FFFFFF", text: "#1F2328", heading: "#111418", accent: "#3B6FE0", accent2: "#E8A33D", muted: "#6B7280", surface: "#F3F5F9" } };
const title = (text: string) => ({ id: "e_title", type: "text", frame: { x: 160, y: 400, w: 1600, h: 200 }, paragraphs: [{ runs: [{ text, size: 72, font: "heading", color: "heading" }] }] });
export const deckWith = (text: string) => ({ schema: 1, size: { w: 1920, h: 1080 }, theme, assets: {}, slides: [{ id: "s_one", layout: "blank", elements: [title(text)] }, { id: "s_two", layout: "blank", elements: [] }] });

export type Version = { seq: number; body: string; author: "user" | "agent" };

/** A deck whose versions are `versions`; with an agent version last, it opens in review. */
export async function installDeck(page: Page, versions: Version[]) {
  await installChatApi(page, { replyDelayMs: 10 });
  await page.goto("/apps/slides");
  const chat = await page.evaluate(() => fetch("/api/v1/chats", { method: "POST", headers: { "content-type": "application/json" }, body: "{}" }).then((r) => r.json()));
  const s = { versions, reviewed: [] as number[], reviewedSeq: 0 };
  const head = () => s.versions[s.versions.length - 1];
  const json = (route: Parameters<Parameters<Page["route"]>[1]>[0], data: unknown, status = 200) => route.fulfill({ status, contentType: "application/json", body: JSON.stringify(data) });
  await page.route(new RegExp(`/api/v1/canvases/${DECK}$`), (route) => json(route, { id: DECK, kind: "deck", title: "Layout", chat_id: chat.id, chat_title: "Layout", updated_at: at, reviewed_seq: s.reviewedSeq }));
  await page.route(new RegExp(`/api/v1/docs/${DECK}/reviewed$`), (route) => {
    s.reviewedSeq = route.request().postDataJSON().seq;
    s.reviewed.push(s.reviewedSeq);
    return json(route, { reviewed_seq: s.reviewedSeq });
  });
  await page.route(new RegExp(`/api/v1/chats/[^/]+/canvases/${DECK}(/|\\?|$)`), (route) => {
    const req = route.request();
    const url = new URL(req.url());
    if (url.pathname.endsWith("/comments")) return json(route, { comments: [] });
    if (url.pathname.endsWith("/versions")) {
      const body = req.postDataJSON();
      if (body.base_seq !== head().seq) return json(route, { code: "conflict", message: "conflict" }, 409);
      s.versions.push({ seq: head().seq + 1, body: body.body, author: "user" });
      return json(route, { seq: head().seq, note: body.note, author_type: "user", created_at: at }, 201);
    }
    const seq = Number(url.searchParams.get("seq") ?? head().seq);
    const v = s.versions.find((x) => x.seq === seq) ?? head();
    return json(route, {
      id: DECK, kind: "deck", title: "Layout", seq: head().seq, viewing_seq: v.seq, created_at: at, updated_at: at, body: v.body,
      versions: [...s.versions].reverse().map((x) => ({ seq: x.seq, note: "Edited", author_type: x.author, created_at: at })),
    });
  });
  await routeCanvasPage(page, { id: DECK, kind: "deck", title: "Layout" });
  await page.goto(`/apps/slides/${DECK}`);
  return s;
}

