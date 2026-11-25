import test from "node:test";
import assert from "node:assert/strict";
import { cleanHeadingTitle, formatDocumentTitle, routeFallbackTitle } from "./document-title.ts";

test("routeFallbackTitle resolves static and nested app routes", () => {
  assert.equal(routeFallbackTitle("/"), "Home");
  assert.equal(routeFallbackTitle("/dev"), "Dev workspace");
  assert.equal(routeFallbackTitle("/settings"), "Settings");
  assert.equal(routeFallbackTitle("/settings/runner"), "Runner environment");
  assert.equal(routeFallbackTitle("/chat/123"), "Chat");
  assert.equal(routeFallbackTitle("/spaces/abc"), "Spaces");
  assert.equal(routeFallbackTitle("/unknown"), "");
});

test("cleanHeadingTitle and formatDocumentTitle normalize titles", () => {
  assert.equal(cleanHeadingTitle("  Loading… "), "");
  assert.equal(cleanHeadingTitle("Vesper"), "");
  assert.equal(cleanHeadingTitle("  Dev   workspace \n"), "Dev workspace");
  assert.equal(formatDocumentTitle("Settings"), "Settings · Vesper");
  assert.equal(formatDocumentTitle("Foundations · Vesper"), "Foundations · Vesper");
  assert.equal(formatDocumentTitle(""), "Vesper");
});
