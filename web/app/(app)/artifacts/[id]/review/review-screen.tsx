"use client";

import { useQuery } from "@tanstack/react-query";
import { useRouter, useSearchParams } from "next/navigation";
import { useCallback, useEffect, useId, useLayoutEffect, useMemo, useRef, useState, type ComponentProps, type KeyboardEvent, type ReactNode } from "react";
import { contentUrl, type Artifact } from "@/lib/api/client";
import { useArtifact, useReviewMockup } from "@/lib/api/hooks";
import { cx } from "@/lib/cx";
import { svgDataUrl } from "@/lib/mockup";
import { actualView, fitView, panBy, PAN_STEP, svgSize, zoomAt, ZOOM_STEP, type Fraction, type Size, type View } from "@/lib/mockup-review";
import { ButtonLink } from "@/components/ui/button";
import { Banner, EmptyState, Kbd, Skeleton } from "@/components/ui/primitives";
import { artifactTitle } from "@/components/domain/artifacts";
import { reviewLabel } from "@/components/domain/mockup";
import { Pane, type ChangeView, type Drawing, type Pin, type Tool } from "./review-canvas";
import { ReviewPanel, type Decision } from "./review-panel";
import { useNativeActions } from "@/lib/native-shell/use-native-actions";
import { buildReviewActions, type ReviewActionsInput } from "@/lib/native-shell/models/mockup-editor";
import { setTopBarTitle } from "@/lib/native-shell/title";

type Version = Artifact["versions"][number];
type Mode = "single" | "side" | "swipe";
/** Fit and 100% follow the viewport's size; any manual zoom or pan makes the view free. */
type Camera = { mode: "fit" | "100" } | { mode: "free"; view: View };

const MODES = [
  { value: "single", label: "Single" },
  { value: "side", label: "Side by side" },
  { value: "swipe", label: "Swipe" },
] as const;
const DEFAULT_SIZE: Size = { w: 1280, h: 800 };
const shell = "fixed inset-0 z-40 flex flex-col bg-bg text-fg";

/** SVG source of a version. The current one comes with the artifact; older ones are fetched once (versions are immutable). */
function useSource(a: Artifact, v: Version | undefined): string | undefined {
  const isCurrent = v?.id === a.current_version.id;
  const q = useQuery({
    queryKey: ["artifacts", "content", a.id, v?.id],
    enabled: !!v && !isCurrent,
    queryFn: async () => {
      const res = await fetch(contentUrl(a.id, v!.id));
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.text();
    },
    staleTime: Infinity,
  });
  return isCurrent ? (a.body_md ?? undefined) : q.data;
}

function useDrawing(a: Artifact, v: Version | undefined): Drawing | null {
  const source = useSource(a, v);
  const label = v?.label;
  return useMemo(
    () => (source && label ? { url: svgDataUrl(source), size: svgSize(source), label, alt: `${a.title} ${label}` } : null),
    [source, label, a.title],
  );
}

function VersionChip({ v, isCurrent }: { v: Version; isCurrent: boolean }) {
  return (
    <span className="flex items-center gap-1.5 rounded-full border border-border bg-surface px-2.5 py-0.5 text-12 shadow-sm">
      <span className="font-mono font-semibold">{v.label}</span>
      {isCurrent && <span className="text-fg-secondary">current</span>}
      {v.review && <span className="text-fg-secondary">· {reviewLabel(v.review.state)}</span>}
    </span>
  );
}

function ToolButton({ on, kbd, children, className, ...rest }: { on?: boolean; kbd?: string; children: ReactNode } & ComponentProps<"button">) {
  return (
    <button
      type="button"
      className={cx(
        "inline-flex h-7 items-center gap-1.5 rounded-md px-2.5 text-13 text-fg-2 hover:bg-hover disabled:cursor-not-allowed disabled:opacity-40",
        on && "bg-accent-soft text-accent",
        className,
      )}
      {...rest}
    >
      {children}
      {kbd && <Kbd className="text-10">{kbd}</Kbd>}
    </button>
  );
}

const Divider = () => <span aria-hidden="true" className="mx-1 h-5 w-px bg-border" />;

