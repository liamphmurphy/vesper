// 16px-grid stroke icons at 1.5px, matching docs/design-system. Decorative by
// default: give the surrounding button an aria-label instead.
const paths = {
  dashboard: <><rect x="2.5" y="2.5" width="4.5" height="4.5" rx="1.2" /><rect x="9" y="2.5" width="4.5" height="4.5" rx="1.2" /><rect x="2.5" y="9" width="4.5" height="4.5" rx="1.2" /><rect x="9" y="9" width="4.5" height="4.5" rx="1.2" /></>,
  inbox: <><path d="M2.5 9.5h3l1 1.8h3l1-1.8h3" /><path d="M2.5 9.5 4.2 3.8c.1-.5.6-.8 1.1-.8h5.4c.5 0 1 .3 1.1.8l1.7 5.7V12a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1z" /></>,
  tickets: <><circle cx="8" cy="8" r="5.5" /><path d="m5.8 8 1.5 1.5 3-3" /></>,
  slides: <><rect x="2.5" y="3" width="11" height="7.5" rx="1.3" /><path d="M8 10.5v2.5M5.5 13.5h5" /></>,
  designs: <><path d="M8 2.5 13.5 8 8 13.5 2.5 8z" /><path d="M8 5.5v5M5.5 8h5" /></>,
  board: <><rect x="2.5" y="2.5" width="11" height="11" rx="2" /><path d="M6.2 2.5v11M9.8 2.5v7" /></>,
  epics: <><path d="M8 2.5 13.5 5.3 8 8.1 2.5 5.3z" /><path d="m2.5 8.2 5.5 2.8 5.5-2.8" /><path d="m2.5 11 5.5 2.8 5.5-2.8" /></>,
  agents: <><rect x="2.5" y="5" width="11" height="8" rx="2.2" /><path d="M8 2.5V5" /><path d="M6 8.6v.8M10 8.6v.8" /></>,
  artifacts: <><path d="M4 2.5h5l3 3v8H4z" /><path d="M9 2.5v3h3" /></>,
  wiki: <><path d="M2.5 3.5h3.8A1.7 1.7 0 0 1 8 5.2v8.3a1.3 1.3 0 0 0-1.3-1.3H2.5z" /><path d="M13.5 3.5H9.7A1.7 1.7 0 0 0 8 5.2v8.3a1.3 1.3 0 0 1 1.3-1.3h4.2z" /></>,
  learn: <><path d="m1.5 6.5 6.5-3 6.5 3-6.5 3z" /><path d="M4.5 8v3c1 1 2.2 1.5 3.5 1.5s2.5-.5 3.5-1.5V8M14.5 6.5v3.5" /></>,
  graph: <><circle cx="8" cy="8" r="1.8" /><circle cx="3.5" cy="4" r="1.3" /><circle cx="12.5" cy="4.5" r="1.3" /><circle cx="11.5" cy="12.5" r="1.3" /><path d="m4.6 4.9 2 1.9M11.4 5.3 9.4 7M10.6 11.4 9.2 9.4" /></>,
  search: <><circle cx="7" cy="7" r="4.5" /><path d="m10.5 10.5 3 3" /></>,
  plus: <path d="M8 3.5v9M3.5 8h9" />,
  chev: <path d="m4.5 6.5 3.5 3.5 3.5-3.5" />,
  chevr: <path d="m6.5 4.5 3.5 3.5-3.5 3.5" />,
  x: <path d="m4 4 8 8M12 4l-8 8" />,
  expand: <path d="M9.5 2.5h4v4M13.5 2.5 9 7M6.5 13.5h-4v-4M2.5 13.5 7 9" />,
  shrink: <path d="M13.5 6.5h-4v-4M9.5 6.5l4-4M2.5 9.5h4v4M6.5 9.5l-4 4" />,
  chevronUp: <path d="m4 10 4-4 4 4" />,
  check: <path d="m3.5 8.5 3 3 6-7" />,
  gear: <><circle cx="8" cy="8" r="2" /><path d="M8 1.8v1.6M8 12.6v1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M1.8 8h1.6M12.6 8h1.6M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1" /></>,
  branch: <><circle cx="4.5" cy="3.5" r="1.5" /><circle cx="4.5" cy="12.5" r="1.5" /><circle cx="11.5" cy="5.5" r="1.5" /><path d="M4.5 5v6M11.5 7c0 2.5-2 3-7 4" /></>,
  pr: <><circle cx="4.5" cy="3.5" r="1.5" /><circle cx="4.5" cy="12.5" r="1.5" /><circle cx="11.5" cy="12.5" r="1.5" /><path d="M4.5 5v6M11.5 11V6.5a2 2 0 0 0-2-2H7.5" /></>,
  lock: <><rect x="3.5" y="7" width="9" height="6.5" rx="1.5" /><path d="M5.5 7V5a2.5 2.5 0 0 1 5 0v2" /></>,
  key: <><circle cx="5.5" cy="10.5" r="2.5" /><path d="m7.3 8.7 5.2-5.2M10.5 5.5l1.5 1.5" /></>,
  code: <path d="m5.5 4.5-3.5 3.5 3.5 3.5M10.5 4.5l3.5 3.5-3.5 3.5" />,
  terminal: <><rect x="2" y="3" width="12" height="10" rx="2" /><path d="m5 7 2 1.5L5 10M8.5 10.5h2.5" /></>,
  msg: <path d="M3 3.5h10a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1H7l-3 2.5V11.5H3a1 1 0 0 1-1-1v-6a1 1 0 0 1 1-1z" />,
  bolt: <path d="M9 2 4 9h4l-1 5 5-7H8z" />,
  play: <path d="M5 3.5v9l7-4.5z" />,
  dollar: <><circle cx="8" cy="8" r="5.5" /><path d="M9.8 6.2c-.3-.6-1-1-1.8-1-1 0-1.8.5-1.8 1.3 0 1.8 3.7 1 3.7 2.9 0 .8-.8 1.4-1.9 1.4-.9 0-1.6-.4-1.9-1M8 4.2v1M8 10.8v1" /></>,
  pause: <path d="M5.5 3.5v9M10.5 3.5v9" />,
  download: <path d="M8 3v8M4.5 7.5 8 11l3.5-3.5M3 13.5h10" />,
  upload: <path d="M8 11V3M4.5 6.5 8 3l3.5 3.5M3 13h10" />,
  printer: <><path d="M4.5 6V2.5h7V6" /><rect x="2.5" y="6" width="11" height="5" rx="1.2" /><path d="M4.5 9.5h7v4h-7z" /></>,
  at: <><circle cx="8" cy="8" r="2.5" /><path d="M10.5 8v1a1.8 1.8 0 0 0 3.5 0V8a6 6 0 1 0-2.4 4.8" /></>,
  server: <><rect x="2.5" y="2.5" width="11" height="4.5" rx="1.2" /><rect x="2.5" y="9" width="11" height="4.5" rx="1.2" /><path d="M5 4.8h.01M5 11.2h.01" /></>,
  users: <><circle cx="6" cy="5.5" r="2.3" /><path d="M2 13c.5-2.2 2-3.4 4-3.4s3.5 1.2 4 3.4" /><path d="M10.5 3.4a2.2 2.2 0 0 1 0 4.2M12 9.8c1 .5 1.7 1.6 2 3.2" /></>,
  sliders: <><path d="M2.5 4.5h7M12.5 4.5h1M2.5 11.5h1M6.5 11.5h7" /><circle cx="11" cy="4.5" r="1.5" /><circle cx="5" cy="11.5" r="1.5" /></>,
  folder: <path d="M2.5 4.5a1 1 0 0 1 1-1h3l1.5 1.5h4.5a1 1 0 0 1 1 1v6a1 1 0 0 1-1 1h-9a1 1 0 0 1-1-1z" />,
  github: <path d="M6 13c-3 1-3-1.5-4.2-1.8M10 14.5v-2.3c0-.7 0-1.2-.4-1.6 2-.2 3.9-1 3.9-4.3a3.3 3.3 0 0 0-.9-2.3 3 3 0 0 0-.1-2.3s-.8-.2-2.5.9a8.5 8.5 0 0 0-4.4 0C3.9 1.5 3.1 1.7 3.1 1.7a3 3 0 0 0-.1 2.3 3.3 3.3 0 0 0-.9 2.3c0 3.3 1.9 4.1 3.9 4.3-.4.4-.5.9-.4 1.6v2.3" />,
  shield: <path d="M8 2 3 4v4c0 3 2.2 5 5 6 2.8-1 5-3 5-6V4z" />,
  refresh: <path d="M13 8a5 5 0 1 1-1.5-3.5M13 2.5v3h-3" />,
  link: <><path d="M7 9a2.5 2.5 0 0 0 3.5 0l2-2A2.5 2.5 0 0 0 9 3.5l-.7.7" /><path d="M9 7a2.5 2.5 0 0 0-3.5 0l-2 2A2.5 2.5 0 0 0 7 12.5l.7-.7" /></>,
  dots: <><circle cx="3.5" cy="8" r="1.2" fill="currentColor" stroke="none" /><circle cx="8" cy="8" r="1.2" fill="currentColor" stroke="none" /><circle cx="12.5" cy="8" r="1.2" fill="currentColor" stroke="none" /></>,
  alert: <><path d="M8 2.5 14 13H2z" /><path d="M8 6.5v3M8 11.3v.2" /></>,
  plug: <><path d="M6 2v3M10 2v3M4 5h8v2.5a4 4 0 0 1-8 0zM8 11.5V14" /></>,
  clock: <><circle cx="8" cy="8" r="5.5" /><path d="M8 5v3.2l2 1.3" /></>,
  activity: <path d="M1.75 8h2.5l1.6-4.25 3.1 8.5 1.8-4.25h3.5" />,
  edit: <path d="M10.5 3 13 5.5 6 12.5H3.5V10z" />,
  history: <><path d="M2.5 8a5.5 5.5 0 1 0 1.6-3.9M2.5 2.5v2.6h2.6" /><path d="M8 5v3l2 1.5" /></>,
  sidebar: <><rect x="2.5" y="3" width="11" height="10" rx="2" /><path d="M6.5 3v10" /></>,
  briefcase: <><rect x="2.5" y="5" width="11" height="8" rx="1.5" /><path d="M6 5V3.5h4V5M2.5 8.5h11" /></>,
  bookmark: <path d="M4.5 2.5h7v11L8 11l-3.5 2.5z" />,
  trash: <path d="M3 4.5h10M6.5 4.5V3h3v1.5M4.5 4.5l.6 8.5h5.8l.6-8.5" />,
  sun: <><circle cx="8" cy="8" r="2.8" /><path d="M8 1.8v1.4M8 12.8v1.4M1.8 8h1.4M12.8 8h1.4M3.6 3.6l1 1M11.4 11.4l1 1M3.6 12.4l1-1M11.4 4.6l1-1" /></>,
  moon: <path d="M13 9.5A5.5 5.5 0 0 1 6.5 3a5.5 5.5 0 1 0 6.5 6.5z" />,
  bulb: <><path d="M6 13.5h4" /><path d="M6 11.5c0-1.3-2-2.2-2-4.8a4 4 0 0 1 8 0c0 2.6-2 3.5-2 4.8z" /></>,
  dice: <><rect x="2.5" y="2.5" width="11" height="11" rx="2.2" /><circle cx="5.5" cy="5.5" r=".6" fill="currentColor" /><circle cx="10.5" cy="5.5" r=".6" fill="currentColor" /><circle cx="8" cy="8" r=".6" fill="currentColor" /><circle cx="5.5" cy="10.5" r=".6" fill="currentColor" /><circle cx="10.5" cy="10.5" r=".6" fill="currentColor" /></>,
  gamepad: <><path d="M5 5h6a3.5 3.5 0 0 1 3.4 4.2l-.4 1.9a1.6 1.6 0 0 1-2.8.7L9.8 10.5H6.2l-1.4 1.3a1.6 1.6 0 0 1-2.8-.7l-.4-1.9A3.5 3.5 0 0 1 5 5z" /><path d="M5.5 7v2M4.5 8h2" /><circle cx="10.6" cy="8" r=".6" fill="currentColor" /></>,
  compass: <><circle cx="8" cy="8" r="5.5" /><path d="m10.5 5.5-1.4 3.6-3.6 1.4 1.4-3.6z" /></>,
  dumbbell: <path d="M5.5 8h5M4 5v6M2.5 6.5v3M12 5v6M13.5 6.5v3" />,
  audio: <path d="M2.5 6.5v3M5.2 4.5v7M8 2.5v11M10.8 4.5v7M13.5 6.5v3" />,
  film: <><rect x="2.5" y="3" width="11" height="10" rx="1.5" /><path d="m6.7 6 3.3 2-3.3 2z" /></>,
  library: <><rect x="2.5" y="3" width="11" height="10" rx="1.5" /><circle cx="6" cy="6.5" r="1.2" /><path d="m2.5 11 3.2-3 2.6 2.4 1.7-1.6 3.5 3.2" /></>,
  compare: <><path d="M8 2.5v11" /><rect x="2" y="4" width="4" height="8" rx="1" /><rect x="10" y="4" width="4" height="8" rx="1" /></>,
} as const;

export type IconName = keyof typeof paths;

export function Icon({
  name,
  size = 16,
  strokeWidth = 1.5,
  className,
}: {
  name: IconName;
  size?: number;
  strokeWidth?: number;
  className?: string;
}) {
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth={strokeWidth}
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      className={className ? `flex-none ${className}` : "flex-none"}
    >
      {paths[name]}
    </svg>
  );
}

export { Mark } from "./mark";
