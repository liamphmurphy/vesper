/**
 * The Slides deck schema (ADR: Slides deck model and export). The server
 * (server/internal/deck) validates the same shape; keep the two in step.
 */

export const W = 1920;
export const H = 1080;

export type Slot = "sans" | "serif" | "mono";
export type FontRef = "heading" | "body" | Slot;
export type ThemeColor = "background" | "text" | "heading" | "accent" | "accent2" | "muted" | "surface";
/** A theme colour name or a literal #RRGGBB. */
export type ColorRef = ThemeColor | string;

/** A two-stop linear gradient; angle is degrees clockwise from left-to-right (90 runs top to bottom). */
export type Gradient = { type: "linear"; angle: number; stops: [ColorRef, ColorRef] };
/** A shape's fill or a slide's background: a colour or a gradient. */
export type Fill = ColorRef | Gradient;
export type Dash = "solid" | "dash" | "dot" | "dashDot" | "longDash";
/** A fill with its colours resolved to #RRGGBB. */
export type Paint = string | { angle: number; stops: [string, string] };

export type Run = { text: string; size: number; bold?: boolean; italic?: boolean; underline?: boolean; strike?: boolean; color?: ColorRef; highlight?: ColorRef; font?: FontRef };
/** lineSpacing multiplies the default line height (0.8–3; unset is 1). */
export type Paragraph = { runs: Run[]; align?: "left" | "center" | "right" | "justify"; bullet?: "disc" | "number"; level?: number; spaceBefore?: number; lineSpacing?: number };
export type TextBox = { paragraphs: Paragraph[]; valign?: "top" | "middle" | "bottom" };
export type Frame = { x: number; y: number; w: number; h: number };
export type Crop = { l: number; t: number; r: number; b: number };
export type Placeholder = "title" | "subtitle" | "body" | "body2" | "body3" | "label" | "label2" | "image";

type Common = { id: string; frame: Frame; rotation?: number; placeholder?: Placeholder };
export type TextElement = Common & { type: "text" } & TextBox;
/** PowerPoint prstGeom names; server/internal/deck Shapes and geometry.ts SHAPES list the same set. */
export type ShapeKind =
  | "rect" | "roundRect" | "ellipse"
  | "triangle" | "rtTriangle" | "diamond" | "pentagon" | "hexagon" | "octagon"
  | "rightArrow" | "leftArrow" | "upArrow" | "downArrow" | "chevron" | "homePlate"
  | "wedgeRectCallout" | "wedgeRoundRectCallout"
  | "star5" | "plus" | "donut" | "heart";
export type ShapeElement = Common & { type: "shape"; shape: ShapeKind; fill?: Fill; fillOpacity?: number; stroke?: ColorRef; strokeWidth?: number; strokeOpacity?: number; dash?: Dash; radius?: number; text?: TextBox };
export type LineElement = Common & { type: "line"; stroke: ColorRef; strokeWidth: number; strokeOpacity?: number; dash?: Dash; endArrow?: boolean; startArrow?: boolean };
export type ImageElement = Common & { type: "image"; asset: string; crop?: Crop; alt?: string; opacity?: number };
/** An element that isn't a group: what a group can hold. */
export type LeafElement = TextElement | ShapeElement | LineElement | ImageElement;
/**
 * Two or more elements that move and resize together. Children are in slide
 * coordinates and stacking order; the frame is their box (the server derives
 * it). Groups don't nest, rotate or hold placeholders.
 */
export type GroupElement = Common & { type: "group"; elements: LeafElement[] };
export type Element = LeafElement | GroupElement;

export type Layout = "title" | "title-body" | "two-column" | "image-right" | "section" | "blank" | "quote" | "big-number" | "three-column" | "comparison" | "image-full" | "image-left" | "agenda" | "closing";
export type Slide = { id: string; layout: Layout; background?: { color: Fill }; notes?: string; hidden?: boolean; elements: Element[] };
export type Theme = { name: string; fonts: { heading: Slot; body: Slot }; colors: Record<ThemeColor, string> };
export type Asset = { mime: "image/png" | "image/jpeg"; w: number; h: number; alt?: string };
export type Deck = { schema: 1; size: { w: number; h: number }; theme: Theme; assets: Record<string, Asset>; slides: Slide[] };

