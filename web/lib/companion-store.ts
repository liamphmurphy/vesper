"use client";

// What a chat's persona companion is doing (LAZYAGENTS persona state loops): the character
// state its working card publishes, and the reply it's revealing. The bubble, the companion
// and its pop-out all read one reveal per chat, so they stay in step.
import { useSyncExternalStore } from "react";
import type { CharacterState } from "./persona-character.ts";
import { revealSlice, type CompanionState } from "./persona-state-media.ts";

type Reveal = { messageId: string; text: string; wps: number; started: number; shown: string; done: boolean };
// hadWork: the turn showed a working state since the last reply, so its reply earns the
// complete beat; celebrate: that beat waits for the reveal; completeUntil: it's playing.
type Chat = { work?: CharacterState; reveal?: Reveal; revealed: Set<string>; hadWork?: boolean; celebrate?: boolean; completeUntil?: number };

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
export function startReveal(chatId: string, messageId: string, text: string, wordsPerSecond: number) {
  const c = chat(chatId);
  if (c.revealed.has(messageId) || c.reveal?.messageId === messageId) return;
  c.celebrate = !!c.hadWork;
  c.hadWork = false;
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

/** Shows the rest of the chat's reply at once (a click on it, or the person sending). */
export function finishReveal(chatId: string) {
  const r = chats.get(chatId)?.reveal;
  if (!r || r.done) return;
  const c = chat(chatId);
  c.reveal = { ...r, shown: r.text, done: true };
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
  if (c?.reveal && !c.reveal.done) return "talking";
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