function Toolbar({ scale, cam, onZoom, onFit, onActual, tool, onTool, canPin, showPins, onShowPins }: {
  scale: number; cam: Camera["mode"]; onZoom: (factor: number) => void; onFit: () => void; onActual: () => void;
  tool: Tool; onTool: (t: Tool) => void; canPin: boolean; showPins: boolean; onShowPins: () => void;
}) {
  return (
    <div role="toolbar" aria-label="Canvas tools" className="pointer-events-auto flex items-center rounded-[10px] border border-border bg-surface p-1 shadow-[var(--shadow-float)]">
      <ToolButton aria-label="Zoom out" title="Zoom out (−)" className="px-2 text-16" onClick={() => onZoom(1 / ZOOM_STEP)}>
        −
      </ToolButton>
      <output aria-label="Zoom level" className="w-12 text-center font-mono text-12">
        {Math.round(scale * 100)}%
      </output>
      <ToolButton aria-label="Zoom in" title="Zoom in (+)" className="px-2 text-16" onClick={() => onZoom(ZOOM_STEP)}>
        +
      </ToolButton>
      <Divider />
      <ToolButton on={cam === "fit"} title="Fit (0)" onClick={onFit}>
        Fit
      </ToolButton>
      <ToolButton on={cam === "100"} title="100% (1)" onClick={onActual}>
        100%
      </ToolButton>
      <Divider />
      <ToolButton on={tool === "pan"} aria-pressed={tool === "pan"} kbd="H" onClick={() => onTool("pan")}>
        Pan
      </ToolButton>
      <ToolButton
        on={tool === "pin"}
        aria-pressed={tool === "pin"}
        kbd="C"
        disabled={!canPin}
        title={canPin ? "Click the mockup to pin a comment" : "Pins go on the current version"}
        onClick={() => onTool("pin")}
      >
        Pin
      </ToolButton>
      <Divider />
      <ToolButton onClick={onShowPins}>{showPins ? "Hide pins" : "Show pins"}</ToolButton>
    </div>
  );
}

const round4 = (n: number) => Math.round(n * 10_000) / 10_000;

const FOCUSABLE = 'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), [tabindex]:not([tabindex="-1"])';

/** Keeps Tab inside the modal workspace: it wraps from the last control to the first and back. */
function trapTab(e: KeyboardEvent<HTMLDivElement>, root: HTMLElement | null) {
  if (!root) return;
  const items = [...root.querySelectorAll<HTMLElement>(FOCUSABLE)].filter((el) => el.getClientRects().length > 0);
  if (!items.length) return;
  const first = items[0];
  const last = items[items.length - 1];
  const active = document.activeElement;
  if (e.shiftKey && (active === first || active === root)) {
    e.preventDefault();
    last.focus();
  } else if (!e.shiftKey && (active === last || !root.contains(active))) {
    e.preventDefault();
    first.focus();
  }
}

/**
 * True when this page was reached by navigating inside the app, so history.back()
 * stays in the app. history.length can't tell: a new tab may already have entries.
 */
function enteredInApp(): boolean {
  const nav = performance.getEntriesByType("navigation")[0];
  if (!nav) return false;
  const first = new URL(nav.name);
  return first.pathname + first.search !== window.location.pathname + window.location.search;
}

/** Publishes the review's header row (versions, compare, Close) and title to the Mac app's toolbar. Draws nothing. */
function NativeReviewBar({ title, input }: { title: string; input: ReviewActionsInput }) {
  useNativeActions(buildReviewActions(input));
  useEffect(() => {
    const token = Symbol("review-title");
    setTopBarTitle(token, { title, subtitle: "Review" });
    return () => setTopBarTitle(token, null);
  }, [title]);
  return null;
}

