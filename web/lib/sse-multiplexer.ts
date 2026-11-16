export type SsePayload = { type: string; ids?: unknown; [k: string]: unknown };

export interface EventSourceLike {
  onopen: ((ev: unknown) => void) | null;
  onerror: ((ev: unknown) => void) | null;
  onmessage: ((ev: { data: string }) => void) | null;
  close(): void;
}

export interface BroadcastChannelLike {
  onmessage: ((ev: { data: unknown }) => void) | null;
  postMessage(message: unknown): void;
  close(): void;
}

export type RequestLockFn = (name: string, callback: () => Promise<void>) => Promise<void>;

type MultiplexMessage =
  | { kind: "event"; payload: SsePayload }
  | { kind: "status"; offline: boolean }
  | { kind: "hello" };

export interface SseMultiplexerOptions {
  url?: string;
  channelName?: string;
  lockName?: string;
  onEvent: (payload: SsePayload) => void;
  onStatus?: (offline: boolean) => void;
  createEventSource?: (url: string) => EventSourceLike;
  createChannel?: (name: string) => BroadcastChannelLike | undefined;
  requestLock?: RequestLockFn;
  addUnloadListener?: (fn: () => void) => () => void;
}

export interface SseClient {
  stop(): void;
  readonly mode: "multiplex" | "direct";
}

function defaultCreateEventSource(url: string): EventSourceLike {
  const es = new EventSource(url);
  const like: EventSourceLike = {
    onopen: null,
    onerror: null,
    onmessage: null,
    close: () => es.close(),
  };
  es.onopen = (ev) => like.onopen?.(ev);
  es.onerror = (ev) => like.onerror?.(ev);
  es.onmessage = (ev) => like.onmessage?.({ data: String(ev.data) });
  return like;
}

function defaultCreateChannel(name: string): BroadcastChannelLike | undefined {
  if (typeof BroadcastChannel === "undefined") return undefined;
  const ch = new BroadcastChannel(name);
  const like: BroadcastChannelLike = {
    onmessage: null,
    postMessage: (message) => ch.postMessage(message),
    close: () => ch.close(),
  };
  ch.onmessage = (ev) => like.onmessage?.({ data: ev.data });
  return like;
}

function defaultRequestLock(): RequestLockFn | undefined {
  if (typeof navigator === "undefined" || !navigator.locks || typeof navigator.locks.request !== "function") {
    return undefined;
  }
  return (name, callback) => navigator.locks.request(name, callback).then(() => undefined);
}

function defaultAddUnloadListener(fn: () => void): () => void {
  if (typeof window === "undefined" || typeof window.addEventListener !== "function") {
    return () => {};
  }
  window.addEventListener("pagehide", fn);
  window.addEventListener("beforeunload", fn);
  return () => {
    window.removeEventListener("pagehide", fn);
    window.removeEventListener("beforeunload", fn);
  };
}

/**
 * Coordinates same-origin tabs so only one elected leader holds EventSource("/events")
 * and relays parsed SSE payloads and connection status via BroadcastChannel.
 * Falls back to a direct EventSource when Web Locks or BroadcastChannel are unavailable.
 */
export function createSseClient(options: SseMultiplexerOptions): SseClient {
  const url = options.url ?? "/events";
  const channelName = options.channelName ?? `vesper:sse:${url}`;
  const lockName = options.lockName ?? `vesper:sse:${url}:leader`;
  const createEventSource = options.createEventSource ?? defaultCreateEventSource;
  const createChannel = "createChannel" in options ? options.createChannel : defaultCreateChannel;
  const requestLock = "requestLock" in options ? options.requestLock : defaultRequestLock();
  const addUnloadListener = options.addUnloadListener ?? defaultAddUnloadListener;

  let stopped = false;
  let directStream: EventSourceLike | null = null;

  const startDirect = () => {
    if (stopped || directStream) return;
    const stream = createEventSource(url);
    directStream = stream;
    stream.onopen = () => {
      if (!stopped) options.onStatus?.(false);
    };
    stream.onerror = () => {
      if (!stopped) options.onStatus?.(true);
    };
    stream.onmessage = (ev) => {
      if (stopped) return;
      try {
        const payload = JSON.parse(ev.data) as SsePayload;
        options.onEvent(payload);
      } catch {
        /* Ignore malformed hints; reconnect resets every cache. */
      }
    };
  };

  if (!createChannel || !requestLock) {
    startDirect();
    return {
      mode: "direct",
      stop() {
        stopped = true;
        directStream?.close();
        directStream = null;
      },
    };
  }

  let channel: BroadcastChannelLike | undefined;
  try {
    channel = createChannel(channelName);
  } catch {
    channel = undefined;
  }

  if (!channel) {
    startDirect();
    return {
      mode: "direct",
      stop() {
        stopped = true;
        directStream?.close();
        directStream = null;
      },
    };
  }

  let isLeader = false;
  let hasStatus = false;
  let lastOffline = false;
  let leaderStream: EventSourceLike | null = null;
  let releaseLock: (() => void) | null = null;

  const setStatus = (offline: boolean) => {
    hasStatus = true;
    lastOffline = offline;
    options.onStatus?.(offline);
    if (isLeader && !stopped) {
      channel.postMessage({ kind: "status", offline } satisfies MultiplexMessage);
    }
  };

  channel.onmessage = (ev) => {
    if (stopped) return;
    const msg = ev.data as MultiplexMessage | null | undefined;
    if (!msg || typeof msg !== "object") return;
    if (msg.kind === "hello") {
      if (isLeader && hasStatus) {
        channel.postMessage({ kind: "status", offline: lastOffline } satisfies MultiplexMessage);
      }
      return;
    }
    if (isLeader) return;
    if (msg.kind === "status") {
      options.onStatus?.(Boolean(msg.offline));
    } else if (msg.kind === "event" && msg.payload) {
      options.onEvent(msg.payload);
    }
  };

  const stop = () => {
    if (stopped) return;
    stopped = true;
    removeUnload();
    leaderStream?.close();
    leaderStream = null;
    directStream?.close();
    directStream = null;
    isLeader = false;
    const release = releaseLock;
    releaseLock = null;
    release?.();
    channel.close();
  };

  const removeUnload = addUnloadListener(stop);

  // Ask an existing leader (if any) for its current connection status.
  channel.postMessage({ kind: "hello" } satisfies MultiplexMessage);

  void requestLock(lockName, () => {
    if (stopped) return Promise.resolve();
    isLeader = true;
    const stream = createEventSource(url);
    leaderStream = stream;
    stream.onopen = () => {
      if (!stopped) setStatus(false);
    };
    stream.onerror = () => {
      if (!stopped) setStatus(true);
    };
    stream.onmessage = (ev) => {
      if (stopped) return;
      try {
        const payload = JSON.parse(ev.data) as SsePayload;
        options.onEvent(payload);
        channel.postMessage({ kind: "event", payload } satisfies MultiplexMessage);
      } catch {
        /* Ignore malformed hints; reconnect resets every cache. */
      }
    };
    return new Promise<void>((resolve) => {
      releaseLock = resolve;
    });
  }).catch(() => {
    if (!stopped && !isLeader) {
      startDirect();
    }
  });

  return {
    mode: "multiplex",
    stop,
  };
}
