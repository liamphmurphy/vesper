import test from "node:test";
import assert from "node:assert/strict";
import {
  SETTINGS_DEFAULT_SECTION,
  SETTINGS_FILTER_KEYWORDS,
  matchesSettingsFilter,
  resolveSettingsRoute,
  selectedNavId,
  settingsHref,
} from "./settings-nav.ts";
import { redirectFor } from "./next-compat/redirects.ts";

const q = (s = "") => new URLSearchParams(s);

test("resolveSettingsRoute defaults to You and resolves every explicit ?section=", () => {
  assert.deepEqual(resolveSettingsRoute(q()), { section: SETTINGS_DEFAULT_SECTION });
  assert.equal(SETTINGS_DEFAULT_SECTION, "you");

  for (const section of ["you", "appearance", "connectors", "repositories", "runners", "dev-workspace", "sign-in", "backup"]) {
    assert.deepEqual(resolveSettingsRoute(q(`section=${section}`)), { section });
  }
  assert.deepEqual(resolveSettingsRoute(q("section=memory")), { section: "memory" });
  assert.deepEqual(resolveSettingsRoute(q("section=memory&id=mem-1")), { section: "memory", focusId: "mem-1" });
  assert.deepEqual(resolveSettingsRoute(q("section=personas")), { section: "personas", personaFilter: "all" });
  assert.deepEqual(resolveSettingsRoute(q("section=personas&filter=tickets")), { section: "personas", personaFilter: "tickets" });
  assert.deepEqual(resolveSettingsRoute(q("section=personas&filter=invalid")), { section: "personas", personaFilter: "all" });
  assert.deepEqual(resolveSettingsRoute(q("section=personas&persona=p1")), { section: "persona", personaId: "p1" });
  assert.deepEqual(resolveSettingsRoute(q("section=persona&persona=p2")), { section: "persona", personaId: "p2" });
  assert.deepEqual(resolveSettingsRoute(q("section=persona&id=p3")), { section: "persona", personaId: "p3" });
  assert.deepEqual(resolveSettingsRoute(q("section=persona")), { section: "personas", personaFilter: "all" });
  assert.deepEqual(resolveSettingsRoute(q("section=secrets")), { section: "secrets", secretsTab: "provider" });
  assert.deepEqual(resolveSettingsRoute(q("section=secrets&tab=api")), { section: "secrets", secretsTab: "api" });
  assert.deepEqual(resolveSettingsRoute(q("section=secrets&secret=sec-1")), { section: "secrets", secretsTab: "api", secretId: "sec-1" });
  assert.deepEqual(resolveSettingsRoute(q("section=secrets&tab=provider&secret=sec-1")), { section: "secrets", secretsTab: "provider", secretId: "sec-1" });
  assert.deepEqual(resolveSettingsRoute(q("section=workspace")), { section: "workspace" });
  assert.deepEqual(resolveSettingsRoute(q("section=workspace"), "#images"), { section: "workspace", anchor: "images" });
  assert.deepEqual(resolveSettingsRoute(q("section=spaces")), { section: "spaces" });
  assert.deepEqual(resolveSettingsRoute(q("section=spaces&space=sp1")), { section: "spaces", spaceId: "sp1" });
  assert.deepEqual(resolveSettingsRoute(q("section=spaces"), "#overrides"), { section: "spaces", anchor: "overrides" });
});

test("resolveSettingsRoute supports implicit query params and legacy #hashes", () => {
  assert.deepEqual(resolveSettingsRoute(q("persona=p1")), { section: "persona", personaId: "p1" });
  assert.deepEqual(resolveSettingsRoute(q("id=m1")), { section: "memory", focusId: "m1" });
  assert.deepEqual(resolveSettingsRoute(q("space=s1")), { section: "spaces", spaceId: "s1" });
  assert.deepEqual(resolveSettingsRoute(q("secret=sec1")), { section: "secrets", secretsTab: "api", secretId: "sec1" });

  assert.deepEqual(resolveSettingsRoute(q(), "#appearance"), { section: "appearance" });
  assert.deepEqual(resolveSettingsRoute(q(), "#secrets"), { section: "secrets", secretsTab: "provider" });
  assert.deepEqual(resolveSettingsRoute(q(), "#runners"), { section: "runners" });
  assert.deepEqual(resolveSettingsRoute(q(), "#repositories"), { section: "repositories" });
  assert.deepEqual(resolveSettingsRoute(q(), "#images"), { section: "workspace", anchor: "images" });
  assert.deepEqual(resolveSettingsRoute(q(), "#dev-workspace"), { section: "dev-workspace" });
  assert.deepEqual(resolveSettingsRoute(q(), "#overrides"), { section: "spaces", anchor: "overrides" });
  assert.deepEqual(resolveSettingsRoute(q(), "#sign-in"), { section: "sign-in" });
  assert.deepEqual(resolveSettingsRoute(q(), "#backup"), { section: "backup" });
  assert.deepEqual(resolveSettingsRoute(q(), "#workspace"), { section: "workspace" });
  assert.deepEqual(resolveSettingsRoute(q("section=unknown")), { section: "you" });
  assert.deepEqual(resolveSettingsRoute(q(), "#unknown"), { section: "you" });
});

