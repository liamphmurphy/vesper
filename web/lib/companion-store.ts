"use client";

// What a chat's persona companion is doing (LAZYAGENTS persona state loops): the character
// state its working card publishes, and the reply it's revealing. The bubble, the companion
// and its pop-out all read one reveal per chat, so they stay in step.
import { useSyncExternalStore } from "react";
import type { CharacterState } from "./persona-character.ts";
import { revealSlice, type CompanionState } from "./persona-state-media.ts";

// waiting: held at the start while its speech loads, so text and voice begin together.
type Reveal = { messageId: string; text: string; wps: number; started: number; shown: string; done: boolean; waiting?: boolean; stop?: () => void };
// hadWork: the turn showed a working state since the last reply, so its reply earns the
// complete beat; celebrate: that beat waits for the reveal; completeUntil: it's playing.
type Chat = { work?: CharacterState; reveal?: Reveal; revealed: Set<string>; hadWork?: boolean; celebrate?: boolean; completeUntil?: number; popoutOpen?: boolean };

/** A persona's voice mode (Schemas["PersonaVoiceMode"]). */
export type VoiceMode = "off" | "popout" | "always";

/** Speech for a reply: where to fetch it and the author's voice mode. */
export type ReplySpeech = { url: string; mode: VoiceMode };

/**
 * Plays a reply's speech. Resolves once it's playing, with the words it speaks and its length,
 * or null when there's none to play (voice off, no provider, autoplay refused).
 */
export type SpeechPlayer = (url: string) => Promise<{ words: number; seconds: number; stop: () => void } | null>;

/** How long a reveal waits for its speech before going ahead silently. */
export const SPEECH_WAIT_MS = 8000;

/** How long the complete beat plays before the companion settles to idle: about one loop. */
export const COMPLETE_MS = 3500;

const chats = new Map<string, Chat>();
const listeners = new Set<() => void>();
let version = 0;
let timer: ReturnType<typeof setInterval> | undefined;

function chat(id: string): Chat {
  let c = chats.get(id);
  if (!c) chats.set(id, (c = { revealed: new Set() }));
  return c;
}

function emit() {
  version++;
  for (const l of listeners) l();
}

function subscribe(l: () => void) {
  listeners.add(l);
  return () => listeners.delete(l);
}

// One clock for every running reveal; it stops when none is left.
function tick() {
  const now = performance.now();
  let running = false;
  for (const c of chats.values()) {
    const r = c.reveal;
    if (!r || r.done) continue;
    if (r.waiting) {
      running = true;
      continue;
    }
    const next = revealSlice(r.text, now - r.started, r.wps);
    if (next.text !== r.shown || next.done) {
      c.reveal = { ...r, shown: next.text, done: next.done };
      if (next.done) c.revealed.add(r.messageId);
    }
    if (next.done) celebrate(c);
    running ||= !next.done;
  }
  if (!running && timer) {
    clearInterval(timer);
    timer = undefined;
  }
  emit();
}

/** The working card's character state for a chat; undefined once the turn's card is gone. */
export function setCompanionWork(chatId: string, state: CharacterState | undefined) {
  const c = chat(chatId);
  if (c.work === state) return;
  c.work = state;
  // A stopped turn (static) or one waiting on the person isn't work done.
  if (state && state !== "static" && state !== "needs_you") c.hadWork = true;
  if (state === "static") c.hadWork = false;
  emit();
}

/**
 * Starts revealing a reply that just arrived. A reply is revealed once: one already shown in
 * full (or skipped) never replays when the transcript re-renders.
 */
export function startReveal(chatId: string, messageId: string, text: string, wordsPerSecond: number, speech?: ReplySpeech) {
  const c = chat(chatId);
  if (c.revealed.has(messageId) || c.reveal?.messageId === messageId) return;
  c.celebrate = !!c.hadWork;
  c.hadWork = false;
  if (speech && speaks(c, speech.mode)) {
    // The voice sets the pace: hold the text until it's playing, then reveal in time with it.
    c.reveal = { messageId, text, wps: wordsPerSecond || FALLBACK_WPS, started: performance.now(), shown: "", done: false, waiting: true };
    timer ??= setInterval(tick, 50);
    emit();
    void playSpeech(chatId, messageId, speech.url);
    return;
  }
  if (wordsPerSecond <= 0) {
    c.revealed.add(messageId);
    celebrate(c);
    emit();
    return;
  }
  c.reveal = { messageId, text, wps: wordsPerSecond, started: performance.now(), shown: "", done: false };
  timer ??= setInterval(tick, 50);
  emit();
}

// The pace for a spoken reply whose speech never came (pace off, voice failed).
const FALLBACK_WPS = 15;

function speaks(c: Chat, mode: VoiceMode): boolean {
  return !muted() && (mode === "always" || (mode === "popout" && !!c.popoutOpen));
}

async function playSpeech(chatId: string, messageId: string, url: string) {
  const timeout = new Promise<null>((r) => setTimeout(() => r(null), SPEECH_WAIT_MS));
  let played: Awaited<ReturnType<SpeechPlayer>> = null;
  try {
    played = await Promise.race([player(url), timeout]);
  } catch {
    played = null;
  }
  const c = chat(chatId);
  const r = c.reveal;
  if (!r || r.messageId !== messageId || r.done) {
    played?.stop(); // skipped or replaced while it loaded
    return;
  }
  if (played && muted()) {
    played.stop(); // muted while it loaded: keep the pace, drop the sound
  }
  const wps = played && played.seconds > 0 && played.words > 0 ? played.words / played.seconds : r.wps;
  c.reveal = { ...r, waiting: false, started: performance.now(), wps, stop: played?.stop };
  emit();
}

