// While a reply runs, the composer sends in one of four ways: queue the
// message for when the reply ends, steer the live turn in-place, ask a side
// instance about the reply without stopping it, or interrupt it. Pure helpers;
// the components live in app/(app)/chat/_components (send-modes.tsx, followups.tsx, asides.tsx).

export type SendMode = "followup" | "steer" | "aside" | "interrupt";

/** In switcher order. Follow-up comes first: Enter never changes or throws away work in progress unless asked to. */
export const SEND_MODES: SendMode[] = ["followup", "steer", "aside", "interrupt"];

export const SEND_MODE_LABEL: Record<SendMode, string> = {
  followup: "Follow-up",
  steer: "Steer",
  aside: "Aside",
  interrupt: "Interrupt",
};

/** What each mode does, for its title and the Send button's. */
export const SEND_MODE_HINT: Record<SendMode, string> = {
  followup: "Send this once the current reply ends",
  steer: "Steer the active reply mid-turn without losing progress",
  aside: "Ask about the current reply without stopping it",
  interrupt: "Stop the reply and answer this together with your last message",
};

/** Tab moves to the next mode, Shift+Tab to the previous one. */
export function cycleSendMode(mode: SendMode, back = false): SendMode {
  const i = SEND_MODES.indexOf(mode);
  return SEND_MODES[(i + (back ? SEND_MODES.length - 1 : 1)) % SEND_MODES.length];
}

/** The Send button's name: what pressing it does. */
export function sendModeAction(mode: SendMode): string {
  switch (mode) {
    case "followup":
      return "Queue";
    case "steer":
      return "Steer";
    case "aside":
      return "Ask aside";
    case "interrupt":
      return "Interrupt";
  }
}

/** What Enter does in each mode, for the hint under the box. */
export const SEND_MODE_ENTER: Record<SendMode, string> = {
  followup: "queues it",
  steer: "steers mid-turn",
  aside: "asks it on the side",
  interrupt: "interrupts",
};

export function sendModePlaceholder(mode: SendMode, name: string): string {
  switch (mode) {
    case "followup":
      return `Queue a follow-up for when ${name} finishes…`;
    case "steer":
      return `Steer ${name} mid-turn without discarding work…`;
    case "aside":
      return `Ask on the side. ${name} keeps working…`;
    case "interrupt":
      return `Stop ${name} and steer it…`;
  }
}

/** /aside, /queue, and /steer send their text in that mode, whichever one is picked. */
export function commandSendMode(name: string): SendMode | null {
  return name === "aside" ? "aside" : name === "queue" ? "followup" : name === "steer" ? "steer" : null;
}

type Dated = { created_at: string; anchor_message_id?: string; second_opinion?: boolean };

/** The asides asked during a turn, from its start up to (not including) the next turn's; threads and second opinions aren't among them. */
export function asidesInWindow<T extends Dated>(asides: T[] | undefined, since?: string, until?: string): T[] {
  if (!asides?.length || !since) return [];
  const from = Date.parse(since);
  const to = until ? Date.parse(until) : Infinity;
  return asides.filter((a) => {
    // A thread or second opinion belongs to its card/anchor, not to the generic turn aside rail.
    if (a.anchor_message_id || a.second_opinion) return false;
    const at = Date.parse(a.created_at);
    return at >= from && at < to;
  });
}

/** "2 asides", "1 aside". */
export function asideCount(n: number): string {
  return `${n} aside${n === 1 ? "" : "s"}`;
}
