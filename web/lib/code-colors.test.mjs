import test from "node:test";
import assert from "node:assert/strict";
import { tokenColor } from "./code-colors.ts";
import { VIZ_LIGHT } from "./chat-svg.ts";

test("token colours move onto the palette by hue, greys onto ink and muted", () => {
  assert.equal(tokenColor("#D73A49", VIZ_LIGHT), VIZ_LIGHT.series[7]);
  assert.equal(tokenColor("#6F42C1", VIZ_LIGHT), VIZ_LIGHT.series[6]);
  assert.equal(tokenColor("#6A737D", VIZ_LIGHT), VIZ_LIGHT.muted);
  assert.equal(tokenColor("#E1E4E8", VIZ_LIGHT), VIZ_LIGHT.ink);
  assert.equal(tokenColor(undefined, VIZ_LIGHT), VIZ_LIGHT.ink);
});
