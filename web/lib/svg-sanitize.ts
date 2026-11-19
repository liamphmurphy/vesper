import { CHARACTER_MOTIONS, CHARACTER_SPEEDS, isValidCharacterShow, parseCharacterDelay, parseCharacterPivot } from "./persona-character.ts";

/**
 * Pure whitelist converter: a parsed SVG DOM node -> a plain tree that the
 * visual editor renders with React.createElement. Parsed documents are inert;
 * this is what keeps scripts, styles, foreign content and external loads out of
 * the live page. Anything not whitelisted is dropped (elements are counted).
 * No DOM access: it only reads the structural bits of the node it is given.
 */

export type XAttr = { name: string; localName?: string | null; namespaceURI?: string | null; value: string };
export type XNode = {
  nodeType: number;
  namespaceURI?: string | null;
  localName?: string | null;
  nodeValue?: string | null;
  attributes?: ArrayLike<XAttr> | null;
  childNodes: ArrayLike<XNode>;
};

export type SNode = {
  /** Element name, or "#text". */
  tag: string;
  /** React prop names -> sanitized values. */
  attrs: Record<string, string>;
  children: SNode[];
  /** Text content of a "#text" node. */
  text?: string;
  /** Child-index path from the root element in the original doc ("" is the root, "0.3.1" a descendant). */
  path: string;
};

export const SVG_NS = "http://www.w3.org/2000/svg";
const XLINK_NS = "http://www.w3.org/1999/xlink";

const ELEMENTS = new Set([
  "svg", "g", "rect", "circle", "ellipse", "line", "polyline", "polygon", "path", "text", "tspan", "title", "desc",
  "defs", "linearGradient", "radialGradient", "stop", "clipPath", "mask", "pattern", "symbol", "use", "image", "marker",
]);

/** Elements whose character data is kept. */
const TEXTY = new Set(["text", "tspan", "title", "desc"]);

/** SVG attribute name -> React prop name. */
const ATTRS: Record<string, string> = {
  x: "x", y: "y", x1: "x1", y1: "y1", x2: "x2", y2: "y2", cx: "cx", cy: "cy", r: "r", rx: "rx", ry: "ry", fx: "fx", fy: "fy",
  width: "width", height: "height", d: "d", points: "points", transform: "transform", viewBox: "viewBox",
  preserveAspectRatio: "preserveAspectRatio", fill: "fill", stroke: "stroke", opacity: "opacity",
  "stroke-width": "strokeWidth", "stroke-dasharray": "strokeDasharray", "stroke-linecap": "strokeLinecap",
  "stroke-linejoin": "strokeLinejoin", "fill-opacity": "fillOpacity", "stroke-opacity": "strokeOpacity",
  "fill-rule": "fillRule", "clip-rule": "clipRule",
  "font-family": "fontFamily", "font-size": "fontSize", "font-weight": "fontWeight", "font-style": "fontStyle",
  "text-anchor": "textAnchor", "dominant-baseline": "dominantBaseline", "letter-spacing": "letterSpacing",
  offset: "offset", "stop-color": "stopColor", "stop-opacity": "stopOpacity", gradientUnits: "gradientUnits",
  gradientTransform: "gradientTransform", spreadMethod: "spreadMethod", dx: "dx", dy: "dy", id: "id",
  "clip-path": "clipPath", mask: "mask", "marker-start": "markerStart", "marker-mid": "markerMid", "marker-end": "markerEnd",
  patternUnits: "patternUnits", patternTransform: "patternTransform", clipPathUnits: "clipPathUnits", maskUnits: "maskUnits",
  markerWidth: "markerWidth", markerHeight: "markerHeight", refX: "refX", refY: "refY", orient: "orient",
  "data-vid": "data-vid", href: "href", rotate: "rotate", display: "display", visibility: "visibility",
};

const CHARACTER_EXTRA_ATTRS: Record<string, string> = {
  "stroke-dashoffset": "strokeDashoffset",
  "stroke-miterlimit": "strokeMiterlimit",
  "aria-hidden": "aria-hidden",
  "data-part": "data-part",
  "data-motion": "data-motion",
  "data-motion-idle": "data-motion-idle",
  "data-motion-working": "data-motion-working",
  "data-motion-thinking": "data-motion-thinking",
  "data-motion-reading": "data-motion-reading",
  "data-motion-coding": "data-motion-coding",
  "data-motion-creating": "data-motion-creating",
  "data-motion-needs-you": "data-motion-needs-you",
  "data-show": "data-show",
  "data-pivot": "data-pivot",
  "data-delay": "data-delay",
  "data-speed": "data-speed",
};

