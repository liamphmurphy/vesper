"use client";

import { useRecordVisit } from "@/components/shell/use-record-visit";
import { useRouter, useSearchParams } from "next/navigation";
import { DropdownMenu, Popover } from "radix-ui";
import { useCallback, useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import { ApiError } from "@/lib/api/client";
import { fetchDesign, fetchDesignVersion, uploadDesignAsset, useDesign, useDesignProposals, useDesignSettings, useDesignVersion, useDuplicateDesign, useRenameDesign, useResolveProposal, useSaveDesign } from "@/lib/api/designs-hooks";
import { provideChatRefs, useChat, useChatRunEvents, useSendChatMessage } from "@/lib/api/hooks";
import { toolCalls } from "@/lib/chat-ui";
import { cx } from "@/lib/cx";
import * as W from "@/lib/designs/doc";
import { dropTarget } from "@/lib/designs/hit";
import { duplicateNodes, find, groupNodes, inAutoLayout, insertNodes, labelOf, mapNodes, newId, removeNodes, reorder, topLevelIds, ungroupNodes, type ZOrder } from "@/lib/designs/edit";
import { makeLayout, settle, type LaidNode, type LaidPage } from "@/lib/designs/layout";
import { mergeDesigns } from "@/lib/designs/merge";
import { presenceOf } from "@/lib/designs/presence";
import { adoptVersion, pendingGhosts, type Change } from "@/lib/designs/review";
import { designAssetHref, useDesignFonts } from "@/lib/designs/render";
import { DesignError, normalize, type Design, type DesignNode, type ImageNode } from "@/lib/designs/schema";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { Banner, Skeleton } from "@/components/ui/primitives";
import { EditorLayout, type DockTab, type EditorHeader } from "@/components/shell/editor-layout";
import { floatPanel } from "@/components/domain/pickers";
import type { DockState } from "@/lib/editor-layout";
import { tokensChanged } from "@/lib/designs/tokens";
import { PersonaAvatar, personaLook } from "@/app/(app)/chat/_components/persona";
import { Conversation } from "@/app/(app)/chat/_components/conversation";
import { DesignCanvas, fitCamera, zoomAt, type Camera, type Tool } from "./design-canvas";
import { GhostLayer, ReviewOverlay, ReviewPanel, ReviewPill, stepChange, suggestionPages, useReview, type ReviewMode } from "./design-review";
import { ExportMenu } from "./export-menu";
import { PresenceLayer } from "./presence-layer";
import { Inspector } from "./inspector";
import { PrototypePanel } from "./prototype-panel";
import { InspectPanel, TokensSyncBadge } from "./library-panels";
import { LayersPanel } from "./layers-panel";

type SaveState = "saved" | "unsaved" | "saving" | "conflict" | "error";
const SAVE_LABEL: Record<SaveState, string> = { saved: "Saved", unsaved: "Unsaved changes", saving: "Saving…", conflict: "Not saved", error: "Not saved" };
/** Until the canvas has measured itself and the page is fitted, nothing shows. */
const HIDDEN_CAMERA: Camera = { x: -1e7, y: -1e7, z: 1 };
/** Edits within this quiet time save as one version. */
export const AUTOSAVE_MS = 800;
const MAX_IMAGE_EDGE = 4096;
const errorText = (e: unknown) => (e instanceof Error ? e.message : "Something went wrong. Please try again.");

const TOOLS: { tool: Tool | "image"; label: string; key: string; glyph: string }[] = [
  { tool: "select", label: "Move", key: "V", glyph: "➤" },
  { tool: "hand", label: "Hand", key: "H", glyph: "✋" },
  { tool: "frame", label: "Frame", key: "F", glyph: "#" },
  { tool: "rect", label: "Rectangle", key: "R", glyph: "▭" },
  { tool: "ellipse", label: "Ellipse", key: "O", glyph: "◯" },
  { tool: "line", label: "Line", key: "L", glyph: "╱" },
  { tool: "pen", label: "Pen", key: "P", glyph: "✒" },
  { tool: "text", label: "Text", key: "T", glyph: "T" },
  { tool: "image", label: "Image", key: "⇧⌘K", glyph: "▣" },
  { tool: "sticky", label: "Sticky", key: "S", glyph: "▤" },
  { tool: "section", label: "Section", key: "⇧S", glyph: "⌗" },
  { tool: "connector", label: "Connector", key: "C", glyph: "→" },
];
/** The beside-chat panel's cut-down toolbar (docs/design/designs-from-chat.svg). */
const BESIDE_TOOLS = new Set<Tool | "image">(["select", "frame", "rect", "line", "text"]);
const menuItem = "flex cursor-pointer select-none items-center rounded-md px-2.5 py-1.5 text-13 text-fg outline-none data-[highlighted]:bg-hover";
const TOOL_KEYS: Record<string, Tool> = { v: "select", h: "hand", f: "frame", a: "frame", r: "rect", o: "ellipse", l: "line", p: "pen", t: "text", s: "sticky", c: "connector" };

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

/** A top-level node's ops, kept while the node and what it depends on (tokens, assets, components) are the same objects. */
const laidCache = new WeakMap<DesignNode, { deps: unknown[]; laid: LaidNode }>();

/**
 * The page's display list, reusing a top-level node's ops while that node
 * (and what instances and tokens depend on) is the same object, so an edit
 * re-renders only the nodes it touched.
 */
function useLaidPage(design: Design | undefined, pageId: string | undefined): { laid?: LaidPage; lay?: ReturnType<typeof makeLayout> } {
  return useMemo(() => {
    const page = design?.pages.find((p) => p.id === pageId) ?? design?.pages[0];
    if (!design || !page) return {};
    const lay = makeLayout(design);
    const laid = lay.layoutPage(page);
    const components: DesignNode[] = [];
    for (const p of design.pages) {
      const walk = (list: DesignNode[]) => {
        for (const n of list) {
          if (n.type === "component") components.push(n);
          if ("children" in n && Array.isArray(n.children)) walk(n.children);
        }
      };
      walk(p.children);
    }
    const deps = [design.mode, design.token_sets, design.tokens_ref, design.assets, ...components];
    const byId = new Map(page.children.map((n) => [n.id, n]));
    laid.nodes = laid.nodes.map((ln) => {
      const node = byId.get(ln.id)!;
      const prev = laidCache.get(node);
      if (prev && prev.deps.length === deps.length && prev.deps.every((d, i) => d === deps[i])) return prev.laid;
      laidCache.set(node, { deps, laid: ln });
      return ln;
    });
    return { laid, lay };
  }, [design, pageId]);
}

/**
 * A design: pages and layers, the canvas, the inspector and the design's
 * chat (docs/design/designs-editor.svg). Edits save themselves as versions
 * after a quiet moment; a version from elsewhere merges per node, and
 * overlapping changes ask the person.
 */
/** Beside the chat: closing, and the review in place, whose open state the chat keeps in its URL (review=1). */
type Beside = { onClose: () => void; reviewing?: boolean; onReview?: (on: boolean) => void };

export function DesignEditor({ id, beside }: { id: string; beside?: Beside }) {
  const router = useRouter();
  const search = useSearchParams();
  const ref = useDesign(id);
  useRecordVisit(ref.data ? { id: `design-${id}`, title: ref.data.title || "Design", meta: "Design", href: `/apps/designs/${id}`, kind: "Designs" } : undefined);
  const chatId = ref.data?.chat_id ?? "";
  const chat = useChat(chatId || undefined).data;
  const persona = (chat?.speaker ?? chat?.persona)?.name ?? "Assistant";
  const head = useDesignVersion(id, ref.data?.seq);
  const save = useSaveDesign(id);
  // mutateAsync is stable across renders; the mutation object isn't (a Slides review fix).
  const saveVersion = save.mutateAsync;
  const send = useSendChatMessage(chatId);
  useDesignFonts();
  const assetUrl = useCallback((a: string) => designAssetHref(id, a), [id]);

  // ---- The working copy (lib/designs/doc.ts) in a ref; `tick` re-renders on change.
  const docRef = useRef<W.Doc | null>(null);
  const [doc, setDocState] = useState<W.Doc | null>(null);
  const setDoc = (d: W.Doc) => {
    docRef.current = d;
    setDocState(d);
  };
  const [saveState, setSaveState] = useState<{ s: SaveState; message?: string }>({ s: "saved" });
  const [conflict, setConflict] = useState<{ theirs: Design; seq: number; layers: string[] } | null>(null);
  const conflicted = useRef(false);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const saving = useRef<Promise<void> | null>(null);
  const retries = useRef(0);
  const retryRef = useRef<() => void>(() => undefined);
  const scheduleRef = useRef<() => void>(() => undefined);
  const personaRef = useRef(persona);
  useEffect(() => {
    personaRef.current = persona;
  }, [persona]);
  const [loadError, setLoadError] = useState<string>();

  const runSave = useCallback(async (): Promise<void> => {
    for (let attempt = 0; attempt < 3; attempt++) {
      const cur = docRef.current;
      if (!cur || conflicted.current) return;
      if (!W.isDirty(cur)) {
        setSaveState({ s: "saved" });
        return;
      }
      const mine = cur.draft;
      const base = cur.saved;
      let body: string;
      try {
        // The layout's boxes are a cache in the body (ADR §3.2): written fresh on save.
        body = normalize(settle(mine)).json;
      } catch (e) {
        setSaveState({ s: "error", message: `This change can’t be saved: ${errorText(e)}` });
        return;
      }
      setSaveState({ s: "saving" });
      try {
        const v = await saveVersion({ base_seq: base.seq, body, note: "Edited" });
        retries.current = 0;
        const now = docRef.current!;
        setDoc(W.saved(now, v.seq, mine));
        if (now.draft === mine) setSaveState({ s: "saved" });
        else setSaveState({ s: "unsaved" });
        return;
      } catch (e) {
        if (e instanceof ApiError && e.status === 409) {
          // Saved elsewhere in between (a persona with direct edit, another tab): merge per node, or ask.
          let latest: { seq: number }, theirs: Design;
          try {
            latest = await fetchDesign(id);
            theirs = normalize((await fetchDesignVersion(id, latest.seq)).body).design;
          } catch (err) {
            setSaveState({ s: "error", message: `Couldn’t load the newer version: ${errorText(err)}` });
            retryRef.current();
            return;
          }
          const now = docRef.current!;
          // All three settled, so cached boxes don't look like edits on either side.
          const r = mergeDesigns(base.design, W.settled(now.draft), W.settled(theirs));
          if (r.design) {
            setDoc(W.merged(now, latest.seq, theirs, r.design));
            setSaveState({ s: "unsaved" });
            continue;
          }
          conflicted.current = true;
          clearTimeout(timer.current);
          const names = r.conflicts.map((c) => {
            const f = find(now.draft, c) ?? find(theirs, c);
            return f ? labelOf(f.node) : (now.draft.pages.find((p) => p.id === c) ?? theirs.pages.find((p) => p.id === c))?.name ?? "the design’s settings";
          });
          setConflict({ theirs, seq: latest.seq, layers: [...new Set(names)] });
          setSaveState({ s: "conflict", message: "This design changed while you were editing." });
        } else if (e instanceof ApiError && e.status === 422 && /changes nothing/.test(e.message)) {
          setDoc(W.saved(docRef.current!, base.seq, mine));
          setSaveState({ s: "saved" });
        } else {
          setSaveState({ s: "error", message: errorText(e) });
          retryRef.current();
        }
        return;
      }
    }
    setSaveState({ s: "error", message: "The design kept changing while saving." });
    retryRef.current();
  }, [saveVersion, id]);

  /** Saves now (after any save in flight). */
  const flush = useCallback(async () => {
    clearTimeout(timer.current);
    while (saving.current) await saving.current;
    if (docRef.current && W.isDirty(docRef.current) && !conflicted.current) {
      saving.current = runSave().finally(() => (saving.current = null));
      await saving.current;
    }
  }, [runSave]);

  /** Debounced autosave: every edit restarts the quiet time, so a burst of edits is one version. */
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
  useEffect(() => {
    scheduleRef.current = () => schedule();
    retryRef.current = () => {
      retries.current += 1;
      schedule(Math.min(30_000, 2_000 * 2 ** (retries.current - 1)));
    };
  }, [schedule]);

  // Open the design, then follow the server: a version from elsewhere (a persona's direct edit, an
  // accepted suggestion) replaces a clean draft or merges into unsaved edits, and is one undo step.
  const [arrival, setArrival] = useState<{ seq: number; text: string }>();
  useEffect(() => {
    const v = head.data;
    if (!v) return;
    let d: Design;
    try {
      d = normalize(v.body).design;
    } catch (e) {
      // Showing why the body can't be opened (external data).
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setLoadError(e instanceof DesignError ? e.message : errorText(e));
      return;
    }
    const cur = docRef.current;
    if (!cur) {
      setDoc(W.open(v.seq, d));
      return;
    }
    // A save in flight (or a conflict being asked about) meets the newer version itself, as a 409.
    if (v.seq <= cur.saved.seq || saving.current || conflicted.current) return;
    const r = adoptVersion(cur, v.seq, d);
    if (r.doc === cur) return;
    setDoc(r.doc);
    if (r.doc.past !== cur.past) {
      setArrival({ seq: v.seq, text: v.author_type === "agent" ? `${personaRef.current} edited the design` : "Accepted changes were applied" });
    }
    if (W.isDirty(r.doc)) {
      setSaveState({ s: "unsaved" });
      scheduleRef.current();
    }
  }, [head.data]);

  // Save on the way out: hidden tab, closed page or navigation.
  const flushRef = useRef(flush);
  useEffect(() => {
    flushRef.current = flush;
  }, [flush]);
  useEffect(() => {
    const dirty = () => !!docRef.current && W.isDirty(docRef.current);
    const hide = () => {
      if (document.visibilityState === "hidden" && dirty()) void flushRef.current().catch(() => undefined);
    };
    const leave = (e: BeforeUnloadEvent) => {
      if (dirty()) e.preventDefault();
    };
    document.addEventListener("visibilitychange", hide);
    window.addEventListener("beforeunload", leave);
    return () => {
      document.removeEventListener("visibilitychange", hide);
      window.removeEventListener("beforeunload", leave);
      if (dirty()) void flushRef.current().catch(() => undefined);
    };
  }, []);

  // ---- Review (a persona's suggestions as a diff): After and Diff show a preview, so nothing is editable there.
  const proposals = useDesignProposals(id, !!ref.data).data;
  // ?review=1 (the chat's panel sheet sends it) opens straight into the review. Beside the chat, the chat's URL holds it.
  const [reviewState, setReviewState] = useState(() => search.get("review") === "1");
  const reviewOpen = beside ? !!beside.reviewing : reviewState;
  const setReviewing = (on: boolean) => (beside ? beside.onReview?.(on) : setReviewState(on));
  const reviewing = reviewOpen && !!proposals?.length;
  const [mode, setMode] = useState<ReviewMode>("diff");
  const [resolving, setResolving] = useState(false);
  const [resolveError, setResolveError] = useState<string>();
  const resolve = useResolveProposal(id);
  const settings = useDesignSettings(id);
  const viewOnly = reviewing && mode !== "before" && !!proposals?.length;
  const readOnly = !!conflict || !!chat?.archived || viewOnly;
  const readOnlyRef = useRef(readOnly);
  useEffect(() => {
    readOnlyRef.current = readOnly;
  }, [readOnly]);

  /** One edit of the working copy; key coalesces a drag or typing into one undo step. */
  const apply = useCallback(
    (fn: (d: Design) => Design, key?: string) => {
      const cur = docRef.current;
      if (!cur || readOnlyRef.current) return;
      const next = fn(cur.draft);
      if (next === cur.draft) return;
      setDoc(W.edit(cur, next, key));
      setSaveState({ s: "unsaved" });
      schedule();
    },
    [schedule],
  );
  const travel = (back: boolean) => {
    const cur = docRef.current;
    if (!cur || readOnly) return;
    const next = back ? W.undo(cur) : W.redo(cur);
    if (next === cur) return;
    setDoc(next);
    setEditing(undefined);
    setSaveState({ s: "unsaved" });
    schedule();
  };

  // ---- Page, selection, tools and camera.
  const design = doc?.draft;
  const review = useReview(design, proposals, reviewing);
  // What the canvas draws: the working copy, or in After / Diff the suggestion applied to it.
  const shown = viewOnly && review ? review.after : design;
  const [pageId, setPageId] = useState<string>();
  const page = shown?.pages.find((p) => p.id === pageId) ?? shown?.pages[0];
  const [selectedRaw, setSelected] = useState<string[]>([]);
  const [editing, setEditing] = useState<string>();
  const [tool, setTool] = useState<Tool>("select");
  const { laid, lay } = useLaidPage(shown, page?.id);
  // Outside review, what the persona has suggested so far is drawn faded over the working copy. Deferred: a drag
  // re-lays the whole suggested design, which mustn't hold up the drag's own frames.
  const ghostBase = useDeferredValue(design);
  const ghosts = useMemo(() => (!reviewing && ghostBase && proposals?.length ? pendingGhosts(ghostBase, proposals) : undefined), [reviewing, ghostBase, proposals]);
  const ghostLaid = useLaidPage(ghosts?.after, page?.id).laid;
  // Ids that left the page (undo, another page) drop out of the selection.
  const selected = useMemo(() => (laid ? selectedRaw.filter((s) => laid.boxes.has(s)) : []), [selectedRaw, laid]);
  const [camera, setCameraState] = useState<Camera | null>(null);
  const [viewport, setViewport] = useState({ w: 1200, h: 800, known: false });
  const camKey = page ? `designs.camera.${id}.${page.id}` : "";
  const setCamera = useCallback((c: Camera | ((c: Camera) => Camera)) => setCameraState((prev) => (typeof c === "function" ? (prev ? c(prev) : prev) : c)), []);
  // Each page keeps its own camera in this browser (ADR §3.2); a page opens fitted the first time.
  useEffect(() => {
    if (!camKey || !laid || !viewport.known) return;
    let c: Camera | null = null;
    try {
      const v = JSON.parse(localStorage.getItem(camKey) ?? "null");
      if (v && [v.x, v.y, v.z].every(Number.isFinite)) c = v;
    } catch {
      // Unreadable storage: fit the page.
    }
    // Choosing the camera once the page is known (browser storage).
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setCameraState(c ?? fitCamera(laid.box, viewport.w, viewport.h));
    // eslint-disable-next-line react-hooks/exhaustive-deps -- only when the page changes
  }, [camKey, !!laid, viewport.known]);
  useEffect(() => {
    if (!camera || !camKey) return;
    const t = setTimeout(() => {
      try {
        localStorage.setItem(camKey, JSON.stringify(camera));
      } catch {
        // Storage full or blocked: the camera resets next time.
      }
    }, 300);
    return () => clearTimeout(t);
  }, [camera, camKey]);
  const zoomBy = (k: number) => setCamera((c) => zoomAt(c, c.z * k, viewport.w / 2, viewport.h / 2));
  const zoomToFit = () => laid && setCameraState(fitCamera(selected.length ? unionOf(selected) : laid.box, viewport.w, viewport.h));
  const unionOf = (ids: string[]) => {
    const bs = ids.map((s) => laid!.boxes.get(s)).filter((b) => !!b);
    const x = Math.min(...bs.map((b) => b.x)), y = Math.min(...bs.map((b) => b.y));
    return { x, y, w: Math.max(...bs.map((b) => b.x + b.w)) - x, h: Math.max(...bs.map((b) => b.y + b.h)) - y };
  };

  // ---- Commands on the selection: each is one undo step.
  const removeSelected = () => {
    if (!selected.length) return;
    apply((d) => removeNodes(d, new Set(selected)));
    setSelected([]);
  };
  const duplicateSelected = () => {
    if (!selected.length || !doc) return;
    let made: string[] = [];
    apply((d) => {
      const r = duplicateNodes(d, selected);
      made = r.ids;
      return r.design;
    });
    if (made.length) setSelected(made);
  };
  const group = () => {
    let gid = "";
    apply((d) => {
      const r = groupNodes(d, selected);
      if (!r) return d;
      gid = r.id;
      return r.design;
    });
    if (gid) setSelected([gid]);
  };
  const ungroup = () => {
    let freed: string[] = [];
    apply((d) => {
      const r = ungroupNodes(d, selected);
      freed = r.ids;
      return r.design;
    });
    if (freed.length) setSelected(freed);
  };
  const order = (op: ZOrder) => selected.length && apply((d) => reorder(d, new Set(selected), op));
  const nudge = (dx: number, dy: number) =>
    selected.length &&
    apply((d) => mapNodes(d, new Set(selected.filter((s) => {
      const f = find(d, s);
      return f && f.node.type !== "connector" && !inAutoLayout(f.parent) && !f.node.locked;
    })), (n) => (n.type === "connector" ? n : ({ ...n, x: n.x + dx, y: n.y + dy } as DesignNode))), `nudge:${selected.join(",")}`);
  const toggleAutoLayout = () => {
    if (selected.length !== 1) return;
    apply((d) => mapNodes(d, new Set(selected), (n) => {
      if (n.type !== "frame" && n.type !== "component") return n;
      if (n.auto_layout) return n;
      return { ...n, auto_layout: { direction: "vertical", gap: 16, padding: [16, 16, 16, 16] } };
    }));
  };

  // ---- Images: uploaded, added to the assets, placed in the frame under the viewport centre.
  const fileInput = useRef<HTMLInputElement>(null);
  const [notice, setNotice] = useState<string>();
  const [uploading, setUploading] = useState(false);
  const onImage = async (file: File) => {
    const target = page?.id;
    if (!target || !camera) return;
    setNotice(undefined);
    setUploading(true);
    try {
      const blob = await prepareImage(file);
      if (blob.size > 10 << 20) throw new Error(`${file.name} is ${(blob.size / (1 << 20)).toFixed(0)} MB: the limit is 10 MB`);
      const a = await uploadDesignAsset(id, blob);
      if (readOnlyRef.current) throw new Error("the design became read-only while uploading; add it again once you can edit");
      const k = Math.min(600 / a.w, 600 / a.h, 1);
      const w = Math.round(a.w * k), h = Math.round(a.h * k);
      const cx0 = (viewport.w / 2 - camera.x) / camera.z, cy0 = (viewport.h / 2 - camera.y) / camera.z;
      const node: ImageNode = { id: newId("n"), type: "image", name: file.name.replace(/\.[a-z0-9]+$/i, "").slice(0, 200) || "Image", asset: a.id, x: Math.round(cx0 - w / 2), y: Math.round(cy0 - h / 2), w, h, alt: file.name.replace(/\.[a-z0-9]+$/i, "").slice(0, 500) };
      const board = laid ? dropTarget(page, laid.boxes, cx0, cy0) : undefined;
      const bb = board && laid?.boxes.get(board.id);
      if (board && bb) Object.assign(node, { x: node.x - Math.round(bb.x), y: node.y - Math.round(bb.y) });
      apply((d) => insertNodes({ ...d, assets: { ...d.assets, [a.id]: { mime: a.mime as "image/png" | "image/jpeg", w: a.w, h: a.h } } }, board?.id ?? target, [node]));
      setSelected([node.id]);
    } catch (e) {
      setNotice(`Couldn’t add ${file.name}: ${errorText(e)}`);
    } finally {
      setUploading(false);
    }
  };

  // ---- Keyboard.
  const root = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement;
      // Beside a chat, keys are the design's only while focus is in the panel (or nowhere).
      if (beside && t !== document.body && !root.current?.contains(t)) return;
      // Nor while it's out of sight: behind another tab of the chat's dock, or in the collapsed dock.
      if (beside && (!root.current || root.current.closest("[hidden]"))) return;
      if (t.isContentEditable || t instanceof HTMLInputElement || t instanceof HTMLTextAreaElement || t instanceof HTMLSelectElement) return;
      // The chat rail takes its own keys.
      if (t.closest?.("[data-design-chat]")) return;
      const mod = e.metaKey || e.ctrlKey;
      const k = e.key.toLowerCase();
      if (mod && k === "z") {
        e.preventDefault();
        travel(!e.shiftKey);
      } else if (mod && k === "y") {
        e.preventDefault();
        travel(false);
      } else if (mod && k === "s") {
        e.preventDefault();
        void flush();
      } else if (mod && k === "a") {
        e.preventDefault();
        if (page) setSelected(topLevelIds(page));
      } else if (mod && k === "d") {
        e.preventDefault();
        if (!readOnly) duplicateSelected();
      } else if (mod && k === "g") {
        e.preventDefault();
        if (readOnly) return;
        if (e.shiftKey) ungroup();
        else group();
      } else if (mod && (e.code === "BracketRight" || e.code === "BracketLeft")) {
        e.preventDefault();
        if (!readOnly) order(e.code === "BracketRight" ? (e.altKey ? "front" : "forward") : e.altKey ? "back" : "backward");
      } else if (mod && e.shiftKey && k === "k") {
        e.preventDefault();
        if (!readOnly) fileInput.current?.click();
      } else if (mod && (k === "=" || k === "+")) {
        e.preventDefault();
        zoomBy(1.25);
      } else if (mod && k === "-") {
        e.preventDefault();
        zoomBy(0.8);
      } else if ((mod && k === "0") || (e.shiftKey && e.code === "Digit0")) {
        e.preventDefault();
        setCamera((c) => zoomAt(c, 1, viewport.w / 2, viewport.h / 2));
      } else if (e.shiftKey && e.code === "Digit1") {
        e.preventDefault();
        zoomToFit();
      } else if (e.shiftKey && k === "a" && !mod) {
        e.preventDefault();
        if (!readOnly) toggleAutoLayout();
      } else if (e.shiftKey && k === "s" && !mod) {
        e.preventDefault();
        if (!readOnly) setTool("section");
      } else if (e.key === "Escape") {
        // Consumed here, so the panel sheet around a design (chat-panel-host) stays open.
        if (tool !== "select" || selected.length) e.preventDefault();
        if (tool !== "select") setTool("select");
        else if (selected.length) {
          // Up to the parent first, then nothing.
          const f = selected.length === 1 && design ? find(design, selected[0]) : undefined;
          setSelected(f?.parent ? [f.parent.id] : []);
        }
      } else if ((e.key === "Delete" || e.key === "Backspace") && !readOnly) {
        e.preventDefault();
        removeSelected();
      } else if (e.key === "Enter" && selected.length === 1 && design) {
        e.preventDefault();
        const n = find(design, selected[0])?.node;
        if ((n?.type === "text" || n?.type === "sticky") && !readOnly) setEditing(n.id);
        else if (n && "children" in n && n.children.length) setSelected(n.children.filter((c) => c.type !== "connector").map((c) => c.id));
      } else if (e.key.startsWith("Arrow") && !mod && !readOnly && selected.length) {
        e.preventDefault();
        const s = e.shiftKey ? 10 : 1;
        nudge(e.key === "ArrowLeft" ? -s : e.key === "ArrowRight" ? s : 0, e.key === "ArrowUp" ? -s : e.key === "ArrowDown" ? s : 0);
      } else if (!mod && !e.altKey && !e.shiftKey && TOOL_KEYS[k] && !readOnly) {
        setTool(TOOL_KEYS[k]);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  // Every message sent from this design's chat carries what the person has selected and is looking at.
  const ctx = useRef({ page: "", selected: [] as string[], camera: null as Camera | null, w: 1200, h: 800 });
  useEffect(() => {
    ctx.current = { page: page?.id ?? "", selected, camera, w: viewport.w, h: viewport.h };
  });
  useEffect(() => {
    if (!chatId) return;
    return provideChatRefs(chatId, () => {
      const c = ctx.current;
      if (!c.page) return undefined;
      const z = c.camera?.z ?? 1;
      const viewportBox = c.camera ? { x: Math.round(-c.camera.x / z), y: Math.round(-c.camera.y / z), w: Math.round(c.w / z), h: Math.round(c.h / z), zoom: z } : { x: 0, y: 0, w: Math.round(c.w), h: Math.round(c.h), zoom: 1 };
      return [{ kind: "canvas", id, selection: { page: c.page, nodes: c.selected.slice(0, 100), viewport: viewportBox } }];
    });
  }, [chatId, id]);

  // ---- Presence: the persona's running turn names the canvas and nodes it is working on.
  const running = chat?.state === "running";
  const events = useChatRunEvents(chat?.current_run_id, running && !!ref.data).data;
  const presence = useMemo(() => (running ? presenceOf(toolCalls(events), id, true) : undefined), [events, running, id]);
  // The nodes it touched once they reach this tab, as ghosts while they wait for review; until then, where its
  // input says it is working (the parent it adds to).
  const presenceNodes = useMemo(() => {
    if (!presence || !laid) return [];
    const laidOut = (ids: string[]) => ids.flatMap((id) => {
      const box = laid.boxes.get(id) ?? ghostLaid?.boxes.get(id);
      return box ? [{ id, box }] : [];
    });
    const touched = laidOut(presence.nodes);
    return touched.length ? touched : laidOut(presence.around);
  }, [presence, laid, ghostLaid]);
  const presenceBoxes = useMemo(() => presenceNodes.map((n) => n.box), [presenceNodes]);
  const [follow, setFollow] = useState(false);
  const paused = !!ref.data?.settings?.persona_paused;
  const presenceKey = presenceBoxes.map((b) => `${b.x},${b.y}`).join(";");
  useEffect(() => {
    if (!follow || !presenceBoxes.length || !viewport.known) return;
    const x0 = Math.min(...presenceBoxes.map((b) => b.x)), y0 = Math.min(...presenceBoxes.map((b) => b.y));
    const x1 = Math.max(...presenceBoxes.map((b) => b.x + b.w)), y1 = Math.max(...presenceBoxes.map((b) => b.y + b.h));
    // Following means the camera tracks an external thing (the persona's turn).
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setCamera((c) => ({ ...c, x: viewport.w / 2 - ((x0 + x1) / 2) * c.z, y: viewport.h / 2 - ((y0 + y1) / 2) * c.z }));
    // eslint-disable-next-line react-hooks/exhaustive-deps -- follows when the nodes it names move
  }, [follow, presenceKey, viewport.known]);

  // A change picked in the review: its page, and the camera moves there when it is off screen.
  const focusChange = (c: Change) => {
    review?.setFocus(c.i);
    if (c.page) setPageId(c.page);
    const b = c.box;
    if (!b || !camera) return;
    const sx = b.x * camera.z + camera.x, sy = b.y * camera.z + camera.y;
    if (c.page === page?.id && sx >= 0 && sy >= 0 && sx + b.w * camera.z <= viewport.w && sy + b.h * camera.z <= viewport.h) return;
    setCamera((cam) => ({ ...cam, x: viewport.w / 2 - (b.x + b.w / 2) * cam.z, y: viewport.h / 2 - (b.y + b.h / 2) * cam.z }));
  };
  /** Done: saves what is unsaved first, so the accepted ops land on it; the version that comes back merges into anything typed meanwhile. */
  const finishReview = async () => {
    if (!review?.body) return;
    setResolving(true);
    setResolveError(undefined);
    try {
      await flush();
      if (conflicted.current) throw new Error("Choose between your version and the latest first.");
      await resolve.mutateAsync({ proposalId: review.proposal.id, decisions: review.body.decisions });
      // The last suggestion ends the review, so a later one waits behind its chat card instead of taking over the dock.
      if ((proposals?.length ?? 0) <= 1) setReviewing(false);
      setSelected([]);
      setMode("diff");
    } catch (e) {
      setResolveError(errorText(e));
    } finally {
      setResolving(false);
    }
  };
  // A design started from a description or a ticket key asks its persona to draft it, once.
  const brief = search.get("brief");
  const briefSent = useRef(false);
  useEffect(() => {
    if (!brief || !chatId || !doc || briefSent.current) return;
    briefSent.current = true;
    router.replace(`/apps/designs/${id}`);
    void send.mutateAsync({ body: `Design this: ${brief}` }).catch((e) => setNotice(`Couldn’t ask ${persona} to draft it: ${errorText(e)}`));
  }, [brief, chatId, doc, id, persona, router, send]);

  const [tab, setTab] = useState<"Design" | "Prototype" | "Inspect">("Design");
  /** Present mode plays the saved design, so unsaved edits are saved first. */
  const present = async (frame?: string) => {
    try {
      await flush();
    } catch {
      // The save banner explains; Present shows the last saved version.
    }
    const q = new URLSearchParams();
    if (frame) q.set("start", frame);
    else if (selected.length === 1) q.set("start", selected[0]);
    if (page) q.set("page", page.id);
    router.push(`/present/designs/${id}?${q}`);
  };
  /** Export draws the saved design (PNG comes from the server), so unsaved edits are saved first. */
  const exportCurrent = async (): Promise<Design> => {
    await flush();
    const d = docRef.current;
    if (!d) throw new Error("the design hasn’t loaded");
    if (W.isDirty(d)) throw new Error("your latest edits couldn’t be saved first, so the export would miss them");
    return d.saved.design;
  };
  const title = ref.data?.title ?? "Design";
  const fetchError = ref.error ?? head.error;
  const selectionLabel = design && selected.length === 1 ? find(design, selected[0])?.node : undefined;

  // ---- The dock (full editor only): Review opens from the header's Review pill; Chat is unread while hidden.
  // Each review that starts (the pill, ?review=1 once suggestions load) brings the Review tab up.
  const [showReview, setShowReview] = useState(0);
  const [reviewShown, setReviewShown] = useState(false);
  if (reviewing !== reviewShown) {
    setReviewShown(reviewing);
    if (reviewing) setShowReview((n) => n + 1);
  }
  /** The pill's Review: starts the review, or brings its tab back up if it is already going. */
  const startReview = () => {
    if (reviewing) setShowReview((n) => n + 1);
    else setReviewing(true);
  };
  const [dock, setDock] = useState<DockState>();
  const chatShowing = !dock || (dock.open && !dock.hidden && dock.tab === "chat");
  const lastReply = chat?.last_message_at;
  const [seenReply, setSeenReply] = useState<string>();
  // The reply that was there on load, or that arrived while Chat showed, counts as read.
  if (lastReply && seenReply !== lastReply && (chatShowing || seenReply === undefined)) setSeenReply(lastReply);
  const unread = !chatShowing && !!lastReply && !!seenReply && lastReply !== seenReply && !running;
  const direct = !!ref.data?.settings?.direct_edit;
  const proposalCount = proposals?.length ?? 0;
  const suggestions = `${proposalCount} ${proposalCount === 1 ? "suggestion" : "suggestions"}`;
  const pending = proposals?.[0];
  const pendingPages = useMemo(() => (design && pending ? suggestionPages(design, pending) : []), [design, pending]);
  const look = personaLook(chat?.speaker ?? chat?.persona);
  const rename = useRenameDesign();
  const duplicate = useDuplicateDesign();
  const [renaming, setRenaming] = useState(false);
  const commitRename = (v: string) => {
    setRenaming(false);
    if (v.trim() && v.trim() !== title) rename.mutate({ id, title: v.trim() });
  };

  const failed = fetchError || loadError ? (
    <div className="mx-auto w-full max-w-[720px] p-6">
      <Banner tone="blocked" title="Couldn’t open this design" actions={<Button onClick={() => router.push("/knowledge")}>Back to Knowledge</Button>}>
        {loadError ?? (fetchError instanceof ApiError && fetchError.status === 404 ? "It may have been deleted, or it belongs to someone else." : errorText(fetchError))}
      </Banner>
    </div>
  ) : null;

  // The canvas's status, most important first: a conflict to settle, a failed save, an archived chat, an
  // image notice, paused edits, an arrived version, the persona at work.
  const status = conflict ? (
    <Banner
      tone="blocked"
      title="This design changed while you were editing"
      actions={
        <>
          <Button
            variant="secondary"
            onClick={() => {
              conflicted.current = false;
              setDoc(W.takeTheirs(conflict.seq, conflict.theirs));
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
              setDoc(W.keepMine(docRef.current!, conflict.seq, conflict.theirs));
              setConflict(null);
              void flush().catch(() => undefined);
            }}
          >
            Keep mine
          </Button>
        </>
      }
    >
      You and {persona} both changed {conflict.layers.slice(0, 3).join(", ")}
      {conflict.layers.length > 3 ? ` and ${conflict.layers.length - 3} more` : ""}. Nothing is saved until you choose: Keep mine saves your version over theirs (theirs stays in the version history), or use the latest version and drop your unsaved edits.
    </Banner>
  ) : saveState.s === "error" ? (
    <Banner tone="blocked" title="Couldn’t save your changes" actions={<Button onClick={() => void flush().catch(() => undefined)}>Retry now</Button>}>{saveState.message} Your edits are kept in this tab; don’t close it yet.</Banner>
  ) : chat?.archived ? (
    <Banner tone="human" title="This design’s chat is archived">Restore the chat to edit the design.</Banner>
  ) : notice || uploading ? (
    <p role={notice ? "alert" : "status"} className={cx("pointer-events-auto self-start rounded-md bg-surface px-2 py-1 text-12 shadow", notice ? "text-pill-blocked-fg" : "text-fg-secondary")}>{notice ?? "Uploading image…"}</p>
  ) : paused ? (
    <div role="status" data-testid="persona-paused" className="pointer-events-auto flex items-center gap-2 self-start rounded-full border border-border-float bg-surface-raised px-3 py-1 text-13 text-fg-secondary shadow-[var(--shadow-float)]">
      {persona}’s edits are paused
      <Button variant="ghost" className="h-[22px] px-1.5 text-12" disabled={settings.isPending} onClick={() => settings.mutate({ persona_paused: false })}>Resume</Button>
    </div>
  ) : arrival && !reviewing ? (
    <div role="status" data-testid="design-arrival" className="pointer-events-auto flex items-center gap-2 self-start rounded-md bg-surface-raised px-3 py-1.5 text-13 text-fg shadow-[var(--shadow-float)]">
      {arrival.text}
      <Button variant="ghost" className="h-[22px] px-1.5 text-12 text-accent" onClick={() => (travel(true), setArrival(undefined))}>Undo</Button>
      <Button variant="ghost" className="h-[22px] px-1.5 text-12" aria-label="Dismiss" onClick={() => setArrival(undefined)}>✕</Button>
    </div>
  ) : presence ? (
    <div role="status" data-testid="persona-chip" className="pointer-events-auto flex items-center gap-2 self-start rounded-full border border-[#3FC1B0] bg-surface-raised py-1 pl-1 pr-2 text-13 text-fg shadow-[var(--shadow-float)]">
      <span aria-hidden className="grid size-5 place-items-center rounded-full bg-[#3FC1B024] text-10 font-bold text-[#3FC1B0]">{persona.slice(0, 1).toUpperCase()}</span>
      {persona} is editing
      <Button variant="ghost" className="h-[22px] px-1.5 text-12" aria-pressed={follow} onClick={() => setFollow((f) => !f)}>Follow</Button>
      <Button variant="ghost" className="h-[22px] px-1.5 text-12" disabled={settings.isPending} onClick={() => settings.mutate({ persona_paused: true })}>Pause</Button>
    </div>
  ) : null;

  const canvas = design && shown && page && laid && lay ? (
    <main className="relative flex min-h-0 min-w-0 flex-1 flex-col">
      {/* One status area: the most important message only. While reviewing it moves to the bottom, so only the review pill sits over the frame. */}
      {status && (
        <div data-testid="design-status" className={cx("absolute left-3 z-10 flex max-w-[min(640px,calc(100%-24px))] flex-col", reviewing ? "bottom-20" : "top-3")}>
          {status}
        </div>
      )}
      {reviewing && review && (
        <div className="pointer-events-none absolute inset-x-3 top-3 z-10 flex justify-center">
          <ReviewPill review={review} mode={mode} onMode={setMode} onStep={(dir) => { const c = stepChange(review, dir); if (c) focusChange(c); }} onClose={() => setReviewing(false)} busy={resolving} />
        </div>
      )}
      <DesignCanvas
        design={shown}
        page={page}
        laid={laid}
        selected={selected}
        onSelect={setSelected}
        tool={tool}
        onTool={setTool}
        readOnly={readOnly}
        assetUrl={assetUrl}
        camera={camera ?? HIDDEN_CAMERA}
        onCamera={setCamera}
        onEdit={apply}
        editing={editing}
        onEditing={setEditing}
        onViewport={(w, h) => setViewport({ w, h, known: true })}
        wires={tab === "Prototype"}
      />
      {ghosts && ghostLaid && laid && <GhostLayer ghosts={ghosts} now={laid} laid={ghostLaid} page={page.id} camera={camera ?? HIDDEN_CAMERA} assetUrl={assetUrl} />}
      {reviewing && review && <ReviewOverlay review={review} mode={mode} page={page.id} camera={camera ?? HIDDEN_CAMERA} />}
      {presence && <PresenceLayer name={persona} nodes={presenceNodes} camera={camera ?? HIDDEN_CAMERA} busy={presence.busy} />}
      {/* Tools centred, zoom on the right: on a narrow canvas the 1fr sides give way and the tools slide left of the zoom instead of under it. */}
      <div className="pointer-events-none absolute inset-x-4 bottom-4 z-10 grid grid-cols-[1fr_auto_1fr] items-end gap-2">
        <div role="toolbar" aria-label="Tools" className="pointer-events-auto col-start-2 flex items-center gap-0.5 rounded-xl border border-border-float bg-surface-raised p-1 shadow-[var(--shadow-float)]">
          {TOOLS.filter((t) => !beside || BESIDE_TOOLS.has(t.tool)).map((t) => (
            <button
              key={t.tool}
              type="button"
              aria-label={`${t.label} (${t.key})`}
              title={`${t.label} (${t.key})`}
              aria-pressed={t.tool !== "image" ? tool === t.tool : undefined}
              disabled={readOnly && t.tool !== "select" && t.tool !== "hand"}
              className={cx("grid size-[32px] place-items-center rounded-lg text-15 disabled:opacity-40", tool === t.tool ? "bg-accent text-fg-on-accent" : "text-fg-2 hover:bg-hover")}
              onClick={() => (t.tool === "image" ? fileInput.current?.click() : setTool(t.tool))}
            >
              {t.glyph}
            </button>
          ))}
          {beside && (
            <>
              <span aria-hidden className="mx-1 h-5 w-px bg-border" />
              <button
                type="button"
                aria-pressed={paused}
                data-testid="design-pause"
                disabled={settings.isPending || !ref.data}
                title={paused ? `Let ${persona} change this design again` : `Stop ${persona}’s changes to this design from applying or being suggested`}
                className={cx("flex h-[32px] items-center gap-1.5 rounded-lg px-3 text-13 font-medium hover:bg-hover disabled:opacity-50", paused ? "text-accent" : "text-fg-secondary")}
                onClick={() => settings.mutate({ persona_paused: !paused })}
              >
                {paused ? "Resume" : "Pause"}
              </button>
            </>
          )}
        </div>
        <div className="pointer-events-auto col-start-3 mb-1 flex items-center gap-1 justify-self-end rounded-lg border border-border-float bg-surface-raised px-1 py-0.5 text-12 text-fg-secondary shadow-[var(--shadow-float)]">
          <button type="button" aria-label="Zoom out" className="grid size-6 place-items-center rounded hover:bg-hover" onClick={() => zoomBy(0.8)}>−</button>
          <button type="button" aria-label="Zoom to fit (⇧1)" data-testid="design-zoom" className="min-w-[44px] rounded px-1 hover:bg-hover" onClick={zoomToFit}>
            {Math.round((camera?.z ?? 1) * 100)}%
          </button>
          <button type="button" aria-label="Zoom in" className="grid size-6 place-items-center rounded hover:bg-hover" onClick={() => zoomBy(1.25)}>+</button>
        </div>
      </div>
      <input ref={fileInput} type="file" accept="image/png,image/jpeg,image/*" className="hidden" aria-label="Add an image to the design" data-testid="design-image-input" onChange={(e) => {
        const f = e.target.files?.[0];
        e.target.value = "";
        if (f) void onImage(f);
      }} />
    </main>
  ) : null;

  if (beside) {
    return (
      <div ref={root} data-design-beside={id} className="flex h-full min-h-0 flex-col">
        <div className="flex min-h-[52px] items-center gap-2.5 border-b border-border-subtle px-4">
          <Icon name="designs" size={16} className="flex-none text-accent" />
          <h2 className="min-w-0 truncate text-14 font-semibold text-fg">{title}</h2>
          <span className="flex-none truncate text-12 text-fg-tertiary">Design{page ? ` · ${page.name}` : ""}{reviewing ? " · Reviewing" : ""}</span>
          <span className="flex-1" />
          {presence && <span title={`${persona} is working on it`} aria-label={`${persona} is working on it`} className="grid size-5 flex-none place-items-center rounded-full border border-[#3FC1B0] bg-[#3FC1B024] text-10 font-bold text-[#3FC1B0]">{persona.slice(0, 1).toUpperCase()}</span>}
          {doc && <span data-testid="design-save-state" title={saveState.message} className={cx("flex-none text-12", saveState.s === "error" || saveState.s === "conflict" ? "text-pill-blocked-fg" : "text-fg-tertiary")}>{SAVE_LABEL[saveState.s]}</span>}
          {proposalCount > 0 && !reviewing && (
            // Compact: the panel sheet's bottom bar has the Review.
            <Button variant="approve" className="max-md:hidden" title={`Review ${suggestions} here`} onClick={() => setReviewing(true)}>
              Review {proposalCount}
            </Button>
          )}
          <Button variant="secondary" onClick={() => void flush().catch(() => undefined).then(() => router.push(`/apps/designs/${id}${reviewing ? "?review=1" : ""}`))}>Open in Designs</Button>
          <button type="button" aria-label="Close the design" onClick={beside.onClose} className="grid size-7 flex-none place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg">
            <Icon name="x" size={14} />
          </button>
        </div>
        {failed ?? (canvas ? (
          <div className="relative flex min-h-0 flex-1 max-md:flex-col">
            {canvas}
            {/* The same review as in Designs (docs/design/designs-review.svg): the canvas with its pill, the changes beside it. */}
            {reviewing && review && shown && (
              <aside aria-label="Changes" data-testid="beside-review" className="flex min-h-0 flex-none flex-col border-border-subtle bg-surface max-md:max-h-[50%] max-md:border-t md:w-[304px] md:border-l">
                <ReviewPanel review={review} design={shown} chatId={chatId} canvasId={id} seq={doc?.saved.seq ?? 0} persona={persona} error={resolveError} busy={resolving} onFocus={focusChange} onDone={() => void finishReview()} />
              </aside>
            )}
          </div>
        ) : (
          <div aria-busy="true" className="flex min-h-0 flex-1 gap-3 p-3">
            <Skeleton className="flex-1" />
          </div>
        ))}
      </div>
    );
  }

  const saveBad = saveState.s === "error" || saveState.s === "conflict";
  const header: EditorHeader = {
    back: { href: "/knowledge", label: "Knowledge" },
    name: title,
    title: renaming ? (
      <input
        autoFocus
        aria-label="Design title"
        maxLength={200}
        defaultValue={title}
        className="h-[26px] w-[240px] rounded-md border border-accent bg-surface px-2 text-14 font-semibold text-fg outline-none"
        onBlur={(e) => commitRename(e.currentTarget.value)}
        onKeyDown={(e) => {
          if (e.key === "Enter") commitRename(e.currentTarget.value);
          else if (e.key === "Escape") setRenaming(false);
        }}
      />
    ) : (
      title
    ),
    titleMenu: ref.data && !renaming && (
      <DropdownMenu.Root>
        <DropdownMenu.Trigger asChild>
          <button type="button" aria-label="Design menu" className="grid size-6 place-items-center rounded-md text-fg-tertiary hover:bg-hover hover:text-fg">▾</button>
        </DropdownMenu.Trigger>
        <DropdownMenu.Portal>
          <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "z-50 w-44")}>
            <DropdownMenu.Item className={menuItem} onSelect={() => setRenaming(true)}>Rename</DropdownMenu.Item>
            <DropdownMenu.Item className={menuItem} disabled={duplicate.isPending} onSelect={() => duplicate.mutate(id, { onSuccess: (d) => router.push(`/apps/designs/${d.id}`) })}>Duplicate</DropdownMenu.Item>
          </DropdownMenu.Content>
        </DropdownMenu.Portal>
      </DropdownMenu.Root>
    ),
    // What waits on the design sits with the design, beside its save state, not in the chat.
    status: pending && (
      <SuggestionsPill
        changes={pending.ops.length}
        pages={pendingPages}
        more={proposalCount - 1}
        onReview={startReview}
      />
    ),
    saveState: doc && (
      <span data-testid="design-save-state" title={saveState.message} className={cx("flex items-center gap-1.5", saveBad && "text-pill-blocked-fg")}>
        <span aria-hidden className={cx("size-1.5 rounded-full", saveBad ? "bg-pill-blocked-fg" : saveState.s === "saved" ? "bg-state-done" : "bg-fg-tertiary")} />
        {SAVE_LABEL[saveState.s]} · v{doc.saved.seq}
        {saveState.s === "error" && (
          <button type="button" className="text-accent hover:underline" onClick={() => void flush().catch(() => undefined)}>
            Retry
          </button>
        )}
      </span>
    ),
    presence: presence && (
      <span className="flex items-center gap-1.5 text-12 text-fg-tertiary" title={`${persona} is working on it`}>
        <PersonaAvatar persona={look} size={22} className="ring-2 ring-[#3FC1B0]" />
        editing
      </span>
    ),
    actions: ref.data
      ? [
          <Button key="present" variant="secondary" disabled={!design} onClick={() => void present()} title="Play the prototype from the selected frame">
            ▶ Present
          </Button>,
          <ExportMenu key="share" trigger="Share" id={id} title={title} design={design} pageId={page?.id} selected={selected} current={exportCurrent} />,
        ]
      : undefined,
    overflow: ref.data && (
      <Popover.Root>
        <Popover.Trigger asChild>
          <button type="button" aria-label="More" className="relative grid size-7 flex-none place-items-center rounded-md border border-border text-fg-secondary hover:bg-hover hover:text-fg">
            ⋯{design && tokensChanged(design) && <span aria-hidden className="absolute -right-1 -top-1 size-2 rounded-full bg-state-human" />}
          </button>
        </Popover.Trigger>
        <Popover.Portal>
          <Popover.Content align="end" sideOffset={6} aria-label="More" className={cx(floatPanel, "z-50 flex w-[260px] flex-col gap-2 p-3 text-13")}>
            <span className="text-11 font-medium uppercase tracking-wide text-fg-tertiary">Design tokens</span>
            {design && tokensChanged(design) ? <TokensSyncBadge design={design} readOnly={readOnly} onEdit={apply} /> : <span className="text-fg-secondary">In sync with tokens.css</span>}
          </Popover.Content>
        </Popover.Portal>
      </Popover.Root>
    ),
  };

  const loading = <Skeleton className="m-3 flex-1" />;
  // How the persona's edits land, in the chat's one header row rather than a bar of its own.
  const editMode = (
    <DropdownMenu.Root>
      <DropdownMenu.Trigger asChild>
        <button
          type="button"
          data-testid="direct-edit"
          disabled={!ref.data || settings.isPending}
          title={`Suggests: ${persona}’s edits wait as suggestions you review. Edits directly: they apply at once, and Undo reverts them.`}
          aria-label={`${persona} ${direct ? "edits directly" : "suggests changes"}`}
          className="flex h-[26px] flex-none items-center gap-1 rounded-full border border-border bg-surface-raised px-2.5 text-12 text-fg hover:bg-hover disabled:opacity-50"
        >
          {direct ? "Direct" : "Suggests"} <span aria-hidden className="text-fg-tertiary">▾</span>
        </button>
      </DropdownMenu.Trigger>
      <DropdownMenu.Portal>
        <DropdownMenu.Content align="start" sideOffset={6} className={cx(floatPanel, "z-50 w-64")}>
          <DropdownMenu.RadioGroup value={direct ? "direct" : "suggest"} onValueChange={(v) => settings.mutate({ direct_edit: v === "direct" })}>
            <DropdownMenu.RadioItem value="suggest" className={cx(menuItem, "flex-col items-start")}>
              <span>{direct ? "" : "✓ "}Suggests changes</span>
              <span className="text-11 text-fg-tertiary">Edits wait as suggestions you review.</span>
            </DropdownMenu.RadioItem>
            <DropdownMenu.RadioItem value="direct" className={cx(menuItem, "flex-col items-start")}>
              <span>{direct ? "✓ " : ""}Edits directly</span>
              <span className="text-11 text-fg-tertiary">Edits apply at once; Undo reverts them.</span>
            </DropdownMenu.RadioItem>
          </DropdownMenu.RadioGroup>
        </DropdownMenu.Content>
      </DropdownMenu.Portal>
    </DropdownMenu.Root>
  );
  const chatPanel = (
    <div data-design-chat className="flex min-h-0 flex-1 flex-col">
      {chatId && <Conversation key={chatId} id={chatId} docked actions={editMode} onNew={() => router.push("/knowledge")} />}
    </div>
  );
  const dockTabs: DockTab[] = [
    { id: "chat", label: "Chat", icon: "msg", avatar: <PersonaAvatar persona={look} size={16} />, busy: !!presence, unread, content: chatPanel },
  ];
  if (proposalCount || reviewing)
    dockTabs.push({
      id: "review",
      label: "Review",
      icon: "check",
      badge: <span className="rounded-full bg-pill-review-bg px-1.5 text-11 text-pill-review-fg">{proposalCount}</span>,
      content:
        reviewing && review && shown ? (
          <ReviewPanel review={review} design={shown} chatId={chatId} canvasId={id} seq={doc?.saved.seq ?? 0} persona={persona} error={resolveError} busy={resolving} onFocus={focusChange} onDone={() => void finishReview()} />
        ) : (
          <div className="flex flex-col items-start gap-3 p-4 text-13 text-fg-secondary">
            <p>{persona} suggested {suggestions}. Nothing changes until you accept.</p>
            <Button variant="approve" onClick={() => setReviewing(true)}>Start review</Button>
          </div>
        ),
    });
  dockTabs.push({
    id: "design",
    label: "Design",
    icon: "designs",
    content: design && lay ? (
      <>
        <div role="tablist" aria-label="Inspector" className="flex flex-none gap-4 border-b border-border-subtle px-4 pt-3">
          {(["Design", "Prototype", "Inspect"] as const).map((t) => (
            <button key={t} type="button" role="tab" aria-selected={t === tab} onClick={() => setTab(t)} className={cx("-mb-px border-b-2 pb-2 text-13", t === tab ? "border-accent font-medium text-fg" : "border-transparent text-fg-tertiary hover:text-fg")}>
              {t}
            </button>
          ))}
        </div>
        <div className="min-h-0 flex-1 overflow-y-auto" role="tabpanel" aria-label={selectionLabel ? `${tab}: ${labelOf(selectionLabel)}` : tab}>
          {tab === "Design" ? (
            <Inspector design={design} selected={selected} lay={lay} onEdit={apply} readOnly={readOnly} onGroup={group} onRemove={removeSelected} onSelect={setSelected} />
          ) : tab === "Inspect" ? (
            <InspectPanel design={design} selected={selected} />
          ) : (
            <PrototypePanel design={design} selected={selected} readOnly={readOnly} onEdit={apply} onSelect={setSelected} onPresent={(f) => void present(f)} />
          )}
        </div>
      </>
    ) : (
      loading
    ),
  });

  return (
    <EditorLayout
      app="designs"
      header={header}
      show={{ tab: "review", n: showReview }}
      onDockChange={setDock}
      left={
        shown && page ? (
          <nav aria-label="Pages and layers" className="flex min-h-0 flex-1 flex-col">
            <LayersPanel
              design={shown}
              page={page}
              onPage={(pid) => {
                setPageId(pid);
                setSelected([]);
                setEditing(undefined);
              }}
              selected={selected}
              onSelect={setSelected}
              onEdit={apply}
              readOnly={readOnly}
            />
          </nav>
        ) : (
          !failed && loading
        )
      }
      main={failed ?? canvas ?? <div aria-busy="true" className="flex min-h-0 flex-1 p-3"><Skeleton className="flex-1" /></div>}
      dock={dockTabs}
    />
  );
}

/** The editor bar's "Review N": the persona's waiting suggestions, one click from review. Nothing changes until they're accepted. */
function SuggestionsPill({ changes, pages, more, onReview }: { changes: number; pages: string[]; more: number; onReview: () => void }) {
  const what = `${changes} suggested ${changes === 1 ? "change" : "changes"}`;
  const detail = [what + (pages.length ? ` · ${pages.join(", ")}` : ""), "Nothing changes until you accept.", more > 0 ? `${more} more waiting after this.` : ""].filter(Boolean).join(" ");
  return (
    <button type="button" data-testid="suggestion-card" aria-label={`Review ${what}`} title={detail} onClick={onReview}
      className="flex h-[26px] flex-none items-center gap-1.5 rounded-full bg-pill-review-bg px-2.5 text-12 font-medium text-pill-review-fg hover:brightness-95">
      <Icon name="check" size={12} />
      Review
      <span className="rounded-full bg-surface/60 px-1.5 text-11 tabular-nums">{changes}</span>
    </button>
  );
}