export const THEME_COLORS: ThemeColor[] = ["background", "text", "heading", "accent", "accent2", "muted", "surface"];
export const LAYOUTS: { id: Layout; label: string }[] = [
  { id: "title", label: "Title" },
  { id: "title-body", label: "Title and body" },
  { id: "two-column", label: "Two columns" },
  { id: "image-right", label: "Text and image" },
  { id: "section", label: "Section" },
  { id: "blank", label: "Blank" },
  { id: "quote", label: "Quote" },
  { id: "big-number", label: "Big number" },
  { id: "three-column", label: "Three columns" },
  { id: "comparison", label: "Comparison" },
  { id: "image-full", label: "Full-bleed image" },
  { id: "image-left", label: "Image and text" },
  { id: "agenda", label: "Agenda" },
  { id: "closing", label: "Closing" },
];
/** Layouts added in the second Slides epic; the picker badges them. */
export const NEW_LAYOUTS = new Set<Layout>(["quote", "big-number", "three-column", "comparison", "image-full", "image-left", "agenda", "closing"]);

/** The built-in themes; server/internal/deck/templates.go has the same values. */
export const THEMES: Record<string, Theme> = {
  light: { name: "Light", fonts: { heading: "sans", body: "sans" }, colors: { background: "#FFFFFF", text: "#1F2328", heading: "#111418", accent: "#3B6FE0", accent2: "#E8A33D", muted: "#5F6673", surface: "#F3F5F9" } },
  dark: { name: "Dark", fonts: { heading: "sans", body: "sans" }, colors: { background: "#14151A", text: "#E6E7EB", heading: "#FFFFFF", accent: "#8B9CFF", accent2: "#F2B35E", muted: "#9AA0AE", surface: "#1F2129" } },
  paper: { name: "Paper", fonts: { heading: "serif", body: "serif" }, colors: { background: "#FBF8F1", text: "#2B2723", heading: "#1A1612", accent: "#A2462E", accent2: "#3F6B5C", muted: "#655D53", surface: "#F1EBDD" } },
  contrast: { name: "Contrast", fonts: { heading: "sans", body: "serif" }, colors: { background: "#FFFFFF", text: "#000000", heading: "#000000", accent: "#D7263D", accent2: "#1B998B", muted: "#4A4A4A", surface: "#F0F0F0" } },
  dusk: { name: "Dusk", fonts: { heading: "sans", body: "sans" }, colors: { background: "#1B1830", text: "#E4E0F5", heading: "#FFFFFF", accent: "#B79CFF", accent2: "#F4A261", muted: "#A9A3C4", surface: "#262240" } },
  ocean: { name: "Ocean", fonts: { heading: "sans", body: "sans" }, colors: { background: "#0B2540", text: "#D6E4F0", heading: "#FFFFFF", accent: "#4CC9F0", accent2: "#FFD166", muted: "#9DB4CB", surface: "#13355A" } },
  forest: { name: "Forest", fonts: { heading: "serif", body: "sans" }, colors: { background: "#F3F6EF", text: "#1E2A20", heading: "#14301B", accent: "#2F6B3A", accent2: "#B5651D", muted: "#56635A", surface: "#E3EADC" } },
  sunset: { name: "Sunset", fonts: { heading: "sans", body: "sans" }, colors: { background: "#FFF4EC", text: "#3A1F2B", heading: "#5A1A33", accent: "#D1495B", accent2: "#7B4FA0", muted: "#7A5560", surface: "#FBE3D3" } },
  mono: { name: "Mono", fonts: { heading: "mono", body: "sans" }, colors: { background: "#FAFAFA", text: "#1A1A1A", heading: "#000000", accent: "#111111", accent2: "#777777", muted: "#5C5C5C", surface: "#EDEDED" } },
  blueprint: { name: "Blueprint", fonts: { heading: "mono", body: "sans" }, colors: { background: "#123A6B", text: "#E8F1FB", heading: "#FFFFFF", accent: "#9BD1FF", accent2: "#FFE08A", muted: "#B4CBE6", surface: "#1B4A82" } },
};
export type ThemeKey = keyof typeof THEMES;