const CHARACTER_MOTION_ATTRS = new Set([
  "data-motion",
  "data-motion-idle",
  "data-motion-working",
  "data-motion-thinking",
  "data-motion-reading",
  "data-motion-coding",
  "data-motion-creating",
  "data-motion-needs-you",
]);
const CHARACTER_MOTIONS_SET = new Set<string>(CHARACTER_MOTIONS);
const CHARACTER_SPEEDS_SET = new Set<string>(CHARACTER_SPEEDS);
const PART_NAME = /^[a-z0-9-]{1,32}$/;

const ID = /^[A-Za-z_][\w.:-]*$/;
const URL_REF = /^url\(\s*#([A-Za-z_][\w.:-]*)\s*\)$/i;
const DATA_IMAGE = /^data:image\/(png|jpeg|gif|webp);base64,[A-Za-z0-9+/=\s]*$/;

/** Sanitized value for an attribute, or null to drop it. */
function cleanValue(react: string, raw: string, prefix: string, character: boolean): string | null {
  if (raw.replace(/[\s\u0000-\u001f]/g, "").toLowerCase().includes("javascript:")) return null;
  if (react === "id") return ID.test(raw) ? prefix + raw : null;
  if (react === "href") {
    if (!character && DATA_IMAGE.test(raw)) return raw;
    return raw.startsWith("#") && ID.test(raw.slice(1)) ? "#" + prefix + raw.slice(1) : null;
  }
  if (/url\(/i.test(raw)) {
    const m = URL_REF.exec(raw.trim());
    return m ? `url(#${prefix}${m[1]})` : null;
  }
  if (character) {
    if (CHARACTER_MOTION_ATTRS.has(react)) return CHARACTER_MOTIONS_SET.has(raw) ? raw : null;
    if (react === "data-part") return PART_NAME.test(raw) ? raw : null;
    if (react === "data-show") return isValidCharacterShow(raw) ? raw.trim() : null;
    if (react === "data-pivot") return parseCharacterPivot(raw) ? raw.trim() : null;
    if (react === "data-delay") return parseCharacterDelay(raw) ? raw.trim() : null;
    if (react === "data-speed") return CHARACTER_SPEEDS_SET.has(raw) ? raw : null;
  }
  return raw;
}

function cleanAttrs(attributes: ArrayLike<XAttr> | null | undefined, prefix: string, character: boolean): Record<string, string> {
  const out: Record<string, string> = {};
  for (let i = 0; i < (attributes?.length ?? 0); i++) {
    const a = attributes![i];
    let key: string | undefined;
    if (!a.namespaceURI) key = a.name;
    else if (a.namespaceURI === XLINK_NS && (a.localName ?? "") === "href") key = "href";
    if (key === undefined) continue;
    const react = Object.hasOwn(ATTRS, key)
      ? ATTRS[key]
      : character && Object.hasOwn(CHARACTER_EXTRA_ATTRS, key)
        ? CHARACTER_EXTRA_ATTRS[key]
        : undefined;
    if (react === undefined) continue;
    if (react in out && !a.namespaceURI) delete out[react]; // a plain attribute overrides xlink:href
    else if (react in out) continue;
    const v = cleanValue(react, a.value, prefix, character);
    if (v !== null) out[react] = v;
  }
  return out;
}

function countElements(n: XNode): number {
  let c = n.nodeType === 1 ? 1 : 0;
  for (let i = 0; i < n.childNodes.length; i++) c += countElements(n.childNodes[i]);
  return c;
}

/**
 * Convert `root` (the document element) to a sanitized tree. `prefix` is
 * prepended to every id and url(#…)/#… reference. Returns tree null when the
 * root isn't an SVG-namespace <svg>.
 */
export function sanitizeSvg(root: XNode, prefix: string, options?: { character?: boolean }): { tree: SNode | null; skipped: number } {
  const character = !!options?.character;
  let skipped = 0;
  const walk = (n: XNode, path: string, parentTag: string | null): SNode | null => {
    if (n.nodeType === 3 || n.nodeType === 4) {
      const text = n.nodeValue ?? "";
      if (!parentTag || !TEXTY.has(parentTag) || !text) return null;
      return { tag: "#text", attrs: {}, children: [], text, path };
    }
    if (n.nodeType !== 1) return null; // comments, PIs
    const tag = n.localName ?? "";
    if (n.namespaceURI !== SVG_NS || !ELEMENTS.has(tag) || (character && tag === "image") || (character && parentTag !== null && tag === "svg")) {
      skipped += countElements(n);
      return null;
    }
    const children: SNode[] = [];
    for (let i = 0; i < n.childNodes.length; i++) {
      const c = walk(n.childNodes[i], path ? `${path}.${i}` : String(i), tag);
      if (c) children.push(c);
    }
    return { tag, attrs: cleanAttrs(n.attributes, prefix, character), children, path };
  };
  if (root.nodeType !== 1 || root.namespaceURI !== SVG_NS || root.localName !== "svg") return { tree: null, skipped: 0 };
  return { tree: walk(root, "", null), skipped };
}
