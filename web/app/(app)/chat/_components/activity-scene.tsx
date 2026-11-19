"use client";

import { useEffect, useRef, useState, type CSSProperties, type ReactNode, type RefObject } from "react";
import type { ChatStatusKind } from "@/lib/chat-ui";

/** How long a scene stays up at least, so rapid tool calls never strobe. */
const HOLD_MS = 800;
/** Matches the crossfade in globals.css. */
const FADE_MS = 240;
/** How long a scene takes to coast to a stop once the person presses Stop. */
const WIND_DOWN_MS = 600;

const delay = (seconds: number): CSSProperties => ({ animationDelay: `${seconds}s` });

/**
 * The scene to show for the newest kind of work: it follows `kind`, but holds each scene
 * for HOLD_MS and keeps the outgoing one mounted for the crossfade. Kinds that come and
 * go inside a hold are skipped.
 */
export function useHeldScene(kind: ChatStatusKind) {
  const [scene, setScene] = useState<{ current: ChatStatusKind; previous?: ChatStatusKind }>({ current: kind });
  const current = scene.current;
  const shownAt = useRef(0);
  useEffect(() => {
    shownAt.current = Date.now();
  }, []);
  useEffect(() => {
    if (kind === current) return;
    const timer = setTimeout(() => {
      shownAt.current = Date.now();
      setScene((s) => ({ current: kind, previous: s.current }));
    }, Math.max(0, HOLD_MS - (Date.now() - shownAt.current)));
    return () => clearTimeout(timer);
  }, [kind, current]);
  useEffect(() => {
    if (!scene.previous) return;
    const timer = setTimeout(() => setScene((s) => ({ current: s.current })), FADE_MS);
    return () => clearTimeout(timer);
  }, [scene.previous]);
  return scene;
}

const LEARNING_PATH = "M18 44C34 44 34 16 52 16S70 44 88 44S104 16 114 16";

/** The next-step scene's branches out of the finished step: up, straight on, down. */
const NEXT_BRANCHES = ["M30 28C52 28 62 12 92 12", "M30 28H96", "M30 28C52 28 62 44 92 44"];

const CODE_LINES ="M20 10H72 M30 19H112 M30 28H88 M20 37H60 M20 46H108";

const toX = (px: number) => ({ "--to-x": `${px}px` }) as CSSProperties;
const toFrom = (px: number) => ({ "--from-x": `${px}px` }) as CSSProperties;

function canvasScene(pin?: boolean) {
  return (
    <>
      <rect className="scene-paper" x="30" y="4" width="72" height="48" rx="3" />
      {["M42 14H70V32H42Z", "M84 22a8 8 0 1 0 .01 0", "M42 42H90"].map((d, i) => (
        <path key={d} className="scene-line-accent scene-link" d={d} pathLength={1} style={delay(i * 0.35)} />
      ))}
      {pin && (
        <g className="scene-box scene-pin">
          <path className="scene-warm" d="M92 20c-4-5-6-7-6-10a6 6 0 0 1 12 0c0 3-2 5-6 10z" />
        </g>
      )}
      <g className="scene-cursor">
        <path fill="var(--text)" d="M70 32v9l2.6-2.4 3.6-.2z" />
      </g>
    </>
  );
}

/** A check on a done-coloured badge centred at (x, y). */
const badgeCheck = (x: number, y: number) => (
  <path d={`M${x - 2.4} ${y}l1.7 1.7 3.2-3.4`} fill="none" stroke="var(--surface)" strokeWidth="1.6" strokeLinecap="round" strokeLinejoin="round" />
);

/** A four-point sparkle centred at (x, y), s from centre to tip. */
const sparkle = (x: number, y: number, s: number) =>
  `M${x} ${y - s}l${s * 0.25} ${s * 0.75}l${s * 0.75} ${s * 0.25}l${-s * 0.75} ${s * 0.25}l${-s * 0.25} ${s * 0.75}l${-s * 0.25} ${-s * 0.75}l${-s * 0.75} ${-s * 0.25}l${s * 0.75} ${-s * 0.25}z`;

const vars = (v: Record<string, string | number>) => v as CSSProperties;

/** A done-coloured badge with a check, centred at (x, y). */
const doneBadge = (x: number, y: number) => (
  <>
    <circle className="scene-done" cx={x} cy={y} r="5.5" />
    {badgeCheck(x, y)}
  </>
);

/** A project folder 30 wide at x: its tab, its body and two lines of name. */
const folder = (x: number) => (
  <>
    <rect className="scene-paper" x={x + 2} y="15" width="12" height="7" rx="1.5" />
    <rect className="scene-paper" x={x} y="19" width="30" height="25" rx="2.5" />
    <path className="scene-line" strokeWidth="1.5" d={`M${x + 6} 28H${x + 22} M${x + 6} 35H${x + 16}`} />
  </>
);

/** A Library tile at (x, y) holding a thumbnail of one kind of thing made. */
const shelfTile = (x: number, y: number, thumb: ReactNode) => (
  <>
    <rect className="scene-paper" x={x} y={y} width="22" height="19" rx="2" />
    {thumb}
  </>
);

/** Kinds split off a broader one keep its scene: the step rail's glyph is what tells them apart. */
type SplitKind = "image-view" | "design-view";

