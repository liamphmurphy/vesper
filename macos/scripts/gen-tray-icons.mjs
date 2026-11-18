// Renders the menu bar (tray) icons into macos/Resources/tray/, which build-app.sh
// copies into the app. The star is the Vesper logo's
// sparkle. "Template" icons are black-on-transparent so macOS tints them for
// light/dark menu bars; the error icon is not a template so its red dot shows.
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";

// @resvg/resvg-js comes from web/node_modules (run `npm ci` in web/ first).
const { Resvg } = createRequire(import.meta.url)("../../web/node_modules/@resvg/resvg-js");

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.resolve(__dirname, "..", "Resources", "tray");

const STAR = "M11 2.2c.5 3.7 1.4 4.6 5.1 5.1-3.7.5-4.6 1.4-5.1 5.1-.5-3.7-1.4-4.6-5.1-5.1 3.7-.5 4.6-1.4 5.1-5.1Z";
const HORIZON = "M2 18.5c3-1.6 6-2.3 9-2.3s6 .7 9 2.3";

const icons = {
  // Running: solid star over the horizon.
  trayTemplate: `<path d="${STAR}" fill="#000"/><path d="${HORIZON}" stroke="#000" stroke-width="1.6" stroke-linecap="round" fill="none"/>`,
  // Starting / stopped: hollow star.
  trayStartingTemplate: `<path d="${STAR}" fill="none" stroke="#000" stroke-width="1.2"/><path d="${HORIZON}" stroke="#000" stroke-width="1.6" stroke-linecap="round" fill="none" stroke-dasharray="2 2"/>`,
  // Error: solid star with a red dot (not a template image).
  trayError: `<path d="${STAR}" fill="#8a8a8a"/><path d="${HORIZON}" stroke="#8a8a8a" stroke-width="1.6" stroke-linecap="round" fill="none"/><circle cx="17.5" cy="4.5" r="3.5" fill="#e5484d"/>`,
};

fs.mkdirSync(outDir, { recursive: true });
for (const [name, body] of Object.entries(icons)) {
  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="22" height="22" viewBox="0 0 22 22">${body}</svg>`;
  for (const [suffix, size] of [["", 22], ["@2x", 44]]) {
    const png = new Resvg(svg, { fitTo: { mode: "width", value: size } }).render().asPng();
    fs.writeFileSync(path.join(outDir, `${name}${suffix}.png`), png);
  }
}
console.log(`Wrote tray icons to ${outDir}`);
