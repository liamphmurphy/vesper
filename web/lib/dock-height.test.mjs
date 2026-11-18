import assert from "node:assert/strict";
import test from "node:test";
import { dockHeightValue } from "./dock-height.ts";

test("dockHeightValue rounds up to whole pixels and rejects junk", () => {
  assert.equal(dockHeightValue(88), "88px");
  assert.equal(dockHeightValue(88.2), "89px");
  assert.equal(dockHeightValue(0), "0px");
  assert.equal(dockHeightValue(-1), "");
  assert.equal(dockHeightValue(Number.NaN), "");
});
