import assert from "node:assert/strict";
import test from "node:test";
import { typedText } from "./chat-context.ts";
import {
  buildCustomAppSrcDoc,
  CUSTOM_APP_ICONS,
  hlsRelayStreamId,
  localMediaEmbed,
  parseBridgeMessage,
  parseHlsRelayUrl,
  parseLocalMediaUrl,
  parseSafeExternalUrl,
  parseSafeHttpsUrl,
  resolveAppIcon,
  resolveVideoEmbed,
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
  // An app may play video it builds in memory (Media Source / blob URLs), and nothing from the network.
  assert.ok(html.includes("media-src blob:;"));
  assert.ok(!/media-src[^;]*(https?:|\*)/.test(html));
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

test("parseSafeExternalUrl and parseSafeHttpsUrl enforce protocols and reject credentials", () => {
  assert.equal(parseSafeExternalUrl("https://youtube.com/watch?v=dQw4w9WgXcQ"), "https://youtube.com/watch?v=dQw4w9WgXcQ");
  assert.equal(parseSafeExternalUrl("http://localhost:3000/test"), "http://localhost:3000/test");
  assert.equal(parseSafeExternalUrl("javascript:alert(1)"), null);
  assert.equal(parseSafeExternalUrl("data:text/html,<script>alert(1)</script>"), null);
  assert.equal(parseSafeExternalUrl("file:///etc/passwd"), null);
  assert.equal(parseSafeExternalUrl("https://user:pass@example.com"), null);

  assert.equal(parseSafeHttpsUrl("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"), "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg");
  assert.equal(parseSafeHttpsUrl("http://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg"), null);
  assert.equal(parseSafeHttpsUrl("https://user@example.com/a.png"), null);
});

test("resolveVideoEmbed resolves YouTube and Twitch URLs safely", () => {
  assert.deepEqual(resolveVideoEmbed("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=1m5s"), {
    provider: "youtube",
    embedUrl: "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&rel=0&start=65",
    externalUrl: "https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=65s",
    titleFallback: "YouTube video",
  });
  assert.equal(
    resolveVideoEmbed("https://youtu.be/dQw4w9WgXcQ")?.embedUrl,
    "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&rel=0",
  );
  assert.equal(
    resolveVideoEmbed("https://m.youtube.com/shorts/dQw4w9WgXcQ")?.embedUrl,
    "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&rel=0",
  );
  assert.equal(
    resolveVideoEmbed("https://www.youtube.com/live/dQw4w9WgXcQ")?.embedUrl,
    "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&rel=0",
  );

  assert.deepEqual(resolveVideoEmbed("https://www.twitch.tv/SomeStreamer", "vesper.local"), {
    provider: "twitch",
    embedUrl: "https://player.twitch.tv/?channel=somestreamer&parent=vesper.local&autoplay=true",
    externalUrl: "https://www.twitch.tv/somestreamer",
    titleFallback: "SomeStreamer on Twitch",
  });
  assert.deepEqual(resolveVideoEmbed("https://www.twitch.tv/videos/123456789", "vesper.local"), {
    provider: "twitch",
    embedUrl: "https://player.twitch.tv/?video=123456789&parent=vesper.local&autoplay=true",
    externalUrl: "https://www.twitch.tv/videos/123456789",
    titleFallback: "Twitch video",
  });
  assert.equal(
    resolveVideoEmbed("https://clips.twitch.tv/FriendlyClipSlug-123", "vesper.local")?.embedUrl,
    "https://clips.twitch.tv/embed?clip=FriendlyClipSlug-123&parent=vesper.local&autoplay=true",
  );
  assert.equal(
    resolveVideoEmbed("https://www.twitch.tv/streamer/clip/FriendlyClipSlug-123", "vesper.local")?.embedUrl,
    "https://clips.twitch.tv/embed?clip=FriendlyClipSlug-123&parent=vesper.local&autoplay=true",
  );
  assert.equal(resolveVideoEmbed("https://www.twitch.tv/directory", "vesper.local"), null);
  assert.equal(resolveVideoEmbed("https://evil.example/watch?v=dQw4w9WgXcQ"), null);
  assert.equal(resolveVideoEmbed("javascript:alert(1)"), null);
});

test("parseBridgeMessage validates open-url and play-video", () => {
  assert.deepEqual(
    parseBridgeMessage({ channel: "vesper:custom-app", type: "open-url", payload: { url: "https://example.com/a" } }),
    { channel: "vesper:custom-app", id: "", type: "open-url", payload: { url: "https://example.com/a" } },
  );
  assert.equal(
    parseBridgeMessage({ channel: "vesper:custom-app", type: "open-url", payload: { url: "javascript:alert(1)" } }),
    null,
  );
  assert.deepEqual(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      type: "play-video",
      payload: { url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", title: "Demo video" },
    }),
    {
      channel: "vesper:custom-app",
      id: "",
      type: "play-video",
      payload: { url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ", title: "Demo video" },
    },
  );
  assert.equal(
    parseBridgeMessage({ channel: "vesper:custom-app", type: "play-video", payload: { url: "data:text/html,hi" } }),
    null,
  );
});

test("parseBridgeMessage validates image proxy requests", () => {
  assert.deepEqual(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      id: "req_img_1",
      type: "image",
      payload: { url: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg" },
    }),
    {
      channel: "vesper:custom-app",
      id: "req_img_1",
      type: "image",
      payload: { url: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg" },
    },
  );
  assert.equal(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      id: "",
      type: "image",
      payload: { url: "https://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg" },
    }),
    null,
  );
  assert.equal(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      id: "req_img_2",
      type: "image",
      payload: { url: "http://i.ytimg.com/vi/dQw4w9WgXcQ/mqdefault.jpg" },
    }),
    null,
  );
  assert.equal(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      id: "req_img_3",
      type: "image",
      payload: { url: "javascript:alert(1)" },
    }),
    null,
  );
});

