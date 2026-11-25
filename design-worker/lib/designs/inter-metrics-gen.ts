// Builds web/lib/designs/inter-metrics.json from the shipped Inter TTFs
// (ADR-designs §3.4): advance widths per code point, hhea ascent/descent and
// the underline and strikeout metrics, all as fractions of the em. A small
// reader of the four tables we need, so neither the generator nor the drift
// test needs a font library.

export const FACE_FILES: Record<string, string> = {
  "400": "Inter-Regular.ttf",
  "500": "Inter-Medium.ttf",
  "600": "Inter-SemiBold.ttf",
  "700": "Inter-Bold.ttf",
  "400i": "Inter-Italic.ttf",
  "500i": "Inter-MediumItalic.ttf",
  "600i": "Inter-SemiBoldItalic.ttf",
  "700i": "Inter-BoldItalic.ttf",
};

/** Basic Latin, Latin-1, Latin Extended-A, general punctuation, currency and arrows. */
export const RANGES: [number, number][] = [[0x20, 0x7e], [0xa0, 0x17f], [0x2000, 0x206f], [0x20a0, 0x20bf], [0x2190, 0x21ff]];

export type FaceMetrics = {
  adv: Record<string, number>;
  missing: number;
  asc: number;
  desc: number;
  underline: { pos: number; thick: number };
  strike: { pos: number; thick: number };
};

const r4 = (x: number) => Math.round(x * 10000) / 10000;

function tables(v: DataView): Map<string, number> {
  const out = new Map<string, number>();
  const n = v.getUint16(4);
  for (let i = 0; i < n; i++) {
    const at = 12 + i * 16;
    const tag = String.fromCharCode(v.getUint8(at), v.getUint8(at + 1), v.getUint8(at + 2), v.getUint8(at + 3));
    out.set(tag, v.getUint32(at + 8));
  }
  return out;
}

/** Code point → glyph index from the Unicode cmap (format 12 preferred, else format 4). */
function cmap(v: DataView, base: number): (cp: number) => number {
  const n = v.getUint16(base + 2);
  let f4 = -1;
  let f12 = -1;
  for (let i = 0; i < n; i++) {
    const at = base + 4 + i * 8;
    const pid = v.getUint16(at);
    const eid = v.getUint16(at + 2);
    const sub = base + v.getUint32(at + 4);
    const fmt = v.getUint16(sub);
    if (fmt === 12 && (pid === 0 || (pid === 3 && eid === 10))) f12 = sub;
    if (fmt === 4 && (pid === 0 || (pid === 3 && eid === 1))) f4 = sub;
  }
  if (f12 >= 0) {
    const groups = v.getUint32(f12 + 12);
    return (cp) => {
      for (let g = 0; g < groups; g++) {
        const at = f12 + 16 + g * 12;
        const s = v.getUint32(at);
        const e = v.getUint32(at + 4);
        if (cp >= s && cp <= e) return v.getUint32(at + 8) + cp - s;
      }
      return 0;
    };
  }
  if (f4 < 0) throw new Error("no Unicode cmap");
  const segs = v.getUint16(f4 + 6) / 2;
  const ends = f4 + 14;
  const starts = ends + segs * 2 + 2;
  const deltas = starts + segs * 2;
  const ranges = deltas + segs * 2;
  return (cp) => {
    for (let s = 0; s < segs; s++) {
      if (cp > v.getUint16(ends + s * 2)) continue;
      const start = v.getUint16(starts + s * 2);
      if (cp < start) return 0;
      const delta = v.getInt16(deltas + s * 2);
      const ro = v.getUint16(ranges + s * 2);
      if (!ro) return (cp + delta) & 0xffff;
      const g = v.getUint16(ranges + s * 2 + ro + (cp - start) * 2);
      return g ? (g + delta) & 0xffff : 0;
    }
    return 0;
  };
}

export function faceMetrics(buf: ArrayBuffer | Uint8Array): FaceMetrics {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  const v = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const t = tables(v);
  const need = (tag: string) => {
    const at = t.get(tag);
    if (at === undefined) throw new Error(`no ${tag} table`);
    return at;
  };
  const upm = v.getUint16(need("head") + 18);
  const hhea = need("hhea");
  const metricsCount = v.getUint16(hhea + 34);
  const hmtx = need("hmtx");
  const advance = (g: number) => v.getUint16(hmtx + Math.min(g, metricsCount - 1) * 4);
  const glyph = cmap(v, need("cmap"));
  const adv: Record<string, number> = {};
  for (const [a, b] of RANGES)
    for (let cp = a; cp <= b; cp++) {
      const g = glyph(cp);
      if (g) adv[cp] = r4(advance(g) / upm);
    }
  const post = need("post");
  const os2 = need("OS/2");
  return {
    adv,
    missing: r4(advance(0) / upm),
    asc: r4(v.getInt16(hhea + 4) / upm),
    desc: r4(-v.getInt16(hhea + 6) / upm),
    underline: { pos: r4(-v.getInt16(post + 8) / upm), thick: r4(v.getInt16(post + 10) / upm) },
    strike: { pos: r4(v.getInt16(os2 + 28) / upm), thick: r4(v.getInt16(os2 + 26) / upm) },
  };
}

/** The whole table, from a reader of the files in public/fonts/designs. */
export function buildMetrics(read: (file: string) => Uint8Array): Record<string, FaceMetrics> {
  return Object.fromEntries(Object.entries(FACE_FILES).map(([k, f]) => [k, faceMetrics(read(f))]));
}
