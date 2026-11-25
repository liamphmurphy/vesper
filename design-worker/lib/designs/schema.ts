// The Designs body, schema 1 (docs/design/ADR-designs.md §3.1): types,
// normalize and validate. Mirrors server/internal/design (schema.go) so the
// editor never sends a body the server would refuse; both run the shared
// invalid bodies in ./fixtures/invalid (cases.json).

export const SCHEMA = 1;

export const CAPS = {
  body: 2 * 1024 * 1024,
  nodes: 10000,
  depth: 32,
  textChars: 5000,
  pages: 50,
  links: 2000,
  tokenSets: 8,
  assets: 200,
  tokens: 400,
} as const;

export type Mode = "dark" | "light";
export type Color = string; // "#RRGGBB" | "#RRGGBBAA" | "$token-name"
export type Paint = Color | { angle: number; stops: [Color, Color] };
export type Dash = "solid" | "dash" | "dot" | "dashDot" | "longDash";

export type Run = {
  text: string;
  size: number;
  weight?: 400 | 500 | 600 | 700;
  bold?: boolean;
  italic?: boolean;
  underline?: boolean;
  strike?: boolean;
  color?: Color;
  highlight?: Color;
};
export type Paragraph = {
  runs: Run[];
  align?: "left" | "center" | "right" | "justify";
  bullet?: "disc" | "number";
  level?: number;
  spaceBefore?: number;
  lineSpacing?: number;
};
export type TextBox = { paragraphs: Paragraph[]; valign?: "top" | "middle" | "bottom" };

export type Sizing = { w?: "fixed" | "hug" | "fill"; h?: "fixed" | "hug" | "fill" };
export type AutoLayout = {
  direction: "horizontal" | "vertical";
  gap?: number;
  padding?: [number, number, number, number];
  align?: "start" | "center" | "end";
  justify?: "start" | "center" | "end" | "space-between";
};
export type Constraints = {
  h?: "left" | "right" | "left-right" | "center" | "scale";
  v?: "top" | "bottom" | "top-bottom" | "center" | "scale";
};

type Box = {
  id: string;
  name?: string;
  x: number;
  y: number;
  w: number;
  h: number;
  rotation?: number;
  opacity?: number;
  visible?: boolean;
  locked?: boolean;
  sizing?: Sizing;
  absolute?: boolean;
  constraints?: Constraints;
};
type Styled = { fill?: Paint; stroke?: Color; stroke_width?: number; dash?: Dash };
type ContainerFields = {
  children: DesignNode[];
  radius?: number;
  clip?: boolean;
  mode?: Mode;
  auto_layout?: AutoLayout;
  preset?: string;
  linked_tickets?: string[];
  linked_paths?: string[];
};

export type FrameNode = Box & Styled & ContainerFields & { type: "frame" | "component" };
export type GroupNode = Box & { type: "group"; children: DesignNode[] };
export type SectionNode = Box & { type: "section"; fill?: Color; children: DesignNode[] };
export type ShapeNode = Box & Styled & { type: "shape"; shape: string; radius?: number; text?: TextBox };
export type PathNode = Box & Styled & { type: "path"; d: string; cap?: "butt" | "round" | "square"; join?: "miter" | "round" | "bevel" };
export type TextNode = Box & { type: "text"; paragraphs: Paragraph[]; valign?: "top" | "middle" | "bottom" };
export type ImageNode = Box & {
  type: "image";
  asset: string;
  fit?: "cover" | "contain" | "fill";
  crop?: { l: number; t: number; r: number; b: number };
  radius?: number;
  alt?: string;
};
export type Override = { text?: string; fill?: Paint; visible?: boolean };
export type InstanceNode = Box & { type: "instance"; component: string; overrides?: Record<string, Override> };
export type StickyNode = Box & { type: "sticky"; text: string; color?: "yellow" | "pink" | "green" | "blue" | "violet" | "grey"; author?: string };
export type Endpoint = { node: string; anchor?: "auto" | "top" | "right" | "bottom" | "left" };
export type ConnectorNode = {
  id: string;
  type: "connector";
  name?: string;
  from: Endpoint;
  to: Endpoint;
  route?: "orthogonal" | "straight";
  label?: string;
  stroke?: Color;
  stroke_width?: number;
  dash?: Dash;
  start_arrow?: "none" | "arrow" | "dot";
  end_arrow?: "none" | "arrow" | "dot";
  visible?: boolean;
  points?: [number, number][];
};
export type DesignNode = FrameNode | GroupNode | SectionNode | ShapeNode | PathNode | TextNode | ImageNode | InstanceNode | StickyNode | ConnectorNode;
export type NodeType = DesignNode["type"];

