"use client";

import { createElement, useId, useMemo, useSyncExternalStore, type CSSProperties, type ReactNode } from "react";
import { cx } from "@/lib/cx";
import { prepareCharacterSvgForRaster, resolveCharacterNodeStyle, type CharacterState } from "@/lib/persona-character";
import { parseSvg } from "@/lib/svg-edit";
import { sanitizeSvg, type SNode } from "@/lib/svg-sanitize";

const noopSubscribe = () => () => {};
function useHydrated() {
  return useSyncExternalStore(noopSubscribe, () => true, () => false);
}

function renderCharacterNode(n: SNode, state: CharacterState, key?: number): ReactNode {
  if (n.tag === "#text") return n.text;
  const isRoot = n.path === "";
  const resolved = isRoot ? { hidden: false } : resolveCharacterNodeStyle(n.attrs, state);
  const props: Record<string, unknown> = { key, ...n.attrs };
  if (isRoot) {
    props.viewBox = "0 0 64 64";
    delete props.width;
    delete props.height;
    props["aria-hidden"] = "true";
  }
  if (resolved.motion) props["data-pc-motion"] = resolved.motion;
  if (resolved.hidden) props["data-pc-hidden"] = "true";
  if (resolved.style) props.style = resolved.style;
  return createElement(n.tag, props, ...n.children.map((c, i) => renderCharacterNode(c, state, i)));
}

/**
 * Renders a persona's validated 64x64 SVG character safely via React.createElement
 * and resolves action-state animations (`idle`, `thinking`, `reading`, `coding`,
 * `creating`, `needs_you`, or `static`).
 */
export function PersonaCharacterView({
  svg,
  color,
  size,
  state = "static",
  framed = false,
  clipped = false,
  className,
}: {
  svg: string;
  color: string;
  size: number;
  state?: CharacterState;
  framed?: boolean;
  clipped?: boolean;
  className?: string;
}) {
  const hydrated = useHydrated();
  const rawId = useId();
  const prefix = `pc-${rawId.replace(/\W/g, "")}-`;
  const tree = useMemo(() => {
    if (!hydrated) return null;
    const doc = parseSvg(svg);
    if (!doc) return null;
    return sanitizeSvg(doc.documentElement, prefix, { character: true }).tree;
  }, [hydrated, svg, prefix]);

  const boxStyle: CSSProperties = {
    width: size,
    height: size,
    color,
    ...(framed ? { background: `color-mix(in srgb, ${color} var(--persona-tint), var(--bg))`, padding: Math.max(1, Math.round(size * 0.06)) } : null),
  };

  if (!hydrated) {
    return <span aria-hidden style={boxStyle} className={cx("inline-block flex-none", framed && "rounded-full", className)} />;
  }
  if (!tree) return null;

  return (
    <span
      aria-hidden
      data-testid="persona-character"
      data-pc-state={state}
      data-pc-clipped={clipped ? "true" : undefined}
      style={boxStyle}
      className={cx(
        "persona-character inline-grid flex-none place-items-center",
        framed && "rounded-full",
        clipped && "overflow-hidden rounded-full",
        className,
      )}
    >
      {renderCharacterNode(tree, state)}
    </span>
  );
}

/**
 * Best-effort offscreen rasterization of the character's idle frame into a
 * 256x256 PNG (base64, without data: prefix) for native macOS avatar fallback.
 */
export async function rasterizeCharacterPngBase64(svg: string, color: string, size = 256): Promise<string | undefined> {
  if (typeof document === "undefined" || typeof Image === "undefined") return undefined;
  try {
    const doc = prepareCharacterSvgForRaster(svg, color, size);
    const bytes = new TextEncoder().encode(doc);
    let bin = "";
    for (let i = 0; i < bytes.length; i++) bin += String.fromCharCode(bytes[i]);
    const url = `data:image/svg+xml;base64,${btoa(bin)}`;
    const img = await new Promise<HTMLImageElement>((resolve, reject) => {
      const el = new Image();
      el.onload = () => resolve(el);
      el.onerror = () => reject(new Error("failed to decode SVG character"));
      el.src = url;
    });
    const canvas = document.createElement("canvas");
    canvas.width = size;
    canvas.height = size;
    const ctx = canvas.getContext("2d");
    if (!ctx) return undefined;

    // Soft circular tinted disc matching Vesper's avatar badge so macOS Circle clip looks natural.
    ctx.beginPath();
    ctx.arc(size / 2, size / 2, size / 2, 0, Math.PI * 2);
    ctx.closePath();
    ctx.clip();
    ctx.fillStyle = "#18181b";
    ctx.fillRect(0, 0, size, size);
    const hex = /^#[0-9a-f]{6}$/i.test(color) ? color : "#64748b";
    const r = parseInt(hex.slice(1, 3), 16);
    const g = parseInt(hex.slice(3, 5), 16);
    const b = parseInt(hex.slice(5, 7), 16);
    ctx.fillStyle = `rgba(${r}, ${g}, ${b}, 0.18)`;
    ctx.fillRect(0, 0, size, size);

    const pad = Math.round(size * 0.08);
    ctx.drawImage(img, pad, pad, size - pad * 2, size - pad * 2);
    const dataUrl = canvas.toDataURL("image/png");
    const prefix = "data:image/png;base64,";
    return dataUrl.startsWith(prefix) ? dataUrl.slice(prefix.length) : undefined;
  } catch {
    return undefined;
  }
}
