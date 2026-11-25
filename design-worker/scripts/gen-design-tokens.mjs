// npm run gen:design-tokens: rewrites lib/designs/tokens.generated.json (and the Go copy the API
// embeds) from styles/tokens.css.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { buildSnapshot } from "../lib/designs/tokens-gen.ts";

const read = (p) => readFileSync(new URL(p, import.meta.url), "utf8");
const css = read("../styles/tokens.css");
const snap = buildSnapshot(css, createHash("sha256").update(css).digest("hex"));
const out = JSON.stringify(snap, null, 1) + "\n";
writeFileSync(new URL("../lib/designs/tokens.generated.json", import.meta.url), out);
writeFileSync(new URL("../../server/internal/design/tokens.generated.json", import.meta.url), out);
console.log(`wrote tokens.generated.json: ${Object.keys(snap.modes.dark).length} dark, ${Object.keys(snap.modes.light).length} light, ${snap.hash}`);
