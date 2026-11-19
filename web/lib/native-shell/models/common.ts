// Small helpers shared by the screen models.
import { initials } from "../chats-model.ts";
import { DUSK } from "../../palette-defaults.ts";
import type { Avatar, Tone } from "../protocol.ts";

const AGENT_HUES = ["atlas", "quill", "sentry", "juno", "nova", "relay", "pike", "echo"] as const;

/**
 * A persona's identity color as a literal hex (the avatar's `color`): the active palette's
 * --agent-<hue> when running in a page, else the default dark palette's.
 */
export function agentAvatarColor(colorIndex: number): string {
  const hue = AGENT_HUES[((colorIndex % AGENT_HUES.length) + AGENT_HUES.length) % AGENT_HUES.length];
  if (typeof document !== "undefined") {
    const value = getComputedStyle(document.documentElement).getPropertyValue(`--agent-${hue}`).trim();
    if (/^#[\da-f]{6}$/i.test(value)) return value;
  }
  return (DUSK.dark as Record<string, string>)[`agent-${hue}`];
}

/** An avatar for the shell: initials, a literal color only, and an absolute image url. */
export function navAvatar(name: string, color?: string, imageUrl?: string | null, origin?: string): Avatar {
  const a: Avatar = { initials: initials(name) };
  if (color && /^#|^rgb|^hsl/i.test(color)) a.color = color;
  if (imageUrl) {
    try {
      a.imageUrl = origin ? new URL(imageUrl, origin).toString() : imageUrl;
    } catch {
      /* no image */
    }
  }
  return a;
}

/** The page's origin for absolute avatar urls; undefined while rendering on the server. */
export function pageOrigin(): string | undefined {
  return typeof window === "undefined" ? undefined : window.location.origin;
}

const TICKET_TONES: Record<string, Tone> = {
  done: "done",
  in_progress: "accent",
  in_review: "warning",
  canceled: "neutral",
  todo: "neutral",
  backlog: "neutral",
};

export function ticketStatusTone(status: string): Tone {
  return TICKET_TONES[status] ?? "neutral";
}

const RUN_TONES: Record<string, Tone> = {
  running: "done",
  queued: "neutral",
  starting: "accent",
  waiting: "human",
  paused: "human",
  waiting_for_quota: "warning",
  blocked: "blocked",
  failed: "blocked",
  completed: "done",
  cancelled: "neutral",
};

export function runStateTone(state: string): Tone {
  return RUN_TONES[state] ?? "neutral";
}

const HEALTH_TONES: Record<string, Tone> = {
  on_track: "done",
  at_risk: "warning",
  off_track: "blocked",
};

export function epicHealthTone(health: string): Tone {
  return HEALTH_TONES[health] ?? "neutral";
}