/** A fresh id: prefix ("s", "e" or "a") and 10 random base32 characters, like the server's. */
export function newId(prefix: "s" | "e" | "a"): string {
  const alphabet = "abcdefghijklmnopqrstuvwxyz234567";
  const b = crypto.getRandomValues(new Uint8Array(10));
  return `${prefix}_${Array.from(b, (n) => alphabet[n % 32]).join("")}`;
}

/** A theme colour name resolved to #RRGGBB; literals pass through. */
export function resolveColor(theme: Theme, c: ColorRef | undefined, fallback: ThemeColor = "text"): string {
  const v = c ?? fallback;
  return v.startsWith("#") ? v.toUpperCase() : (theme.colors[v as ThemeColor] ?? theme.colors[fallback]);
}

export const isGradient = (f: Fill | undefined): f is Gradient => typeof f === "object" && f !== null;

/** A fill resolved against the theme. */
export function resolvePaint(theme: Theme, f: Fill | undefined, fallback: ThemeColor = "text"): Paint {
  if (!isGradient(f)) return resolveColor(theme, f, fallback);
  return { angle: f.angle, stops: [resolveColor(theme, f.stops[0], fallback), resolveColor(theme, f.stops[1], fallback)] };
}

/** A CSS background for a fill (toolbar swatches). */
export function paintCss(p: Paint): string {
  return typeof p === "string" ? p : `linear-gradient(${p.angle + 90}deg, ${p.stops[0]}, ${p.stops[1]})`;
}

/**
 * Where a gradient at angle runs across a box: from the edge or corner it
 * starts at to the opposite one, like CSS and PowerPoint (unscaled), so both
 * end colours reach the box's extremes.
 */
export function gradientLine(angle: number, x: number, y: number, w: number, h: number) {
  const a = (angle * Math.PI) / 180, dx = Math.cos(a), dy = Math.sin(a);
  const half = (Math.abs(w * dx) + Math.abs(h * dy)) / 2, cx = x + w / 2, cy = y + h / 2;
  return { x1: cx - dx * half, y1: cy - dy * half, x2: cx + dx * half, y2: cy + dy * half };
}

/** Dash styles: the pattern is in multiples of the stroke width (PowerPoint's dash, sysDot, dashDot and lgDash). */
export const DASHES: { id: Dash; label: string; pattern: number[]; pptx: "solid" | "dash" | "sysDot" | "dashDot" | "lgDash" }[] = [
  { id: "solid", label: "Solid", pattern: [], pptx: "solid" },
  { id: "dash", label: "Dash", pattern: [4, 3], pptx: "dash" },
  { id: "dot", label: "Dot", pattern: [1, 1], pptx: "sysDot" },
  { id: "dashDot", label: "Dash-dot", pattern: [4, 3, 1, 3], pptx: "dashDot" },
  { id: "longDash", label: "Long dash", pattern: [8, 3], pptx: "lgDash" },
];

/** A dash style as lengths in slide units for a stroke width; empty for solid. */
export const dashArray = (d: Dash | undefined, sw: number): number[] => (DASHES.find((x) => x.id === d)?.pattern ?? []).map((n) => n * sw);

/** The slot a run's font resolves to. */
export const slotOf = (theme: Theme, f: FontRef | undefined): Slot => (f === undefined || f === "body" ? theme.fonts.body : f === "heading" ? theme.fonts.heading : f);

const para = (text: string, size: number, opts: Partial<Run> = {}, p: Partial<Paragraph> = {}): Paragraph => ({ ...p, runs: [{ text, size, ...opts }] });
const text = (placeholder: Placeholder, frame: Frame, valign: TextBox["valign"], ...paragraphs: Paragraph[]): TextElement => ({ id: newId("e"), type: "text", placeholder, frame, valign, paragraphs });

/**
 * An empty image placeholder: a text element with the image role and no text,
 * so it draws nothing in presentation, PDF and PPTX. The editor shows it as a
 * "click to add image" box and swaps in an image element with the same frame
 * and role. server/internal/deck imageSlot makes the same.
 */
