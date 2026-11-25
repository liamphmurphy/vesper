# Mockup SVG profile corpus

Shared fixtures for [Mockup SVG profile v1](../../docs/dev/mockup-svg-profile.md).
The Go validator (`server/internal/artifacts`) and the Swift validator
(`macos/Sources/VesperCore/Native/MockupSVG`) must both accept every file in
`valid/` and reject every file in `invalid/`. Each invalid file breaks exactly
one rule, named by its file name. `normalize/` holds `<name>.in.svg` →
`<name>.out.svg` pairs for the server's CSS normalizer, and
`normalize-reject/` inputs it must refuse.
