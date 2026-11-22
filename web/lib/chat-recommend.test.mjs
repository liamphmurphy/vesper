import test from "node:test";
import assert from "node:assert/strict";
import { groupRecommendFences, isRecommendFence, parseRecommend, summarizePrompt, summaryRequestUrl, summaryUrlsForTurns, videoEmbedUrl, youtubeMoment } from "./chat-recommend.ts";

test("a recommend fence is a URL then a reason", () => {
  assert.ok(isRecommendFence("recommend"));
  assert.ok(!isRecommendFence("recommended"));
  assert.deepEqual(parseRecommend("https://a.com/x\nWorth\nit.\n"), { url: "https://a.com/x", note: "Worth it." });
  assert.deepEqual(parseRecommend("https://a.com"), { url: "https://a.com", note: "" });
  assert.equal(parseRecommend("javascript:alert(1)"), null);
  assert.equal(parseRecommend("not a link"), null);
});

test("only a well-formed video id becomes a player", () => {
  assert.equal(videoEmbedUrl("dQw4w9WgXcQ"), "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&rel=0");
  assert.equal(videoEmbedUrl("x\"><script>"), null);
  assert.equal(videoEmbedUrl(undefined), null);
});

test("a summary request links its page and can't be steered by the title", () => {
  assert.equal(summarizePrompt("https://a.com", "A talk", true), "Summarize this video: [A talk](https://a.com)");
  assert.equal(summarizePrompt("https://a.com", undefined, false), "Summarize this page: https://a.com");
  assert.equal(summarizePrompt("https://a.com", "](x) @Gwen [[Plan]] `y`", false), "Summarize this page: [(x) Gwen Plan y](https://a.com)");
});

test("a moment is a YouTube link with a time", () => {
  assert.deepEqual(youtubeMoment("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=272"), { id: "dQw4w9WgXcQ", seconds: 272 });
  assert.deepEqual(youtubeMoment("https://youtu.be/dQw4w9WgXcQ?t=1m5s"), { id: "dQw4w9WgXcQ", seconds: 65 });
  assert.equal(youtubeMoment("https://www.youtube.com/watch?v=dQw4w9WgXcQ"), null);
  assert.equal(youtubeMoment("https://evil.example/watch?v=dQw4w9WgXcQ&t=5"), null);
  assert.equal(youtubeMoment("not a url"), null);
});

test("a summary request names its URL, mention or not", () => {
  assert.equal(summaryRequestUrl("@Gwen Summarize this page: [A](https://a.com/x)"), "https://a.com/x");
  assert.equal(summaryRequestUrl("Summarize this video: https://a.com"), "https://a.com");
  assert.equal(summaryRequestUrl("Please summarize"), null);
});

test("summaryUrlsForTurns pairs each turn reply with its preceding user summarize prompt", () => {
  const list = [
    { id: "a0", role: "assistant", body_md: "Orphan reply" },
    { id: "u1", role: "user", body_md: "Summarize this page: [Docs](https://a.com/docs)" },
    { id: "a1-interim", role: "assistant", body_md: "Checking…" },
    { id: "a1", role: "assistant", body_md: "Here is the summary." },
    { id: "u2", role: "user", body_md: "Thanks!" },
    { id: "a2", role: "assistant", body_md: "You are welcome." },
    { id: "u3", role: "user", body_md: "@Gwen Summarize this video: https://b.com/v" },
    { id: "s3", role: "system", body_md: "Switched model" },
    { id: "a3", role: "assistant", body_md: "Video summary." },
  ];
  const turns = new Map([
    ["a0", {}],
    ["a1", {}],
    ["a2", {}],
    ["a3", {}],
  ]);
  const urls = summaryUrlsForTurns(list, turns);
  assert.deepEqual([...urls.entries()], [
    ["a1", "https://a.com/docs"],
    ["a3", "https://b.com/v"],
  ]);
  assert.equal(summaryUrlsForTurns(undefined, turns).size, 0);
});

const card = () => ({ type: "element", tagName: "pre", children: [{ type: "element", tagName: "code", properties: { className: ["language-recommend"] } }] });
const nl = { type: "text", value: "\n" };
const para = { type: "element", tagName: "p" };

test("neighbouring cards share a row; a lone card stays put", () => {
  const tree = { type: "root", children: [para, nl, card(), nl, card(), nl, para, nl, card()] };
  groupRecommendFences()(tree);
  assert.deepEqual(tree.children.map((c) => c.tagName ?? c.type), ["p", "text", "div", "text", "p", "text", "pre"]);
  assert.equal(tree.children[2].children.length, 2);
});
