"use client";

import { useRouter } from "next/navigation";
import { useCallback, useEffect, useState, useSyncExternalStore, type CSSProperties } from "react";
import { DropdownMenu } from "radix-ui";
import type { Schemas } from "@/lib/api/client";
import { usePersonas } from "@/lib/api/persona-hooks";
import { cx } from "@/lib/cx";
import type { CharacterState } from "@/lib/persona-character";
import { inChatList } from "@/lib/persona-ui";
import type { StateMediaSummary } from "@/lib/persona-state-media";
import { hasLoops } from "@/lib/persona-state-media";
import { PersonaCharacterView } from "@/components/domain/persona-character";
import { PersonaStateStage } from "@/components/domain/persona-state-stage";
import { Icon, type IconName } from "@/components/ui/icon";
import { floatPanel } from "@/components/domain/pickers";

// Persona pickers, avatars and names for chats. A persona that works is also named on
// tickets and runs, by the same id.

type Persona = Schemas["Persona"];
type Summary = Schemas["PersonaSummary"];
/** What a chat needs to show who it is talking to; a null persona is the built-in Assistant. */
export type PersonaLook = { id?: string; name: string; color: string; avatar_url?: string; character_svg?: string; has_character?: boolean };

/** Resolves a persona's animated SVG character from the look itself or the cached personas list. */
export function usePersonaCharacterSvg(persona: PersonaLook): string | undefined {
  const q = usePersonas();
  if (persona.character_svg) return persona.character_svg;
  if (!persona.id) return undefined;
  return q.data?.personas.find((p) => p.id === persona.id)?.character_svg;
}

/** A persona's photorealistic state loops, from the cached personas list; undefined without any. */
export function usePersonaStateMedia(persona: PersonaLook): StateMediaSummary | undefined {
  const q = usePersonas();
  if (!persona.id) return undefined;
  const media = q.data?.personas.find((p) => p.id === persona.id)?.state_media;
  return hasLoops(media) ? media : undefined;
}

/** The built-in Assistant: chats without a persona, or whose persona was deleted. */
export const BUILTIN: PersonaLook = { name: "Assistant", color: "var(--accent)" };

export const personaLook = (p?: Summary | Persona | null): PersonaLook => p ?? BUILTIN;

/** The Assistant's own face (a wizard on the dusk gradient), until the person gives it a picture. */
export const ASSISTANT_MARK = "/assistant-mark.svg";
const avatarSrc = (p: PersonaLook) => p.avatar_url ?? (p.name === BUILTIN.name ? ASSISTANT_MARK : undefined);

const TONE: Record<Schemas["PersonaTone"], string> = {
  neutral: "Neutral",
  friendly: "Friendly",
  concise: "Concise",
  formal: "Formal",
  playful: "Playful",
};
export const toneLabel = (t?: Schemas["PersonaTone"]) => (t ? TONE[t] : "Neutral");

/** What a persona can be allowed to do, in display order. */
export const CAPABILITIES: { key: "code" | "images" | "svg" | "personas" | "workflows"; icon: IconName; label: string; title: string }[] = [
  { key: "code", icon: "terminal", label: "Write code", title: "Can write code" },
  { key: "images", icon: "artifacts", label: "Generate images", title: "Can generate images" },
  { key: "svg", icon: "library", label: "Create SVG images", title: "Can create SVG images" },
  { key: "personas", icon: "users", label: "Create personas", title: "Can propose new personas" },
  { key: "workflows", icon: "graph", label: "Create workflows", title: "Can propose workflows" },
];

/** Small icons for what a persona can do (code, images, SVG images, create personas, create workflows); nothing when it can't do any. */
export function CapabilityBadges({ capabilities, className }: { capabilities?: Schemas["PersonaCapabilities"]; className?: string }) {
  const granted = CAPABILITIES.filter((c) => capabilities?.[c.key]);
  if (!granted.length) return null;
  return (
    <span className={cx("inline-flex flex-none items-center gap-1 text-fg-tertiary", className)} data-testid="capability-badges">
      {granted.map((c) => (
        <span key={c.key} title={c.title} className="inline-flex items-center rounded bg-selected p-0.5">
          <Icon name={c.icon} size={12} />
          <span className="sr-only">{c.title}</span>
        </span>
      ))}
    </span>
  );
}