test("downloaded videos play from Vesper, never from an outside URL", () => {
  const id = "01a1f7a0-1234-7abc-8def-0123456789ab";
  assert.equal(parseLocalMediaUrl(`vesper-media:${id}`), `vesper-media:${id}`);
  assert.equal(parseLocalMediaUrl(` VESPER-MEDIA:${id.toUpperCase()} `), `vesper-media:${id}`);
  for (const bad of ["vesper-media:not-a-uuid", `vesper-media:${id}/../x`, `https://cdn.example/${id}.mp4`, 42, null]) {
    assert.equal(parseLocalMediaUrl(bad), null, String(bad));
  }

  assert.deepEqual(localMediaEmbed(`vesper-media:${id}`, "feed"), {
    provider: "local",
    embedUrl: `/api/v1/custom-apps/feed/media/${id}/content`,
    externalUrl: "",
    titleFallback: "Downloaded video",
  });
  assert.equal(localMediaEmbed(`vesper-media:${id}`, "../feed"), null);
  assert.equal(localMediaEmbed("https://www.youtube.com/watch?v=dQw4w9WgXcQ", "feed"), null);

  assert.deepEqual(
    parseBridgeMessage({ channel: "vesper:custom-app", type: "play-video", payload: { url: `vesper-media:${id}`, title: "Clip" } }),
    { channel: "vesper:custom-app", id: "", type: "play-video", payload: { url: `vesper-media:${id}`, title: "Clip" } },
  );
});

test("parseBridgeMessage keeps play-video's theater flag only when it is a boolean", () => {
  const url = "https://www.youtube.com/watch?v=dQw4w9WgXcQ";
  assert.deepEqual(
    parseBridgeMessage({ channel: "vesper:custom-app", type: "play-video", payload: { url, theater: true } }),
    { channel: "vesper:custom-app", id: "", type: "play-video", payload: { url, theater: true } },
  );
  assert.deepEqual(
    parseBridgeMessage({ channel: "vesper:custom-app", type: "play-video", payload: { url, theater: "yes" } }),
    { channel: "vesper:custom-app", id: "", type: "play-video", payload: { url } },
  );
});

test("HLS relay streams parse vesper-hls:<uuid> and optional safe externalUrl", () => {
  const id = "01a1f7a0-1234-7abc-8def-0123456789ab";
  assert.equal(parseHlsRelayUrl(`vesper-hls:${id}`), `vesper-hls:${id}`);
  assert.equal(parseHlsRelayUrl(` VESPER-HLS:${id.toUpperCase()} `), `vesper-hls:${id}`);
  assert.equal(hlsRelayStreamId(`vesper-hls:${id}`), id);
  for (const bad of ["vesper-hls:not-a-uuid", `vesper-hls:${id}/../x`, `http://192.168.1.2/master.m3u8`, 42, null]) {
    assert.equal(parseHlsRelayUrl(bad), null, String(bad));
    assert.equal(hlsRelayStreamId(bad), null, String(bad));
  }

  assert.deepEqual(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      type: "play-video",
      payload: { url: `vesper-hls:${id}`, title: "Live", theater: true, externalUrl: "https://www.twitch.tv/demo" },
    }),
    {
      channel: "vesper:custom-app",
      id: "",
      type: "play-video",
      payload: { url: `vesper-hls:${id}`, title: "Live", theater: true, externalUrl: "https://www.twitch.tv/demo" },
    },
  );
  // Unsafe externalUrl is dropped while keeping the valid relay URL.
  assert.deepEqual(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      type: "play-video",
      payload: { url: `vesper-hls:${id}`, externalUrl: "javascript:alert(1)" },
    }),
    { channel: "vesper:custom-app", id: "", type: "play-video", payload: { url: `vesper-hls:${id}` } },
  );
});

test("parseBridgeMessage validates ws-open, ws-send, and ws-close", () => {
  assert.deepEqual(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      type: "ws-open",
      payload: { connId: "ws_1", url: "wss://irc-ws.chat.twitch.tv:443", protocols: ["irc"] },
    }),
    {
      channel: "vesper:custom-app",
      id: "",
      type: "ws-open",
      payload: { connId: "ws_1", url: "wss://irc-ws.chat.twitch.tv/", protocols: ["irc"] },
    },
  );
  assert.equal(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      type: "ws-open",
      payload: { connId: "ws_2", url: "ws://irc-ws.chat.twitch.tv/" },
    }),
    null,
  );
  assert.equal(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      type: "ws-open",
      payload: { connId: "ws_3", url: "wss://user:pass@irc-ws.chat.twitch.tv/" },
    }),
    null,
  );
  assert.equal(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      type: "ws-open",
      payload: { connId: "", url: "wss://irc-ws.chat.twitch.tv/" },
    }),
    null,
  );
  assert.deepEqual(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      type: "ws-send",
      payload: { connId: "ws_1", data: "PING :tmi.twitch.tv" },
    }),
    {
      channel: "vesper:custom-app",
      id: "",
      type: "ws-send",
      payload: { connId: "ws_1", data: "PING :tmi.twitch.tv" },
    },
  );
  assert.deepEqual(
    parseBridgeMessage({
      channel: "vesper:custom-app",
      type: "ws-close",
      payload: { connId: "ws_1", code: 1000, reason: "bye" },
    }),
    {
      channel: "vesper:custom-app",
      id: "",
      type: "ws-close",
      payload: { connId: "ws_1", code: 1000, reason: "bye" },
    },
  );
});
