import assert from "node:assert/strict";
import test from "node:test";
import { createSseClient } from "./sse-multiplexer.ts";

function createTestHub() {
  const channels = new Map();
  const streams = [];
  const locks = new Map();
  const activeLocks = new Set();

  class MockChannel {
    constructor(name) {
      this.name = name;
      this.onmessage = null;
      this.closed = false;
      let group = channels.get(name);
      if (!group) {
        group = new Set();
        channels.set(name, group);
      }
      group.add(this);
    }

    postMessage(message) {
      if (this.closed) return;
      const group = channels.get(this.name);
      if (!group) return;
      for (const peer of group) {
        if (peer !== this && !peer.closed) {
          peer.onmessage?.({ data: structuredClone(message) });
        }
      }
    }

    close() {
      this.closed = true;
      channels.get(this.name)?.delete(this);
    }
  }

  class MockEventSource {
    constructor(url) {
      this.url = url;
      this.closed = false;
      this.onopen = null;
      this.onerror = null;
      this.onmessage = null;
      streams.push(this);
    }

    emitOpen() {
      if (!this.closed) this.onopen?.({});
    }

    emitError() {
      if (!this.closed) this.onerror?.({});
    }

    emitMessage(data) {
      if (!this.closed) this.onmessage?.({ data: typeof data === "string" ? data : JSON.stringify(data) });
    }

    close() {
      this.closed = true;
    }
  }

  const pumpQueue = (name) => {
    if (activeLocks.has(name)) return;
    const queue = locks.get(name);
    const next = queue?.shift();
    if (!next) return;
    activeLocks.add(name);
    Promise.resolve()
      .then(() => next.run())
      .then(
        () => {
          activeLocks.delete(name);
          next.resolveOuter();
          pumpQueue(name);
        },
        (err) => {
          activeLocks.delete(name);
          next.rejectOuter(err);
          pumpQueue(name);
        },
      );
  };

  const requestLock = (name, callback) => {
    return new Promise((resolveOuter, rejectOuter) => {
      let queue = locks.get(name);
      if (!queue) {
        queue = [];
        locks.set(name, queue);
      }
      queue.push({ run: callback, resolveOuter, rejectOuter });
      pumpQueue(name);
    });
  };

  return {
    streams,
    createChannel: (name) => new MockChannel(name),
    createEventSource: (url) => new MockEventSource(url),
    requestLock,
  };
}

const tick = () => new Promise((r) => setTimeout(r, 0));

test("multiple tabs elect a single leader and relay events and status to followers", async () => {
  const hub = createTestHub();
  const eventsByTab = [[], [], []];
  const statusesByTab = [[], [], []];

  const clients = [0, 1, 2].map((i) =>
    createSseClient({
      url: "/events",
      createChannel: hub.createChannel,
      createEventSource: hub.createEventSource,
      requestLock: hub.requestLock,
      addUnloadListener: () => () => {},
      onEvent: (p) => eventsByTab[i].push(p),
      onStatus: (offline) => statusesByTab[i].push(offline),
    }),
  );

  await tick();
  assert.equal(clients[0].mode, "multiplex");
  assert.equal(hub.streams.length, 1);

  hub.streams[0].emitOpen();
  hub.streams[0].emitMessage({ type: "ticket.updated", ids: ["t-1"] });
  hub.streams[0].emitError();

  for (let i = 0; i < 3; i++) {
    assert.deepEqual(eventsByTab[i], [{ type: "ticket.updated", ids: ["t-1"] }]);
    assert.deepEqual(statusesByTab[i], [false, true]);
  }

  for (const c of clients) c.stop();
});

test("follower receives current offline status via hello when joining after leader", async () => {
  const hub = createTestHub();
  const lateStatuses = [];

  const leader = createSseClient({
    createChannel: hub.createChannel,
    createEventSource: hub.createEventSource,
    requestLock: hub.requestLock,
    addUnloadListener: () => () => {},
    onEvent: () => {},
  });

  await tick();
  hub.streams[0].emitError();

  const follower = createSseClient({
    createChannel: hub.createChannel,
    createEventSource: hub.createEventSource,
    requestLock: hub.requestLock,
    addUnloadListener: () => () => {},
    onEvent: () => {},
    onStatus: (offline) => lateStatuses.push(offline),
  });

  await tick();
  assert.equal(hub.streams.length, 1);
  assert.deepEqual(lateStatuses, [true]);

  follower.stop();
  leader.stop();
});

test("when the leader closes, a follower promotes itself and opens a new EventSource", async () => {
  const hub = createTestHub();
  const tab1Events = [];
  const tab2Events = [];

  const tab1 = createSseClient({
    createChannel: hub.createChannel,
    createEventSource: hub.createEventSource,
    requestLock: hub.requestLock,
    addUnloadListener: () => () => {},
    onEvent: (p) => tab1Events.push(p),
  });
  const tab2 = createSseClient({
    createChannel: hub.createChannel,
    createEventSource: hub.createEventSource,
    requestLock: hub.requestLock,
    addUnloadListener: () => () => {},
    onEvent: (p) => tab2Events.push(p),
  });

  await tick();
  assert.equal(hub.streams.length, 1);

  tab1.stop();
  await tick();
  await tick();

  assert.equal(hub.streams[0].closed, true);
  assert.equal(hub.streams.length, 2);
  assert.equal(hub.streams[1].closed, false);

  hub.streams[1].emitMessage({ type: "run.events", ids: ["run-9"] });
  assert.deepEqual(tab1Events, []);
  assert.deepEqual(tab2Events, [{ type: "run.events", ids: ["run-9"] }]);

  tab2.stop();
});

test("falls back to direct EventSource when Web Locks or BroadcastChannel are unavailable", () => {
  const hub = createTestHub();
  const received = [];
  const statuses = [];

  const client = createSseClient({
    createEventSource: hub.createEventSource,
    createChannel: undefined,
    requestLock: undefined,
    addUnloadListener: () => () => {},
    onEvent: (p) => received.push(p),
    onStatus: (offline) => statuses.push(offline),
  });

  assert.equal(client.mode, "direct");
  assert.equal(hub.streams.length, 1);

  hub.streams[0].emitOpen();
  hub.streams[0].emitMessage({ type: "reset" });
  hub.streams[0].emitMessage("not-json");
  assert.deepEqual(statuses, [false]);
  assert.deepEqual(received, [{ type: "reset" }]);

  client.stop();
  assert.equal(hub.streams[0].closed, true);
});

test("6+ simultaneous tabs share 1 active EventSource stream", async () => {
  const hub = createTestHub();
  const received = Array.from({ length: 8 }, () => []);
  const clients = received.map((bucket) =>
    createSseClient({
      createChannel: hub.createChannel,
      createEventSource: hub.createEventSource,
      requestLock: hub.requestLock,
      addUnloadListener: () => () => {},
      onEvent: (p) => bucket.push(p),
    }),
  );

  await tick();
  assert.equal(hub.streams.length, 1);

  hub.streams[0].emitMessage({ type: "inbox.updated" });
  for (const bucket of received) {
    assert.deepEqual(bucket, [{ type: "inbox.updated" }]);
  }

  for (const c of clients) c.stop();
});