/** Animated SVG character (when present), avatar image cropped to a circle, or the initial on a tint of the persona color. */
export function PersonaAvatar({
  persona,
  size = 20,
  state = "static",
  framed = true,
  clipped = false,
  className,
}: {
  persona: PersonaLook;
  size?: number;
  state?: CharacterState;
  framed?: boolean;
  clipped?: boolean;
  className?: string;
}) {
  const characterSvg = usePersonaCharacterSvg(persona);
  const loops = usePersonaStateMedia(persona);
  const style: CSSProperties = { width: size, height: size };
  // An avatar that fails to load (removed, stale ?v=) falls back to the initial.
  const [broken, setBroken] = useState<string>();
  if (characterSvg) {
    return <PersonaCharacterView svg={characterSvg} color={persona.color} size={size} state={state} framed={framed} clipped={clipped} className={className} />;
  }
  // A full loop is unreadable at avatar size; the matching head crop stands in
  // when the persona has no picture of its own.
  const src = avatarSrc(persona) ?? loops?.head_url;
  if (src && broken !== src) {
    return (
      // A same-origin, private, cache-busted URL: next/image would only add a proxy hop.
      <img src={src} alt="" aria-hidden onError={() => setBroken(src)} className={cx("flex-none rounded-full object-cover", className)} style={style} />
    );
  }
  return (
    <span
      aria-hidden
      className={cx("grid flex-none place-items-center rounded-full font-semibold", className)}
      style={{
        ...style,
        fontSize: Math.round(size * 0.5),
        // Light themes mix the color toward the text color (--persona-ink) so the initial stays readable.
        color: `color-mix(in srgb, ${persona.color} var(--persona-ink), var(--text))`,
        background: `color-mix(in srgb, ${persona.color} var(--persona-tint), var(--bg))`,
      }}
    >
      {persona.name.trim().slice(0, 1).toUpperCase() || "A"}
    </span>
  );
}

/** Overlapping avatars of everyone in a group chat, host first. */
export function PersonaStack({ personas, size = 16 }: { personas: PersonaLook[]; size?: number }) {
  return (
    <span className="flex flex-none items-center" data-testid="persona-stack">
      {personas.map((p, i) => (
        <span key={p.id ?? p.name} className="rounded-full ring-2 ring-surface" style={{ marginLeft: i ? -Math.round(size / 3) : 0, zIndex: personas.length - i }}>
          <PersonaAvatar persona={p} size={size} clipped />
        </span>
      ))}
    </span>
  );
}

/** The persona's name in its color. */
export function PersonaName({ persona, className }: { persona: PersonaLook; className?: string }) {
  return (
    <span className={cx("font-semibold", className)} style={{ color: persona.color }}>
      {persona.name}
    </span>
  );
}

// ---- Sidebar filter: kept for the browser session, reset when the default changes.

/** "default" (the server's default), a persona id, or "all". */
export type FilterValue = string;
type Stored = { v: FilterValue; d: string };

const STORE_KEY = "lazyagents.assistant.persona-filter";
const listeners = new Set<() => void>();
function readStored(): string | null {
  try {
    return sessionStorage.getItem(STORE_KEY);
  } catch {
    return null;
  }
}
function subscribe(fn: () => void) {
  listeners.add(fn);
  return () => listeners.delete(fn);
}
function writeStored(s: Stored) {
  try {
    sessionStorage.setItem(STORE_KEY, JSON.stringify(s));
  } catch {
    /* Private mode: the choice lasts until the next render only. */
  }
  for (const fn of listeners) fn();
}
function parseStored(raw: string | null): Stored | null {
  if (!raw) return null;
  try {
    const s = JSON.parse(raw) as Stored;
    return typeof s?.v === "string" && typeof s?.d === "string" ? s : null;
  } catch {
    return null;
  }
}

