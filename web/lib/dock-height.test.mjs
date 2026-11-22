import assert from "node:assert/strict";
import test from "node:test";
import { DOCK_HEIGHT_VAR, dockHeightValue, trackDockHeight } from "./dock-height.ts";

test("dockHeightValue rounds up to whole pixels and rejects junk", () => {
  assert.equal(dockHeightValue(88), "88px");
  assert.equal(dockHeightValue(88.2), "89px");
  assert.equal(dockHeightValue(0), "0px");
  assert.equal(dockHeightValue(-1), "");
  assert.equal(dockHeightValue(Number.NaN), "");
});

test("trackDockHeight skips redundant CSS custom property writes for unchanged heights", () => {
  const sets = [];
  const removals = [];
  let callback;
  const prevRO = globalThis.ResizeObserver;
  globalThis.ResizeObserver = class {
    constructor(cb) {
      callback = cb;
    }
    observe() {}
    disconnect() {}
  };
  try {
    const host = {
      style: {
        setProperty(name, value) {
          sets.push([name, value]);
        },
        removeProperty(name) {
          removals.push(name);
        },
      },
    };
    const dock = {
      parentElement: host,
      getBoundingClientRect: () => ({ height: 88.1 }),
    };
    const stop = trackDockHeight(dock);
    assert.deepEqual(sets, [[DOCK_HEIGHT_VAR, "89px"]]);

    // Subpixel jitter that rounds to the same whole pixel writes nothing.
    callback([{ borderBoxSize: [{ blockSize: 88.9 }] }]);
    assert.equal(sets.length, 1);

    // An actual height change writes once.
    callback([{ borderBoxSize: [{ blockSize: 112.4 }] }]);
    assert.deepEqual(sets, [
      [DOCK_HEIGHT_VAR, "89px"],
      [DOCK_HEIGHT_VAR, "113px"],
    ]);

    stop();
    assert.deepEqual(removals, [DOCK_HEIGHT_VAR]);
  } finally {
    globalThis.ResizeObserver = prevRO;
  }
});
