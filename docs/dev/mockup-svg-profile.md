# Mockup SVG profile v1

A mockup is reviewed by a person before agents build from it, so its SVG must
mean exactly one picture. Profile v1 is the subset of SVG 1.1/2 that the Mac
app's native renderer (`macos/Sources/VesperCore/Native/MockupSVG/`) draws
completely. The server (`server/internal/artifacts/mockup_profile.go`) and the
app (`MockupSVGProfile`) enforce the same rules; the shared corpus in
`testdata/mockup-svg/` keeps them in step. Change this file, both validators
and the corpus together.

Every new mockup version must conform. Before validating, the server rewrites
simple CSS into presentation attributes (see "Normalization"). Versions saved
before v1 that don't conform are **legacy**: the app still shows them through
WebKit, labelled as legacy, and they can't be edited visually until a
conforming version replaces them.

The security rules in `ValidSVG` (no scripts, event handlers, external URLs,
DOCTYPE or entities) still apply first; v1 only narrows further.

## Document

- Root element `svg` in the SVG namespace (`http://www.w3.org/2000/svg`).
- The root needs a `viewBox` with positive width and height, or numeric
  `width` and `height` (then the viewBox is `0 0 width height`).
- At most 5,000 elements and a nesting depth of 32.
- Comments, the `<?xml ?>` declaration and whitespace are fine.

## Elements

Drawn: `svg` (root only), `g`, `rect`, `circle`, `ellipse`, `line`,
`polyline`, `polygon`, `path`, `text`, `tspan`, `image`, `use`.

Referenced (never drawn directly): `defs`, `symbol`, `linearGradient`,
`radialGradient`, `stop`, `clipPath`, `mask`, `pattern`, `marker`.

Ignored with their content: `title`, `desc`, `metadata`.

Anything else is rejected, including `style`, `filter` and `fe*`, `animate*`,
`set`, `foreignObject`, `switch`, `a`, `textPath`, nested `svg`, `view`,
`cursor` and `font`.

## Attributes

An attribute not listed here is rejected, except these, which are allowed and
ignored: `xmlns`, `xmlns:*`, `version`, `baseProfile`, `xml:space`, `xml:lang`,
`lang`, `role`, `aria-*`, `data-*` (canvases address elements by `data-vid`),
`focusable` and `pointer-events`.

| Group | Attributes |
|---|---|
| Identity | `id` |
| Viewport | `viewBox`, `preserveAspectRatio`, `width`, `height` (root, `use`, `image`, `rect`, `pattern`, `mask`, `symbol`) |
| Geometry | `x`, `y`, `width`, `height`, `rx`, `ry`, `cx`, `cy`, `r`, `fx`, `fy`, `fr`, `x1`, `y1`, `x2`, `y2`, `points`, `d`, `transform`, `dx`, `dy` |
| Paint | `fill`, `fill-opacity`, `fill-rule`, `stroke`, `stroke-width`, `stroke-opacity`, `stroke-dasharray`, `stroke-dashoffset`, `stroke-linecap`, `stroke-linejoin`, `stroke-miterlimit`, `opacity`, `color`, `display`, `visibility` |
| Clip and mask | `clip-path`, `clip-rule`, `mask`, `clipPathUnits`, `maskUnits`, `maskContentUnits` |
| Gradients | `gradientUnits`, `gradientTransform`, `spreadMethod`, `offset`, `stop-color`, `stop-opacity`, `href`, `xlink:href` |
| Patterns | `patternUnits`, `patternContentUnits`, `patternTransform` |
| Markers | `marker-start`, `marker-mid`, `marker-end`, `markerWidth`, `markerHeight`, `markerUnits`, `refX`, `refY`, `orient` |
| Text | `font-family`, `font-size`, `font-weight`, `font-style`, `text-anchor`, `dominant-baseline`, `letter-spacing`, `text-decoration` |

`style` and `class` are rejected after normalization.

## Values

