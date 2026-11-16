import assert from "node:assert/strict";
import test from "node:test";
import { classifyNavigation, cleanTabTitle, ClosedTabStack } from "../dist/routing.js";

test("classifyNavigation distinguishes same-origin Vesper, Playground ports, external links, and ignored schemes", () => {
  const localServer = "http://localhost:8080";

  assert.equal(classifyNavigation("http://localhost:8080/tickets/LAZYAGENTS-228", localServer), "vesper");
  assert.equal(classifyNavigation("http://localhost:8090/preview", localServer), "playground");
  assert.equal(classifyNavigation("http://127.0.0.1:8094/", localServer), "playground");
  assert.equal(classifyNavigation("http://localhost:9000/other", localServer), "external");
  assert.equal(classifyNavigation("https://github.com/liamphmurphy/vesper", localServer), "external");
  assert.equal(classifyNavigation("mailto:team@example.com", localServer), "external");
  assert.equal(classifyNavigation("about:blank", localServer), "ignore");
  assert.equal(classifyNavigation("javascript:void(0)", localServer), "ignore");
  assert.equal(classifyNavigation("not a url", localServer), "ignore");

  const remoteServer = "https://vesper.tailnet.ts.net";
  assert.equal(classifyNavigation("https://vesper.tailnet.ts.net/chat/123", remoteServer), "vesper");
  assert.equal(classifyNavigation("http://vesper.tailnet.ts.net:8092/app", remoteServer), "playground");
  assert.equal(classifyNavigation("http://localhost:8090/", remoteServer), "external");
});

test("cleanTabTitle strips redundant Vesper suffixes while preserving standalone Vesper", () => {
  assert.equal(cleanTabTitle(""), "Vesper");
  assert.equal(cleanTabTitle("Vesper"), "Vesper");
  assert.equal(cleanTabTitle("Inbox · Vesper"), "Inbox");
  assert.equal(cleanTabTitle("LAZYAGENTS-228 - Vesper"), "LAZYAGENTS-228");
  assert.equal(cleanTabTitle("Designs — Vesper"), "Designs");
  assert.equal(cleanTabTitle("  Chat   with   Meow  · Vesper  "), "Chat with Meow");
});

test("ClosedTabStack pushes LIFO, skips local/blank/consecutive duplicates, and respects maxItems", () => {
  const stack = new ClosedTabStack(3);
  stack.push("file:///app/renderer/offline.html");
  stack.push("about:blank");
  assert.equal(stack.size, 0);

  stack.push("http://localhost:8080/a");
  stack.push("http://localhost:8080/a");
  assert.equal(stack.size, 1);

  stack.push("http://localhost:8080/b");
  stack.push("http://localhost:8080/c");
  stack.push("http://localhost:8080/d");
  assert.equal(stack.size, 3);

  assert.equal(stack.pop(), "http://localhost:8080/d");
  assert.equal(stack.pop(), "http://localhost:8080/c");
  assert.equal(stack.pop(), "http://localhost:8080/b");
  assert.equal(stack.pop(), undefined);
});
