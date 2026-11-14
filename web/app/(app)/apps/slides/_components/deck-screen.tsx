"use client";

import { useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useMemo, useRef, useState, type KeyboardEvent } from "react";
import { ApiError, api, unwrap } from "@/lib/api/client";
import { useCanvasActions, useChatCanvas } from "@/lib/api/canvas-hooks";
import { useMarkDocReviewed } from "@/lib/api/docs-hooks";
import { useChat, useSendChatMessage } from "@/lib/api/hooks";
import { uploadDeckAsset, useCreateSlideTheme, useDeckRef, useDeleteSlideTheme, useSlideThemes, useUpdateSlideTheme } from "@/lib/api/slides-hooks";
import { cx } from "@/lib/cx";
import { reviewBase } from "@/lib/doc-review";
import { align, distribute, duplicate, reorder, unionBox, type AlignOp, type ZOrder } from "@/lib/slides/arrange";
import { pushRecent, shiftLevel, toggleArrow, withRadius, withStrokeWidth } from "@/lib/slides/edit";
import { measure } from "@/lib/slides/fonts";
import { layoutSlide } from "@/lib/slides/layout";
import { assetHref, useSlideFonts } from "@/lib/slides/render";
import { mergeDecks, same } from "@/lib/slides/review";
import { outlinePrompt } from "@/lib/slides/outline";
import { H, THEMES, W, encodeDeck, isImageSlot, type Theme, newId, newSlide, parseDeck, relayout, textOf, type Deck, type Element, type Layout, type Paragraph, type Slide } from "@/lib/slides/schema";
import { applyStyle } from "@/lib/slides/styles";
import { fit, flatten, groupElements, isGroup, mapDeep, removeDeep, scopeElements, ungroupElements, withFrame } from "@/lib/slides/group";
import { Button } from "@/components/ui/button";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { EditorLayout, type DockTab, type EditorHeader } from "@/components/shell/editor-layout";
import type { DockState } from "@/lib/editor-layout";
import { useCompact } from "@/lib/viewport";
import { Conversation } from "@/app/(app)/chat/_components/conversation";
import { PersonaAvatar, personaLook } from "@/app/(app)/chat/_components/persona";
import { DeckReview } from "./deck-review";
import { ExportMenu } from "./export-menu";
import { SlideCanvas } from "./slide-canvas";
import type { TextEditorHandle } from "./text-editor";
import { ThemeEditor, type ThemeEditTarget } from "./theme-editor";
import { Thumbnails } from "./thumbnails";
import type { StylePatch } from "./style-menus";
import { Toolbar, type TextFormat, type ToolbarActions } from "./toolbar";
import { confirmAction } from "@/components/ui/confirm";

type SaveState = "saved" | "unsaved" | "saving" | "conflict" | "error";
const SAVE_LABEL: Record<SaveState, string> = { saved: "Saved", unsaved: "Unsaved changes", saving: "Saving…", conflict: "Not saved", error: "Not saved" };
const AUTOSAVE_MS = 800;
const MAX_IMAGE_EDGE = 4096;
const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

/** A PNG or JPEG of at most 4096 px a side, converting or downscaling in the browser first. */
async function prepareImage(file: File): Promise<Blob> {
  const bmp = await createImageBitmap(file).catch(() => {
    throw new Error("this file isn't an image the browser can read");
  });
  const edge = Math.max(bmp.width, bmp.height);
  if ((file.type === "image/png" || file.type === "image/jpeg") && edge <= MAX_IMAGE_EDGE && file.size <= 10 << 20) return file;
  const k = Math.min(1, MAX_IMAGE_EDGE / edge);
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(bmp.width * k);
  canvas.height = Math.round(bmp.height * k);
  canvas.getContext("2d")!.drawImage(bmp, 0, 0, canvas.width, canvas.height);
  const type = file.type === "image/jpeg" ? "image/jpeg" : "image/png";
  return new Promise((res, rej) => canvas.toBlob((b) => (b ? res(b) : rej(new Error("couldn't convert the image"))), type, 0.9));
}

const mapRuns = (paragraphs: Paragraph[], fn: (r: Paragraph["runs"][number]) => Paragraph["runs"][number]) => paragraphs.map((p) => ({ ...p, runs: p.runs.map(fn) }));

/**
 * Applies a text format to every run (or paragraph) of an element's text. A
 * mark is set to `markOn`, or toggled from the first run's when it's unset.
 */
function formatElement(e: Element, f: TextFormat, markOn?: boolean): Element {
  const box = textOf(e);
  if (!box) return e;
  const first = box.paragraphs[0]?.runs[0];
  let paragraphs = box.paragraphs;
  if (f.kind === "mark") paragraphs = mapRuns(paragraphs, (r) => ({ ...r, [f.mark]: (markOn ?? !first?.[f.mark]) || undefined }));
  if (f.kind === "size") paragraphs = mapRuns(paragraphs, (r) => ({ ...r, size: f.size }));
  if (f.kind === "font") paragraphs = mapRuns(paragraphs, (r) => ({ ...r, font: f.font }));
  if (f.kind === "color") paragraphs = mapRuns(paragraphs, (r) => ({ ...r, color: f.color }));
  if (f.kind === "highlight") paragraphs = mapRuns(paragraphs, (r) => ({ ...r, highlight: f.highlight }));
  if (f.kind === "lineSpacing") paragraphs = paragraphs.map((p) => ({ ...p, lineSpacing: f.lineSpacing === 1 ? undefined : f.lineSpacing }));
  if (f.kind === "align") paragraphs = paragraphs.map((p) => ({ ...p, align: f.align === "left" ? undefined : f.align }));
  if (f.kind === "bullet") paragraphs = paragraphs.map((p) => (f.bullet ? { ...p, bullet: f.bullet, level: p.level ?? 0 } : { ...p, bullet: undefined, level: undefined }));
  if (f.kind === "indent") paragraphs = shiftLevel(paragraphs, f.delta);
  return paragraphs === box.paragraphs ? e : withText(e, paragraphs);
}

/** Sets the style fields that apply to an element's type; undefined clears one. */
function withStyle(e: Element, patch: StylePatch): Element {
  const allowed: (keyof StylePatch)[] = e.type === "shape" ? ["fill", "fillOpacity", "strokeOpacity", "dash"] : e.type === "line" ? ["strokeOpacity", "dash"] : e.type === "image" ? ["opacity"] : [];
  const next: Record<string, unknown> = { ...e };
  for (const k of allowed) {
    if (!(k in patch)) continue;
    if (patch[k] === undefined) delete next[k];
    else next[k] = patch[k];
  }
  return next as Element;
}