- **Numbers and lengths**: a number with an optional `px`. `%` is allowed on
  `x`, `y`, `width`, `height`, `cx`, `cy`, `r`, `rx`, `ry`, `x1`, `y1`, `x2`,
  `y2`, `fx`, `fy`, `fr` and `offset` (relative to the viewBox, or to the
  bounding box under `objectBoundingBox` units). No other units. `x`, `y`,
  `dx` and `dy` take one value, not a list.
- **Colours**: `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()`,
  `hsl()`/`hsla()` (comma or space syntax, optional `/ alpha`), the 148 CSS
  named colours, `transparent`, `currentColor` and `none` (paint only).
- **Paint** (`fill`, `stroke`): a colour, `none`, or `url(#id)` with an
  optional fallback colour, pointing at a gradient or pattern.
- **References** (`clip-path`, `mask`, `marker-*`): `none` or `url(#id)` to an
  element of the right kind. `href`/`xlink:href`: `#id` on `use` and gradients,
  a `data:image/(png|jpeg|gif|webp);base64,` URI on `image`. A reference to a
  missing id is rejected. `use` must not reference itself or an ancestor,
  directly or indirectly.
- **transform**, `gradientTransform`, `patternTransform`: a list of `matrix`,
  `translate`, `scale`, `rotate` (1 or 3 arguments), `skewX`, `skewY`.
- **Path data** (`d`): SVG path grammar, every command `MLHVCSQTAZ` in both
  cases.
- **Enumerations**: `fill-rule`/`clip-rule` `nonzero|evenodd`;
  `stroke-linecap` `butt|round|square`; `stroke-linejoin`
  `miter|round|bevel`; `display` `inline|block|none`; `visibility`
  `visible|hidden|collapse`; `*Units` `userSpaceOnUse|objectBoundingBox`
  (`markerUnits`: `strokeWidth|userSpaceOnUse`); `spreadMethod`
  `pad|reflect|repeat`; `orient` a number, `auto` or `auto-start-reverse`;
  `text-anchor` `start|middle|end`; `dominant-baseline`
  `auto|alphabetic|middle|central|hanging`; `font-style`
  `normal|italic|oblique`; `font-weight` `normal|bold|bolder|lighter|100…900`;
  `text-decoration` `none|underline|line-through`; `preserveAspectRatio` the
  SVG grammar (`none` or `x(Min|Mid|Max)Y(Min|Mid|Max)` with optional
  `meet|slice`).
- **font-family**: any comma-separated list. The renderer uses the first
  family installed on the Mac; `sans-serif`, `system-ui`, `-apple-system`,
  `ui-sans-serif` and `BlinkMacSystemFont` map to the system font, `serif` and
  `ui-serif` to Times/New York, `monospace` and `ui-monospace` to SF Mono or
  Menlo. An unknown family falls back to the system font.

## Normalization (server, before validation)

The server rewrites CSS that has a single unambiguous meaning, so agents and
uploaded files that use it still conform:

1. `<style>` blocks whose rules all have selectors made of a type, `.class`,
   `#id`, `*`, or a compound of those (`rect.card`), in comma lists.
2. `style="…"` attributes.

The cascade is CSS's: presentation attributes lose to stylesheet rules (by
specificity, then source order), which lose to `style` declarations;
`!important` wins within its origin. Each property must be one of the
attributes above; `cursor`, `pointer-events`, `user-select`, `transition*` and
`-webkit-*`/`-moz-*` properties are dropped. After rewriting, `<style>`,
`class` and `style` are removed.

Normalization fails, and the version is rejected with a message naming the
rule, for any other selector (descendants, children, pseudo-classes, attribute
selectors), at-rules, unknown properties or `var()`/`calc()` values.

## Approved snapshot

When a person reviews a version in the Mac app, the app sends the PNG it showed
(`snapshot` on `POST …/versions/{versionId}/review`): the image, the renderer
that drew it (`vesper-native/1` or `webkit`) and the SHA-256 of the version's
SVG source. The server refuses a snapshot whose hash doesn't match the
version. Runs get it beside the SVG as `.lazyagents/context/mockup-….png`.
