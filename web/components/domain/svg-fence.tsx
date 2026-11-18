"use client";

import { createContext, useContext, useMemo, useState, type ReactNode } from "react";
import { useSaveLibraryDiagram } from "@/lib/api/library-hooks";
import { exportSvg, isThemedSvg, parseStepsFence, stepCount, stepFrame, svgDataUrl, svgTitle, themeSvg } from "@/lib/chat-svg";
import { cx } from "@/lib/cx";
import { useVizPalette } from "@/lib/viz-theme";
import { Button } from "@/components/ui/button";
import { Icon } from "@/components/ui/icon";
import { CodeFence } from "./code-fence";
import { usePrintMode } from "./print-mode";
import { VisualFrame } from "./visual-frame";

/** The assistant reply a fence is in; without one there's no "Save to Library". */
export const SvgFenceMessage = createContext<string | undefined>(undefined);

/** Unlike generated images, diagrams reach the Library only from here. */
function SaveToLibrary({ messageId, svg }: { messageId: string; svg: string }) {
  const save = useSaveLibraryDiagram();
  const saved = save.isSuccess && save.variables.svg === svg;
  return (
    <>
      {save.isError && <span role="alert" className="text-pill-blocked-fg">{save.error.message || "Couldn’t save."}</span>}
      <button type="button" disabled={save.isPending || saved} className="flex items-center gap-1 rounded px-1 hover:text-fg disabled:hover:text-fg-tertiary" onClick={() => save.mutate({ message_id: messageId, svg })}>
        <Icon name={saved ? "check" : "bookmark"} size={12} />
        {saved ? "Saved" : save.isPending ? "Saving…" : "Save to Library"}
      </button>
    </>
  );
}

/**
 * A diagram, in Chat or a lesson, shown through <img> so the agent's markup
 * can't script or load anything (see svgDataUrl). With captions or data-step
 * marks it becomes a step-through: one image per frame, stacked so the height
 * never jumps. A document the browser can't draw falls back to its source.
 */
export function DiagramVisual({ source, captions = [], alt, label = "SVG image", caption, code, info }: {
  source: string;
  captions?: readonly string[];
  alt?: string;
  label?: string;
  caption?: ReactNode;
  /** The fence's text, for the Code view; lessons don't have one. */
  code?: string;
  info?: string;
}) {
  const palette = useVizPalette();
  const themed = isThemedSvg(source);
  const doc = useMemo(() => (themed ? themeSvg(source, palette) : source), [themed, source, palette]);
  const count = stepCount(source, captions);
  const stepped = count > 1;
  const urls = useMemo(() => (stepped ? Array.from({ length: count }, (_, i) => svgDataUrl(stepFrame(doc, i + 1))) : [svgDataUrl(doc)]), [doc, count, stepped]);
  // On paper a step-through shows its last frame, which holds everything, with every caption.
  const printing = usePrintMode();
  const [step, setStep] = useState(printing ? count - 1 : 0);
  const at = Math.min(step, urls.length - 1);
  const [view, setView] = useState<"image" | "code">("image");
  // By URL, so an edited source gets another try.
  const [failedUrl, setFailedUrl] = useState<string>();
  const failed = failedUrl === urls[0];
  const messageId = useContext(SvgFenceMessage);
  const name = alt ?? svgTitle(source) ?? label;
  const frameAlt = stepped ? `${name}. Step ${at + 1} of ${count}${captions[at] ? `: ${captions[at]}` : ""}` : name;
  const portable = useMemo(() => exportSvg(stepped ? stepFrame(source, count) : source, palette), [source, stepped, count, palette]);

  const stage = (zoomed: boolean) => (
    <div className={cx("grid overflow-auto p-2", themed ? "bg-surface" : "bg-white")}>
      {urls.map((url, i) => (
        // a data: URL; next/image adds nothing here
        <img key={i} src={url} alt={i === at ? frameAlt : ""} aria-hidden={i === at ? undefined : true} className={cx("col-start-1 row-start-1 mx-auto block h-auto max-w-full", zoomed ? "max-h-[78vh] w-full" : "max-h-[720px]", i !== at && "invisible")} onError={() => setFailedUrl(urls[0])} />
      ))}
    </div>
  );
  const nav = stepped && printing ? (
    <ol className="list-decimal border-t border-border-row py-2 pl-8 pr-3 text-13 text-fg-2">
      {captions.map((c, i) => <li key={i}>{c}</li>)}
    </ol>
  ) : stepped && (
    <div className="flex items-center gap-2 border-t border-border-row px-3 py-2">
      <Button variant="ghost" aria-label="Previous step" disabled={at === 0} onClick={() => setStep(at - 1)}>←</Button>
      <p aria-live="polite" className="min-w-0 flex-1 text-13 text-fg-2">
        <span className="mr-2 font-mono text-12 text-fg-tertiary">{at + 1}/{count}</span>
        {captions[at]}
      </p>
      <Button variant="ghost" aria-label="Next step" disabled={at === count - 1} onClick={() => setStep(at + 1)}>→</Button>
    </div>
  );
  // The inner fence sits flush inside this frame's border.
  const sourceView = code !== undefined && (
    <div className="[&>div]:rounded-none [&>div]:border-0">
      <CodeFence code={code} info={info?.replace(/^\s*\S+/, "html")} />
    </div>
  );

  return (
    <VisualFrame
      testId="svg-fence"
      icon="library"
      label={label}
      views={!failed && code !== undefined ? [{ value: "image", label: "Image" }, { value: "code", label: "Code" }] : undefined}
      view={view}
      onView={setView}
      caption={caption}
      zoom={!failed && view === "image" ? <>{stage(true)}{nav}</> : undefined}
      actions={!failed && (
        <>
          {messageId && <SaveToLibrary messageId={messageId} svg={portable} />}
          <a href={svgDataUrl(portable)} download="image.svg" aria-label="Download SVG" title="Download" className="flex items-center rounded px-1 hover:text-fg">
            <Icon name="download" size={12} />
          </a>
        </>
      )}
    >
      {view === "image" && !failed ? (
        <>
          {stage(false)}
          {nav}
        </>
      ) : (
        <>
          {failed && <p role="alert" className="border-b border-border-row px-3 py-1 text-12 text-pill-blocked-fg">This SVG couldn&apos;t be displayed.{code !== undefined ? " Its source is below." : ` ${name}`}</p>}
          {sourceView}
        </>
      )}
    </VisualFrame>
  );
}

/** An ```svg-image fence in chat. */
export function SvgFence({ code, info }: { code: string; info?: string }) {
  return <DiagramVisual source={code} code={code} info={info} />;
}

/** An ```svg-steps fence: the SVG, then one numbered caption per step. */
export function StepsFence({ code, info }: { code: string; info?: string }) {
  const { svg, captions } = useMemo(() => parseStepsFence(code), [code]);
  return <DiagramVisual source={svg} captions={captions} label="Step-through" code={code} info={info} />;
}
