import test from "node:test";
import assert from "node:assert/strict";
import {
  CHARACTER_PREVIEW_STATES,
  characterStateForDock,
  characterStateForStatus,
  detectCharacterStates,
  prepareCharacterSvgForRaster,
  resolveCharacterNodeStyle,
} from "./persona-character.ts";

test("characterStateForStatus maps actions, awaiting, and stopping", () => {
  assert.equal(characterStateForStatus("reading-code"), "reading");
  assert.equal(characterStateForStatus("writing-code"), "coding");
  assert.equal(characterStateForStatus("tests"), "coding");
  assert.equal(characterStateForStatus("canvas"), "creating");
  assert.equal(characterStateForStatus("thinking"), "thinking");
  assert.equal(characterStateForStatus("connector"), "needs_you");
  assert.equal(characterStateForStatus("writing-code", { awaiting: true }), "needs_you");
  assert.equal(characterStateForStatus("writing-code", { stopping: true }), "static");
  assert.equal(characterStateForStatus("writing-code", { awaiting: true, stopping: true }), "static");
});

test("characterStateForDock maps dock states", () => {
  assert.equal(characterStateForDock("working"), "working");
  assert.equal(characterStateForDock("needs_you"), "needs_you");
  assert.equal(characterStateForDock("replied"), "idle");
  assert.equal(characterStateForDock(undefined), "idle");
  assert.equal(CHARACTER_PREVIEW_STATES.length, 6);
});

test("resolveCharacterNodeStyle cascades action -> working -> base motion and respects none", () => {
  const attrs = {
    "data-motion": "blink",
    "data-motion-idle": "breathe",
    "data-motion-working": "tap",
    "data-motion-coding": "type",
    "data-motion-reading": "none",
    "data-pivot": "32 34",
    "data-delay": "-0.5",
    "data-speed": "fast",
  };
  assert.equal(resolveCharacterNodeStyle(attrs, "static").motion, undefined);
  assert.equal(resolveCharacterNodeStyle(attrs, "idle").motion, "breathe");
  assert.equal(resolveCharacterNodeStyle(attrs, "thinking").motion, "tap");
  assert.equal(resolveCharacterNodeStyle(attrs, "coding").motion, "type");
  assert.equal(resolveCharacterNodeStyle(attrs, "reading").motion, undefined);

  const resolved = resolveCharacterNodeStyle(attrs, "coding");
  assert.equal(resolved.hidden, false);
  assert.equal(resolved.style?.transformOrigin, "32px 34px");
  assert.equal(resolved.style?.animationDelay, "-0.5s");
  assert.equal(resolved.style?.["--pc-speed"], "0.65");
});

test("resolveCharacterNodeStyle resolves data-show across static, working, and action states", () => {
  const sparkAttrs = { "data-show": "coding creating", "data-motion": "spark" };
  assert.equal(resolveCharacterNodeStyle(sparkAttrs, "static").hidden, true);
  assert.equal(resolveCharacterNodeStyle(sparkAttrs, "idle").hidden, true);
  assert.equal(resolveCharacterNodeStyle(sparkAttrs, "reading").hidden, true);
  assert.equal(resolveCharacterNodeStyle(sparkAttrs, "coding").hidden, false);
  assert.equal(resolveCharacterNodeStyle(sparkAttrs, "coding").motion, "spark");
  assert.equal(resolveCharacterNodeStyle(sparkAttrs, "creating").hidden, false);

  const workAttrs = { "data-show": "working", "data-motion": "orbit" };
  assert.equal(resolveCharacterNodeStyle(workAttrs, "idle").hidden, true);
  assert.equal(resolveCharacterNodeStyle(workAttrs, "reading").hidden, false);
  assert.equal(resolveCharacterNodeStyle(workAttrs, "coding").hidden, false);
  assert.equal(resolveCharacterNodeStyle(workAttrs, "needs_you").hidden, true);

  const alertAttrs = { "data-show": "needs-you", "data-motion": "pulse" };
  assert.equal(resolveCharacterNodeStyle(alertAttrs, "needs_you").hidden, false);
  assert.equal(resolveCharacterNodeStyle(alertAttrs, "idle").hidden, true);
});

test("detectCharacterStates finds authored motion and show states", () => {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">
    <g data-motion-idle="breathe" data-motion-coding="type">
      <path data-show="reading needs-you"/>
    </g>
  </svg>`;
  const found = detectCharacterStates(svg);
  assert.deepEqual([...found].sort(), ["coding", "idle", "needs_you", "reading"]);
});

test("prepareCharacterSvgForRaster substitutes currentColor and hides non-idle layers", () => {
  const svg = `<svg viewBox="0 0 64 64" width="64" height="64"><circle fill="currentColor" r="10"/><path data-show="coding" d="M0 0"/></svg>`;
  const out = prepareCharacterSvgForRaster(svg, "#8b8fff", 256);
  assert.match(out, /fill="#8b8fff"/);
  assert.match(out, /width="256" height="256"/);
  assert.match(out, /xmlns="http:\/\/www\.w3\.org\/2000\/svg"/);
  assert.match(out, /\[data-show\]:not\(\[data-show~="idle"\]\)\{display:none\}/);
});
