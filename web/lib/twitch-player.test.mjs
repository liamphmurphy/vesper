import test from "node:test";
import assert from "node:assert/strict";
import {
  DEFAULT_BACKUP_PLAYER_TYPES,
  formatTwitchLatency,
  formatTwitchTime,
  isSameOriginTwitchPlaylistUrl,
  parseBackupTypesInput,
  shouldHideAdOverlay,
} from "./twitch-player.ts";

test("parseBackupTypesInput normalizes, filters, and deduplicates", () => {
  assert.deepEqual([...DEFAULT_BACKUP_PLAYER_TYPES], ["embed", "popout", "autoplay"]);
  assert.deepEqual(parseBackupTypesInput("Embed, popout  autoplay, invalid! , embed"), ["embed", "popout", "autoplay"]);
  assert.deepEqual(parseBackupTypesInput("   "), []);
});

test("shouldHideAdOverlay respects manual reveal toggle", () => {
  assert.equal(shouldHideAdOverlay(false, false), false);
  assert.equal(shouldHideAdOverlay(true, false), true);
  assert.equal(shouldHideAdOverlay(true, true), false);
});

test("formatTwitchTime and formatTwitchLatency format media durations cleanly", () => {
  assert.equal(formatTwitchTime(0), "0:00");
  assert.equal(formatTwitchTime(65), "1:05");
  assert.equal(formatTwitchTime(3723), "1:02:03");
  assert.equal(formatTwitchTime(-5), "0:00");

  assert.equal(formatTwitchLatency(undefined), "");
  assert.equal(formatTwitchLatency(2.34), "2.3s");
  assert.equal(formatTwitchLatency(12.7), "13s");
});

test("isSameOriginTwitchPlaylistUrl enables credentials only for same-origin proxy endpoints", () => {
  assert.equal(isSameOriginTwitchPlaylistUrl("/api/v1/twitch/sessions/abc/master.m3u8", "https://vesper.local"), true);
  assert.equal(
    isSameOriginTwitchPlaylistUrl("https://vesper.local/api/v1/twitch/sessions/abc/variant/0.m3u8", "https://vesper.local"),
    true,
  );
  assert.equal(
    isSameOriginTwitchPlaylistUrl("https://video-edge-abc.ttvnw.net/v1/segment/seg.ts", "https://vesper.local"),
    false,
  );
  assert.equal(isSameOriginTwitchPlaylistUrl("https://evil.example/api/v1/twitch/x", "https://vesper.local"), false);
});
