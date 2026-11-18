"use client";

import { useEffect, useId, useState } from "react";
import { svgDataUrl } from "@/lib/chat-svg";
import { CodeFence } from "./code-fence";
import { useVizPalette } from "@/lib/viz-theme";
import { contrast } from "@/lib/palettes";

export const isMermaidFence = (info: string | undefined) => (info ?? "").trim().split(/\s+/)[0]?.toLowerCase() === "mermaid";

const MAX_SOURCE = 20_000;

// Mermaid owns global configuration. Serialize initialize + render together so
// simultaneous diagrams cannot render using another view's palette.
let drawing: Promise<unknown> = Promise.resolve();

/**
 * A ```mermaid fence, drawn as a diagram. The result shows as an image, like svg-image
 * fences, so nothing in a reply's diagram can run. Mermaid loads only when one appears.
 */
export function MermaidFence({ code, info }: { code: string; info?: string }) {
  const id = `mermaid-${useId().replace(/[^a-zA-Z0-9]/g, "")}`;
  const palette = useVizPalette();
  const paletteKey = JSON.stringify(palette);
  const [drawn, setDrawn] = useState<{ code: string; paletteKey: string; svg?: string }>();
  const [showCode, setShowCode] = useState(false);
  useEffect(() => {
    if (code.length > MAX_SOURCE) return;
    let live = true;
    drawing = drawing.catch(() => undefined).then(() => import("mermaid"))
      .then(async ({ default: mermaid }) => {
        if (!live) return;
        mermaid.initialize({ startOnLoad: false, securityLevel: "strict", theme: "base", themeVariables: {
          darkMode: contrast(palette.surface, "#ffffff") > contrast(palette.surface, "#000000"),
          background: palette.surface, primaryColor: palette.panel, primaryTextColor: palette.ink,
          primaryBorderColor: palette.series[0], secondaryColor: palette.panel, secondaryTextColor: palette.ink,
          secondaryBorderColor: palette.series[1], tertiaryColor: palette.surface, tertiaryTextColor: palette.ink,
          tertiaryBorderColor: palette.line, lineColor: palette.line, textColor: palette.ink,
          mainBkg: palette.panel, nodeBorder: palette.series[0], clusterBkg: palette.surface, clusterBorder: palette.line,
          edgeLabelBackground: palette.surface, actorBkg: palette.panel, actorTextColor: palette.ink,
          actorBorder: palette.line, actorLineColor: palette.line, signalColor: palette.ink, signalTextColor: palette.ink,
          labelBoxBkgColor: palette.panel, labelBoxBorderColor: palette.line, labelTextColor: palette.ink,
          loopTextColor: palette.ink, noteBkgColor: palette.panel, noteTextColor: palette.ink, noteBorderColor: palette.line,
          ...Object.fromEntries(palette.series.map((c, i) => [`pie${i + 1}`, c])),
        }, suppressErrorRendering: true, htmlLabels: false, flowchart: { htmlLabels: false, useMaxWidth: false }, sequence: { useMaxWidth: false } });
        const { svg } = await mermaid.render(id, code);
        if (live) setDrawn({ code, paletteKey, svg });
      })
      .catch(() => {
        if (live) setDrawn({ code, paletteKey });
      });
    return () => {
      live = false;
    };
  }, [code, id, palette, paletteKey]);
  const current = drawn?.code === code && drawn.paletteKey === paletteKey ? drawn : undefined;
  if (code.length > MAX_SOURCE || (current && !current.svg)) return <CodeFence code={code} info={info} />;
  if (!current) return <div data-testid="mermaid-loading" aria-label="Drawing diagram" className="h-48 w-full animate-pulse rounded-lg border border-border bg-surface-sunken" />;
  return (
    <div data-testid="mermaid" className="flex max-w-full break-inside-avoid flex-col gap-1">
      {showCode ? (
        <CodeFence code={code} info={info} />
      ) : (
        <img src={svgDataUrl(current.svg!)} alt="Diagram" className="max-h-[480px] w-auto max-w-full self-start rounded-lg border border-border bg-surface object-contain p-2" />
      )}
      <button type="button" onClick={() => setShowCode((v) => !v)} className="self-start text-12 text-fg-tertiary hover:text-fg print:hidden">{showCode ? "Show diagram" : "Show code"}</button>
    </div>
  );
}
