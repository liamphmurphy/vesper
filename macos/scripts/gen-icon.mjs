// Renders macos/Resources/AppIcon.icns from design-worker/assets/logo.svg. Run: node macos/scripts/gen-icon.mjs
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

// @resvg/resvg-js comes from design-worker/node_modules (run `npm ci` in design-worker/ first).
const { Resvg } = createRequire(import.meta.url)("../../design-worker/node_modules/@resvg/resvg-js");

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const macosRoot = path.resolve(__dirname, "..");
const svgPath = path.resolve(macosRoot, "../design-worker/assets/logo.svg");
const buildDir = path.resolve(macosRoot, "Resources");

// Apple .icns OSType PNG chunk types and pixel dimensions.
const ICNS_CHUNKS = [
  ["icp4", 16],
  ["icp5", 32],
  ["icp6", 64],
  ["ic07", 128],
  ["ic08", 256],
  ["ic09", 512],
  ["ic10", 1024],
  ["ic11", 32],
  ["ic12", 64],
  ["ic13", 256],
  ["ic14", 512],
];

function renderPng(svgSource, size) {
  const resvg = new Resvg(svgSource, {
    fitTo: { mode: "width", value: size },
  });
  return Buffer.from(resvg.render().asPng());
}

function encodeIcns(chunks) {
  const totalSize = 8 + chunks.reduce((sum, entry) => sum + 8 + entry.png.length, 0);
  const out = Buffer.alloc(totalSize);
  out.write("icns", 0, 4, "ascii");
  out.writeUInt32BE(totalSize, 4);

  let offset = 8;
  for (const { type, png } of chunks) {
    out.write(type, offset, 4, "ascii");
    out.writeUInt32BE(8 + png.length, offset + 4);
    png.copy(out, offset + 8);
    offset += 8 + png.length;
  }
  return out;
}

const svgSource = fs.readFileSync(svgPath, "utf8");
fs.mkdirSync(buildDir, { recursive: true });

const pngCache = new Map();
for (const [, size] of ICNS_CHUNKS) {
  if (!pngCache.has(size)) {
    pngCache.set(size, renderPng(svgSource, size));
  }
}

const icnsChunks = ICNS_CHUNKS.map(([type, size]) => ({
  type,
  png: pngCache.get(size),
}));

const icnsBuffer = encodeIcns(icnsChunks);
fs.writeFileSync(path.join(buildDir, "AppIcon.icns"), icnsBuffer);

console.log(`Generated ${path.relative(macosRoot, path.join(buildDir, "AppIcon.icns"))} (${icnsBuffer.length} bytes)`);
