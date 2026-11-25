#!/usr/bin/env node
// Copies elkjs's self-contained bundle into macos/Sources/VesperCore/Resources/elk/ so the native
// Node Graph layout engine (VesperCore/Native/NodeGraph/ELKLayoutEngine.swift) runs ELK offline
// in JavaScriptCore with zero remote SwiftPM dependencies. Re-run after upgrading elkjs in
// design-worker/package.json:
//
//   node macos/scripts/build-elk-bundle.mjs        (needs design-worker/node_modules: npm --prefix design-worker ci)
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const repo = join(dirname(fileURLToPath(import.meta.url)), "../..");
const modules = join(repo, "design-worker/node_modules");
const out = join(repo, "macos/Sources/VesperCore/Resources/elk");
const pkg = JSON.parse(readFileSync(join(modules, "elkjs/package.json"), "utf8"));

mkdirSync(out, { recursive: true });

const elk = readFileSync(join(modules, "elkjs/lib/elk.bundled.js"), "utf8");
writeFileSync(join(out, "elk.bundled.js"), `/* elkjs ${pkg.version} (EPL-2.0), lib/elk.bundled.js */\n${elk}`);

console.log(`wrote ${join(out, "elk.bundled.js")} (elkjs ${pkg.version}, ${elk.length} bytes)`);
