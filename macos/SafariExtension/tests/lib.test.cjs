// node --test macos/SafariExtension/tests (make -C macos safari-test)
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const ext = require("../Resources/lib.js");

const lists = { builtin: ["1password.com", "accounts.google.com"], mine: ["chase.com"] };

test("never-share sites, private windows and non-web pages can't be shared", () => {
  for (const [url, incognito] of [
    ["https://my.1password.com/vaults", false],
    ["https://accounts.google.com/signin", false],
    ["https://secure.chase.com/accounts", false],
    ["https://www.chase.com/", false],
    ["https://example.com/", true],
    ["file:///Users/liam/notes.txt", false],
    ["safari-web-extension://abc/popup.html", false],
    ["https://user:pw@example.com/", false],
  ]) {
    assert.equal(ext.shareablePage(url, incognito, lists).ok, false, url);
  }
  assert.equal(ext.shareablePage("https://secure.chase.com/", false, lists).mine, true);
  for (const url of ["https://github.com/o/r/pull/1", "https://notchase.com/", "http://localhost:3000/"]) {
    assert.equal(ext.shareablePage(url, false, lists).ok, true, url);
  }
});

test("normalizeHost matches the server's", () => {
  assert.equal(ext.normalizeHost("https://www.Chase.com/login"), "chase.com");
  assert.equal(ext.normalizeHost("bank.example:8443"), "bank.example");
  assert.equal(ext.normalizeHost("evil.com/path"), null);
  assert.equal(ext.normalizeHost("  "), null);
});

test("an in-page anchor is the same page; anything else isn't", () => {
  assert.equal(ext.samePage("https://a.com/doc?id=1", "https://a.com/doc?id=1#s2"), true);
  assert.equal(ext.samePage("https://a.com/doc?id=1", "https://a.com/doc?id=2"), false);
});

test("card numbers are removed, other long numbers kept", () => {
  assert.equal(ext.redactCardNumbers("Card 4111 1111 1111 1111 exp 12/29"), "Card [card number removed] exp 12/29");
  assert.equal(ext.redactCardNumbers("pay 4111-1111-1111-1111."), "pay [card number removed].");
  // Fails Luhn: an order number stays.
  assert.equal(ext.redactCardNumbers("Order 1234567890123"), "Order 1234567890123");
  // A phone number is too short to be a card.
  assert.equal(ext.redactCardNumbers("Call 555 123 4567"), "Call 555 123 4567");
});

test("site actions: GitHub PRs and issues, YouTube videos", () => {
  const personas = [
    { id: "p1", name: "Meow", is_default: true },
    { id: "p2", name: "Code Reviewer", is_default: false },
  ];
  const pr = ext.siteActions("https://github.com/liamphmurphy/vesper/pull/42/files", personas);
  assert.deepEqual(pr.map((a) => a.id), ["review-pr", "ticket-from-pr"]);
  assert.equal(pr[0].label, "Review with Code Reviewer");
  assert.equal(pr[0].persona.id, "p2");
  assert.equal(pr[1].persona.id, "p1");

  const noReviewer = ext.siteActions("https://github.com/o/r/pull/1", [personas[0]]);
  assert.equal(noReviewer[0].label, "Review this pull request");
  assert.equal(noReviewer[0].persona.id, "p1");

  assert.deepEqual(ext.siteActions("https://github.com/o/r/issues/7", personas).map((a) => a.id), ["ticket-from-issue"]);
  assert.deepEqual(ext.siteActions("https://github.com/o/r/pulls", personas), []);
  assert.deepEqual(ext.siteActions("https://www.youtube.com/watch?v=abc", personas).map((a) => a.id), ["video-notes"]);
  assert.deepEqual(ext.siteActions("https://youtu.be/abc", personas).map((a) => a.id), ["video-notes"]);
  assert.deepEqual(ext.siteActions("https://www.youtube.com/feed/subscriptions", personas), []);
  assert.deepEqual(ext.siteActions("not a url", personas), []);
});