function withText(e: Element, paragraphs: Paragraph[]): Element {
  if (e.type === "text") return { ...e, paragraphs };
  if (e.type === "shape") return { ...e, text: { ...(e.text ?? {}), paragraphs } };
  return e;
}

/**
 * A deck on the shared EditorLayout (mockup "Slides editor on the shared
 * EditorLayout"): thumbnails on the left, the slide with its formatting
 * toolbar, and a dock with the persona's chat and, while there are
 * suggestions, their review. Edits save themselves as
 * new versions; concurrent changes to different slides merge, the same slide
 * asks the person.
 */
export function DeckScreen({ id }: { id: string }) {
  const ref = useDeckRef(id);
  const router = useRouter();
  const search = useSearchParams();
  const chatId = ref.data?.chat_id ?? "";
  const chat = useChat(chatId || undefined).data;
  const live = chat?.state === "running";
  const archived = !!chat?.archived;
  const persona = (chat?.speaker ?? chat?.persona)?.name ?? "Assistant";
  const head = useChatCanvas(chatId, chatId ? id : undefined, undefined, live);
  const c = head.data;
  const fonts = useSlideFonts();
  const actions = useCanvasActions(chatId, id);
  // mutateAsync is stable across renders; the mutation result object isn't.
  const saveVersion = actions.save.mutateAsync;
  const reviewed = useMarkDocReviewed(id);
  const send = useSendChatMessage(chatId);
  const assetUrl = useCallback((a: string) => assetHref(id, a), [id]);
  // Custom colours used in this deck, newest first: editor state, kept per deck in this browser.
  const recentKey = `slides.recentColors.${id}`;
  const [recentColors, setRecentColors] = useState<string[]>([]);
  useEffect(() => {
    try {
      const v: unknown = JSON.parse(localStorage.getItem(recentKey) ?? "[]");
      // Reading browser storage once the page is in the browser.
      // eslint-disable-next-line react-hooks/set-state-in-effect
      if (Array.isArray(v)) setRecentColors(v.filter((c) => typeof c === "string").reduceRight<string[]>((r, c) => pushRecent(r, c), []));
    } catch {
      // Unreadable storage only loses the recent colours.
    }
  }, [recentKey]);
  const rememberColor = (c: string) =>
    setRecentColors((r) => {
      const next = pushRecent(r, c);
      try {
        localStorage.setItem(recentKey, JSON.stringify(next));
      } catch {
        // Storage full or blocked: the colours stay for this visit.
      }
      return next;
    });

  // ---- The working copy, what was last saved, and history.
  const [deck, setDeckState] = useState<Deck | null>(null);
  const deckRef = useRef<Deck | null>(null);
  const saved = useRef<{ seq: number; deck: Deck } | null>(null);
  const dirty = useRef(false);
  const [isDirty, setIsDirty] = useState(false);
  const history = useRef<{ past: Deck[]; future: Deck[]; key?: string; at: number }>({ past: [], future: [], at: 0 });
  const [hist, setHist] = useState({ undo: 0, redo: 0 });
  const [savedSeq, setSavedSeq] = useState(0);
  const [saveState, setSaveState] = useState<{ s: SaveState; message?: string }>({ s: "saved" });
  const [conflict, setConflict] = useState<{ theirs: Deck; seq: number } | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  // Set while a conflict waits on the person: nothing saves until they choose.
  const conflicted = useRef(false);
  const saving = useRef<Promise<void> | null>(null);

  const setDeck = (d: Deck) => {
    deckRef.current = d;
    setDeckState(d);
  };
  const setDirty = (v: boolean) => {
    dirty.current = v;
    setIsDirty(v);
  };
  const markSaved = (seq: number, d: Deck) => {
    saved.current = { seq, deck: d };
    setSavedSeq(seq);
  };
  const syncHist = () => setHist({ undo: history.current.past.length, redo: history.current.future.length });
  // Undo steps are only valid against the draft they were taken from: once
  // the server or a merge replaces the draft, undoing would quietly revert
  // someone else's changes, so the history starts again.
  const resetHist = () => {
    history.current = { past: [], future: [], at: 0 };
    syncHist();
  };
  const retries = useRef(0);
  const retryRef = useRef<() => void>(() => undefined);

  // Follow the server while there's nothing unsaved here (the persona's live edits included).
  useEffect(() => {
    if (!c || c.kind !== "deck") return;
    if (saved.current && c.seq <= saved.current.seq) return;
    if (dirty.current) return; // the next save meets the newer version and merges
    try {
      const d = parseDeck(c.body);
      saved.current = { seq: c.seq, deck: d };
      deckRef.current = d;
      history.current = { past: [], future: [], at: 0 };
      // Syncing the editable draft from the server query, an external store.
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setSavedSeq(c.seq);
      setDeckState(d);
      setHist({ undo: 0, redo: 0 });
    } catch {
      setSaveState({ s: "error", message: "This deck's content couldn't be read." });
    }
  }, [c]);

  const runSave = useCallback(async (): Promise<void> => {
    // A merge after a conflict saves again on top of the newer version.
    for (let attempt = 0; attempt < 3; attempt++) {
      const mine = deckRef.current;
      const at = saved.current;
      if (!mine || !at || !dirty.current || conflicted.current) return;
      if (same(mine, at.deck)) {
        setDirty(false);
        setSaveState({ s: "saved" });
        return;
      }
      setSaveState({ s: "saving" });
      try {
        const v = await saveVersion({ base_seq: at.seq, body: encodeDeck(mine), note: "Edited" });
        markSaved(v.seq, mine);
        retries.current = 0;
        if (deckRef.current === mine) {
          setDirty(false);
          setSaveState({ s: "saved" });
        }
        return;
      } catch (e) {
        if (e instanceof ApiError && e.status === 409) {
          // Someone (the persona) saved in between: merge per slide, or ask.
          let latest, theirs;
          try {
            latest = await unwrap(api.GET("/chats/{id}/canvases/{canvasId}", { params: { path: { id: chatId, canvasId: id } } }));
            theirs = parseDeck(latest.body);
          } catch (err) {
            setSaveState({ s: "error", message: `Couldn't load the newer version: ${errorText(err)}` });
            retryRef.current();
            return;
          }
          const merged = mergeDecks(at.deck, deckRef.current ?? mine, theirs);
          markSaved(latest.seq, theirs);
          if (merged) {
            setDeck(merged);
            resetHist();
            setSaveState({ s: "unsaved" });
            continue;
          }
          conflicted.current = true;
          clearTimeout(timer.current);
          setConflict({ theirs, seq: latest.seq });
          setSaveState({ s: "conflict", message: "This deck changed while you were editing." });
        } else if (e instanceof ApiError && e.status === 422 && /changes nothing/.test(e.message)) {
          setDirty(false);
          setSaveState({ s: "saved" });
        } else {
          setSaveState({ s: "error", message: errorText(e) });
          retryRef.current();
        }
        return;
      }
    }
    // Still behind after three merges: try again shortly rather than give up.
    setSaveState({ s: "error", message: "The deck kept changing while saving." });
    retryRef.current();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the helpers only touch refs and state setters
  }, [saveVersion, chatId, id]);

  /** Saves now (after any save in flight) and returns the deck as saved. */
  const flush = useCallback(async () => {
    clearTimeout(timer.current);
    while (saving.current) await saving.current;
    if (dirty.current && !conflicted.current) {
      saving.current = runSave().finally(() => (saving.current = null));
      await saving.current;
    }
    if (dirty.current) throw new Error(conflicted.current ? "resolve the conflict first" : "the deck isn't saved yet");
    return { deck: saved.current!.deck, seq: saved.current!.seq };
  }, [runSave]);

  const schedule = useCallback(
    (delay = AUTOSAVE_MS) => {
      clearTimeout(timer.current);
      const tick = () => {
        if (saving.current) {
          timer.current = setTimeout(tick, AUTOSAVE_MS);
          return;
        }
        saving.current = runSave().finally(() => (saving.current = null));
      };
      timer.current = setTimeout(tick, delay);
    },
    [runSave],
  );
  // A failed save tries again by itself, backing off to 30 s; any edit or Retry saves sooner.
  useEffect(() => {
    retryRef.current = () => {
      retries.current += 1;
      schedule(Math.min(30_000, 2_000 * 2 ** (retries.current - 1)));
    };
  }, [schedule]);

  // Save on the way out: hidden tab, closed page or navigation. Registered
  // once and reading flush through a ref, so it runs on leaving, not on every render.
  const flushRef = useRef(flush);
  useEffect(() => {
    flushRef.current = flush;
  }, [flush]);
  useEffect(() => {
    const hide = () => {
      if (document.visibilityState === "hidden" && dirty.current) void flushRef.current().catch(() => undefined);
    };
    const leave = (e: BeforeUnloadEvent) => {
      if (dirty.current) e.preventDefault();
    };
    document.addEventListener("visibilitychange", hide);
    window.addEventListener("beforeunload", leave);
    return () => {
      document.removeEventListener("visibilitychange", hide);
      window.removeEventListener("beforeunload", leave);
      if (dirty.current) void flushRef.current().catch(() => undefined);
    };
  }, []);

  // ---- Persona review: their versions after the person's last edit or review.
  const base = c ? reviewBase(c.versions, ref.data?.reviewed_seq ?? 0) : 0;
  const reviewing = !!c && !live && !isDirty && base > 0 && c.seq > base;
  const before = useChatCanvas(chatId, reviewing ? id : undefined, base).data;
  const baseDeck = useMemo(() => (before && before.viewing_seq === base ? parseDeck(before.body) : undefined), [before, base]);
  const headDeck = useMemo(() => (reviewing && c ? parseDeck(c.body) : undefined), [reviewing, c]);
  const changedSlides = useMemo(() => {
    if (!baseDeck || !headDeck) return undefined;
    const old = new Map(baseDeck.slides.map((s) => [s.id, JSON.stringify(s)]));
    return new Set(headDeck.slides.filter((s) => old.get(s.id) !== JSON.stringify(s)).map((s) => s.id));
  }, [baseDeck, headDeck]);

  // ---- Selection.
  const [slideId, setSlideId] = useState<string>();
  // Back from presenting (or a link) at ?slide=N opens that slide.
  const startAt = Number(search.get("slide") ?? 0);
  const [selected, setSelected] = useState<string[]>([]);
  const [editing, setEditing] = useState<string>();
  /** The group whose elements are being edited (entered by double-clicking it), if any. */
  const [entered, setScope] = useState<string>();
  const editorRef = useRef<TextEditorHandle | null>(null);
  const slide = deck?.slides.find((s) => s.id === slideId) ?? deck?.slides[Math.max(0, Math.min(deck.slides.length - 1, startAt - 1))];
  // The selection in stacking order; ids no longer on the slide (after an undo) drop out.
  // Out of a group once it's gone (ungrouped, undone, another slide).
  const scope = entered && slide?.elements.some((e) => e.id === entered && isGroup(e)) ? entered : undefined;
  // Inside an entered group, the selection is among its elements.
  const scoped = useMemo(() => (slide ? scopeElements(slide.elements, scope) : []), [slide, scope]);
  const selection = useMemo(() => scoped.filter((e) => selected.includes(e.id)), [scoped, selected]);
  const selectedEl = selection.length === 1 ? selection[0] : undefined;
  const selIds = new Set(selection.map((e) => e.id));
  const readOnly = live || archived || reviewing || !!conflict;
  // For async work (uploads) that finishes after later renders.
  const readOnlyRef = useRef(readOnly);
  const slideIdRef = useRef(slide?.id);
  useEffect(() => {
    readOnlyRef.current = readOnly;
    slideIdRef.current = slide?.id;
  }, [readOnly, slide?.id]);

  const laid = useMemo(() => (deck && fonts ? deck.slides.map((s) => ({ id: s.id, overflow: layoutSlide(deck, s, measure).overflow })) : []), [deck, fonts]);
  const overflowingSlides = useMemo(() => new Set(laid.filter((l) => l.overflow.size).map((l) => l.id)), [laid]);
  const overflowHere = laid.find((l) => l.id === slide?.id)?.overflow ?? new Set<string>();

  // ---- Changing the deck.
  const update = (fn: (d: Deck) => Deck, key?: string) => {
    const cur = deckRef.current;
    if (!cur || readOnly || readOnlyRef.current) return;
    const next = fn(cur);
    if (next === cur) return;
    const h = history.current;
    const now = Date.now();
    if (!(key && h.key === key && now - h.at < 1500)) {
      h.past.push(cur);
      if (h.past.length > 100) h.past.shift();
    }
    h.future = [];
    h.key = key;
    h.at = now;
    syncHist();
    setDeck(next);
    setDirty(true);
    setSaveState({ s: "unsaved" });
    schedule();
  };
  const travel = (back: boolean) => {
    const h = history.current;
    const cur = deckRef.current;
    const to = back ? h.past.pop() : h.future.pop();
    if (!to || !cur || readOnly) return;
    (back ? h.future : h.past).push(cur);
    h.key = undefined;
    setEditing(undefined);
    setDeck(to);
    setDirty(true);
    setSaveState({ s: "unsaved" });
    schedule();
    syncHist();
  };
  const mapSlide = (sid: string, fn: (s: Slide) => Slide) => (d: Deck) => ({ ...d, slides: d.slides.map((s) => (s.id === sid ? fn(s) : s)) });
  const mapElement = (eid: string, fn: (e: Element) => Element) => mapElements(new Set([eid]), fn);
  /** fn on the elements with the ids, inside groups too (their boxes refit). */
  const mapElements = (ids: ReadonlySet<string>, fn: (e: Element) => Element) => (d: Deck) => ({ ...d, slides: d.slides.map((s) => ({ ...s, elements: mapDeep(s.elements, ids, fn) })) });
  /** fn on the list the selection lives in: the slide's elements, or the entered group's. */
  const mapScope = (s: Slide, fn: (els: Element[]) => Element[]): Slide => {
    const g = scope ? s.elements.find((e) => e.id === scope) : undefined;
    if (!g || !isGroup(g)) return { ...s, elements: fn(s.elements) };
    const kids = fn(g.elements);
    return kids === g.elements ? s : { ...s, elements: s.elements.map((e) => (e === g ? fit({ ...g, elements: kids as typeof g.elements }) : e)) };
  };
  /** A change to every selected element; a selected group's elements take it instead. */
  const deep = (fn: (e: Element) => Element) => (e: Element): Element => {
    if (!isGroup(e)) return fn(e);
    const kids = e.elements.map((c) => fn(c) as typeof c);
    return kids.every((c, i) => c === e.elements[i]) ? e : fit({ ...e, elements: kids });
  };
  const addElement = (e: Element, edit = false) => {
    if (!slide) return;
    setScope(undefined);
    update(mapSlide(slide.id, (s) => ({ ...s, elements: [...s.elements, e] })));
    setSelected([e.id]);
    if (edit) setEditing(e.id);
  };
  const removeSelected = () => {
    if (!slide || !selIds.size) return;
    update(mapSlide(slide.id, (s) => ({ ...s, elements: removeDeep(s.elements, selIds) })));
    setSelected([]);
  };

  // ---- Arranging the selection: each is one undo step.
  const arrange = {
    order: (op: ZOrder) => {
      if (!slide || !selIds.size) return;
      // reorder returns the same array when nothing moves, which update skips.
      update((d) => {
        const s = d.slides.find((x) => x.id === slide.id);
        if (!s) return d;
        const next = mapScope(s, (els) => reorder(els, selIds, op));
        return next === s || next.elements === s.elements ? d : mapSlide(slide.id, () => next)(d);
      });
    },
    duplicate: () => {
      if (!slide || !selIds.size) return;
      let ids: string[] = [];
      update(mapSlide(slide.id, (s) => mapScope(s, (els) => {
        const r = duplicate(els, selIds, () => newId("e"));
        ids = r.ids;
        return r.elements;
      })));
      setSelected(ids);
    },
    /** The selected elements as one group, at the topmost one's place. */
    group: () => {
      if (!slide || scope || selection.length < 2) return;
      const r = groupElements(slide.elements, selIds, () => newId("e"));
      if (!r) return;
      update(mapSlide(slide.id, (s) => ({ ...s, elements: r.elements })));
      setSelected([r.id]);
    },
    /** The selected groups back into their elements, which stay selected. */
    ungroup: () => {
      if (!slide || scope || !selection.some(isGroup)) return;
      const r = ungroupElements(slide.elements, selIds);
      update(mapSlide(slide.id, (s) => ({ ...s, elements: r.elements })));
      setSelected([...selection.filter((e) => !isGroup(e)).map((e) => e.id), ...r.ids]);
    },
    /** To the selection's box, or to the slide when one element is selected. */
    align: (op: AlignOp) => {
      if (!selection.length) return;
      const to = selection.length === 1 ? { l: 0, t: 0, r: W, b: H } : unionBox(selection.map((e) => e.frame))!;
      setFrames(align(Object.fromEntries(selection.map((e) => [e.id, e.frame])), op, to));
    },
    distribute: (axis: "x" | "y") => {
      if (selection.length >= 3) setFrames(distribute(Object.fromEntries(selection.map((e) => [e.id, e.frame])), axis));
    },
  };
  /** Changes each selected element as one undo step; none when nothing actually changes. */
  /** key coalesces repeated edits (a slider's drag) into one undo step. */
  const editSelection = (fn: (e: Element) => Element, key?: string) => {
    if (!selection.length) return;
    const changed = new Map(selection.map((e) => [e.id, deep(fn)(e)] as const).filter(([, n], i) => JSON.stringify(n) !== JSON.stringify(selection[i])));
    if (changed.size) update(mapElements(new Set(changed.keys()), (e) => changed.get(e.id) ?? e), key && `${selection.map((e) => e.id).join(",")}:${key}`);
  };
  /** Sets several frames at once, leaving the deck untouched (no undo step) when nothing moves. */
  const setFrames = (frames: Record<string, { x: number; y: number; w: number; h: number }>, key?: string) =>
    update((d) => {
      const moved = (e: Element) => frames[e.id] && JSON.stringify(frames[e.id]) !== JSON.stringify(e.frame);
      if (!flatten(slide?.elements ?? []).some(moved)) return d;
      return mapElements(new Set(Object.keys(frames)), (e) => withFrame(e, frames[e.id]))(d);
    }, key);

  const fileInput = useRef<HTMLInputElement>(null);
  // The image placeholder the next picked file fills, if any.
  const fillTarget = useRef<string | undefined>(undefined);
  const fillImage = (eid: string) => {
    if (readOnly) return;
    fillTarget.current = eid;
    fileInput.current?.click();
  };
  const [notice, setNotice] = useState<string>();
  // ---- Themes: the person's saved ones, and the editor.
  const savedThemes = useSlideThemes().data;
  const createTheme = useCreateSlideTheme();
  const updateTheme = useUpdateSlideTheme();
  const deleteTheme = useDeleteSlideTheme();
  const [themeEdit, setThemeEdit] = useState<{ start: Theme; target: ThemeEditTarget } | null>(null);
  const [themeError, setThemeError] = useState<string>();
  const themeBody = (t: Theme) => ({ name: t.name, fonts: t.fonts, colors: t.colors });
  const [uploading, setUploading] = useState(false);
  const onImage = async (file: File) => {
    // The slide it was added on, even if the person moves on while it uploads.
    const target = slide?.id;
    const slot = fillTarget.current;
    fillTarget.current = undefined;
    if (!target) return;
    setNotice(undefined);
    setUploading(true);
    try {
      const blob = await prepareImage(file);
      if (blob.size > 10 << 20) throw new Error(`${file.name} is ${(blob.size / (1 << 20)).toFixed(0)} MB: the limit is 10 MB`);
      const a = await uploadDeckAsset(id, blob);
      const k = Math.min(1200 / a.w, 800 / a.h, 1);
      const w = Math.round(a.w * k), h = Math.round(a.h * k);
      const el: Element = { id: newId("e"), type: "image", asset: a.id, frame: { x: Math.round((1920 - w) / 2), y: Math.round((1080 - h) / 2), w, h }, alt: file.name.replace(/\.[a-z0-9]+$/i, "") };
      // Read now, not from when the upload started.
      if (readOnlyRef.current) throw new Error("the deck became read-only while uploading; add it again once you can edit");
      // Filling a placeholder: the image takes its frame and role (the
      // renderers centre-crop it to cover) and its place in paint order.
      const place = (els: Element[]) => {
        const i = slot ? els.findIndex((x) => x.id === slot && isImageSlot(x)) : -1;
        if (i < 0) return [...els, el];
        Object.assign(el, { frame: els[i].frame, placeholder: "image" });
        return els.map((x, k) => (k === i ? el : x));
      };
      update((d) => mapSlide(target, (s) => ({ ...s, elements: place(s.elements) }))({ ...d, assets: { ...d.assets, [a.id]: { mime: a.mime, w: a.w, h: a.h } } }));
      if (slideIdRef.current === target) setSelected([el.id]);
    } catch (e) {
      setNotice(`Couldn't add ${file.name}: ${errorText(e)}`);
    } finally {
      setUploading(false);
    }
  };

  const tools: ToolbarActions = {
    undo: () => travel(true),
    redo: () => travel(false),
    canUndo: hist.undo > 0,
    canRedo: hist.redo > 0,
    insertText: () => addElement({ id: newId("e"), type: "text", frame: { x: 560, y: 440, w: 800, h: 200 }, paragraphs: [{ runs: [{ text: "", size: 44, font: "body", color: "text" }] }] }, true),
    insertShape: (shape) =>
      addElement({ id: newId("e"), type: "shape", shape, frame: { x: 760, y: 390, w: 400, h: 300 }, fill: "accent", radius: shape === "roundRect" ? 32 : undefined, text: { valign: "middle", paragraphs: [{ align: "center", runs: [{ text: "", size: 40, color: "background", font: "body" }] }] } }),
    insertImage: () => {
      fillTarget.current = undefined;
      fileInput.current?.click();
    },
    insertLine: () => addElement({ id: newId("e"), type: "line", frame: { x: 560, y: 540, w: 800, h: 0 }, stroke: "text", strokeWidth: 6 }),
    setLayout: (l) => slide && update(mapSlide(slide.id, (s) => relayout(s, l))),
    setTheme: (t) => update((d) => ({ ...d, theme: { name: t.name, fonts: { ...t.fonts }, colors: { ...t.colors } } })),
    savedThemes: savedThemes ?? [],
    customiseTheme: (savedId) => {
      const saved = savedId ? savedThemes?.find((t) => t.id === savedId) : undefined;
      if (savedId && !saved) return;
      setThemeError(undefined);
      setThemeEdit(saved ? { start: themeBody(saved), target: { kind: "saved", id: saved.id } } : deck ? { start: deck.theme, target: { kind: "deck" } } : null);
    },
    deleteSavedTheme: async (tid) => {
      const t = savedThemes?.find((x) => x.id === tid);
      if (!t || !await confirmAction({ title: `Delete the theme “${t.name}”?`, body: "Decks using it keep their copy.", confirmLabel: "Delete theme" })) return;
      deleteTheme.mutate(tid, { onError: (e) => setNotice(`Couldn't delete ${t.name}: ${errorText(e)}`) });
    },
    setBackground: (col, key) => slide && update(mapSlide(slide.id, (s) => ({ ...s, background: col ? { color: col } : undefined })), key && `${slide.id}:${key}`),
    format: (f) => {
      if (!selection.length) return;
      if (editing && editorRef.current && selectedEl) {
        if (f.kind === "mark") return editorRef.current.format(f.mark);
        if (f.kind === "color") return editorRef.current.color(f.color);
        if (f.kind === "highlight") return editorRef.current.highlight(f.highlight);
        if (f.kind === "indent") return editorRef.current.indent(f.delta);
        const paragraphs = editorRef.current.read();
        setEditing(undefined);
        update(mapElement(selectedEl.id, (e) => formatElement(withText(e, paragraphs), f)));
        return;
      }
      // A mark goes on everywhere unless every selected text already has it.
      const texts = selection.flatMap((e) => (isGroup(e) ? e.elements : [e])).flatMap((e) => textOf(e)?.paragraphs ?? []).flatMap((p) => p.runs);
      const markOn = f.kind === "mark" ? !texts.every((r) => r[f.mark]) : undefined;
      const fmt = deep((e) => formatElement(e, f, markOn));
      if (selection.every((e) => fmt(e) === e)) return; // nothing to change: no undo step
      update(mapElements(selIds, fmt));
    },
    setFill: (col, key) => editSelection((e) => (e.type === "shape" ? { ...e, fill: col } : e), key),
    setStyle: (patch, key) => editSelection((e) => withStyle(e, patch), key),
    setStroke: (col) => editSelection((e) => (e.type === "shape" ? { ...e, stroke: col, strokeWidth: col ? (e.strokeWidth || 4) : undefined } : e.type === "line" && col ? { ...e, stroke: col } : e)),
    // One update, so the whole selection restyles as one undo step.
    applyStyle: (sid) => editSelection((e) => applyStyle(e, sid)),
    setStrokeWidth: (w) => editSelection((e) => withStrokeWidth(e, w)),
    setRadius: (r) => editSelection((e) => withRadius(e, r)),
    // Mixed lines all get the arrowhead (or, when every one has it, all lose it).
    toggleArrow: (end) => {
      const k = end === "start" ? "startArrow" : "endArrow";
      const lines = selection.flatMap((e) => (isGroup(e) ? e.elements : [e])).filter((e) => e.type === "line");
      const on = !lines.every((e) => e[k]);
      editSelection((e) => (e.type === "line" && !!e[k] !== on ? toggleArrow(e, end) : e));
    },
    recentColors,
    rememberColor,
    remove: removeSelected,
    order: arrange.order,
    duplicate: arrange.duplicate,
    align: arrange.align,
    distribute: arrange.distribute,
    group: !scope && selection.length > 1 ? arrange.group : undefined,
    ungroup: !scope && selection.some(isGroup) ? arrange.ungroup : undefined,
  };

  const present = async (from?: number) => {
    try {
      await flush();
    } catch {
      // Present what's saved; the banner already says why the rest isn't.
    }
    const i = from ?? Math.max(0, deckRef.current?.slides.findIndex((s) => s.id === slide?.id) ?? 0);
    router.push(`/present/slides/${id}?slide=${i + 1}`);
  };

  // ---- Keyboard: undo/redo anywhere; the rest when the canvas has the selection.
  useEffect(() => {
    const onKey = (e: globalThis.KeyboardEvent) => {
      const t = e.target as HTMLElement;
      if (t.isContentEditable || t instanceof HTMLInputElement || t instanceof HTMLTextAreaElement) return;
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "z") {
        e.preventDefault();
        travel(!e.shiftKey);
      } else if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
        e.preventDefault();
        void present(e.shiftKey ? 0 : undefined);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });
  const onCanvasKey = (e: KeyboardEvent<HTMLDivElement>) => {
    const t = e.target as HTMLElement;
    if (editing || t.isContentEditable || t instanceof HTMLInputElement || t instanceof HTMLTextAreaElement) return;
    const mod = e.metaKey || e.ctrlKey;
    if (mod && e.key.toLowerCase() === "a" && slide) {
      e.preventDefault();
      setSelected(scoped.map((x) => x.id));
      return;
    }
    if (e.key === "Escape") {
      // Out of an entered group first, with the group selected.
      setSelected(scope ? [scope] : []);
      setScope(undefined);
      return;
    }
    if (!selection.length || readOnly) return;
    const step = e.shiftKey ? 10 : 1;
    const nudge = { ArrowLeft: [-step, 0], ArrowRight: [step, 0], ArrowUp: [0, -step], ArrowDown: [0, step] }[e.key];
    // e.code, not e.key: with ⌥ held, ] and [ type other characters on a Mac.
    const bracket = e.code === "BracketRight" ? "up" : e.code === "BracketLeft" ? "down" : undefined;
    if (nudge && !mod) {
      e.preventDefault();
      setFrames(Object.fromEntries(selection.map((x) => [x.id, { ...x.frame, x: x.frame.x + nudge[0], y: x.frame.y + nudge[1] }])), `nudge:${[...selIds].join(",")}`);
    } else if (e.key === "Delete" || e.key === "Backspace") {
      e.preventDefault();
      removeSelected();
    } else if (e.key === "Enter" && selectedEl && isImageSlot(selectedEl)) {
      e.preventDefault();
      fillImage(selectedEl.id);
    } else if (e.key === "Enter" && selectedEl && textOf(selectedEl)) {
      e.preventDefault();
      setEditing(selectedEl.id);
    } else if (mod && e.shiftKey && e.key.toLowerCase() === "x" && selection.some((x) => textOf(x))) {
      e.preventDefault();
      tools.format({ kind: "mark", mark: "strike" });
    } else if (mod && e.key.toLowerCase() === "g") {
      e.preventDefault();
      if (e.shiftKey) arrange.ungroup();
      else arrange.group();
    } else if (mod && e.key.toLowerCase() === "d") {
      e.preventDefault();
      arrange.duplicate();
    } else if (mod && bracket) {
      e.preventDefault();
      arrange.order(bracket === "up" ? (e.altKey ? "front" : "forward") : e.altKey ? "back" : "backward");
    }
  };

  // ---- Slides.
  const addSlide = (layout?: Layout) => {
    if (!slide) return;
    const s = newSlide(layout ?? (slide.layout === "title" ? "title-body" : slide.layout));
    update((d) => {
      const i = d.slides.findIndex((x) => x.id === slide.id);
      return { ...d, slides: [...d.slides.slice(0, i + 1), s, ...d.slides.slice(i + 1)] };
    });
    setSlideId(s.id);
    setSelected([]);
  };
  const duplicateSlide = (sid: string) => {
    const src = deckRef.current?.slides.find((s) => s.id === sid);
    if (!src) return;
    const fresh = <T extends Element>(e: T): T => ({ ...structuredClone(e), id: newId("e") });
    const copy: Slide = { ...structuredClone(src), id: newId("s"), elements: src.elements.map((e) => (isGroup(e) ? { ...fresh(e), elements: e.elements.map(fresh) } : fresh(e))) };
    update((d) => {
      const i = d.slides.findIndex((x) => x.id === sid);
      return { ...d, slides: [...d.slides.slice(0, i + 1), copy, ...d.slides.slice(i + 1)] };
    });
    setSlideId(copy.id);
  };
  const removeSlide = (sid: string) => {
    if ((deckRef.current?.slides.length ?? 0) < 2) return;
    const i = deckRef.current!.slides.findIndex((s) => s.id === sid);
    update((d) => ({ ...d, slides: d.slides.filter((s) => s.id !== sid) }));
    const next = deckRef.current!.slides[Math.min(i, deckRef.current!.slides.length - 1)];
    setSlideId(next?.id);
  };
  const moveSlide = (sid: string, to: number) =>
    update((d) => {
      const s = d.slides.find((x) => x.id === sid)!;
      const rest = d.slides.filter((x) => x.id !== sid);
      return { ...d, slides: [...rest.slice(0, to), s, ...rest.slice(to)] };
    });

  // A deck started from a description or an outline asks the persona to draft it, once.
  const brief = search.get("brief");
  const outline = search.get("outline");
  const briefSent = useRef(false);
  useEffect(() => {
    const ask = brief ? `Draft this deck: ${brief}` : outline ? outlinePrompt(outline) : "";
    if (!ask || !chatId || briefSent.current) return;
    briefSent.current = true;
    router.replace(`/apps/slides/${id}`);
    void send.mutateAsync({ body: ask }).catch((e) => setNotice(`Couldn't ask ${persona} to draft the deck: ${errorText(e)}`));
  }, [brief, outline, chatId, id, persona, router, send]);

  const title = ref.data?.title ?? c?.title ?? "Deck";
  const loadError = ref.error ?? head.error;
  // The built-in theme the deck uses, if its copy is unchanged.
  const themeKey = deck ? Object.entries(THEMES).find(([, t]) => t.name === deck.theme.name && same(t.colors, deck.theme.colors) && same(t.fonts, deck.theme.fonts))?.[0] : undefined;

  // ---- The dock: Review opens itself when a review starts; Chat is unread while hidden.
  const compact = useCompact();
  const [showReview, setShowReview] = useState(0);
  const [reviewShown, setReviewShown] = useState(false);
  if (reviewing !== reviewShown) {
    setReviewShown(reviewing);
    if (reviewing) setShowReview((n) => n + 1);
  }
  const [dock, setDock] = useState<DockState>();
  const chatShowing = !dock || (dock.open && !dock.hidden && dock.tab === "chat");
  const lastReply = chat?.last_message_at;
  const [seenReply, setSeenReply] = useState<string>();
  // The reply that was there on load, or that arrived while Chat showed, counts as read.
  if (lastReply && seenReply !== lastReply && (chatShowing || seenReply === undefined)) setSeenReply(lastReply);
  const unread = !chatShowing && !!lastReply && !!seenReply && lastReply !== seenReply && !live;
  const look = personaLook(chat?.speaker ?? chat?.persona);
  const changeCount = changedSlides?.size ?? 0;

  const saveBad = saveState.s === "error" || saveState.s === "conflict";
  const header: EditorHeader = {
    back: { href: "/knowledge", label: "Knowledge" },
    name: title,
    title,
    saveState: ref.data && c && (
      <span data-testid="deck-save-state" title={saveState.message} className={cx("flex items-center gap-1.5", saveBad && "text-pill-blocked-fg")}>
        <span aria-hidden className={cx("size-1.5 rounded-full", saveBad ? "bg-pill-blocked-fg" : saveState.s === "saved" ? "bg-state-done" : "bg-fg-tertiary")} />
        {SAVE_LABEL[saveState.s]} · v{savedSeq || c.seq}
        {saveState.s === "error" && (
          <button type="button" className="text-accent hover:underline" onClick={() => void flush().catch(() => undefined)}>
            Retry
          </button>
        )}
      </span>
    ),
    presence: ref.data && (
      <span className="flex items-center gap-1.5 text-12 text-fg-tertiary">
        <PersonaAvatar persona={look} size={22} className={cx(live && "animate-pulse ring-2 ring-[#3FC1B0] motion-reduce:animate-none")} />
        {live ? `${persona} is editing…` : reviewing ? `${persona} suggested changes` : `${persona} can edit`}
      </span>
    ),
    actions: ref.data
      ? [
          <Button key="present" variant="secondary" onClick={() => void present()} disabled={!deck} hint="⌘↵">
            ▶ Present
          </Button>,
          deck ? <ExportMenu key="share" deckId={id} title={title} current={flush} assetUrl={assetUrl} fontsReady={fonts} /> : undefined,
        ]
      : undefined,
  };

  const thumbnails = deck && slide && (
    <Thumbnails
      deck={reviewing && headDeck ? headDeck : deck}
      current={slide.id}
      onSelect={(sid) => {
        setSlideId(sid);
        setSelected([]);
        setEditing(undefined);
        if (reviewing && changedSlides?.has(sid)) {
          setShowReview((n) => n + 1);
          requestAnimationFrame(() => document.querySelector(`[data-change-slide="${CSS.escape(sid)}"]`)?.scrollIntoView({ block: "nearest" }));
        }
      }}
      onMove={moveSlide}
      onDuplicate={duplicateSlide}
      onRemove={removeSlide}
      onAdd={() => addSlide()}
      onAddLayout={addSlide}
      assetUrl={assetUrl}
      fontsReady={fonts}
      overflowing={overflowingSlides}
      changed={changedSlides}
      persona={persona}
      readOnly={readOnly}
    />
  );

  const main = loadError ? (
    <div className="mx-auto w-full max-w-[720px] p-6">
      <Banner tone="blocked" title="Couldn’t open this deck" actions={<Button onClick={() => router.push("/knowledge")}>Back to Knowledge</Button>}>
        {loadError instanceof ApiError && loadError.status === 404 ? "It may have been deleted, or it belongs to someone else." : errorText(loadError)}
      </Banner>
    </div>
  ) : !deck || !slide || !c ? (
    <div aria-busy="true" className="flex min-h-0 flex-1 flex-col gap-3 p-4">
      <Skeleton className="h-8 w-1/2" />
      <Skeleton className="aspect-video w-full max-w-[900px]" />
    </div>
  ) : (
    <div className="flex min-h-0 min-w-0 flex-1 max-md:flex-col-reverse">
      {compact && thumbnails}
      <main className="flex min-h-0 min-w-0 flex-1 flex-col bg-surface-sunken">
        <Toolbar theme={deck.theme} themeKey={themeKey} layout={slide.layout} slide={slide} selection={selection} editing={!!editing} disabled={readOnly} a={tools} />
        <input ref={fileInput} type="file" accept="image/*" className="hidden" aria-label="Add an image to the slide" data-testid="slide-image-input" onChange={(e) => {
          const f = e.target.files?.[0];
          e.target.value = "";
          if (f) void onImage(f);
        }} />
        <div className="min-h-0 flex-1 overflow-y-auto px-8 py-6 max-sm:px-3" onKeyDown={onCanvasKey}>
          <div className="mx-auto flex max-w-[1100px] flex-col gap-3">
            {reviewing && (
              <Banner tone="human" title={`${persona} suggested ${changeCount === 1 ? "1 change" : `${changeCount || "some"} changes`}`} actions={<Button variant="approve" onClick={() => setShowReview((n) => n + 1)}>Review</Button>}>
                Editing is paused until you decide them in Review.
              </Banner>
            )}
            {conflict && (
              <Banner
                tone="blocked"
                title="This deck changed while you were editing"
                actions={
                  <>
                    <Button
                      variant="secondary"
                      onClick={() => {
                        conflicted.current = false;
                        markSaved(conflict.seq, conflict.theirs);
                        setDeck(conflict.theirs);
                        resetHist();
                        setDirty(false);
                        setConflict(null);
                        setSaveState({ s: "saved" });
                      }}
                    >
                      Use the latest version
                    </Button>
                    <Button
                      variant="primary"
                      onClick={() => {
                        conflicted.current = false;
                        setConflict(null);
                        void flush().catch(() => undefined);
                      }}
                    >
                      Keep mine
                    </Button>
                  </>
                }
              >
                {persona} changed some of the same slides you did. Keep mine saves your version over theirs (theirs stays in the version history).
              </Banner>
            )}
            {live && <Banner tone="human" title={`${persona} is editing…`}>The canvas is read-only until {persona} finishes; you’ll then review the changes.</Banner>}
            {archived && <Banner tone="human" title="This deck’s chat is archived">Restore the chat to edit the deck.</Banner>}
            {saveState.s === "error" && <Banner tone="blocked" title="Couldn’t save your changes" actions={<Button onClick={() => void flush().catch(() => undefined)}>Retry now</Button>}>{saveState.message} Your edits are kept in this tab; don’t close it yet.</Banner>}
            {(notice || uploading) && <p role={notice ? "alert" : "status"} className={cx("text-12", notice ? "text-pill-blocked-fg" : "text-fg-secondary")}>{notice ?? "Uploading image…"}</p>}
            <SlideCanvas
              deck={deck}
              slide={slide}
              assetUrl={assetUrl}
              fontsReady={fonts}
              selected={selected}
              onSelect={setSelected}
              scope={scope}
              onScope={setScope}
              editing={editing}
              onEdit={setEditing}
              onFillImage={fillImage}
              onFrames={(live) => update(mapElements(new Set(Object.keys(live)), (e) => (isGroup(e) ? withFrame(e, live[e.id].frame) : { ...e, ...live[e.id] })))}
              onText={(eid, paragraphs) => update(mapElement(eid, (e) => withText(e, paragraphs)))}
              readOnly={readOnly}
              editorRef={editorRef}
              overflow={overflowHere}
            />
            <label className="flex flex-col gap-1.5 rounded-xl border border-border bg-surface p-3">
              <span className="flex items-center justify-between text-12 font-medium text-fg-secondary">
                Speaker notes
                <span className="font-mono text-12 font-normal text-fg-tertiary">
                  Slide {deck.slides.findIndex((s) => s.id === slide.id) + 1} of {deck.slides.length}
                </span>
              </span>
              <textarea
                className="min-h-[72px] resize-y bg-transparent text-14 text-fg-2 outline-none placeholder:text-fg-tertiary"
                placeholder="What to say on this slide"
                value={slide.notes ?? ""}
                readOnly={readOnly}
                maxLength={10000}
                onChange={(e) => {
                  const notes = e.target.value;
                  update(mapSlide(slide.id, (s) => ({ ...s, notes: notes || undefined })), `notes:${slide.id}`);
                }}
              />
            </label>
            <label className="flex items-center gap-2 text-13 text-fg-secondary">
              <input type="checkbox" checked={!!slide.hidden} disabled={readOnly} onChange={(e) => update(mapSlide(slide.id, (s) => ({ ...s, hidden: e.target.checked || undefined })))} />
              Skip this slide when presenting and exporting
            </label>
          </div>
        </div>
      </main>
      {themeEdit && (
        <ThemeEditor
          start={themeEdit.start}
          target={themeEdit.target}
          deck={deck}
          slide={slide}
          assetUrl={assetUrl}
          fontsReady={fonts}
          busy={createTheme.isPending || updateTheme.isPending}
          error={themeError}
          onClose={() => setThemeEdit(null)}
          onApply={(t) => {
            tools.setTheme(t);
            setThemeEdit(null);
          }}
          onSave={(t) =>
            createTheme.mutate(themeBody(t), {
              onSuccess: (s) => {
                tools.setTheme(s);
                setThemeEdit(null);
              },
              onError: (e) => setThemeError(errorText(e)),
            })
          }
          onUpdate={(t) => {
            const target = themeEdit.target;
            if (target.kind !== "saved") return;
            updateTheme.mutate({ id: target.id, ...themeBody(t) }, { onSuccess: () => setThemeEdit(null), onError: (e) => setThemeError(errorText(e)) });
          }}
        />
      )}
    </div>
  );

  const dockTabs: DockTab[] = [
    {
      id: "chat",
      label: "Chat",
      icon: "msg",
      avatar: <PersonaAvatar persona={look} size={16} />,
      busy: live,
      unread,
      content: <div data-deck-chat className="flex min-h-0 flex-1 flex-col">{chatId && <Conversation key={chatId} id={chatId} docked onNew={() => router.push("/knowledge")} />}</div>,
    },
  ];
  if (reviewing && c)
    dockTabs.push({
      id: "review",
      label: "Review",
      icon: "check",
      badge: changeCount ? <span className="rounded-full bg-pill-review-bg px-1.5 text-11 text-pill-review-fg">{changeCount}</span> : undefined,
      content:
        baseDeck && headDeck ? (
          <DeckReview
            key={`${base}-${c.seq}`}
            base={baseDeck}
            head={headDeck}
            persona={persona}
            assetUrl={assetUrl}
            fontsReady={fonts}
            busy={archived || reviewed.isPending || actions.save.isPending}
            error={reviewed.error || actions.save.error ? errorText(reviewed.error ?? actions.save.error) : undefined}
            onAcceptAll={() => reviewed.mutate(c.seq)}
            onResolve={(d, note) =>
              actions.save.mutate(
                { base_seq: c.seq, body: encodeDeck(d), note },
                { onSuccess: (v) => reviewed.mutate(v.seq) },
              )
            }
          />
        ) : (
          <div aria-busy="true" className="p-3"><Skeleton className="h-[320px]" /></div>
        ),
    });

  return (
    <EditorLayout
      app="slides"
      header={header}
      show={{ tab: "review", n: showReview }}
      onDockChange={setDock}
      left={!compact && !loadError ? thumbnails || <div aria-busy="true" className="flex flex-col gap-3 p-3">{[0, 1, 2, 3].map((i) => <Skeleton key={i} className="aspect-video w-full" />)}</div> : undefined}
      main={main}
      dock={dockTabs}
    />
  );
}