const imageSlot = (frame: Frame): TextElement => text("image", frame, "middle", para("", 40, { font: "body", color: "muted" }));

/** An image placeholder nobody has filled yet. */
export const isImageSlot = (e: Element): boolean => e.type === "text" && e.placeholder === "image";

/** The elements a layout starts with; server/internal/deck Placeholders makes the same. */
export function placeholders(layout: Layout, title = ""): Element[] {
  const heading = (t: string, size: number, frame: Frame, valign: TextBox["valign"], align?: Paragraph["align"]) =>
    text("title", frame, valign, para(t, size, { bold: true, font: "heading", color: "heading" }, align ? { align } : {}));
  const body = (p: Placeholder, frame: Frame) => text(p, frame, "top", para("", 44, { font: "body", color: "text" }, { bullet: "disc" }));
  switch (layout) {
    case "title":
      return [heading(title || "Title", 112, { x: 160, y: 300, w: 1600, h: 280 }, "bottom"), text("subtitle", { x: 160, y: 600, w: 1600, h: 120 }, "top", para("", 44, { font: "body", color: "muted" }))];
    case "title-body":
      return [heading("", 80, { x: 120, y: 80, w: 1680, h: 160 }, "middle"), body("body", { x: 120, y: 280, w: 1680, h: 700 })];
    case "two-column":
      return [heading("", 80, { x: 120, y: 80, w: 1680, h: 160 }, "middle"), body("body", { x: 120, y: 280, w: 810, h: 700 }), body("body2", { x: 990, y: 280, w: 810, h: 700 })];
    case "image-right":
      return [heading("", 72, { x: 120, y: 120, w: 800, h: 300 }, "top"), text("body", { x: 120, y: 460, w: 800, h: 480 }, "top", para("", 40, { font: "body", color: "text" })), imageSlot({ x: 1000, y: 120, w: 800, h: 840 })];
    case "section":
      return [heading("", 128, { x: 160, y: 380, w: 1600, h: 320 }, "middle", "center")];
    case "quote":
      return [text("body", { x: 200, y: 220, w: 1520, h: 480 }, "bottom", para("", 72, { italic: true, font: "heading", color: "heading" })), text("subtitle", { x: 200, y: 740, w: 1520, h: 100 }, "top", para("", 44, { font: "body", color: "muted" }))];
    case "big-number":
      return [heading("", 280, { x: 160, y: 220, w: 1600, h: 420 }, "bottom", "center"), text("subtitle", { x: 160, y: 680, w: 1600, h: 160 }, "top", para("", 56, { font: "body", color: "muted" }, { align: "center" }))];
    case "three-column":
      return [heading("", 80, { x: 120, y: 80, w: 1680, h: 160 }, "middle"), body("body", { x: 120, y: 280, w: 520, h: 700 }), body("body2", { x: 700, y: 280, w: 520, h: 700 }), body("body3", { x: 1280, y: 280, w: 520, h: 700 })];
    case "comparison": {
      const label = (p: Placeholder, x: number) => text(p, { x, y: 280, w: 810, h: 90 }, "middle", para("", 52, { bold: true, font: "heading", color: "accent" }));
      return [heading("", 80, { x: 120, y: 80, w: 1680, h: 160 }, "middle"), label("label", 120), label("label2", 990), body("body", { x: 120, y: 390, w: 810, h: 590 }), body("body2", { x: 990, y: 390, w: 810, h: 590 })];
    }
    case "image-full":
      return [imageSlot({ x: 0, y: 0, w: 1920, h: 1080 }), text("title", { x: 120, y: 780, w: 1680, h: 200 }, "bottom", para("", 96, { bold: true, font: "heading", color: "#FFFFFF" }))];
    case "image-left":
      return [imageSlot({ x: 120, y: 120, w: 800, h: 840 }), heading("", 72, { x: 1000, y: 120, w: 800, h: 300 }, "top"), text("body", { x: 1000, y: 460, w: 800, h: 480 }, "top", para("", 40, { font: "body", color: "text" }))];
    case "agenda":
      return [heading("", 80, { x: 120, y: 80, w: 1680, h: 160 }, "middle"), text("body", { x: 120, y: 280, w: 1680, h: 700 }, "top", para("", 52, { font: "body", color: "text" }, { bullet: "number" }))];
    case "closing":
      return [heading(title || "Thank you", 128, { x: 160, y: 300, w: 1600, h: 280 }, "bottom", "center"), text("subtitle", { x: 160, y: 620, w: 1600, h: 140 }, "top", para("", 44, { font: "body", color: "muted" }, { align: "center" }))];
    default:
      return [];
  }
}