function Workspace({ a, initialVersion, initialTicket }: { a: Artifact; initialVersion: string | null; initialTicket: string | null }) {
  const router = useRouter();
  const titleId = useId();
  const hintId = useId();
  const rootRef = useRef<HTMLDivElement>(null);
  const boxRef = useRef<HTMLDivElement>(null);

  const versions = a.versions; // newest first
  const current = a.current_version;
  const [primaryId, setPrimaryId] = useState(() => (versions.some((v) => v.id === initialVersion) ? initialVersion! : current.id));
  const primary = versions.find((v) => v.id === primaryId) ?? current;
  const editable = primary.id === current.id;
  const others = versions.filter((v) => v.id !== primary.id);

  const [mode, setMode] = useState<Mode>("single");
  const [withId, setWithId] = useState<string | null>(null);
  // Compare against the chosen version, else the one just before the reviewed version, else the newest other.
  const compare = mode === "single" ? undefined : (others.find((v) => v.id === withId) ?? others.find((v) => v.seq < primary.seq) ?? others[0]);
  const shown: Mode = compare ? mode : "single";

  const [tool, setTool] = useState<Tool>("pan");
  const [showPins, setShowPins] = useState(true);
  const [swipe, setSwipe] = useState(0.5);
  // This review's new pins. A decision already on the current version keeps its own pins and note; they show
  // (in grey) until the reviewer starts pinning, and a new decision replaces them.
  const [drafts, setDrafts] = useState<Pin[]>([]);
  const [composing, setComposing] = useState<Fraction | null>(null);
  const [note, setNote] = useState("");
  const [activePin, setActivePin] = useState<number | null>(null);
  const [saved, setSaved] = useState<Decision | null>(null);
  const ticketKeys = useMemo(() => [...new Set([...(initialTicket ? [initialTicket] : []), ...a.tickets.map((t) => t.key)])], [initialTicket, a.tickets]);
  const [ticketKey, setTicketKey] = useState<string | null>(() => ticketKeys[0] ?? null);

  const primaryDrawing = useDrawing(a, primary);
  const compareDrawing = useDrawing(a, compare);

  // The canvas area's size; side by side splits it into two panes.
  const [box, setBox] = useState<Size>({ w: 0, h: 0 });
  useLayoutEffect(() => {
    const el = boxRef.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => setBox({ w: e.contentRect.width, h: e.contentRect.height }));
    ro.observe(el);
    return () => ro.disconnect();
  }, []);
  const pane = useMemo<Size>(() => (shown === "side" ? { w: Math.max(0, (box.w - 1) / 2), h: box.h } : box), [shown, box]);
  const size = useMemo(() => primaryDrawing?.size ?? compareDrawing?.size ?? DEFAULT_SIZE, [primaryDrawing, compareDrawing]);

  const [cam, setCam] = useState<Camera>({ mode: "fit" });
  const resolve = useCallback((c: Camera): View => (c.mode === "free" ? c.view : c.mode === "fit" ? fitView(size, pane) : actualView(size, pane)), [size, pane]);
  const view = resolve(cam);
  const change: ChangeView = useCallback((fn) => setCam((c) => ({ mode: "free", view: fn(resolve(c)) })), [resolve]);
  const zoomBy = (factor: number) => change((v) => zoomAt(v, factor, pane.w / 2, pane.h / 2));

  const canPin = editable && !!primaryDrawing;
  const activeTool: Tool = canPin ? tool : "pan";
  const savedPins = primary.review && primary.review.state !== "pending" ? primary.review.pins : [];
  const showSaved = !editable || (drafts.length === 0 && !composing && savedPins.length > 0);
  const primaryPins = showSaved ? savedPins : drafts;

  const mut = useReviewMockup(a.id);
  const decide = (decision: Decision) => {
    setSaved(null);
    mut.mutate(
      { versionId: current.id, decision, note: note.trim() || undefined, pins: drafts },
      {
        onSuccess: () => {
          // The pins and note are now the version's saved review.
          setNote("");
          setDrafts([]);
          setSaved(decision);
        },
      },
    );
  };

  const pickVersion = (id: string) => {
    setPrimaryId(id);
    setComposing(null);
    setActivePin(null);
    setCam({ mode: "fit" });
    if (withId === id) setWithId(null);
  };

  // Back to where the person came from; opened directly (new tab, reload), to the ticket or the mockup page.
  const close = useCallback(() => {
    if (enteredInApp()) router.back();
    else router.push(ticketKey ? `/tickets/${ticketKey}` : `/artifacts/${a.id}`);
  }, [router, ticketKey, a.id]);

  // In the Mac app the header row is the window's toolbar (versions, compare, Close) and title; NativeReviewBar publishes them.
  const nativeTitle = artifactTitle(a);

  // Take focus so the canvas shortcuts work straight away.
  useEffect(() => rootRef.current?.focus(), []);

  const onKeyDown = (e: KeyboardEvent<HTMLDivElement>) => {
    if (e.key === "Tab" && !e.defaultPrevented) return trapTab(e, rootRef.current);
    if (e.defaultPrevented || e.metaKey || e.ctrlKey || e.altKey) return;
    const t = e.target as HTMLElement;
    if (t.isContentEditable || ["INPUT", "TEXTAREA", "SELECT"].includes(t.tagName) || t.closest('[role="menu"]')) return;
    const step = PAN_STEP * (e.shiftKey ? 5 : 1);
    const i = versions.findIndex((v) => v.id === primary.id);
    switch (e.key) {
      case "+":
      case "=":
        zoomBy(ZOOM_STEP);
        break;
      case "-":
      case "_":
        zoomBy(1 / ZOOM_STEP);
        break;
      case "0":
        setCam({ mode: "fit" });
        break;
      case "1":
        setCam({ mode: "100" });
        break;
      case "ArrowLeft":
        change((v) => panBy(v, step, 0));
        break;
      case "ArrowRight":
        change((v) => panBy(v, -step, 0));
        break;
      case "ArrowUp":
        change((v) => panBy(v, 0, step));
        break;
      case "ArrowDown":
        change((v) => panBy(v, 0, -step));
        break;
      case "c":
      case "C":
        if (!canPin) return;
        setTool("pin");
        break;
      case "h":
      case "H":
        setTool("pan");
        break;
      case "[":
        if (i >= versions.length - 1) return;
        pickVersion(versions[i + 1].id);
        break;
      case "]":
        if (i <= 0) return;
        pickVersion(versions[i - 1].id);
        break;
      case "s":
      case "S":
        if (versions.length < 2) return;
        setMode((m) => MODES[(MODES.findIndex((x) => x.value === m) + 1) % MODES.length].value);
        break;
      case "Escape":
        if (composing) setComposing(null);
        else close();
        break;
      default:
        return;
    }
    e.preventDefault();
  };

  const primaryPane = (
    <Pane
      label={`${primary.label} canvas`}
      box={pane}
      view={view}
      change={change}
      drawing={primaryDrawing}
      swipeWith={shown === "swipe" ? compareDrawing : undefined}
      swipe={shown === "swipe" ? swipe : undefined}
      onSwipe={setSwipe}
      pins={primaryPins}
      tone={showSaved ? "saved" : "draft"}
      showPins={showPins}
      tool={activeTool}
      onPlace={canPin ? setComposing : undefined}
      composing={editable ? composing : null}
      onCompose={(text) => {
        if (composing) setDrafts((d) => [...d, { x: round4(composing.x), y: round4(composing.y), text }]);
        setComposing(null);
      }}
      onCancelCompose={() => setComposing(null)}
      activePin={activePin}
      onHoverPin={setActivePin}
      describedBy={hintId}
      chip={shown === "side" ? <VersionChip v={primary} isCurrent={editable} /> : undefined}
    />
  );

  return (
    <div ref={rootRef} role="dialog" aria-modal="true" aria-labelledby={titleId} tabIndex={-1} onKeyDown={onKeyDown} className={cx(shell, "outline-none")}>
      <h1 id={titleId} className="sr-only">{nativeTitle}</h1>
      <NativeReviewBar
        title={nativeTitle}
        input={{
          versions,
          primaryId: primary.id,
          currentId: current.id,
          pickVersion,
          modes: versions.length > 1 ? [...MODES] : undefined,
          mode: shown,
          setMode,
          others: compare ? others : undefined,
          withId: compare?.id,
          setWith: setWithId,
          ticket: ticketKey ? { key: ticketKey, run: () => router.push(`/tickets/${ticketKey}`) } : undefined,
          close,
        }}
      />

      <div className="flex min-h-0 flex-1">
        <div className="relative flex min-w-0 flex-1 flex-col">
          <div ref={boxRef} className="flex min-h-0 flex-1">
            {box.w > 0 &&
              (shown === "side" && compare ? (
                <>
                  <Pane
                    label={`${compare.label} canvas`}
                    box={pane}
                    view={view}
                    change={change}
                    drawing={compareDrawing}
                    pins={compare.review?.pins ?? []}
                    tone="saved"
                    showPins={showPins}
                    tool="pan"
                    describedBy={hintId}
                    chip={<VersionChip v={compare} isCurrent={compare.id === current.id} />}
                  />
                  <div aria-hidden="true" className="w-px flex-none bg-border-strong" />
                  {primaryPane}
                </>
              ) : (
                primaryPane
              ))}
          </div>
          {shown === "swipe" && compare && (
            <>
              <span className="pointer-events-none absolute bottom-24 left-4 rounded-full bg-fg/85 px-2.5 py-0.5 font-mono text-12 font-semibold text-bg">{compare.label}</span>
              <span className="pointer-events-none absolute bottom-24 right-4 rounded-full bg-fg/85 px-2.5 py-0.5 font-mono text-12 font-semibold text-bg">{primary.label}</span>
            </>
          )}
          <div className="pointer-events-none absolute inset-x-0 bottom-9 flex justify-center">
            <Toolbar
              scale={view.scale}
              cam={cam.mode}
              onZoom={zoomBy}
              onFit={() => setCam({ mode: "fit" })}
              onActual={() => setCam({ mode: "100" })}
              tool={activeTool}
              onTool={setTool}
              canPin={canPin}
              showPins={showPins}
              onShowPins={() => setShowPins((s) => !s)}
            />
          </div>
          <p id={hintId} className="pointer-events-none absolute inset-x-4 bottom-2.5 truncate text-center text-11 text-fg-tertiary">
            {shown === "side"
              ? "Both panes share zoom and pan · pins go on the current version · "
              : shown === "swipe"
                ? "Drag the handle, or focus it and use ← → (Shift for 10%), Home / End · "
                : ""}
            Drag, scroll or arrow keys to pan · ⌘/Ctrl+scroll, trackpad pinch or +/− to zoom · 0 Fit · 1 100% · C pin · H pan · [ ] versions · S compare
          </p>
        </div>

        <ReviewPanel
          a={a}
          version={primary}
          editable={editable}
          pins={primaryPins}
          savedPins={showSaved}
          onRemovePin={(i) => {
            setDrafts((d) => d.filter((_, j) => j !== i));
            setActivePin(null);
          }}
          activePin={activePin}
          onHoverPin={setActivePin}
          note={note}
          onNote={setNote}
          onDecide={decide}
          deciding={mut.isPending}
          error={mut.isError ? mut.error.message : null}
          saved={saved}
          ticketKey={ticketKey}
          ticketKeys={ticketKeys}
          onTicket={setTicketKey}
          onPickVersion={pickVersion}
        />
      </div>
    </div>
  );
}