export type Page = { id: string; name: string; background?: Color; children: DesignNode[] };
export type Link = {
  id: string;
  from: string;
  to: string;
  trigger: "click" | "hover" | "after-delay";
  delay_ms?: number;
  transition: "instant" | "dissolve" | "slide-left" | "slide-right" | "slide-up" | "slide-down" | "smart-animate";
  duration_ms?: number;
};
export type Token = { kind: "color"; value: string } | { kind: "dimension"; value: string };
export type TokenSet = { name: string; source?: string | null; modes: { dark: Record<string, Token>; light?: Record<string, Token> } };
export type TokensRef = { set: string; source?: string; hash: string; synced_at: string };
export type Asset = { mime: "image/png" | "image/jpeg"; w: number; h: number; alt?: string; file?: string };

export type Design = {
  schema: 1;
  mode: Mode;
  tokens_ref?: TokensRef;
  token_sets: Record<string, TokenSet>;
  assets: Record<string, Asset>;
  pages: Page[];
  links: Link[];
};

export const NODE_TYPES: NodeType[] = ["frame", "component", "group", "section", "shape", "path", "text", "image", "instance", "sticky", "connector"];
export const CONTAINERS = new Set<string>(["frame", "component", "group", "section"]);
export const SHAPE_PRESETS = ["rect", "roundRect", "ellipse", "triangle", "rtTriangle", "diamond", "pentagon", "hexagon", "octagon", "rightArrow", "leftArrow", "upArrow", "downArrow", "chevron", "homePlate", "wedgeRectCallout", "wedgeRoundRectCallout", "star5", "plus", "donut", "heart"];

