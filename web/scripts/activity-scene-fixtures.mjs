// Writes protocol/activity-scenes/fixtures.json from the web's source of truth:
// - web/lib/chat-ui.ts (all ChatStatusKind values)
// - web/app/(app)/chat/_components/activity-scene.tsx (HOLD_MS, FADE_MS, WIND_DOWN_MS, SCENE_OF, SCENES)
// - web/app/globals.css (all .scene-* animation rules and @keyframes scene-*)
//
// Run after changing activity scenes or keyframes:
//   node web/scripts/activity-scene-fixtures.mjs

import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "../..");
const chatUiSrc = readFileSync(join(repoRoot, "web/lib/chat-ui.ts"), "utf8");
const sceneTsxSrc = readFileSync(join(repoRoot, "web/app/(app)/chat/_components/activity-scene.tsx"), "utf8");
const globalsCssSrc = readFileSync(join(repoRoot, "web/app/globals.css"), "utf8");

function parseKinds(src) {
  const m = /export type ChatStatusKind =([\s\S]*?);/.exec(src);
  if (!m) throw new Error("ChatStatusKind union not found in web/lib/chat-ui.ts");
  return [...m[1].matchAll(/"([^"]+)"/g)].map((x) => x[1]);
}

function parseConstMs(src, name) {
  const m = new RegExp(`const ${name}\\s*=\\s*(\\d+)`).exec(src);
  if (!m) throw new Error(`Constant ${name} not found in activity-scene.tsx`);
  return Number(m[1]);
}

function parseSplitAliases(src) {
  const m = /const SCENE_OF:[^=]*=\s*\{([\s\S]*?)\};/.exec(src);
  if (!m) throw new Error("SCENE_OF map not found in activity-scene.tsx");
  const out = {};
  for (const line of m[1].split("\n")) {
    const entry = /^\s*(?:"([^"]+)"|([a-z0-9-]+))\s*:\s*"([^"]+)"/.exec(line);
    if (entry) out[entry[1] ?? entry[2]] = entry[3];
  }
  return out;
}

function parseUniqueScenes(src) {
  const start = src.indexOf("const SCENES:");
  const end = src.indexOf("const SCENE_OF:");
  if (start < 0 || end < 0 || end <= start) throw new Error("SCENES block not found in activity-scene.tsx");
  const block = src.slice(start, end);
  const out = [];
  for (const line of block.split("\n")) {
    const m = /^  (?:"([a-z0-9-]+)"|([a-z0-9-]+)):\s*\(?/.exec(line);
    if (m) out.push(m[1] ?? m[2]);
  }
  return out;
}

function parseDurationSeconds(token) {
  const m = /^(\d*\.?\d+)(ms|s)$/.exec(token.trim());
  if (!m) return null;
  const val = Number(m[1]);
  return m[2] === "ms" ? val / 1000 : val;
}

function normalizeTimingToken(token) {
  const t = token.trim();
  if (t === "var(--motion-ease)") return "cubic-bezier(0.16, 1, 0.3, 1)";
  return t;
}

function parseAnimationShorthand(value, defaults) {
  const tokens = [];
  let cur = "";
  let depth = 0;
  for (const ch of value.trim()) {
    if (ch === "(") depth++;
    else if (ch === ")" && depth > 0) depth--;
    if (/\s/.test(ch) && depth === 0) {
      if (cur) {
        tokens.push(cur);
        cur = "";
      }
    } else {
      cur += ch;
    }
  }
  if (cur) tokens.push(cur);

  const spec = { ...defaults };
  let sawDuration = false;
  for (const tok of tokens) {
    const dur = parseDurationSeconds(tok);
    if (dur !== null) {
      if (!sawDuration) {
        spec.duration = dur;
        sawDuration = true;
      }
      continue;
    }
    if (tok === "linear" || tok === "ease" || tok === "ease-in" || tok === "ease-out" || tok === "ease-in-out" || tok === "var(--motion-ease)" || /^steps\(\d+\)$/.test(tok) || /^cubic-bezier\(/.test(tok)) {
      spec.easing = normalizeTimingToken(tok);
    } else if (tok === "normal" || tok === "reverse" || tok === "alternate" || tok === "alternate-reverse") {
      spec.direction = tok;
    } else if (tok === "none" || tok === "forwards" || tok === "backwards" || tok === "both") {
      spec.fillMode = tok;
    } else if (tok !== "infinite" && !tok.startsWith("scene-")) {
      // ignore counts or unrelated tokens
    } else if (tok.startsWith("scene-")) {
      spec.name = tok;
    }
  }
  return spec;
}

function parseStops(body) {
  const stops = new Set();
  for (const m of body.matchAll(/([^{}]+)\{[^}]*\}/g)) {
    for (const part of m[1].split(",")) {
      const p = part.trim();
      if (p === "from") stops.add(0);
      else if (p === "to") stops.add(100);
      else if (p.endsWith("%")) {
        const n = Number(p.slice(0, -1));
        if (Number.isFinite(n)) stops.add(n);
      }
    }
  }
  return [...stops].sort((a, b) => a - b);
}

function parseCssAnimations(css) {
  const start = css.indexOf(".scene-layer");
  const end = css.indexOf("/*\n * The step rail");
  if (start < 0 || end < 0 || end <= start) throw new Error("Scene CSS section not found in globals.css");
  const slice = css.slice(start, end).replace(/\/\*[\s\S]*?\*\//g, "");

  const keyframes = new Map();
  for (const m of slice.matchAll(/@keyframes\s+(scene-[a-z0-9-]+)\s*\{((?:[^{}]*|\{[^}]*\})*)\}/g)) {
    keyframes.set(m[1], parseStops(m[2]));
  }

  // Strip @keyframes blocks before reading class rules.
  const withoutKf = slice.replace(/@keyframes\s+scene-[a-z0-9-]+\s*\{(?:[^{}]*|\{[^}]*\})*\}/g, "");

  const storyBase = { duration: 4.8, easing: "ease-out", direction: "normal", fillMode: "both" };
  const rulesByClass = new Map();
  for (const m of withoutKf.matchAll(/([^{}]+)\{([^}]+)\}/g)) {
    const selectors = m[1]
      .split(",")
      .map((s) => s.trim())
      .filter((s) => /^\.scene-[a-z0-9-]+$/.test(s));
    if (!selectors.length) continue;
    const body = m[2];
    for (const sel of selectors) {
      const prev = rulesByClass.get(sel) ?? {};
      const next = { ...prev };
      const anim = /animation\s*:\s*([^;]+)/.exec(body);
      if (anim) {
        Object.assign(next, parseAnimationShorthand(anim[1], { duration: null, easing: "ease", direction: "normal", fillMode: "none" }));
      }
      const animName = /animation-name\s*:\s*([^;]+)/.exec(body);
      if (animName) next.name = animName[1].trim();
      const animTiming = /animation-timing-function\s*:\s*([^;]+)/.exec(body);
      if (animTiming) next.easing = normalizeTimingToken(animTiming[1]);
      const animDir = /animation-direction\s*:\s*([^;]+)/.exec(body);
      if (animDir) next.direction = animDir[1].trim();
      const animFill = /animation-fill-mode\s*:\s*([^;]+)/.exec(body);
      if (animFill) next.fillMode = animFill[1].trim();
      const animDur = /animation-duration\s*:\s*([^;]+)/.exec(body);
      if (animDur) {
        const d = parseDurationSeconds(animDur[1]);
        if (d !== null) next.duration = d;
      }
      rulesByClass.set(sel, next);
    }
  }

  // Group resolved usages by keyframe name.
  const usagesByKf = new Map();
  for (const [cls, rule] of rulesByClass.entries()) {
    const kfName = rule.name;
    if (!kfName) continue;
    const isStoryImplicit = cls !== ".scene-in" && cls !== ".scene-out" && rule.duration == null;
    const resolved = {
      className: cls.slice(1),
      duration: rule.duration ?? (isStoryImplicit ? storyBase.duration : null),
      easing: rule.easing ?? (isStoryImplicit ? storyBase.easing : "ease"),
      direction: rule.direction ?? "normal",
      fillMode: rule.fillMode ?? (isStoryImplicit ? storyBase.fillMode : "none"),
    };
    const arr = usagesByKf.get(kfName) ?? [];
    arr.push(resolved);
    usagesByKf.set(kfName, arr);
  }

  const transitions = {};
  const animations = {};
  for (const [kfName, stops] of [...keyframes.entries()].sort((a, b) => a[0].localeCompare(b[0]))) {
    const usages = usagesByKf.get(kfName) ?? [];
    if (!usages.length) throw new Error(`No CSS rule references @keyframes ${kfName}`);
    const first = usages[0];
    const directions = [...new Set(usages.map((u) => u.direction))];
    const entry = {
      duration: first.duration,
      easing: first.easing,
      direction: directions.length === 1 ? directions[0] : first.direction,
      ...(directions.length > 1 ? { directions } : {}),
      fillMode: first.fillMode,
      stops,
    };
    if (kfName === "scene-in" || kfName === "scene-out") {
      transitions[kfName] = entry;
    } else {
      animations[kfName] = entry;
    }
  }

  return { transitions, animations };
}

