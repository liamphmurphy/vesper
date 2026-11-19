// What the page tells the shell about the native right inspector (InspectorModel).
// Latest-wins registration matching publisher.ts so a screen's own Dock overrides
// DefaultCompanion while mounted, and unmounting restores DefaultCompanion.
// No React; clock and transport are injectable for tests.

import type { WorkSubject } from "../work-context.ts";
import { postDeduped } from "./bridge.ts";
import type { CompanionSubject, InspectorModel, NativeCommand, PageMessage } from "./protocol.ts";

export type InspectorCommand = Extract<
  NativeCommand,
  {
    type:
      | "inspector.visibility"
      | "inspector.selectTab"
      | "inspector.action"
      | "inspector.change"
      | "inspector.toggle";
  }
>;

export interface InspectorRegistration {
  model: InspectorModel;
  onCommand?: (cmd: InspectorCommand) => void;
}

export interface InspectorPublisherDeps {
  send: (msg: PageMessage) => void;
  delayMs: number;
}

const INSPECTOR_COMMAND_TYPES = new Set<string>([
  "inspector.visibility",
  "inspector.selectTab",
  "inspector.action",
  "inspector.change",
  "inspector.toggle",
]);

export function isInspectorCommand(cmd: NativeCommand): cmd is InspectorCommand {
  return INSPECTOR_COMMAND_TYPES.has(cmd.type);
}

export function toCompanionSubject(subject?: WorkSubject): CompanionSubject | undefined {
  if (!subject) return undefined;
  if (subject.kind === "ticket") {
    return { kind: "ticket", id: subject.key, title: subject.title, ticketKey: subject.key };
  }
  return {
    kind: "run",
    id: subject.id,
    title: subject.title,
    agent: subject.agent,
    ...(subject.ticketKey ? { ticketKey: subject.ticketKey } : {}),
  };
}

export function fromCompanionSubject(subject?: CompanionSubject): WorkSubject | undefined {
  if (!subject) return undefined;
  if (subject.kind === "ticket") {
    return { kind: "ticket", key: subject.ticketKey || subject.id, title: subject.title };
  }
  return {
    kind: "run",
    id: subject.id,
    title: subject.title,
    agent: subject.agent || "Agent",
    ...(subject.ticketKey ? { ticketKey: subject.ticketKey } : {}),
  };
}

export function createInspectorPublisher(deps: InspectorPublisherDeps) {
  const entries = new Map<symbol, InspectorRegistration>();
  let timer: ReturnType<typeof setTimeout> | undefined;
  let lastModel = "null";

  const activeEntry = (): InspectorRegistration | undefined => [...entries.values()].at(-1);

  function sendNow() {
    timer = undefined;
    const model = activeEntry()?.model ?? null;
    const json = JSON.stringify(model);
    if (json !== lastModel) {
      lastModel = json;
      deps.send({ v: 1, type: "inspector", model });
    }
  }

  function schedule() {
    if (timer === undefined) timer = setTimeout(sendNow, deps.delayMs);
  }

  return {
    set(token: symbol, entry: InspectorRegistration | null) {
      if (entry) {
        entries.delete(token);
        entries.set(token, entry);
      } else {
        entries.delete(token);
      }
      schedule();
    },
    clear(token: symbol) {
      entries.delete(token);
      schedule();
    },
    dispatchCommand(cmd: NativeCommand): boolean {
      if (!isInspectorCommand(cmd)) return false;
      activeEntry()?.onCommand?.(cmd);
      return true;
    },
    flush() {
      if (timer !== undefined) clearTimeout(timer);
      sendNow();
    },
  };
}

/** The page's one inspector publisher. */
export const inspectorPublisher = createInspectorPublisher({ send: postDeduped, delayMs: 25 });