export const newSlide = (layout: Layout): Slide => ({ id: newId("s"), layout, elements: placeholders(layout) });

/** Where a layout puts each placeholder role, for re-laying out a slide. */
export function relayout(slide: Slide, layout: Layout): Slide {
  const fresh = placeholders(layout);
  const used = new Set<string>();
  // An unfilled image placeholder has nothing to keep: drop it when the new
  // layout has no image slot, rather than leave an invisible box.
  const keep = fresh.some((f) => f.placeholder === "image") ? slide.elements : slide.elements.filter((e) => !isImageSlot(e));
  const elements = keep.map((e) => {
    if (!e.placeholder) return e;
    const f = fresh.find((x) => x.placeholder === e.placeholder && !used.has(x.placeholder!));
    if (!f) return e;
    used.add(e.placeholder);
    return { ...e, frame: f.frame };
  });
  for (const f of fresh) {
    if (used.has(f.placeholder!)) continue;
    elements.push(f);
    used.add(f.placeholder!);
  }
  return { ...slide, layout, elements };
}

/** The text an element carries, if any: a text box, or a shape's text. */
export function textOf(e: Element): TextBox | undefined {
  if (e.type === "text") return e;
  if (e.type === "shape") return e.text;
  return undefined;
}

/** Every run's text in a slide, for accessible labels and change summaries. */
export function slideText(s: Slide): string {
  return s.elements
    .flatMap((e) => (e.type === "group" ? e.elements : [e]))
    .map((e) => (e.type === "image" ? e.alt ?? "" : (textOf(e)?.paragraphs ?? []).map((p) => p.runs.map((r) => r.text).join("")).join(" ")))
    .filter(Boolean)
    .join(" · ");
}

/** A slide's title: its title placeholder's text, else its first text. */
export function slideTitle(s: Slide): string {
  const all = s.elements.flatMap((e) => (e.type === "group" ? e.elements : [e]));
  const t = all.find((e) => e.placeholder === "title") ?? all.find((e) => textOf(e));
  const words = t ? (textOf(t)?.paragraphs ?? []).map((p) => p.runs.map((r) => r.text).join("")).join(" ").trim() : "";
  return words || "Untitled slide";
}

export function parseDeck(body: string): Deck {
  return JSON.parse(body) as Deck;
}

/** The deck as the server stores it (keys in the server's order isn't required: it normalises). */
export const encodeDeck = (d: Deck): string => JSON.stringify(d);

/** The built-in themes in the order the theme menu lists them (deck.ThemeOrder). */
export const THEME_ORDER: ThemeKey[] = ["light", "dark", "paper", "contrast", "dusk", "ocean", "forest", "sunset", "mono", "blueprint"];

function luminance(hex: string): number {
  const [r, g, b] = [1, 3, 5].map((i) => {
    const c = parseInt(hex.slice(i, i + 2), 16) / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/** The WCAG contrast ratio of two #RRGGBB colours, 1 to 21 (deck.Contrast). */
export function contrastRatio(a: string, b: string): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x);
  return (hi + 0.05) / (lo + 0.05);
}

/** Text colours on backgrounds below WCAG AA (4.5:1) in a theme. */
export function contrastIssues(theme: Theme): { fg: ThemeColor; bg: ThemeColor; ratio: number }[] {
  const out: { fg: ThemeColor; bg: ThemeColor; ratio: number }[] = [];
  for (const fg of ["text", "heading", "muted"] as const)
    for (const bg of ["background", "surface"] as const) {
      const ratio = contrastRatio(theme.colors[fg], theme.colors[bg]);
      if (ratio < 4.5) out.push({ fg, bg, ratio });
    }
  return out;
}
