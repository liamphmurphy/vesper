import type { CSSProperties, ReactNode } from "react";
import type { ChatStatusKind, ChatStep } from "@/lib/chat-ui";

/*
 * The step rail's 16px glyphs: one small picture per kind of work. Only the step under way
 * moves (one or two parts, so it never competes with the card's scene); a finished step
 * holds the still frame in the done colour. Each element's resting style is that still
 * frame, and `.glyph-live` parts only show while the step is under way. Styles live in globals.css.
 */

const delay = (seconds: number): CSSProperties => ({ animationDelay: `${seconds}s` });

const dots = (cls: string, xs: number[], cy: number, r: number, step: number) =>
  xs.map((cx, i) => <circle key={cx} className={`glyph-a ${cls}`} style={delay(i * step)} cx={cx} cy={cy} r={r} fill="currentColor" />);

const GLYPHS: Record<ChatStatusKind, ReactNode> = {
  thinking: dots("glyph-bob", [3.5, 8, 12.5], 8.5, 1.6, 0.15),
  // A fork out of the step just finished: the way on draws, and where it leads lights up.
  "next-step": (
    <>
      <circle cx="3" cy="8" r="1.8" fill="currentColor" />
      <path className="glyph-s" opacity=".45" strokeWidth="1.1" d="M4.5 7.2C7 5.5 8.5 3.5 12.5 3.5M4.5 8.8C7 10.5 8.5 12.5 12.5 12.5" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M5 8h6.5" />
      <circle className="glyph-a glyph-tile glyph-live" cx="13.5" cy="8" r="1.6" fill="currentColor" />
    </>
  ),
  "reading-code": (
    <>
      <rect className="glyph-s" x="2.5" y="1.5" width="11" height="13" rx="1.5" />
      <path className="glyph-s" d="M5 5H11M5 8H10M5 11H11" />
      <rect className="glyph-a glyph-scan glyph-live" x="3.5" y="3.5" width="9" height="3" rx="1" fill="currentColor" opacity=".35" />
    </>
  ),
  "searching-code": (
    <>
      <path className="glyph-s" d="M2 3.5h8M2 7h12M2 10.5h7M2 14h10" strokeWidth="1.1" opacity=".5" />
      <g className="glyph-a glyph-sweep">
        <circle className="glyph-s glyph-knock" cx="7.5" cy="7" r="3" />
        <path className="glyph-s" d="M9.7 9.2l2.3 2.3" />
      </g>
    </>
  ),
  "writing-code": (
    <>
      <path className="glyph-s" d="M2.5 4H11M2.5 8H13.5" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M2.5 12H9" />
      <rect className="glyph-a glyph-caret glyph-live" x="10" y="10" width="1.3" height="4" fill="currentColor" />
    </>
  ),
  "writing-reply": (
    <>
      <path className="glyph-s" d="M2.5 3.5A1.5 1.5 0 0 1 4 2h8a1.5 1.5 0 0 1 1.5 1.5v6A1.5 1.5 0 0 1 12 11H6.5L4 13.5V11a1.5 1.5 0 0 1-1.5-1.5v-6z" />
      <path className="glyph-s" d="M5 5.5h6" strokeWidth="1.2" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M5 8h4.5" strokeWidth="1.2" />
    </>
  ),
  tests: [3.5, 8, 12.5].map((cx, i) => (
    <g key={cx}>
      <circle className="glyph-s" cx={cx} cy="8" r="2.2" strokeWidth="1.1" />
      <circle className="glyph-a glyph-fill" style={delay(i * 0.3)} cx={cx} cy="8" r="2.2" fill="currentColor" />
    </g>
  )),
  build: (
    <>
      <g className="glyph-a glyph-spin">
        <circle cx="8" cy="8" r="5" fill="none" stroke="currentColor" strokeWidth="2.6" strokeDasharray="2.6 2.63" />
        <circle className="glyph-s" cx="8" cy="8" r="3.4" />
      </g>
      <circle cx="8" cy="8" r="1.2" fill="currentColor" />
    </>
  ),
  install: (
    <>
      <path className="glyph-s" d="M2.5 10.5v3h11v-3" />
      <path className="glyph-s glyph-a glyph-drop" d="M8 2v7.5M5 6.8l3 3 3-3" />
    </>
  ),
  terminal: (
    <>
      <rect className="glyph-s" x="1.5" y="2.5" width="13" height="11" rx="1.5" />
      <path className="glyph-s" d="M4.5 6l2 2-2 2" />
      <rect className="glyph-a glyph-blink" x="8" y="9.6" width="3.6" height="1.4" fill="currentColor" />
    </>
  ),
  github: (
    <g className="glyph-a glyph-spin">
      <path className="glyph-s" d="M13.2 6.5A5.5 5.5 0 0 0 3.4 5M3.4 2.4V5h2.6M2.8 9.5a5.5 5.5 0 0 0 9.8 1.5M12.6 13.6V11H10" />
    </g>
  ),
  commit: (
    <>
      <path className="glyph-s" d="M1 8h4.3M10.7 8H15" />
      <circle className="glyph-s" cx="8" cy="8" r="2.6" />
      <circle className="glyph-a glyph-ring glyph-live" cx="8" cy="8" r="2.6" fill="none" stroke="currentColor" strokeWidth="1" />
    </>
  ),
  push: (
    <>
      <path className="glyph-s" d="M2.5 2.5h11" />
      <path className="glyph-s glyph-a glyph-rise" d="M8 14V6M5 8.7l3-3 3 3" />
    </>
  ),
  "pull-request": (
    <>
      <circle className="glyph-s" cx="4" cy="3.5" r="1.6" />
      <circle className="glyph-s" cx="4" cy="12.5" r="1.6" />
      <circle className="glyph-s" cx="12" cy="12.5" r="1.6" />
      <path className="glyph-s" d="M4 5.2v5.6" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M12 10.8V7a3 3 0 0 0-3-3H6.5" />
    </>
  ),
  "repo-history": (
    <>
      <path className="glyph-s" d="M4.5 2v12" />
      {[3, 8, 13].map((y, i) => (
        <g key={y}>
          <circle className="glyph-a glyph-tile" style={delay(i * 0.5)} cx="4.5" cy={y} r="1.7" fill="currentColor" />
          <path className="glyph-s" d={`M8 ${y}h${[6, 4.5, 5.5][i]}`} strokeWidth="1.2" />
        </g>
      ))}
    </>
  ),
  web: (
    <>
      <circle className="glyph-s" cx="8" cy="8" r="6" />
      <path className="glyph-s" d="M2 8h12" />
      <ellipse className="glyph-s glyph-a glyph-globe" cx="8" cy="8" rx="2.8" ry="6" />
    </>
  ),
  "web-page": (
    <>
      <rect className="glyph-s" x="1.5" y="2" width="13" height="12" rx="1.5" />
      <path className="glyph-s" d="M1.5 5h13" />
      <svg x="3" y="6" width="10" height="7" viewBox="0 0 10 7" overflow="hidden">
        <path className="glyph-s glyph-a glyph-scroll" d="M0 1.5h8M0 4.5h6M0 7.5h8M0 10.5h5M0 13.5h8" strokeWidth="1.1" />
      </svg>
    </>
  ),
  wiki: (
    <>
      <path className="glyph-s" d="M8 4C6 3 4 3 1.5 3.5V13c2.5-.5 4.5-.5 6.5.5 2-1 4-1 6.5-.5V3.5C12 3 10 3 8 4zM8 4v9.5" />
      <path className="glyph-a glyph-flip glyph-live" d="M8 4.3c2-.9 3.8-.9 5.6-.5V12.4c-1.8-.4-3.6-.3-5.6.6z" fill="currentColor" opacity=".3" />
    </>
  ),
  tickets: (
    <>
      <rect className="glyph-s" x="1.5" y="2" width="5.5" height="12" rx="1" strokeWidth="1.1" />
      <rect className="glyph-s" x="9" y="2" width="5.5" height="12" rx="1" strokeWidth="1.1" />
      <rect className="glyph-a glyph-hop" x="2.8" y="4" width="3" height="3" rx=".6" fill="currentColor" />
    </>
  ),
  "ticket-lookup": (
    <>
      <circle className="glyph-s" cx="4" cy="8" r="2.5" />
      <rect className="glyph-s" x="8.5" y="3" width="6" height="4" rx=".8" strokeWidth="1.1" />
      <rect className="glyph-a glyph-pull glyph-live" x="8.5" y="9" width="6" height="4" rx=".8" fill="currentColor" />
    </>
  ),
  runs: [
    [4, 1.7],
    [8, 2.6],
    [12, 2.1],
  ].map(([y, seconds]) => (
    <g key={y}>
      <path className="glyph-s" d={`M2 ${y}h12`} opacity=".25" />
      <path className="glyph-s glyph-a glyph-grow" style={{ animationDuration: `${seconds}s` }} d={`M2 ${y}h12`} />
    </g>
  )),
  workflow: (
    <>
      <path className="glyph-s" d="M4.5 8h2.5M9 8h2.5" strokeWidth="1.1" />
      {dots("glyph-tile", [2.5, 8, 13.5], 8, 2.1, 0.45)}
    </>
  ),
  connector: (
    <>
      <rect className="glyph-s" x="9.5" y="4" width="5" height="8" rx="1.2" />
      <g className="glyph-a glyph-plug">
        <rect className="glyph-s" x="1.5" y="4.5" width="4.5" height="7" rx="1.2" />
        <path className="glyph-s" d="M6 6.5h2M6 9.5h2" />
      </g>
      <circle className="glyph-a glyph-blink glyph-live" cx="8.7" cy="2.5" r=".9" fill="currentColor" />
    </>
  ),
  // A key: the request carries one of the person's secrets, added by Vesper.
  secret: (
    <>
      <circle className="glyph-s" cx="5" cy="8" r="3" />
      <path className="glyph-s glyph-a glyph-plug" d="M8 8h6.5M12 8v2.5M14.5 8v2" />
      <circle className="glyph-a glyph-blink glyph-live" cx="5" cy="8" r=".9" fill="currentColor" />
    </>
  ),
  video: (
    <>
      <rect className="glyph-s" x="1.5" y="2" width="13" height="9" rx="1.5" />
      <path d="M6.8 4.5v4l3.3-2z" fill="currentColor" />
      <path className="glyph-s" d="M2 14h12" opacity=".35" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M2 14h12" />
    </>
  ),
  image: [
    [2, 2, 0],
    [8.5, 2, 0.4],
    [2, 8.5, 1.2],
    [8.5, 8.5, 0.8],
  ].map(([x, y, wait]) => <rect key={`${x}-${y}`} className="glyph-a glyph-tile" style={delay(wait)} x={x} y={y} width="5.5" height="5.5" rx="1" fill="currentColor" />),
  "image-view": (
    <g className="glyph-a glyph-eye">
      <path className="glyph-s" d="M1.5 8S4 3.5 8 3.5 14.5 8 14.5 8 12 12.5 8 12.5 1.5 8 1.5 8z" />
      <circle cx="8" cy="8" r="2.2" fill="currentColor" />
    </g>
  ),
  canvas: (
    <>
      <rect className="glyph-s" x="1.5" y="1.5" width="13" height="13" rx="1.5" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M4 10.5c1.5-4 3-4 4-1.5s2.5 2.5 4-3" />
    </>
  ),
  "design-view": (
    <>
      <rect className="glyph-s" x="1.5" y="3" width="4.5" height="10" rx="1" />
      <rect className="glyph-s" x="10" y="3" width="4.5" height="10" rx="1" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M6 8H10" />
    </>
  ),
  playground: (
    <>
      <rect className="glyph-s" x="1.5" y="2.5" width="13" height="11" rx="1.5" />
      <path className="glyph-s" d="M1.5 5.5H14.5" />
      <path d="M6.5 7.5v4l3.5-2z" fill="currentColor" />
      <circle className="glyph-a glyph-blink glyph-live" cx="12" cy="4" r="0.9" fill="currentColor" />
    </>
  ),
  design: (
    <>
      <rect className="glyph-s" x="1.5" y="1.5" width="13" height="13" rx="1.5" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M4 10.5c1.5-4 3-4 4-1.5s2.5 2.5 4-3" />
    </>
  ),
  "canvas-comment": (
    <>
      <path className="glyph-s" d="M2 3.5a1.5 1.5 0 0 1 1.5-1.5h9A1.5 1.5 0 0 1 14 3.5v6a1.5 1.5 0 0 1-1.5 1.5H7l-3 3v-3h-.5A1.5 1.5 0 0 1 2 9.5z" />
      {dots("glyph-bob", [5.2, 8, 10.8], 6.5, 1, 0.15)}
    </>
  ),
  memory: (
    <>
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M3 12L8 4l5 7" strokeWidth="1.1" />
      <circle cx="3" cy="12" r="1.8" fill="currentColor" />
      <circle cx="8" cy="4" r="2" fill="currentColor" />
      <circle cx="13" cy="11" r="1.8" fill="currentColor" />
    </>
  ),
  "memory-save": (
    <>
      <path className="glyph-s" d="M3.5 3h9v11l-4.5-3-4.5 3z" />
      <g className="glyph-a glyph-pin glyph-live">
        <path className="glyph-s" d="M8 1v4" />
        <path d="M6.5 3.5L8 5.5l1.5-2z" fill="currentColor" />
      </g>
    </>
  ),
  "chat-history": (
    <>
      <path className="glyph-s" d="M2 3.5A1.5 1.5 0 0 1 3.5 2h9A1.5 1.5 0 0 1 14 3.5v5A1.5 1.5 0 0 1 12.5 10H7l-3 3v-3h-.5A1.5 1.5 0 0 1 2 8.5z" opacity=".5" />
      <g className="glyph-a glyph-sweep">
        <circle className="glyph-s glyph-knock" cx="8" cy="6" r="2.6" />
        <path className="glyph-s" d="M9.9 7.9l2 2" />
      </g>
    </>
  ),
  "repo-search": (
    <>
      <rect className="glyph-s" x="2" y="1.5" width="8" height="11" rx="1" />
      <path className="glyph-s" d="M4.2 1.5v11" />
      <g className="glyph-a glyph-sweep">
        <circle className="glyph-s glyph-knock" cx="10.5" cy="10" r="2.6" />
        <path className="glyph-s" d="M12.4 11.9l2 2" />
      </g>
    </>
  ),
  "repo-attach": (
    <>
      <path className="glyph-s" d="M1.5 4.5h4l1.5 1.5h7.5v8h-13z" />
      <rect className="glyph-a glyph-dock" x="6" y="8" width="4" height="4" rx=".8" fill="currentColor" />
    </>
  ),
  "video-render": (
    <>
      <rect className="glyph-s" x="1.5" y="3" width="13" height="10" rx="1.2" />
      {[3.3, 6.7, 10.1].map((x, i) => (
        <rect key={x} className="glyph-a glyph-tile" style={delay(i * 0.35)} x={x} y="5.2" width="2.6" height="5.6" rx=".5" fill="currentColor" />
      ))}
    </>
  ),
  "audio-render": (
    <>
      {[
        [2.2, 6, 4],
        [5.4, 3.5, 9],
        [8.6, 2.5, 11],
        [11.8, 5, 6],
      ].map(([x, y, h], i) => (
        <rect key={x} className="glyph-a glyph-bar" style={delay(i * 0.3)} x={x} y={y} width="2" height={h} rx="1" fill="currentColor" />
      ))}
    </>
  ),
  finance: (
    <>
      <path className="glyph-s" d="M1.5 14h13" />
      {[
        [2.5, 8.5, 5],
        [6.7, 4.5, 9],
        [10.9, 6.5, 7],
      ].map(([x, y, h], i) => (
        <rect key={x} className="glyph-a glyph-bar" style={delay(i * 0.3)} x={x} y={y} width="2.6" height={h} rx=".5" fill="currentColor" />
      ))}
    </>
  ),
  "finance-sort": (
    <>
      <path className="glyph-s" d="M1.5 3h6M1.5 6.5h4" />
      <path className="glyph-s" d="M9 8.5v5.5h5.5V8.5" />
      <rect className="glyph-a glyph-sort" x="10.25" y="10.5" width="3" height="2.4" rx=".5" fill="currentColor" />
    </>
  ),
  persona: (
    <>
      <circle className="glyph-s" cx="7" cy="5.5" r="2.7" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M2 14.5c0-3 2.2-5 5-5s5 2 5 5" />
      <path className="glyph-a glyph-blink glyph-live" fill="currentColor" d="M13.5 1l.5 1.5 1.5.5-1.5.5-.5 1.5-.5-1.5-1.5-.5 1.5-.5z" />
    </>
  ),
  schedule: (
    <>
      <circle className="glyph-s" cx="8" cy="8" r="6.2" />
      <path className="glyph-s" d="M8 8l2.6 1.6" />
      <path className="glyph-s glyph-a glyph-hand" d="M8 8V3.6" />
    </>
  ),
  learning: (
    <>
      <path className="glyph-s" d="M1 6L8 3l7 3-7 3z" />
      <path className="glyph-s" d="M4.3 7.6v3.2c0 1 1.7 2 3.7 2s3.7-1 3.7-2V7.6" />
      <path className="glyph-s glyph-a glyph-swing" d="M14 6.5v4" />
    </>
  ),
  research: (
    <>
      <path className="glyph-s" d="M3 1.5h6.5l3 3v10H3z" />
      <path className="glyph-s" d="M5.2 7.5h5" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M5.2 10.5h3.6" />
      <circle className="glyph-a glyph-blink glyph-live" cx="10.6" cy="9.6" r=".9" fill="currentColor" />
    </>
  ),
  space: (
    <>
      <rect className="glyph-s" x="1.5" y="4" width="13" height="10" rx="1.5" strokeDasharray="2.2 1.6" />
      <path className="glyph-s" d="M1.5 4V2.5h4.5l1 1.5" />
      {[4, 8.8].map((x, i) => (
        <rect key={x} className="glyph-a glyph-fill" style={delay(i * 0.3)} x={x} y="7.5" width="3.2" height="4" rx=".5" fill="currentColor" />
      ))}
    </>
  ),
  "saved-links": (
    <>
      <path className="glyph-s" d="M6.6 9.4L5 11a2.3 2.3 0 0 1-3.2-3.2l1.6-1.6a2.3 2.3 0 0 1 3.2 0" />
      <path className="glyph-s" d="M9.4 6.6L11 5a2.3 2.3 0 0 1 3.2 3.2l-1.6 1.6a2.3 2.3 0 0 1-3.2 0" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M6.2 9.8l3.6-3.6" />
    </>
  ),
  // A folder whose name is being read.
  projects: (
    <>
      <path className="glyph-s" d="M1.5 4.5V13a1 1 0 0 0 1 1h11a1 1 0 0 0 1-1V6a1 1 0 0 0-1-1H8L6.5 3h-4a1 1 0 0 0-1 1.5z" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M4.5 9.5h7" />
    </>
  ),
  // Books on a shelf; the middle one is being pulled.
  library: (
    <>
      <path className="glyph-s" d="M1.5 14.5h13" />
      <rect className="glyph-s" x="2.5" y="3.5" width="2.6" height="11" rx=".5" />
      <rect className="glyph-s glyph-a glyph-bob" x="6.3" y="5.5" width="2.6" height="9" rx=".5" />
      <path className="glyph-s" d="M10.2 5.6l2.4-.7 2.4 9-2.4.6z" />
    </>
  ),
  // A tray with an item dropping in.
  inbox: (
    <>
      <path className="glyph-s" d="M1.5 9.5l2-6h9l2 6" />
      <path className="glyph-s" d="M1.5 9.5h3.5l1 2h4l1-2h3.5v4.5h-13z" />
      <path className="glyph-s glyph-a glyph-drop glyph-live" d="M5.5 6.5h5" />
    </>
  ),
  chart: (
    <>
      <path className="glyph-s" d="M2 1.5v12.5h12.5" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M4.5 11l3-3.5 2.5 2 4-5" />
    </>
  ),
  diagram: (
    <>
      <path className="glyph-s" opacity=".45" d="M3.5 1.5v13M12.5 1.5v13" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M4.5 5H11.5" />
      <path className="glyph-s glyph-a glyph-draw" style={delay(0.6)} pathLength={1} d="M11.5 10.5H4.5" />
    </>
  ),
  app: (
    <>
      <rect className="glyph-s" x="1.5" y="2" width="13" height="12" rx="1.5" />
      <path className="glyph-s" d="M1.5 5h13" />
      <path className="glyph-s" opacity=".4" d="M4 10.5h8" />
      <circle className="glyph-a glyph-slide" cx="5" cy="10.5" r="1.6" fill="currentColor" />
    </>
  ),
  "custom-app": (
    <>
      <rect className="glyph-s" x="1.5" y="2" width="13" height="12" rx="1.5" />
      <path className="glyph-s" d="M1.5 5h13" />
      {[
        [3.5, 7, 3.5, 5, 0],
        [8.5, 7, 4, 2.2, 0.3],
        [8.5, 10.3, 4, 1.8, 0.6],
      ].map(([x, y, w, h, wait]) => (
        <rect key={`${x}-${y}`} className="glyph-a glyph-tile" style={delay(wait)} x={x} y={y} width={w} height={h} rx=".5" fill="currentColor" />
      ))}
    </>
  ),
  database: (
    <>
      <ellipse className="glyph-s" cx="8" cy="4" rx="5.5" ry="2" />
      <path className="glyph-s" d="M2.5 4v8c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2V4" />
      <path className="glyph-s glyph-a glyph-tile" d="M2.5 8c0 1.1 2.5 2 5.5 2s5.5-.9 5.5-2" />
    </>
  ),
  http: (
    <>
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M2 5.5h11.5M10.5 3l3 2.5-3 2.5" />
      <path className="glyph-s glyph-a glyph-draw" style={delay(0.5)} pathLength={1} d="M14 10.5H2.5M5.5 8l-3 2.5 3 2.5" />
    </>
  ),
  pdf: (
    <>
      <path className="glyph-s" d="M3 1.5h6.5l3.5 3.5v9.5H3z" />
      <path className="glyph-s" d="M9.5 1.5V5H13" strokeWidth="1.1" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M5.5 8.5h5M5.5 11.5h3.5" />
    </>
  ),
  subagent: (
    <>
      <circle className="glyph-s" cx="3.5" cy="8" r="2" />
      <path className="glyph-s glyph-a glyph-draw" pathLength={1} d="M5.5 7.2L10.5 4.2M5.5 8.8L10.5 11.8" strokeWidth="1.2" />
      <circle className="glyph-a glyph-tile" cx="12.5" cy="3.5" r="1.8" fill="currentColor" />
      <circle className="glyph-a glyph-tile" style={delay(0.45)} cx="12.5" cy="12.5" r="1.8" fill="currentColor" />
    </>
  ),
  choices: (
    <>
      {[3.5, 8, 12.5].map((cy) => (
        <circle key={cy} className="glyph-s" cx="3.5" cy={cy} r="1.7" />
      ))}
      <path className="glyph-s" strokeWidth="1.1" d="M7 3.5h7M7 8h5.5M7 12.5h6.5" />
      <circle className="glyph-a glyph-choose" cx="3.5" cy="8" r=".9" fill="currentColor" />
    </>
  ),
};

