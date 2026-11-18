"use client";

import { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { Artifact } from "@/lib/api/client";
import { ApiError } from "@/lib/api/client";
import { useNewVersion, useReviewMockup } from "@/lib/api/hooks";
import { insertIndent, svgError, type Zoom } from "@/lib/mockup";
import { Button } from "@/components/ui/button";
import { Field, TextInput } from "@/components/ui/primitives";
import { Segmented } from "@/components/ui/controls";
import { MockupImage } from "@/components/domain/mockup";
import { MockupCanvas, useSourceHistory } from "@/components/domain/mockup-canvas";
import { ZoomControl } from "./mockup-parts";
import { confirmAction } from "@/components/ui/confirm";
import { addLeaveGuard } from "@/lib/leave-guard";

type Mode = "visual" | "source" | "split";
const MODES = [
  { value: "visual", label: "Visual" },
  { value: "source", label: "Source" },
  { value: "split", label: "Split" },
] as const;

/**
 * SVG editor with Visual (direct manipulation), Source (text + live image preview)
 * and Split modes. All of them edit the same `source` string.
 * Saving always creates a new version (pending review); "Save & approve"
 * also approves it.
 */
export function MockupEditor({ a, onDone }: { a: Artifact; onDone: () => void }) {
  const newVersion = useNewVersion(a.id);
  const review = useReviewMockup(a.id);
  const [baseline, setBaseline] = useState(a.body_md ?? "");
  const [source, setSource] = useState(baseline);
  const [preview, setPreview] = useState(baseline);
  const [note, setNote] = useState("");
  const [zoom, setZoom] = useState<Zoom>("fit");
  const [mode, setMode] = useState<Mode>(() => (svgError(baseline) ? "source" : "visual"));
  const history = useSourceHistory(source, setSource);
  const [error, setError] = useState<string | null>(null);
  const area = useRef<HTMLTextAreaElement>(null);
  const caret = useRef<number | null>(null);

  const problem = useMemo(() => svgError(source), [source]);
  const dirty = source !== baseline;
  const busy = newVersion.isPending || review.isPending;
  const canSave = !problem && dirty && !busy;

  // Debounced preview; the last well-formed source stays on screen while the markup is broken.
  useEffect(() => {
    if (problem) return;
    const id = setTimeout(() => setPreview(source), 250);
    return () => clearTimeout(id);
  }, [source, problem]);

  useLayoutEffect(() => {
    if (caret.current != null && area.current) {
      area.current.setSelectionRange(caret.current, caret.current);
      caret.current = null;
    }
  });

  useEffect(() => {
    if (!dirty) return;
    const warn = (e: BeforeUnloadEvent) => e.preventDefault();
    return addLeaveGuard(warn);
  }, [dirty]);

  async function save(approve: boolean) {
    if (!canSave) return;
    setError(null);
    const form = new FormData();
    form.set("body_md", source);
    if (note.trim()) form.set("note", note.trim());
    let saved: Artifact;
    try {
      saved = await newVersion.mutateAsync(form);
    } catch (e) {
      setError(e instanceof ApiError || e instanceof Error ? e.message : "Couldn't save the mockup.");
      return;
    }
    setBaseline(source);
    if (approve) {
      try {
        await review.mutateAsync({ versionId: saved.current_version.id, decision: "approved" });
      } catch (e) {
        setError(`Saved as ${saved.current_version.label}, but approving failed: ${e instanceof Error ? e.message : "unknown error"}`);
        return;
      }
    }
    onDone();
  }

  async function cancel() {
    if (dirty && !await confirmAction({ title: "Discard your unsaved changes to this mockup?", confirmLabel: "Discard", cancelLabel: "Keep editing" })) return;
    onDone();
  }

  const canvas = (side: boolean) => (
    <div
      className="flex min-w-0 flex-1 flex-col"
      onKeyDown={(e) => {
        if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") {
          e.preventDefault();
          void save(false);
        }
      }}
    >
    <MockupCanvas
      source={source}
      history={history}
      zoom={zoom}
      toolbarEnd={<ZoomControl value={zoom} onChange={setZoom} />}
      alt={`Visual editor for ${a.title}`}
      inspectorSide={side}
    />
    </div>
  );
  const sourcePane = (
    <div className="flex min-h-[320px] flex-col gap-2">
      <label htmlFor="mockup-source" className="text-13 font-medium text-fg-2">
        SVG source <span className="font-normal text-fg-tertiary">· Tab indents, ⌘S saves</span>
      </label>
      <textarea
        id="mockup-source"
        ref={area}
        value={source}
        spellCheck={false}
        autoCapitalize="off"
        autoCorrect="off"
        aria-invalid={!!problem}
        onChange={(e) => {
          setSource(e.target.value);
          setError(null);
        }}
        onKeyDown={(e) => {
          if (e.key === "Tab" && !e.shiftKey && !e.metaKey && !e.ctrlKey && !e.altKey) {
            e.preventDefault();
            const t = e.currentTarget;
            const r = insertIndent(t.value, t.selectionStart, t.selectionEnd);
            caret.current = r.caret;
            setSource(r.value);
          }
          if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s") {
            e.preventDefault();
            void save(false);
          }
        }}
        className="min-h-[320px] w-full flex-1 resize-none rounded-md border border-border-strong bg-surface-sunken p-3 font-mono text-13 leading-relaxed text-fg [tab-size:2] focus:border-accent focus:outline-none aria-[invalid=true]:border-pill-blocked-fg"
      />
    </div>
  );

  return (
    <div className="flex flex-1 flex-col">
      <div className="flex flex-wrap items-end gap-3 border-b border-border-subtle px-6 py-3">
        <div className="min-w-[220px] flex-1">
          <Field label="What changed" htmlFor="mockup-note">
            <TextInput id="mockup-note" value={note} onChange={(e) => setNote(e.target.value)} placeholder="Optional note for this version" />
          </Field>
        </div>
        <div className="flex flex-wrap items-center gap-2">
          <Button variant="ghost" onClick={cancel}>
            Cancel
          </Button>
          <Button variant="secondary" disabled={!canSave} onClick={() => save(false)} hint="⌘S">
            Save version
          </Button>
          <Button variant="approve" icon="check" disabled={!canSave} onClick={() => save(true)}>
            Save &amp; approve
          </Button>
        </div>
      </div>
      {(error || problem) && (
        <p role="alert" className="border-b border-border-subtle px-6 py-2 text-12 text-pill-blocked-fg">
          {error ?? problem}
        </p>
      )}
      <div className="flex items-center justify-between gap-2 px-6 pt-3">
        <Segmented small label="Editor mode" value={mode} onChange={setMode} options={MODES} />
      </div>
      {mode === "visual" && (
        <div className="flex min-h-[480px] flex-1 p-4 lg:p-6">{canvas(true)}</div>
      )}
      {mode === "source" && (
        <div className="grid min-h-[480px] flex-1 grid-cols-1 gap-4 p-4 lg:grid-cols-2 lg:p-6">
          {sourcePane}
          <div className="flex min-h-[320px] min-w-0 flex-col gap-2">
            <div className="flex items-center justify-between gap-2">
              <h2 className="text-13 font-medium text-fg-2">Preview</h2>
              <ZoomControl value={zoom} onChange={setZoom} />
            </div>
            <MockupImage source={preview} alt={`Preview of ${a.title}`} zoom={zoom} className="min-h-[320px] flex-1" />
          </div>
        </div>
      )}
      {mode === "split" && (
        <div className="grid min-h-[480px] flex-1 grid-cols-1 gap-4 p-4 lg:grid-cols-2 lg:p-6">
          {canvas(false)}
          {sourcePane}
        </div>
      )}
    </div>
  );
}