export type PersonaFilterState = {
  /** The dropdown's value. */
  value: FilterValue;
  set: (v: FilterValue) => void;
  /** persona_id for GET /chats: "" lets the server use the default persona. */
  query: string;
  personas: Persona[];
  /** The default persona, or the built-in Assistant when there's none. */
  defaultLook: PersonaLook;
  defaultId?: string;
  error: unknown;
  loading: boolean;
  retry: () => void;
};

/**
 * The sidebar's persona filter. It starts on every persona; a pick lasts for the
 * browser session until the default changes. If personas can't load, the list
 * falls back to every conversation.
 */
export function usePersonaFilter(): PersonaFilterState {
  const q = usePersonas();
  const raw = useSyncExternalStore(subscribe, readStored, () => null);
  const personas = q.data?.personas ?? [];
  const defaultId = q.data?.default_persona_id;
  const defaultPersona = personas.find((p) => p.id === defaultId);
  const stored = parseStored(raw);
  // The list opens on every persona (a persona is who a chat is with, not a section of the list).
  // A stored pick made against another default, or for a persona that's gone, resets to all.
  let value: FilterValue = "all";
  if (stored && q.data && stored.d === (defaultId ?? "")) {
    if (stored.v === "default" || personas.some((p) => p.id === stored.v && p.id !== defaultId)) value = stored.v;
  }
  const query = q.isError ? "all" : value === "default" ? "" : value;
  return {
    value: q.isError ? "all" : value,
    set: (v) => writeStored({ v, d: defaultId ?? "" }),
    query,
    personas,
    defaultLook: personaLook(defaultPersona),
    defaultId,
    error: q.error,
    loading: q.isPending,
    retry: () => void q.refetch(),
  };
}

const DOCK_PERSONA_KEY = (dock: string) => `lazyagents.dock-persona.${dock}`;

/**
 * Who a dock's new chat starts with: the persona last used in that dock (Knowledge, the work chat),
 * else the default persona, else the built-in Assistant. `remember` records the open chat's persona.
 */
export function useDockPersona(dock: string): { id?: string; look: PersonaLook; remember: (id: string | undefined) => void } {
  const q = usePersonas();
  const [stored, setStored] = useState<string | null>(null);
  useEffect(() => {
    try {
      // eslint-disable-next-line react-hooks/set-state-in-effect -- reading browser-only storage after hydration
      setStored(localStorage.getItem(DOCK_PERSONA_KEY(dock)));
    } catch {
      /* No storage: the default persona. */
    }
  }, [dock]);
  const personas = q.data?.personas ?? [];
  const persona = personas.find((p) => p.id === stored) ?? personas.find((p) => p.id === q.data?.default_persona_id);
  const remember = useCallback((id: string | undefined) => {
    if (!id) return;
    setStored((cur) => (cur === id ? cur : id));
    try {
      localStorage.setItem(DOCK_PERSONA_KEY(dock), id);
    } catch {
      /* Not remembered. */
    }
  }, [dock]);
  return { id: persona?.id, look: personaLook(persona), remember };
}

/** Opens the persona manager (LAZYAGENTS-85). */
export function useOpenPersonaManager() {
  const router = useRouter();
  return () => router.push("/settings?section=personas");
}

const item =
  "flex h-9 cursor-default select-none items-center gap-2 rounded-md px-2 outline-none data-[highlighted]:bg-hover data-[disabled]:opacity-50";

function Check({ on }: { on: boolean }) {
  return <span className="w-4 flex-none text-accent">{on && <Icon name="check" size={14} strokeWidth={1.8} />}</span>;
}

/**
 * The persona for a conversation that has no messages yet (mockup frame C): a
 * pill in the composer that opens upwards. Hidden when there's nothing to pick.
 */
