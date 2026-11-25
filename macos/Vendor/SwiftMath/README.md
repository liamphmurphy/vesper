# SwiftMath (vendored)

Computer Inspirations' TeX math typesetter for Apple platforms, in pure Swift (a port of iosMath):
https://github.com/mgriebling/SwiftMath, `main` at commit `0b0222e102ba415b352cd29f334075622bd4e6aa`
(2026-10-28). Licence: `LICENSE` (MIT). The font's licences are in `Sources/mathFonts.bundle`
(`GUST-FONT-LICENSE.txt` for Latin Modern Math; `LICENSE` and `OFL.txt` as upstream ships them).

Chat math (`Sources/VesperCore/ChatEmbeds/NativeMath.swift`) lays TeX out with it and draws it with
CoreGraphics. Vendored so the build fetches nothing (the package has no SwiftPM dependencies; the macOS
build VM has no network).

Only the library's sources are here: upstream `Sources/SwiftMath/MathRender/` and `MathBundle/`, and from
`mathFonts.bundle` only `latinmodern-math.otf` and its `.plist` (Latin Modern is the closest match to
KaTeX's Computer Modern look; the other eleven fonts would add about 6 MB). The fonts load on demand, so
the missing ones are never read; `MathFont` still lists them. One file is Vesper's own:
`Sources/VesperTypesetting.swift`, a public entry point to the typesetter and the font (upstream
reaches them only through its label view). Nothing else is modified. It builds in Swift 5 language mode.

To update: check out a newer commit, copy `Sources/SwiftMath/MathRender/` and `MathBundle/` over these (keep
`VesperTypesetting.swift`), copy the Latin Modern font and plist into `Sources/mathFonts.bundle`, update the commit above, and run
`swift build --package-path macos` and `make -C macos test` (`NativeMathTests`).
