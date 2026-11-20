import assert from "node:assert/strict";
import test from "node:test";
import { fromPaletteRequest, toPaletteRequest } from "./palette.ts";

test("toPaletteRequest preserves location, scope, agent flag, and query", () => {
  const req = toPaletteRequest(
    { scope: { kind: "type", type: "ticket", label: "Tickets" }, includeAgent: false, query: "auth" },
    { pathname: "/tickets", search: "?project=VES" },
  );
  assert.deepEqual(req, {
    path: "/tickets",
    search: "?project=VES",
    scope: "type",
    scopeType: "ticket",
    scopeLabel: "Tickets",
    includeAgent: false,
    query: "auth",
  });

  const round = fromPaletteRequest(req);
  assert.equal(round.pathname, "/tickets");
  assert.equal(round.search, "?project=VES");
  assert.deepEqual(round.detail, {
    scope: { kind: "type", type: "ticket", label: "Tickets" },
    includeAgent: false,
    query: "auth",
  });
});

test("fromPaletteRequest handles knowledge scope, fallback paths, and unknown scope types", () => {
  const knowledge = fromPaletteRequest({
    path: "/knowledge/123",
    scope: "knowledge",
    includeAgent: true,
    query: "#tag",
  });
  assert.deepEqual(knowledge, {
    pathname: "/knowledge/123",
    search: "",
    detail: { scope: { kind: "knowledge", label: "Knowledge" }, includeAgent: true, query: "#tag" },
  });

  const invalid = fromPaletteRequest({ path: "//evil.com", scope: "type", scopeType: "bogus" });
  assert.equal(invalid.pathname, "/");
  assert.equal(invalid.detail.scope, undefined);
});
