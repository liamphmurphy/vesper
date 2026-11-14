# ADR: Designs: body schema, persistence, persona suggestions, rendering and export

- **Status:** Proposed. Implementation tickets ([[LAZYAGENTS-146]] onwards) start once Liam approves it.
- **Ticket:** [[LAZYAGENTS-145]], the first ticket of the epic "Designs app: flows, diagrams and wireframes with personas"
- **Mockups (approved):**
  - Home: `docs/design/designs-home.svg`
  - Editor: `docs/design/designs-editor.svg`
  - Review: `docs/design/designs-review.svg`
  - From a persona chat: `docs/design/designs-from-chat.svg`
- **Evidence:**
  - Schema: `docs/design/schema/design-1.schema.json`
  - Shared acceptance design: `docs/design/fixtures/acceptance-design.json`, with `fixtures/landscape.png` and `fixtures/checkout.mmd`
  - Proof of concept: `docs/design/poc/`. Its outputs and `report.json` are in `docs/design/poc/evidence/`.
- **Modelled on:** `docs/slides/ADR-slides.md`. Designs reuses its persistence, text model and export delivery, and changes what Slides couldn't carry over.

## 1. Context

Designs is the third app in the Docs and Slides family. A person and a persona build app flows, diagrams and wireframes together on an infinite canvas. The approved mockups and the epic set the scope:

- **Editor:**
  - pages, frames with device presets, shapes, text, images and vector paths;
  - auto layout, layers and an inspector (Design / Prototype / Inspect);
  - autosave and undo.
- **Diagramming:** connectors with routing, stickies, sections and Mermaid import.
- **Prototyping:** links between frames and a Present mode.
- **Components and tokens:**
  - components and instances;
  - token snapshots of `web/styles/tokens.css` (Dusk), with a sync badge.
- **Persona work arrives as suggestions by default.** The person accepts or rejects each change with a reason. A per-design switch lets the persona edit directly.
- **Design from chat:** a design can be created from a persona chat, opens beside it, and leaves a Design card.
- **Ticket context:** frames can be sent to a ticket, and its runs get them as context.
- **Export:** PNG, SVG and PDF, matching the editor, downloadable or saved to the Library.

The hard constraints that Slides didn't have:

1. **A server renderer.** `design_render` gives the persona a PNG, ticket runs get frame PNGs as context files, and PNG export uses the same renderer. Slides kept the server renderer-free. Designs can't, so the editor and the server must draw the same pixels from one source.
2. **Scale.** Flows and diagrams grow into thousands of nodes on one page. Slides capped decks at 100 elements per slide.
3. **Suggestions as the default.** A Slides persona edits the deck, and the person reviews the result afterwards. In Designs, a persona's patch is held as a proposal and doesn't touch the design until the person accepts it.

## 2. Options considered

### 2.1 Content model

| Option | Verdict |
|---|---|
| **A. Our own JSON tree (pages → nodes), stored as a new canvas kind `design`** | **Chosen.** Same reasoning as Slides §2. Stable ids give per-node review, merge, undo, comments and proposals. One validator in Go and one in TypeScript. Fits the canvas version and 409 machinery unchanged. |
| B. SVG canvas (`kind=svg`, `data-vid` ops) | Rejected. It has no auto layout, components, connectors-as-relations or prototype links, and no text wrapping. |
| C. Reuse the Slides deck schema with an "infinite slide" | Rejected. Slides' geometry is absolute and flat, with one group level. Auto layout, nesting, instances and connectors would turn it into a different schema anyway. We reuse its **text model** and **shape presets** instead (§3.4). |
| D. tldraw / Excalidraw / Penpot engines | Rejected. Same as Slides: licence (tldraw is commercial), whiteboard-only semantics (Excalidraw), or a whole separate app (Penpot, MPL, Clojure). We'd still need our own schema for proposals, inspect and export. |

### 2.2 Where the server renderer runs

The display list is TypeScript (`web/lib/designs/`), because the editor needs it at 60 fps. The server has to run the same code.

| Option | For | Against | Verdict |
|---|---|---|---|
| **A. A Node "design worker" in the web container: an internal route that runs `web/lib/designs` and rasterises with resvg (`@resvg/resvg-js`, MPL-2.0)** | The same module the editor runs. resvg takes the Inter TTFs directly, with no system fonts, so its output is deterministic. The web image is already Node 24. | The Go API calls the web container for renders, which is a new internal hop with a shared secret. | **Chosen** |
| B. Port the layout to Go and rasterise in Go | No new hop | Two layout engines drift. Go has no SVG/text rasteriser of resvg's quality, and the API is `CGO_ENABLED=0` on distroless. | Rejected |
| C. Headless Chromium on the server | Pixel-identical to Chrome | A ~300 MB browser, plus sandboxing and memory limits (Slides §4.1 rejected it for the same reasons) | Rejected |
| D. Go + goja (JS) + resvg compiled to WASM (wazero) | Keeps the API one static binary | Two unproven integrations, and slow text measurement in goja | Rejected for v1. Revisit if the hop becomes a problem. |

### 2.3 Text measurement

Slides measures with canvas `measureText` in the browser, and only the browser lays text out. Designs lays out on the server too, so measurement can't depend on a canvas.

**Decision:** a generated **advance-width table** per Inter face (`web/lib/designs/inter-metrics.json`, built from the shipped TTFs). Measuring is plain arithmetic, identical in both runtimes.
- Renderers draw with kerning off (`font-kerning: none`, `"kern" 0`), so the drawn text matches the measured widths.
- One `<text>` is emitted per measured piece, so any rounding difference can't move the next word.
- A build test fails if the TTFs and the table drift.

### 2.4 Mermaid parsing

Mermaid's own parser needs a DOM (DOMPurify), which the PoC confirmed: `mermaid.parse` throws in Node. `design_import` runs in the worker.

**Decision:** a small parser for the flowchart subset, in `web/lib/designs/mermaid.ts`, with ELK (`elkjs`, EPL-2.0, already a transitive dependency of `mermaid` in `web/`) for layered layout and orthogonal routing. Anything outside the subset is refused with the line number and the failing text. Styling statements are skipped with a warning.

## 3. Decision

### 3.1 The body: schema 1

A design is one JSON document, the body of a `chat_canvases` row with `kind = 'design'`.
- **Structure:** `schema/design-1.schema.json` (JSON Schema 2020-12).
- **Complete example:** `fixtures/acceptance-design.json`.

