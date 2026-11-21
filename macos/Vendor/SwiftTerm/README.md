# SwiftTerm (vendored)

Miguel de Icaza's terminal emulator for AppKit, in pure Swift: https://github.com/migueldeicaza/SwiftTerm,
tag `v1.18.0`, commit `7691f85b222a67a66b58499e1b2647443cf0dda7`. Licence: `LICENSE` (MIT; it carries the
xterm.js authors' notice too, since SwiftTerm's parser started as a port of xterm.js).

The Dev workspace's terminal (`Sources/Vesper/Native/Dev/`) draws with its `TerminalView`. Vendored so the
Mac app's build fetches nothing (the package has no SwiftPM dependencies; the macOS build VM has no network).
SwiftTerm over libghostty because it builds with SwiftPM alone: libghostty needs Zig and a prebuilt
xcframework. `v1.18.0` is the last release whose library target needs no build-tool plugin (from `v1.19.0`
a plugin generates build-info and terminfo sources with git at build time).

Only the library's sources are here: upstream `Sources/SwiftTerm/` without `iOS/` (UIKit only),
`Documentation.docc/`, `Mac/README.md` and `Apple/Metal/Shaders.metal` (the Metal renderer is opt-in and
unused; leaving the shader out keeps SwiftPM from making a resource bundle). Nothing is modified. It builds
in Swift 5 language mode, as upstream does.

To update: check out a newer tag, copy `Sources/SwiftTerm/` and `LICENSE` over these, drop the same
paths, update the tag and commit above, and run `swift build --package-path macos` and
`make -C macos test`. A tag that adds a build plugin or package dependency to the `SwiftTerm` target
needs its generated sources committed here instead.
