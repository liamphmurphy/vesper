// npm run gen:inter-metrics: regenerates lib/designs/inter-metrics.json from the Inter TTFs in
// fonts/designs/.
import { readFileSync, writeFileSync } from "node:fs";
import { buildMetrics } from "../lib/designs/inter-metrics-gen.ts";

const dir = new URL("../fonts/designs/", import.meta.url);
const table = buildMetrics((f) => readFileSync(new URL(f, dir)));
const out = JSON.stringify(table) + "\n";
writeFileSync(new URL("../lib/designs/inter-metrics.json", import.meta.url), out);
writeFileSync(new URL("../../macos/Sources/VesperCore/Resources/designs/inter-metrics.json", import.meta.url), out);
console.log("wrote inter-metrics.json");