```
Design     { schema: 1, mode: "dark"|"light", tokens_ref?: TokensRef, token_sets: {[key]: TokenSet},
             assets: {[a_id]: Asset}, pages: Page[1..50], links: Link[] }
Page       { id: p_…, name, background?: Color, children: Node[] }               // paint order = array order
Node       common { id: n_…, type, name?, x, y, w, h, rotation?, opacity?, visible?, locked?,
                    sizing?: {w,h: "fixed"|"hug"|"fill"}, absolute?: bool, constraints?: {h, v} }
  frame      container + styled { preset?: "iphone-15"|…, radius?, clip?, mode?, auto_layout?, linked_tickets?, linked_paths? }
  component  same fields as frame; the main of a component
  instance   { component: n_…, overrides?: {[descendant id of the main]: {text?, fill?, visible?}} }
  group      { children[1..] }                       // box = children's box; no styling
  section    { fill?: Color, children }              // diagram area with a title; moving it moves its contents
  shape      styled { shape: "rect"|"roundRect"|"ellipse"|<the 18 Slides presets>, radius?, text?: TextBox }
  path       styled { d: "M/L/C/Q/Z" in node coordinates, cap?, join? }    // the vector pen's output
  text       { paragraphs: Paragraph[], valign? }    // the Slides text model, §3.4
  image      { asset: a_…, fit?: "cover"|"contain"|"fill", crop?: {l,t,r,b}, radius?, alt? }
  sticky     { text, color?: yellow|pink|green|blue|violet|grey, author? }
  connector  { from: {node, anchor?}, to: {node, anchor?}, route?: "orthogonal"|"straight", label?,
               stroke?, stroke_width?, dash?, start_arrow?, end_arrow?: "none"|"arrow"|"dot", points?: [x,y][] }   // no box
styled     { fill?: Paint, stroke?: Color, stroke_width?, dash?: Dash }
AutoLayout { direction: "horizontal"|"vertical", gap?, padding?: [t,r,b,l], align?: "start"|"center"|"end" (cross axis),
             justify?: "start"|"center"|"end"|"space-between" (main axis) }
Link       { id: k_…, from: n_… (any node: the hotspot), to: n_… (a top-level frame), trigger: "click"|"hover"|"after-delay",
             delay_ms?, transition: "instant"|"dissolve"|"slide-left|right|up|down"|"smart-animate", duration_ms? }
Color      "#RRGGBB" | "#RRGGBBAA" | "$token-name"           // upper-case hex after normalisation
Paint      Color | { angle, stops: [Color, Color] }          // as Slides
TokensRef  { set, source, hash: "sha256:…", synced_at }
TokenSet   { name, source: path|null, modes: { dark: Tokens, light?: Tokens } }
Tokens     { [name]: {kind: "color", value: "#RRGGBB(AA)"} | {kind: "dimension", value: "<n>px"} }
Asset      { mime: "image/png"|"image/jpeg", w, h, alt? }    // bytes in the blob store, as Slides §3.5
```

**Naming.**
- Designs' own fields are `snake_case`, like the rest of the API.
- `Paragraph`, `Run` and `TextBox` are the Slides types unchanged (`spaceBefore`, `lineSpacing`), so `lib/slides` text code is reused without an adapter.
- Two Slides fields are handled differently. `font` is refused, because the font is always Inter. `bold` is normalised to `weight: 700`, and `weight` (400, 500, 600 or 700) is the one addition.

**Stable ids.**
- Ids are opaque: a prefix (`p_`, `n_`, `k_`, `a_`) plus 10 random base32 characters. Fixtures may use readable ids that match `^[a-z]_[a-z0-9_]{1,40}$`.
- The editor mints ids. The server mints them for persona ops that omit one, when the proposal is created, so the review can point at them.
- Ids are never reused within a design. Duplicating a design or a node mints new ids.
- Instance children are addressed as `instanceId/mainChildId` at run time, and never stored.
- Ids are the unit of diffing, merging, undo, proposals, comment anchors and Send to ticket.

**Validation and normalisation** follow the pattern "Validate overrides in normalize, cap in one place".
- `server/internal/design.Normalize` runs from `canvas.normalize` for kind `design`.
- `web/lib/designs/schema.ts` mirrors it, so the editor never sends a body the server would refuse.
- **Normalisation:**
  - round numbers to 0.01;
  - upper-case hex;
  - `bold` becomes `weight: 700`;
  - drop default values;
  - re-encode compactly.
- **Rules:** the JSON Schema, plus these, which JSON Schema can't express (`poc/validate.mjs` implements both, and §5.1 lists the refused cases):
  - unique ids across pages, nodes and links;
  - children only in frame, component, group or section;
  - `fill` sizing only under an auto-layout parent;
  - `hug` sizing only on text, instances or auto-layout containers;
  - every `$token` is a colour in `tokens_ref.set`;
  - every image asset is in `assets`;
  - a crop must leave some of the image;
  - instances point at a `component`, and their overrides at the main's descendants;
  - a component can't contain an instance of itself;
  - connectors join two non-connector nodes on the same page and never sit in a group;
  - links go to a top-level frame, and `after-delay` needs `delay_ms`. A link whose target no longer exists (a merge removed the frame) stays valid but **broken**: the Prototype tab flags it, Present and `design_flows` skip it ([[LAZYAGENTS-149]]). A target that exists but isn't a top-level frame is still refused.
- **Shared test cases:** the Go and TS validators run the same table of invalid bodies (the §5.1 list, kept as `web/lib/designs/fixtures/invalid/*.json`).

**Caps** (one constant each, in `server/internal/design`; `canvas.maxBodyFor(kind)` is the single place the body cap is applied):

| Cap | Value | Why |
|---|---|---|
| Body | **2 MB** (Docs, SVG and decks stay at 512 KB) | The 2 035-node PoC design is 404 KB compact, so 2 MB gives ~5× headroom. |
| Nodes per design | 10 000 | About 5× the pan/zoom PoC. Beyond that, culling (§3.8) becomes required. |
| Nesting depth | 32 | |
| Characters per text node | 5 000 | Same as Slides |
| Pages | 50 | |
| Links | 2 000 | |
| Token sets | 8 | |
| Assets | 200 | |
| Ops per patch | 100 | The existing `canvas.maxOps` |

**Schema versioning** works as in Slides:
- Upgrades are pure `vN → vN+1` functions, applied on read and persisted on the next save.
- Readers refuse a `schema` newer than they know.

### 3.2 Coordinates and auto layout

**Coordinates.**
- Design pixels. The origin is top-left and y points down.
- A top-level node's `x, y` are page coordinates. A child's are relative to its parent's top-left.
- Rotation is clockwise degrees about the node's centre.
- Pages are unbounded. The camera is `(zoom 0.02–8, centre x, centre y)`, per person and page, kept in local storage and not in the body.
- **Device presets** only seed `w × h`. They are a label and aren't constraints. v1 presets:
  - iPhone 15 393×852
  - iPhone 15 Pro Max 430×932
  - Android 412×915
  - iPad 820×1180
  - Desktop 1440×900
  - Web 1280×800