const FAILED = (
  <g className="glyph-a glyph-shake">
    <circle className="glyph-s" cx="8" cy="8" r="6" />
    <path className="glyph-s" d="M5.8 5.8l4.4 4.4M10.2 5.8l-4.4 4.4" />
  </g>
);

const CHECK = <path className="glyph-s" d="M4.5 8.3l2.3 2.3 4.7-5" strokeWidth="1.8" />;

/**
 * A step's marker in the rail: a dashed ring while planned, the kind's glyph once its work
 * starts (moving while under way, unless the person pressed Stop), and a cross when it failed.
 * A step with no kind yet keeps the plain dot and check.
 */
export function StepGlyph({ step, stopping }: { step: Pick<ChatStep, "kind" | "state">; stopping?: boolean }) {
  const { kind, state } = step;
  if (state === "planned") return <span aria-hidden className="size-4 flex-none rounded-full border border-dashed border-border-strong" />;
  if (state === "active" && !kind) return <span aria-hidden className={`size-4 flex-none rounded-full bg-accent ${stopping ? "" : "motion-safe:animate-pulse"}`} />;
  const body = state === "failed" ? FAILED : kind ? GLYPHS[kind] : CHECK;
  return (
    <svg aria-hidden viewBox="0 0 16 16" data-glyph={state === "failed" ? "failed" : (kind ?? "done")} className={`step-glyph size-4 flex-none overflow-visible ${state}${stopping ? " stopped" : ""}`}>
      {body}
    </svg>
  );
}