export function PersonaSwitcher({
  value,
  onChange,
  disabled,
}: {
  /** The persona id in use, or undefined for the built-in Assistant. */
  value?: string;
  onChange: (id: string) => void;
  disabled?: boolean;
}) {
  const manage = useOpenPersonaManager();
  const q = usePersonas();
  const all = q.data?.personas ?? [];
  const personas = inChatList(all, value);
  if (!personas.length) return null;
  const defaultId = q.data?.default_persona_id;
  const current = personaLook(all.find((p) => p.id === value));
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          disabled={disabled}
          aria-label={`Persona for this conversation: ${current.name}`}
          className="flex h-[30px] max-w-full items-center gap-1.5 rounded-full bg-selected pl-1.5 pr-2.5 text-13 font-medium text-fg hover:bg-hover disabled:cursor-not-allowed disabled:opacity-50"
        >
          <PersonaAvatar persona={current} size={18} />
          <span className="truncate">{current.name}</span>
          <Icon name="chev" size={12} strokeWidth={1.6} className="rotate-180 text-fg-tertiary" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" side="top" sideOffset={6} className={cx(floatPanel, "w-[290px]")}>
          <DropdownMenu.Label className="px-2 py-1 text-12 font-medium uppercase tracking-wide text-fg-tertiary">
            Persona for this conversation
          </DropdownMenu.Label>
          <DropdownMenu.RadioGroup value={value ?? ""} onValueChange={onChange}>
            {personas.map((p) => (
              <DropdownMenu.RadioItem key={p.id} value={p.id} className={item}>
                <PersonaAvatar persona={p} />
                <PersonaName persona={p} className="truncate" />
                <CapabilityBadges capabilities={p.capabilities} />
                <span className="truncate text-12 text-fg-tertiary">
                  {p.id === defaultId ? "(default) · " : ""}
                  {toneLabel(p.tone)}
                </span>
                <span className="ml-auto" />
                <Check on={p.id === value} />
              </DropdownMenu.RadioItem>
            ))}
          </DropdownMenu.RadioGroup>
          <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />
          <DropdownMenu.Item className={item} onSelect={manage}>
            <span className="text-12 text-fg-secondary">Manage personas…</span>
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/**
 * The header's persona control (the workbench design's "Hackerman ▾"): who this conversation is
 * with, always in view. Before the first message it switches the persona, as the composer's
 * pill does; once the conversation has started it starts a new chat with another persona, since a
 * conversation keeps the persona it began with.
 */
export function HeaderPersona({ persona, personaId, fresh, onSwitch, disabled, compact = false, working = false }: {
  persona: PersonaLook;
  /** The chat's persona id, or undefined for the built-in Assistant. */
  personaId?: string;
  /** No messages yet: picking switches this conversation's persona. */
  fresh: boolean;
  onSwitch: (id: string) => void;
  disabled?: boolean;
  /** In a narrow dock: the avatar and ▾ only, leaving the row to the title. */
  compact?: boolean;
  /** Whether the persona is currently running a turn. */
  working?: boolean;
}) {
  const router = useRouter();
  const manage = useOpenPersonaManager();
  const q = usePersonas();
  const personas = inChatList(q.data?.personas ?? [], personaId);
  const avatar = <PersonaAvatar persona={persona} size={22} state={working ? "working" : "idle"} />;
  // No personas to pick from: the avatar alone says who it is.
  if (!personas.length)
    return <span title={persona.name} className="flex-none">{avatar}<span className="sr-only">Persona: {persona.name}</span></span>;
  return (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button type="button" disabled={disabled} aria-label={`Persona: ${persona.name}`} data-testid="header-persona"
          className={cx("flex h-[30px] max-w-[180px] flex-none items-center gap-1.5 rounded-full border border-border bg-surface pl-1 text-13 font-medium text-fg hover:bg-hover disabled:cursor-not-allowed disabled:opacity-50", compact ? "pr-1.5" : "pr-2")}>
          {avatar}
          {!compact && <span className="truncate">{persona.name}</span>}
          <Icon name="chev" size={12} strokeWidth={1.6} className="text-fg-tertiary" />
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "w-[290px]")}>
          <DropdownMenu.Label className="px-2 py-1 text-12 font-medium uppercase tracking-wide text-fg-tertiary">
            {fresh ? "Persona for this conversation" : "New chat with"}
          </DropdownMenu.Label>
          {personas.map((p) => (
            <DropdownMenu.Item key={p.id} className={item}
              onSelect={() => (fresh ? onSwitch(p.id) : router.push(`/chat?new&persona=${encodeURIComponent(p.id)}`))}>
              <PersonaAvatar persona={p} />
              <PersonaName persona={p} className="truncate" />
              <CapabilityBadges capabilities={p.capabilities} />
              <span className="ml-auto" />
              <Check on={p.id === personaId} />
            </DropdownMenu.Item>
          ))}
          <DropdownMenu.Separator className="my-1 h-px bg-border-subtle" />
          <DropdownMenu.Item className={item} onSelect={manage}>
            <span className="text-12 text-fg-secondary">Manage personas…</span>
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
}

