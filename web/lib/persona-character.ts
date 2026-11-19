import type { CSSProperties } from "react";
import type { ChatStatusKind } from "./chat-ui.ts";
import type { DockState } from "./persona-dock.ts";

export const CHARACTER_MOTIONS = [
  "none",
  "breathe",
  "float",
  "blink",
  "glance",
  "tilt",
  "nod",
  "sway",
  "wag",
  "wag-fast",
  "tap",
  "type",
  "bounce",
  "wave",
  "scan",
  "orbit",
  "spark",
  "pulse",
  "shadow",
] as const;
export type CharacterMotion = (typeof CHARACTER_MOTIONS)[number];

export const CHARACTER_SHOW_STATES = [
  "idle",
  "working",
  "thinking",
  "reading",
  "coding",
  "creating",
  "needs-you",
] as const;
export type CharacterShowToken = (typeof CHARACTER_SHOW_STATES)[number];

export const CHARACTER_SPEEDS = ["slow", "normal", "fast"] as const;
export type CharacterSpeed = (typeof CHARACTER_SPEEDS)[number];

export type CharacterState =
  | "static"
  | "idle"
  | "working"
  | "thinking"
  | "reading"
  | "coding"
  | "creating"
  | "needs_you";

export const CHARACTER_PREVIEW_STATES: readonly { value: Exclude<CharacterState, "static" | "working">; label: string }[] = [
  { value: "idle", label: "Idle" },
  { value: "thinking", label: "Thinking" },
  { value: "reading", label: "Reading" },
  { value: "coding", label: "Coding" },
  { value: "creating", label: "Creating" },
  { value: "needs_you", label: "Needs you" },
];

type ActiveWorkState = "thinking" | "reading" | "coding" | "creating" | "needs_you";

/** Exhaustive map from every ChatStatusKind to an action-reactive character state. */
const STATUS_TO_CHARACTER_STATE: Record<ChatStatusKind, ActiveWorkState> = {
  thinking: "thinking",
  "next-step": "thinking",
  memory: "thinking",
  "memory-save": "thinking",
  inbox: "thinking",
  choices: "thinking",
  subagent: "thinking",
  learning: "thinking",

  "reading-code": "reading",
  "searching-code": "reading",
  wiki: "reading",
  "ticket-lookup": "reading",
  "chat-history": "reading",
  "repo-search": "reading",
  web: "reading",
  "web-page": "reading",
  "saved-links": "reading",
  research: "reading",
  library: "reading",
  projects: "reading",
  "image-view": "reading",
  "design-view": "reading",
  "repo-history": "reading",
  finance: "reading",
  runs: "reading",
  schedule: "reading",

  "writing-code": "coding",
  tests: "coding",
  build: "coding",
  install: "coding",
  terminal: "coding",
  github: "coding",
  commit: "coding",
  push: "coding",
  "pull-request": "coding",
  "repo-attach": "coding",
  playground: "coding",
  "custom-app": "coding",
  database: "coding",
  http: "coding",
  workflow: "coding",

  "writing-reply": "creating",
  canvas: "creating",
  "canvas-comment": "creating",
  design: "creating",
  image: "creating",
  video: "creating",
  "video-render": "creating",
  "audio-render": "creating",
  chart: "creating",
  diagram: "creating",
  app: "creating",
  pdf: "creating",
  persona: "creating",
  space: "creating",
  tickets: "creating",
  "finance-sort": "creating",

  connector: "needs_you",
  secret: "needs_you",
};

/** Picks the live character state for a running chat's status scene. */
export function characterStateForStatus(
  kind: ChatStatusKind,
  opts?: { awaiting?: boolean; stopping?: boolean },
): CharacterState {
  if (opts?.stopping) return "static";
  if (opts?.awaiting) return "needs_you";
  return STATUS_TO_CHARACTER_STATE[kind];
}

/** Picks the character state for a persona row in the dock/filter menu. */
export function characterStateForDock(state?: DockState): CharacterState {
  if (state === "needs_you") return "needs_you";
  if (state === "working") return "working";
  return "idle";
}

const WORK_STATES = new Set<CharacterState>(["working", "thinking", "reading", "coding", "creating"]);
const MOTION_SET = new Set<string>(CHARACTER_MOTIONS);
const SHOW_SET = new Set<string>(CHARACTER_SHOW_STATES);
const SPEED_MULT: Record<CharacterSpeed, string> = { slow: "1.5", normal: "1", fast: "0.65" };

export function parseCharacterPivot(raw?: string): string | undefined {
  if (!raw) return undefined;
  const parts = raw.trim().split(/\s+/);
  if (parts.length !== 2) return undefined;
  const x = Number(parts[0]);
  const y = Number(parts[1]);
  if (!Number.isFinite(x) || !Number.isFinite(y) || x < 0 || x > 64 || y < 0 || y > 64) return undefined;
  return `${x}px ${y}px`;
}

export function parseCharacterDelay(raw?: string): string | undefined {
  if (!raw) return undefined;
  const s = raw.trim().replace(/s$/i, "");
  if (!s) return undefined;
  const n = Number(s);
  if (!Number.isFinite(n) || n < -4 || n > 4) return undefined;
  return `${n}s`;
}

