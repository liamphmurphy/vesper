# Markdown fixtures

Shared fixtures for the Mac app's native markdown renderer (`macos/Sources/VesperCore/Markdown`),
checked against the web's renderer (`web/components/domain/markdown.tsx`).

- `fixtures.json` lists the fixtures and how the web renders each: `chat` adds ChatMarkdown's
  rewrites (bare ticket keys become `[[links]]`, `[n]` becomes a citation for the numbers in
  `cites`).
- `fixtures/<name>.md` is the markdown.
- `expected/<name>.json` is the web's output, written by
  `node --experimental-strip-types web/scripts/markdown-fixtures.mjs`: `ast` is the remark tree
  (after the chat and wiki-link rewrites) normalized to the shape `MarkdownDocument.snapshot()`
  produces, and `code` is Shiki's tokens for each highlighted code block, with the colours
  `lib/code-colors.ts` maps them to on the default light and dark palettes.

`MarkdownSnapshotTests` (`make -C macos test`) parses every fixture natively and highlights its
code in JavaScriptCore, and fails on any difference. After changing a fixture, the web renderer,
Shiki or the themes, regenerate `expected/` (and `macos/scripts/build-shiki-bundle.mjs` for Shiki).
