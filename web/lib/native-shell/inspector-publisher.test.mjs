import test from "node:test";
import assert from "node:assert/strict";
import {
  createInspectorPublisher,
  isInspectorCommand,
} from "./inspector-publisher.ts";

function sampleModel(id, open = true, activeTabId = "chat") {
  return {
    id,
    open,
    activeTabId,
    tabs: [{ id: activeTabId, label: id, icon: "msg", kind: "companion" }],
  };
}

test("latest-wins inspector registration, deduplication, and restore", () => {
  const sent = [];
  const pub = createInspectorPublisher({ send: (m) => sent.push(m), delayMs: 0 });
  const fallback = Symbol("default");
  const screen = Symbol("doc");

  pub.set(fallback, { model: sampleModel("companion", false) });
  pub.flush();
  assert.equal(sent.length, 1);
  assert.equal(sent[0].model?.id, "companion");

  // Repeated identical update is deduped.
  pub.set(fallback, { model: sampleModel("companion", false) });
  pub.flush();
  assert.equal(sent.length, 1);

  // Screen model overrides default companion.
  pub.set(screen, { model: sampleModel("doc:d1", true, "properties") });
  pub.flush();
  assert.equal(sent.length, 2);
  assert.equal(sent[1].model?.id, "doc:d1");

  // Clearing screen restores default companion.
  pub.clear(screen);
  pub.flush();
  assert.equal(sent.length, 3);
  assert.equal(sent[2].model?.id, "companion");

  // Clearing everything sends null.
  pub.clear(fallback);
  pub.flush();
  assert.equal(sent.length, 4);
  assert.equal(sent[3].model, null);
});

test("dispatchCommand routes inspector commands only to the active owner", () => {
  const pub = createInspectorPublisher({ send: () => {}, delayMs: 0 });
  const fallback = Symbol("default");
  const screen = Symbol("run");
  const fallbackCmds = [];
  const screenCmds = [];

  pub.set(fallback, { model: sampleModel("companion"), onCommand: (c) => fallbackCmds.push(c) });
  pub.set(screen, { model: sampleModel("run:r1"), onCommand: (c) => screenCmds.push(c) });

  assert.equal(pub.dispatchCommand({ v: 1, type: "navigate", path: "/spaces" }), false);
  assert.equal(pub.dispatchCommand({ v: 1, type: "inspector.visibility", open: false }), true);
  assert.equal(pub.dispatchCommand({ v: 1, type: "inspector.selectTab", tabId: "chat" }), true);
  assert.equal(pub.dispatchCommand({ v: 1, type: "inspector.action", tabId: "context", actionId: "cancel" }), true);
  assert.equal(pub.dispatchCommand({ v: 1, type: "inspector.change", tabId: "properties", fieldId: "priority", value: "high" }), true);
  assert.equal(pub.dispatchCommand({ v: 1, type: "inspector.toggle", tabId: "properties", fieldId: "mockup", checked: true }), true);
  assert.equal(pub.dispatchCommand({ v: 1, type: "panel.event", tabId: "playground", event: "openFull" }), true);

  assert.equal(fallbackCmds.length, 0);
  assert.deepEqual(screenCmds.map((c) => c.type), [
    "inspector.visibility",
    "inspector.selectTab",
    "inspector.action",
    "inspector.change",
    "inspector.toggle",
    "panel.event",
  ]);
  assert.equal(isInspectorCommand({ v: 1, type: "inspector.toggle", tabId: "t", fieldId: "f", checked: false }), true);
  assert.equal(isInspectorCommand({ v: 1, type: "panel.event", tabId: "playground", event: "openFull" }), true);
  assert.equal(isInspectorCommand({ v: 1, type: "companion.context", context: {} }), false);
});
