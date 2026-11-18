import test from "node:test";
import assert from "node:assert/strict";
import { splitActions } from "./actions.ts";

test("items lose their handlers and dispatch runs the right one", () => {
  const calls = [];
  const { items, dispatch } = splitActions([
    { id: "a", label: "A", kind: "button", run: () => calls.push("a") },
    { id: "m", label: "M", kind: "menu", menu: [
      { id: "m1", label: "One", run: () => calls.push("m1") },
      { id: "sep", separator: true },
      { id: "sub", label: "Sub", children: [{ id: "m2", label: "Two", run: () => calls.push("m2") }] },
      { id: "off", label: "Off", disabled: true, run: () => calls.push("off") },
    ] },
    { id: "d", label: "D", kind: "button", disabled: true, run: () => calls.push("d") },
  ]);
  assert.equal(JSON.stringify(items).includes("run"), false);
  assert.equal(items[1].menu[2].children[0].id, "m2");
  dispatch("a"); dispatch("m", "m1"); dispatch("m", "m2"); dispatch("m", "off"); dispatch("d"); dispatch("nope"); dispatch("a", "m1");
  assert.deepEqual(calls, ["a", "m1", "m2"]);
});