const RE = {
  nodeId: /^n_[a-z0-9_]{1,40}$/,
  pageId: /^p_[a-z0-9_]{1,40}$/,
  linkId: /^k_[a-z0-9_]{1,40}$/,
  assetId: /^a_[a-z0-9_]{1,40}$/,
  key: /^[a-z0-9][a-z0-9-]{0,39}$/,
  tokenName: /^[a-z0-9][a-z0-9-]{0,63}$/,
  color: /^(#[0-9A-F]{6}([0-9A-F]{2})?|\$[a-z0-9][a-z0-9-]{0,63})$/,
  hex: /^#[0-9A-F]{6}([0-9A-F]{2})?$/,
  anyHex: /^#[0-9a-fA-F]{6}([0-9a-fA-F]{2})?$/,
  dimension: /^-?\d+(\.\d+)?px$/,
  hash: /^sha256:[0-9a-f]{64}$/,
  dateTime: /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$/,
  preset: /^[a-z0-9-]{1,40}$/,
  ticket: /^[A-Z][A-Z0-9]{1,15}-[0-9]{1,7}$/,
  pathRef: /^[^/\s][^\s]{0,299}$/,
  pathD: /^[MLCQZmlcqz0-9eE.,\s-]+$/,
};

/** A refused body: the message matches the server's. */
export class DesignError extends Error {}

type J = unknown;
type Obj = Record<string, J>;
const isObj = (v: J): v is Obj => typeof v === "object" && v !== null && !Array.isArray(v);
const fail = (msg: string): never => {
  throw new DesignError(msg);
};
const at = (path: string, msg: string): never => fail(`body: ${path || "design"}: ${msg}`);
const join = (path: string, k: string) => (path ? `${path}.${k}` : k);
const chars = (s: string) => [...s].length;

// ---- normalisation ----

/** Rounds to 0.01 like the server (Math.round, so halves go up), without -0. */
export const round = (x: number) => {
  const r = Math.round(x * 100) / 100;
  return r === 0 ? 0 : r;
};

function roundAll(v: J): J {
  if (typeof v === "number") return round(v);
  if (Array.isArray(v)) return v.map(roundAll);
  if (isObj(v)) {
    for (const k of Object.keys(v)) v[k] = roundAll(v[k]);
  }
  return v;
}

const upperHex = (v: J) => (typeof v === "string" && RE.anyHex.test(v) ? v.toUpperCase() : v);

function normPaint(m: Obj, k: string) {
  const p = m[k];
  if (typeof p === "string") m[k] = upperHex(p);
  else if (isObj(p) && Array.isArray(p.stops)) p.stops = p.stops.map(upperHex);
}

function dropDefault(m: Obj, k: string, def: J) {
  if (k in m && m[k] === def) delete m[k];
}

const NODE_DEFAULTS: [string, J][] = [["rotation", 0], ["opacity", 1], ["visible", true], ["locked", false], ["absolute", false]];

function normParagraphs(ps: J) {
  if (!Array.isArray(ps)) return;
  for (const p of ps) {
    if (!isObj(p)) continue;
    dropDefault(p, "level", 0);
    dropDefault(p, "spaceBefore", 0);
    dropDefault(p, "lineSpacing", 1);
    if (!Array.isArray(p.runs)) continue;
    for (const r of p.runs) {
      if (!isObj(r)) continue;
      if (typeof r.bold === "boolean") {
        const b = r.bold;
        delete r.bold;
        if (b) r.weight = 700;
      }
      dropDefault(r, "weight", 400);
      for (const k of ["italic", "underline", "strike"]) dropDefault(r, k, false);
      for (const k of ["color", "highlight"]) if (k in r) r[k] = upperHex(r[k]);
    }
  }
}

function normNode(n: J) {
  if (!isObj(n)) return;
  for (const [k, def] of NODE_DEFAULTS) dropDefault(n, k, def);
  normPaint(n, "fill");
  if ("stroke" in n) n.stroke = upperHex(n.stroke);
  normParagraphs(n.paragraphs);
  if (isObj(n.text)) normParagraphs(n.text.paragraphs);
  if (isObj(n.overrides)) for (const o of Object.values(n.overrides)) if (isObj(o)) normPaint(o, "fill");
  if (Array.isArray(n.children)) n.children.forEach(normNode);
}

function normalizeDoc(d: Obj) {
  roundAll(d);
  if (Array.isArray(d.pages)) {
    for (const p of d.pages) {
      if (!isObj(p)) continue;
      if ("background" in p) p.background = upperHex(p.background);
      if (Array.isArray(p.children)) p.children.forEach(normNode);
    }
  }
  if (isObj(d.token_sets)) {
    for (const s of Object.values(d.token_sets)) {
      if (!isObj(s) || !isObj(s.modes)) continue;
      for (const m of Object.values(s.modes)) {
        if (!isObj(m)) continue;
        for (const t of Object.values(m)) if (isObj(t) && t.kind === "color") t.value = upperHex(t.value);
      }
    }
  }
}

/** JSON with keys sorted at every level, as the server writes it. */
export function canonical(v: J): string {
  const sort = (x: J): J => {
    if (Array.isArray(x)) return x.map(sort);
    if (isObj(x)) {
      const o: Obj = {};
      for (const k of Object.keys(x).sort()) o[k] = sort(x[k]);
      return o;
    }
    return x;
  };
  return JSON.stringify(sort(v));
}

const byteLength = (s: string) => new TextEncoder().encode(s).length;

/**
 * Parses (when given a string), normalises and validates a design and returns
 * it with its canonical JSON. Throws DesignError with the server's message.
 */
export function normalize(input: string | Design): { design: Design; json: string } {
  let d: J;
  if (typeof input === "string") {
    if (byteLength(input) > CAPS.body) fail(`body: is ${Math.floor(byteLength(input) / 1024)} KB; a design is at most ${CAPS.body / 1024} KB`);
    try {
      d = JSON.parse(input);
    } catch (e) {
      fail(`body: isn't valid JSON: ${(e as Error).message}`);
    }
  } else {
    d = structuredClone(input);
  }
  if (!isObj(d)) fail("body: must be a JSON object");
  const doc = d as Obj;
  if (typeof doc.schema === "number" && doc.schema > SCHEMA) fail(`body: schema ${doc.schema} is newer than this editor knows (${SCHEMA})`);
  normalizeDoc(doc);
  validate(doc);
  const json = canonical(doc);
  if (byteLength(json) > CAPS.body) fail(`body: is ${Math.floor(byteLength(json) / 1024)} KB; a design is at most ${CAPS.body / 1024} KB`);
  return { design: doc as unknown as Design, json };
}

/** The error message for a body, or null when it's valid. */
export function problem(input: string | Design): string | null {
  try {
    normalize(input);
    return null;
  } catch (e) {
    if (e instanceof DesignError) return e.message;
    throw e;
  }
}

// ---- structural checks (the JSON Schema, by hand) ----

type Check = (v: J, path: string) => void;

const str = (re: RegExp | null, min: number, max: number): Check => (v, path) => {
  if (typeof v !== "string") at(path, "must be a string");
  const s = v as string;
  const n = chars(s);
  if (n < min || (max > 0 && n > max)) at(path, min > 0 ? `must be ${min} to ${max} characters` : `must be at most ${max} characters`);
  if (re && !re.test(s)) at(path, `${JSON.stringify(s)} isn't in the expected form`);
};
const num = (min: number, max: number): Check => (v, path) => {
  if (typeof v !== "number") at(path, "must be a number");
  if ((v as number) < min || (v as number) > max) at(path, `must be between ${min} and ${max}`);
};
const integer = (min: number, max: number): Check => (v, path) => {
  if (typeof v !== "number" || !Number.isInteger(v)) at(path, "must be a whole number");
  if ((v as number) < min || (v as number) > max) at(path, `must be between ${min} and ${max}`);
};
const oneOf = (...vals: J[]): Check => (v, path) => {
  if (!vals.includes(v)) at(path, `must be one of ${vals.join(", ")}`);
};
const boolean: Check = (v, path) => {
  if (typeof v !== "boolean") at(path, "must be true or false");
};
const arr = (item: Check, min: number, max: number): Check => (v, path) => {
  if (!Array.isArray(v)) at(path, "must be a list");
  const a = v as J[];
  if (a.length < min || (max >= 0 && a.length > max)) at(path, max < 0 ? `must have at least ${min} items` : `must have ${min} to ${max} items`);
  a.forEach((x, i) => item(x, `${path}[${i}]`));
};
const unique = (item: Check, max: number): Check => (v, path) => {
  arr(item, 0, max)(v, path);
  const seen = new Set<J>();
  for (const x of v as J[]) {
    if (seen.has(x)) at(path, `lists ${x} twice`);
    seen.add(x);
  }
};
type Fields = Record<string, Check>;
function checkFields(m: Obj, path: string, fs: Fields, required: string[]) {
  for (const k of required) if (!(k in m)) at(path, `${k} is required`);
  for (const k of Object.keys(m).sort()) {
    const c = fs[k];
    if (!c) at(path, `unknown field ${k}`);
    c(m[k], join(path, k));
  }
}
const object = (fs: Fields, ...required: string[]): Check => (v, path) => {
  if (!isObj(v)) at(path, "must be an object");
  checkFields(v as Obj, path, fs, required);
};
const mapOf = (key: RegExp, val: Check, max: number): Check => (v, path) => {
  if (!isObj(v)) at(path, "must be an object");
  const keys = Object.keys(v as Obj).sort();
  if (keys.length > max) at(path, `has ${keys.length} entries; at most ${max}`);
  for (const k of keys) {
    if (!key.test(k)) at(path, `${JSON.stringify(k)} isn't a valid key`);
    val((v as Obj)[k], join(path, k));
  }
};
const nullable = (c: Check): Check => (v, path) => {
  if (v !== null) c(v, path);
};
const any: Check = () => {};

const cColor = str(RE.color, 0, 0);
const cPaint: Check = (v, path) => (typeof v === "string" ? cColor(v, path) : object({ angle: num(0, 360), stops: arr(cColor, 2, 2) }, "angle", "stops")(v, path));
const cNum = num(-1000000, 1000000);
const cSize = num(0, 100000);
const cMode = oneOf("dark", "light");
const cDash = oneOf("solid", "dash", "dot", "dashDot", "longDash");
const cToken: Check = (v, path) => {
  if (!isObj(v)) at(path, "must be an object");
  const m = v as Obj;
  if (m.kind === "color") return checkFields(m, path, { kind: oneOf("color"), value: str(RE.hex, 0, 0) }, ["kind", "value"]);
  if (m.kind === "dimension") return checkFields(m, path, { kind: oneOf("dimension"), value: str(RE.dimension, 0, 0) }, ["kind", "value"]);
  at(path, "kind must be color or dimension");
};
const cTokens = mapOf(RE.tokenName, cToken, CAPS.tokens);
const cTokenSet = object({ name: str(null, 1, 80), source: nullable(str(null, 0, 200)), modes: object({ dark: cTokens, light: cTokens }, "dark") }, "name", "modes");
const cAsset = object({ mime: oneOf("image/png", "image/jpeg"), w: integer(1, 8192), h: integer(1, 8192), alt: str(null, 0, 500), file: str(null, 0, 0) }, "mime", "w", "h");
const cNodeId = str(RE.nodeId, 0, 0);
const cLink = object(
  {
    id: str(RE.linkId, 0, 0),
    from: cNodeId,
    to: cNodeId,
    trigger: oneOf("click", "hover", "after-delay"),
    delay_ms: integer(0, 60000),
    transition: oneOf("instant", "dissolve", "slide-left", "slide-right", "slide-up", "slide-down", "smart-animate"),
    duration_ms: integer(0, 5000),
  },
  "id", "from", "to", "trigger", "transition",
);
const cRun = object(
  {
    text: str(null, 0, CAPS.textChars),
    size: num(4, 400),
    weight: oneOf(400, 500, 600, 700),
    bold: boolean,
    italic: boolean,
    underline: boolean,
    strike: boolean,
    color: cColor,
    highlight: cColor,
  },
  "text", "size",
);
const cParagraph = object(
  { runs: arr(cRun, 1, -1), align: oneOf("left", "center", "right", "justify"), bullet: oneOf("disc", "number"), level: integer(0, 4), spaceBefore: num(0, 1000), lineSpacing: num(0.8, 3) },
  "runs",
);
const cParagraphs = arr(cParagraph, 1, -1);
const cValign = oneOf("top", "middle", "bottom");
const cTextBox = object({ paragraphs: cParagraphs, valign: cValign }, "paragraphs");
const cEndpoint = object({ node: cNodeId, anchor: oneOf("auto", "top", "right", "bottom", "left") }, "node");
const cOverride: Check = (v, path) => {
  if (isObj(v) && Object.keys(v).length === 0) at(path, "must set text, fill or visible");
  object({ text: str(null, 0, CAPS.textChars), fill: cPaint, visible: boolean })(v, path);
};
const cAutoLayout = object(
  {
    direction: oneOf("horizontal", "vertical"),
    gap: num(0, 10000),
    padding: arr(num(0, 10000), 4, 4),
    align: oneOf("start", "center", "end"),
    justify: oneOf("start", "center", "end", "space-between"),
  },
  "direction",
);
const sizes = oneOf("fixed", "hug", "fill");
const cSizing = object({ w: sizes, h: sizes });
const cConstraints = object({ h: oneOf("left", "right", "left-right", "center", "scale"), v: oneOf("top", "bottom", "top-bottom", "center", "scale") });
const frac = num(0, 0.99);
const cCrop = object({ l: frac, t: frac, r: frac, b: frac }, "l", "t", "r", "b");

const cChildren = (min: number): Check => (v, path) => arr(cNode, min, -1)(v, path);
const boxFields: Fields = {
  id: cNodeId,
  type: any,
  name: str(null, 0, 100),
  x: cNum,
  y: cNum,
  w: cSize,
  h: cSize,
  rotation: num(-360, 360),
  opacity: num(0, 1),
  visible: boolean,
  locked: boolean,
  sizing: cSizing,
  absolute: boolean,
  constraints: cConstraints,
};
const BOX_REQUIRED = ["id", "type", "x", "y", "w", "h"];
const styledFields: Fields = { fill: cPaint, stroke: cColor, stroke_width: num(0, 1000), dash: cDash };
const frameFields: Fields = {
  ...boxFields,
  ...styledFields,
  children: cChildren(0),
  radius: num(0, 10000),
  clip: boolean,
  mode: cMode,
  auto_layout: cAutoLayout,
  preset: str(RE.preset, 0, 0),
  linked_tickets: unique(str(RE.ticket, 0, 0), 20),
  linked_paths: unique(str(RE.pathRef, 0, 0), 20),
};
const NODE_FIELDS: Record<string, Fields> = {
  frame: frameFields,
  component: frameFields,
  group: { ...boxFields, children: cChildren(1) },
  section: { ...boxFields, children: cChildren(0), fill: cColor },
  shape: { ...boxFields, ...styledFields, shape: oneOf(...SHAPE_PRESETS), radius: num(0, 10000), text: cTextBox },
  path: { ...boxFields, ...styledFields, d: str(RE.pathD, 3, 20000), cap: oneOf("butt", "round", "square"), join: oneOf("miter", "round", "bevel") },
  text: { ...boxFields, paragraphs: cParagraphs, valign: cValign },
  image: { ...boxFields, asset: str(RE.assetId, 0, 0), fit: oneOf("cover", "contain", "fill"), crop: cCrop, radius: num(0, 10000), alt: str(null, 0, 500) },
  instance: { ...boxFields, component: cNodeId, overrides: mapOf(RE.nodeId, cOverride, 200) },
  sticky: { ...boxFields, text: str(null, 0, 2000), color: oneOf("yellow", "pink", "green", "blue", "violet", "grey"), author: str(null, 0, 80) },
  connector: {
    id: cNodeId,
    type: any,
    name: str(null, 0, 100),
    from: cEndpoint,
    to: cEndpoint,
    route: oneOf("orthogonal", "straight"),
    label: str(null, 0, 200),
    stroke: cColor,
    stroke_width: num(0.5, 50),
    dash: cDash,
    start_arrow: oneOf("none", "arrow", "dot"),
    end_arrow: oneOf("none", "arrow", "dot"),
    visible: boolean,
    points: arr(arr(cNum, 2, 2), 0, 64),
  },
};
const NODE_REQUIRED: Record<string, string[]> = {
  frame: ["children"],
  component: ["children"],
  group: ["children"],
  section: ["children"],
  shape: ["shape"],
  path: ["d"],
  text: ["paragraphs"],
  image: ["asset"],
  instance: ["component"],
  sticky: ["text"],
};

function cNode(v: J, path: string) {
  if (!isObj(v)) at(path, "must be an object");
  const m = v as Obj;
  const t = typeof m.type === "string" ? m.type : "";
  const fs = NODE_FIELDS[t];
  if (!fs) at(join(path, "type"), `must be one of ${NODE_TYPES.join(", ")}`);
  const req = t === "connector" ? ["id", "type", "from", "to"] : [...BOX_REQUIRED, ...(NODE_REQUIRED[t] ?? [])];
  checkFields(m, path, fs, req);
}

const cPage = object({ id: str(RE.pageId, 0, 0), name: str(null, 1, 100), background: cColor, children: cChildren(0) }, "id", "name", "children");

const cDesign = object(
  {
    schema: oneOf(1),
    mode: cMode,
    tokens_ref: object({ set: str(RE.key, 0, 0), source: str(null, 0, 200), hash: str(RE.hash, 0, 0), synced_at: str(RE.dateTime, 0, 0) }, "set", "hash", "synced_at"),
    token_sets: mapOf(RE.key, cTokenSet, CAPS.tokenSets),
    assets: mapOf(RE.assetId, cAsset, CAPS.assets),
    pages: arr(cPage, 1, CAPS.pages),
    links: arr(cLink, 0, CAPS.links),
  },
  "schema", "mode", "pages", "assets", "links", "token_sets",
);

// ---- semantic checks (ADR §3.1 rules JSON Schema can't express) ----

type AnyNode = Obj & { id: string; type: string; children?: AnyNode[] };
type AnyPage = Obj & { id: string; children: AnyNode[] };

/** Visits every node in paint order, parents first. */
export function walk<P extends { children: N[] }, N extends { children?: N[] }>(
  d: { pages: P[] },
  fn: (n: N, parent: N | null, page: P, depth: number) => void,
) {
  const visit = (n: N, parent: N | null, page: P, depth: number) => {
    fn(n, parent, page, depth);
    for (const c of n.children ?? []) visit(c, n, page, depth + 1);
  };
  for (const p of d.pages) for (const n of p.children) visit(n, null, p, 1);
}

const paragraphsOf = (n: AnyNode): Paragraph[] =>
  (Array.isArray(n.paragraphs) ? n.paragraphs : isObj(n.text) && Array.isArray(n.text.paragraphs) ? n.text.paragraphs : []) as Paragraph[];

/** Checks a normalised design: structure first, then the rules. Throws DesignError. */
export function validate(input: unknown) {
  cDesign(input, "");
  const d = input as { pages: AnyPage[]; links: Link[]; assets: Obj; token_sets: Record<string, TokenSet>; tokens_ref?: TokensRef };
  const ids = new Map<string, { n: AnyNode; parent: AnyNode | null; page: AnyPage }>();
  const seen = new Set<string>();
  let first: string | null = null;
  const note = (msg: string) => {
    if (first === null) first = msg;
  };
  const dup = (id: string) => {
    if (seen.has(id)) note(`body: duplicate id ${id}`);
    seen.add(id);
  };
  for (const p of d.pages) dup(p.id);
  for (const l of d.links) dup(l.id);
  let count = 0;
  walk<AnyPage, AnyNode>(d, (n, parent, page, depth) => {
    dup(n.id);
    ids.set(n.id, { n, parent, page });
    count++;
    if (depth > CAPS.depth) note(`body: ${n.id} is nested ${depth} deep; the cap is ${CAPS.depth}`);
    if (parent && !CONTAINERS.has(parent.type)) note(`body: ${n.id}: a ${parent.type} can't have children`);
    if (n.type === "connector" && parent?.type === "group") note(`body: ${n.id}: connectors can't sit in a group`);
    const total = paragraphsOf(n).flatMap((p) => p.runs).reduce((a, r) => a + chars(r.text), 0);
    if (total > CAPS.textChars) note(`body: ${n.id} has ${total} characters of text; the cap is ${CAPS.textChars}`);
    if (n.type === "image") {
      if (!(String(n.asset) in d.assets)) note(`body: ${n.id}: asset ${n.asset} isn't in assets`);
      const c = n.crop as { l: number; t: number; r: number; b: number } | undefined;
      if (c && (c.l + c.r >= 1 || c.t + c.b >= 1)) note(`body: ${n.id}: crop leaves nothing of the image`);
    }
    const sz = n.sizing as Sizing | undefined;
    if (sz) {
      const vals = Object.values(sz);
      if (vals.includes("fill") && !parent?.auto_layout) note(`body: ${n.id}: fill sizing needs a parent with auto layout`);
      if (vals.includes("hug") && n.type !== "text" && n.type !== "instance" && !n.auto_layout) note(`body: ${n.id}: hug sizing needs text, an instance or auto layout`);
    }
  });
  if (first !== null) fail(first);
  if (count > CAPS.nodes) fail(`body: has ${count} nodes; the cap is ${CAPS.nodes}`);

  // Tokens.
  let set: TokenSet | undefined;
  let setName = "(no token set)";
  if (d.tokens_ref) {
    setName = d.tokens_ref.set;
    set = d.token_sets[setName];
    if (!set) fail(`body: tokens_ref.set ${setName} isn't in token_sets`);
  }
  const checkColor = (v: J, where: string) => {
    const cs = typeof v === "string" ? [v] : isObj(v) && Array.isArray(v.stops) ? (v.stops as string[]) : [];
    for (const c of cs) {
      if (c.startsWith("$") && set?.modes.dark[c.slice(1)]?.kind !== "color") fail(`body: ${where}: token ${c} isn't a colour in ${setName}`);
    }
  };
  for (const p of d.pages) checkColor(p.background, p.id);
  walk<AnyPage, AnyNode>(d, (n) => {
    checkColor(n.fill, n.id);
    checkColor(n.stroke, n.id);
    for (const p of paragraphsOf(n)) for (const r of p.runs) (checkColor(r.color, n.id), checkColor(r.highlight, n.id));
    if (isObj(n.overrides)) for (const k of Object.keys(n.overrides).sort()) checkColor((n.overrides[k] as Override).fill, n.id);
  });

  // References.
  walk<AnyPage, AnyNode>(d, (n, _parent, page) => {
    if (n.type === "instance") {
      const comp = String(n.component);
      const main = ids.get(comp);
      if (!main || main.n.type !== "component") fail(`body: ${n.id}: component ${comp} isn't a component`);
      const inMain = new Set<string>();
      const mark = (m: AnyNode) => {
        inMain.add(m.id);
        for (const c of m.children ?? []) mark(c);
      };
      mark(main!.n);
      if (inMain.has(n.id)) fail(`body: ${n.id}: a component can't contain an instance of itself`);
      if (isObj(n.overrides)) {
        for (const k of Object.keys(n.overrides).sort()) if (!inMain.has(k) || k === comp) fail(`body: ${n.id}: override ${k} isn't inside ${comp}`);
      }
    }
    if (n.type === "connector") {
      for (const end of [n.from, n.to] as Endpoint[]) {
        const t = ids.get(end.node);
        if (!t) fail(`body: ${n.id}: endpoint ${end.node} doesn't exist`);
        else if (t.page.id !== page.id) fail(`body: ${n.id}: endpoint ${end.node} is on another page`);
        else if (t.n.type === "connector") fail(`body: ${n.id}: can't connect to a connector`);
      }
    }
  });
  const top = new Set(d.pages.flatMap((p) => p.children.filter((n) => n.type === "frame").map((n) => n.id)));
  for (const l of d.links) {
    if (!ids.has(l.from)) fail(`body: link ${l.id}: from ${l.from} doesn't exist`);
    // A missing target is a broken link (kept, shown as broken, skipped by Present); a non-frame one is refused.
    if (ids.has(l.to) && !top.has(l.to)) fail(`body: link ${l.id}: to ${l.to} isn't a top-level frame`);
    if (l.trigger === "after-delay" && l.delay_ms === undefined) fail(`body: link ${l.id}: after-delay needs delay_ms`);
  }
}