const SCENES: Record<Exclude<ChatStatusKind, SplitKind>, ReactNode> = {
  thinking: (
    <>
      <circle className="scene-box scene-breathe" cx="66" cy="28" r="22" fill="none" stroke="var(--accent)" strokeOpacity="0.35" strokeWidth="1.5" />
      <circle className="scene-accent scene-drift-a" cx="54" cy="29" r="4" opacity="0.55" />
      <circle className="scene-accent scene-drift-b" cx="66" cy="23" r="5" />
      <circle className="scene-accent scene-drift-c" cx="78" cy="31" r="3.5" opacity="0.75" />
    </>
  ),
  // From the step just finished, it tries two branches part way, then commits to one and lights its node.
  "next-step": (
    <>
      {NEXT_BRANCHES.map((d) => (
        <path key={d} className="scene-empty" strokeDasharray="3 3" d={d} />
      ))}
      {[
        [98, 12],
        [102, 28],
        [98, 44],
      ].map(([cx, cy]) => (
        <circle key={cy} className="scene-empty" cx={cx} cy={cy} r="5" />
      ))}
      <path className="scene-line-accent scene-ns-probe scene-ns-probe-a" pathLength={1} d={NEXT_BRANCHES[0]} />
      <path className="scene-line-accent scene-ns-probe scene-ns-probe-b" pathLength={1} d={NEXT_BRANCHES[2]} />
      <path className="scene-line-accent scene-ns-commit" pathLength={1} d={NEXT_BRANCHES[1]} />
      <circle className="scene-accent scene-box scene-ns-chosen" cx="102" cy="28" r="5" />
      <g className="scene-ns-from">{doneBadge(22, 28)}</g>
    </>
  ),
  wiki: (
    <>
      <rect className="scene-paper" x="38" y="5" width="56" height="46" rx="4" />
      <rect className="scene-accent scene-sweep" x="38" y="18" width="56" height="9" opacity="0.3" />
      <path className="scene-line" d="M45 13H85 M45 22H81 M45 31H87 M45 40H70" />
    </>
  ),
  tickets: (
    <>
      {[24, 58, 92].map((x) => (
        <rect key={x} className="scene-empty" x={x} y="5" width="26" height="46" rx="3" />
      ))}
      <rect className="scene-paper" x="27" y="36" width="20" height="10" rx="2" />
      <rect className="scene-paper" x="61" y="36" width="20" height="10" rx="2" />
      <rect className="scene-paper" x="95" y="26" width="20" height="10" rx="2" />
      <rect className="scene-accent scene-card" x="27" y="12" width="20" height="10" rx="2" />
    </>
  ),
  // Ticket and epic cards fly in from the right and settle into a stack by the
  // persona, which pulses as each one lands. The still frame is the full stack.
  "ticket-lookup": (
    <>
      <path className="scene-line-accent scene-link" d="M120 28H40" pathLength={1} strokeOpacity="0.35" strokeDasharray="0.04 0.03" />
      <circle className="scene-box scene-node" cx="22" cy="28" r="10" fill="var(--accent)" fillOpacity="0.18" stroke="var(--accent)" strokeWidth="1.5" style={delay(0.7)} />
      <circle className="scene-accent" cx="22" cy="28" r="3.5" />
      {[
        { y: 7, epic: false, wait: 0 },
        { y: 22, epic: false, wait: 0.55 },
        { y: 37, epic: true, wait: 1.1 },
      ].map(({ y, epic, wait }) => (
        <g key={y} className="scene-pull" style={{ ...toFrom(64), ...delay(wait) }}>
          <rect className={epic ? "scene-accent" : "scene-paper"} x="42" y={y} width="34" height="12" rx="2.5" opacity={epic ? 0.85 : 1} />
          {epic ? (
            <path d={`M47 ${y + 6}l2.5-2.5 2.5 2.5-2.5 2.5z`} fill="var(--surface-raised)" />
          ) : (
            <path className="scene-line" d={`M47 ${y + 6}H52`} strokeWidth="1.5" stroke="var(--accent)" />
          )}
          <path className="scene-line" d={`M56 ${y + 6}H${epic ? 70 : 72}`} strokeWidth="1.5" style={epic ? { stroke: "var(--surface-raised)" } : undefined} />
        </g>
      ))}
    </>
  ),
  "reading-code": (
    <>
      <path className="scene-line" d={CODE_LINES} />
      <rect className="scene-accent scene-scan" x="14" y="23" width="104" height="10" rx="2" opacity="0.25" />
    </>
  ),
  // A lens sweeps across the code and locks onto the matched token.
  "searching-code": (
    <>
      <rect className="scene-paper" x="18" y="4" width="96" height="48" rx="4" />
      <path className="scene-line" strokeWidth="1.6" d="M28 14H66 M34 24H98 M34 34H84 M28 44H74" />
      <rect className="scene-accent scene-story scene-sc-hit" x="48" y="19.5" width="32" height="9" rx="2" opacity="0.32" />
      <path className="scene-line-accent scene-story scene-sc-match" strokeWidth="1.8" d="M52 24H76" />
      <g className="scene-story scene-sc-lens">
        <circle cx="64" cy="24" r="8.5" fill="var(--surface)" fillOpacity="0.35" stroke="var(--accent)" strokeWidth="2" />
        <path className="scene-line-accent" d="M70 30l6 6" />
      </g>
    </>
  ),
  "writing-code": (
    <>
      <path className="scene-line-accent scene-left scene-type-1" d="M20 12H80" />
      <path className="scene-line scene-left scene-type-2" d="M30 22H110" />
      <path className="scene-line-done scene-left scene-type-3" d="M30 32H80" />
      <path className="scene-line-done scene-left scene-type-4" d="M30 42H62" />
      <g className="scene-caret-path">
        <rect className="scene-caret" x="63" y="38" width="1.5" height="8" fill="var(--text)" />
      </g>
    </>
  ),
  tests: (
    <>
      {[26, 46, 66, 86, 106].map((cx, i) => (
        <g key={cx}>
          <circle className="scene-empty" cx={cx} cy="28" r="6.5" />
          <circle className="scene-done scene-box scene-dot" cx={cx} cy="28" r="6.5" style={{ ...delay(i * 0.4), ...(i === 4 ? { transform: "scale(0)" } : {}) }} />
        </g>
      ))}
    </>
  ),
  build: (
    <>
      <path className="scene-line" d="M36 53H96" />
      <g className="scene-row-1">
        {[42, 58, 74].map((x) => (
          <rect key={x} className="scene-paper" x={x} y="40" width="15" height="12" rx="2" />
        ))}
      </g>
      <g className="scene-row-2">
        {[50, 66].map((x) => (
          <rect key={x} className="scene-paper" x={x} y="27" width="15" height="12" rx="2" />
        ))}
      </g>
      <g className="scene-row-3">
        <rect className="scene-accent" x="58" y="14" width="15" height="12" rx="2" />
      </g>
    </>
  ),
  install: (
    <>
      {[52, 62, 72].map((x, i) => (
        <rect key={x} className="scene-accent scene-drop" x={x} y="6" width="9" height="9" rx="1.5" style={delay(i * 0.8)} />
      ))}
      <g className="scene-bump">
        <rect className="scene-paper" x="46" y="30" width="40" height="22" rx="2" />
        <path className="scene-line" d="M46 30L38 24 M86 30L94 24 M60 41H72" />
      </g>
    </>
  ),
  terminal: (
    <>
      <rect className="scene-paper" x="28" y="4" width="76" height="48" rx="4" />
      <svg x="36" y="8" width="60" height="30" viewBox="0 0 60 30">
        <path className="scene-line scene-scroll-3" d="M0 5H42 M0 15H54 M0 25H30 M0 35H42 M0 45H54 M0 55H30" />
      </svg>
      <path className="scene-line-accent" d="M36 40l3 3-3 3" />
      <rect className="scene-caret" x="44" y="39" width="5" height="8" fill="var(--accent)" />
    </>
  ),
  github: (
    <>
      <path className="scene-line" d="M8 44H124" />
      <path className="scene-line-done" d="M24 44C40 44 40 14 56 14H88C104 14 104 44 120 44" />
      <circle className="scene-muted" cx="24" cy="44" r="3.5" />
      <circle className="scene-done" cx="56" cy="14" r="3.5" />
      <circle cx="120" cy="44" r="4" fill="var(--surface)" stroke="var(--accent)" strokeWidth="1.5" />
      <g className="scene-commit">
        <circle className="scene-done" cx="72" cy="14" r="7" opacity="0.25" />
        <circle className="scene-done" cx="72" cy="14" r="3" />
      </g>
    </>
  ),
  commit: (
    <>
      <path className="scene-line" d="M12 40H120" />
      <circle className="scene-muted" cx="28" cy="40" r="3.5" />
      <circle className="scene-muted" cx="64" cy="40" r="3.5" />
      {[12, 0, -12].map((x, i) => (
        <rect key={x} className="scene-paper scene-box scene-chip" x={96 - x} y="8" width="8" height="10" rx="1.5" style={{ ...toX(x), ...delay(i * 0.15) }} />
      ))}
      <circle className="scene-done scene-box scene-stamp" cx="100" cy="40" r="5" />
    </>
  ),
  push: (
    <>
      <path className="scene-line" d="M20 44L88 22" />
      <circle className="scene-muted" cx="20" cy="44" r="4" />
      <path className="scene-line-accent scene-box scene-arrive" d="M92 28a8 8 0 0 1 0-16 11 11 0 0 1 21-2 9 9 0 0 1 3 18z" />
      <g className="scene-push">
        <circle className="scene-done" cx="88" cy="22" r="7" opacity="0.25" />
        <circle className="scene-done" cx="88" cy="22" r="3" />
      </g>
    </>
  ),
  "pull-request": (
    <>
      <path className="scene-line" d="M10 44H122" />
      <path className="scene-line-done scene-link" d="M22 44C36 44 36 14 52 14H70C86 14 86 44 100 44" pathLength={1} />
      <circle className="scene-muted" cx="22" cy="44" r="3.5" />
      <g className="scene-box scene-pop">
        <circle className="scene-done" cx="100" cy="44" r="8" />
        <path d="M96.5 44l2.5 2.5 4.5-5" fill="none" stroke="var(--surface)" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
      </g>
    </>
  ),
  "repo-history": (
    <>
      <path className="scene-line" d="M30 6V50" />
      {[10, 22, 34, 46].map((cy) => (
        <circle key={cy} className="scene-muted" cx="30" cy={cy} r="3" />
      ))}
      <path className="scene-line" d="M42 10H104 M42 22H88 M42 34H110 M42 46H78" />
      <rect className="scene-accent scene-log" x="22" y="4" width="94" height="12" rx="2" opacity="0.25" />
    </>
  ),
  web: (
    <>
      <g fill="none" stroke="var(--text-tertiary)" strokeWidth="1.5">
        <circle cx="66" cy="28" r="16" />
        <ellipse cx="66" cy="28" rx="7" ry="16" />
        <path d="M50 28H82 M53 19H79 M53 37H79" />
      </g>
      <g className="scene-orbit">
        <g className="scene-upright">
          <circle cx="79" cy="19" r="6.5" fill="var(--surface)" stroke="var(--accent)" strokeWidth="2" />
          <path className="scene-line-accent" d="M83.6 23.6l5.4 5.4" />
        </g>
      </g>
    </>
  ),
  // A browser page scrolls past while a reader highlight sweeps down the article.
  "web-page": (
    <>
      <rect className="scene-paper" x="22" y="4" width="88" height="48" rx="4" />
      <path className="scene-line" strokeWidth="1" opacity="0.45" d="M22 14H110" />
      {[28, 33, 38].map((cx) => (
        <circle key={cx} className="scene-muted" cx={cx} cy="9" r="1.4" />
      ))}
      <rect className="scene-empty" x="45" y="6.8" width="44" height="4.4" rx="2" strokeWidth="1" opacity="0.6" />
      <svg x="28" y="17" width="76" height="31" viewBox="0 0 76 31">
        <g className="scene-wp-scroll">
          <rect className="scene-accent" opacity="0.24" x="0" y="2" width="26" height="13" rx="2" />
          <path className="scene-line-accent" strokeWidth="1.6" d="M32 5H68" />
          <path className="scene-line" strokeWidth="1.5" d="M32 11H62 M0 21H70 M0 28H54" />
          <rect className="scene-accent" opacity="0.24" x="0" y="36" width="26" height="13" rx="2" />
          <path className="scene-line-accent" strokeWidth="1.6" d="M32 39H68" />
          <path className="scene-line" strokeWidth="1.5" d="M32 45H62 M0 55H70 M0 62H54" />
        </g>
      </svg>
      <rect className="scene-accent scene-wp-scan" x="26" y="24" width="80" height="7" rx="1.5" opacity="0.18" />
    </>
  ),
  video: (
    <>
      <rect className="scene-paper" x="40" y="3" width="52" height="31" rx="4" />
      <path className="scene-accent scene-box scene-node" d="M61 11v15l12-7.5z" />
      <svg x="34" y="38" width="64" height="16" viewBox="0 0 64 16">
        <path className="scene-line scene-scroll-2" d="M6 4H58 M14 12H50 M6 20H58 M14 28H50" />
      </svg>
    </>
  ),
  image: (
    <>
      {["var(--border-strong)", "var(--text-tertiary)", "var(--accent)", "var(--accent)", "var(--text-tertiary)", "var(--accent)", "var(--accent)", "var(--state-progress)", "var(--border-strong)", "var(--state-done)", "var(--state-done)", "var(--state-done)"].map((fill, i) => (
        <rect key={i} className="scene-tile" x={40 + (i % 4) * 13} y={6 + Math.floor(i / 4) * 14.67} width="13" height="14.67" fill={fill} opacity={i % 4 === 2 ? 0.75 : 1} style={delay(((i * 5) % 12) * 0.08)} />
      ))}
    </>
  ),
  canvas: canvasScene(),
  "canvas-comment": canvasScene(true),
  // A frame sketches itself, its button is wired to the next frame, that frame fills in, then a sparkle.
  design: (
    <>
      <rect className="scene-paper" x="26" y="4" width="32" height="48" rx="4" />
      <path className="scene-line-accent scene-dash scene-story scene-dz-sketch" strokeWidth="1.5" pathLength={1} d="M30 4H54a4 4 0 0 1 4 4V48a4 4 0 0 1-4 4H30a4 4 0 0 1-4-4V8a4 4 0 0 1 4-4z" />
      <path className="scene-line scene-story scene-dz-a0" d="M32 12H46" />
      <path className="scene-line scene-story scene-dz-a1" strokeWidth="1.5" opacity="0.6" d="M32 19H52M32 25H48" />
      <rect className="scene-accent scene-story scene-dz-btn" x="32" y="40" width="20" height="7" rx="2" />
      <path className="scene-line-accent scene-dash scene-story scene-dz-wire" strokeWidth="1.6" pathLength={1} d="M52 43.5C68 43.5 68 20 83 20" />
      <path className="scene-accent scene-story scene-dz-head" d="M81 16.5l4 3.5-4 3.5z" />
      <rect className="scene-paper scene-story scene-dz-frame" x="86" y="4" width="32" height="48" rx="4" stroke="var(--accent)" strokeWidth="1.5" />
      <path className="scene-line-accent scene-story scene-dz-b0" d="M92 12H106" />
      <path className="scene-line scene-story scene-dz-b1" strokeWidth="1.5" opacity="0.6" d="M92 19H112M92 25H104" />
      <rect className="scene-accent scene-story scene-dz-b2" x="92" y="40" width="20" height="7" rx="2" />
      <path className="scene-warm scene-story scene-dz-spark" d={sparkle(122, 12, 6)} />
      <g className="scene-story scene-dz-cur">
        <path fill="var(--text)" d="M104 36v9l2.6-2.4 3.6-.2z" />
      </g>
    </>
  ),
  runs: (
    <>
      {[
        { y: 14, rest: 0.8, seconds: 2.6, stroke: "var(--accent)" },
        { y: 28, rest: 0.45, seconds: 3.7, stroke: "var(--state-done)" },
        { y: 42, rest: 0.65, seconds: 3.1, stroke: "var(--state-progress)" },
      ].map(({ y, rest, seconds, stroke }) => (
        <g key={y}>
          <path className="scene-line" d={`M24 ${y}H108`} opacity="0.3" />
          <path className="scene-line scene-left scene-bar" d={`M24 ${y}H108`} style={{ stroke, transform: `scaleX(${rest})`, animationDuration: `${seconds}s` }} />
        </g>
      ))}
    </>
  ),
  workflow: (
    <>
      <path className="scene-line" d="M30 28C42 28 44 14 56 14 M30 28C42 28 44 42 56 42 M74 14C86 14 88 28 98 28 M74 42C86 42 88 28 98 28" />
      {[
        { x: 12, y: 22, wait: 0 },
        { x: 56, y: 8, wait: 0.5 },
        { x: 56, y: 36, wait: 0.5 },
        { x: 98, y: 22, wait: 1 },
      ].map(({ x, y, wait }) => (
        <rect key={`${x}-${y}`} className="scene-accent scene-light" x={x} y={y} width="18" height="12" rx="3" style={delay(wait)} />
      ))}
    </>
  ),
  connector: (
    <>
      <rect className="scene-accent scene-box scene-plug" x="24" y="19" width="26" height="18" rx="4" />
      <path className="scene-line-accent scene-plug" d="M8 28H24M50 23H60M50 33H60" />
      <rect className="scene-warm" x="82" y="17" width="26" height="22" rx="4" fillOpacity="0.85" />
      <path className="scene-line-accent" d="M108 28H124" />
      <path className="scene-line-accent scene-link" d="M64 23H82M64 33H82" pathLength={1} strokeOpacity="0.5" />
      <circle className="scene-warm scene-box scene-node" cx="73" cy="10" r="2.5" />
      <circle className="scene-accent scene-box scene-node" cx="66" cy="47" r="2" style={delay(0.5)} />
      <circle className="scene-warm scene-box scene-node" cx="80" cy="47" r="2" style={delay(1)} />
    </>
  ),
  // A key travels to a lock: Vesper adds the secret on the way out.
  secret: (
    <>
      <circle className="scene-warm scene-box" cx="30" cy="28" r="9" fillOpacity="0.85" />
      <path className="scene-line-accent scene-plug" d="M39 28H62M54 28V34M60 28V33" />
      <rect className="scene-accent scene-box" x="86" y="22" width="22" height="18" rx="3" />
      <path className="scene-line-accent" d="M90 22V17A7 7 0 0 1 104 17V22" />
      <path className="scene-line-accent scene-link" d="M64 28H84" pathLength={1} strokeOpacity="0.5" />
      <circle className="scene-warm scene-box scene-node" cx="97" cy="31" r="2" style={delay(0.5)} />
    </>
  ),
  memory: (
    <>
      {["M30 44L54 16", "M54 16L84 32", "M84 32L106 10", "M54 16L72 50", "M72 50L84 32"].map((d, i) => (
        <path key={d} className="scene-line-accent scene-link" d={d} pathLength={1} strokeOpacity="0.6" style={delay(i * 0.35)} />
      ))}
      <circle className="scene-accent scene-box scene-node" cx="30" cy="44" r="3.5" />
      <circle className="scene-accent scene-box scene-node" cx="54" cy="16" r="4.5" style={delay(0.3)} />
      <circle className="scene-accent scene-box scene-node" cx="84" cy="32" r="4" style={delay(0.6)} />
      <circle className="scene-warm scene-box scene-node" cx="106" cy="10" r="5" style={delay(0.9)} />
      <circle className="scene-accent scene-box scene-node" cx="72" cy="50" r="3" style={delay(1.2)} />
    </>
  ),
  // A new memory star lands beside the constellation, wires in, and sparkles.
  "memory-save": (
    <>
      <path className="scene-line" strokeWidth="1.4" opacity="0.45" d="M26 42L48 18L72 36L50 48Z" />
      <circle className="scene-accent" opacity="0.7" cx="26" cy="42" r="3.2" />
      <circle className="scene-accent" opacity="0.85" cx="48" cy="18" r="4" />
      <circle className="scene-accent" opacity="0.75" cx="72" cy="36" r="3.8" />
      <circle className="scene-accent" opacity="0.6" cx="50" cy="48" r="2.8" />
      <path className="scene-line-accent scene-dash scene-story scene-ms-link0" strokeWidth="1.6" pathLength={1} d="M48 18L98 18" />
      <path className="scene-line-accent scene-dash scene-story scene-ms-link1" strokeWidth="1.6" pathLength={1} d="M72 36L98 18" />
      <circle className="scene-warm scene-story scene-ms-node" cx="98" cy="18" r="6" />
      <path className="scene-warm scene-story scene-ms-spark" d={sparkle(112, 10, 5)} />
    </>
  ),
  // The app's containers stack up (a database, its setup, a process), a link
  // reaches the browser, the page fills in and the status light goes green.
  playground: (
    <>
      <rect className="scene-paper scene-pg-1" x="14" y="40" width="32" height="11" rx="5.5" />
      <path className="scene-line scene-pg-1" d="M21 45.5H39" strokeWidth="1.5" />
      <rect className="scene-paper scene-pg-2" x="14" y="27" width="32" height="11" rx="2.5" />
      <path className="scene-line-done scene-pg-2" d="M24 32.5l3 3 6-6" strokeWidth="1.5" />
      <rect className="scene-paper scene-pg-3" x="14" y="14" width="32" height="11" rx="2.5" />
      <path className="scene-accent scene-pg-3" d="M27 16.5v6l5-3z" />
      <path className="scene-line-accent scene-pg-link" d="M48 19.5C58 19.5 58 28 68 28" pathLength={1} />
      <rect className="scene-paper" x="70" y="6" width="50" height="44" rx="4" />
      <path className="scene-line" d="M71 15H119" strokeWidth="1" strokeOpacity="0.5" />
      {[75, 79, 83].map((cx) => (
        <circle key={cx} className="scene-muted" cx={cx} cy="10.5" r="1.3" />
      ))}
      <g className="scene-pg-page">
        <path className="scene-line" d="M76 22H108 M76 29H100" strokeWidth="1.5" />
        <rect className="scene-accent" x="76" y="36" width="20" height="7" rx="2" />
      </g>
      <circle className="scene-box scene-pg-ring" cx="114" cy="10.5" r="2.4" fill="none" stroke="var(--state-done)" strokeWidth="1" strokeOpacity="0.4" />
      <circle className="scene-done scene-box scene-pg-live" cx="114" cy="10.5" r="2.4" />
    </>
  ),
  // Past conversations as speech bubbles; a lens passes over each in turn and
  // the one under it lights up, like a match turning up.
  "chat-history": (
    <>
      {[
        { x: 22, y: 4, w: 48, tail: "M30 16l-4 5 9-5" },
        { x: 62, y: 21, w: 48, tail: "M102 33l4 5-9-5" },
        { x: 22, y: 38, w: 40, tail: "" },
      ].map(({ x, y, w, tail }, i) => (
        <g key={y}>
          {tail && <path className="scene-paper" d={tail} />}
          <rect className="scene-paper" x={x} y={y} width={w} height="13" rx="6.5" />
          <rect className="scene-accent scene-history-hit" x={x} y={y} width={w} height="13" rx="6.5" style={delay(i * 1.32)} />
          <path className="scene-line" d={`M${x + 7} ${y + 6.5}H${x + w - 12}`} strokeWidth="1.5" />
        </g>
      ))}
      <g className="scene-history-lens">
        <circle cx="46" cy="10.5" r="7" fill="var(--surface)" fillOpacity="0.4" stroke="var(--accent)" strokeWidth="2" />
        <path className="scene-line-accent" d="M51 15.5l5 5" />
      </g>
    </>
  ),
  // A lens reads down the repositories; the second matches and gets a check.
  "repo-search": (
    <>
      {[6, 22, 38].map((y) => (
        <rect key={y} className="scene-paper" x="20" y={y} width="84" height="12" rx="2.5" />
      ))}
      <rect className="scene-accent scene-story scene-rs-hit" opacity="0.3" x="20" y="22" width="84" height="12" rx="2.5" />
      <path className="scene-line-accent" strokeWidth="1.3" strokeLinejoin="round" d="M27 8.5h5v7h-5z M27 24.5h5v7h-5z M27 40.5h5v7h-5z" />
      <path className="scene-line" strokeWidth="1.5" d="M38 12H86 M38 28H74 M38 44H80" />
      <g className="scene-story scene-rs-check">
        <circle className="scene-done" cx="114" cy="28" r="5.5" />
        {badgeCheck(114, 28)}
      </g>
      <g className="scene-story scene-rs-lens">
        <circle cx="80" cy="12" r="6" fill="var(--surface)" fillOpacity="0.4" stroke="var(--accent)" strokeWidth="2" />
        <path className="scene-line-accent" d="M84.4 16.4l4.4 4.4" />
      </g>
    </>
  ),
  // Files travel from the repository into the workspace folder, which fills, then a check.
  "repo-attach": (
    <>
      <rect className="scene-paper" x="14" y="12" width="30" height="32" rx="3" />
      <rect x="22" y="19" width="14" height="17" rx="1.5" fill="none" stroke="var(--accent)" strokeWidth="1.5" />
      <path className="scene-line-accent" strokeWidth="1.5" d="M25.5 19v17" />
      <path className="scene-line" strokeWidth="1.5" strokeDasharray="2 3" opacity="0.5" d="M48 28H80" />
      {[0, 0.35, 0.7].map((wait) => (
        <rect key={wait} className="scene-accent scene-story scene-ra-chip" opacity="0" style={delay(wait)} x="46" y="24" width="6" height="8" rx="1.2" />
      ))}
      <path className="scene-paper" strokeLinejoin="round" d="M84 14h11l3 4h20v30H84z" />
      {["M90 27H112", "M90 34H106", "M90 41H110"].map((d, i) => (
        <path key={d} className={`scene-line scene-story scene-ra-f${i}`} strokeWidth="1.5" d={d} />
      ))}
      <g className="scene-story scene-ra-badge">
        <circle className="scene-done" cx="118" cy="16" r="5.5" />
        {badgeCheck(118, 16)}
      </g>
    </>
  ),
  // The filmstrip's frames render one by one with the progress bar, then a play badge.
  "video-render": (
    <>
      <rect className="scene-paper" x="16" y="3" width="100" height="36" rx="3" />
      {Array.from({ length: 12 }, (_, i) => (
        <g key={i} fill="var(--border-strong)">
          <rect x={20 + i * 8} y="5" width="4" height="2.5" rx="0.6" />
          <rect x={20 + i * 8} y="34.5" width="4" height="2.5" rx="0.6" />
        </g>
      ))}
      {[0.9, 0.6, 0.8, 0.5, 0.7, 0.95].map((o, i) => (
        <g key={i}>
          <rect className="scene-empty" x={21 + i * 15.5} y="10" width="13.5" height="22" rx="1.5" />
          <rect className={`scene-accent scene-story scene-vr-c${i}`} opacity={o} style={vars({ "--o": o })} x={21 + i * 15.5} y="10" width="13.5" height="22" rx="1.5" />
        </g>
      ))}
      <path className="scene-line" opacity="0.3" d="M16 48H116" />
      <path className="scene-line-accent scene-story scene-vr-bar" d="M16 48H116" />
      <g className="scene-story scene-vr-badge">
        <circle className="scene-done" cx="66" cy="21" r="8.5" />
        <path d="M63.5 16.5v9l7-4.5z" fill="var(--surface)" />
      </g>
    </>
  ),
  // Waveform bars rise one by one as the render advances, then a play badge lands.
  "audio-render": (
    <>
      <rect className="scene-paper" x="16" y="3" width="100" height="36" rx="3" />
      {[0.35, 0.6, 0.9, 0.5, 0.75, 1, 0.55, 0.8, 0.4, 0.65].map((h, i) => (
        <g key={i}>
          <rect className="scene-empty" x={23 + i * 9} y={21 - h * 14} width="4.5" height={h * 28} rx="2" />
          <rect className={`scene-accent scene-story scene-au-b${i % 5}`} x={23 + i * 9} y={21 - h * 14} width="4.5" height={h * 28} rx="2" />
        </g>
      ))}
      <path className="scene-line" opacity="0.3" d="M16 48H116" />
      <path className="scene-line-accent scene-story scene-au-bar" d="M16 48H116" />
      <g className="scene-story scene-au-badge">
        <circle className="scene-done" cx="104" cy="12" r="7.5" />
        <path d="M101.8 8.5v7l5.6-3.5z" fill="var(--surface)" />
      </g>
    </>
  ),
  // Bars rise, a trend line draws over them, and a coin lands.
  finance: (
    <>
      <path className="scene-line" d="M22 49H102" />
      {[16, 26, 20, 34].map((h, i) => (
        <rect key={i} className={`scene-accent scene-story scene-fin-b${i}`} opacity={[0.45, 0.6, 0.75, 1][i]} x={28 + i * 18} y={48 - h} width="12" height={h} rx="2" />
      ))}
      <path className="scene-line-done scene-dash scene-story scene-fin-line" pathLength={1} strokeLinejoin="round" d="M34 28L52 18L70 24L88 10" />
      <g className="scene-story scene-fin-coin">
        <circle className="scene-warm" cx="112" cy="14" r="8" />
        <text x="112" y="17.5" textAnchor="middle" fontSize="10" fontWeight="700" fontFamily="system-ui" fill="var(--surface)">
          $
        </text>
      </g>
    </>
  ),
  // Each transaction hops from its row into its category's bucket.
  "finance-sort": (
    <>
      {[8, 22, 36].map((y) => (
        <g key={y}>
          <rect className="scene-paper" x="12" y={y} width="46" height="10" rx="2" />
          <path className="scene-line" strokeWidth="1.5" d={`M16 ${y + 5}H30`} />
        </g>
      ))}
      {(
        [
          ["var(--accent)", 72],
          ["var(--state-done)", 92],
          ["var(--state-progress)", 112],
        ] as const
      ).map(([stroke, x]) => (
        <path key={x} d={`M${x} 32v16h16V32`} fill="none" stroke={stroke} strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />
      ))}
      {(
        [
          ["var(--accent)", 10, 33, 31],
          ["var(--state-done)", 24, 53, 17],
          ["var(--state-progress)", 38, 73, 3],
        ] as const
      ).map(([fill, y, tx, ty], i) => (
        <rect key={y} className="scene-story scene-fs-chip" fill={fill} style={{ ...vars({ "--tx": `${tx}px`, "--ty": `${ty}px` }), ...delay(i * 0.6) }} x="40" y={y} width="14" height="6" rx="1.5" />
      ))}
    </>
  ),
  // A portrait is drawn in, then sparkles.
  persona: (
    <>
      <rect className="scene-paper" x="44" y="4" width="44" height="48" rx="6" />
      <path className="scene-line-accent scene-dash scene-story scene-pe-head" pathLength={1} d="M66 13a8 8 0 1 1-.01 0" />
      <path className="scene-line-accent scene-dash scene-story scene-pe-body" pathLength={1} d="M52 47c0-9 6-14 14-14s14 5 14 14" />
      <path className="scene-warm scene-story scene-pe-s0" d={sparkle(100, 14, 6)} />
      <path className="scene-warm scene-story scene-pe-s1" d={sparkle(32, 40, 4.5)} />
    </>
  ),
  // The clock's hand sweeps while the same weekday lights up week after week.
  schedule: (
    <>
      <circle className="scene-paper" cx="38" cy="28" r="19" />
      <path className="scene-line" strokeWidth="1.5" d="M38 12v3 M38 41v3 M22 28h3 M51 28h3" />
      <path className="scene-line" d="M38 28l-6 4" />
      <path className="scene-line-accent scene-sch-hand" d="M38 28V16" />
      <circle className="scene-accent" cx="38" cy="28" r="2" />
      <rect className="scene-paper" x="68" y="8" width="50" height="42" rx="3" />
      <rect className="scene-accent" x="68" y="8" width="50" height="8" rx="3" />
      <rect className="scene-accent" x="68" y="12" width="50" height="4" />
      {[25, 34, 43].map((y) =>
        [77, 88, 99, 110].map((x) => <circle key={`${x}-${y}`} className="scene-muted" opacity="0.45" cx={x} cy={y} r="2.4" />),
      )}
      {[25, 34, 43].map((y, i) => (
        <circle key={y} className={`scene-accent scene-story scene-sch-d${i}`} cx="88" cy={y} r="3.4" />
      ))}
    </>
  ),
  // The path draws and each lesson is checked off on the way to the flag.
  learning: (
    <>
      <path className="scene-line" opacity="0.35" d={LEARNING_PATH} />
      <path className="scene-line-done scene-dash scene-story scene-lm-path" pathLength={1} d={LEARNING_PATH} />
      {[
        [18, 44],
        [52, 16],
        [88, 44],
      ].map(([x, y], i) => (
        <g key={x} className={`scene-story scene-lm-n${i}`}>
          <circle className="scene-done" cx={x} cy={y} r="5.5" />
          {badgeCheck(x, y)}
        </g>
      ))}
      <g className="scene-story scene-lm-n3">
        <path className="scene-line-accent" strokeWidth="1.5" d="M114 24V5" />
        <path className="scene-warm" d="M114 5.5h11l-3 3.5 3 3.5h-11z" />
      </g>
    </>
  ),
  // The report types itself while each source links to its citation.
  research: (
    <>
      <rect className="scene-paper" x="18" y="4" width="62" height="48" rx="3" />
      {["M26 14H70", "M26 23H64", "M26 32H72", "M26 41H54"].map((d, i) => (
        <path key={d} className={`${i ? "scene-line" : "scene-line-accent"} scene-story scene-rt-${i}`} d={d} />
      ))}
      {[8, 23, 38].map((y) => (
        <g key={y}>
          <rect className="scene-paper" x="92" y={y} width="28" height="10" rx="2" />
          <path className="scene-line" strokeWidth="1.5" d={`M97 ${y + 5}H113`} />
        </g>
      ))}
      {[
        [73, 12],
        [67, 21],
        [75, 30],
      ].map(([x, y], i) => (
        <g key={x}>
          <path className={`scene-line-accent scene-dash scene-story scene-rl-${i}`} strokeWidth="1.2" strokeOpacity="0.6" pathLength={1} d={`M91 ${13 + 15 * i}L${x + 3} ${y}`} />
          <circle className={`scene-accent scene-story scene-rsup-${i}`} cx={x} cy={y} r="2" />
        </g>
      ))}
    </>
  ),
  // The space's outline draws, its tab appears, and things drop in.
  space: (
    <>
      <path className="scene-line-accent scene-dash scene-story scene-sp-o" pathLength={1} strokeLinejoin="round" d="M30 12H102V50H30Z" />
      <rect className="scene-accent scene-story scene-sp-tab" x="30" y="4" width="26" height="8" rx="2" />
      {[40, 59, 78].map((x, i) => (
        <g key={x} className={`scene-story scene-sp-i${i}`}>
          <rect className="scene-paper" x={x} y="26" width="14" height="16" rx="2" />
          <path className="scene-line" strokeWidth="1.5" d={`M${x + 4} 31H${x + 10}`} />
        </g>
      ))}
    </>
  ),
  // A bookmark ribbon drops onto the stack of saved pages.
  "saved-links": (
    <>
      <rect className="scene-paper" x="52" y="14" width="50" height="36" rx="3" />
      <rect className="scene-paper" x="46" y="10" width="50" height="36" rx="3" />
      <rect className="scene-paper" x="40" y="6" width="50" height="36" rx="3" />
      <rect className="scene-accent" opacity="0.3" x="44" y="10" width="16" height="12" rx="1.5" />
      <path className="scene-line" strokeWidth="1.5" d="M64 13H76 M64 19H72" />
      <path className="scene-line" strokeWidth="1.5" opacity="0.6" d="M44 29H82 M44 35H70" />
      <path className="scene-warm scene-story scene-sl-r" d="M78 6V20l4-3 4 3V6z" />
    </>
  ),
  // Three folders land, the default one lifts, its tab lights and gets a check.
  projects: (
    <>
      <g className="scene-story scene-pj-f0">{folder(16)}</g>
      <g className="scene-story scene-pj-f1">
        <g className="scene-story scene-pj-lift">
          {folder(51)}
          <rect className="scene-accent scene-story scene-pj-tab" x="53" y="15" width="12" height="7" rx="1.5" />
          <rect className="scene-paper" style={{ fill: "none" }} x="51" y="19" width="30" height="25" rx="2.5" />
          <g className="scene-story scene-pj-check">{doneBadge(81, 19)}</g>
        </g>
      </g>
      <g className="scene-story scene-pj-f2">{folder(86)}</g>
    </>
  ),
  // A lens browses the shelf of things made; the video matches and pops forward.
  library: (
    <>
      {shelfTile(30, 6, (
        <>
          <path className="scene-accent" opacity="0.55" d="M33 22l5-6 4 4 3-3 4 5z" />
          <circle className="scene-warm" cx="46" cy="11" r="2" />
        </>
      ))}
      {shelfTile(56, 6, <path className="scene-line" strokeWidth="1.5" d="M60 11H74 M60 15.5H72 M60 20H68" />)}
      {shelfTile(82, 6, <path className="scene-accent" opacity="0.8" d="M86 22v-5h3v5z M91 22v-9h3v9z M96 22v-7h3v7z" />)}
      {shelfTile(30, 31, (
        <>
          <rect className="scene-empty" x="33" y="35" width="7" height="5" rx="1" />
          <rect className="scene-empty" x="44" y="42" width="7" height="5" rx="1" />
          <path className="scene-line" strokeWidth="1.2" d="M40 37.5C44 37.5 44 44.5 44 44.5" />
        </>
      ))}
      <g className="scene-story scene-lib-pop">
        {shelfTile(56, 31, <path className="scene-accent" d="M64 35.5v10l8-5z" />)}
        <rect className="scene-accent scene-story scene-lib-hit" opacity="0.3" x="56" y="31" width="22" height="19" rx="2" />
      </g>
      {shelfTile(82, 31, <path className="scene-muted" opacity="0.6" d="M85 47l5-6 4 4 3-3 4 5z" />)}
      <g className="scene-story scene-lib-lens">
        <circle cx="41" cy="15.5" r="6.5" fill="var(--surface)" fillOpacity="0.4" stroke="var(--accent)" strokeWidth="2" />
        <path className="scene-line-accent" d="M45.6 20.1l4.4 4.4" />
      </g>
    </>
  ),
  // What needs the person drops into the tray one by one, then the count pops.
  inbox: (
    <>
      {(
        [
          ["scene-accent", 5, 80],
          ["scene-warm", 14, 74],
          ["scene-done", 23, 84],
        ] as const
      ).map(([dot, y, end], i) => (
        <g key={y} className={`scene-story scene-ib-c${i}`}>
          <rect className="scene-paper" x="42" y={y} width="48" height="8" rx="2" />
          <circle className={dot} cx="47" cy={y + 4} r="2" />
          <path className="scene-line" strokeWidth="1.5" d={`M52 ${y + 4}H${end}`} />
        </g>
      ))}
      <path className="scene-paper" strokeLinejoin="round" d="M28 34h20l4 6h28l4-6h20v16H28z" />
      <g className="scene-story scene-ib-n">
        <circle className="scene-warm" cx="108" cy="34" r="6.5" />
        <text x="108" y="37" textAnchor="middle" fontSize="8.5" fontWeight="700" fontFamily="system-ui" fill="var(--surface)">
          3
        </text>
      </g>
    </>
  ),
  // The line draws across the axes and each point pops as it's reached.
  chart: (
    <>
      <path className="scene-line" strokeWidth="1" opacity="0.3" d="M26 18H114 M26 28H114 M26 38H114" />
      <path className="scene-line" strokeWidth="1.5" strokeLinejoin="round" d="M26 6V48H114" />
      <path className="scene-line-accent scene-dash scene-story scene-ch-l" pathLength={1} strokeLinejoin="round" d="M32 40L50 30L68 34L86 20L106 12" />
      {[
        [32, 40],
        [50, 30],
        [68, 34],
        [86, 20],
        [106, 12],
      ].map(([x, y], i) => (
        <circle key={x} className={`scene-accent scene-story scene-ch-p${i}`} cx={x} cy={y} r="2.8" />
      ))}
    </>
  ),
  // A sequence diagram's messages draw back and forth between two lifelines.
  diagram: (
    <>
      <rect className="scene-paper" x="16" y="3" width="32" height="10" rx="2" />
      <rect className="scene-paper" x="84" y="3" width="32" height="10" rx="2" />
      <path className="scene-line" strokeWidth="1.5" d="M24 8H40 M92 8H108" />
      <path className="scene-line" strokeWidth="1.2" strokeDasharray="2 3" opacity="0.6" d="M32 14V53 M100 14V53" />
      {["M34 22H96", "M98 33H36", "M34 44H96"].map((d, i) => (
        <path key={d} className={`scene-line-accent scene-dash scene-story scene-sq-m${i}`} strokeWidth="1.6" pathLength={1} d={d} />
      ))}
      {["M92.5 19l3.5 3-3.5 3", "M39.5 30l-3.5 3 3.5 3", "M92.5 41l3.5 3-3.5 3"].map((d, i) => (
        <path key={d} className={`scene-line-accent scene-story scene-sq-h${i}`} strokeWidth="1.6" strokeLinejoin="round" d={d} />
      ))}
    </>
  ),
  // A slider moves and the shape it controls grows and shrinks with it.
  app: (
    <>
      <rect className="scene-paper" x="26" y="4" width="80" height="48" rx="4" />
      <path className="scene-line" strokeWidth="1" opacity="0.5" d="M26 13H106" />
      {[31, 35, 39].map((cx) => (
        <circle key={cx} className="scene-muted" cx={cx} cy="8.5" r="1.3" />
      ))}
      <circle cx="66" cy="27" r="9" fill="none" stroke="var(--border-strong)" strokeWidth="1.5" strokeDasharray="2 2" />
      <circle className="scene-accent scene-box scene-ap-grow" opacity="0.75" cx="66" cy="27" r="9" />
      <path className="scene-line" strokeWidth="1.5" opacity="0.4" d="M38 44H94" />
      <path className="scene-line-accent scene-box scene-ap-fill" strokeWidth="1.5" d="M38 44H94" />
      <circle className="scene-box scene-ap-knob" cx="46" cy="44" r="3.5" fill="var(--surface)" stroke="var(--accent)" strokeWidth="2" />
    </>
  ),
  // The highlight hops between the options, a pointer clicks the second, and it's picked.
  choices: (
    <>
      {[5, 22, 39].map((y) => (
        <rect key={y} className="scene-paper" x="30" y={y} width="72" height="12" rx="6" />
      ))}
      <rect className="scene-accent scene-story scene-cho-hl" fillOpacity="0.22" x="30" y="22" width="72" height="12" rx="6" />
      {[11, 28, 45].map((cy) => (
        <circle key={cy} className="scene-empty" cx="38" cy={cy} r="3" />
      ))}
      <path className="scene-line" strokeWidth="1.5" d="M46 11H86 M46 28H92 M46 45H80" />
      <circle className="scene-accent scene-story scene-cho-dot" cx="38" cy="28" r="1.8" />
      <g className="scene-story scene-cho-cur">
        <path fill="var(--text)" d="M94 30v9l2.6-2.4 3.6-.2z" />
      </g>
    </>
  ),
  // A custom app shell fills with modular panels, then goes live.
  "custom-app": (
    <>
      <rect className="scene-paper" x="20" y="4" width="92" height="48" rx="4" />
      <path className="scene-line" strokeWidth="1" opacity="0.45" d="M20 13H112" />
      {[26, 31, 36].map((cx) => (
        <circle key={cx} className="scene-muted" cx={cx} cy="8.5" r="1.3" />
      ))}
      <rect className="scene-empty scene-story scene-ca-nav" x="25" y="17" width="18" height="30" rx="2" />
      <rect className="scene-accent scene-story scene-ca-a" opacity="0.28" x="47" y="17" width="28" height="13" rx="2" />
      <rect className="scene-empty scene-story scene-ca-b" x="79" y="17" width="28" height="13" rx="2" />
      <rect className="scene-empty scene-story scene-ca-c" x="47" y="34" width="60" height="13" rx="2" />
      <path className="scene-line-accent scene-story scene-ca-c" strokeWidth="1.5" d="M52 40.5H82" />
      <circle className="scene-done scene-story scene-ca-live" cx="105" cy="8.5" r="2.3" />
    </>
  ),
  // A database cylinder scans and populates rows in a result table.
  database: (
    <>
      <g>
        <path className="scene-paper" d="M16 15v26c0 3.3 8 6 18 6s18-2.7 18-6V15z" />
        <ellipse className="scene-paper" cx="34" cy="15" rx="18" ry="5.5" />
        <path className="scene-line" strokeWidth="1.3" opacity="0.55" d="M16 24c0 3 8 5.5 18 5.5S52 27 52 24 M16 33c0 3 8 5.5 18 5.5S52 36 52 33" />
        <ellipse className="scene-accent scene-story scene-db-scan" cx="34" cy="24" rx="15" ry="3.5" opacity="0.35" />
      </g>
      <path className="scene-line-accent scene-dash scene-story scene-db-link" strokeWidth="1.6" pathLength={1} d="M54 28H68" />
      <rect className="scene-paper" x="70" y="9" width="46" height="38" rx="3" />
      <path className="scene-line-accent" strokeWidth="1.5" d="M75 16H111" opacity="0.65" />
      {[24, 32, 40].map((y, i) => (
        <g key={y} className={`scene-story scene-db-r${i}`}>
          <circle className={i === 0 ? "scene-accent" : "scene-done"} cx="77" cy={y} r="1.8" />
          <path className="scene-line" strokeWidth="1.5" d={`M83 ${y}H${[108, 102, 106][i]}`} />
        </g>
      ))}
    </>
  ),
  // A request fires left-to-right to an endpoint and a green response bounces back.
  http: (
    <>
      <rect className="scene-paper" x="12" y="14" width="28" height="28" rx="4" />
      <path className="scene-line-accent" strokeWidth="1.6" d="M18 24H30" />
      <path className="scene-line" strokeWidth="1.5" d="M18 31H34" />
      <path className="scene-line" strokeWidth="1.3" strokeDasharray="2 3" opacity="0.45" d="M43 22H89 M43 34H89" />
      <rect className="scene-accent scene-story scene-http-req" x="44" y="19" width="12" height="6" rx="3" />
      <rect className="scene-done scene-story scene-http-res" x="76" y="31" width="12" height="6" rx="3" />
      <g className="scene-story scene-http-srv">
        <rect className="scene-paper" x="92" y="14" width="28" height="28" rx="4" />
        <path className="scene-line" strokeWidth="1.5" d="M98 23H114 M98 29H110 M98 35H114" />
      </g>
      <g className="scene-story scene-http-ok">{doneBadge(118, 15)}</g>
    </>
  ),
  // A document lays out its pages, gets a PDF stamp, and finishes with a check.
  pdf: (
    <>
      <path className="scene-paper" strokeLinejoin="round" d="M38 4h38l12 12v36H38z" />
      <path className="scene-line" strokeWidth="1.3" strokeLinejoin="round" d="M76 4v12h12" />
      <path className="scene-line-accent scene-story scene-pdf-l0" strokeWidth="1.8" d="M46 15H68" />
      <path className="scene-line scene-story scene-pdf-l1" strokeWidth="1.5" d="M46 23H80 M46 29H74" />
      <path className="scene-line scene-story scene-pdf-l2" strokeWidth="1.5" d="M46 35H78" />
      <g className="scene-story scene-pdf-tag">
        <rect className="scene-warm" x="45" y="40" width="24" height="9" rx="2" />
        <text x="57" y="47" textAnchor="middle" fontSize="6.5" fontWeight="700" fontFamily="system-ui" fill="var(--surface)">
          PDF
        </text>
      </g>
      <g className="scene-story scene-pdf-done">{doneBadge(88, 46)}</g>
    </>
  ),
  // A parent agent dispatches work to two helper nodes, which complete and check in.
  subagent: (
    <>
      <path className="scene-line" strokeWidth="1.3" strokeDasharray="2.5 2.5" opacity="0.45" d="M34 28C56 28 62 15 92 15 M34 28C56 28 62 41 92 41" />
      <path className="scene-line-accent scene-dash scene-story scene-sa-out0" strokeWidth="1.8" pathLength={1} d="M34 28C56 28 62 15 92 15" />
      <path className="scene-line-accent scene-dash scene-story scene-sa-out1" strokeWidth="1.8" pathLength={1} d="M34 28C56 28 62 41 92 41" />
      <circle className="scene-paper" cx="25" cy="28" r="9.5" stroke="var(--accent)" strokeWidth="1.6" />
      <circle className="scene-accent" cx="25" cy="28" r="3.6" />
      <g className="scene-story scene-sa-h0">
        <circle className="scene-paper" cx="100" cy="15" r="7.5" stroke="var(--accent)" strokeWidth="1.5" />
        <circle className="scene-accent" cx="100" cy="15" r="2.6" />
      </g>
      <g className="scene-story scene-sa-h1">
        <circle className="scene-paper" cx="100" cy="41" r="7.5" stroke="var(--accent)" strokeWidth="1.5" />
        <circle className="scene-accent" cx="100" cy="41" r="2.6" />
      </g>
      <g className="scene-story scene-sa-ok0">{doneBadge(111, 12)}</g>
      <g className="scene-story scene-sa-ok1">{doneBadge(111, 44)}</g>
    </>
  ),
};