const kinds = parseKinds(chatUiSrc);
const uniqueScenes = parseUniqueScenes(sceneTsxSrc);
const splitAliases = parseSplitAliases(sceneTsxSrc);
const timing = {
  holdMs: parseConstMs(sceneTsxSrc, "HOLD_MS"),
  fadeMs: parseConstMs(sceneTsxSrc, "FADE_MS"),
  windDownMs: parseConstMs(sceneTsxSrc, "WIND_DOWN_MS"),
};
const { transitions, animations } = parseCssAnimations(globalsCssSrc);

if (uniqueScenes.length + Object.keys(splitAliases).length !== kinds.length) {
  throw new Error(
    `Count mismatch: uniqueScenes (${uniqueScenes.length}) + splitAliases (${Object.keys(splitAliases).length}) !== kinds (${kinds.length})`,
  );
}

const outDir = join(repoRoot, "protocol/activity-scenes");
mkdirSync(outDir, { recursive: true });
const outPath = join(outDir, "fixtures.json");
const payload = {
  viewBox: { width: 132, height: 56 },
  timing,
  kinds,
  uniqueScenes,
  splitAliases,
  transitions,
  animations,
};
writeFileSync(outPath, JSON.stringify(payload, null, 2) + "\n");
console.log(
  `wrote protocol/activity-scenes/fixtures.json: ${kinds.length} kinds (${uniqueScenes.length} unique + ${Object.keys(splitAliases).length} aliases), ${Object.keys(animations).length} animations, ${Object.keys(transitions).length} transitions`,
);
