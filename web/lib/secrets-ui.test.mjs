import test from "node:test";
import assert from "node:assert/strict";
import { expiryPill, expiryText, handleFor, hostOf, jwtExpiry, oauthStatus, placementLabel, secretCall, sentAs, splitScopes } from "./secrets-ui.ts";

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");

test("a JWT's exp is read; anything else has none", () => {
  const jwt = `${b64({ alg: "HS256" })}.${b64({ exp: 1794700800 })}.sig`;
  assert.equal(jwtExpiry(jwt)?.toISOString(), "2026-11-15T00:00:00.000Z");
  assert.equal(jwtExpiry("sk_live_123"), null);
  assert.equal(jwtExpiry(`${b64({})}.${b64({ sub: "x" })}.sig`), null);
  assert.equal(jwtExpiry("a.!!!.c"), null);
});

test("handles match the server's derivation", () => {
  assert.equal(handleFor("Acme API JWT"), "acme-api-jwt");
  assert.equal(handleFor("  2FA token "), "s-2fa-token");
  assert.equal(handleFor("x".repeat(50)).length, 36);
});

test("hosts accept pasted URLs but not wildcards", () => {
  assert.equal(hostOf("https://API.acme.com/v1?x=1"), "api.acme.com");
  assert.equal(hostOf("localhost:8080"), "localhost");
  assert.equal(hostOf("*.acme.com"), null);
  assert.equal(hostOf("acme com"), null);
  assert.equal(hostOf(""), null);
});

test("the request preview shows the handle, never a value", () => {
  assert.equal(sentAs("bearer", "", "acme-jwt"), "Authorization: Bearer ‹acme-jwt›");
  assert.equal(sentAs("header", "X-Api-Key", "k"), "X-Api-Key: ‹k›");
  assert.equal(sentAs("query", "api_key", "k"), "?api_key=‹k›");
  assert.equal(placementLabel("header", "X-Api-Key"), "X-Api-Key header");
  assert.equal(placementLabel("bearer", ""), "Authorization: Bearer");
});

test("expiry pills", () => {
  const now = Date.parse("2026-11-09T00:00:00Z");
  assert.deepEqual(expiryPill("2026-11-15T00:00:00Z", now), { label: "6d left", tone: "human" });
  assert.deepEqual(expiryPill("2026-11-09T05:00:00Z", now), { label: "5h left", tone: "human" });
  assert.deepEqual(expiryPill("2026-11-08T00:00:00Z", now), { label: "Expired", tone: "blocked" });
  assert.deepEqual(expiryPill("2027-01-01T00:00:00Z", now), { label: "Active", tone: "done" });
  assert.equal(expiryPill(undefined, now), null);
  assert.equal(expiryText("2026-11-15T00:00:00Z", now), "Expires Nov 15, 2026");
  assert.equal(expiryText(new Date("2026-11-08T00:00:00Z"), now), "Expired Nov 8, 2026");
  assert.equal(expiryText(undefined, now), "No expiry found");
});

test("secret calls are recognised in both harnesses' naming", () => {
  assert.deepEqual(secretCall("mcp__vesper_secrets__http_request", { secret: "acme-jwt", url: "https://api.acme.com/v1/orders?since=x" }), { tool: "http_request", handle: "acme-jwt", method: "GET", target: "api.acme.com/v1/orders" });
  assert.deepEqual(secretCall("vesper_secrets.http_request", { secret: "k", method: "post", url: "nope" }), { tool: "http_request", handle: "k", method: "POST", target: "nope" });
  assert.equal(secretCall("mcp__github__create_issue", {}), null);
});

test("scopes split on spaces, commas and new lines, without repeats", () => {
  assert.deepEqual(splitScopes(" drive.readonly, drive.file\ndrive.readonly "), ["drive.readonly", "drive.file"]);
  assert.deepEqual(splitScopes("   "), []);
});

test("an OAuth secret is usable only once signed in, until a refresh is refused", () => {
  assert.equal(oauthStatus(undefined), null);
  assert.deepEqual(oauthStatus({ error: "" }), { label: "Not signed in", tone: "human", action: "Sign in" });
  assert.equal(oauthStatus({ signed_in_at: "2026-11-15T00:00:00Z", error: "" })?.tone, "done");
  assert.equal(oauthStatus({ signed_in_at: "2026-11-15T00:00:00Z", error: "invalid_grant" })?.tone, "blocked");
});