const SCENE_OF: Record<SplitKind, Exclude<ChatStatusKind, SplitKind>> = {
  "image-view": "image",
  // Design reads share the design scene, like image-view (ADR-designs §3.9).
  "design-view": "design",
};

const sceneOf = (kind: ChatStatusKind) => (kind in SCENE_OF ? SCENE_OF[kind as SplitKind] : (kind as Exclude<ChatStatusKind, SplitKind>));

function SceneLayer({ kind, leaving }: { kind: ChatStatusKind; leaving?: boolean }) {
  return (
    <div data-scene={leaving ? undefined : kind} className={`scene-layer ${leaving ? "scene-out" : "scene-in"}`}>
      <svg viewBox="0 0 132 56" className={`h-full w-full ${sceneOf(kind) === "image" ? "scene-focus" : ""}`}>
        {SCENES[sceneOf(kind)]}
      </svg>
    </div>
  );
}

/** Coasts the looping animations under `ref` to a halt while `stopping`, and restores them if the stop doesn't take. */
function useWindDown(ref: RefObject<HTMLElement | null>, stopping: boolean | undefined, scene: ChatStatusKind) {
  useEffect(() => {
    if (!stopping || !ref.current) return;
    const loops = ref.current.getAnimations({ subtree: true }).filter((a) => a.effect?.getTiming().iterations === Infinity);
    const start = performance.now();
    let frame = requestAnimationFrame(function step(now) {
      const rate = Math.max(0, 1 - (now - start) / WIND_DOWN_MS);
      for (const a of loops) a.playbackRate = rate;
      if (rate > 0) frame = requestAnimationFrame(step);
    });
    return () => {
      cancelAnimationFrame(frame);
      for (const a of loops) a.playbackRate = 1;
    };
  }, [ref, stopping, scene]);
}

/** The card's vignette, purely decorative: the status text is what's announced. Hidden when the card is too narrow. */
export function ActivityScene({ current, previous, stopping }: { current: ChatStatusKind; previous?: ChatStatusKind; stopping?: boolean }) {
  const stage = useRef<HTMLDivElement>(null);
  useWindDown(stage, stopping, current);
  return (
    <div
      ref={stage}
      aria-hidden
      data-stopping={stopping || undefined}
      className={`relative h-14 w-[132px] flex-none transition-[filter,opacity] duration-(--motion-progress) motion-reduce:transition-none @max-[420px]:w-[88px] @max-[300px]:hidden ${stopping ? "opacity-50 grayscale" : ""}`}
    >
      {previous && <SceneLayer key={`out-${previous}`} kind={previous} leaving />}
      <SceneLayer key={current} kind={current} />
    </div>
  );
}