**Auto layout.** This is Figma's model, cut down. The PoC implements all of it (`poc/layout.mjs`).
- A container with `auto_layout` places its flow children (not `absolute`, not hidden, not connectors) along `direction`, with `gap` and `padding`.
- `justify` positions the run on the main axis. `space-between` overrides `gap`.
- `align` positions each child on the cross axis.
- **Child sizing, per axis:**
  - `fixed` uses `w`/`h`.
  - `hug` uses the intrinsic size: for text, the unwrapped width, or the wrapped height at its width; for a container, its children plus padding and gaps.
  - `fill` takes an equal share of the leftover main-axis space, or the full inner cross size.
- **Order of evaluation:** widths first, then heights at those widths (text wraps to its width), then positions.
- `x, y, w, h` stored on auto-laid children are a cache. Every renderer recomputes them. The editor writes the fresh values when it saves.
- **Constraints** (`left|right|left-right|center|scale`, and the vertical equivalents) apply only to children of a non-auto-layout container, when that container is resized. That includes an instance resized away from its main.
- No wrap, min/max sizes or baseline alignment in v1.

### 3.3 Components and instances

- **Main component:** a `component` node can sit on any page. The mockups use a "Components" page.
- **Instance:** an `instance` renders its main's subtree at its own size, with `overrides` keyed by the main's descendant ids:
  - `text` replaces the first run's text and keeps its style;
  - `fill`;
  - `visible`.
- **Propagation:** editing the main changes every instance on the next layout. Overrides survive, because they're keyed by id. An override whose id has gone is dropped on the next normalise.
- **Detach:** an op that replaces the instance with a `frame` holding a copy of the expanded subtree, with new ids.
- **Scope:** components are local to a design in v1. Cross-design libraries are deferred (§8).

### 3.4 Text and Inter

- **The model is Slides' (§3.4 there).** Paragraphs of runs, with:
  - run marks: weight 400, 500, 600 or 700; italic, underline, strike, colour and highlight;
  - paragraph properties: left/centre/right/justify alignment, bullets, five levels, space before, line spacing 0.8–3×.
  - The layout constants are the same as Slides: line height = 1.2 × the largest run × lineSpacing, half-leading, greedy word wrap, and a long word broken between characters.
- **Insets:** a text node has **no inset**, as design tools expect. Shape text has 8 and stickies 12.
- **Overflow** is reported, never hidden, as in Slides.
- **One family: Inter 4.1** (rsms/inter, SIL OFL 1.1, free to bundle and embed).
  - We ship the **static** faces Regular, Medium, SemiBold and Bold, roman and italic (8 faces), not the variable font. Static faces measure identically everywhere, and resvg and jsPDF handle them without variation support.
  - The app UI's own `next/font` Inter (variable, with `cv11`/`ss01`/`ss03`) is separate. Designs draw default glyphs, so a design looks the same on every machine.
