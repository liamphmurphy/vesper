import assert from "node:assert/strict";
import test from "node:test";
import { createDraftStore, createTextareaHeightState, syncTextareaHeight } from "./chat-draft.ts";

/** Simulates a textarea whose content height follows line count (24px/line + 8px padding). */
function fakeTextarea(initial = "", lineHeight = 24, pad = 8, lineWidth = 20) {
  let value = initial;
  let styleHeight = "";
  const writes = [];
  const contentHeight = () => {
    const lines = value.split("\n").reduce((n, l) => n + Math.max(1, Math.ceil(l.length / lineWidth)), 0);
    return lines * lineHeight + pad;
  };
  const explicitPx = () => (styleHeight.endsWith("px") ? parseFloat(styleHeight) : 0);
  return {
    writes,
    el: {
      get value() {
        return value;
      },
      set value(v) {
        value = v;
      },
      get clientHeight() {
        return explicitPx() || contentHeight();
      },
      get scrollHeight() {
        return Math.max(contentHeight(), explicitPx());
      },
      style: {
        get height() {
          return styleHeight;
        },
        set height(v) {
          writes.push(v);
          styleHeight = v;
        },
      },
    },
  };
}

test("createDraftStore notifies subscribers only on changes and supports updater functions", () => {
  const store = createDraftStore("hi");
  assert.equal(store.get(), "hi");
  assert.equal(store.hasText(), true);

  let calls = 0;
  const unsub = store.subscribe(() => calls++);

  store.set("hi");
  assert.equal(calls, 0);

  store.set((prev) => `${prev}!`);
  assert.equal(store.get(), "hi!");
  assert.equal(calls, 1);

  store.set("   ");
  assert.equal(store.hasText(), false);
  assert.equal(calls, 2);

  unsub();
  store.set("after");
  assert.equal(calls, 2);
});

test("syncTextareaHeight avoids height='auto' reflows during normal typing and single-line deletes", () => {
  const { el, writes } = fakeTextarea("");
  const state = createTextareaHeightState();

  // Initial mount measures the single-line height once.
  assert.equal(syncTextareaHeight(el, state), true);
  assert.deepEqual(writes, ["auto", "34px"]);
  writes.length = 0;

  // Typing characters on line 1 performs zero style writes.
  for (const ch of "hello world") {
    el.value += ch;
    assert.equal(syncTextareaHeight(el, state), false);
  }
  assert.deepEqual(writes, []);

  // Backspacing on line 1 also performs zero style writes.
  el.value = "hello";
  assert.equal(syncTextareaHeight(el, state), false);
  assert.deepEqual(writes, []);

  // Wrapping to line 2 grows directly without setting height='auto'.
  el.value = "hello\nworld";
  assert.equal(syncTextareaHeight(el, state), true);
  assert.deepEqual(writes, ["58px"]);
  writes.length = 0;

  // Continuing to type on line 2 performs zero style writes.
  el.value = "hello\nworld!";
  assert.equal(syncTextareaHeight(el, state), false);
  assert.deepEqual(writes, []);

  // Deleting back to line 1 collapses via 'auto' and shrinks back to 34px.
  el.value = "hello";
  assert.equal(syncTextareaHeight(el, state), true);
  assert.deepEqual(writes, ["auto", "34px"]);
  writes.length = 0;

  // Growing again then clearing jumps straight to cached baseHeight without 'auto'.
  el.value = "a\nb\nc";
  syncTextareaHeight(el, state);
  writes.length = 0;
  el.value = "";
  assert.equal(syncTextareaHeight(el, state), true);
  assert.deepEqual(writes, ["34px"]);
});

test("syncTextareaHeight clamps at maxHeight and stops writing once clamped", () => {
  const { el, writes } = fakeTextarea("");
  const state = createTextareaHeightState();
  syncTextareaHeight(el, state, 100);
  writes.length = 0;

  el.value = "1\n2\n3\n4\n5\n6";
  assert.equal(syncTextareaHeight(el, state, 100), true);
  assert.deepEqual(writes, ["100px"]);
  writes.length = 0;

  el.value += "\n7";
  assert.equal(syncTextareaHeight(el, state, 100), false);
  assert.deepEqual(writes, []);
});

test("syncTextareaHeight ignores hidden zero-height mount until visible", () => {
  const writes = [];
  let hidden = true;
  const el = {
    value: "",
    get scrollHeight() {
      return hidden ? 0 : 32;
    },
    get clientHeight() {
      return hidden ? 0 : 32;
    },
    style: {
      height: "",
    },
  };
  Object.defineProperty(el.style, "height", {
    get: () => "",
    set: (v) => writes.push(v),
  });
  const state = createTextareaHeightState();
  assert.equal(syncTextareaHeight(el, state), false);
  assert.equal(state.height, 0);

  hidden = false;
  assert.equal(syncTextareaHeight(el, state), true);
  assert.equal(state.height, 34);
  assert.equal(state.baseHeight, 34);
});