let player: SpeechPlayer = browserSpeechPlayer;

/** Swaps the speech player (tests). */
export function setSpeechPlayer(p: SpeechPlayer) {
  player = p;
}

async function browserSpeechPlayer(url: string): ReturnType<SpeechPlayer> {
  const res = await fetch(url, { credentials: "same-origin" });
  if (!res.ok) return null;
  const words = Number(res.headers.get("X-Speech-Words") ?? 0);
  const src = URL.createObjectURL(await res.blob());
  const audio = new Audio(src);
  const release = () => URL.revokeObjectURL(src);
  audio.addEventListener("ended", release, { once: true });
  try {
    await audio.play(); // refused without a recent gesture: the reveal goes on silently
  } catch {
    release();
    return null;
  }
  const seconds = Number.isFinite(audio.duration) ? audio.duration : await new Promise<number>((r) => audio.addEventListener("loadedmetadata", () => r(audio.duration), { once: true }));
  return {
    words,
    seconds,
    stop: () => {
      audio.pause();
      release();
    },
  };
}

// ---- mute (one switch for every persona, remembered) ----

const MUTE_KEY = "vesper:companion-muted";
let mutedFallback = false;
function muted(): boolean {
  try {
    return localStorage.getItem(MUTE_KEY) === "1";
  } catch {
    return mutedFallback;
  }
}

/** Mutes or unmutes persona voices; muting stops any reply being spoken. */
export function setVoiceMuted(next: boolean) {
  try {
    if (next) localStorage.setItem(MUTE_KEY, "1");
    else localStorage.removeItem(MUTE_KEY);
  } catch {
    mutedFallback = next;
  }
  if (next) for (const c of chats.values()) c.reveal?.stop?.();
  emit();
}

export function useVoiceMuted(): boolean {
  return useSyncExternalStore(subscribe, muted, () => false);
}

/** Whether the chat's pop-out is open, for voices set to speak only there. */
export function setPopoutOpen(chatId: string, open: boolean) {
  chat(chatId).popoutOpen = open;
}

/** Shows the rest of the chat's reply at once (a click on it, or the person sending). */
export function finishReveal(chatId: string) {
  const r = chats.get(chatId)?.reveal;
  if (!r || r.done) return;
  const c = chat(chatId);
  r.stop?.();
  c.reveal = { ...r, shown: r.text, done: true, waiting: false };
  c.revealed.add(r.messageId);
  celebrate(c);
  emit();
}

// Plays the complete beat once a reply that ended real work is fully shown, then lets the
// companion settle; a new turn's working state takes over at once.
function celebrate(c: Chat) {
  if (!c.celebrate) return;
  c.celebrate = false;
  c.completeUntil = performance.now() + COMPLETE_MS;
  setTimeout(emit, COMPLETE_MS + 20);
}

/** Marks replies as already seen, so opening a chat never replays its history. */
export function markRevealed(chatId: string, messageIds: Iterable<string>) {
  const c = chat(chatId);
  for (const id of messageIds) c.revealed.add(id);
}

/** The text of a reply to show now: its revealed part while it reveals, else all of it. */
export function useRevealedText(chatId: string, messageId: string, full: string): { text: string; revealing: boolean } {
  return useSyncExternalStore(
    subscribe,
    () => revealedText(chatId, messageId, full),
    () => ({ text: full, revealing: false }),
  );
}

// Cached per version so useSyncExternalStore gets a stable snapshot between changes.
const snapshots = new Map<string, { v: number; out: { text: string; revealing: boolean } }>();
function revealedText(chatId: string, messageId: string, full: string) {
  const key = `${chatId}:${messageId}`;
  const hit = snapshots.get(key);
  if (hit && hit.v === version) return hit.out;
  const r = chats.get(chatId)?.reveal;
  const out = r && r.messageId === messageId && !r.done ? { text: r.shown, revealing: true } : hit?.out.text === full && !hit.out.revealing ? hit.out : { text: full, revealing: false };
  snapshots.set(key, { v: version, out });
  return out;
}

/** What the chat's companion acts out: talking while a reply reveals, else the turn's state, else idle. */
export function useCompanionState(chatId: string): CompanionState {
  return useSyncExternalStore(subscribe, () => companionState(chatId), () => "idle");
}

/** What the chat's companion acts out right now (useCompanionState without React). */
export function companionState(chatId: string): CompanionState {
  const c = chats.get(chatId);
  // Talking starts with the first word on screen, not when the reply arrives:
  // a spoken reply holds its text while the voice loads, and even an instant
  // pace shows nothing for the first beat.
  if (c?.reveal && !c.reveal.done && c.reveal.shown !== "") return "talking";
  if (c?.work && c.work !== "static") return c.work;
  if (c?.completeUntil && performance.now() < c.completeUntil) return "complete";
  return "idle";
}

/** The reply being revealed in a chat, if any, for the pop-out to follow. */
export function useRevealingMessage(chatId: string): string | undefined {
  return useSyncExternalStore(
    subscribe,
    () => {
      const r = chats.get(chatId)?.reveal;
      return r && !r.done ? r.messageId : undefined;
    },
    () => undefined,
  );
}
