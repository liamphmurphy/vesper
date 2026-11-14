import assert from "node:assert/strict";
import test from "node:test";
import { typedText } from "./chat-context.ts";
import {
  buildCustomAppSrcDoc,
  CUSTOM_APP_ICONS,
  parseBridgeMessage,
  resolveAppIcon,
  slugifyAppName,
  validateCustomAppSlug,
  withCustomAppContext,
} from "./custom-app-bridge.ts";

test("slug validation allows finance and rejects reserved routes", () => {
  assert.equal(slugifyAppName("My Finance Ledger"), "my-finance-ledger");
  assert.equal(slugifyAppName("  Finance  "), "finance");
  assert.equal(validateCustomAppSlug("finance"), null);
  assert.equal(validateCustomAppSlug("spending-2026"), null);
  assert.ok(validateCustomAppSlug("new"));
  assert.ok(validateCustomAppSlug("slides"));
  assert.ok(validateCustomAppSlug("designs"));
  assert.ok(validateCustomAppSlug("Bad_Slug"));
});

test("icon fallback picks a known icon", () => {
  assert.equal(resolveAppIcon("dollar"), "dollar");
  assert.equal(resolveAppIcon("nonexistent"), "dashboard");
  assert.ok(CUSTOM_APP_ICONS.includes("dashboard"));
});

test("srcDoc enforces strict CSP, embeds safe theme vars, and escapes script close tags", () => {
  const html = buildCustomAppSrcDoc({
    slug: "finance",
    seq: 2,
    bundleJs: 'console.log("</script><script>alert(1)</script>");',
    bundleCss: "body { color: red; }</style>",
    themeVars: { "--bg": "#111111", "--accent": "#d79921;evil" },
  });
  assert.ok(html.includes("default-src 'none'; script-src 'unsafe-inline'"));
  assert.ok(html.includes("--bg: #111111;"));
  assert.ok(html.includes("<\\/script>"));
  assert.ok(html.includes("<\\/style>"));
  assert.ok(!html.includes("</script><script>alert(1)"));
});

test("parseBridgeMessage validates SQL, API, MCP, nav, ask-dock, and errors", () => {
  assert.deepEqual(
    parseBridgeMessage({ channel: "vesper:custom-app", id: "req_1", type: "sql", payload: { query: "SELECT 1", params: [1] } }),
    { channel: "vesper:custom-app", id: "req_1", type: "sql", payload: { query: "SELECT 1", params: [1] } },
  );
  assert.deepEqual(
    parseBridgeMessage({ channel: "vesper:custom-app", id: "req_2", type: "api", payload: { path: "/api/v1/projects" } }),
    { channel: "vesper:custom-app", id: "req_2", type: "api", payload: { method: "GET", path: "/api/v1/projects", body: undefined } },
  );
  assert.deepEqual(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      type: "set-nav",
      payload: { items: [{ id: "overview", label: "Overview", icon: "graph" }], activeId: "overview" },
    }),
    {
      channel: "vesper:custom-app",
      id: "",
      type: "set-nav",
      payload: { items: [{ id: "overview", label: "Overview", icon: "graph" }], activeId: "overview" },
    },
  );
  assert.equal(parseBridgeMessage({ channel: "other", id: "1", type: "sql", payload: { query: "SELECT 1" } }), null);
  assert.equal(parseBridgeMessage({ channel: "vesper:custom-app", id: "", type: "sql", payload: { query: "SELECT 1" } }), null);
});

test("withCustomAppContext appends context once and typedText hides it from user bubble", () => {
  const once = withCustomAppContext("Add a recurring column", {
    slug: "finance",
    name: "Finance",
    seq: 3,
    activeNav: "transactions",
    error: "ReferenceError: x is not defined",
  });
  const twice = withCustomAppContext(once, {
    slug: "finance",
    name: "Finance",
    seq: 3,
    activeNav: "transactions",
    error: "ReferenceError: x is not defined",
  });
  assert.equal(once, twice);
  assert.equal(typedText(once), "Add a recurring column");
});

test("every theme var forwarded to custom apps is defined by Vesper's tokens", async () => {
  const { readFile } = await import("node:fs/promises");
  const tokens = await readFile(new URL("../styles/tokens.css", import.meta.url), "utf8");
  const { THEME_VARS } = await import("./custom-app-bridge.ts");
  for (const [appVar, hostVar] of Object.entries(THEME_VARS)) {
    assert.ok(tokens.includes(`${hostVar}:`), `${appVar} reads ${hostVar}, which tokens.css doesn't define`);
  }
});

test("readThemeVarsFrom exposes Vesper's text colors under the --fg names apps use", async () => {
  const { readThemeVarsFrom } = await import("./custom-app-bridge.ts");
  const host = { "--bg": "#0C0B12", "--text": "#EEEDF3", "--text-secondary": "#A4A1B3", "--text-on-accent": "#120F24" };
  const vars = readThemeVarsFrom((name) => host[name] ?? "");
  assert.equal(vars["--bg"], "#0C0B12");
  assert.equal(vars["--fg"], "#EEEDF3");
  assert.equal(vars["--fg-secondary"], "#A4A1B3");
  assert.equal(vars["--on-accent"], "#120F24");
  assert.ok(!("--fg-2" in vars), "unset host vars are omitted so the app's own fallback applies");
});
