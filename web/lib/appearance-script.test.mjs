import assert from "node:assert/strict";
import test from "node:test";
import { runInNewContext } from "node:vm";
import { themeScript } from "./appearance-script.ts";
import { DEFAULT_APPEARANCE, parseAppearance } from "./palettes.ts";

test("pre-paint harness visibility matches saved appearance before React loads", () => {
  for (const raw of [null, "{", "a".repeat(40001), ...[undefined, false, true, "false", 0].map((showHarnessActivity) => JSON.stringify({ version: 1, palette: "nord", showHarnessActivity }))]) {
    const root = { dataset: {}, style: { setProperty() {} }, setAttribute() {} };
    runInNewContext(themeScript, { document: { documentElement: root }, localStorage: { getItem: (key) => key === "la-appearance" ? raw : null }, matchMedia: () => ({ matches: false }) });
    assert.equal(root.dataset.harnessActivity, parseAppearance(raw).showHarnessActivity === false ? "hidden" : "visible");
  }
});

test("blocked storage keeps the default footer and does not break first paint", () => {
  const root = { dataset: {}, style: { setProperty() {} }, setAttribute() {} };
  runInNewContext(themeScript, { document: { documentElement: root }, localStorage: { getItem: () => { throw new Error("Blocked"); } }, matchMedia: () => ({ matches: true }) });
  assert.equal(root.dataset.harnessActivity, "visible");
  assert.equal(root.dataset.palette, DEFAULT_APPEARANCE.palette);
});

test("pre-paint text size matches saved appearance, and unknown sizes fall back to default", () => {
  for (const textSize of [undefined, "small", "default", "large", "larger", "huge", 3]) {
    const raw = JSON.stringify({ version: 1, palette: "dusk", textSize });
    const root = { dataset: {}, style: { setProperty() {} }, setAttribute() {} };
    runInNewContext(themeScript, { document: { documentElement: root }, localStorage: { getItem: (key) => key === "la-appearance" ? raw : null }, matchMedia: () => ({ matches: false }) });
    assert.equal(root.dataset.textSize, parseAppearance(raw).textSize);
    assert.equal(root.dataset.textSize, ["small", "large", "larger"].includes(textSize) ? textSize : "default");
  }
});
