import test from "node:test";
import assert from "node:assert/strict";
import {
  decodeComposerDrop,
  encodeComposerDrop,
  makePanelSpec,
  parsePanelProps,
} from "./panel-events.ts";

test("makePanelSpec and parsePanelProps round-trip valid props and reject malformed JSON", () => {
  const spec = makePanelSpec("chat.playground", "chat.playground:c1", {
    tabId: "playground",
    chatId: "c1",
    initialTab: "preview",
  });
  assert.equal(spec.kind, "chat.playground");
  assert.equal(spec.key, "chat.playground:c1");
  assert.deepEqual(parsePanelProps(spec.propsJson), {
    tabId: "playground",
    chatId: "c1",
    initialTab: "preview",
  });
  assert.equal(parsePanelProps("{bad json"), null);
  assert.equal(parsePanelProps("[1,2,3]"), null);
  assert.equal(parsePanelProps("null"), null);
});

test("encodeComposerDrop and decodeComposerDrop round-trip text-only payloads", async () => {
  const json = await encodeComposerDrop("chat-42", { text: "Please inspect GET /api/v1/health" });
  const decoded = decodeComposerDrop(json);
  assert.ok(decoded);
  assert.equal(decoded.chatId, "chat-42");
  assert.equal(decoded.drop.text, "Please inspect GET /api/v1/health");
  assert.equal(decoded.drop.files, undefined);
});

test("encodeComposerDrop and decodeComposerDrop round-trip large binary File arrays without overflow", async () => {
  // > 64 KB exercises multiple base64 chunks across chunk boundaries.
  const size = 90_000;
  const raw = new Uint8Array(size);
  for (let i = 0; i < size; i += 1) raw[i] = (i * 31) & 0xff;
  const png = new File([raw], "playground-20261119.png", { type: "image/png" });
  const md = new File([new TextEncoder().encode("# Report\n\nOK")], "playground-20261119.md", {
    type: "text/markdown",
  });

  const json = await encodeComposerDrop("chat-99", { text: "See attached", files: [md, png] });
  const decoded = decodeComposerDrop(json);
  assert.ok(decoded);
  assert.equal(decoded.chatId, "chat-99");
  assert.equal(decoded.drop.text, "See attached");
  assert.equal(decoded.drop.files?.length, 2);

  const [outMd, outPng] = decoded.drop.files;
  assert.equal(outMd.name, "playground-20261119.md");
  assert.equal(outMd.type, "text/markdown");
  assert.equal(await outMd.text(), "# Report\n\nOK");

  assert.equal(outPng.name, "playground-20261119.png");
  assert.equal(outPng.type, "image/png");
  const outBytes = new Uint8Array(await outPng.arrayBuffer());
  assert.equal(outBytes.length, size);
  assert.deepEqual(outBytes, raw);
});

test("decodeComposerDrop rejects invalid or missing payloads", () => {
  assert.equal(decodeComposerDrop(undefined), null);
  assert.equal(decodeComposerDrop("{not json"), null);
  assert.equal(decodeComposerDrop(JSON.stringify({ text: "missing chatId" })), null);
});
