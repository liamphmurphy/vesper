"use client";

import { cx } from "@/lib/cx";
import { BUILTIN_COLOR, personaInitial } from "@/lib/persona-ui";

/**
 * A persona's avatar: its uploaded image cropped to a circle, or its initial
 * on a tint of the persona color. No persona means the built-in Assistant.
 */
export function PersonaAvatar({
  name,
  color = BUILTIN_COLOR,
  src,
  size = 20,
  className,
}: {
  name: string;
  color?: string;
  /** avatar_url, or an object URL while previewing an upload */
  src?: string;
  size?: number;
  className?: string;
}) {
  const box = { width: size, height: size };
  if (src)
    // same-origin API image or a local preview blob
    return <img src={src} alt="" aria-hidden style={box} className={cx("flex-none rounded-full object-cover", className)} />;
  return (
    <span
      aria-hidden
      style={{ ...box, background: `color-mix(in srgb, ${color} var(--persona-tint), var(--bg))`, color: `color-mix(in srgb, ${color} var(--persona-ink), var(--text))`, fontSize: Math.max(9, Math.round(size * 0.5)) }}
      className={cx("grid flex-none place-items-center rounded-full font-semibold leading-none", className)}
    >
      {personaInitial(name)}
    </span>
  );
}

/** The persona's name in its color. */
export function PersonaName({ name, color = BUILTIN_COLOR, className }: { name: string; color?: string; className?: string }) {
  return (
    <span style={{ color }} className={cx("font-semibold", className)}>
      {name}
    </span>
  );
}