export function isValidCharacterShow(raw: string): boolean {
  const tokens = raw.trim().split(/\s+/).filter(Boolean);
  return tokens.length > 0 && tokens.every((t) => SHOW_SET.has(t));
}

export type ResolvedNodeMotion = {
  motion?: Exclude<CharacterMotion, "none">;
  hidden: boolean;
  style?: CSSProperties;
};

/**
 * Resolves the active CSS animation, visibility, pivot, delay, and speed for
 * one sanitized SVG node in `state`.
 */
export function resolveCharacterNodeStyle(attrs: Record<string, string>, state: CharacterState): ResolvedNodeMotion {
  let hidden = false;
  const showRaw = attrs["data-show"];
  if (showRaw) {
    const tokens = showRaw.trim().split(/\s+/);
    const token: CharacterShowToken =
      state === "static" ? "idle" : state === "needs_you" ? "needs-you" : state;
    const matches = tokens.includes(token) || (WORK_STATES.has(state) && tokens.includes("working"));
    if (!matches) hidden = true;
  }

  let chosen: string | undefined;
  if (state !== "static" && !hidden) {
    if (state === "idle") {
      chosen = attrs["data-motion-idle"];
    } else if (state === "working") {
      chosen = attrs["data-motion-working"];
    } else if (state === "needs_you") {
      chosen = attrs["data-motion-needs-you"] ?? attrs["data-motion-working"];
    } else {
      chosen = attrs[`data-motion-${state}`] ?? attrs["data-motion-working"];
    }
    if (chosen === undefined) {
      chosen = attrs["data-motion"];
    }
  }

  const motion =
    chosen && chosen !== "none" && MOTION_SET.has(chosen)
      ? (chosen as Exclude<CharacterMotion, "none">)
      : undefined;

  const style: Record<string, string | number> = {};
  if (hidden) {
    style.opacity = 0;
    style.pointerEvents = "none";
  }
  const pivot = parseCharacterPivot(attrs["data-pivot"]);
  if (pivot) style.transformOrigin = pivot;

  if (motion) {
    const delay = parseCharacterDelay(attrs["data-delay"]);
    if (delay) style.animationDelay = delay;
    const speed = attrs["data-speed"] as CharacterSpeed | undefined;
    if (speed && speed in SPEED_MULT && speed !== "normal") {
      style["--pc-speed"] = SPEED_MULT[speed];
    }
  }

  return {
    motion,
    hidden,
    style: Object.keys(style).length > 0 ? (style as CSSProperties) : undefined,
  };
}

/**
 * Reports which action states have explicit `data-motion-*` or `data-show`
 * rules in an SVG character so preview cards can highlight customized states.
 */
export function detectCharacterStates(svg: string): Set<CharacterState> {
  const out = new Set<CharacterState>();
  const motionAttrs: [string, CharacterState][] = [
    ["data-motion-idle", "idle"],
    ["data-motion-working", "working"],
    ["data-motion-thinking", "thinking"],
    ["data-motion-reading", "reading"],
    ["data-motion-coding", "coding"],
    ["data-motion-creating", "creating"],
    ["data-motion-needs-you", "needs_you"],
  ];
  for (const [attr, state] of motionAttrs) {
    if (new RegExp(`\\b${attr}\\s*=`, "i").test(svg)) out.add(state);
  }
  for (const match of svg.matchAll(/\bdata-show\s*=\s*["']([^"']*)["']/gi)) {
    for (const tok of match[1].trim().split(/\s+/)) {
      if (tok === "needs-you") out.add("needs_you");
      else if (tok === "idle" || tok === "working" || tok === "thinking" || tok === "reading" || tok === "coding" || tok === "creating") {
        out.add(tok);
      }
    }
  }
  return out;
}

const HEX_COLOR = /^#[0-9a-f]{6}$/i;
const ROOT_OPEN = /<svg\b([^>]*)>/i;

/**
 * Prepares an SVG character's idle frame for offscreen rasterization to a PNG
 * fallback: resolves `currentColor`, ensures xmlns/256x256 bounds, and hides
 * non-idle `data-show` layers.
 */
export function prepareCharacterSvgForRaster(svg: string, color: string, size = 256): string {
  const safeColor = HEX_COLOR.test(color) ? color : "#64748b";
  let out = svg.trim().replace(/\bcurrentColor\b/gi, safeColor);
  out = out.replace(ROOT_OPEN, (_full, rawAttrs: string) => {
    let attrs = rawAttrs;
    if (!/\bxmlns\s*=/.test(attrs)) attrs += ' xmlns="http://www.w3.org/2000/svg"';
    attrs = attrs.replace(/\s+\b(?:width|height)\s*=\s*(?:"[^"]*"|'[^']*')/gi, "");
    return `<svg${attrs} width="${size}" height="${size}">`;
  });
  const m = ROOT_OPEN.exec(out);
  if (m && !out.slice(m.index, m.index + m[0].length).endsWith("/>")) {
    const at = m.index + m[0].length;
    out = `${out.slice(0, at)}<style>[data-show]:not([data-show~="idle"]){display:none}</style>${out.slice(at)}`;
  }
  return out;
}
