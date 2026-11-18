# Native bridge protocol fixtures

Example messages for the protocol between the web UI and the macOS shell
(`web/lib/native-shell/protocol.ts`, mirrored in
`macos/Sources/VesperCore/Bridge/Protocol.swift`).

- `page-messages.json`: page → shell messages. Every entry must decode on the Swift side.
- `native-commands.json`: shell → page commands. Every entry must pass `isNativeCommand` on the
  web side and must round-trip through the Swift encoder.

Both test suites read these files. Change the protocol in both places and add an example here
in the same commit.