/** A persona's portrait on a soft glow of its color: the welcome's centrepiece and an empty chat's greeting. */
export function PersonaPortrait({ persona, size = 92, breathe }: { persona: PersonaLook; size?: number; breathe?: boolean }) {
  const glow = Math.round(size * 1.9);
  const characterSvg = usePersonaCharacterSvg(persona);
  const loops = usePersonaStateMedia(persona);
  if (loops) {
    // The full-height loop stands on the persona's glow instead of a circle.
    const width = Math.round(size * 1.9);
    return (
      <span className="relative grid flex-none place-items-end justify-center" data-testid="persona-portrait">
        <span
          aria-hidden
          className={cx("pointer-events-none absolute bottom-0 rounded-full", breathe && "wizard-breathe")}
          style={{ width: width * 1.5, height: width * 1.1, background: `radial-gradient(ellipse at 50% 70%, color-mix(in srgb, ${persona.color} 18%, transparent) 0%, transparent 70%)` }}
        />
        <PersonaStateStage media={loops} state="idle" width={width} label={persona.name} className="relative" />
      </span>
    );
  }
  return (
    <span className="relative grid flex-none place-items-center" style={{ width: size + 8, height: size + 8 }} data-testid="persona-portrait">
      <span
        aria-hidden
        className={cx("pointer-events-none absolute rounded-full", breathe && "wizard-breathe")}
        style={{ width: glow, height: glow, background: `radial-gradient(circle, color-mix(in srgb, ${persona.color} 20%, transparent) 0%, transparent 68%)` }}
      />
      {characterSvg ? (
        <PersonaAvatar persona={persona} size={size} state="idle" framed={false} className="relative" />
      ) : (
        <span className="relative rounded-full p-[3px]" style={{ boxShadow: `0 0 0 2px color-mix(in srgb, ${persona.color} 60%, transparent)` }}>
          <PersonaAvatar persona={persona} size={size} />
        </span>
      )}
    </span>
  );
}