/** Full-screen review of a mockup's versions: zoom, compare, pin comments, decide. */
export function ReviewScreen({ id }: { id: string }) {
  const { data: a, isError, error } = useArtifact(id);
  const search = useSearchParams();

  if (isError) {
    const missing = "status" in error && error.status === 404;
    return (
      <div className={cx(shell, "items-center justify-center p-6")}>
        {missing ? (
          <EmptyState icon="artifacts" title="This mockup doesn't exist" actions={<ButtonLink href="/library?source=projects" variant="outline">Library</ButtonLink>}>
            It may have been removed, or the link is wrong.
          </EmptyState>
        ) : (
          <Banner tone="blocked" title="Couldn't load this mockup">
            {error.message}
          </Banner>
        )}
      </div>
    );
  }
  if (!a) {
    return (
      <div aria-busy="true" className={cx(shell, "gap-4 p-6")}>
        <Skeleton className="h-8 w-1/3" />
        <Skeleton className="flex-1" />
      </div>
    );
  }
  if (a.type !== "mockup") {
    return (
      <div className={cx(shell, "items-center justify-center p-6")}>
        <EmptyState icon="artifacts" title="Only mockups are reviewed here" actions={<ButtonLink href={`/artifacts/${a.id}`} variant="outline">Open {a.title}</ButtonLink>}>
          This artifact is a {a.type}.
        </EmptyState>
      </div>
    );
  }
  // Remount when a new version lands so drafts start from it.
  return <Workspace key={a.current_version.id} a={a} initialVersion={search.get("version")} initialTicket={search.get("ticket")} />;
}