test("settingsHref round-trips through resolveSettingsRoute and selectedNavId maps selection", () => {
  const cases = [
    { section: "you" },
    { section: "appearance" },
    { section: "memory" },
    { section: "memory", focusId: "m-1" },
    { section: "personas", personaFilter: "all" },
    { section: "personas", personaFilter: "tickets" },
    { section: "persona", personaId: "p-1" },
    { section: "secrets", secretsTab: "provider" },
    { section: "secrets", secretsTab: "api", secretId: "s-1" },
    { section: "connectors" },
    { section: "repositories" },
    { section: "workspace" },
    { section: "workspace", anchor: "images" },
    { section: "runners" },
    { section: "dev-workspace" },
    { section: "spaces" },
    { section: "spaces", spaceId: "sp-1" },
    { section: "spaces", anchor: "overrides" },
    { section: "sign-in" },
    { section: "backup" },
  ];
  for (const route of cases) {
    const url = new URL(settingsHref(route), "https://vesper.local");
    assert.deepEqual(resolveSettingsRoute(url.searchParams, url.hash), route);
  }
  assert.equal(selectedNavId({ section: "personas", personaFilter: "all" }), "all-personas");
  assert.equal(selectedNavId({ section: "persona", personaId: "p-1" }), "persona:p-1");
  assert.equal(selectedNavId({ section: "secrets", secretsTab: "api" }), "secrets");
});

test("redirectFor maps /customization, /memory, /personas, and /agents into /settings", () => {
  const redir = (path) => redirectFor(new URL(path, "https://vesper.local"));
  assert.equal(redir("/customization"), "/settings?section=memory");
  assert.equal(redir("/customization?id=m1"), "/settings?section=memory&id=m1");
  assert.equal(redir("/customization?who=person"), "/settings?section=you");
  assert.equal(redir("/customization?who=personas"), "/settings?section=personas");
  assert.equal(redir("/customization?who=agents"), "/settings?section=personas&filter=tickets");
  assert.equal(redir("/customization?who=connectors"), "/settings?section=connectors");
  assert.equal(redir("/customization?who=secrets"), "/settings?section=secrets&tab=api");
  assert.equal(redir("/customization?who=secrets&secret=s1"), "/settings?section=secrets&tab=api&secret=s1");
  assert.equal(redir("/customization?who=p-uuid"), "/settings?section=personas&persona=p-uuid");
  assert.equal(redir("/customization?space=sp-1"), "/settings?section=spaces&space=sp-1");
  assert.equal(redir("/customization?who=person#top"), "/settings?section=you#top");

  assert.equal(redir("/memory"), "/settings?section=memory");
  assert.equal(redir("/memory?id=abc"), "/settings?section=memory&id=abc");
  assert.equal(redir("/personas"), "/settings?section=personas");
  assert.equal(redir("/agents"), "/settings?section=personas");
});

test("matchesSettingsFilter matches labels and section keywords across multiple words", () => {
  assert.equal(matchesSettingsFilter("", "Appearance"), true);
  assert.equal(matchesSettingsFilter("theme palette", "Appearance", SETTINGS_FILTER_KEYWORDS.appearance), true);
  assert.equal(matchesSettingsFilter("image engine", "Workspace", SETTINGS_FILTER_KEYWORDS.workspace), true);
  assert.equal(matchesSettingsFilter("oauth key", "Secrets & Credentials", SETTINGS_FILTER_KEYWORDS.secrets), true);
  assert.equal(matchesSettingsFilter("subagent", "Runners", SETTINGS_FILTER_KEYWORDS.runners), true);
  assert.equal(matchesSettingsFilter("delegation", "Runners", SETTINGS_FILTER_KEYWORDS.runners), true);
  assert.equal(matchesSettingsFilter("oauth", "Appearance", SETTINGS_FILTER_KEYWORDS.appearance), false);
});