/** The welcome's persona picker: the picked one large in the middle, up to two neighbours a side, arrows to step through. */
export function PersonaCarousel({
  ordered,
  current,
  left,
  right,
  onPick,
  disabled,
  enterFrom = 0,
}: {
  ordered: Persona[];
  current: PersonaLook;
  left: Persona[];
  right: Persona[];
  onPick: (id: string) => void;
  disabled?: boolean;
  /** Slide in on mount from this side, as when the Welcome Wizard hands over to a new persona. */
  enterFrom?: -1 | 0 | 1;
}) {
  const index = ordered.findIndex((p) => p.id === current.id);
  // Which side the picked persona came from, so it slides in from there. 0 until the first step: no motion on load.
  const [from, setFrom] = useState<-1 | 0 | 1>(enterFrom);
  const pick = (id: string, d: -1 | 1) => {
    setFrom(d);
    onPick(id);
  };
  const step = (d: -1 | 1) => ordered.length > 1 && pick(ordered[(((index + d) % ordered.length) + ordered.length) % ordered.length].id, d);
  // The moving parts are keyed by the picked persona: each step remounts them, which replays the slide.
  const slide = from ? "motion-slide" : undefined;
  const slideFrom = { "--slide-from": from } as CSSProperties;
  const sides = (ps: Persona[], d: -1 | 1) =>
    ps.length > 0 && (
      <span key={`${d}-${current.id}`} style={slideFrom} className={cx("flex items-center gap-4 max-sm:hidden", slide)}>
        {ps.map((p) => (
          <button key={p.id} type="button" role="radio" aria-checked={false} aria-label={p.name} title={p.name} tabIndex={-1} disabled={disabled} onClick={() => pick(p.id, d)}
            className="rounded-full opacity-55 transition-opacity hover:opacity-100 disabled:cursor-not-allowed">
            <PersonaAvatar persona={p} size={40} />
          </button>
        ))}
      </span>
    );
  const arrow = (d: -1 | 1) => (
    <button type="button" aria-label={d < 0 ? "Previous persona" : "Next persona"} disabled={disabled} onClick={() => step(d)}
      className="grid size-8 flex-none place-items-center rounded-full text-fg-tertiary hover:bg-hover hover:text-fg disabled:cursor-not-allowed">
      <Icon name="chev" size={16} strokeWidth={1.6} className={d < 0 ? "rotate-90" : "-rotate-90"} />
    </button>
  );
  const many = ordered.length > 1;
  // A radio group: the picked persona holds focus and the arrow keys step through the rest.
  return (
    <div role="radiogroup" aria-label="Who to talk to" className="flex items-center justify-center gap-4">
      {sides(left, -1)}
      {many && arrow(-1)}
      <button
        type="button"
        role="radio"
        aria-checked
        aria-label={current.name}
        disabled={disabled}
        onKeyDown={(e) => {
          if (e.key === "ArrowLeft" || e.key === "ArrowUp") { e.preventDefault(); step(-1); }
          if (e.key === "ArrowRight" || e.key === "ArrowDown") { e.preventDefault(); step(1); }
        }}
        className="cursor-default rounded-full focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-accent"
      >
        {/* The button stays mounted so it keeps focus while the arrow keys step. */}
        <span key={current.id ?? ""} style={slideFrom} className={cx("block", slide)}>
          <PersonaPortrait persona={current} />
        </span>
      </button>
      {many && arrow(1)}
      {sides(right, 1)}
    </div>
  );
}

/** "Hi Liam, I'm Atlas." over the persona's portrait, for a conversation before its first message. */
export function PersonaGreeting({
  persona,
  tone,
  isDefault,
  firstName,
  canSwitch,
}: {
  persona: PersonaLook;
  tone?: Schemas["PersonaTone"];
  isDefault: boolean;
  firstName?: string;
  canSwitch: boolean;
}) {
  return (
    <div className="flex flex-col items-center gap-2 py-10 text-center">
      <PersonaPortrait persona={persona} size={72} />
      <h2 className="mt-3 text-22 font-semibold tracking-[-0.02em] text-fg">
        {firstName ? `Hi ${firstName}, I’m ` : "I’m "}
        {persona.id ? persona.name : "your assistant"}.
      </h2>
      <p className="text-14 text-fg-secondary">
        A new conversation{isDefault ? " with your default persona" : ""}
        {persona.id ? ` · ${toneLabel(tone)} tone` : ""}
      </p>
      <p className="max-w-[520px] text-14 text-fg-secondary">
        {canSwitch
          ? "Pick another persona below before you send your first message."
          : "Ask about your runs, tickets, epics and wiki, or have me draft tickets. I save useful things to your private memory and tell you when I do."}
      </p>
    </div>
  );
}