- **Bundling:**
  - `web/public/fonts/designs/Inter-<Face>.woff2`: the editor loads these with `FontFace` before the first layout. They're also embedded in SVG export.
  - `web/public/fonts/designs/Inter-<Face>.ttf`: the design worker passes these to resvg as `fontFiles`, with `loadSystemFonts: false`. jsPDF embeds them in PDF export.
  - `web/lib/designs/inter-metrics.json`: advance widths, hhea ascent/descent, and underline and strikeout metrics, generated from the TTFs by `npm run gen:inter-metrics`, plus a drift test. `poc/metrics.mjs` is the generator.
  - Download script and checksum: `poc/fetch-fonts.py` (the zip's SHA-256 is pinned). The TTFs are about 3.3 MB for 8 faces, and the WOFF2 files about 0.9 MB. Each face loads when it's first used.
- **Glyph coverage:** Inter covers Latin, Greek and Cyrillic. The metrics table covers Latin, Latin-1, Latin Extended-A, punctuation, arrows and currency. Unknown code points measure as `.notdef`. The editor warns about them, as Slides does for emoji and CJK.

### 3.5 Tokens: snapshots and the sync badge

- **A token set is a snapshot.** A build step parses `web/styles/tokens.css` into `web/lib/designs/tokens.generated.json` (`poc/tokens.mjs` is the parser).
  - The `:root` block becomes `dark`.
  - The `:root[data-theme="light"]` overrides become `light`.
  - Colour tokens are normalised to `#RRGGBB(AA)`, `rgba()` included. `px` dimensions are kept. Fonts, shadows and composite values are skipped.
  - The snapshot is stamped `hash = sha256(tokens.css)`.
  - The fixture's snapshot has 111 dark and 83 light tokens.
- **A design holds its own copy** in `token_sets`, with `tokens_ref` naming the set in use, its source and the hash it was synced at. Nodes refer to tokens as `"$surface"`.
- **Mode:** `mode` on the design, overridable per frame. Light falls back to dark for a token that light doesn't override. Light and dark are the only modes.
- **Sync badge (client-side):**
  - When `tokens_ref.source === "web/styles/tokens.css"` and `tokens_ref.hash !== tokens.generated.json.hash`, the editor shows **"tokens.css changed, sync?"**.
  - Sync replaces the set with the current snapshot and stamps the hash and time, as one user version. Undo restores the old snapshot.
  - A token that disappeared makes sync list the nodes that use it, and the person picks a replacement or keeps the literal colour. Nothing recolours until the person syncs.
- **Per-design sets** (for example "Dusk (iOS)") have `source: null` and are edited in the inspector. Personas can propose token edits (`set_token`), never a sync.

### 3.6 Persistence, assets and the migration

- **Reuse `chat_canvases` and `chat_canvas_versions` with `kind = 'design'`.** That brings:
  - versions, `Restore` and seq conflicts (409 on a stale base);
  - `GetMyCanvas` ownership;
  - a per-design chat in an app space (`chat_spaces.app = 'designs'`);
  - `reviewed_seq`;
  - canvas comments (`chat_canvas_comments`, anchored `{node: n_…, x, y}` as fractions of the node's box).
- **Autosave, undo and conflicts work as in Slides §3.6,** with the three fixes the Slides review found:
  1. a stable `mutateAsync` dependency;
  2. canonical comparison (normalised JSON) for "unchanged";
  3. a history reset when the server or a merge replaces the working copy.
  - Conflicts merge three-way per node (and per page or link). Overlaps raise the Docs-style banner, and nothing is overwritten silently.
- **Assets** use the Slides pipeline:
  - `POST/GET /designs/{id}/assets[/{assetId}]`, PNG/JPEG only, 10 MB, longest edge 4096;
  - content-addressed blobs `designs/{workspace}/{user}/{sha256}`;
  - the 1 GB Library quota;
  - the trigger-queued blob sweep.
  - A new `design_assets` table has the same shape as `deck_assets`. Its trigger queues released keys into the existing `deck_blob_sweep`. The sweep deletes a key only when neither table references it, and the `designs/` and `slides/` prefixes keep the two kinds' blobs apart.
- **Migration `00113_designs.sql`** (number after the latest; a person applies it, because agents are denied `db:migrate`):
  - `chat_canvases.kind` gains `'design'`; `chat_spaces.app` gains `'designs'`. Slides missed the second at first; this migration doesn't.
  - `design_settings(canvas_id PK → chat_canvases ON DELETE CASCADE, direct_edit bool NOT NULL DEFAULT false, persona_paused bool NOT NULL DEFAULT false, project_id NULL → projects)`. The switch lives outside the body, so toggling it isn't a version and no patch can change it.
  - `design_assets(canvas_id, id, workspace_id, user_id, blob_key, mime, width, height, size_bytes, created_at)`, with the sweep trigger.
  - `design_proposals` (§3.7).
  - `design_frame_links(canvas_id, node_id, ticket_id → tickets ON DELETE CASCADE, PRIMARY KEY (canvas_id, node_id, ticket_id))`. It's an index of the body's `linked_tickets`, rewritten in the same transaction as every version, so runs can find a ticket's frames without scanning bodies.
  - Realtime: `notify_entity_change` triggers on `design_proposals` and `design_settings`.
  - **Down:** it deletes `kind='design'` canvases and their chats, so no orphans are left. Their blob keys are queued for the sweep before the tables drop. Then it drops the tables and narrows the CHECKs.
- **REST endpoints (all owner-scoped; another user's design is 404):**
  - `GET/POST /designs` {title?, starter?, project?}
  - `PATCH/DELETE /designs/{id}`
  - `POST /designs/{id}/duplicate`
  - `GET /designs/{id}/versions/{seq}`
  - `PATCH /designs/{id}/settings` {direct_edit?, persona_paused?}
  - `GET /designs/{id}/proposals`
  - `POST /designs/{id}/proposals/{pid}/resolve`
  - `GET /designs/{id}/render?node=&scale=` (PNG)
  - assets
  - Save goes through the existing canvas save with `base`.
- **Enum growth** is the same exercise as Slides §6:
  - `MyCanvasKind` and `ChatCanvas.kind` gain `design`;
  - every `Record<kind, …>` map and every switch on `kind` must handle it;
  - the chat canvas panel shows a design as a thumbnail with **Open in Designs**;
  - Docs keeps filtering `kind === "text"`;
  - Library's "save canvas as source" refuses `design`.

### 3.7 Persona suggestions and review

**Default: suggest.** A persona's `design_patch`, and `canvas_patch` on a design (so the generic tool can't bypass review), become a proposal:

```
design_proposals(id uuid PK, canvas_id → chat_canvases ON DELETE CASCADE, chat_id, run_id NULL, agent_id,
                 turn_id uuid NULL, base_seq int, summary text, ops jsonb,
                 status 'draft'|'pending'|'resolved'|'applied'|'withdrawn',
                 decisions jsonb DEFAULT '[]',   -- [{i, state: accepted|rejected|stale, reason?}]
                 result_seq int NULL, created_at, resolved_at NULL)
```

- **Creating a proposal:**
  - The server mints missing ids, then dry-runs the ops against `base_seq`. Any error rejects the whole patch with the op index, as Slides does.
  - Every op must carry a `why` (≤ 280 chars), and the patch a `summary`.
  - The design body is untouched.
  - The tool returns `{proposal_id, ops: n, nodes, pending_review: true}`, and the space instructions tell the persona to wait for the person. `nodes` lists the node each op is about, in op order, with the ids minted for nodes the persona left unnamed.
- **One turn, one result** (2026-11-14, superseding per-patch proposals and the live ghosts and cursor): the person sees what a persona made, not how.
  - During a chat turn, every `design_patch` and `design_import` joins that turn's **draft** (`status='draft'`, keyed by `turn_id`). Only the persona sees it: `design_read`, `design_outline` and `design_render` show the version with the draft applied, so later patches build on earlier ones. Lists, counts and the editor never show drafts.
  - When the turn ends, the runner publishes the draft (`designs.PublishSettled`); reading the design publishes any draft whose turn ended another way. Publishing applies the draft to the current version and stores the **net change** (`design.Diff`: a layer added then removed is nothing, one edited three times is one `set_node`, placement uses `after`/`before`). A change with no exact net form (a page reorder) keeps the steps that still apply.
  - The result is one pending suggestion, or a version by the persona when direct edit is on, or when the design holds nothing of the person's yet (untouched since version 1, its blank or starter beginning, and no suggestion pending or reviewed): a first draft needs no review, whoever started the design.
  - A persona's `design_create` in a turn makes version 1 blank and puts the starter in the draft, so placeholder frames (Start, Details, Done) are scaffolding only and never appear in a version or a review.
  - Outside a turn (an unmanaged token), a patch is still its own proposal, as below.
- **Dependencies:** op *j* depends on op *i* when it references an id that *i* creates (a child added to a new frame, or a link to a new frame). Review groups dependents under their parent. Accepting *j* accepts *i*. Rejecting *i* rejects *j*.
- **Review** (`designs-review.svg`, `web/lib/designs/review.ts`):
  - Each op is a change, with a numbered pin on the canvas and its `why`. Added changes are outlined green, changed ones amber, and removed ones red and dashed.
  - **Before / After / Diff** toggles.
  - **Accept**, **Reject** (with an optional reason) or **Discuss** (opens a comment thread on the node), per change.
  - **Accept all** / **Reject all** (the rest, once some are decided) settle every open change and apply in one click.
  - **Done** applies once every change has a decision.
- **Resolving** (`POST …/resolve` {decisions}) runs in one transaction:
  - The accepted ops are applied **on the current head**, not on `base_seq`. Ops are id-keyed, so they rebase.
  - An op whose target no longer exists is marked `stale` and skipped. The person's own later edits always win.
  - The result is one new version, authored by the person, with the note "Accepted n of Hackerman's m changes".
  - `result_seq` is recorded and `reviewed_seq` advances.
  - Rejections (with reasons) and stale ops go back to the persona as a system message in the design's chat: "Liam rejected 'Remove Promo code field': promo codes belong on Cart".
- **A newer proposal** from the same persona on the same nodes doesn't withdraw the older one. Both show, oldest first.
- **Direct edit on** (the per-design switch, "Let personas edit directly"):
  - Patches apply immediately as a version authored by the persona, and are recorded as a proposal with `status='applied'`, so history and the Design card can show them.
  - The editor receives the version over realtime and three-way merges it with unsaved local edits (§3.6). The person's unsaved edits are never overwritten.
  - **Undo** works on the persona's version as one step: the client inverts the per-node diff and saves a new version, as Slides undo does.
- **Pause** (`persona_paused`) makes `design_patch` and `design_import` fail with "Liam paused persona edits on this design" until the person resumes.
- **Presence** is a quiet "H is drafting changes…" chip with Pause while the persona's turn calls design tools on this canvas (from its in-flight tool calls; no new transport). Nothing is drawn on the canvas: the work is in the draft until the turn ends.
- **Selection context:** chat messages sent from the editor carry `{design, page, selection: [ids], viewport: {x, y, w, h, zoom}}` through the existing chat context. The space instructions tell the persona to treat "this" as the selection.

### 3.8 Shared rendering module

`web/lib/designs/` mirrors `lib/slides`:

- **Types and validation:**
  - `schema.ts`: types, `normalize`, `validate`;
  - `inter-metrics.json` and `measure.ts`;
  - `tokens.generated.json`.
- **Layout:** `layout.ts`. A node or a page becomes a **display list**: flat ops in page coordinates.
  - `rect` (radius), `ellipse`, `path`, `polyline`, `image` (source rect for crop and cover, rounded clip), `text` (one measured piece, baseline, weight, italic, size, colour), and `clip`/`unclip`.
  - It expands instances, resolves tokens per mode, and runs auto layout.
  - The PoC's `layout.mjs` is the template, and reuses the Slides wrap algorithm and shape presets (`lib/slides/geometry.ts`).
- **Connectors and import:**
  - `route.ts`: orthogonal connector routing. The PoC routes with stubs and one or two bends. Ticket 7 adds obstacle avoidance and re-routing on move.
  - `mermaid.ts`: the parser plus ELK.
- **Renderers, all drawing the same ops:**
  - `<DesignSvg>` (React): editor canvas, thumbnails, review, Present, and the Design card. Selection handles, pins, prototype wires and presence are overlays on top, not ops.
  - `toSvg(ops)` (string): SVG export, and the worker's input.
  - **The design worker:** `web/app/internal/designs/{render,layout,import}/route.ts`, Node runtime.
    - It's called by the Go API with `Authorization: Bearer $DESIGN_WORKER_TOKEN` (a new env var shared by api and web) at `DESIGN_WORKER_URL` (default `http://web:3000/internal/designs`).
    - It isn't routed publicly: the gateway's `/api`, `/events` and `/mcp` go to Go, and `/internal/*` is refused by middleware unless the token matches.
    - The input is body JSON, a node id and a scale. The output is a PNG.
    - Asset bytes are posted with the request as data URIs by Go, which owns the blob store. The worker has no database or storage access.
    - Resource limits: 4096 px longest edge, scale ≤ 3, at most 4 renders at a time (others get 503 and are retried), and a 10 s timeout.
    - `next.config` lists `@resvg/resvg-js` in `serverExternalPackages`. It ships musl prebuilds for the alpine image.
- **Pan/zoom** (proven in §5.2):
  - The camera is a `transform` attribute on the root `<g>`, updated per frame.
  - Viewport culling of top-level nodes (skip those whose box is off-screen by more than one screen) is required in the editor.
  - CSS-transform-during-gesture is kept as the fallback if a real profile shows main-thread pressure.

### 3.9 MCP tools

All tools take `canvas_id`, check ownership like `canvas_read`, and refuse non-design canvases. Each maps to an activity kind:
- `design`: the scene (ticket 5) plays while the tool runs.
- `design-view`: read tools, which share the scene, like `image-view`.
- Ticket 4 adds the mappings with these values, and the PR #255 drift test accepts them.

| Tool | Ticket | Input | Output | Kind |
|---|---|---|---|---|
| `design_list` | 4 | `project?` | `[{canvas_id, title, pages, frames, updated_at, pending_proposals}]` | design-view |
| `design_outline` | 4 | `canvas_id, page?, depth? (default 3)` | Compact tree `{id, type, name, box, children?, child_count}`, with boxes computed by the worker | design-view |
| `design_read` | 4 | `canvas_id, node_ids[] \| page` | Full nodes, with tokens shown as `{token, value}`, instance overrides and links touching them | design-view |
| `design_render` | 4 | `canvas_id, node_id \| page, scale? (1–3, default 1)` | MCP image content (PNG), plus `{w, h}` | design-view |
| `design_patch` | 4 | `canvas_id, base_version, summary, ops[] (each with why)` | `{proposal_id, nodes, pending_review}`, or `{version, nodes}` when direct edit is on. 409 on a stale base. | design |
| `design_comments` | 4 | `canvas_id, open_only?` | Threads with node anchors | design-view |
| `design_comment` / `design_reply` | 4 | `canvas_id, node_id, body` / `comment_id, body` | The comment | design |
| `design_create` | 5 | `title, project?, starter? (blank\|mobile-flow\|web-flow\|diagram\|wireframe)` | `{canvas_id, url}`; opens beside the chat | design |
| `design_flows` | 6 | `canvas_id, page?` | `{frames, links}` JSON plus a Mermaid `flowchart LR` of the prototype | design-view |
| `design_import` | 7 | `canvas_id, page, x?, y?, mermaid \| svg` | Like `design_patch` (a proposal unless direct edit is on). Mermaid errors name the line. | design |
| `design_components` | 8 | `canvas_id` | `[{id, name, page, instances}]` | design-view |
| `design_tokens` | 8 | `canvas_id` | `token_sets` and `tokens_ref`, plus whether tokens.css changed | design-view |
| `design_inspect` | 8 | `canvas_id, node_id, target: css\|tailwind\|react` | Code, spacing, type, token names and assets | design-view |
| `design_link_ticket` | 8 | `canvas_id, node_id, ticket` | A patch op `link_ticket`, so it follows the suggestion rules | design |

**`design_patch` ops.** Each op is `{op, …, why}`. Ids are server-minted where omitted.

| Op | Fields | Notes |
|---|---|---|
| `add_page` | `page: {name}`, `after?` | |
| `set_page` | `id`, `name?`, `background?` | |
| `remove_page` | `id` | Refused on the last page |
| `add_node` | `parent` (page or container id), `after?`, `node` (a subtree) | |
| `set_node` | `id`, fields | A merge patch. `paragraphs` and `children` aren't settable here. |
| `move_node` | `id`, `parent?`, `after?`, `x?`, `y?` | Reparent, reorder or move |
| `remove_node` | `id` | Also removes the connectors and links that touch it |
| `set_text` | `id`, `paragraphs` \| `text` | Plain `text` keeps the first run's style |
| `connect` | `from`, `to`, `label?`, `route?`, style | Creates a connector in the endpoints' lowest common container |
| `add_sticky` | `page`, `x`, `y`, `text`, `color?` | |
| `add_link` / `set_link` / `remove_link` | Link fields / `id` | |
| `create_component` | `id` (a frame), `name?` | Turns a frame into a component |
| `instantiate` | `component`, `parent`, `x`, `y`, `overrides?` | |
| `set_overrides` | `id`, `overrides` | |
| `detach` | `id` | |
| `set_token` | `set`, `name`, `mode`, `value` | Only on sets with `source: null` |
| `link_ticket` / `unlink_ticket` | `node`, `ticket` | |

The **space instructions** tell the persona to:
- outline first, then read the nodes it will change;
- patch with tokens, not hex;
- use auto layout for UI;
- give every op a specific `why`;
- never paste body JSON into the chat;
- render after a large patch, to check its work.

### 3.10 Export

The Export menu covers the selection, a frame, a page or all frames.

| Format | How | Delivery |
|---|---|---|
| **PNG** 1×/2×/3× | Server renderer (`GET /designs/{id}/render`), the same as `design_render` | Download, or save to the Library |
| **SVG** | `toSvg(display list)` in the browser. Text stays `<text>`. The used Inter faces are embedded as WOFF2 data URIs in `@font-face`, so it opens offline, plus a `font-family` fallback list. Images are inline data URIs. | Same |
| **PDF** | jsPDF from the display list, as Slides §4.1 does. One page per frame at the frame's size (1 px = 0.75 pt), in page order. Inter TTFs are embedded and subset by jsPDF. | Same |

- The Library save is a multipart upload to `POST /designs/{id}/library` ([[LAZYAGENTS-150]]), counted against the 1 GB quota. It is design-scoped rather than the generic `POST /library`, which stays images-only for a person's own uploads: the design endpoint checks ownership, ties the item to the design's chat, and accepts exactly the three export types, typed by content (PNG → `image`, SVG → `diagram`, PDF → `document`).
- A failure leaves no partial item: the upload happens only after the whole file is built, and the Library takes one file per save. A PNG or SVG export of several items is downloaded as a `.zip`; to keep several items in the Library, export them as one PDF.
- Scopes (`web/lib/designs/export.ts`): a selected node is drawn as its region of its top-level node, as the worker draws `node=`; "frame" is the top-level frame holding the selection, else the page's first; "page" is the whole page with its connectors; "all frames" is every visible top-level frame, in page order then layer order. Export draws the *saved* version (pending edits are saved first), so PNG from the server and SVG/PDF from the browser show the same thing.
- File names join the design title and the item name with an ASCII ` - `: Chromium drops a `download` name with non-ASCII characters.
- The comparison test (`web/e2e/designs-export.spec.ts`) renders `n_pay` and `n_state` of the acceptance fixture through all three and pixel-diffs each against the editor references committed in `web/e2e/designs-export/`, using `poc/parity.mjs`'s method and the tolerance in §5.1. The SVG is opened from disk with the network off; the PDF is rasterised by pdf.js. Measured: PNG 0.026 % / 0.011 %, SVG 0 % / 0 %, PDF 0.026 % / 0.018 %.

### 3.11 Ticket runs get linked frames

`runner.ContextFiles` ([[LAZYAGENTS-126]]) gains linked design frames: for each `design_frame_links` row of the ticket, and of its epic for epic runs:
- `designs/<design>-<frame>.png`, from the worker at 1×;
- `designs/<design>-<frame>.md`, the `design_inspect` React output plus `linked_paths`.

At most 10 frames. A render failure becomes a note in the `.md` file and doesn't fail the run.

## 4. Reuse versus extension

- **Reused unchanged:**
  - canvas versions, Restore and 409;
  - `GetMyCanvas`;
  - app spaces;
  - `Conversation`;
  - canvas comments;
  - `reviewBase`;
  - the Slides text wrap and shape presets;
  - the Slides asset pipeline and sweep;
  - the `ExportMenu` structure;
  - the Present-mode shell from Slides (`/present/designs/{id}`).
- **Extended:**
  - `canvas.normalize` and `canvas.Apply` gain kind `design`;
  - `canvas.maxBodyFor(kind)`;
  - `canvas_read` and `canvas_patch` accept designs, and `canvas_patch` goes through proposals;
  - `MyCanvasKind`;
  - the activity-kind map;
  - `ContextFiles`;
  - the exact MCP tool lists in `httpapi/mcp_profiles_test.go` and `chat_tools_test.go`.
- **New:**
  - `server/internal/design` (normalize, ops, proposals, settings, frame links, the worker client);
  - `server/internal/httpapi/designs.go`;
  - `web/lib/designs/*`;
  - `web/app/(app)/apps/designs/**`;
  - `web/app/internal/designs/*`;
  - `web/public/fonts/designs/*`;
  - migration 00113.
- **Docs and Slides regressions:** neither code path changes except the per-kind body cap. `web/e2e/docs-app.spec.ts` and the Slides specs must stay green (epic criterion 8).

## 5. Proof of concept (evidence)

To reproduce: `cd docs/design/poc && npm ci && python3 -I fetch-fonts.py && node run.mjs`. It needs a Playwright Chromium, for example `PLAYWRIGHT_BROWSERS_PATH` or `npx playwright-core install chromium`. Every number below is from `evidence/report.json`, generated with Chromium 158.0.8127.18 headless on Linux x86-64 (18 cores, software compositing, no GPU).

### 5.1 Server PNG matches the editor

- **Method.**
  - `layout.mjs` turns a node of the acceptance fixture into a display list, and `svg.mjs` turns that into one SVG string.
  - **Editor:** that SVG inline in Chromium, with the Inter faces loaded through `@font-face`, screenshotted at deviceScaleFactor 2.
  - **Server:** the same SVG rasterised by resvg 2.6.2 at 2×, with the Inter TTFs passed in and system fonts off.
  - `pixelmatch` (threshold 0.1) counts differing pixels, first excluding the pixels it classifies as anti-aliasing, then including them.
- **Results:**

  | Target | What it covers | Size @2× | Differing pixels | With anti-aliasing |
  |---|---|---|---|---|
  | `n_pay` (Payment frame) | Inter 400/500/600 and italic, mixed runs with underline, wrapped paragraph, nested horizontal and vertical auto layout with `fill`/`hug`, a cropped and covered image with a rounded clip, a component instance with a text override, tokens | 786×1704 | **347 (0.026 %)** | 5 619 (0.42 %) |
  | `n_state` (Order state section) | Shapes with centred text (roundRect, diamond, pills), four orthogonal connectors with arrowheads, labels and a dashed one, a sticky with an author line, a section title | 1440×840 | **133 (0.011 %)** | 2 434 (0.20 %) |

- **Images** (`evidence/parity/`): `<id>-editor.png`, `<id>-server.png`, `<id>-diff.png` (red marks a real difference, yellow anti-aliasing) and `<id>-side-by-side.png` (editor | server | diff).
- **What the differences are:** every differing pixel is on glyph edges. Chromium (Skia) and resvg (tiny-skia) rasterise anti-aliased glyph outlines slightly differently. No word is in a different place, because positions come from the shared layout. Shapes, the image and connectors match.
- **Tolerance for later tickets:** ≤ 0.1 % differing pixels (pixelmatch threshold 0.1, anti-aliasing excluded) for `design_render` (ticket 4) and PNG/SVG/PDF export (ticket 9) against the editor.

### 5.2 Pan/zoom with ~2k nodes

- **Design:** `poc/large.mjs` builds 40 iPhone frames, each a vertical auto-layout list of 12 rows (a row frame with horizontal auto layout, an avatar ellipse and two text nodes), plus 35 connectors.
  - **2 035 nodes**, 404 KB compact JSON. It passes the validator.
  - Layout takes **7.4 ms** in Node and produces 4 590 display ops, which become 4 632 SVG elements.
- **Method (`poc/panzoom.mjs`):**
  - 1440×900 viewport at 2×.
  - A scripted camera runs for 360 animation frames in three phases:
    - pan across the whole grid at overview zoom, where every node is on screen (the worst case for paint);
    - zoom 0.1× ↔ 2× and back;
    - pan at 100 %.
  - Recorded per frame:
    1. the `requestAnimationFrame` interval;
    2. from a Chromium trace: main-thread `BeginMainFrame` (style, layout, prepaint, paint), worker-thread raster time, and the interval between frames actually drawn (`Display::DrawAndSwap`).
- **Results:**

  | Strategy | rAF fps | rAF p95 | Main thread p50 / p95 / max | Raster per frame p50 / p95 | Drawn-frame interval p50 / p95 | Drawn frames > 33 ms |
  |---|---|---|---|---|---|---|
  | **`transform` attribute on the root `<g>`** (chosen) | 60.0 | 16.7 ms | 1.2 / 13.6 / 17.4 ms | 4.8 / 9.2 ms | 16.6 / 19.2 ms | 1 of 363 |
  | CSS transform on a wrapper (`will-change`) | 60.0 | 16.7 ms | 0.3 / 0.5 / 12.7 ms | 0 / 0.1 ms | 16.6 / 19.1 ms | 1 of 363 |

  The single slow drawn frame in each run is the first frame after load (initial raster). There were no long tasks.
- **Conclusion:** the plain SVG renderer holds 60 fps on 2k nodes, with every node visible, on software rasterisation. The attribute strategy keeps text crisp at every zoom. Its main-thread p95 of 13.6 ms is the margin to watch, which is why viewport culling (§3.8) is required, and the CSS strategy is the measured fallback.
- **Caveats:**
  - Headless Chromium with software compositing isn't a laptop GPU. A GPU is usually faster at raster but not at main-thread paint, which the attribute strategy is bound by.
  - Ticket 3 repeats the measurement in the real editor (React reconciliation included) with this script's camera path. The result goes into its acceptance criterion 7.

### 5.3 Mermaid flowchart → nodes and connectors

- **Input:** `fixtures/checkout.mmd` covers:
  - `flowchart LR`;
  - stadium, rect, diamond, circle, cylinder and flag shapes;
  - `-->|label|`, `-- label -->`, `-. label .->`, `-.->|label|`, `==>` and `---`;
  - a chain;
  - `&` fan-out;
  - a subgraph with a title;
  - `classDef`/`class`.
- **Output** (`evidence/mermaid/`):
  - `checkout.design.json`: one section with **11 shapes, 1 nested section (the subgraph) and 11 connectors** carrying routed `points`. It passes the validator.
  - `checkout.png`: drawn by the server renderer.
  - ELK layered (left to right) places the nodes and routes the edges orthogonally.
  - Edge points come back relative to the edge's ELK container and are shifted into the section's coordinates.
- **Warnings** (shown to the person, not errors):
  - `classDef` and `class` are ignored;
  - a cylinder is drawn as a rectangle;
  - an asymmetric (flag) shape is drawn as a rectangle.
- **Refusals,** each naming the problem:
  - `sequenceDiagram`: line 1, "only flowcharts can be imported";
  - `A -->`: "the edge has no target node";
  - `A[open --> B`: "node A opens [ but never closes it with ]";
  - `A ~~> B`: "expected an edge … or the end of the line";
  - an unterminated subgraph: "subgraph x has no 'end'";
  - empty text.

### 5.4 Schema and fixture

`validate.mjs` accepts `fixtures/acceptance-design.json` (34.6 KB). It refuses 12 invalid variants, each with a specific message (`report.json` → `validation.invalidCases`):
- an unknown field;
- an unknown token;
- a duplicate id;
- a link to a non-frame;
- a missing asset;
- a cross-page connector;
- an override outside the component;
- `font` on a run;
- children on a shape;
- `fill` without auto layout;
- un-normalised hex;
- schema 2.

The fixture's token snapshot hash equals the current `tokens.css` (`tokensInSync: true`).

### 5.5 Findings that shape implementation

1. **resvg matches font faces by family plus weight and style** when it's given the static TTFs, so `font-family="Inter" font-weight="600"` needs no per-face family names. Don't pass the variable font.
2. **Kerning must be off in both renderers,** and text emitted per measured piece. With that, word positions agree exactly and only glyph anti-aliasing differs.
3. **ELK returns an edge's points relative to the edge's container,** which is the subgraph for an edge inside it. Shift them by the container's absolute offset (`mermaid.mjs`).
4. **ELK ports sit on the bounding box,** so edges into a diamond stop at its box, short of the outline. Ticket 7's router clips the end segment to the shape outline.
5. **An auto-laid child's stored box goes stale** after a persona patch that the editor hasn't laid out yet. Persona-facing boxes (`design_outline`, `design_read`) therefore come from the worker's `layout`, not from the stored cache.

## 6. Feature matrix: which ticket delivers what

| Feature | Ticket |
|---|---|
| ADR, schema, fixture, PoC evidence | 1 [[LAZYAGENTS-145]] |
| Migration (kind, app, settings, assets, proposals, frame links); Go validator + TS validator with shared cases; body cap; 409; CRUD/duplicate/settings/assets/proposal endpoints; OpenAPI | 2 [[LAZYAGENTS-146]] |
| Apps entry; Home (starters, recent, filters); editor shell; `web/lib/designs` display list + `<DesignSvg>`; pan/zoom with culling; frames + presets; shapes; paths (vector pen); text in Inter; images; groups; auto layout + constraints; pages; layers; inspector Design tab; selection, multi-select and shortcuts; autosave, undo/redo, conflicts | 3 [[LAZYAGENTS-147]] |
| `design_list/outline/read/render/patch/comments/comment/reply`; design worker (render, layout); `canvas_*` on designs; proposals; Review overlay; direct-edit switch; presence; selection context; activity kinds | 4 [[LAZYAGENTS-148]] |
| `design_create`; + menu and `/design`; Design card; beside-chat panel with Pause; `design` scene | 5 [[LAZYAGENTS-151]] |
| Prototype tab, links and wires; Present mode; transitions (smart animate dissolves for now; tweening same-named nodes is a follow-up); `design_flows` | 6 [[LAZYAGENTS-149]] |
| Connectors with orthogonal routing and re-routing; stickies; sections; `design_import` (Mermaid; SVG where the mapping is clear); `connect`/`add_sticky` ops | 7 [[LAZYAGENTS-152]] |
| Components, instances, overrides and detach; token snapshots and the sync badge; per-design token sets; `design_components/tokens/inspect/link_ticket`; Inspect tab; Send to ticket; frames in run context | 8 [[LAZYAGENTS-153]] |
| Export menu: PNG 1/2/3× (server), SVG (text + embedded Inter), PDF (one page per frame); download or Library; comparison test | 9 [[LAZYAGENTS-150]] |

| Capability | Editor | Present | `design_render` / PNG | SVG export | PDF export |
|---|---|---|---|---|---|
| Frames, presets, clip, radius, fills, strokes, gradients | 3 | 6 | 4 | 9 | 9 |
| Text (Inter, Slides model) | 3 | 6 | 4 | 9 (text as text) | 9 (embedded) |
| Auto layout, constraints | 3 | 6 | 4 | 9 | 9 |
| Images (crop + cover, rounded) | 3 | 6 | 4 | 9 | 9 |
| Paths (vector pen) | 3 | 6 | 4 | 9 | 9 |
| Components and instances | 8 (3 renders instances) | 6 | 4 | 9 | 9 |
| Connectors, stickies, sections | 7 (3 renders them) | — | 4 | 9 | 9 |
| Prototype links | 6 (wires are an overlay) | 6 | — | — | — |
| Tokens and modes | 8 (3 resolves them) | 6 | 4 | 9 (flattened) | 9 (flattened) |
| Rotation | 3 | 6 | 4 | 9 | 9 |

## 7. Representative acceptance design

`fixtures/acceptance-design.json`, plus `fixtures/landscape.png` and `fixtures/checkout.mmd`. Every later ticket uses it unchanged: validator tests, editor rendering, `design_outline/read/render` tests, `design_flows`, Inspect, and export comparison. It contains:

- **Flows** page: four iPhone 15 frames (Cart → Shipping → Payment → Confirmation), wired by three prototype links: slide-left, slide-left, smart-animate.
  - **Cart:** a group (thumb and two-paragraph text), and a Button instance with the override "Checkout". Linked to LAZYAGENTS-150.
  - **Shipping:** a divider path with `fill` width, a wrapping address, and an instance "Continue".
  - **Payment:** title; a cropped and covered image with radius 12; a card-number field (horizontal auto layout, `hug` text); an Expiry · CVC row (two `fill` children); a mixed-run paragraph (600 weight, italic, underline, accent colour) that wraps three lines; and an instance "Pay $84.00". Linked to LAZYAGENTS-150 and `web/app/checkout/pay.tsx`.
  - **Confirmation:** a centred group (an ellipse and a round-capped tick path) and a centred title.
- **Diagrams** page: the "Order state" section, with a roundRect, a diamond and two pills with text, four orthogonal connectors (two labelled, one dashed `retry`), and a sticky by Liam.
- **Components** page: `Button / Primary`, a `hug` component with horizontal auto layout and a label text.
- **Tokens:** the `dusk-web` snapshot of `tokens.css` (dark and light), `mode: "dark"`.

## 8. Deferrals (confirm)

- Real-time multi-user editing. It's one person plus personas, with conflicts merged as in §3.6.
- Cross-design component libraries and shared token sets. Home's "Component libraries" and "Token sets" cards list what's in the person's designs read-only in v1.
- Variants and component properties beyond text, fill and visibility overrides.
- Auto-layout wrap, min/max sizes, baseline alignment, and absolute children inside instances.
- Boolean path operations, a path's own corner radius, and images other than PNG/JPEG. Image fills on shapes.
- Effects: shadows, blur, blend modes. Letter spacing and the app UI's Inter feature settings (`cv11`, `ss01`, `ss03`).
- Fonts other than Inter, and emoji/CJK fallback (the editor warns).
- Import from Figma or Excalidraw (Home lists Figma as "later"), Mermaid diagrams other than flowcharts, and Mermaid styling.
- Comments on prototype links, version branching, and design-to-code generation beyond Inspect output.
- Squashing autosave versions. A design version is larger than a deck's, so watch version volume. Squashing a person's consecutive versions within 2 minutes is the planned follow-up, as Slides §3.6 noted.

## 9. Consequences

- **Good:**
  - One display list drives the editor, the server PNG, SVG and PDF. §5.1 shows the editor and the server agree to within glyph anti-aliasing.
  - Suggestions are first-class and rebased per op, so a persona never silently overwrites the person.
  - Designs reuses Slides' text, assets, persistence and export delivery.
- **Costs:**
  - A Node-side worker with a new internal hop and a shared secret (`DESIGN_WORKER_URL`, `DESIGN_WORKER_TOKEN`), and a native addon (`@resvg/resvg-js`) in the web image.
  - Inter files: ~3.3 MB of TTF on the server and ~0.9 MB of WOFF2 in the browser, cached.
  - A second schema to keep in sync between Go and TS, guarded by the shared fixture and invalid cases.
  - A 2 MB body cap for this kind.
  - A migration a person must apply.
- **Risks to watch:**
  - Main-thread paint on large pages. Culling is required, and ticket 3 re-measures.
  - Version volume.
  - Worker availability: `design_render` errors must degrade to "render unavailable" text for the persona and runs.
  - Mermaid subset gaps, which are reported, never guessed.
