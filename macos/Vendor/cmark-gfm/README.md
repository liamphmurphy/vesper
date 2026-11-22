# cmark-gfm (vendored)

GitHub's CommonMark parser with the GFM extensions, as Apple maintains it for swift-markdown:
https://github.com/swiftlang/swift-cmark, branch `gfm`, commit
`437611671145d47e6d9679761b8a5987766f4ae5`. Licence: `COPYING` (BSD-2-Clause and MIT parts).

Vendored so the Mac app's build fetches nothing (the package has no SwiftPM dependencies; the macOS
build VM has no network). Only the library sources are here: `src/` (core, with its prebuilt
`include/` headers and module map) and `extensions/` (tables, strikethrough, autolinks, task lists,
tagfilter). Nothing is modified.

The native markdown renderer uses it from `Sources/VesperCore/Markdown/MarkdownParser.swift`.

To update: clone that repository at a newer commit, copy `src/*.c`, `src/*.inc`, `src/include/`,
`extensions/*.c`, `extensions/*.h`, `extensions/include/` and `COPYING` over these, update the commit
above, and run `make -C macos test` (the markdown snapshot tests compare against the web's output).
